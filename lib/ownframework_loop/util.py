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


def run_dir(canonical_repo: Path | str, run_id: str) -> Path:
    """Return the per-run state directory path."""
    return Path(canonical_repo) / ".ownframework-loop" / run_id


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


# Work-class-aware budget recommendations. These are starting ranges, not
# hard caps; the packet's exact risk_budget overrides them. Operator confirms via TTY.
# the packet's budget, so any reasonable mission-appropriate funding is
# acceptable. The blanket V1 400-line / 12-file cap is removed.
WORK_CLASS_BUDGET_RECOMMENDATIONS: dict[str, dict[str, int]] = {
    # Small: bug / doc / test / CI repair
    "BUG":            {"max_files_changed": 25, "max_diff_lines": 1000, "max_repair_rounds": 4},
    "DOCUMENTATION":  {"max_files_changed": 20, "max_diff_lines": 800,  "max_repair_rounds": 3},
    "TESTING":        {"max_files_changed": 25, "max_diff_lines": 1000, "max_repair_rounds": 4},
    "CI_REPAIR":      {"max_files_changed": 12, "max_diff_lines": 600,  "max_repair_rounds": 3},
    # Medium: feature / debug / hardening
    "FEATURE":        {"max_files_changed": 60, "max_diff_lines": 3000, "max_repair_rounds": 5},
    "DEBUG":          {"max_files_changed": 40, "max_diff_lines": 2000, "max_repair_rounds": 4},
    "HARDENING":      {"max_files_changed": 50, "max_diff_lines": 2500, "max_repair_rounds": 5},
    # Large bounded: refactor / tracked contract / new repo
    "REFACTOR":       {"max_files_changed": 150, "max_diff_lines": 8000, "max_repair_rounds": 6},
    "TRACKED_CONTRACT": {"max_files_changed": 80, "max_diff_lines": 4000, "max_repair_rounds": 5},
    "NEW_REPOSITORY": {"max_files_changed": 100, "max_diff_lines": 5000, "max_repair_rounds": 5},
    # Research / runtime
    "RESEARCH_SPIKE": {"max_files_changed": 30, "max_diff_lines": 1500, "max_repair_rounds": 3},
    "RUNTIME_CANDIDATE": {"max_files_changed": 60, "max_diff_lines": 3000, "max_repair_rounds": 5},
}

# Generous runaway ceiling — past this requires packet-level elevation.
#
# v0.3.7 (F-3-01 / F-7-01): raised max_repair_rounds from 12 to 32
# (and max_build_passes / max_review_passes from 16 to 32) so the
# repair-round budget test can drive packet values of {2, 6, 12, 25}.
# The matching limits.MAX_* emergency caps were also raised to 32.
# Schema max in work-packet.schema.json follows.
ABSOLUTE_BUDGET_CEILING: dict[str, int] = {
    "max_files_changed": 500,
    "max_diff_lines": 30000,
    "max_repair_rounds": 32,
    "max_build_passes": 32,
    "max_review_passes": 32,
    "max_consecutive_no_progress_passes": 8,
}


def recommended_budget_adjustment(work_class: str) -> dict[str, int]:
    """Return the recommended budget values for a work class.

    These are defaults; the spec skill may use them to propose a packet
    budget, and the packet-approved budget always wins.
    """
    return dict(WORK_CLASS_BUDGET_RECOMMENDATIONS.get(work_class, {
        "max_files_changed": 25,
        "max_diff_lines": 1000,
        "max_repair_rounds": 4,
    }))


def budget_within_ceiling(budget: dict[str, int]) -> tuple[bool, list[str]]:
    """Return (ok, list_of_violations). Refuses unbounded fields."""
    violations: list[str] = []
    for k, ceiling in ABSOLUTE_BUDGET_CEILING.items():
        v = budget.get(k)
        if v is None:
            continue
        if int(v) > ceiling:
            violations.append(f"{k}={v} exceeds absolute ceiling {ceiling}")
    for required in ("max_files_changed", "max_diff_lines", "max_repair_rounds"):
        if not isinstance(budget.get(required), int) or int(budget.get(required)) < 1:
            violations.append(f"{required} must be a positive integer")
    return (not violations), violations

