"""Supervisor dispatch-hold authority.

Canonical owner of the supervisor's dispatch-hold lifecycle surface:

  * Hold request validation (one bounded pre-conditions check).
  * Hold persistence primitives (``_hold_row``, ``_hold_dict``).
  * Pre-claim hold matching (``_hold_matches_before_claim``).
  * Claim-barrier classification (``_hold_decision_blocks_claim``).
  * Hold read projection (``dispatch_hold_status``).
  * Hold release mutation (``release_dispatch_hold``).
  * Hold cancel mutation (``cancel_dispatch_hold``).

The hold lifecycle is a discrete scheduling authority: an
operator or a PROGRAM progression can ARM a hold to bind a
checkpoint boundary to a job; the supervisor FSM refuses to
claim a job while a hold is ARMED or HELD; release/cancel are
the two terminal mutations.

What stays in ``supervisor.py``:
  * The hold-boundary matching engine
    (``dispatch_hold_mod.engineering_boundary_matches``) — the
    cross-domain identity check that compares a hold's recorded
    repo / branch / candidate against the live repository
    state.  That is a packet / identity helper, not a hold
    authority.
  * The ``enqueue`` and ``_take_next_job`` entry points.  These
    coordinate between enrollment, hold lifecycle, and claim;
    they belong with claims authority (``supervisor_claims``).
  * The read-model projections that consume hold state
    (``_job_dict`` reads ``_hold_dict`` for its ``dispatch_hold``
    field).  Those are projections, not hold lifecycle.

Dependency direction: this module imports from
``supervisor_db`` for the DB primitives.  The remaining
supervisor-internal helpers (``_logical_job_row``) are a
follow-up extraction step.
"""
from __future__ import annotations

import sqlite3
import time
from pathlib import Path
from typing import Any

from . import state as state_mod
from . import dispatch_hold as dispatch_hold_mod
from . import supervisor_db as _db_mod


# Hold schema constants.  Canonical owner is THIS module;
# ``supervisor.py`` re-exports for backward compatibility.
DISPATCH_HOLD_KIND = "PROGRAM_CHECKPOINT_BOUNDARY"
DISPATCH_HOLD_STATES = frozenset({"ARMED", "HELD", "RELEASED", "CANCELLED"})


def _validate_dispatch_hold_request(
    kind: str | None,
    previous_checkpoint_id: str | None,
    next_checkpoint_id: str | None,
) -> None:
    supplied = (kind, previous_checkpoint_id, next_checkpoint_id)
    if not any(value is not None for value in supplied):
        return
    if kind != DISPATCH_HOLD_KIND:
        raise ValueError(f"unsupported dispatch hold kind: {kind!r}")
    if not previous_checkpoint_id or not next_checkpoint_id:
        raise ValueError("PROGRAM_CHECKPOINT_BOUNDARY requires previous and next checkpoint ids")


def _hold_row(conn: sqlite3.Connection, job_id: int) -> sqlite3.Row | None:
    return conn.execute(
        "SELECT * FROM dispatch_holds WHERE job_id=?", (int(job_id),)
    ).fetchone()


def _hold_dict(row: sqlite3.Row | None) -> dict[str, Any] | None:
    return dict(row) if row is not None else None


def _hold_matches_before_claim(
    conn: sqlite3.Connection,
    row: sqlite3.Row,
) -> tuple[sqlite3.Row | None, str]:
    hold = _hold_row(conn, int(row["id"]))
    if hold is None or str(hold["state"]) in {"RELEASED", "CANCELLED"}:
        return hold, "NO_ACTIVE_HOLD"
    if str(hold["state"]) not in DISPATCH_HOLD_STATES:
        return hold, "invalid_hold_state"
    if str(hold["state"]) == "HELD":
        return hold, "HELD"
    matches, reason = dispatch_hold_mod.engineering_boundary_matches(
        repo=Path(str(row["repo"])), run_id=str(row["run_id"]), hold=hold
    )
    return hold, "MATCH" if matches else reason


def _hold_decision_blocks_claim(decision: str) -> bool:
    """Return whether a pre-claim hold decision is a scheduling barrier.

    This classification is shared by the authoritative claim path and its
    read-only projections.  ``MATCH`` remains special in the claim path because
    it must first perform the existing ARMED -> HELD compare-and-swap; it is
    nevertheless already a barrier for read-side schedulability truth.
    """
    return (
        decision in {
            "HELD",
            "MATCH",
            "invalid_hold_state",
            "unsupported_hold_kind",
        }
        or decision.startswith("engineering_state_unavailable")
    )


def dispatch_hold_status(
    *,
    canonical_repo: Path,
    run_id: str,
    hold_id: str | None = None,
    db_path: Path | None = None,
) -> dict[str, Any]:
    _logical_job_row = _db_mod._logical_job_row
    state_mod.validate_run_id(run_id)
    repo = str(Path(canonical_repo).resolve(strict=False))
    db = db_path or _db_mod.default_db_path()
    if not Path(db).expanduser().is_file():
        return {"schema": _db_mod.SCHEMA, "ok": False, "reason": "ledger_missing"}
    with _db_mod._managed_connect_readonly(db) as conn:
        job, lookup_reason = _logical_job_row(conn, canonical_repo, run_id)
        if job is None:
            row = None
        else:
            row = conn.execute(
                """SELECT h.*, j.status AS job_status, j.worker_pid,
                          j.worker_role, j.worker_attempt_id
                   FROM dispatch_holds h JOIN jobs j ON j.id=h.job_id
                   WHERE h.job_id=?
                     AND (? IS NULL OR h.hold_id=?)""",
                (int(job["id"]), hold_id, hold_id),
            ).fetchone()
    if row is None:
        return {
            "schema": _db_mod.SCHEMA,
            "ok": False,
            "repo": repo,
            "run_id": run_id,
            "reason": "dispatch_hold_not_found",
            "db_path": str(db),
        }
    result = dict(row)
    result.update({"schema": _db_mod.SCHEMA, "ok": True, "db_path": str(db)})
    return result


def release_dispatch_hold(
    *,
    canonical_repo: Path,
    run_id: str,
    hold_id: str,
    db_path: Path | None = None,
) -> dict[str, Any]:
    _logical_job_row = _db_mod._logical_job_row
    state_mod.validate_run_id(run_id)
    repo = str(Path(canonical_repo).resolve(strict=False))
    db = db_path or _db_mod.default_db_path()
    now = time.time()
    with _db_mod._managed_connect(db) as conn:
        job, lookup_reason = _logical_job_row(conn, canonical_repo, run_id)
        if job is None:
            return {
                "schema": _db_mod.SCHEMA, "ok": False,
                "reason": lookup_reason or "dispatch_hold_not_found",
            }
        conn.execute("BEGIN IMMEDIATE")
        row = conn.execute(
            "SELECT * FROM dispatch_holds WHERE hold_id=? AND job_id=?",
            (hold_id, int(job["id"])),
        ).fetchone()
        if row is None:
            return {"schema": _db_mod.SCHEMA, "ok": False, "reason": "dispatch_hold_not_found"}
        if row["state"] == "RELEASED":
            out = _hold_dict(row) or {}
            out.update({"schema": _db_mod.SCHEMA, "ok": True, "idempotent": True})
            return out
        if row["state"] != "HELD":
            out = _hold_dict(row) or {}
            out.update({"schema": _db_mod.SCHEMA, "ok": False, "reason": "release_requires_held"})
            return out
        cur = conn.execute(
            """UPDATE dispatch_holds
               SET state='RELEASED', released_at=?, updated_at=?
               WHERE hold_id=? AND job_id=? AND state='HELD'""",
            (now, now, hold_id, int(row["job_id"])),
        )
        if cur.rowcount != 1:
            return {"schema": _db_mod.SCHEMA, "ok": False, "reason": "release_lost_hold_race"}
        updated = conn.execute(
            "SELECT * FROM dispatch_holds WHERE hold_id=?", (hold_id,)
        ).fetchone()
    out = _hold_dict(updated) or {}
    out.update({"schema": _db_mod.SCHEMA, "ok": True, "released": True})
    return out


def cancel_dispatch_hold(
    *,
    canonical_repo: Path,
    run_id: str,
    hold_id: str,
    db_path: Path | None = None,
) -> dict[str, Any]:
    _logical_job_row = _db_mod._logical_job_row
    state_mod.validate_run_id(run_id)
    repo = str(Path(canonical_repo).resolve(strict=False))
    db = db_path or _db_mod.default_db_path()
    now = time.time()
    with _db_mod._managed_connect(db) as conn:
        job, lookup_reason = _logical_job_row(conn, canonical_repo, run_id)
        if job is None:
            return {
                "schema": _db_mod.SCHEMA, "ok": False,
                "reason": lookup_reason or "dispatch_hold_not_found",
            }
        conn.execute("BEGIN IMMEDIATE")
        row = conn.execute(
            "SELECT * FROM dispatch_holds WHERE hold_id=? AND job_id=?",
            (hold_id, int(job["id"])),
        ).fetchone()
        if row is None:
            return {"schema": _db_mod.SCHEMA, "ok": False, "reason": "dispatch_hold_not_found"}
        if row["state"] == "CANCELLED":
            out = _hold_dict(row) or {}
            out.update({"schema": _db_mod.SCHEMA, "ok": True, "idempotent": True})
            return out
        if row["state"] == "RELEASED":
            out = _hold_dict(row) or {}
            out.update({"schema": _db_mod.SCHEMA, "ok": False, "reason": "cancel_refuses_released"})
            return out
        cur = conn.execute(
            """UPDATE dispatch_holds
               SET state='CANCELLED', cancelled_at=?, updated_at=?
               WHERE hold_id=? AND job_id=? AND state IN ('ARMED','HELD')""",
            (now, now, hold_id, int(row["job_id"])),
        )
        if cur.rowcount != 1:
            return {"schema": _db_mod.SCHEMA, "ok": False, "reason": "cancel_lost_hold_race"}
        updated = conn.execute(
            "SELECT * FROM dispatch_holds WHERE hold_id=?", (hold_id,)
        ).fetchone()
    out = _hold_dict(updated) or {}
    out.update({"schema": _db_mod.SCHEMA, "ok": True, "cancelled": True})
    return out
