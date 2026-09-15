"""Core-owned recovery for candidate-only protected-path drift.

This module is intentionally narrow.  It never repairs an authority breach;
it only removes protected-path changes from the current candidate when the
same candidate is otherwise a descendant of a durable checkpoint-entry tree.
The discarded candidate remains an ancestor of a core-owned restore commit and
the private receipt makes the operation restart-safe and auditable.
"""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
from pathlib import Path
from typing import Any

from . import approval, git_checks, packet as packet_mod, program, state, util


SCHEMA = "ownframework-loop-protected-drift-recovery/v1"


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


def _anchor_sha(repo: Path, run_id: str, packet: dict[str, Any], current: dict[str, Any], cp_id: str) -> str:
    ps = current.get("program") or {}
    candidate = program.checkpoint_entry_candidate_sha(
        packet=packet, program_state=ps, cp_id=cp_id, events=_events(repo, run_id)
    )
    if candidate:
        return candidate
    # For legacy CP-0 state the sealed approval baseline is the only valid
    # checkpoint-entry authority.
    order = (packet.get("checkpoint_graph") or {}).get("execution_order") or []
    if order and cp_id == order[0]:
        doc = approval.load_approval(repo, run_id)
        value = str((doc or {}).get("baseline_sha") or "")
        if value:
            return value
    raise ProtectedDriftRecoveryError(
        f"no durable checkpoint-entry candidate anchor for {cp_id}"
    )


def _tree_entry(repo: Path, commit: str, path: str) -> tuple[str, str] | None:
    result = _git(repo, "ls-tree", commit, "--", path)
    if result.returncode != 0:
        raise ProtectedDriftRecoveryError(
            f"cannot inspect protected path {path!r} at {commit[:12]}"
        )
    line = result.stdout.strip()
    if not line:
        return None
    fields = line.split(None, 3)
    if len(fields) < 3:
        raise ProtectedDriftRecoveryError(f"malformed tree entry for {path!r}")
    return fields[0], fields[2]


def _write_receipt(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    util.atomic_write_json(path, payload, mode=0o600)
    if util.read_private_json(path) != payload:
        raise ProtectedDriftRecoveryError("protected-drift receipt verification failed")


def _verify_receipt(receipt: dict[str, Any], expected: dict[str, Any]) -> None:
    for key, value in expected.items():
        if receipt.get(key) != value:
            raise ProtectedDriftRecoveryError(
                f"protected-drift receipt mismatch: {key}"
            )


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
        "previous_candidate_sha": str(receipt["previous_candidate_sha"]),
        "candidate_sha": str(receipt["rollback_candidate_sha"]),
        "checkpoint_entry_candidate_sha": str(receipt["checkpoint_entry_candidate_sha"]),
        "offending_paths": list(receipt["offending_paths"]),
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
    """Find a completed recovery whose state transition was interrupted.

    The Git recovery and the FSM transition are separate durable operations.
    If the process dies after the safe tree and receipt are committed but
    before the finalizer funds the repair, the next finalization must replay
    the same repair rather than treating the restored tree as a fresh success.
    """
    if current_state.get("state") != "BUILDING":
        return None
    root = state.run_dir(canonical_repo, run_id) / "protected-drift-recovery"
    if not root.is_dir():
        return None
    matches: list[dict[str, Any]] = []
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
        rollback = str(receipt.get("rollback_candidate_sha") or "")
        if not rollback:
            raise ProtectedDriftRecoveryError("completed protected-drift receipt has no rollback")
        matches.append({"path": path, "receipt": receipt, "rollback": rollback})
    if not matches:
        return None
    branch_head = git_checks.branch_head(canonical_repo, candidate_branch)
    wt = Path(builder_worktree).resolve(strict=False)
    matching = [item for item in matches if item["rollback"] == branch_head]
    if not matching:
        return None
    if len(matching) != 1:
        raise ProtectedDriftRecoveryError("multiple protected-drift recoveries match current branch")
    item = matching[0]
    if git_checks.current_head(wt) != branch_head or git_checks.dirty_status(wt) != "clean":
        raise ProtectedDriftRecoveryError(
            "completed protected-drift recovery has not restored a proven clean worktree"
        )
    return _recovery_result(item["path"], item["receipt"], already_recovered=True)


def _receipt_path(repo: Path, run_id: str, recovery_id: str) -> Path:
    return state.run_dir(repo, run_id) / "protected-drift-recovery" / f"{recovery_id}.json"


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
    """Restore only protected files from the durable checkpoint-entry tree.

    The caller must invoke this only after all identity, baseline, source
    ceiling, and hard-secret checks have passed.  This function independently
    re-proves the Git lineage and refuses if the protected paths were not
    changed by the current candidate itself.
    """
    repo = Path(canonical_repo).resolve(strict=False)
    wt = Path(builder_worktree).resolve(strict=False)
    paths = sorted({str(p) for p in offending_paths if str(p)})
    if not paths:
        raise ProtectedDriftRecoveryError("no protected paths supplied")
    anchor = _anchor_sha(repo, run_id, packet, current_state, checkpoint_id)
    recovery_id = hashlib.sha256(
        ("\0".join((run_id, checkpoint_id, candidate_sha, anchor, *paths))).encode()
    ).hexdigest()[:32]
    receipt_path = _receipt_path(repo, run_id, recovery_id)
    expected = {
        "schema": SCHEMA,
        "run_id": run_id,
        "checkpoint_id": checkpoint_id,
        "candidate_branch": candidate_branch,
        "previous_candidate_sha": candidate_sha,
        "checkpoint_entry_candidate_sha": anchor,
        "offending_paths": paths,
    }
    existing = util.read_private_json(receipt_path, default=None)
    if existing is not None:
        if not isinstance(existing, dict):
            raise ProtectedDriftRecoveryError("protected-drift receipt is malformed")
        _verify_receipt(existing, expected)
        rollback_existing = str(existing.get("rollback_candidate_sha") or "")
        branch_head_existing = git_checks.branch_head(repo, candidate_branch)
        if (
            existing.get("status") in {"prepared", "complete"}
            and rollback_existing
            and branch_head_existing == rollback_existing
        ):
            # A process death after ref publication or during worktree reset
            # is recoverable only when the worktree is still at the candidate
            # or already at the exact recovery commit.  Unknown HEADs fail
            # closed; we never overwrite contradictory evidence.
            current_existing = git_checks.current_head(wt)
            if current_existing == rollback_existing:
                if git_checks.dirty_status(wt) != "clean":
                    raise ProtectedDriftRecoveryError(
                        "protected-drift recovery worktree is dirty after restore"
                    )
            elif current_existing == candidate_sha:
                reset = _git(wt, "reset", "--hard", rollback_existing)
                if reset.returncode != 0:
                    raise ProtectedDriftRecoveryError(
                        reset.stderr.strip() or "cannot resume protected-drift worktree restore"
                    )
            else:
                raise ProtectedDriftRecoveryError(
                    "protected-drift recovery worktree has contradictory HEAD"
                )
            if git_checks.current_head(wt) != rollback_existing or git_checks.dirty_status(wt) != "clean":
                raise ProtectedDriftRecoveryError(
                    "protected-drift recovery worktree proof failed during restart"
                )
            if existing.get("status") != "complete":
                existing = _complete_receipt(receipt_path, existing)
            return _recovery_result(
                receipt_path,
                existing,
                already_recovered=True,
            )
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
            raise ProtectedDriftRecoveryError(
                f"protected path {path} was not changed by current candidate"
            )
        if diff.returncode not in (1,):
            raise ProtectedDriftRecoveryError(f"cannot compare protected path {path}")

    if existing is not None:
        if not isinstance(existing, dict):
            raise ProtectedDriftRecoveryError("protected-drift receipt is malformed")
        _verify_receipt(existing, expected)
        rollback = str(existing.get("rollback_candidate_sha") or "")
        if not rollback or not git_checks.commit_exists(repo, rollback):
            raise ProtectedDriftRecoveryError("protected-drift rollback commit is unavailable")
    else:
        fd, index_name = tempfile.mkstemp(prefix="ofloop-protected-index-", dir=str(state.run_dir(repo, run_id)))
        os.close(fd)
        try:
            env = dict(os.environ)
            env["GIT_INDEX_FILE"] = index_name
            for command in (("read-tree", candidate_sha),):
                result = _git(repo, *command, env=env)
                if result.returncode != 0:
                    raise ProtectedDriftRecoveryError(result.stderr.strip() or "cannot seed recovery index")
            for path in paths:
                entry = _tree_entry(repo, anchor, path)
                if entry is None:
                    result = _git(repo, "update-index", "--remove", "--", path, env=env)
                else:
                    mode, blob = entry
                    result = _git(
                        repo,
                        "update-index",
                        "--add",
                        "--cacheinfo",
                        f"{mode},{blob},{path}",
                        env=env,
                    )
                if result.returncode != 0:
                    raise ProtectedDriftRecoveryError(result.stderr.strip() or f"cannot restore {path}")
            tree = _git(repo, "write-tree", env=env)
            if tree.returncode != 0:
                raise ProtectedDriftRecoveryError(tree.stderr.strip() or "cannot write recovery tree")
            tree_sha = tree.stdout.strip()
        finally:
            try:
                Path(index_name).unlink()
            except FileNotFoundError:
                pass
        commit = _git(
            repo,
            "commit-tree",
            tree_sha,
            "-p",
            candidate_sha,
            env={
                **dict(os.environ),
                "GIT_AUTHOR_NAME": "OwnFramework Loop",
                "GIT_AUTHOR_EMAIL": "ownframework-loop@localhost",
                "GIT_COMMITTER_NAME": "OwnFramework Loop",
                "GIT_COMMITTER_EMAIL": "ownframework-loop@localhost",
            },
        )
        if commit.returncode != 0:
            raise ProtectedDriftRecoveryError(commit.stderr.strip() or "cannot create recovery commit")
        rollback = commit.stdout.strip()
        if not re_full_sha(rollback):
            raise ProtectedDriftRecoveryError("recovery commit SHA is invalid")
        payload = {
            **expected,
            "rollback_candidate_sha": rollback,
            "tree_sha256": util.sha256_bytes(tree_sha.encode()),
            "status": "prepared",
            "recorded_at": util.utc_now_iso(),
        }
        _write_receipt(receipt_path, payload)

    ref = f"refs/heads/{candidate_branch}"
    branch_head = git_checks.branch_head(repo, candidate_branch)
    if branch_head == candidate_sha:
        updated = _git(repo, "update-ref", ref, rollback, candidate_sha)
        if updated.returncode != 0:
            raise ProtectedDriftRecoveryError(updated.stderr.strip() or "cannot publish recovery commit")
    elif branch_head != rollback:
        raise ProtectedDriftRecoveryError("candidate branch changed unexpectedly during recovery")

    if git_checks.current_head(wt) != rollback or git_checks.dirty_status(wt) != "clean":
        reset = _git(wt, "reset", "--hard", rollback)
        if reset.returncode != 0:
            raise ProtectedDriftRecoveryError(reset.stderr.strip() or "cannot restore builder worktree")
    if git_checks.current_head(wt) != rollback or git_checks.dirty_status(wt) != "clean":
        raise ProtectedDriftRecoveryError("recovery worktree proof failed")

    final = util.read_private_json(receipt_path, default={})
    if not isinstance(final, dict):
        raise ProtectedDriftRecoveryError("protected-drift receipt disappeared")
    final = _complete_receipt(receipt_path, final)
    return _recovery_result(
        receipt_path,
        final,
        already_recovered=existing is not None and branch_head == rollback,
    )


def re_full_sha(value: str) -> bool:
    return len(value) == 40 and all(ch in "0123456789abcdef" for ch in value)
