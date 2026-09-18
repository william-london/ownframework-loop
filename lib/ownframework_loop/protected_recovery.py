"""Core-owned whole-attempt recovery for protected-path drift."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
from typing import Any

from . import approval, git_checks, packet as packet_mod, program, state, util


SCHEMA = "ownframework-loop-protected-drift-recovery/v2"


class ProtectedDriftRecoveryError(RuntimeError):
    """Fail-closed refusal to discard candidate content."""


def _git(repo: Path, *args: str, env: dict[str, str] | None = None):
    return util.run_subprocess(["git", "-C", str(repo), *args], timeout=30, env=env)


def _events(repo: Path, run_id: str) -> list[dict[str, Any]]:
    path = state.events_path(repo, run_id)
    out: list[dict[str, Any]] = []
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.strip():
                value = json.loads(line)
                if isinstance(value, dict):
                    out.append(value)
    except (OSError, json.JSONDecodeError) as exc:
        raise ProtectedDriftRecoveryError(f"cannot read verified event history: {exc}") from exc
    return out


def _anchor_sha(
    repo: Path,
    run_id: str,
    packet: dict[str, Any],
    current: dict[str, Any],
    cp_id: str,
) -> str:
    ps = current.get("program") or {}
    # v0.9.1+ program-final repair has no CP-owned safe anchor; the
    # durable authority is the exact assembled candidate the immediately
    # preceding final review rejected, persisted on top-level
    # ``state.last_candidate_sha``.  Never fabricate a CP id or invent
    # a tree.
    if not cp_id and ps.get("review_scope") == program.REVIEW_SCOPE_PROGRAM_FINAL:
        anchor = program.program_final_safe_repair_anchor(
            state_doc=current, cp_id="",
        )
        if not anchor:
            raise ProtectedDriftRecoveryError(
                "no durable program-final repair anchor (last_candidate_sha "
                "missing or malformed on durable state)"
            )
        return anchor
    candidate = program.checkpoint_entry_candidate_sha(
        packet=packet, program_state=ps, cp_id=cp_id, events=_events(repo, run_id)
    )
    if candidate:
        return candidate
    order = (packet.get("checkpoint_graph") or {}).get("execution_order") or []
    if order and cp_id == order[0]:
        doc = approval.load_approval(repo, run_id)
        value = str((doc or {}).get("baseline_sha") or "")
        if value:
            return value
    raise ProtectedDriftRecoveryError(
        f"no durable checkpoint-entry candidate anchor for {cp_id}"
    )


def _commit_tree(repo: Path, commit: str) -> str:
    result = _git(repo, "rev-parse", f"{commit}^{{tree}}")
    value = result.stdout.strip()
    if result.returncode != 0 or not re_full_sha(value):
        raise ProtectedDriftRecoveryError(f"cannot prove tree for commit {commit[:12]}")
    return value


def _write_receipt(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    util.atomic_write_json(path, payload, mode=0o600)
    if util.read_private_json(path) != payload:
        raise ProtectedDriftRecoveryError("protected-drift receipt verification failed")


def _verify_receipt(receipt: dict[str, Any], expected: dict[str, Any]) -> None:
    for key, value in expected.items():
        if receipt.get(key) != value:
            raise ProtectedDriftRecoveryError(f"protected-drift receipt mismatch: {key}")


def _verify_recovery_commit(
    repo: Path,
    receipt: dict[str, Any],
    *,
    violating_candidate_sha: str,
    checkpoint_entry_candidate_sha: str,
    checkpoint_entry_tree_sha: str,
) -> str:
    recovery = str(receipt.get("recovery_commit_sha") or "")
    if not re_full_sha(recovery) or not git_checks.commit_exists(repo, recovery):
        raise ProtectedDriftRecoveryError("recovery commit is unavailable")
    if str(receipt.get("recovery_tree_sha") or "") != checkpoint_entry_tree_sha:
        raise ProtectedDriftRecoveryError("recovery receipt tree does not equal checkpoint-entry tree")
    if str(receipt.get("checkpoint_entry_tree_sha") or "") != checkpoint_entry_tree_sha:
        raise ProtectedDriftRecoveryError("checkpoint-entry tree binding changed")
    if _commit_tree(repo, recovery) != checkpoint_entry_tree_sha:
        raise ProtectedDriftRecoveryError("recovery commit tree differs from safe checkpoint-entry tree")
    parents = _git(repo, "rev-list", "--parents", "-n", "1", recovery)
    if parents.returncode != 0 or parents.stdout.strip().split()[1:] != [violating_candidate_sha]:
        raise ProtectedDriftRecoveryError("recovery commit parent is not the violating candidate")
    if _git(repo, "merge-base", "--is-ancestor", violating_candidate_sha, recovery).returncode != 0:
        raise ProtectedDriftRecoveryError("violating candidate is not an ancestor of recovery commit")
    if not git_checks.commit_exists(repo, checkpoint_entry_candidate_sha):
        raise ProtectedDriftRecoveryError("checkpoint-entry candidate commit is unavailable")
    if _commit_tree(repo, checkpoint_entry_candidate_sha) != checkpoint_entry_tree_sha:
        raise ProtectedDriftRecoveryError("checkpoint-entry candidate tree binding is invalid")
    return recovery


def _recovery_result(
    receipt_path: Path,
    receipt: dict[str, Any],
    *,
    already_recovered: bool,
) -> dict[str, Any]:
    return {
        "result": "recovered",
        "recovered": True,
        "already_recovered": already_recovered,
        "receipt_path": str(receipt_path),
        "previous_candidate_sha": str(receipt["violating_candidate_sha"]),
        "candidate_sha": str(receipt["recovery_commit_sha"]),
        "checkpoint_entry_candidate_sha": str(receipt["checkpoint_entry_candidate_sha"]),
        "checkpoint_entry_tree_sha": str(receipt["checkpoint_entry_tree_sha"]),
        "recovery_tree_sha": str(receipt["recovery_tree_sha"]),
        "offending_paths": list(receipt["offending_paths"]),
        "prior_attempt_rejected_whole": True,
    }


def _complete_receipt(receipt_path: Path, receipt: dict[str, Any]) -> dict[str, Any]:
    completed = dict(receipt)
    completed["status"] = "complete"
    completed["completed_at"] = util.utc_now_iso()
    _write_receipt(receipt_path, completed)
    return completed


def pending_completed_recovery(
    *,
    canonical_repo: Path,
    run_id: str,
    current_state: dict[str, Any],
    checkpoint_id: str,
    builder_worktree: Path,
    candidate_branch: str,
) -> dict[str, Any] | None:
    """Find a completed whole-tree recovery whose FSM transition was interrupted."""
    if current_state.get("state") != "BUILDING":
        return None
    root = state.run_dir(canonical_repo, run_id) / "protected-drift-recovery"
    if not root.is_dir():
        return None
    matches: list[tuple[Path, dict[str, Any]]] = []
    for path in sorted(root.glob("*.json")):
        receipt = util.read_private_json(path, default=None)
        if not isinstance(receipt, dict):
            raise ProtectedDriftRecoveryError("protected-drift receipt is malformed")
        if receipt.get("schema") != SCHEMA:
            raise ProtectedDriftRecoveryError("protected-drift receipt schema mismatch")
        if receipt.get("run_id") != run_id:
            raise ProtectedDriftRecoveryError("protected-drift receipt run mismatch")
        if receipt.get("checkpoint_id") != checkpoint_id:
            continue
        if receipt.get("candidate_branch") != candidate_branch:
            continue
        if receipt.get("status") != "complete":
            continue
        matches.append((path, receipt))
    if not matches:
        return None
    branch_head = git_checks.branch_head(canonical_repo, candidate_branch)
    matching = []
    for path, receipt in matches:
        _verify_recovery_commit(
            canonical_repo,
            receipt,
            violating_candidate_sha=str(receipt.get("violating_candidate_sha") or ""),
            checkpoint_entry_candidate_sha=str(receipt.get("checkpoint_entry_candidate_sha") or ""),
            checkpoint_entry_tree_sha=str(receipt.get("checkpoint_entry_tree_sha") or ""),
        )
        if str(receipt.get("recovery_commit_sha") or "") == branch_head:
            matching.append((path, receipt))
    if not matching:
        return None
    if len(matching) != 1:
        raise ProtectedDriftRecoveryError("multiple protected-drift recoveries match current branch")
    path, receipt = matching[0]
    wt = Path(builder_worktree).resolve(strict=False)
    if git_checks.current_head(wt) != branch_head or git_checks.dirty_status(wt) != "clean":
        raise ProtectedDriftRecoveryError("completed protected-drift recovery has not restored a proven clean worktree")
    if _commit_tree(canonical_repo, branch_head) != str(receipt["checkpoint_entry_tree_sha"]):
        raise ProtectedDriftRecoveryError("completed recovery worktree tree proof failed")
    return _recovery_result(path, receipt, already_recovered=True)


def _receipt_path(repo: Path, run_id: str, recovery_id: str) -> Path:
    return state.run_dir(repo, run_id) / "protected-drift-recovery" / f"{recovery_id}.json"


def _new_recovery_commit(
    repo: Path,
    *,
    tree_sha: str,
    violating_candidate_sha: str,
    recovery_id: str,
) -> str:
    """Create a deterministic recovery commit so crash retry reuses its SHA."""
    env = {
        **dict(os.environ),
        "GIT_AUTHOR_NAME": "OwnFramework Loop",
        "GIT_AUTHOR_EMAIL": "ownframework-loop@localhost",
        "GIT_COMMITTER_NAME": "OwnFramework Loop",
        "GIT_COMMITTER_EMAIL": "ownframework-loop@localhost",
        "GIT_AUTHOR_DATE": "2000-01-01T00:00:00Z",
        "GIT_COMMITTER_DATE": "2000-01-01T00:00:00Z",
    }
    result = _git(
        repo,
        "commit-tree",
        tree_sha,
        "-p",
        violating_candidate_sha,
        "-m",
        f"OwnFramework Loop whole-attempt recovery {recovery_id}",
        env=env,
    )
    if result.returncode != 0:
        raise ProtectedDriftRecoveryError(result.stderr.strip() or "cannot create recovery commit")
    recovery = result.stdout.strip()
    if not re_full_sha(recovery):
        raise ProtectedDriftRecoveryError("recovery commit SHA is invalid")
    return recovery


def recover_candidate_only_protected_drift(
    *,
    canonical_repo: Path,
    run_id: str,
    packet: dict[str, Any],
    current_state: dict[str, Any],
    checkpoint_id: str,
    builder_worktree: Path,
    candidate_branch: str,
    candidate_sha: str,
    offending_paths: list[str],
) -> dict[str, Any]:
    """Discard the entire candidate and restore the exact safe anchor tree."""
    repo = Path(canonical_repo).resolve(strict=False)
    wt = Path(builder_worktree).resolve(strict=False)
    paths = sorted({str(p) for p in offending_paths if str(p)})
    if not paths:
        raise ProtectedDriftRecoveryError("no protected paths supplied")
    anchor = _anchor_sha(repo, run_id, packet, current_state, checkpoint_id)
    recovery_tree = _commit_tree(repo, anchor)
    recovery_id = hashlib.sha256(
        ("\0".join((run_id, checkpoint_id, candidate_sha, anchor, recovery_tree, *paths))).encode()
    ).hexdigest()[:32]
    receipt_path = _receipt_path(repo, run_id, recovery_id)
    expected = {
        "schema": SCHEMA,
        "run_id": run_id,
        "checkpoint_id": checkpoint_id,
        "candidate_branch": candidate_branch,
        "violating_candidate_sha": candidate_sha,
        "checkpoint_entry_candidate_sha": anchor,
        "checkpoint_entry_tree_sha": recovery_tree,
        "offending_paths": paths,
        "recovery_identity": recovery_id,
    }

    existing = util.read_private_json(receipt_path, default=None)
    if existing is not None:
        if not isinstance(existing, dict):
            raise ProtectedDriftRecoveryError("protected-drift receipt is malformed")
        _verify_receipt(existing, expected)
        recovery = _verify_recovery_commit(
            repo,
            existing,
            violating_candidate_sha=candidate_sha,
            checkpoint_entry_candidate_sha=anchor,
            checkpoint_entry_tree_sha=recovery_tree,
        )
        branch_head = git_checks.branch_head(repo, candidate_branch)
        if existing.get("status") in {"prepared", "complete"} and branch_head == recovery:
            current_head = git_checks.current_head(wt)
            if current_head == candidate_sha:
                reset = _git(wt, "reset", "--hard", recovery)
                if reset.returncode != 0:
                    raise ProtectedDriftRecoveryError(reset.stderr.strip() or "cannot restore builder worktree")
            elif current_head != recovery:
                raise ProtectedDriftRecoveryError("protected-drift recovery worktree has contradictory HEAD")
            if git_checks.current_head(wt) != recovery or git_checks.dirty_status(wt) != "clean":
                raise ProtectedDriftRecoveryError("recovery worktree proof failed during restart")
            if _commit_tree(repo, recovery) != recovery_tree:
                raise ProtectedDriftRecoveryError("recovery tree proof failed during restart")
            if existing.get("status") != "complete":
                existing = _complete_receipt(receipt_path, existing)
            return _recovery_result(receipt_path, existing, already_recovered=True)
        if branch_head == candidate_sha:
            if git_checks.current_head(wt) != candidate_sha or git_checks.dirty_status(wt) != "clean":
                raise ProtectedDriftRecoveryError(
                    "prepared protected-drift recovery has contradictory candidate worktree"
                )
        if branch_head not in {candidate_sha, recovery}:
            raise ProtectedDriftRecoveryError("candidate branch changed unexpectedly during recovery")
    else:
        if git_checks.current_head(wt) != candidate_sha:
            raise ProtectedDriftRecoveryError("builder HEAD changed before protected-drift recovery")
        if git_checks.current_branch(wt) != candidate_branch:
            raise ProtectedDriftRecoveryError("builder branch changed before protected-drift recovery")
        if git_checks.dirty_status(wt) != "clean":
            raise ProtectedDriftRecoveryError("candidate worktree is not clean")

    if not git_checks.commit_exists(repo, anchor) or not git_checks.commit_exists(repo, candidate_sha):
        raise ProtectedDriftRecoveryError("candidate or checkpoint anchor commit is unavailable")
    approval_doc = approval.load_approval(repo, run_id)
    baseline = str((approval_doc or {}).get("baseline_sha") or "")
    if not baseline:
        raise ProtectedDriftRecoveryError("sealed baseline is unavailable")
    if _git(repo, "merge-base", "--is-ancestor", baseline, anchor).returncode != 0:
        raise ProtectedDriftRecoveryError("checkpoint anchor does not descend from sealed baseline")
    if _git(repo, "merge-base", "--is-ancestor", anchor, candidate_sha).returncode != 0:
        raise ProtectedDriftRecoveryError("candidate does not descend from checkpoint anchor")
    if _git(repo, "merge-base", "--is-ancestor", candidate_sha, candidate_branch).returncode != 0:
        raise ProtectedDriftRecoveryError("candidate branch does not contain candidate")
    for path in paths:
        if not packet_mod.is_protected_path(packet, path):
            raise ProtectedDriftRecoveryError(f"path is not packet-protected: {path}")
        diff = _git(repo, "diff", "--quiet", anchor, candidate_sha, "--", path)
        if diff.returncode == 0:
            raise ProtectedDriftRecoveryError(f"protected path {path} was not changed by current candidate")
        if diff.returncode != 1:
            raise ProtectedDriftRecoveryError(f"cannot compare protected path {path}")

    if existing is None:
        recovery = _new_recovery_commit(
            repo,
            tree_sha=recovery_tree,
            violating_candidate_sha=candidate_sha,
            recovery_id=recovery_id,
        )
        provisional = {
            **expected,
            "recovery_commit_sha": recovery,
            "recovery_tree_sha": recovery_tree,
            "status": "prepared",
            "recorded_at": util.utc_now_iso(),
        }
        _verify_recovery_commit(
            repo,
            provisional,
            violating_candidate_sha=candidate_sha,
            checkpoint_entry_candidate_sha=anchor,
            checkpoint_entry_tree_sha=recovery_tree,
        )
        _write_receipt(receipt_path, provisional)
        existing = provisional
    else:
        recovery = _verify_recovery_commit(
            repo,
            existing,
            violating_candidate_sha=candidate_sha,
            checkpoint_entry_candidate_sha=anchor,
            checkpoint_entry_tree_sha=recovery_tree,
        )

    ref = f"refs/heads/{candidate_branch}"
    branch_head = git_checks.branch_head(repo, candidate_branch)
    if branch_head == candidate_sha:
        updated = _git(repo, "update-ref", ref, recovery, candidate_sha)
        if updated.returncode != 0:
            raise ProtectedDriftRecoveryError(updated.stderr.strip() or "cannot publish recovery commit")
    elif branch_head != recovery:
        raise ProtectedDriftRecoveryError("candidate branch changed unexpectedly during recovery")

    if git_checks.current_head(wt) != recovery or git_checks.dirty_status(wt) != "clean":
        reset = _git(wt, "reset", "--hard", recovery)
        if reset.returncode != 0:
            raise ProtectedDriftRecoveryError(reset.stderr.strip() or "cannot restore builder worktree")
    if git_checks.current_head(wt) != recovery or git_checks.dirty_status(wt) != "clean":
        raise ProtectedDriftRecoveryError("recovery worktree proof failed")
    if _commit_tree(repo, recovery) != recovery_tree:
        raise ProtectedDriftRecoveryError("recovery tree differs from safe anchor")
    if _git(repo, "merge-base", "--is-ancestor", candidate_sha, recovery).returncode != 0:
        raise ProtectedDriftRecoveryError("recovery no longer preserves violating candidate ancestry")

    final = util.read_private_json(receipt_path, default=None)
    if not isinstance(final, dict):
        raise ProtectedDriftRecoveryError("protected-drift receipt disappeared")
    final = _complete_receipt(receipt_path, final)
    return _recovery_result(receipt_path, final, already_recovered=existing is not None)


def re_full_sha(value: str) -> bool:
    return len(value) == 40 and all(ch in "0123456789abcdef" for ch in value)
