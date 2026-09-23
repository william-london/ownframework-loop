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
    _is_proven_unpublished_gated_reservation = (
        _attempts_mod._is_proven_unpublished_gated_reservation
    )
    _terminalize_proven_unpublished_gated_reservation = (
        _attempts_mod._terminalize_proven_unpublished_gated_reservation
    )

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

            if _is_proven_unpublished_gated_reservation(attempt):
                if not _terminalize_proven_unpublished_gated_reservation(
                    conn, job_id=job_id, attempt=attempt
                ):
                    conn.rollback()
                    continue
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


# Engine default transient-failure ceiling (matches
# `supervisor_db.bootstrap_schema`). When the operator explicitly
# disables the transient ceiling (max_transient_failures=0), the
# progress_stalled branch falls back to this value as an emergency
# fuse so a stalled worker can never retry forever. Reused as a
# canonical default rather than inventing a new packet field.
DEFAULT_MAX_TRANSIENT_FAILURES = 8


def _compute_transient_retry_state(
    *,
    current_transient_failures: int,
    current_transient_recovery_cycles: int,
    max_transient_failures: int,
    max_transient_recovery_cycles: int,
    emergency_ceiling: int | None = None,
) -> tuple[int, int, bool, bool, float, str]:
    """The single canonical transient-streak/circuit advancement.

    Used by ordinary transient failure AND progress_stalled so
    neither path defines a parallel copy of the streak/circuit
    semantics.

    Sequence (fail-closed against unbounded retry):

      1. Increment transient_failures by exactly one.
      2. Resolve the effective ceiling. If the operator set
         ``max_transient_failures > 0`` use it; otherwise use the
         caller-supplied ``emergency_ceiling`` (or
         ``DEFAULT_MAX_TRANSIENT_FAILURES`` as the final backstop
         when no emergency_ceiling is given). This guarantees
         finite termination for ``progress_stalled`` even when the
         operator has explicitly disabled the transient budget.
      3. Compute ``threshold_hit`` = the effective ceiling has been
         reached. Compute ``cycles_open`` = at least one circuit
         slot remains. Compute ``cycles_exhausted`` = the cycle
         budget is spent (only meaningful when
         ``max_transient_recovery_cycles > 0``).
      4. ``max_transient_recovery_cycles == 0`` preserves zero
         recovery-cycle semantics — there are ZERO recovery circuit
         openings; the funded transient streak (or the emergency
         ceiling) is the only retry authority.
      5. If threshold hit AND cycles_open AND
         ``max_transient_recovery_cycles > 0``: open circuit (cycle
         count +1, streak reset to 0, backoff = 600s).
      6. Else if threshold hit OR cycles exhausted: quarantine.
      7. Else: bounded streak backoff only.

    Returns
    -------
    ``(new_transient_failures, new_transient_recovery_cycles,
    quarantined, circuit_opened, backoff_seconds, branch_label)``.
    ``branch_label`` is one of ``"circuit_opened"`` /
    ``"quarantined"`` / ``"backoff"``.
    """
    # Resolve the effective ceiling. Three cases:
    #   1. configured ceiling > 0 → use configured ceiling
    #   2. configured ceiling <= 0 AND emergency_ceiling is
    #      provided → use emergency_ceiling
    #   3. configured ceiling <= 0 AND emergency_ceiling is None →
    #      operator explicitly disabled the transient budget; do
    #      NOT silently substitute a default — keep that
    #      historical disabled semantics. This branch is exactly
    #      what the ordinary ``transient`` path needs so its
    #      zero-ceiling backoff remains bounded-as-operator-set,
    #      NOT bounded-as-implicit-fallback.
    ceil: int | None
    configured = int(max_transient_failures or 0)
    if configured > 0:
        ceil = configured
    elif emergency_ceiling is not None:
        ceil = int(emergency_ceiling)
    else:
        ceil = None
    max_cycles = int(max_transient_recovery_cycles or 0)
    new_failures = int(current_transient_failures) + 1
    threshold_hit = (
        ceil is not None and ceil > 0 and new_failures >= ceil
    )
    cycles_open = (
        max_cycles > 0
        and int(current_transient_recovery_cycles) < max_cycles
    )
    cycles_exhausted = (
        max_cycles > 0
        and int(current_transient_recovery_cycles) >= max_cycles
    )
    if threshold_hit and cycles_open and max_cycles > 0:
        return (
            0,
            int(current_transient_recovery_cycles) + 1,
            False,
            True,
            600.0,
            "circuit_opened",
        )
    if threshold_hit or cycles_exhausted:
        return (
            new_failures,
            int(current_transient_recovery_cycles),
            True,
            False,
            0.0,
            "quarantined",
        )
    streak = new_failures
    backoff = min(300.0, float(5 * (2 ** max(0, streak - 1))))
    return (
        new_failures,
        int(current_transient_recovery_cycles),
        False,
        False,
        backoff,
        "backoff",
    )


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
    max_transient_failures = int(row["max_transient_failures"] or 0)
    max_transient_recovery_cycles = int(
        row["max_transient_recovery_cycles"] or 0
    )

    if failure_class in ("transient", "progress_stalled"):
        # Both failure classes go through the SAME canonical
        # transient-bucket helper. The only progress_stalled-specific
        # difference is the emergency ceiling for the case where
        # the operator explicitly disabled max_transient_failures
        # (= 0). For ordinary transient failures the operator's
        # exact intent is honored; for progress_stalled we fall back
        # to ``DEFAULT_MAX_TRANSIENT_FAILURES`` so a stalled worker
        # can never retry forever.
        emergency = (
            DEFAULT_MAX_TRANSIENT_FAILURES
            if failure_class == "progress_stalled"
            else None
        )
        (
            transient_failures,
            transient_recovery_cycles,
            quarantined,
            circuit_opened_flag,
            backoff,
            _branch,
        ) = _compute_transient_retry_state(
            current_transient_failures=transient_failures,
            current_transient_recovery_cycles=transient_recovery_cycles,
            max_transient_failures=max_transient_failures,
            max_transient_recovery_cycles=max_transient_recovery_cycles,
            emergency_ceiling=emergency,
        )
    elif immediate:
        # A hard non-transient refusal ends any active transient streak.
        transient_failures = 0
        quarantined = True
        streak = 1
        backoff = 0.0
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
        "quarantined": bool(quarantined),
        "circuit_opened": bool(
            (failure_class in ("transient", "progress_stalled"))
            and not quarantined
            and backoff == 600.0
            and transient_failures == 0
        ),
        "backoff_seconds": 0.0 if quarantined else backoff,
    }
