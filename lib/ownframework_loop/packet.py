"""Work packet parsing, validation, hashing, and immutability.

V2 wires approval authority to a separate ``APPROVAL.json`` artifact (see
``approval.py``). The packet itself is byte-immutable after approval and
must NOT carry any ``approved_*`` / ``human_approved`` fields. Only
``schema: ownframework-work-packet/v2`` packets are accepted by V2 runs.
V1 packets with embedded approval fields are recognized by
``approval.is_legacy_packet_approval`` and must be re-approved under the
V2 contract.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from .util import sha256_text
from .integrity import canonical_json_dumps
from . import capabilities as capabilities_mod, git_checks, schema_validate


SCHEMA_VERSION = "ownframework-work-packet/v2"
LEGACY_SCHEMA_VERSION = "ownframework-work-packet/v1"
PROGRAM_SCHEMA_VERSION = "ownframework-work-packet/v3"
SUPPORTED_SCHEMA_VERSIONS = (LEGACY_SCHEMA_VERSION, SCHEMA_VERSION, PROGRAM_SCHEMA_VERSION)

WORK_CLASSES = {
    "NEW_REPOSITORY", "FEATURE", "BUG", "DEBUG", "HARDENING",
    "REFACTOR", "TESTING", "DOCUMENTATION", "CI_REPAIR",
    "TRACKED_CONTRACT", "RUNTIME_CANDIDATE", "RESEARCH_SPIKE",
}

RISK_CLASSES = {"low", "medium", "high"}

_NETWORK_READ_HOST_RE = re.compile(
    r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*"
    r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"
)
MAX_NETWORK_READ_DOMAINS = 64

REQUIRED_FIELDS = (
    "schema", "packet_id", "created_at", "work_class", "risk_class",
    "title", "target", "acceptance_criteria", "non_goals",
    "allowed_paths", "protected_paths", "work_units",
    "merge_authority", "deploy_authority", "push_authority",
    "external_action_authority",
)


def parse_packet_file(path: Path) -> tuple[dict[str, Any], str]:
    """Parse a WORK_PACKET.md file. Returns (metadata_dict, raw_text).

    The packet has a JSON metadata block enclosed in fenced code blocks
    (```json ... ```), followed by readable Markdown. The first JSON block
    is authoritative. Pure stdlib — no YAML dependency.
    """
    text = path.read_text(encoding="utf-8")
    meta = _extract_metadata_block(text)
    return meta, text


def _extract_metadata_block(text: str) -> dict[str, Any]:
    """Extract the first ```json ... ``` fenced block."""
    pattern = re.compile(r"```json\s*\n(.*?)\n```", re.DOTALL)
    match = pattern.search(text)
    if not match:
        raise ValueError("WORK_PACKET.md missing ```json metadata block")
    try:
        return json.loads(match.group(1))
    except json.JSONDecodeError as e:
        raise ValueError(f"WORK_PACKET.md metadata is not valid JSON: {e}") from e


def _scope_path_error(value: Any) -> str | None:
    """Return an error for scope paths that are not canonical repo-relative paths.

    Scope entries are prefix declarations. For authoring convenience, a single
    trailing ``/**`` is accepted as an exact synonym for the same directory
    prefix without the suffix (``apps/**`` == ``apps``). Arbitrary globbing is
    intentionally not supported by the deterministic scope engine.
    """
    if not isinstance(value, str) or not value.strip():
        return "must be a non-empty string"
    raw = value.strip()
    if "\x00" in raw or "\\" in raw:
        return "must not contain NUL or backslash separators"
    if raw.startswith("/") or raw.startswith("~") or Path(raw).is_absolute():
        return "must be repository-relative, not absolute/home-relative"
    if raw.startswith("./"):
        raw = raw[2:]
    raw = raw.rstrip("/")
    if "*" in raw:
        if not raw.endswith("/**") or raw.count("*") != 2:
            return "only a single trailing /** suffix is supported; arbitrary globs are not"
        raw = raw[:-3].rstrip("/")
    if not raw:
        return "must identify a repository-relative file or directory"
    parts = raw.split("/")
    if any(part in (".", "..", "") for part in parts):
        return "must not contain traversal or empty path components"
    return None


def _validate_risk_budget_envelope(meta: dict[str, Any]) -> list[str]:
    """Reject packet budgets the executable runtime can never honor."""
    errors: list[str] = []
    rb = meta.get("risk_budget")
    if rb is None:
        return errors
    if not isinstance(rb, dict):
        return ["risk_budget must be an object"]
    v3 = meta.get("schema") == PROGRAM_SCHEMA_VERSION
    # Runtime envelopes: a sealed PROGRAM must be able to fund the work it
    # describes. max_runtime_seconds is the whole-run wall-clock envelope
    # (consumed by `supervisor enqueue`); max_pass_runtime_seconds is one
    # semantic worker's authority. Both remain bounded so a packet cannot
    # declare nonsense values, but the v3 ceilings are sized for real
    # multi-checkpoint programs (28 days whole-run, 8h per pass). The v2
    # single-run pass ceiling stays below the historical 3600s fallback fuse
    # only insofar as packets narrow; it no longer caps BELOW the fallback.
    maxima = {
        "max_files_changed": 500,
        "max_diff_lines": 30000,
        "max_repair_rounds": 128 if v3 else 32,
        "max_build_passes": 128 if v3 else 32,
        "max_review_passes": 128 if v3 else 32,
        "max_runtime_seconds": 2419200 if v3 else 28800,
        "max_pass_runtime_seconds": 28800 if v3 else 7200,
        "max_consecutive_no_progress_passes": 8,
        "max_identical_finding_repeats": 8,
    }
    for key, ceiling in maxima.items():
        value = rb.get(key)
        if value is None:
            continue
        if not isinstance(value, int) or isinstance(value, bool) or value < 1:
            errors.append(f"risk_budget.{key} must be a positive integer")
            continue
        if value > ceiling:
            errors.append(
                f"risk_budget.{key}={value} exceeds executable ceiling {ceiling}"
            )
    return errors


def validate_packet_metadata(meta: dict[str, Any]) -> list[str]:
    """Return list of validation errors (empty if valid).

    Dispatch by packet schema: v1/v2 use the standard contract; v3
    additionally requires `execution_mode`, and (if `execution_mode ==
    program`) `checkpoint_graph`, and (always optional) `promotion_policy`.
    """
    errors: list[str] = []
    schema = meta.get("schema")
    if schema not in SUPPORTED_SCHEMA_VERSIONS:
        errors.append(
            f"schema must be one of {sorted(SUPPORTED_SCHEMA_VERSIONS)}, got {schema!r}"
        )
        # Even on schema mismatch, do not run downstream checks against
        # potentially-mutated field set.
        return errors

    # v3 packets: execution_mode is OPTIONAL in the schema (default "single")
    # so v3 stays a strict superset of v2. The validator must accept the
    # schema default; only invalidate when execution_mode is present but
    # invalid. Audit v0.3.0-F2: previous hard-reject diverged from the
    # schema and rejected schema-valid packets.
    if schema == PROGRAM_SCHEMA_VERSION and "execution_mode" in meta and meta["execution_mode"] not in ("single", "program"):
        errors.append(f"execution_mode must be single|program, got {meta['execution_mode']!r}")
    errors.extend(_validate_risk_budget_envelope(meta))
    errors.extend(capabilities_mod.validate_capability_names(meta.get("capabilities")))

    if schema == PROGRAM_SCHEMA_VERSION:
        em = meta.get("execution_mode")
        # Schema default is "single"; only validate when present.
        if em is not None and em not in ("single", "program"):
            errors.append(f"execution_mode must be single|program, got {em!r}")
        pp = meta.get("promotion_policy")
        if pp is not None and pp not in ("human_gate", "merge_on_approved"):
            errors.append(f"promotion_policy invalid: {pp!r}")
        if em == "program":
            from .program import validate_checkpoint_graph as _validate_cg
            errors.extend(_validate_cg(meta))

    for f in REQUIRED_FIELDS:
        if f not in meta:
            errors.append(f"missing required field: {f}")
    wc = meta.get("work_class")
    if wc not in WORK_CLASSES:
        errors.append(f"invalid work_class: {wc}")
    rc = meta.get("risk_class")
    if rc not in RISK_CLASSES:
        errors.append(f"invalid risk_class: {rc}")
    tgt = meta.get("target")
    if isinstance(tgt, dict):
        repo = tgt.get("repo")
        if not isinstance(repo, str) or not Path(repo).is_absolute():
            errors.append("target.repo must be absolute path")
        for k in ("branch", "classification"):
            if k not in tgt:
                errors.append(f"target.{k} missing")
        branch = tgt.get("branch")
        if isinstance(branch, str) and branch and not git_checks.is_valid_branch_name(branch):
            errors.append(f"target.branch is not a valid Git branch: {branch!r}")
        candidate = tgt.get("candidate_branch_prefix")
        if candidate is not None:
            if not isinstance(candidate, str) or not git_checks.is_valid_branch_name(candidate):
                errors.append(
                    f"target.candidate_branch_prefix is not a valid Git branch: {candidate!r}"
                )
        cls = tgt.get("classification")
        if cls not in ("local_only", "github_private", "github_public"):
            errors.append(f"invalid target.classification: {cls}")
    else:
        errors.append("target must be an object")
    if not isinstance(meta.get("acceptance_criteria"), list) or not meta["acceptance_criteria"]:
        errors.append("acceptance_criteria must be a non-empty array")
    if not isinstance(meta.get("work_units"), list) or not meta["work_units"]:
        errors.append("work_units must be a non-empty array")

    network_domains = meta.get("network_read_allowlist", [])
    if not isinstance(network_domains, list):
        errors.append("network_read_allowlist must be an array")
    else:
        if len(network_domains) > MAX_NETWORK_READ_DOMAINS:
            errors.append(
                f"network_read_allowlist may contain at most {MAX_NETWORK_READ_DOMAINS} domains"
            )
        seen_network_domains: set[str] = set()
        for idx, value in enumerate(network_domains):
            if not isinstance(value, str):
                errors.append(
                    f"network_read_allowlist[{idx}] must be a lowercase hostname"
                )
                continue
            if value != value.strip() or value != value.lower() or not _NETWORK_READ_HOST_RE.fullmatch(value):
                errors.append(
                    f"network_read_allowlist[{idx}] must be a lowercase hostname without scheme, port, path, or wildcard: {value!r}"
                )
                continue
            if value in seen_network_domains:
                errors.append(f"network_read_allowlist contains duplicate domain: {value}")
            seen_network_domains.add(value)

    if not isinstance(meta.get("allowed_paths"), list) or not meta["allowed_paths"]:
        errors.append("allowed_paths must be a non-empty array")
    if not isinstance(meta.get("protected_paths"), list) or not meta["protected_paths"]:
        errors.append("protected_paths must be a non-empty array")
    for field in (
        "relevant_paths", "allowed_paths", "protected_paths",
        "sensitive_paths", "elevated_allowed_paths",
    ):
        values = meta.get(field) or []
        if not isinstance(values, list):
            continue
        for idx, value in enumerate(values):
            err = _scope_path_error(value)
            if err:
                errors.append(f"{field}[{idx}] {err}: {value!r}")
    for auth in ("merge_authority", "deploy_authority", "push_authority", "external_action_authority"):
        v = meta.get(auth)
        if v not in ("human_only", "delegated", "none"):
            errors.append(f"{auth} must be human_only|delegated|none, got: {v}")
    return errors


# Known project root files (no slash, dotfile or extension-bearing filename
# at the repository root). When a NEW_REPOSITORY or TRACKED_CONTRACT work
# unit's prose names one of these, allowed_paths MUST include it.
# Conservative list — only files that are unambiguous root-level artifacts.
KNOWN_ROOT_FILES: frozenset[str] = frozenset(
    {
        "pyproject.toml", "setup.py", "setup.cfg",
        "README.md", "README.rst", "README",
        "LICENSE", "LICENSE.md", "LICENSE.txt",
        "CHANGELOG.md", "CONTRIBUTING.md",
        "Makefile", "Dockerfile",
        ".gitignore", ".dockerignore", ".editorconfig", ".env.example",
        "package.json", "Cargo.toml", "go.mod",
    }
)


# Regex matching a literal root-level file reference in prose. Matches:
#   pyproject.toml      (alphanum/underscore/dot/dash, with extension)
#   .gitignore          (leading-dot dotfile)
#   README              (alphanum word with no extension)
# Conservative — only matches tokens that look like filenames (no slash).
_ROOT_FILE_TOKEN_RE = re.compile(
    r"(?<![\w./-])"                                # not preceded by word/slash/dot/dash
    r"(?:"                                          # one of:
    r"\.[A-Za-z][A-Za-z0-9_.-]{0,32}"               #   .dotfile (e.g. .gitignore)
    r"|[A-Za-z][A-Za-z0-9_-]{0,32}\.[A-Za-z0-9]{1,5}"  # name.ext (e.g. pyproject.toml)
    r"|[A-Z][A-Z0-9_-]{1,32}"                       # ALL-CAPS (e.g. README, LICENSE, Makefile)
    r")"
    r"(?![\w./-])"                                  # not followed by word/slash/dot/dash
)


def _extract_root_file_references(meta: dict[str, Any]) -> set[str]:
    """Return root-level filename tokens referenced in work_units + title.

    Conservative: only tokens in KNOWN_ROOT_FILES are returned (this avoids
    false positives like 'should', 'http', 'make', etc.). The caller decides
    whether to surface a missing-from-allowed_paths error.
    """
    tokens: set[str] = set()
    blob_parts: list[str] = []
    title = meta.get("title")
    if isinstance(title, str):
        blob_parts.append(title)
    for wu in meta.get("work_units") or []:
        if not isinstance(wu, dict):
            continue
        for k in ("title", "scope"):
            v = wu.get(k)
            if isinstance(v, str):
                blob_parts.append(v)
    blob = "\n ".join(blob_parts)
    for m in _ROOT_FILE_TOKEN_RE.finditer(blob):
        tok = m.group(0)
        if tok in KNOWN_ROOT_FILES:
            tokens.add(tok)
    return tokens


def validate_packet_self_consistency(meta: dict[str, Any]) -> list[str]:
    """Detect packet prose vs allowed_paths drift.

    A packet is self-inconsistent when its work_units or title reference a
    known project root file (e.g. ``pyproject.toml``) but ``allowed_paths``
    does not include it. This is the deterministic pre-approval check that
    prevents the v0.4.1 commissioning failure where a generated packet
    required ``pyproject.toml`` (WU-1 prose) yet ``allowed_paths`` only
    listed ``src/`` and ``tests/``.

    Returns a list of human-readable error strings (empty == consistent).
    Run this AFTER ``validate_packet_metadata``; it does not duplicate
    schema-level checks.
    """
    errors: list[str] = []
    allowed = list(meta.get("allowed_paths") or [])
    protected = list(meta.get("protected_paths") or [])
    if not isinstance(allowed, list):
        return errors  # covered by validate_packet_metadata
    referenced = _extract_root_file_references(meta)
    if not referenced:
        return errors
    allowed_norm = {p.rstrip("/") for p in allowed if isinstance(p, str)}
    protected_norm = {p.rstrip("/") for p in protected if isinstance(p, str)}
    missing = sorted(t for t in referenced if t not in allowed_norm and t not in protected_norm)
    if missing:
        names = ", ".join(missing)
        errors.append(
            "work_units reference root-level file(s) that are NOT in allowed_paths "
            f"or protected_paths: {names}. Either include them in allowed_paths "
            "or remove the reference from work_units prose."
        )
    return errors


def validate_packet_for_approval(meta: dict[str, Any]) -> list[str]:
    """Fail-closed admission validator for packets entering execution.

    Current v2/v3 packets must first satisfy the checked-in structural JSON
    schema. Only after that proof do the handwritten deterministic checks own
    higher-level executable/business invariants (authority, path safety,
    budgets, PROGRAM graph consistency, and packet/source consistency).

    Legacy v1 packets have no current published schema file and retain their
    historical handwritten parse/audit path; they still cannot become a modern
    execution seal without the surrounding compatibility rules.
    """
    schema = meta.get("schema")
    if schema in (SCHEMA_VERSION, PROGRAM_SCHEMA_VERSION):
        structural = schema_validate.validate_packet(meta)
        if structural:
            return [f"schema: {err}" for err in structural]

    errors: list[str] = list(validate_packet_metadata(meta))
    errors.extend(validate_packet_self_consistency(meta))
    return errors


def is_approved(meta: dict[str, Any]) -> bool:
    """V1 packet-shape approval check — legacy fields only.

    V2 runs MUST use the separate APPROVAL.json artifact. A return value
    of True here is informational only and is never consulted by the V2
    build/review finalizers (which call ``approval.validate_approval_binding``).
    """
    if meta.get("schema") == LEGACY_SCHEMA_VERSION:
        if meta.get("human_approved") is True:
            return True
        if meta.get("approved_packet_sha256") and meta.get("approved_at"):
            return True
    return False


def packet_file_sha256(path: Path) -> str:
    """SHA-256 of the raw packet bytes."""
    return sha256_text(path.read_text(encoding="utf-8"))


def packet_metadata_sha256(meta: dict[str, Any]) -> str:
    """SHA-256 of the deterministic metadata serialization.

    Uses canonical_json_dumps (compact, sort_keys, separators=(",", ":"))
    so packet_metadata_sha256 is byte-identical to canonical_json_dumps
    output. Indented json.dumps diverges from the canonical form and was
    removed by audit (v0.3.0).
    """
    return sha256_text(canonical_json_dumps(meta))


def packet_is_v2(meta: dict[str, Any]) -> bool:
    """True iff the packet carries the V2 schema."""
    return meta.get("schema") == SCHEMA_VERSION


def packet_is_legacy_v1(meta: dict[str, Any]) -> bool:
    """True iff the packet carries the legacy V1 schema."""
    return meta.get("schema") == LEGACY_SCHEMA_VERSION


def paths_within_packet(packet: dict[str, Any]) -> set[str]:
    """Return the union of allowed + protected paths (for fast membership)."""
    s = set()
    for p in packet.get("allowed_paths", []):
        s.add(p.rstrip("/") + "/")
        s.add(p)
    for p in packet.get("protected_paths", []):
        s.add(p.rstrip("/") + "/")
        s.add(p)
    return s


def _normalize_path_for_compare(p: str) -> str:
    """Normalize a path for membership comparison.

    Strips a single leading `./`, then a single leading `/`. Does NOT
    strip arbitrary leading dots — `.claude/` is meaningful.
    """
    s = p
    if s.startswith("./"):
        s = s[2:]
    if s.startswith("/"):
        s = s[1:]
    return s


def _normalize_scope_prefix(p: str) -> str:
    """Normalize one declared scope entry to deterministic prefix form.

    ``dir/**`` is accepted as a compatibility spelling for ``dir`` because
    packet authors commonly use recursive-glob notation even though Loop scope
    semantics are prefix-based rather than general glob matching.
    """
    s = _normalize_path_for_compare(p).rstrip("/")
    if s.endswith("/**"):
        s = s[:-3].rstrip("/")
    return s


def path_matches_scope_entry(file_path: str, scope_entry: str) -> bool:
    """Return True when ``file_path`` is inside one declared scope prefix."""
    fp = _normalize_path_for_compare(file_path).rstrip("/")
    prefix = _normalize_scope_prefix(scope_entry)
    if not prefix:
        return False
    return fp == prefix or fp.startswith(prefix + "/")


def is_protected_path(packet: dict[str, Any], file_path: str) -> bool:
    """Return True if file_path is in the packet's protected_paths."""
    return any(
        path_matches_scope_entry(file_path, p)
        for p in packet.get("protected_paths", [])
        if isinstance(p, str)
    )


def is_allowed_path(packet: dict[str, Any], file_path: str) -> bool:
    """Return True if file_path is within the packet's allowed_paths."""
    return any(
        path_matches_scope_entry(file_path, p)
        for p in packet.get("allowed_paths", [])
        if isinstance(p, str)
    )


def packet_is_program(meta: dict[str, Any]) -> bool:
    """True iff the packet is a v3 PROGRAM-mode packet."""
    return (
        meta.get("schema") == PROGRAM_SCHEMA_VERSION
        and meta.get("execution_mode") == "program"
    )


# v0.6.0 — current executable packet authority model.
# Distinct from validate_packet_metadata (which only checks parseable shape).
# A packet MAY be parseable yet not executable under current 0.6 rules.
EXECUTABLE_AUTHORITY_REQUIREMENTS: tuple[tuple[str, str], ...] = (
    ("merge_authority", "human_only"),
    ("push_authority", "human_only"),
    ("deploy_authority", "human_only"),
    ("external_action_authority", "none"),
)
EXECUTABLE_PROMOTION_POLICY: str = "human_gate"


def packet_is_executable_under_current_authority(meta: dict[str, Any]) -> tuple[bool, list[str]]:
    """True iff the packet would be accepted for execution under current v0.6 rules.

    A packet that parses cleanly but carries `external_action_authority=delegated`
    or `promotion_policy=merge_on_approved` is NOT executable under current rules.
    Such packets remain readable for audit/compatibility, but dispatch will refuse
    to claim a BUILD/REVIEW work order for them.
    """
    reasons: list[str] = []
    for field, required in EXECUTABLE_AUTHORITY_REQUIREMENTS:
        actual = meta.get(field)
        if actual != required:
            reasons.append(
                f"{field} must be {required!r} for current execution, got {actual!r}"
            )
    pp = meta.get("promotion_policy")
    if pp not in (None, EXECUTABLE_PROMOTION_POLICY):
        reasons.append(
            f"promotion_policy must be {EXECUTABLE_PROMOTION_POLICY!r} or omitted "
            f"for current execution, got {pp!r}"
        )
    return (not reasons, reasons)
