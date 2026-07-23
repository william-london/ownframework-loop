"""Git identity, baseline, dirty-worktree, and remote-block checks."""

from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Any

from .util import run_subprocess, stderr, normalize_path


def is_git_repo(path: Path) -> bool:
    r = run_subprocess(["git", "-C", str(path), "rev-parse", "--git-dir"], timeout=10)
    return r.returncode == 0 and r.stdout.strip() != ""


def git_toplevel(path: Path) -> Path | None:
    r = run_subprocess(["git", "-C", str(path), "rev-parse", "--show-toplevel"], timeout=10)
    if r.returncode != 0:
        return None
    return Path(r.stdout.strip())


def git_common_dir(path: Path) -> Path | None:
    r = run_subprocess(["git", "-C", str(path), "rev-parse", "--git-common-dir"], timeout=10)
    if r.returncode != 0:
        return None
    return Path(r.stdout.strip())


def current_branch(path: Path) -> str | None:
    r = run_subprocess(["git", "-C", str(path), "branch", "--show-current"], timeout=10)
    if r.returncode != 0:
        return None
    return r.stdout.strip() or None


def current_head(path: Path) -> str | None:
    r = run_subprocess(["git", "-C", str(path), "rev-parse", "HEAD"], timeout=10)
    if r.returncode != 0:
        return None
    return r.stdout.strip() or None


def remote_count(path: Path) -> int:
    r = run_subprocess(["git", "-C", str(path), "remote"], timeout=10)
    if r.returncode != 0:
        return 0
    return len([line for line in r.stdout.splitlines() if line.strip()])


def remotes(path: Path) -> list[str]:
    r = run_subprocess(["git", "-C", str(path), "remote", "-v"], timeout=10)
    if r.returncode != 0:
        return []
    return r.stdout.strip().splitlines()


def is_dirty(path: Path) -> bool:
    r = run_subprocess(["git", "-C", str(path), "status", "--porcelain"], timeout=10)
    return r.returncode == 0 and bool(r.stdout.strip())


def worktree_list(path: Path) -> list[dict[str, Any]]:
    r = run_subprocess(["git", "-C", str(path), "worktree", "list", "--porcelain"], timeout=10)
    if r.returncode != 0:
        return []
    entries: list[dict[str, Any]] = []
    cur: dict[str, Any] = {}
    for line in r.stdout.splitlines():
        if not line:
            if cur:
                entries.append(cur)
                cur = {}
            continue
        k, _, v = line.partition(" ")
        cur[k] = v
    if cur:
        entries.append(cur)
    return entries


def branch_exists(path: Path, branch: str) -> bool:
    r = run_subprocess(["git", "-C", str(path), "rev-parse", "--verify", "--quiet", f"refs/heads/{branch}"], timeout=10)
    return r.returncode == 0


def commit_exists(path: Path, sha: str) -> bool:
    r = run_subprocess(["git", "-C", str(path), "cat-file", "-e", sha], timeout=10)
    return r.returncode == 0


def rev_parse(path: Path, ref: str) -> str | None:
    r = run_subprocess(["git", "-C", str(path), "rev-parse", "--verify", ref], timeout=10)
    if r.returncode != 0:
        return None
    return r.stdout.strip() or None


def check_baseline_identity(
    repo: Path,
    *,
    expected_branch: str,
    expected_baseline_sha: str | None,
) -> tuple[bool, str]:
    """Verify repo identity matches expectations. Returns (ok, message)."""
    if not is_git_repo(repo):
        return False, "not a git repository"
    branch = current_branch(repo)
    if branch != expected_branch:
        return False, f"expected branch {expected_branch!r}, found {branch!r}"
    head = current_head(repo)
    if expected_baseline_sha:
        if head is None:
            return False, "repository has no HEAD"
        if not head.startswith(expected_baseline_sha[:7]):
            return False, f"HEAD {head[:12]} does not match expected baseline {expected_baseline_sha[:12]}"
    return True, "ok"


def check_local_only_remote_block(repo: Path, target_classification: str) -> tuple[bool, str]:
    """Refuse to create remotes on local-only repos."""
    if target_classification != "local_only":
        return True, "ok"
    rc = remote_count(repo)
    if rc > 0:
        return False, f"local-only repo has {rc} remote(s) configured"
    return True, "ok"
