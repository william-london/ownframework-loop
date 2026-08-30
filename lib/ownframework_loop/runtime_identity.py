"""Deterministic runtime-generation identity from actual executable payload bytes.

A runtime generation is an operational compatibility fence for sealed runs.
Clean Git checkouts use immutable HEAD identity. Dirty Git checkouts and
installed/non-Git payloads use byte-derived identities that are independent of
absolute install path.
"""
from __future__ import annotations

import hashlib
import os
import stat
import subprocess
from pathlib import Path

IGNORED_DIR_NAMES = {".git", "logs", ".ownframework-loop", "__pycache__"}
IGNORED_FILE_NAMES = {".payload.manifest", ".payload.manifest.tmp"}
IGNORED_FILE_SUFFIXES = (".pyc", ".pyo", ".pyd")


class RuntimeIdentityError(RuntimeError):
    """Raised when runtime bytes cannot be identified deterministically."""


def _hash_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _hash_path_entry(path: Path) -> bytes:
    st = path.lstat()
    mode = stat.S_IMODE(st.st_mode)
    if stat.S_ISLNK(st.st_mode):
        payload = os.readlink(path).encode("utf-8", errors="surrogateescape")
        kind = b"L"
        content = hashlib.sha256(payload).hexdigest()
    elif stat.S_ISREG(st.st_mode):
        kind = b"F"
        content = _hash_file(path)
    else:
        raise RuntimeIdentityError(f"unsupported payload entry type: {path}")
    return kind + b":" + oct(mode).encode("ascii") + b":" + content.encode("ascii")


def _iter_payload_files(root: Path) -> list[Path]:
    out: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = sorted(d for d in dirnames if d not in IGNORED_DIR_NAMES)
        base = Path(dirpath)
        for name in sorted(filenames):
            if name in IGNORED_FILE_NAMES or name.endswith(IGNORED_FILE_SUFFIXES):
                continue
            out.append(base / name)
    return sorted(out, key=lambda p: p.relative_to(root).as_posix())


def payload_tree_digest(root: Path) -> str:
    """Hash active payload bytes independent of the absolute install path."""
    root = Path(root).expanduser().resolve(strict=False)
    if not root.is_dir():
        raise RuntimeIdentityError(f"runtime root missing: {root}")
    h = hashlib.sha256()
    files = _iter_payload_files(root)
    if not files:
        raise RuntimeIdentityError(f"runtime root has no active payload files: {root}")
    for path in files:
        rel = path.relative_to(root).as_posix().encode("utf-8", errors="surrogateescape")
        h.update(rel)
        h.update(b"\0")
        h.update(_hash_path_entry(path))
        h.update(b"\0")
    return h.hexdigest()


def _git(root: Path, *args: str, text: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", "-C", str(root), *args],
        capture_output=True,
        text=text,
        check=False,
        timeout=10,
    )


def _git_head(root: Path) -> str:
    try:
        r = _git(root, "rev-parse", "HEAD")
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return r.stdout.strip() if r.returncode == 0 else ""


def _dirty_git_digest(root: Path, head: str) -> str:
    """Hash HEAD plus working-tree delta and non-ignored untracked bytes."""
    try:
        diff = _git(root, "diff", "--binary", "HEAD", "--", text=False)
        untracked = _git(root, "ls-files", "--others", "--exclude-standard", "-z", text=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeIdentityError("git worktree identity probe failed") from exc
    if diff.returncode != 0 or untracked.returncode != 0:
        raise RuntimeIdentityError("git worktree identity probe returned non-zero")
    h = hashlib.sha256()
    h.update(head.encode("ascii", errors="ignore"))
    h.update(b"\0")
    h.update(diff.stdout)
    h.update(b"\0")
    names = [n for n in untracked.stdout.split(b"\0") if n]
    for raw in sorted(names):
        rel = raw.decode("utf-8", errors="surrogateescape")
        path = root / rel
        h.update(raw)
        h.update(b"\0")
        if path.exists() or path.is_symlink():
            h.update(_hash_path_entry(path))
        else:
            h.update(b"MISSING")
        h.update(b"\0")
    return h.hexdigest()


def runtime_generation_for_root(root: Path, version: str) -> str:
    """Return a deterministic generation label for exactly the serving bytes."""
    root = Path(root).expanduser().resolve(strict=False)
    head = _git_head(root)
    if head:
        try:
            status_probe = _git(root, "status", "--porcelain=v1", "--untracked-files=all")
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise RuntimeIdentityError("git status identity probe failed") from exc
        if status_probe.returncode != 0:
            raise RuntimeIdentityError("git status identity probe returned non-zero")
        if not status_probe.stdout.strip():
            return f"ofloop-{version}@{head[:16]}"
        return f"ofloop-{version}@dirty-{_dirty_git_digest(root, head)[:24]}"
    return f"ofloop-{version}@payload-{payload_tree_digest(root)[:24]}"


__all__ = ["RuntimeIdentityError", "payload_tree_digest", "runtime_generation_for_root"]
