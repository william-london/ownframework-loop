"""Single source of truth for the candidate branch of a Loop run.

After approval, APPROVAL.json.candidate_branch is authoritative. Before
approval, an explicit packet target may choose the candidate branch; otherwise
the deterministic default is factory/candidate/<run-id>.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from . import approval as approval_mod
from . import git_checks
from . import state as state_mod


DEFAULT_CANDIDATE_PREFIX = "factory/candidate"


def _validated(branch: str) -> str:
    if not git_checks.is_valid_branch_name(branch):
        raise ValueError(f"invalid candidate branch: {branch!r}")
    return branch


def default_candidate_branch(run_id: str) -> str:
    state_mod.validate_run_id(run_id)
    return _validated(f"{DEFAULT_CANDIDATE_PREFIX}/{run_id}")


def resolve_candidate_branch(
    canonical_repo: Path,
    run_id: str,
    *,
    packet: dict[str, Any] | None = None,
) -> str:
    """Resolve candidate branch without inventing a second source of truth.

    Priority:
      1. explicit packet target (pre-approval/spec-time caller)
      2. approval-frozen branch
      3. PROGRAM provenance
      4. legacy top-level provenance
      5. deterministic default
    """
    if packet:
        target = packet.get("target") or {}
        prefix = target.get("candidate_branch_prefix")
        if isinstance(prefix, str) and prefix.strip():
            return _validated(prefix.strip())

    approval_doc = approval_mod.load_approval(canonical_repo, run_id)
    if isinstance(approval_doc, dict) and approval_doc.get("candidate_branch"):
        return _validated(str(approval_doc["candidate_branch"]))

    state = state_mod.load(canonical_repo, run_id)
    if isinstance(state, dict):
        program = state.get("program") or {}
        if isinstance(program, dict):
            src = program.get("source_sha_provenance") or {}
            if isinstance(src, dict) and src.get("candidate_branch"):
                return _validated(str(src["candidate_branch"]))
        # Legacy pre-v0.4.5 fallback only.
        src = state.get("source_sha_provenance") or {}
        if isinstance(src, dict) and src.get("candidate_branch"):
            return _validated(str(src["candidate_branch"]))

    return default_candidate_branch(run_id)


def freeze_into_approval(
    canonical_repo: Path,
    run_id: str,
    *,
    packet: dict[str, Any] | None = None,
) -> str:
    """Compute the candidate branch to freeze into a newly-created approval."""
    return resolve_candidate_branch(canonical_repo, run_id, packet=packet)
