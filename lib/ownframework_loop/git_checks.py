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


def require_current_branch(path: Path) -> str:
    """Return the current branch or raise — never fabricate a branch name.

    Replaces the historical `current_branch(wt) or factory/candidate/<run-id>`
    pattern that silently minted a never-registered branch when the worktree
    was detached or git was unavailable.
    """
    br = current_branch(path)
    if not br:
        raise RuntimeError(
            f"refusing to fabricate branch identity for {path}: no current branch "
            f"(detached HEAD or git unavailable)"
        )
    return br


def current_head(path: Path) -> str | None:
    r = run_subprocess(["git", "-C", str(path), "rev-parse", "HEAD"], timeout=10)
    if r.returncode != 0:
        return None
    return r.stdout.strip() or None


def remote_count(path: Path) -> int:
    """Number of configured Git remotes.

    FAIL-CLOSED: on probe failure, raises RuntimeError. The historical
    fallback of returning 0 on git failure was fail-open — it allowed the
    local-only remote-block check to silently pass for a hostile repo
    whose `.git/config` could not be parsed.
    """
    try:
        r = run_subprocess(["git", "-C", str(path), "remote"], timeout=10)
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError) as exc:
        raise RuntimeError(f"could not enumerate remotes: {exc}") from exc
    if r.returncode != 0:
        raise RuntimeError(
            f"git remote failed rc={r.returncode}: {r.stderr.strip()}"
        )
    return len([line for line in r.stdout.splitlines() if line.strip()])


def remotes(path: Path) -> list[str]:
    r = run_subprocess(["git", "-C", str(path), "remote", "-v"], timeout=10)
    if r.returncode != 0:
        return []
    return r.stdout.strip().splitlines()


def is_dirty(path: Path) -> bool:
    """Backwards-compatible boolean API. True iff the worktree is provably dirty.

    If git status fails (returncode != 0), returns False which historically
    was treated as "clean" — this is the fail-open bug the v0.6.1 hardening
    closed. Authoritative callers MUST use dirty_status() instead.
    """
    return dirty_status(path) == "dirty"


def dirty_status(path: Path) -> str:
    """Strict tri-state git-status probe.

    Returns one of:
      - "clean"   -> porcelain output is empty AND git-status succeeded
      - "dirty"   -> porcelain output is non-empty AND git-status succeeded
      - "unknown" -> git-status failed (returncode != 0) OR path missing

    "Cannot prove clean" is NEVER collapsed to "clean". Authoritative proof
    paths (semantic readiness, exact-SHA finalizers, worktree validators)
    must reject "unknown" rather than treat it as clean.
    """
    if not path.exists():
        return "unknown"
    r = run_subprocess(["git", "-C", str(path), "status", "--porcelain"], timeout=10)
    if r.returncode != 0:
        return "unknown"
    if not r.stdout.strip():
        return "clean"
    return "dirty"


def is_bare(path: Path) -> bool:
    """True iff `path` is a bare Git repository."""
    r = run_subprocess(["git", "-C", str(path), "rev-parse", "--is-bare-repository"], timeout=10)
    return r.returncode == 0 and r.stdout.strip().lower() == "true"


def dirty_classification(path: Path) -> dict[str, Any]:
    """Classify the dirty state of a Git working tree.

    Returns a dict with keys:
      - has_tracked_modified: bool (M in first column of porcelain)
      - has_tracked_deleted: bool  (D in first column)
      - has_staged: bool          (any first-column entry other than '?')
      - has_untracked: bool       (?? in porcelain)
      - has_ignored_present: bool (ignored files that exist on disk; surfaced
                                    only as a hint, not as a refusal reason)
      - porcelain: list[str]      (raw porcelain lines for transparency)
    """
    out: dict[str, Any] = {
        "has_tracked_modified": False,
        "has_tracked_deleted": False,
        "has_staged": False,
        "has_untracked": False,
        "has_ignored_present": False,
        "porcelain": [],
    }
    r = run_subprocess(["git", "-C", str(path), "status", "--porcelain"], timeout=10)
    if r.returncode != 0:
        return out
    lines = r.stdout.splitlines()
    out["porcelain"] = lines
    for line in lines:
        if not line.strip():
            continue
        x = line[0] if len(line) > 0 else " "
        y = line[1] if len(line) > 1 else " "
        if x == "?" and y == "?" :
            out["has_untracked"] = True
            continue
        if x == "!":
            continue
        if x != " ":
            out["has_staged"] = True
        if y == "M":
            out["has_tracked_modified"] = True
        if y == "D":
            out["has_tracked_deleted"] = True
    # Hint: do any ignored files exist? `git status --ignored --porcelain`
    # lists ignored files; we use this only as informational output.
    ri = run_subprocess(
        ["git", "-C", str(path), "status", "--ignored", "--porcelain"],
        timeout=10,
    )
    if ri.returncode == 0:
        for line in ri.stdout.splitlines():
            if line.startswith("!!"):
                out["has_ignored_present"] = True
                break
    return out


def effective_git_author(path: Path) -> tuple[str | None, str | None]:
    """Read the effective Git author identity from local repo config (no
    global config writes). Returns (name, email). Either may be None if
    not configured. Reads only the repository's local config; does not
    fall back to global config to keep installation scope strict.
    """
    rn = run_subprocess(["git", "-C", str(path), "config", "--local", "user.name"], timeout=10)
    re_ = run_subprocess(["git", "-C", str(path), "config", "--local", "user.email"], timeout=10)
    name = rn.stdout.strip() if rn.returncode == 0 else None
    email = re_.stdout.strip() if re_.returncode == 0 else None
    if not name:
        rn2 = run_subprocess(["git", "-C", str(path), "config", "user.name"], timeout=10)
        name = rn2.stdout.strip() if rn2.returncode == 0 else None
    if not email:
        re2 = run_subprocess(["git", "-C", str(path), "config", "user.email"], timeout=10)
        email = re2.stdout.strip() if re2.returncode == 0 else None
    return (name or None, email or None)


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
    """True iff `sha` resolves to a COMMIT object in the canonical repo.

    Uses `git rev-parse --verify &lt;sha&gt;^{commit}` which fails with non-zero
    exit if the object does not exist OR if it is not a commit (e.g. tree,
    blob, annotated tag). The historical `git cat-file -e` accepted any
    object type — a tree or blob with the right hex would satisfy the gate.
    """
    r = run_subprocess(
        ["git", "-C", str(path), "rev-parse", "--verify", "--quiet", f"{sha}^{{commit}}"],
        timeout=10,
    )
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
        if head != expected_baseline_sha:
            return False, f"HEAD {head} does not match expected baseline {expected_baseline_sha}"
    return True, "ok"


def check_local_only_remote_block(repo: Path, target_classification: str) -> tuple[bool, str]:
    """Refuse to create remotes on local-only repos."""
    if target_classification != "local_only":
        return True, "ok"
    rc = remote_count(repo)
    if rc > 0:
        return False, f"local-only repo has {rc} remote(s) configured"
    return True, "ok"
