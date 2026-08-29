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
from . import git_checks, state as state_mod, util


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


def template_path(source_root: Path) -> Path:
    """Return the absolute path of the bundled agent-result template."""
    return source_root / "templates" / AGENT_RESULT_TEMPLATE_NAME


def agent_result_path(canonical_repo: Path, run_id: str) -> Path:
    """Return the current claimed build pass's semantic-result path.

    v0.4.5: semantic artifacts are pass-scoped. A replayed claim retains the
    same pass number/path for crash recovery; a fresh claim gets a fresh path,
    so CP-N can never inherit CP-(N-1)'s filled result.
    """
    state = state_mod.load(canonical_repo, run_id)
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
    rd = state_mod.run_dir(canonical_repo, "")
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
    state = state_mod.load(canonical_repo, run_id)
    packet_p = state_mod.run_dir(canonical_repo, run_id) / "WORK_PACKET.md"
    meta, _ = _safe_parse_packet(packet_p)
    work_units = meta.get("work_units") or []
    if not work_units:
        raise RuntimeError("packet has no work_units; cannot scaffold build identity")

    if state_mod.is_program_state(state):
        program = state.get("program") or {}
        current_cps = program.get("current_checkpoints") or []
        if current_cps:
            cp_id = current_cps[0]
            cps = (meta.get("checkpoint_graph") or {}).get("checkpoints") or []
            for cp in cps:
                if cp.get("id") == cp_id:
                    cp_wus = cp.get("work_units") or []
                    if cp_wus:
                        unit_id = cp_wus[0]
                        if not isinstance(unit_id, str) or not unit_id:
                            raise RuntimeError(
                                f"checkpoint {cp_id} has invalid work-unit identity"
                            )
                        return unit_id
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
