"""Utility functions — UTC timestamps, hashing, paths, safe subprocess."""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any


def utc_now_iso() -> str:
    """Return current UTC timestamp in ISO 8601 with 'Z' suffix."""
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def utc_now_compact() -> str:
    """Compact UTC timestamp for run-id suffixes: YYYYMMDDTHHMMSSZ."""
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())


def sha256_file(path: Path) -> str:
    """Compute SHA-256 hex digest of a file's bytes."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_bytes(data: bytes) -> str:
    """SHA-256 of a byte string."""
    return hashlib.sha256(data).hexdigest()


def sha256_text(text: str) -> str:
    """SHA-256 of a UTF-8 string."""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def short_sha(sha: str, length: int = 12) -> str:
    """Return the short form of a SHA (first N hex chars)."""
    return sha[:length]


def new_run_id() -> str:
    """Generate a run id of form run-<compact-utc>-<uuid8>."""
    short = uuid.uuid4().hex[:8]
    return f"run-{utc_now_compact()}-{short}"


def run_dir(canonical_repo: Path, run_id: str) -> Path:
    """Return the per-run state directory path."""
    return canonical_repo / ".ownframework-loop" / run_id


def worktrees_dir(canonical_repo: Path) -> Path:
    """Return the per-run worktree parent directory."""
    return canonical_repo / ".worktrees" / "ownframework-loop"


def builder_worktree(canonical_repo: Path, run_id: str) -> Path:
    return worktrees_dir(canonical_repo) / run_id / "builder"


def reviewer_worktree(canonical_repo: Path, run_id: str) -> Path:
    return worktrees_dir(canonical_repo) / run_id / "reviewer"


def canonical_repo_root(path: Path) -> Path:
    """Resolve canonical absolute repo path. Raises if not absolute."""
    p = Path(path).expanduser().resolve(strict=False)
    if not p.is_absolute():
        raise ValueError(f"path must be absolute: {path}")
    return p


def ensure_mode(path: Path, mode: int) -> None:
    """Restrict the mode of a file or directory (best-effort)."""
    try:
        os.chmod(path, mode)
    except OSError:
        pass


def atomic_write_json(path: Path, payload: Any, mode: int = 0o600) -> None:
    """Write JSON to a temp file, fsync, then atomic rename.

    Also attempts a directory fsync after the rename (best-effort). If
    directory fsync is not supported by the filesystem, the failure is
    swallowed and the function still returns success — the file write
    itself was atomic, so a subsequent read of `path` will see the new
    contents or the old contents, never a half-written file.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.parent / f".{path.name}.tmp.{os.getpid()}"
    data = json.dumps(payload, indent=2, sort_keys=True)
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(data)
        f.flush()
        try:
            os.fsync(f.fileno())
        except OSError:
            pass
    os.replace(tmp, path)
    ensure_mode(path, mode)
    try:
        fsync_dir(path.parent)
    except OSError:
        pass


def fsync_dir(dirpath: Path) -> None:
    """Best-effort directory fsync.

    A directory's entries must be fsynced to durably persist a rename.
    macOS exposes this via `os.fsync` on the directory fd; on some
    Linux filesystems without dir-fsync support, the call raises
    EINVAL/ENOTSUP, which we treat as best-effort and ignore.
    """
    fd = os.open(str(dirpath), os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def read_json(path: Path, default: Any = None) -> Any:
    """Read JSON, returning default on missing or parse error."""
    if not path.exists():
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return default


def read_text(path: Path, default: str = "") -> str:
    """Read text, returning default on missing."""
    if not path.exists():
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except OSError:
        return default


def run_subprocess(
    cmd: list[str],
    cwd: Path | None = None,
    timeout: float | None = None,
    check: bool = False,
) -> subprocess.CompletedProcess:
    """Run a subprocess with explicit args, no shell."""
    result = subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    if check and result.returncode != 0:
        raise RuntimeError(
            f"command failed: {' '.join(cmd)}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return result


def safe_str(obj: Any) -> str:
    """Coerce arbitrary value to a string safely."""
    if obj is None:
        return ""
    if isinstance(obj, str):
        return obj
    try:
        return str(obj)
    except Exception:
        return repr(obj)


def normalize_path(p: str) -> str:
    """Normalize a path: expand ~, resolve, ensure absolute."""
    return str(Path(p).expanduser().resolve(strict=False))


def is_within(child: Path, parent: Path) -> bool:
    """Return True if child is inside parent (after resolution)."""
    try:
        child_r = child.resolve(strict=False)
        parent_r = parent.resolve(strict=False)
        return parent_r == child_r or parent_r in child_r.parents
    except OSError:
        return False


def stderr(msg: str) -> None:
    """Write a message to stderr."""
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()
