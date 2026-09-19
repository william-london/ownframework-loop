"""Supervisor runtime/environment authority.

Owns commissioned service-environment loading, exact installed-runtime
generation observation, and disposable semantic runtime-cache lifecycle.
Runtime identity itself remains delegated to runtime_identity.py.
"""
from __future__ import annotations

import json
import os
import shutil
import stat
from pathlib import Path
from typing import Any

from . import runtime_env, runtime_identity
from . import supervisor_db as _db_mod

_SERVICE_ENV_FILE_VAR = "OFLOOP_SERVICE_ENV_FILE"

_SERVICE_ENV_ALLOWED_KEYS = frozenset({
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_MODEL",
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "CLAUDE_CODE_OAUTH_REFRESH_TOKEN",
    "CLAUDE_CODE_OAUTH_SCOPES",
    "CLAUDE_CONFIG_DIR",
})

def _load_service_env_file() -> list[str]:
    """Load a private commissioned-service environment without leaking values.

    The service definition carries only OFLOOP_SERVICE_ENV_FILE. The referenced
    file must be an owned regular file beneath a private directory and have no
    group/other permission bits. Unknown keys or non-string values fail closed.
    """
    raw = os.environ.get(_SERVICE_ENV_FILE_VAR, "").strip()
    if not raw:
        return []
    candidate = Path(raw).expanduser()
    if not candidate.is_absolute() or candidate.is_symlink():
        raise RuntimeError("service_env_refused: path must be an absolute non-symlink")
    try:
        path = candidate.resolve(strict=True)
        st = path.stat()
        parent_st = path.parent.stat()
    except OSError as exc:
        raise RuntimeError(
            f"service_env_refused: unreadable service env ({type(exc).__name__})"
        ) from exc
    if not stat.S_ISREG(st.st_mode):
        raise RuntimeError("service_env_refused: service env is not a regular file")
    if hasattr(os, "getuid") and st.st_uid != os.getuid():
        raise RuntimeError("service_env_refused: service env owner mismatch")
    if stat.S_IMODE(st.st_mode) & 0o077:
        raise RuntimeError("service_env_refused: service env must be mode 0600 or stricter")
    if stat.S_IMODE(parent_st.st_mode) & 0o077:
        raise RuntimeError("service_env_refused: service env directory must be mode 0700 or stricter")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(
            f"service_env_refused: invalid service env ({type(exc).__name__})"
        ) from exc
    if not isinstance(payload, dict):
        raise RuntimeError("service_env_refused: service env must be a JSON object")
    unknown = sorted(set(payload) - _SERVICE_ENV_ALLOWED_KEYS)
    if unknown:
        raise RuntimeError(
            "service_env_refused: unsupported keys=" + ",".join(unknown)
        )
    loaded: list[str] = []
    for key, value in payload.items():
        if not isinstance(value, str) or not value:
            raise RuntimeError(f"service_env_refused: {key} must be a non-empty string")
        os.environ[key] = value
        loaded.append(key)
    return sorted(loaded)

def runtime_generation() -> str:
    """Deterministic identity of the exact runtime bytes serving this process."""
    from . import __version__
    root = Path(__file__).resolve().parents[2]
    return runtime_identity.runtime_generation_for_root(root, __version__)

_current_runtime_generation = runtime_generation

def _runtime_cache_run_root(canonical_repo: Path, run_id: str) -> Path:
    """Pure path for disposable semantic runtime cache for one run."""
    return runtime_env.runtime_cache_path(canonical_repo, run_id, "builder").parent

def _cleanup_terminal_runtime_cache(
    canonical_repo: Path,
    run_id: str,
) -> dict[str, Any]:
    """Best-effort GC for non-evidence cache after durable DONE."""
    root = _runtime_cache_run_root(canonical_repo, run_id)
    existed = root.exists()
    error = ""
    if existed:
        try:
            shutil.rmtree(root)
            try:
                root.parent.rmdir()
            except OSError:
                pass
        except OSError as exc:
            error = str(exc)
    return {
        "path": str(root),
        "existed": existed,
        "removed": existed and not root.exists(),
        "error": error,
    }

def _cleanup_done_runtime_caches(db_path: Path | None = None) -> list[dict[str, Any]]:
    """Retry disposable-cache GC for durable DONE jobs at supervisor startup."""
    db = db_path or _db_mod.default_db_path()
    if not db.exists():
        return []
    with _db_mod._managed_connect_readonly(db) as conn:
        rows = conn.execute(
            "SELECT repo,run_id FROM jobs WHERE status='DONE' ORDER BY id"
        ).fetchall()
    return [
        _cleanup_terminal_runtime_cache(Path(row["repo"]), str(row["run_id"]))
        for row in rows
    ]

__all__ = [
    "_load_service_env_file",
    "runtime_generation",
    "_current_runtime_generation",
    "_runtime_cache_run_root",
    "_cleanup_terminal_runtime_cache",
    "_cleanup_done_runtime_caches",
]
