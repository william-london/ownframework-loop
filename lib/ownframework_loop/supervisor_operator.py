"""Supervisor operator-mutation authority.

Canonical owner of the supervisor's operator-facing mutation
surface.  Read-model projections live in
``supervisor_readmodel.py``; this module owns the bounded
operator mutations that are NOT a hold lifecycle and NOT a
claim lifecycle.  Examples:

  * ``supervisor_config_set`` — persist the bounded operational
    execution capacity (``max_concurrency``) inside an explicit
    transaction with row-level UPSERT semantics.

What stays in ``supervisor.py``:

  * The composition facade (``serve``, ``run_one``, ``enqueue``,
    ``resume``, ``retire``).
  * Hold lifecycle (``dispatch_hold_status``, ``release_dispatch_hold``,
    ``cancel_dispatch_hold``) — owned by ``supervisor_holds.py``.
  * Read-model projections — owned by ``supervisor_readmodel.py``.

Dependency direction: this module imports from ``supervisor_db``
for the DB primitives.  The supervisor module re-exports the
canonical symbols here for backward compatibility.
"""
from __future__ import annotations

import time
from pathlib import Path
from typing import Any

from . import supervisor_db as _db_mod


def supervisor_config_set(
    *, max_concurrency: Any, db_path: Path | None = None
) -> dict[str, Any]:
    """Persist the bounded operational execution capacity."""
    from . import supervisor as _supervisor_mod
    value = _supervisor_mod._validate_max_concurrency(max_concurrency)
    db = db_path or _db_mod.default_db_path()
    now = time.time()
    with _db_mod._managed_connect(db) as conn:
        conn.execute("BEGIN IMMEDIATE")
        conn.execute(
            """INSERT INTO supervisor_config(key, value, updated_at) VALUES (?, ?, ?)
               ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at""",
            (_db_mod._CONFIG_MAX_CONCURRENCY, str(value), now),
        )
        conn.commit()
    return {
        "schema": _db_mod.SCHEMA, "ok": True,
        "max_concurrency": value, "db_path": str(db),
    }


__all__ = ["supervisor_config_set"]
