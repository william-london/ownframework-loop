"""Plugin-global persistent data — ${CLAUDE_PLUGIN_DATA} resolution.

OwnFramework Loop never writes mutable state into ${CLAUDE_PLUGIN_ROOT}.

Resolution policy (in strict order):

1. If `CLAUDE_PLUGIN_DATA` is set and points at a valid directory, use
   it as-is. This is the official Claude-managed persistent data root
   Claude Code exports when a plugin is loaded.

2. Otherwise, derive the managed data root from the Claude config
   directory:

       ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/data/of-loop-ownframework-local

   The directory is created if missing. No other fallbacks are
   permitted, and in particular this plugin never falls back to
   `~/.claude/ownframework-loop-receipts`.

3. Mutable receipts, logs, indexes, migration archives, and
   installation/release receipts only ever land under the resolved
   plugin-data directory. Repository run state stays under
   `<repo>/.ownframework-loop/<run-id>/`.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any


SCHEMA_INSTALL_RECEIPT = "ownframework-loop-install-receipt/v2"
SCHEMA_RELEASE_RECEIPT = "ownframework-loop-release-receipt/v1"
SCHEMA_GLOBAL_INDEX = "ownframework-loop-global-run-index/v1"
SCHEMA_MIGRATION_RECEIPT = "ownframework-loop-migration-receipt/v1"


# The single allowed subdirectory name for this plugin's persistent data.
# Must remain stable across releases.
PLUGIN_DATA_DIR_NAME = "of-loop-ownframework-local"


def _config_dir() -> Path:
    """Resolve the Claude config directory.

    Honors `CLAUDE_CONFIG_DIR` (the official override Claude honors for
    tests and isolated sessions). Falls back to `$HOME/.claude`.

    Fails loud if neither yields a usable path.
    """
    explicit = os.environ.get("CLAUDE_CONFIG_DIR")
    if explicit:
        p = Path(explicit).expanduser()
        if not p.is_absolute():
            raise RuntimeError(
                f"CLAUDE_CONFIG_DIR must be an absolute path, got: {explicit!r}")
        return p
    home = os.environ.get("HOME")
    if not home:
        raise RuntimeError(
            "Cannot resolve Claude config dir: HOME is unset and "
            "CLAUDE_CONFIG_DIR is unset")
    return Path(home) / ".claude"


def plugin_data_root() -> Path:
    """Return the persistent data root.

    Order:
      1. `CLAUDE_PLUGIN_DATA` (when set and valid)
      2. `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/data/of-loop-ownframework-local`

    Never falls back to `~/.claude/ownframework-loop-receipts`.
    """
    explicit = os.environ.get("CLAUDE_PLUGIN_DATA")
    if explicit:
        p = Path(explicit).expanduser().resolve(strict=False)
        if not _is_safe_data_path(p):
            raise RuntimeError(
                f"Refusing to use unsafe CLAUDE_PLUGIN_DATA: {explicit!r}")
        p.mkdir(parents=True, exist_ok=True)
        return p
    cfg = _config_dir()
    root = (cfg / "plugins" / "data" / PLUGIN_DATA_DIR_NAME).resolve(strict=False)
    if not _is_safe_data_path(root):
        raise RuntimeError(
            f"Refusing to use unsafe derived plugin-data path: {root}")
    root.mkdir(parents=True, exist_ok=True)
    return root


def _is_safe_data_path(p: Path) -> bool:
    """Refuse obviously-broken or surprising data paths.

    Rejects:
      - the obsolete legacy directory `ownframework-loop-receipts`
      - a path that resolves inside the plugin cache
      - an empty / whitespace-only path
      - any path containing the legacy marker segment
    """
    parts = set(p.parts)
    if "ownframework-loop-receipts" in parts:
        return False
    if not str(p).strip():
        return False
    # Disallow writing into the plugin cache (read-only).
    if "plugins" in parts and "cache" in parts:
        return False
    return True


def ensure_subdir(name: str) -> Path:
    """Ensure <plugin-data>/<name> exists. Returns the path.

    Fails loud on unexpected subdirectory names (no implicit creation
    of arbitrary directories).
    """
    allowed = {"installation", "receipts", "indexes", "logs", "migration"}
    if name not in allowed:
        raise RuntimeError(f"Unknown plugin-data subdir: {name!r}")
    root = plugin_data_root()
    sub = root / name
    sub.mkdir(parents=True, exist_ok=True)
    return sub


def installation_dir() -> Path:
    return ensure_subdir("installation")


def receipts_dir() -> Path:
    return ensure_subdir("receipts")


def indexes_dir() -> Path:
    return ensure_subdir("indexes")


def logs_dir() -> Path:
    return ensure_subdir("logs")


def migration_dir() -> Path:
    return ensure_subdir("migration")


def write_receipt(subdir_name: str, payload: dict[str, Any]) -> Path:
    """Atomically write a JSON receipt into <plugin-data>/<subdir>.

    Filename: <subdir>-<UTC compact timestamp>.json.
    """
    import json
    from .util import atomic_write_json, utc_now_compact
    sub = ensure_subdir(subdir_name)
    ts = utc_now_compact()
    name_map = {"installation": "install", "receipts": "receipt",
                "indexes": "index", "logs": "log", "migration": "migration"}
    prefix = name_map.get(subdir_name, subdir_name)
    path = sub / f"{prefix}-{ts}.json"
    atomic_write_json(path, payload)
    return path


def write_text_log(filename: str, text: str) -> Path:
    """Write a text log into <plugin-data>/logs/."""
    logs = logs_dir()
    path = logs / filename
    path.write_text(text, encoding="utf-8")
    return path
