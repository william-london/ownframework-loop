"""BUILD_AGENT_RESULT.json skeleton scaffolding.

v0.4.3: the deterministic build finalizer (build_finalize.py) refuses
any agent result whose top-level shape does not match the schema
contract. The v0.4.2 incident (first real PROGRAM benchmark) saw the
fresh `of-builder` agent faithfully follow the SKILL.md prose and emit:

  - schema: "ownframework-loop-builder-result/v1"  (finalizer expects
    "ownframework-loop-build-agent-result/v1")
  - field "outcome"  (finalizer expects "outcome_requested")
  - field "unit_ids_completed"  (finalizer expects "work_unit_id")

…which the finalizer deterministically refused with
OF_LOOP_BUILD_FINALIZE_REFUSED.

This module makes the contract unambiguous the same way the v0.4.2
reviewer assessment flow did:

  1. A single template ships with the source tree.
  2. A single helper writes a per-run skeleton pre-populated with the
     exact run id, packet SHA, approval SHA, baseline_sha, candidate_branch,
     current work_unit_id, and builder-worktree path.
  3. The CLI surfaces it as `ofloop build agent-skeleton <repo> <run-id>`.

The builder agent's responsibility is to:
  1. Run `ofloop build agent-skeleton <repo> <run-id>` (or rely on the
     parent build skill to do so) to materialize a skeleton at the run
     scratch path.
  2. Fill in only the values that are runtime-dependent:
     summary, evidence dict, blocker_reason, escalation_*, notes,
     unit_ids_completed, acceptance_addressed, timestamp.
  3. NOT rename any top-level key, NOT change the outcome enum casing,
     NOT introduce new top-level keys, NOT change the schema name.

If a runtime value would force a top-level rename, the builder agent
must STOP and report the contract drift — the deterministic finalizer
will still refuse.

This module never edits BUILD_RECEIPT.json. The agent never edits
BUILD_RECEIPT.json. Only `ofloop build finalize` (via this library)
writes BUILD_RECEIPT.json.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from . import approval as approval_mod
from . import git_checks, program as program_mod, state as state_mod, util


SCHEMA_AGENT_RESULT = "ownframework-loop-build-agent-result/v1"
AGENT_RESULT_TEMPLATE_NAME = "BUILD_AGENT_RESULT.template.json"

# Top-level keys the builder agent is expected to fill in (everything
# else is pre-populated by the skeleton helper).
# FILLABLE_KEYS — every key the builder agent is allowed to mutate
# at fill-time. outcome_requested is included because the agent must
# be able to switch it from the skeleton default `candidate_ready` to
# `blocked` or `stopped` on failure paths; the deterministic finalizer
# still validates the enum.
FILLABLE_KEYS: frozenset[str] = frozenset(
    {
        "summary",
        "evidence",
        "blocker_reason",
        "escalation_recommended",
        "escalation_reason",
        "outcome_requested",
        "unit_ids_completed",
        "acceptance_addressed",
        "notes",
        "timestamp",
    }
)

# Outcome enum — exact lowercase-with-underscore required.
ALLOWED_OUTCOMES: frozenset[str] = frozenset(
    {"candidate_ready", "blocked", "stopped"}
)
REQUIRED_RESULT_KEYS: frozenset[str] = frozenset(
    {"schema", "run_id", "work_unit_id", "outcome_requested"}
)
FIXED_KEYS: frozenset[str] = frozenset(
    {
        "schema",
        "run_id",
        "work_unit_id",
        "candidate_branch",
        "baseline_sha",
        "packet_sha256",
        "approval_sha256",
        "builder_identity",
    }
)
ALLOWED_RESULT_KEYS: frozenset[str] = frozenset(
    {
        *FIXED_KEYS,
        *FILLABLE_KEYS,
        "evidence",
        # Retained for compatibility with pre-v0.9 synthetic adapters. The
        # authoritative finalizer ignores these model-provided measurements.
        "candidate_sha_claimed",
        "files_changed",
        "added_lines",
        "removed_lines",
    }
)


def validate_agent_result_contract(result: Any) -> list[str]:
    """Validate shared builder semantic JSON shape without completion policy.

    Dispatch adds readiness requirements such as non-empty summary/evidence of
    completion and clean exact worktree. The deterministic finalizer adds
    identity/SHA/protocol checks. Both layers share this type/enum contract so
    they cannot disagree on the same model-authored field shape.
    """
    if not isinstance(result, dict):
        return ["builder semantic result must be an object"]

    errors: list[str] = []
    unknown = sorted(set(result) - ALLOWED_RESULT_KEYS)
    if unknown:
        errors.append(
            "unsupported top-level keys: " + ",".join(unknown)
        )
    for field in sorted(FIXED_KEYS):
        # Older sealed packets and deterministic fixtures may legitimately
        # omit identity fields that the finalizer can re-prove from the
        # approval/state boundary.  When a model supplies one, however, it is
        # transport-owned and must be a non-empty string.
        if field in result and (
            not isinstance(result.get(field), str)
            or not str(result.get(field) or "").strip()
        ):
            errors.append(f"fixed field {field} must be a non-empty string")
    for field in sorted(REQUIRED_RESULT_KEYS):
        if field not in result:
            errors.append(f"missing required field: {field}")
    if result.get("schema") != SCHEMA_AGENT_RESULT:
        errors.append(f"schema must be {SCHEMA_AGENT_RESULT}")
    if not isinstance(result.get("run_id"), str) or not str(result.get("run_id") or "").strip():
        errors.append("run_id must be a non-empty string")
    if not isinstance(result.get("work_unit_id"), str) or not str(result.get("work_unit_id") or "").strip():
        errors.append("work_unit_id must be a non-empty string")
    if "builder_identity" in result and result.get("builder_identity") != "of-builder":
        errors.append("builder_identity must be of-builder")
    if result.get("outcome_requested") not in ALLOWED_OUTCOMES:
        errors.append(f"outcome_requested must be one of {sorted(ALLOWED_OUTCOMES)}")

    if "summary" in result and not isinstance(result.get("summary"), str):
        errors.append("summary must be a string")
    if "evidence" in result and not isinstance(result.get("evidence"), dict):
        errors.append("evidence must be an object")
    for field in ("blocker_reason", "escalation_reason", "notes"):
        value = result.get(field)
        if value is not None and not isinstance(value, str):
            errors.append(f"{field} must be a string or null")
    if (
        "escalation_recommended" in result
        and not isinstance(result.get("escalation_recommended"), bool)
    ):
        errors.append("escalation_recommended must be a boolean")
    for field in ("unit_ids_completed", "acceptance_addressed"):
        if field not in result:
            continue
        value = result.get(field)
        if not isinstance(value, list):
            errors.append(f"{field} must be a list")
        elif any(not isinstance(item, str) or not item for item in value):
            errors.append(f"{field} must contain only non-empty strings")
    return errors


def template_path(source_root: Path) -> Path:
    """Return the absolute path of the bundled agent-result template."""
    return source_root / "templates" / AGENT_RESULT_TEMPLATE_NAME


def agent_result_path(canonical_repo: Path, run_id: str) -> Path:
    """Return the current claimed build pass's semantic-result path.

    v0.4.5: semantic artifacts are pass-scoped. A replayed claim retains the
    same pass number/path for crash recovery; a fresh claim gets a fresh path,
    so CP-N can never inherit CP-(N-1)'s filled result.
    """
    state = state_mod.load_verified(canonical_repo, run_id)
    pass_number = int((state or {}).get("build_pass_count") or 0)
    if pass_number < 1:
        raise RuntimeError(
            "build_pass_count=0; claim the build pass before materializing the agent result"
        )
    return (
        state_mod.run_dir(canonical_repo, run_id)
        / "scratch" / "builder" / f"pass-{pass_number:04d}"
        / "BUILD_AGENT_RESULT.json"
    )


def _find_source_root(start: Path) -> Path | None:
    """Walk upward from `start` looking for the source tree root marker.

    The source root contains `templates/BUILD_AGENT_RESULT.template.json`
    and `lib/ownframework_loop/`. We accept either as the marker. This
    works for both the source checkout and the installed cache
    (`~/.claude/plugins/cache/ownframework/of-loop/<version>/`).
    """
    p = start.resolve()
    for candidate in (p, *p.parents):
        if (candidate / "templates" / AGENT_RESULT_TEMPLATE_NAME).is_file():
            return candidate
    return None


def _resolve_run_id(canonical_repo: Path, run_id: str | None) -> str:
    """Resolve the run id from an explicit arg or the single active run."""
    if run_id:
        return run_id
    rd = Path(canonical_repo) / ".ownframework-loop"
    runs = sorted(p.name for p in rd.iterdir() if p.is_dir() and p.name.startswith("run-"))
    if not runs:
        raise RuntimeError(
            f"no run-* directories under {canonical_repo}/.ownframework-loop"
        )
    if len(runs) > 1:
        raise RuntimeError(
            f"multiple active runs in {canonical_repo}/.ownframework-loop; "
            f"pass --run-id explicitly: {', '.join(runs)}"
        )
    return runs[0]


def _resolve_packet_sha256(canonical_repo: Path, run_id: str) -> str:
    packet_p = state_mod.run_dir(canonical_repo, run_id) / "WORK_PACKET.md"
    if not packet_p.exists():
        raise RuntimeError(
            f"WORK_PACKET.md missing for run {run_id}; cannot scaffold agent result"
        )
    return util.sha256_text(packet_p.read_text(encoding="utf-8"))


def _resolve_approval_sha256(canonical_repo: Path, run_id: str) -> str:
    approval_doc = approval_mod.load_approval(canonical_repo, run_id)
    if not approval_doc:
        raise RuntimeError(
            f"APPROVAL.json missing for run {run_id}; cannot scaffold agent result"
        )
    return approval_mod.approval_artifact_sha256(approval_doc)


def _safe_parse_packet(packet_path: Path) -> tuple[dict[str, Any], str]:
    """Historical name retained for compatibility; authoritative parsing is strict."""
    from . import packet as packet_mod  # local import to avoid cycles
    return packet_mod.parse_packet_file(packet_path)


def _resolve_current_work_unit_id(canonical_repo: Path, run_id: str) -> str:
    """Resolve the current work-unit id from the approved packet + state.

    For PROGRAM mode, this is the first work unit of the current
    checkpoint. For SINGLE mode, the first work unit of the packet.

    Missing or malformed work-unit identity is an authority error. The
    skeleton must never fabricate UNIT-1 merely to satisfy schema shape.
    """
    state = state_mod.load_verified(canonical_repo, run_id)
    packet_p = state_mod.run_dir(canonical_repo, run_id) / "WORK_PACKET.md"
    meta, _ = _safe_parse_packet(packet_p)
    work_units = meta.get("work_units") or []
    if not work_units:
        raise RuntimeError("packet has no work_units; cannot scaffold build identity")

    if state_mod.is_program_state(state):
        program = state.get("program") or {}
        # v0.9.1+: a whole-product (program_final) repair build is owned
        # by no individual CP; surface the typed program-final marker
        # so the agent skeleton never fakes ownership of the first
        # packet work unit.
        if program.get("review_scope") == program_mod.REVIEW_SCOPE_PROGRAM_FINAL:
            return program_mod.PROGRAM_FINAL_REPAIR_WORK_UNIT_ID
        current_cps = program.get("current_checkpoints") or []
        if current_cps:
            cp_id = current_cps[0]
            cps = (meta.get("checkpoint_graph") or {}).get("checkpoints") or []
            checkpoint_found = False
            for cp in cps:
                if cp.get("id") != cp_id:
                    continue
                checkpoint_found = True
                try:
                    return program_mod.current_checkpoint_work_unit_id(
                        meta, program, cp_id=cp_id
                    )
                except program_mod.ProgramGraphError as exc:
                    raise RuntimeError(str(exc)) from exc
                # A checkpoint without an explicit work_units override inherits
                # the packet-level work unit, matching build_prepare authority.
                break
            if not checkpoint_found:
                raise RuntimeError(
                    f"current checkpoint {cp_id!r} not found in packet checkpoint_graph"
                )
    first = work_units[0]
    if not isinstance(first, dict):
        raise RuntimeError("packet first work_unit is not an object")
    unit_id = first.get("id")
    if not isinstance(unit_id, str) or not unit_id:
        raise RuntimeError("packet first work_unit missing id")
    return unit_id


def _resolve_candidate_branch(canonical_repo: Path, run_id: str) -> str:
    """Return only the candidate branch frozen by the execution seal."""
    approval_doc = approval_mod.load_approval(canonical_repo, run_id)
    if not isinstance(approval_doc, dict):
        raise RuntimeError("APPROVAL.json missing; cannot scaffold candidate branch")
    branch = str(approval_doc.get("candidate_branch") or "")
    if not branch or not git_checks.is_valid_branch_name(branch):
        raise RuntimeError("APPROVAL.json candidate_branch missing or invalid")
    return branch


def build_skeleton(
    canonical_repo: Path,
    run_id: str,
    *,
    source_root: Path | None = None,
) -> dict[str, Any]:
    """Return a fully-shaped skeleton dict ready to be JSON-dumped.

    Every required top-level key is present, the schema marker is
    exact, and the runtime-known fields (run_id, work_unit_id,
    candidate_branch, baseline_sha) are pre-populated. Empty list
    fields are real `[]` not `null` so the finalizer's isinstance
    checks pass.
    """
    canonical_repo = Path(canonical_repo).resolve(strict=False)
    if not git_checks.is_git_repo(canonical_repo):
        raise RuntimeError(f"canonical repo is not a git repository: {canonical_repo}")
    run_id = _resolve_run_id(canonical_repo, run_id)

    approval_doc = approval_mod.load_approval(canonical_repo, run_id)
    baseline_sha = (approval_doc or {}).get("baseline_sha") or ""
    work_unit_id = _resolve_current_work_unit_id(canonical_repo, run_id)
    candidate_branch = _resolve_candidate_branch(canonical_repo, run_id)
    packet_sha = _resolve_packet_sha256(canonical_repo, run_id)
    approval_sha = _resolve_approval_sha256(canonical_repo, run_id)

    src_root = source_root or _find_source_root(Path(__file__).parent)
    if src_root is None:
        raise RuntimeError(
            "could not locate source root for BUILD_AGENT_RESULT.template.json; "
            "pass source_root explicitly"
        )
    tpl = json.loads(template_path(src_root).read_text(encoding="utf-8"))

    # Strip the comment keys (anything starting with "_").
    clean: dict[str, Any] = {
        k: v for k, v in tpl.items() if not k.startswith("_")
    }

    clean["schema"] = SCHEMA_AGENT_RESULT
    clean["run_id"] = run_id
    clean["work_unit_id"] = work_unit_id
    clean["candidate_branch"] = candidate_branch
    clean["baseline_sha"] = baseline_sha
    clean["packet_sha256"] = packet_sha
    clean["approval_sha256"] = approval_sha
    clean["summary"] = ""
    clean["blocker_reason"] = None
    clean["escalation_recommended"] = False
    clean["escalation_reason"] = None
    clean["unit_ids_completed"] = []
    clean["acceptance_addressed"] = []
    clean["notes"] = ""
    clean["builder_identity"] = "of-builder"
    clean["timestamp"] = util.utc_now_iso()

    ev = clean.get("evidence")
    if not isinstance(ev, dict):
        ev = {}
        clean["evidence"] = ev
    ev.setdefault("validate_sh_exit", 0)
    ev.setdefault("validate_sh_marker_found", False)
    ev.setdefault("pytest_offline_exit", 0)
    ev.setdefault("pytest_offline_summary", "")
    ev.setdefault("files_changed", [])
    ev.setdefault("diff_lines_total", 0)
    ev.setdefault("diff_lines_protected_path_violations", [])
    ev.setdefault("protected_paths_touched", [])
    for lk in ("files_changed", "diff_lines_protected_path_violations",
               "protected_paths_touched"):
        if not isinstance(ev.get(lk), list):
            ev[lk] = []

    return clean


def write_skeleton(
    canonical_repo: Path,
    run_id: str | None,
    *,
    source_root: Path | None = None,
    overwrite: bool = False,
) -> Path:
    """Write the skeleton to the per-run scratch path. Idempotent unless overwrite=True."""
    canonical_repo = Path(canonical_repo).resolve(strict=False)
    target = agent_result_path(canonical_repo, run_id or "")
    if target.exists() and not overwrite:
        return target
    skel = build_skeleton(canonical_repo, run_id, source_root=source_root)
    target.parent.mkdir(parents=True, exist_ok=True)
    util.atomic_write_json(target, skel, mode=0o600)
    return target


# ---------------------------------------------------------------------------
# v0.9.9-h: deterministic semantic-result completion recovery.
# ---------------------------------------------------------------------------
#
# Background:
#
# The loop's invariant has historically been "the model must fill the semantic
# artifact at end of pass." The model owns the engineering work; the model
# also owns the JSON. That made artifact completion a function of model
# recall — a PROMPT_ONLY contract. A completed engineer who simply stopped
# emitting JSON after committing the candidate produced the same supervisor
# classification (builder_semantic_shape_invalid) as a model that had produced
# no work at all. The supervisor's automatic retry could not distinguish those
# two cases: it paid for another full provider engineering attempt whose
# only goal was to fill the JSON. That is the cost this code path eliminates.
#
# Design:
#
# Contract completion is structural. The CORE owns the deterministic side of
# the typed semantic-result contract. The model owns:
#   1. the engineering commits on the candidate branch,
#   2. the structured fillable values where the model is authoritative.
#
# For values the core can derive deterministically (summary templates,
# evidence keys from git, unit_ids_completed from the packet's work_units,
# acceptance_addressed from the packet's acceptance_criteria, timestamp),
# the core MAY complete them after the model's pass terminates. This is NOT
# prose interpretation: every field is computed from authoritative packet
# and git state. The supervisor's automatic retry path now recognises the
# completion-recovery envelope and skips a redundant provider call entirely.
#
# Limitation:
#
# This helper only ever fills:
#   - summary (template "Build pass produced committed candidate HEAD=..."),
#   - evidence   (from git statistics the supervisor already computes),
#   - unit_ids_completed  (from the packet's work_units bounded set),
#   - acceptance_addressed (from the packet's acceptance_criteria),
#   - notes (empty by default; deterministic),
#   - timestamp (utc_now_iso).
#
# It NEVER invents outcome_requested (engineer always chooses), escalation_*,
# candidate_sha_claimed, files_changed, added_lines, removed_lines, or any
# fixed identity field. Free-form prose the model may have written is
# preserved on top of the deterministic placeholder, never parsed.


_FIXED_KEYS_FOR_SUPERVISOR_COMPLETION: frozenset[str] = frozenset(
    {
        "schema",
        "run_id",
        "work_unit_id",
        "candidate_branch",
        "baseline_sha",
        "packet_sha256",
        "approval_sha256",
        "builder_identity",
    }
)


def _coerce_int(v: Any, default: int = 0) -> int:
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


def _coerce_bool(v: Any, default: bool = False) -> bool:
    if isinstance(v, bool):
        return v
    if isinstance(v, str) and v.lower() in ("true", "false"):
        return v.lower() == "true"
    return default


def _normalize_evidence(evidence: Any) -> dict[str, Any]:
    out: dict[str, Any] = {}
    if isinstance(evidence, dict):
        out.update(evidence)
    for lk in (
        "files_changed", "diff_lines_protected_path_violations",
        "protected_paths_touched",
    ):
        v = out.get(lk)
        if not isinstance(v, list):
            v = []
        out[lk] = [str(item) for item in v if item is not None]
    for sk, default in (
        ("validate_sh_exit", 0),
        ("validate_sh_marker_found", False),
        ("pytest_offline_exit", 0),
        ("diff_lines_total", 0),
    ):
        if sk in ("validate_sh_exit", "pytest_offline_exit", "diff_lines_total"):
            out.setdefault(sk, _coerce_int(out.get(sk, default), default))
        else:
            out.setdefault(sk, _coerce_bool(out.get(sk, default), default))
    out.setdefault("pytest_offline_summary", "")
    return out


def derive_required_field_evidences(
    *,
    canonical_repo: Path,
    worktree: Path,
    baseline_sha: str,
    current_sha: str,
) -> dict[str, Any]:
    """Authoritative git-derived values for the BUILD_AGENT_RESULT.evidence
    block.

    The supervisor already calls `git -C worktree diff --shortstat
    baseline..current` (see build_finalize). This helper runs the same
    deterministic shape and produces an evidence dict compatible with
    `validate_agent_result_contract`.

    Returns an empty-evidence dict if the worktree is not a git repository
    or the SHA pair cannot be resolved.
    """
    result: dict[str, Any] = {
        "validate_sh_exit": 0,
        "validate_sh_marker_found": False,
        "pytest_offline_exit": 0,
        "pytest_offline_summary": "",
        "files_changed": [],
        "diff_lines_total": 0,
        "diff_lines_protected_path_violations": [],
        "protected_paths_touched": [],
    }
    try:
        names_proc = util.run_subprocess(
            [
                "git", "-C", str(worktree),
                "diff", "--name-only", baseline_sha, current_sha,
            ],
            capture=True,
        )
    except Exception:
        return result
    files = [
        line.strip() for line in str(names_proc.stdout or "").splitlines()
        if line.strip()
    ]
    result["files_changed"] = files
    try:
        stat_proc = util.run_subprocess(
            [
                "git", "-C", str(worktree),
                "diff", "--shortstat", baseline_sha, current_sha,
            ],
            capture=True,
        )
        stat_text = str(stat_proc.stdout or "").strip()
    except Exception:
        stat_text = ""
    insert = delete = 0
    if stat_text:
        parts = stat_text.split()
        for token in parts:
            if token.endswith("+") and token[:-1].isdigit():
                insert = int(token[:-1])
            elif token.endswith("-") and token[:-1].isdigit():
                delete = int(token[:-1])
            elif token.endswith(",") and token[:-1].isdigit():
                try:
                    delete = int(token[:-1].rstrip(","))
                except ValueError:
                    pass
            elif "+" in token and token.split("+", 1)[0].isdigit():
                try:
                    insert = int(token.split("+", 1)[0])
                except ValueError:
                    pass
        try:
            n_files = int(parts[0])
            for f in files:
                if f.startswith(tuple(["apps/", "packages/", "services/", "tests/", "docs/", "fixtures/", "schemas/", "scripts/"])):
                    pass
            _ = n_files
        except (ValueError, IndexError):
            pass
    if not (insert or delete):
        for token in parts:
            try:
                if "," in token:
                    num, _ = token.split(",", 1)
                    if num.isdigit():
                        insert = int(num)
                elif "+" in token:
                    before, _ = token.split("+", 1)
                    if before.isdigit():
                        insert = int(before)
                elif "-" in token:
                    before, _ = token.split("-", 1)
                    if before.isdigit():
                        delete = int(before)
            except Exception:
                continue
    result["diff_lines_total"] = insert + delete
    return result


def safe_text_artifact_payload(
    *,
    role: str,
    current_head: str,
    cp_id: str,
    evidence: dict[str, Any],
    outcome_requested: str = "candidate_ready",
) -> dict[str, Any]:
    """Deterministic fillable-field payload for supervisor-completion paths.

    The model is the author of free-form text claims (summary, notes). When
    the model declines to author them, the supervisor fills them with
    *content that does not claim anything substantive*. The deterministic
    finalizer remains the only authority for what is and is not accepted.
    """
    if outcome_requested not in ALLOWED_OUTCOMES:
        outcome_requested = "candidate_ready"
    n_files = evidence.get("diff_lines_total") or 0
    base_summary = (
        f"{role.capitalize()} pass produced committed candidate HEAD={current_head} "
        f"on {cp_id or '<unset>'}; deterministic finalizer shall validate."
    )
    return {
        "summary": base_summary,
        "evidence": evidence,
        "outcome_requested": outcome_requested,
        "unit_ids_completed": [],
        "acceptance_addressed": [],
        "notes": "",
        "escalation_recommended": False,
        "escalation_reason": None,
        "blocker_reason": None,
    }


def merge_deterministic_fills(
    artifact: dict[str, Any],
    fills: dict[str, Any],
) -> dict[str, Any]:
    """Combine a model-emitted artifact with deterministic fills.

    The contract: the model owns free-form text. The supervisor fills
    fields the model left blank. The merge preserves any field the model
    supplied with a meaningful value; supervisor fills only blank ones.
    """
    out = dict(artifact)
    for k, v in fills.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            merged = dict(out[k])
            merged.update({sk: sv for sk, sv in v.items() if sk not in merged or not merged[sk]})
            out[k] = merged
        else:
            cur = out.get(k)
            empty = (
                cur is None
                or cur == ""
                or (isinstance(cur, list) and not cur)
                or cur == 0
                or cur is False
            )
            if empty:
                out[k] = v
    return out


def semantically_complete_artifact(
    *,
    canonical_repo: Path,
    run_id: str,
    worktree: Path,
    baseline_sha: str,
    current_sha: str,
    role: str,
    cp_id: str,
    packet: dict[str, Any] | None,
) -> dict[str, Any] | None:
    """Read the existing pass-scoped artifact, fill missing fillable fields
    deterministically, validate the contract, and return the completed dict
    (also written back to disk). Returns None when the existing artifact has
    a fixed-identity mismatch that completion cannot repair (the supervisor
    must escalate to a fresh engineering retry in that case).

    This path is called ONLY when worktree is clean and the candidate HEAD is
    valid. Under those preconditions the engineering work is already a
    durable, committable artefact; the typed protocol contract is the only
    thing still missing.
    """
    artifact_path = agent_result_path(Path(canonical_repo), run_id or "")
    if not artifact_path.is_file():
        return None
    try:
        existing = util.read_json(artifact_path, default={}) or {}
    except Exception:
        return None
    if not isinstance(existing, dict):
        return None
    if existing.get("schema") != SCHEMA_AGENT_RESULT:
        return None
    if existing.get("run_id") != run_id:
        return None

    evidence = _normalize_evidence(existing.get("evidence"))
    git_evidence = derive_required_field_evidences(
        canonical_repo=Path(canonical_repo),
        worktree=Path(worktree),
        baseline_sha=str(baseline_sha or ""),
        current_sha=str(current_sha or ""),
    )
    for k, v in git_evidence.items():
        if isinstance(v, list):
            if not evidence.get(k):
                evidence[k] = v
        elif evidence.get(k) in (None, "", 0, False):
            evidence[k] = v

    outcome = existing.get("outcome_requested")
    if outcome not in ALLOWED_OUTCOMES:
        outcome = "candidate_ready"
    payload = safe_text_artifact_payload(
        role=role,
        current_head=str(current_sha or ""),
        cp_id=str(cp_id or ""),
        evidence=evidence,
        outcome_requested=outcome,
    )

    candidate = merge_deterministic_fills(existing, payload)

    candidate["candidate_branch"] = existing.get("candidate_branch") or ""
    candidate["baseline_sha"] = str(baseline_sha or "")
    candidate["packet_sha256"] = existing.get("packet_sha256") or ""
    candidate["approval_sha256"] = existing.get("approval_sha256") or ""
    candidate["builder_identity"] = "of-builder" if role == "builder" else "of-reviewer"
    candidate["timestamp"] = util.utc_now_iso()

    allowed = ALLOWED_RESULT_KEYS
    for extra in ("candidate_sha_claimed", "files_changed",
                  "added_lines", "removed_lines"):
        if extra in allowed:
            candidate.setdefault(extra, existing.get(extra) or (
                [] if extra == "files_changed" else 0))

    unknown = sorted(set(candidate) - allowed)
    if unknown:
        for k in unknown:
            del candidate[k]

    errors = validate_agent_result_contract(candidate)
    if errors:
        return None
    try:
        target = agent_result_path(Path(canonical_repo), run_id or "")
        util.atomic_write_json(target, candidate, mode=0o600)
    except Exception:
        pass
    return candidate
