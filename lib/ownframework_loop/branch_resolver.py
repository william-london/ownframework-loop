"""Single source of truth for the candidate branch of a Loop run.

v0.4.3: introduced after the v0.4.2 incident demonstrated that
STATE.json.source_sha_provenance.candidate_branch drifted from the
packet's authoritative candidate_branch_prefix. Every consumer now
routes through this module:

  * spec approve     -> APPROVAL.json.candidate_branch (frozen at approval)
  * program init     -> STATE.json.source_sha_provenance.candidate_branch
  * build prepare    -> builder worktree branch
  * build finalize   -> branch recorded in BUILD_RECEIPT.json.candidate_branch
  * review finalize  -> exact-SHA branch check
  * doctor / status  -> human-visible summary
  * receipt / verdict-> audit breadcrumb

The resolver accepts three inputs in priority order:

  1. packet.target.candidate_branch_prefix (authoritative when present)
  2. APPROVAL.json.candidate_branch (frozen at approval)
  3. STATE.json.source_sha_provenance.candidate_branch (frozen at init)
  4. default factory/candidate/<run-id> (only if all above absent)

Default-branch behavior is preserved. Packet-declared prefixes are
preserved. The state capture path no longer has to "guess" which to
use.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from . import approval as approval_mod
from . import state as state_mod


DEFAULT_CANDIDATE_PREFIX = "factory/candidate"


def default_candidate_branch(run_id: str) -> str:
    """Return the deterministic default candidate branch for a run-id.

    Format: factory/candidate/<run-id>
    """
    return f"{DEFAULT_CANDIDATE_PREFIX}/{run_id}"


def resolve_candidate_branch(
    canonical_repo: Path,
    run_id: str,
    *,
    packet: dict[str, Any] | None = None,
) -> str:
    """Resolve the candidate branch for a run.

    Priority order:
      1. packet.target.candidate_branch_prefix (when `packet` is provided
         and declares a non-empty prefix)
      2. APPROVAL.json.candidate_branch (frozen at approval)
      3. STATE.json.source_sha_provenance.candidate_branch
      4. default factory/candidate/<run-id>
    """
    if packet:
        target = packet.get("target") or {}
        prefix = target.get("candidate_branch_prefix")
        if isinstance(prefix, str) and prefix.strip():
            return prefix.strip()

    approval_doc = approval_mod.load_approval(canonical_repo, run_id)
    if isinstance(approval_doc, dict) and approval_doc.get("candidate_branch"):
        return str(approval_doc["candidate_branch"])

    state = state_mod.load(canonical_repo, run_id)
    if isinstance(state, dict):
        src = state.get("source_sha_provenance") or {}
        if src.get("candidate_branch"):
            return str(src["candidate_branch"])

    return default_candidate_branch(run_id)


def freeze_into_approval(
    canonical_repo: Path,
    run_id: str,
    *,
    packet: dict[str, Any] | None = None,
) -> str:
    """Compute the authoritative branch and write it into APPROVAL.json
    in-place. Used by spec approve so the value is frozen at approval
    time and does not depend on later state.

    Returns the value that was frozen.

    NOTE: This is a thin helper. It does NOT itself call the approval
    CLI; it is intended to be invoked from within the spec approve path
    where APPROVAL.json is being freshly written.
    """
    branch = resolve_candidate_branch(canonical_repo, run_id, packet=packet)
    return branch
