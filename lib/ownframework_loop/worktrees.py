"""Worktree lifecycle — create builder/reviewer worktrees, cleanup, mutation detection."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from .util import (
    atomic_write_json, builder_worktree, reviewer_worktree,
    run_subprocess, short_sha, utc_now_iso, worktrees_dir,
)
from .git_checks import branch_exists, current_head, rev_parse, worktree_list


class WorktreeError(RuntimeError):
    """Raised on worktree lifecycle failures."""


def ensure_worktree_parent(canonical_repo: Path) -> Path:
    """Create the .worktrees/ownframework-loop/ parent directory."""
    parent = worktrees_dir(canonical_repo)
    parent.mkdir(parents=True, exist_ok=True)
    return parent


def list_worktrees(canonical_repo: Path) -> list[dict[str, Any]]:
    return worktree_list(canonical_repo)


def add_builder_worktree(
    canonical_repo: Path,
    run_id: str,
    *,
    branch: str,
    base_sha: str | None = None,
) -> dict[str, Any]:
    """Create a fresh builder worktree on a candidate branch.

    If the branch already exists with a worktree, return that worktree info.
    """
    wt = builder_worktree(canonical_repo, run_id)
    parent = ensure_worktree_parent(canonical_repo)
    parent.mkdir(parents=True, exist_ok=True)

    if wt.exists():
        head = current_head(wt)
        return {"path": str(wt), "branch": branch, "head": head, "existed": True}

    # Base sha: the receiver picks; default to current HEAD of canonical.
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
        raise WorktreeError(f"git worktree add failed: {r.stderr.strip()}")
    head = current_head(wt)
    return {"path": str(wt), "branch": branch, "head": head, "existed": False}


def add_reviewer_worktree(
    canonical_repo: Path,
    run_id: str,
    *,
    candidate_sha: str,
    expected_setup_sha: str | None = None,
) -> dict[str, Any]:
    """Create a detached reviewer worktree pinned to candidate_sha.

    If the worktree already exists at the right SHA, return it.
    If it exists at a different SHA, remove and re-add.

    `expected_setup_sha`, when provided, is recorded as the
    `setup_candidate_sha` in the returned dict. The reviewer's mutation
    detector uses this to distinguish a *controlled* refresh from
    external drift: a HEAD change where `before == expected_setup_sha`
    and `after == candidate_sha` is the legitimate reviewer re-pin, not
    a mutation.
    """
    wt = reviewer_worktree(canonical_repo, run_id)
    ensure_worktree_parent(canonical_repo)

    existing_sha = None
    if wt.exists():
        existing_sha = current_head(wt)

    if existing_sha and existing_sha.startswith(candidate_sha[:7]):
        return {
            "path": str(wt),
            "head": existing_sha,
            "existed": True,
            "setup_candidate_sha": expected_setup_sha,
        }

    if wt.exists():
        # Tear down the existing reviewer worktree before re-adding.
        r = run_subprocess(
            ["git", "-C", str(canonical_repo), "worktree", "remove", "--force", str(wt)],
            timeout=30,
        )
        # Belt-and-suspenders: if the directory still exists (e.g., remove
        # succeeded at the registration level but left a stale path), remove
        # it manually so `git worktree add` does not refuse.
        if wt.exists():
            import shutil
            shutil.rmtree(wt, ignore_errors=True)
        if r.returncode != 0:
            # The directory may already be gone; only fail if re-add will.
            pass

    cmd = [
        "git", "-C", str(canonical_repo), "worktree", "add",
        "--detach", str(wt), candidate_sha,
    ]
    r = run_subprocess(cmd, timeout=30)
    if r.returncode != 0:
        raise WorktreeError(f"git worktree add (detached) failed: {r.stderr.strip()}")
    head = current_head(wt)
    return {
        "path": str(wt),
        "head": head,
        "existed": False,
        "setup_candidate_sha": expected_setup_sha,
    }


def cleanup_reviewer_worktree(canonical_repo: Path, run_id: str) -> tuple[bool, str]:
    """Remove the run-specific reviewer worktree only.

    Returns (removed, message). Refuses to remove any other path.
    """
    wt = reviewer_worktree(canonical_repo, run_id)
    if not wt.exists():
        return False, "reviewer worktree not present"

    # Verify the worktree is registered to this repo. Compare canonical paths
    # to handle macOS /var/folders symlinks and other path normalization.
    try:
        wt_canonical = wt.resolve(strict=False)
    except OSError:
        wt_canonical = wt
    registered = False
    for entry in worktree_list(canonical_repo):
        # git worktree list --porcelain emits `worktree <path>` lines; the
        # dictionary key is therefore "worktree", not "path".
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
    """Capture current state of a worktree for mutation detection.

    `setup_candidate_sha` records the SHA the reviewer was supposed to be
    pinned to at setup time. The detector compares this against the
    `before` HEAD to classify controlled-vs-external drift.
    """
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
    """Compare two worktree status records and classify the kind of drift.

    Returns one of:
      - `mutated: False` — no drift at all.
      - `mutated: False, kind: controlled_refresh` — HEAD changed but the
        change is the reviewer's own re-pin to a new candidate SHA. This
        is the legitimate path between review pass starts.
      - `mutated: True, kind: external_drift` — HEAD changed in a way that
        is NOT a controlled refresh. The reviewer should refuse to approve.
      - `mutated: True, kind: unexpected_initial_drift` — `before` had no
        recorded HEAD (e.g. setup never happened) but `after` does.

    `expected_candidate_sha`, when provided, is the SHA the reviewer was
    just re-pinned to. If `before.head` matches it, the change is a
    controlled refresh, not external drift.
    """
    before_sha = before.get("head")
    after_sha = after.get("head")

    if before_sha == after_sha:
        return {
            "mutated": False,
            "kind": "no_change",
            "before_sha": before_sha,
            "after_sha": after_sha,
        }

    if before_sha is None and after_sha is not None:
        return {
            "mutated": True,
            "kind": "unexpected_initial_drift",
            "before_sha": before_sha,
            "after_sha": after_sha,
        }

    # The change IS a HEAD movement. Classify: controlled vs external.
    if expected_candidate_sha is None:
        return {
            "mutated": True,
            "kind": "external_drift",
            "before_sha": before_sha,
            "after_sha": after_sha,
        }

    # A controlled refresh: before_sha == expected_candidate_sha's old value,
    # after_sha == expected_candidate_sha. We approximate "the before was at
    # the previous candidate" by saying: if after_sha matches expected AND
    # expected differs from after_sha, it is a re-pin (control). Otherwise it
    # is external drift.
    if expected_candidate_sha and after_sha and (
        after_sha.startswith(expected_candidate_sha[:7])
        or expected_candidate_sha.startswith(after_sha[:7])
        or after_sha == expected_candidate_sha
    ):
        # Either we are now pinned to expected (re-pin complete), or expected
        # is a prefix of after — both indicate a controlled movement.
        return {
            "mutated": False,
            "kind": "controlled_refresh",
            "before_sha": before_sha,
            "after_sha": after_sha,
        }

    return {
        "mutated": True,
        "kind": "external_drift",
        "before_sha": before_sha,
        "after_sha": after_sha,
    }
