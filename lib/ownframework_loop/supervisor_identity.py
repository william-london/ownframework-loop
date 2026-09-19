"""Supervisor scheduling-identity authority.

Canonical owner of the supervisor's scheduling-identity surface
— the Git-common-dir / repository / workspace / packet-derived
keys that the durable ledger joins on.  These are persistence-
projection inputs, NOT persistence primitives: ``supervisor_db``
owns the schema and SQL, while this module owns the
"what-does-this-repo-mean-as-an-identity" derivation.

  * ``_repository_scheduling_identity`` — return Git-common-dir
    identity for a repository path.  Falls back to a path-based
    key when Git is unavailable, with a ``proven`` flag so the
    caller can fail closed.
  * ``_workspace_scheduling_identity`` — derive the candidate
    branch, workspace key, and proof status for a repository +
    run_id pair.
  * ``_packet_execution_mode`` — read the packet's
    ``execution_mode`` for one (repo, run_id), defaulting to
    ``"SINGLE"`` when the packet is missing.

What stays in ``supervisor.py``:

  * These are NOT directly imported by supervisor's
    composition facade.  They are owned here and used by
    supervisor_db (``_logical_job_row``) and supervisor
    itself (data migrations, claim preflight, scheduler
    metadata bootstrap).

Dependency direction: this module imports only stdlib +
the existing leaf modules (``git_checks``, ``approval``,
``branch_resolver``, ``state``, ``packet``).  No supervisor
imports.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from . import approval as approval_mod
from . import branch_resolver as branch_resolver_mod
from . import git_checks
from . import packet as packet_mod
from . import state as state_mod


def _repository_scheduling_identity(repo: Path) -> tuple[str, bool]:
    """Return Git-common-dir repository identity for aliases/worktrees."""
    resolved = Path(repo).expanduser().resolve(strict=False)
    common = git_checks.git_common_dir(resolved)
    if common is not None:
        return str(common), True
    if (resolved / ".git").exists():
        return f"unproven-git:{resolved}", False
    return f"path:{resolved}", resolved.exists()


def _workspace_scheduling_identity(
    repo: Path,
    run_id: str,
    *,
    repository_key: str,
    repository_proven: bool,
) -> tuple[str, str, bool]:
    """Return candidate branch, workspace key, and proof status.

    Git common-dir remains repository provenance, not a global execution mutex.
    Concurrent ownership is isolated by the run-frozen candidate branch, so
    different branches/worktrees in one repository may execute in parallel.
    """
    if not repository_proven or not repository_key:
        return "", "", False
    try:
        approval_doc = approval_mod.load_approval(repo, run_id)
        if isinstance(approval_doc, dict) and approval_doc.get("candidate_branch"):
            branch = branch_resolver_mod.resolve_candidate_branch(repo, run_id)
        else:
            packet_path = state_mod.run_dir(repo, run_id) / "WORK_PACKET.md"
            packet_meta = None
            if packet_path.exists():
                packet_meta, _ = packet_mod.parse_packet_file(packet_path)
            branch = branch_resolver_mod.resolve_candidate_branch(
                repo, run_id, packet=packet_meta
            )
    except Exception:
        return "", "", False
    if not isinstance(branch, str) or not branch.strip():
        return "", "", False
    branch = branch.strip()
    key = json.dumps(
        {"repository": repository_key, "candidate_branch": branch},
        separators=(",", ":"),
        sort_keys=True,
    )
    return branch, key, True


def _packet_execution_mode(repo: Path, run_id: str) -> str:
    packet_path = state_mod.run_dir(repo, run_id) / "WORK_PACKET.md"
    if not packet_path.exists():
        return "SINGLE"
    try:
        meta, _ = packet_mod.parse_packet_file(packet_path)
    except (OSError, ValueError):
        return "SINGLE"
    return "PROGRAM" if str(meta.get("execution_mode") or "").lower() == "program" else "SINGLE"


__all__ = [
    "_repository_scheduling_identity",
    "_workspace_scheduling_identity",
    "_packet_execution_mode",
]
