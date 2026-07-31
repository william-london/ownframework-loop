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

    # v3 packets must additionally declare execution_mode.
    if schema == PROGRAM_SCHEMA_VERSION and "execution_mode" not in meta:
        errors.append("v3 packets must declare execution_mode (single|program)")
    if schema == PROGRAM_SCHEMA_VERSION:
        em = meta.get("execution_mode")
        if em not in (None, "single", "program"):
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
        cls = tgt.get("classification")
        if cls not in ("local_only", "github_private", "github_public"):
            errors.append(f"invalid target.classification: {cls}")
    else:
        errors.append("target must be an object")
    if not isinstance(meta.get("acceptance_criteria"), list) or not meta["acceptance_criteria"]:
        errors.append("acceptance_criteria must be a non-empty array")
    if not isinstance(meta.get("work_units"), list) or not meta["work_units"]:
        errors.append("work_units must be a non-empty array")
    if not isinstance(meta.get("allowed_paths"), list) or not meta["allowed_paths"]:
        errors.append("allowed_paths must be a non-empty array")
    if not isinstance(meta.get("protected_paths"), list) or not meta["protected_paths"]:
        errors.append("protected_paths must be a non-empty array")
    for auth in ("merge_authority", "deploy_authority", "push_authority", "external_action_authority"):
        v = meta.get(auth)
        if v not in ("human_only", "delegated", "none"):
            errors.append(f"{auth} must be human_only|delegated|none, got: {v}")
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
    """SHA-256 of the deterministic metadata serialization."""
    return sha256_text(json.dumps(meta, indent=2, sort_keys=True))


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


def is_protected_path(packet: dict[str, Any], file_path: str) -> bool:
    """Return True if file_path is in the packet's protected_paths."""
    pp = [_normalize_path_for_compare(p).rstrip("/") for p in packet.get("protected_paths", [])]
    fp = _normalize_path_for_compare(file_path)
    for p in pp:
        if p == "":
            continue
        if fp == p or fp.startswith(p + "/"):
            return True
    return False


def is_allowed_path(packet: dict[str, Any], file_path: str) -> bool:
    """Return True if file_path is within the packet's allowed_paths."""
    ap = [_normalize_path_for_compare(p).rstrip("/") for p in packet.get("allowed_paths", [])]
    fp = _normalize_path_for_compare(file_path)
    for p in ap:
        if p == "":
            continue
        if fp == p or fp.startswith(p + "/"):
            return True
    return False


def packet_is_program(meta: dict[str, Any]) -> bool:
    """True iff the packet is a v3 PROGRAM-mode packet."""
    return (
        meta.get("schema") == PROGRAM_SCHEMA_VERSION
        and meta.get("execution_mode") == "program"
    )


def packet_promotion_policy(meta: dict[str, Any]) -> str:
    """Return "human_gate" (default) or "merge_on_approved"."""
    p = meta.get("promotion_policy")
    if p is None:
        return "human_gate"
    if p not in ("human_gate", "merge_on_approved"):
        raise ValueError(f"invalid promotion_policy: {p!r}")
    return p
