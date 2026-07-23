"""Plugin-global persistent data — ${CLAUDE_PLUGIN_DATA} resolution.

OwnFramework Loop never writes mutable state into ${CLAUDE_PLUGIN_ROOT}.
Plugin-global data (installation receipts, release-gate receipts,
migration history, global run index, operational logs) lives under
${CLAUDE_PLUGIN_DATA}, which Claude Code owns and persists across
sessions. Repository run state stays under <repo>/.ownframework-loop/.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any


SCHEMA_INSTALL_RECEIPT = "ownframework-loop-install-receipt/v2"
SCHEMA_RELEASE_RECEIPT = "ownframework-loop-release-receipt/v1"
SCHEMA_GLOBAL_INDEX = "ownframework-loop-global-run-index/v1"
SCHEMA_MIGRATION_RECEIPT = "ownframework-loop-migration-receipt/v1"


def plugin_data_root() -> Path | None:
    """Return ${CLAUDE_PLUGIN_DATA} if Claude Code provided it.

    Returns None when the environment variable is unset (skills-dir
    or other contexts). Callers must handle None explicitly.
    """
    pd = os.environ.get("CLAUDE_PLUGIN_DATA")
    if not pd:
        return None
    return Path(pd).expanduser().resolve(strict=False)


def ensure_subdir(name: str) -> Path | None:
    """Ensure <plugin-data>/<name> exists. Returns the path or None if
    ${CLAUDE_PLUGIN_DATA} is unavailable."""
    root = plugin_data_root()
    if root is None:
        return None
    sub = root / name
    sub.mkdir(parents=True, exist_ok=True)
    return sub


def installation_dir() -> Path | None:
    return ensure_subdir("installation")


def receipts_dir() -> Path | None:
    return ensure_subdir("receipts")


def indexes_dir() -> Path | None:
    return ensure_subdir("indexes")


def logs_dir() -> Path | None:
    return ensure_subdir("logs")


def migration_dir() -> Path | None:
    return ensure_subdir("migration")


def write_receipt(subdir_name: str, payload: dict[str, Any]) -> Path | None:
    """Atomically write a JSON receipt into <plugin-data>/<subdir>.

    Filename: <subdir>-<UTC compact timestamp>.json. Returns the path
    or None if ${CLAUDE_PLUGIN_DATA} is unavailable.
    """
    import json
    import time
    from .util import atomic_write_json, utc_now_compact
    sub = ensure_subdir(subdir_name)
    if sub is None:
        return None
    ts = utc_now_compact()
    name_map = {"installation": "install", "receipts": "receipt",
                "indexes": "index", "logs": "log", "migration": "migration"}
    prefix = name_map.get(subdir_name, subdir_name)
    path = sub / f"{prefix}-{ts}.json"
    atomic_write_json(path, payload)
    return path


def write_text_log(filename: str, text: str) -> Path | None:
    """Write a text log into <plugin-data>/logs/."""
    logs = logs_dir()
    if logs is None:
        return None
    path = logs / filename
    path.write_text(text, encoding="utf-8")
    return path