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

Dependency direction: this module imports the persistence, accounting,
attempt, and process leaves directly. It never imports supervisor.py.
"""
from __future__ import annotations

import os
import sqlite3
import time
from typing import Any

from . import supervisor_db as _db_mod
from . import supervisor_accounting as _accounting_mod
from . import supervisor_attempts as _attempts_mod
from . import supervisor_process as _process_mod


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
    _local_execution_owned = _process_mod._local_execution_owned
    _pid_alive = _process_mod._pid_alive
    _terminate_owned_process_group = _process_mod._terminate_owned_process_group
    _parse_cost_from_durable_stdout = _accounting_mod.parse_cost_from_durable_stdout
    _parse_token_usage_from_durable_stdout = _accounting_mod.parse_token_usage_from_durable_stdout
    _extract_effective_model_from_durable_stdout = _accounting_mod.extract_effective_model_from_durable_stdout
    _extract_model_usage_json_from_durable_stdout = _accounting_mod.extract_model_usage_json_from_durable_stdout
    _account_attempt_cost = _attempts_mod._account_attempt_cost

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
                # v0.10.0-dev b009: instead of leaving the row in RUNNING
                # forever (the previous b009 defect — PID-reuse + start-time
                # drift would have stranded the row), force QUARANTINED
                # immediately. The identity proof failed; the operator must
                # retire the run manually if the orphan is genuine.
                conn.execute("BEGIN IMMEDIATE")
                current = conn.execute(
                    "SELECT * FROM jobs WHERE id=?", (job_id,)
                ).fetchone()
                if not _recovery_ownership_matches(current, observed):
                    conn.rollback()
                    continue
                conn.execute(
                    """UPDATE jobs SET status='QUARANTINED',
                       last_error=?, last_failure_class='orphan_identity',
                       last_failure_reason='orphan_identity_unproven',
                       worker_pid=NULL, worker_started_at=NULL,
                       worker_pgid=NULL, worker_deadline_at=NULL,
                       worker_start_identity=NULL, worker_role=NULL,
                       worker_attempt_id=NULL, next_attempt_at=0,
                       updated_at=?
                       WHERE id=? AND status='RUNNING'""",
                    (
                        "semantic deadline expired but exact orphan process identity "
                        "could not be proven/terminated; quarantined for operator action",
                        time.time(),
                        job_id,
                    ),
                )
                conn.commit()
                recovered += 1
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


def _apply_failure_policy(
    conn: sqlite3.Connection,
    *,
    job_id: int,
    failure_class: str,
    failure_reason: str,
    detail: str,
    total_cost_usd: float | None = None,
) -> dict[str, Any]:
    """Apply operational retry policy while leaving engineering state untouched."""
    row = conn.execute("SELECT * FROM jobs WHERE id=?", (int(job_id),)).fetchone()
    if row is None:
        raise RuntimeError(f"supervisor job missing during failure policy: {job_id}")

    # v1.0.0 progress-watchdog: when the no-progress watchdog already
    # marked this attempt, do not let a later dispatcher exit handler
    # overwrite the watchdog's classification. Watchdog's failure_class
    # is authoritative for that kill: we keep its failure_class /
    # failure_reason, only re-derive the operational retry policy
    # (status, counters, backoff) from the watchdog's signal.
    watchdog_already_classified = (
        str(row["last_failure_class"] or "") == "progress_stalled"
    )
    if watchdog_already_classified:
        # Reuse the watchdog's authoritative classification; the
        # dispatcher's runner-classifier output is discarded.
        failure_class = "progress_stalled"
        failure_reason = str(row["last_failure_reason"] or failure_reason)

    immediate = failure_class in {
        "configuration",
        "invariant",
        "usage_unknown",
        "timeout_usage_unknown",
        "usage_ceiling",
    }
    infra_failures = int(row["infra_failures"] or 0)
    transient_failures = int(row["transient_failures"] or 0)
    transient_recovery_cycles = int(row["transient_recovery_cycles"] or 0)

    if failure_class == "transient":
        transient_failures += 1
        ceiling = int(row["max_transient_failures"] or 0)
        max_cycles = int(row["max_transient_recovery_cycles"] or 0)
        threshold_hit = ceiling > 0 and transient_failures >= ceiling
        if threshold_hit and transient_recovery_cycles < max_cycles:
            # Open a bounded provider circuit instead of requiring an operator
            # resume. Cost/token/wall-clock ledgers are preserved and keep
            # bounding the run; only the transient streak is cooled down.
            transient_recovery_cycles += 1
            transient_failures = 0
            quarantined = False
            backoff = 600.0
        else:
            quarantined = threshold_hit
            streak = transient_failures
            backoff = min(300.0, float(5 * (2 ** max(0, streak - 1))))
    elif immediate:
        # A hard non-transient refusal ends any active transient streak.
        transient_failures = 0
        quarantined = True
        streak = 1
        backoff = 0.0
    elif failure_class == "progress_stalled":
        # Post-v1 closure: the watchdog owns detect+terminate+classify
        # for progress_stalled and incremented the dedicated
        # ``progress_stall_count`` counter. The canonical failure-policy
        # owner does NOT also increment transient_failures or
        # infra_failures — that would be a double-charge. The stall is
        # its own budget unit; quarantine for repeated stalls is
        # governed by the stall count, not by infra/transient streaks.
        # We still derive the operational backoff so a stalled attempt
        # does not hot-loop.
        quarantined = False
        streak = 1
        backoff = min(300.0, float(5 * (2 ** max(0, streak - 1))))
    else:
        infra_failures += 1
        ceiling = int(row["max_infra_failures"] or 0)
        quarantined = ceiling > 0 and infra_failures >= ceiling
        streak = infra_failures
        backoff = min(300.0, float(5 * (2 ** max(0, streak - 1))))

    status_value = "QUARANTINED" if quarantined else "BACKOFF"
    next_attempt = 0.0 if quarantined else time.time() + backoff
    _db_mod._update_job(
        conn,
        int(job_id),
        status_value=status_value,
        infra_failures=infra_failures,
        transient_failures=transient_failures,
        transient_recovery_cycles=transient_recovery_cycles,
        total_cost_usd=total_cost_usd,
        last_error=detail[-4000:],
        last_failure_class=failure_class,
        last_failure_reason=failure_reason,
        next_attempt_at=next_attempt,
    )
    return {
        "status": status_value,
        "failure_class": failure_class,
        "failure_reason": failure_reason,
        "infra_failures": infra_failures,
        "transient_failures": transient_failures,
        "transient_recovery_cycles": transient_recovery_cycles,
        "max_transient_recovery_cycles": int(row["max_transient_recovery_cycles"] or 0),
        "circuit_opened": bool(
            failure_class == "transient"
            and not quarantined
            and backoff == 600.0
            and transient_failures == 0
        ),
        "backoff_seconds": 0.0 if quarantined else backoff,
    }
