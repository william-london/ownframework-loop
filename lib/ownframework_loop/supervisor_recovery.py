"""Supervisor recovery — stale-RUNNING ownership recovery authority.

Canonical body owner of the supervisor's stale-running
recovery sweep.  The implementations live here; supervisor.py
exposes thin delegating wrappers for backward compatibility.

This module owns:

  * ``_recover_stale_running`` — the bounded sweep that
    quarantines stale RUNNING enrollments whose owning
    runtime generation no longer matches the live supervisor
    (the runtime-recovery lane).
  * ``_recovery_ownership_matches`` — predicate: does one
    row's owning generation still match the live supervisor's
    snapshot?  Used by the recovery sweep and by tests.

  * ``_RECOVERY_OWNERSHIP_FIELDS`` — the canonical set of job
    columns that prove ownership of an in-flight RUNNING
    enrollment.  Mutations only commit when every field
    matches the observed snapshot exactly.

What stays in ``supervisor.py``:

  * The composition facade (``serve``, ``run_one``, ``enqueue``,
    ``resume``, ``retire``).
  * Process-ownership helpers (``_pid_alive``,
    ``_terminate_owned_process_group``,
    ``_read_pid_start_identity``, ``_local_execution_owned``)
    that recovery calls.  These are worker-lifecycle /
    process-introspection helpers that the runner and the
    execute-side own; recovery CONSUMES them but does not
    relocate them.  They will move with the runner-execution
    owner when the runner class extraction lands.

Dependency direction: this module imports from supervisor_db
for the connection primitives, from supervisor_accounting
for cost/token/model observation, and from supervisor via
lazy function-scope imports for the process-ownership
helpers (``_local_execution_owned``, ``_pid_alive``,
``_terminate_owned_process_group``, ``_account_attempt_cost``).
"""
from __future__ import annotations

import os
import sqlite3
import time
from typing import Any

from . import supervisor_db as _db_mod
from . import supervisor_accounting as _accounting_mod


# Job columns that prove ownership of an in-flight RUNNING
# enrollment.  Mutations only commit when every field matches
# the observed snapshot exactly.  The snapshot is read once
# without holding a write lock; the comparison happens after
# BEGIN IMMEDIATE so a concurrent recovery or legitimate
# reclaim turns this stale decision into a no-op instead of
# clobbering the newer RUNNING owner.

_RECOVERY_OWNERSHIP_FIELDS = (
    "worker_pid",
    "worker_started_at",
    "worker_pgid",
    "worker_deadline_at",
    "worker_start_identity",
    "worker_role",
    "worker_attempt_id",
)


def _recover_stale_running(conn: sqlite3.Connection) -> int:
    """Recover stale RUNNING ownership with an exact ownership CAS.

    Process/filesystem evidence is observed without holding SQLite write
    ownership. Before mutating attempt/job state, recovery acquires
    BEGIN IMMEDIATE and re-proves the exact worker/attempt ownership snapshot.
    A concurrent recovery or legitimate reclaim therefore turns this stale
    decision into a no-op instead of clobbering the newer RUNNING owner.
    """
    from . import supervisor as _supervisor_mod
    _local_execution_owned = _supervisor_mod._local_execution_owned
    _pid_alive = _supervisor_mod._pid_alive
    _terminate_owned_process_group = _supervisor_mod._terminate_owned_process_group
    _recovery_ownership_matches = _supervisor_mod._recovery_ownership_matches
    # The accounting parsers are reached through the supervisor
    # facade (NOT directly from supervisor_accounting) so that
    # tests can monkey-patch ``supervisor._parse_*`` to inject
    # deterministic parsers into the recovery sweep.  The
    # facade is a thin delegate to supervisor_accounting; the
    # monkey-patch attaches a different callable to that exact
    # attribute and the recovery code observes it.
    _parse_cost_from_durable_stdout = _supervisor_mod._parse_cost_from_durable_stdout
    _parse_token_usage_from_durable_stdout = _supervisor_mod._parse_token_usage_from_durable_stdout
    _extract_effective_model_from_durable_stdout = _supervisor_mod._extract_effective_model_from_durable_stdout
    _extract_model_usage_json_from_durable_stdout = _supervisor_mod._extract_model_usage_json_from_durable_stdout
    _account_attempt_cost = _supervisor_mod._account_attempt_cost

    recovered = 0
    rows = conn.execute(
        "SELECT * FROM jobs WHERE status='RUNNING' ORDER BY id"
    ).fetchall()
    for observed in rows:
        if conn.in_transaction:
            conn.commit()

        job_id = int(observed["id"])
        if _local_execution_owned(job_id):
            continue
        if (
            str(observed["worker_role"] or "") == "dispatching"
            and int(observed["worker_pid"] or 0) == os.getpid()
        ):
            continue

        pid = observed["worker_pid"]
        started_at = (
            float(observed["worker_started_at"])
            if observed["worker_started_at"] else None
        )
        deadline_at = (
            float(observed["worker_deadline_at"])
            if observed["worker_deadline_at"] else None
        )
        start_identity = str(observed["worker_start_identity"] or "")
        recovery_reason = "recovered stale RUNNING job after supervisor/worker exit"

        if _pid_alive(pid, started_at):
            if deadline_at is None or time.time() < deadline_at:
                continue
            pgid = int(observed["worker_pgid"]) if observed["worker_pgid"] else None
            if not _terminate_owned_process_group(
                int(pid), pgid, start_identity or None, started_at
            ):
                conn.execute("BEGIN IMMEDIATE")
                current = conn.execute(
                    "SELECT * FROM jobs WHERE id=?", (job_id,)
                ).fetchone()
                if not _recovery_ownership_matches(current, observed):
                    conn.rollback()
                    continue
                conn.execute(
                    """UPDATE jobs SET last_error=?, updated_at=?
                       WHERE id=? AND status='RUNNING'""",
                    (
                        "semantic deadline expired but exact orphan process identity "
                        "could not be proven/terminated; retaining RUNNING ownership",
                        time.time(),
                        job_id,
                    ),
                )
                conn.commit()
                continue
            recovery_reason = "semantic deadline expired; exact owned orphan terminated"

        attempt_id = str(observed["worker_attempt_id"] or "")
        observed_attempt = None
        recovered_cost = None
        recovered_usage = None
        recovered_cost_known = False
        recovered_effective_model = ""
        recovered_model_usage_json = ""
        if attempt_id:
            observed_attempt = conn.execute(
                "SELECT * FROM semantic_attempts WHERE attempt_id=? AND job_id=?",
                (attempt_id, job_id),
            ).fetchone()
            if observed_attempt is not None and not bool(
                int(observed_attempt["cost_accounted"] or 0)
            ):
                recovered_cost = _parse_cost_from_durable_stdout(
                    observed_attempt["stdout_path"]
                )
                recovered_cost_known = recovered_cost is not None
                recovered_usage = _parse_token_usage_from_durable_stdout(
                    observed_attempt["stdout_path"]
                )
                recovered_effective_model = _extract_effective_model_from_durable_stdout(
                    observed_attempt["stdout_path"]
                )
                recovered_model_usage_json = _extract_model_usage_json_from_durable_stdout(
                    observed_attempt["stdout_path"]
                )

        conn.execute("BEGIN IMMEDIATE")
        current = conn.execute(
            "SELECT * FROM jobs WHERE id=?", (job_id,)
        ).fetchone()
        if not _recovery_ownership_matches(current, observed):
            conn.rollback()
            continue

        attempt = None
        if attempt_id:
            attempt = conn.execute(
                "SELECT * FROM semantic_attempts WHERE attempt_id=? AND job_id=?",
                (attempt_id, job_id),
            ).fetchone()
            if attempt is None:
                conn.execute(
                    """UPDATE jobs SET status='QUARANTINED', last_error=?,
                       worker_pid=NULL, worker_started_at=NULL, worker_pgid=NULL,
                       worker_deadline_at=NULL, worker_start_identity=NULL,
                       worker_role=NULL, worker_attempt_id=NULL,
                       next_attempt_at=0, updated_at=?
                       WHERE id=? AND status='RUNNING'""",
                    (
                        "semantic attempt ownership missing during crash recovery",
                        time.time(),
                        job_id,
                    ),
                )
                conn.commit()
                continue

            if (
                str(attempt["status"] or "") == "RESERVED"
                and not attempt["worker_pid"]
                and int(attempt["launch_gate_version"] or 0) >= 1
            ):
                conn.execute(
                    """UPDATE semantic_attempts SET
                         status='FAILED', completed_at=?, returncode=NULL,
                         cost_usd=0, cost_accounted=1, cost_known=1,
                         input_tokens=0, output_tokens=0, cache_read_tokens=0,
                         cache_creation_tokens=0, tokens_known=1,
                         failure_class='supervisor',
                         failure_reason='worker_ownership_not_published'
                       WHERE attempt_id=? AND job_id=? AND status='RESERVED'""",
                    (time.time(), attempt_id, job_id),
                )
                recovery_reason = (
                    "recovered unpublished gated semantic reservation; "
                    "provider was never released"
                )
            elif not bool(int(attempt["cost_accounted"] or 0)):
                if (
                    recovered_cost is None
                    and float(current["max_total_cost_usd"] or 0) > 0
                ):
                    conn.execute(
                        """UPDATE semantic_attempts SET status='COST_UNKNOWN',
                           completed_at=?, cost_usd=0, cost_accounted=1,
                           cost_known=0 WHERE attempt_id=? AND job_id=?""",
                        (time.time(), attempt_id, job_id),
                    )
                    conn.execute(
                        """UPDATE jobs SET status='QUARANTINED', last_error=?,
                           worker_pid=NULL, worker_started_at=NULL, worker_pgid=NULL,
                           worker_deadline_at=NULL, worker_start_identity=NULL,
                           worker_role=NULL, worker_attempt_id=NULL,
                           next_attempt_at=0, updated_at=?
                           WHERE id=? AND status='RUNNING'""",
                        (
                            "semantic worker died and model cost could not be recovered "
                            "from durable structured output while a cost ceiling is active",
                            time.time(),
                            job_id,
                        ),
                    )
                    conn.commit()
                    continue

                effective_cost = (
                    0.0 if recovered_cost is None else float(recovered_cost)
                )
                if (
                    int(current["max_total_tokens"] or 0) > 0
                    and recovered_usage is None
                ):
                    # Mirror the live TOKENS_UNKNOWN path: account the recovered
                    # attempt exactly once inside this transaction BEFORE the
                    # quarantine. A known recovered cost must reach the durable
                    # ledger; an unknown one must record honest cost_known=0.
                    _account_attempt_cost(
                        conn,
                        job_id=job_id,
                        attempt_id=attempt_id,
                        cost_usd=effective_cost,
                        returncode=None,
                        status_value="TOKENS_UNKNOWN",
                        cost_known=recovered_cost_known,
                        tokens_known=False,
                        manage_transaction=False,
                        effective_model=recovered_effective_model,
                        model_usage_json=recovered_model_usage_json,
                    )
                    conn.execute(
                        """UPDATE jobs SET status='QUARANTINED',
                           last_error=?, last_failure_class='usage_unknown',
                           last_failure_reason=?,
                           worker_pid=NULL, worker_started_at=NULL,
                           worker_pgid=NULL, worker_deadline_at=NULL,
                           worker_start_identity=NULL, worker_role=NULL,
                           worker_attempt_id=NULL, next_attempt_at=0, updated_at=?
                           WHERE id=? AND status='RUNNING'""",
                        (
                            "semantic worker died and token usage could not be recovered "
                            "while a token ceiling is enabled",
                            "token_usage_unknown_during_crash_recovery",
                            time.time(),
                            job_id,
                        ),
                    )
                    conn.commit()
                    continue

                usage = recovered_usage or {}
                _account_attempt_cost(
                    conn,
                    job_id=job_id,
                    attempt_id=attempt_id,
                    cost_usd=effective_cost,
                    returncode=None,
                    status_value=(
                        "RECOVERED" if recovered_cost_known else "COST_UNKNOWN"
                    ),
                    cost_known=recovered_cost_known,
                    input_tokens=int(usage.get("input_tokens", 0)),
                    output_tokens=int(usage.get("output_tokens", 0)),
                    cache_read_tokens=int(usage.get("cache_read_tokens", 0)),
                    cache_creation_tokens=int(usage.get("cache_creation_tokens", 0)),
                    tokens_known=recovered_usage is not None,
                    manage_transaction=False,
                    effective_model=recovered_effective_model,
                    model_usage_json=recovered_model_usage_json,
                )

        cur = conn.execute(
            """UPDATE jobs SET
              status='QUEUED',
              worker_pid=NULL,
              worker_started_at=NULL,
              worker_pgid=NULL,
              worker_deadline_at=NULL,
              worker_start_identity=NULL,
              worker_role=NULL,
              worker_attempt_id=NULL,
              last_error=?,
              next_attempt_at=0,
              updated_at=?
            WHERE id=? AND status='RUNNING'
            """,
            (recovery_reason, time.time(), job_id),
        )
        if cur.rowcount != 1:
            conn.rollback()
            continue
        conn.commit()
        recovered += 1
    return recovered


# Internal alias (removed: the function body now references
# _supervisor_mod._recovery_ownership_matches directly via the
# lazy import; no forward reference needed).


def _recovery_ownership_matches(
    current: sqlite3.Row | None,
    observed: sqlite3.Row,
) -> bool:
    """True iff the exact RUNNING ownership snapshot is still current."""
    if current is None or str(current["status"] or "") != "RUNNING":
        return False
    return all(
        current[field] == observed[field]
        for field in _RECOVERY_OWNERSHIP_FIELDS
    )


__all__ = [
    "_RECOVERY_OWNERSHIP_FIELDS",
    "_recover_stale_running",
    "_recovery_ownership_matches",
]
