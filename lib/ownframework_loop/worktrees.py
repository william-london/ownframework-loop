"""Worktree lifecycle — create builder/reviewer worktrees, cleanup, mutation detection."""
from __future__ import annotations

from pathlib import Path
from typing import Any

from .locking import flock_exclusive


def is_registered_worktree(canonical_repo: Path, worktree_path: Path) -> bool:
    """True iff `worktree_path` appears in `git worktree list` for canonical_repo.

    A bare directory containing a checkout is NOT a registered worktree. This
    helper is the single source of truth for "is this path a legitimate
    Loop-owned worktree of this repository?" — every builder/reviewer path
    must consult it before any operation that assumes worktree identity.
    """
    r = run_subprocess(
        ["git", "-C", str(canonical_repo), "worktree", "list", "--porcelain"],
        timeout=10,
    )
    if r.returncode != 0:
        return False
    target = str(worktree_path.resolve(strict=False))
    for raw in r.stdout.splitlines():
        # Each entry starts with "worktree <absolute-path>"; subsequent
        # lines are key/value pairs (HEAD, branch, detached, etc.).
        if raw.startswith("worktree "):
            entry_path = raw[len("worktree "):].strip()
            if entry_path == target:
                return True
    return False
from .util import (
    atomic_write_json, builder_worktree, reviewer_worktree,
    run_subprocess, short_sha, utc_now_iso, worktrees_dir,
)
from .git_checks import branch_exists, current_branch, current_head, rev_parse, worktree_list


class WorktreeError(RuntimeError):
    """Raised on worktree lifecycle failures."""


def ensure_worktree_parent(canonical_repo: Path) -> Path:
    parent = worktrees_dir(canonical_repo)
    parent.mkdir(parents=True, exist_ok=True)
    return parent


def list_worktrees(canonical_repo: Path) -> list[dict[str, Any]]:
    return worktree_list(canonical_repo)


def _wt_lock_path(canonical_repo: Path, run_id: str, role: str) -> Path:
    parent = worktrees_dir(canonical_repo) / ".locks"
    parent.mkdir(parents=True, exist_ok=True)
    return parent / f"wt-{role}-{run_id}.lock"


def _require_builder_branch(wt: Path, expected_branch: str) -> str:
    """Return actual branch or fail closed on detached/mismatched worktree."""
    actual = current_branch(wt)
    if actual != expected_branch:
        raise WorktreeError(
            f"builder worktree branch {actual!r} != frozen candidate branch {expected_branch!r}; refusing reuse"
        )
    return actual


def add_builder_worktree(
    canonical_repo: Path,
    run_id: str,
    *,
    branch: str,
    base_sha: str | None = None,
) -> dict[str, Any]:
    """Create/reuse the exact run builder worktree on the frozen branch.

    Existing, race-created, and newly-created worktrees are all verified by
    asking Git for their actual branch. Detached HEAD is a mismatch; the core
    never substitutes the expected branch for missing Git identity.
    """
    wt = builder_worktree(canonical_repo, run_id)
    ensure_worktree_parent(canonical_repo).mkdir(parents=True, exist_ok=True)
    lock = _wt_lock_path(canonical_repo, run_id, "builder")
    with flock_exclusive(lock):
        if wt.exists():
            head = current_head(wt)
            actual_branch = _require_builder_branch(wt, branch)
            return {
                "path": str(wt), "branch": branch, "head": head,
                "actual_branch": actual_branch, "existed": True,
            }

        if base_sha is None:
            base_sha = current_head(canonical_repo)
        if base_sha is None:
            raise WorktreeError("cannot create builder worktree: canonical repo has no HEAD")

        cmd = [
            "git", "-C", str(canonical_repo), "worktree", "add",
            "-b", branch, str(wt), base_sha,
        ]
        r = run_subprocess(cmd, timeout=30)
        if r.returncode != 0:
            if wt.exists():
                head = current_head(wt)
                actual_branch = _require_builder_branch(wt, branch)
                return {
                    "path": str(wt), "branch": branch, "head": head,
                    "actual_branch": actual_branch, "existed": True,
                }
            raise WorktreeError(f"git worktree add failed: {r.stderr.strip()}")

        head = current_head(wt)
        actual_branch = _require_builder_branch(wt, branch)
        return {
            "path": str(wt), "branch": branch, "head": head,
            "actual_branch": actual_branch, "existed": False,
        }


def add_reviewer_worktree(
    canonical_repo: Path,
    run_id: str,
    *,
    candidate_sha: str,
    expected_setup_sha: str | None = None,
) -> dict[str, Any]:
    """Create a detached reviewer worktree pinned to candidate_sha.

    If the worktree already exists at the right SHA, return it. If it exists at
    a different SHA, remove and re-add. Cleanliness is enforced by the
    authoritative verdict writer, so an exact SHA can never be approved from a
    dirty reviewer filesystem.
    """
    wt = reviewer_worktree(canonical_repo, run_id)
    ensure_worktree_parent(canonical_repo)

    lock = _wt_lock_path(canonical_repo, run_id, "reviewer")
    with flock_exclusive(lock):
        existing_sha = current_head(wt) if wt.exists() else None
        if existing_sha and existing_sha == candidate_sha:
            return {
                "path": str(wt),
                "head": existing_sha,
                "existed": True,
                "setup_candidate_sha": expected_setup_sha,
            }

        if wt.exists():
            r = run_subprocess(
                ["git", "-C", str(canonical_repo), "worktree", "remove", "--force", str(wt)],
                timeout=30,
            )
            if wt.exists():
                import shutil
                shutil.rmtree(wt, ignore_errors=True)
            if r.returncode != 0 and wt.exists():
                raise WorktreeError(f"git worktree remove failed: {r.stderr.strip()}")

        cmd = [
            "git", "-C", str(canonical_repo), "worktree", "add",
            "--detach", str(wt), candidate_sha,
        ]
        r = run_subprocess(cmd, timeout=30)
        if r.returncode != 0:
            if wt.exists():
                head = current_head(wt)
                if head != candidate_sha:
                    raise WorktreeError(
                        f"race-created reviewer worktree HEAD {head!r} != candidate {candidate_sha!r}"
                    )
                return {
                    "path": str(wt), "head": head, "existed": True,
                    "setup_candidate_sha": expected_setup_sha,
                }
            raise WorktreeError(f"git worktree add (detached) failed: {r.stderr.strip()}")
        head = current_head(wt)
        if head != candidate_sha:
            raise WorktreeError(
                f"reviewer worktree HEAD {head!r} != candidate {candidate_sha!r} after setup"
            )
        return {
            "path": str(wt),
            "head": head,
            "existed": False,
            "setup_candidate_sha": expected_setup_sha,
        }


def cleanup_reviewer_worktree(canonical_repo: Path, run_id: str) -> tuple[bool, str]:
    wt = reviewer_worktree(canonical_repo, run_id)
    if not wt.exists():
        return False, "reviewer worktree not present"
    try:
        wt_canonical = wt.resolve(strict=False)
    except OSError:
        wt_canonical = wt
    registered = False
    for entry in worktree_list(canonical_repo):
        candidate = entry.get("worktree") or entry.get("path") or ""
        try:
            entry_path = Path(candidate).resolve(strict=False)
        except OSError:
            entry_path = Path(candidate)
        if entry_path == wt_canonical or entry_path == wt:
            registered = True
            break
    if not registered:
        return False, "reviewer worktree path is not a registered worktree of this repo"
    r = run_subprocess(
        ["git", "-C", str(canonical_repo), "worktree", "remove", "--force", str(wt)],
        timeout=30,
    )
    if r.returncode != 0:
        return False, f"git worktree remove failed: {r.stderr.strip()}"
    return True, f"removed reviewer worktree {wt}"


def cleanup_builder_worktree(canonical_repo: Path, run_id: str) -> tuple[bool, str]:
    wt = builder_worktree(canonical_repo, run_id)
    if not wt.exists():
        return False, "builder worktree not present"
    r = run_subprocess(
        ["git", "-C", str(canonical_repo), "worktree", "remove", "--force", str(wt)],
        timeout=30,
    )
    if r.returncode != 0:
        return False, f"git worktree remove failed: {r.stderr.strip()}"
    return True, f"removed builder worktree {wt}"


def record_worktree_status(
    canonical_repo: Path,
    run_id: str,
    *,
    role: str,
    stage: str,
    setup_candidate_sha: str | None = None,
) -> dict[str, Any]:
    if role == "reviewer":
        wt = reviewer_worktree(canonical_repo, run_id)
    elif role == "builder":
        wt = builder_worktree(canonical_repo, run_id)
    else:
        raise ValueError(f"unknown role: {role}")
    head = current_head(wt) if wt.exists() else None
    record = {
        "ts": utc_now_iso(),
        "role": role,
        "stage": stage,
        "worktree": str(wt),
        "head": head,
        "exists": wt.exists(),
    }
    if setup_candidate_sha is not None:
        record["setup_candidate_sha"] = setup_candidate_sha
    return record


def diff_tracked_mutation(
    before: dict[str, Any],
    after: dict[str, Any],
    *,
    expected_candidate_sha: str | None = None,
) -> dict[str, Any]:
    before_sha = before.get("head")
    after_sha = after.get("head")
    if before_sha == after_sha:
        return {
            "mutated": False, "kind": "no_change",
            "before_sha": before_sha, "after_sha": after_sha,
        }
    if before_sha is None and after_sha is not None:
        return {
            "mutated": True, "kind": "unexpected_initial_drift",
            "before_sha": before_sha, "after_sha": after_sha,
        }
    if expected_candidate_sha is None:
        return {
            "mutated": True, "kind": "external_drift",
            "before_sha": before_sha, "after_sha": after_sha,
        }
    if expected_candidate_sha and after_sha and after_sha == expected_candidate_sha:
        return {
            "mutated": False, "kind": "controlled_refresh",
            "before_sha": before_sha, "after_sha": after_sha,
        }
    return {
        "mutated": True, "kind": "external_drift",
        "before_sha": before_sha, "after_sha": after_sha,
    }
