"""Supervisor claims — claim / enrollment / submission-budget authority.

Canonical body owner of the supervisor's claim lifecycle:

  * ``enqueue`` — durable enrollment of one job into the
    supervisor ledger (the public entry point used by every
    ``ofloop supervisor enqueue`` call).  Enrollment is bound
    to the same hold lifecycle as claim, so enrollment and
    claim are kept together in one cohesive scheduling
    lifecycle authority.
  * ``_take_next_job`` — claim-time dispatcher: returns the
    next eligible candidate after running the stale-running
    recovery sweep and the pre-claim hold match.
  * ``_scheduler_submission_budget`` — bounded check that
    the live scheduler is still inside its permitted claim
    budget for this loop tick.

Enrollment is bundled with claim because the two share the
hold lifecycle: ``enqueue`` can ARM a dispatch_hold (via
``supervisor_holds``) that ``_take_next_job`` later matches
before allowing the worker to claim.  Splitting enrollment
into a separate module would force the two modules to
coordinate on every enqueue/claim cycle; keeping them
together preserves the single cohesive authority over the
scheduling lifecycle.

What stays in ``supervisor.py``:

  * The composition facade (``serve``, ``run_one``, ``resume``,
    ``retire``).
  * Process / PID introspection helpers (``_pid_alive``,
    ``_terminate_owned_process_group``,
    ``_local_execution_owned``).
  * The ClaudeCodeRunner class + its ``run`` method (still
    pending extraction to ``supervisor_runner.py``).

Dependency direction:

  supervisor_claims -> supervisor_db (write primitives)
  supervisor_claims -> supervisor_holds (hold lifecycle)
  supervisor_claims -> supervisor_recovery (recovery sweep)
  supervisor_claims -> supervisor_readmodel (job projection)
  supervisor_claims -> supervisor_identity (scheduling keys)
  supervisor_claims -> supervisor_runner_registry + supervisor_runtime
"""
from __future__ import annotations

import os
import sqlite3
import time
import uuid
from pathlib import Path
from typing import Any

from . import packet as packet_mod
from . import state as state_mod
from . import supervisor_db as _db_mod
from . import supervisor_holds as _holds_mod
from . import supervisor_recovery as _recovery_mod
from . import supervisor_readmodel as _readmodel_mod
from . import supervisor_identity as _identity_mod
from . import supervisor_runner_registry as _runner_registry_mod
from . import supervisor_runtime as _runtime_mod




def enqueue(
    *,
    canonical_repo: Path,
    run_id: str,
    runner: str = "claude-code",
    db_path: Path | None = None,
    max_infra_failures: int | None = None,
    max_transient_failures: int | None = None,
    max_transient_recovery_cycles: int | None = None,
    max_total_cost_usd: float | None = None,
    max_total_tokens: int | None = None,
    max_wall_seconds: int | None = None,
    runtime_generation: str | None = None,
    dispatch_hold_kind: str | None = None,
    dispatch_hold_previous_checkpoint_id: str | None = None,
    dispatch_hold_next_checkpoint_id: str | None = None,
) -> dict[str, Any]:
    """Create or refresh one enqueued run's operational envelope.

    Runtime-generation binding: every enqueue binds the job to the runtime
    generation performing the enqueue (``runtime_generation()`` unless an
    explicit value is supplied). A re-enqueue is an explicit operator
    re-registration, so it rebinds to the enqueuing generation. Execution
    later refuses to run a job bound to a different generation (see
    ``run_one``); only re-enqueue or ``resume`` migrates a run.

    Envelope values use ``None`` as the "unspecified" sentinel:

      * NEW job row: unspecified fields take the engine defaults
        (failure ceilings 3/8/2; budget ceilings OFF = 0).
      * EXISTING job row: unspecified fields PRESERVE the configured
        values. A repeated enqueue must never widen or remove an already
        configured operational ceiling merely because the caller omitted
        it — default sentinels are not operator intent. Only an explicit
        value (including an explicit <= 0, which disables that ceiling)
        overwrites the configured envelope.

    Budget ceilings are OFF unless deliberately funded: a value <= 0 disables
    that ceiling. Long PROGRAMs must not hit accidental global stop lines;
    protection against stuck execution comes from semantic pass fuses,
    no-progress detection, pass/repair caps, and failure-class retry policy.
    The CLI resolves packet-declared envelopes (risk_budget.max_runtime_seconds
    -> wall clock) before calling this; explicit operator flags win.
    """
    _current_runtime_generation = _runtime_mod.runtime_generation
    _repository_scheduling_identity = _identity_mod._repository_scheduling_identity
    _workspace_scheduling_identity = _identity_mod._workspace_scheduling_identity
    _packet_execution_mode = _identity_mod._packet_execution_mode
    registered_runner_ids = _runner_registry_mod.registered_runner_ids
    state_mod.validate_run_id(run_id)
    db = db_path or _db_mod.default_db_path()
    live_runners = registered_runner_ids()
    if runner not in live_runners:
        return {
            "schema": _db_mod.SCHEMA,
            "ok": False,
            "db_path": str(db),
            "repo": str(Path(canonical_repo).resolve(strict=False)),
            "run_id": run_id,
            "enqueue_refused": True,
            "reason": "runner_not_registered",
            "runner": runner,
            "live_runners": list(live_runners),
        }
    _holds_mod._validate_dispatch_hold_request(
        dispatch_hold_kind,
        dispatch_hold_previous_checkpoint_id,
        dispatch_hold_next_checkpoint_id,
    )
    repo = str(Path(canonical_repo).resolve(strict=False))
    scheduling_key, identity_proven = _repository_scheduling_identity(Path(repo))
    candidate_branch, workspace_key, workspace_proven = _workspace_scheduling_identity(
        Path(repo), run_id, repository_key=scheduling_key,
        repository_proven=identity_proven,
    )
    execution_mode = _packet_execution_mode(Path(repo), run_id)
    if not identity_proven or not workspace_proven:
        return {
            "schema": _db_mod.SCHEMA,
            "ok": False,
            "db_path": str(db),
            "repo": repo,
            "run_id": run_id,
            "enqueue_refused": True,
            "reason": (
                "repository_identity_unproven"
                if not identity_proven
                else "workspace_identity_unproven"
            ),
            "candidate_branch": candidate_branch or None,
        }
    now = time.time()
    eff_generation = (
        runtime_generation if runtime_generation is not None
        else _current_runtime_generation()
    )
    # Idempotent enqueue: create a new QUEUED row, or update only safe
    # configuration on an existing row. Authorization and mutation share one
    # SQLite write transaction so a concurrent run_one() cannot claim the row
    # between the status/generation check and this upsert.
    with _db_mod._managed_connect(db) as conn:
        conn.execute("BEGIN IMMEDIATE")
        logical_existing = conn.execute(
            """SELECT * FROM jobs
                 WHERE repository_scheduling_key=? AND run_id=? AND repo!=?
                 ORDER BY id LIMIT 1""",
            (scheduling_key, run_id, repo),
        ).fetchone()
        if logical_existing is not None:
            out = dict(logical_existing)
            out.update({
                "schema": _db_mod.SCHEMA,
                "ok": False,
                "db_path": str(db),
                "enqueue_refused": True,
                "reason": "logical_run_already_enrolled_via_other_worktree",
                "requested_repo": repo,
            })
            return out

        branch_existing = conn.execute(
            """SELECT * FROM jobs
                 WHERE repository_scheduling_key=? AND candidate_branch=?
                   AND run_id!=?
                   AND status IN ('QUEUED','BACKOFF','RUNNING','QUARANTINED')
                 ORDER BY id LIMIT 1""",
            (scheduling_key, candidate_branch, run_id),
        ).fetchone()
        if branch_existing is not None:
            out = dict(branch_existing)
            out.update({
                "schema": _db_mod.SCHEMA,
                "ok": False,
                "db_path": str(db),
                "enqueue_refused": True,
                "reason": "candidate_branch_already_enrolled",
                "requested_repo": repo,
                "requested_run_id": run_id,
                "candidate_branch": candidate_branch,
            })
            return out

        # Pre-enqueue admission backstop: refuse durable admission of a
        # never-started run whose current pre-seal packet is not
        # deterministically executable enough to enter durable scheduling.
        # The trusted spec adapter is supposed to validate its own packet
        # before enqueueing (per the spec workflow), but if the adapter skips
        # or mishandles that step, the deterministic supervisor must still
        # fail closed BEFORE the run becomes durable.
        #
        # Three refusal branches, in this order:
        #   A. WORK_PACKET.md is absent              → pre_seal_packet_missing
        #   B. WORK_PACKET.md exists but parse fails → pre_seal_packet_invalid
        #   C. packet parses but does not validate   → pre_seal_packet_invalid
        #                                                 (with packet_errors)
        #
        # Valid packets (D) fall through to the existing durable enrollment
        # path unchanged. Refusal in any branch produces no job row, no
        # dispatch count, no execution seal, no semantic attempt, no cost or
        # token consumption, and no QUARANTINED mutation. The check reuses
        # the authoritative ``validate_packet_for_approval`` (also called by
        # execution_start and capability_migration) and the existing packet
        # parser; it does not fork schema logic, weaken existing QUARANTINE
        # semantics, or auto-reactivate operational rows.
        #
        # Parse-failure classifications (branch B) are emitted as a bounded,
        # non-sensitive diagnostic (``packet_errors`` is a single short string
        # describing the parse class, never raw exception text or file bytes).
        packet_path_for_admission = state_mod.run_dir(Path(repo), run_id) / "WORK_PACKET.md"
        if not packet_path_for_admission.is_file():
            return {
                "schema": _db_mod.SCHEMA,
                "ok": False,
                "db_path": str(db),
                "repo": repo,
                "run_id": run_id,
                "enqueue_refused": True,
                "reason": "pre_seal_packet_missing",
                "packet_path": str(packet_path_for_admission),
            }
        try:
            packet_meta_for_admission, _ = packet_mod.parse_packet_file(packet_path_for_admission)
        except Exception:
            # Bounded diagnostic: classify the parse failure without exposing
            # arbitrary exception text or file contents to durable state.
            return {
                "schema": _db_mod.SCHEMA,
                "ok": False,
                "db_path": str(db),
                "repo": repo,
                "run_id": run_id,
                "enqueue_refused": True,
                "reason": "pre_seal_packet_invalid",
                "packet_path": str(packet_path_for_admission),
                "packet_errors": ["packet: WORK_PACKET.md could not be parsed"],
            }
        admission_errors = packet_mod.validate_packet_for_approval(packet_meta_for_admission)
        if admission_errors:
            return {
                "schema": _db_mod.SCHEMA,
                "ok": False,
                "db_path": str(db),
                "repo": repo,
                "run_id": run_id,
                "enqueue_refused": True,
                "reason": "pre_seal_packet_invalid",
                "packet_path": str(packet_path_for_admission),
                "packet_errors": list(admission_errors),
            }

        existing = conn.execute(
            "SELECT * FROM jobs WHERE repo=? AND run_id=?", (repo, run_id)
        ).fetchone()
        if existing is not None:
            # Retired enrollments are durable historical evidence and must not
            # be silently reactivated by a re-enqueue; the architecture does
            # not expose a reactivation command by design. Fail closed with an
            # explicit diagnostic so an operator cannot accidentally rewrite
            # a retired historical record through normal enqueue traffic.
            if str(existing["status"] or "") == "RETIRED":
                out = dict(existing)
                out.update({
                    "schema": _db_mod.SCHEMA,
                    "ok": False,
                    "db_path": str(db),
                    "enqueue_refused": True,
                    "reason": "enqueue_refuses_retired_enrollment",
                })
                return out
            if str(existing["status"] or "") == "RUNNING":
                existing_generation = str(existing["runtime_generation"] or "")
                if not existing_generation or str(eff_generation) != existing_generation:
                    out = dict(existing)
                    out.update({
                        "schema": _db_mod.SCHEMA,
                        "ok": False,
                        "db_path": str(db),
                        "enqueue_refused": True,
                        "reason": (
                            "running_job_runtime_generation_unbound"
                            if not existing_generation
                            else "cannot_change_runtime_generation_while_running"
                        ),
                    })
                    return out
                existing_key = str(existing["repository_scheduling_key"] or "")
                existing_workspace_key = str(existing["workspace_scheduling_key"] or "")
                existing_candidate_branch = str(existing["candidate_branch"] or "")
                existing_mode = str(existing["execution_mode"] or "SINGLE")
                if (
                    int(existing["repository_identity_proven"] or 0) != 1
                    or int(existing["workspace_identity_proven"] or 0) != 1
                    or existing_key != str(scheduling_key)
                    or existing_workspace_key != str(workspace_key)
                    or existing_candidate_branch != str(candidate_branch)
                    or existing_mode != str(execution_mode)
                ):
                    out = dict(existing)
                    out.update({
                        "schema": _db_mod.SCHEMA,
                        "ok": False,
                        "db_path": str(db),
                        "enqueue_refused": True,
                        "reason": "cannot_change_scheduling_identity_while_running",
                    })
                    return out
            def _keep(field: str, supplied: Any, default: Any) -> Any:
                return supplied if supplied is not None else existing[field]
            eff_infra = _keep("max_infra_failures", max_infra_failures, 3)
            eff_transient = _keep("max_transient_failures", max_transient_failures, 8)
            eff_cycles = _keep(
                "max_transient_recovery_cycles", max_transient_recovery_cycles, 2
            )
            eff_cost = _keep("max_total_cost_usd", max_total_cost_usd, 0.0)
            eff_tokens = _keep("max_total_tokens", max_total_tokens, 0)
            eff_wall = _keep("max_wall_seconds", max_wall_seconds, 0)
            eff_legacy_ambiguous = int(existing["legacy_budget_ambiguous"] or 0)
            if (
                max_total_cost_usd is not None
                and max_total_tokens is not None
                and max_wall_seconds is not None
            ):
                eff_legacy_ambiguous = 0
        else:
            eff_infra = max_infra_failures if max_infra_failures is not None else 3
            eff_transient = max_transient_failures if max_transient_failures is not None else 8
            eff_cycles = (
                max_transient_recovery_cycles
                if max_transient_recovery_cycles is not None else 2
            )
            eff_cost = max_total_cost_usd if max_total_cost_usd is not None else 0.0
            eff_tokens = max_total_tokens if max_total_tokens is not None else 0
            eff_wall = max_wall_seconds if max_wall_seconds is not None else 0
            eff_legacy_ambiguous = 0
        conn.execute(
            """
            INSERT INTO jobs
              (repo, run_id, runner, status, infra_failures,
               max_infra_failures, transient_failures, max_transient_failures,
               transient_recovery_cycles, max_transient_recovery_cycles,
               total_cost_usd, next_attempt_at,
               max_total_cost_usd, max_total_tokens, max_wall_seconds,
               runtime_generation, legacy_budget_ambiguous,
               repository_scheduling_key, repository_identity_proven,

               candidate_branch, workspace_scheduling_key, workspace_identity_proven,

               execution_mode, created_at, updated_at)
            VALUES (?, ?, ?, 'QUEUED', 0, ?, 0, ?, 0, ?, 0, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(repo, run_id) DO UPDATE SET
              runner=excluded.runner,
              max_infra_failures=excluded.max_infra_failures,
              max_transient_failures=excluded.max_transient_failures,
              max_transient_recovery_cycles=excluded.max_transient_recovery_cycles,
              max_total_cost_usd=excluded.max_total_cost_usd,
              max_total_tokens=excluded.max_total_tokens,
              max_wall_seconds=excluded.max_wall_seconds,
              runtime_generation=excluded.runtime_generation,
              legacy_budget_ambiguous=excluded.legacy_budget_ambiguous,
              repository_scheduling_key=excluded.repository_scheduling_key,
              repository_identity_proven=excluded.repository_identity_proven,
              candidate_branch=excluded.candidate_branch,
              workspace_scheduling_key=excluded.workspace_scheduling_key,
              workspace_identity_proven=excluded.workspace_identity_proven,
              execution_mode=excluded.execution_mode,
              updated_at=excluded.updated_at
            """,
            (
                repo,
                run_id,
                runner,
                int(eff_infra),
                int(eff_transient),
                int(eff_cycles),
                float(eff_cost),
                int(eff_tokens),
                int(eff_wall),
                str(eff_generation),
                int(eff_legacy_ambiguous),
                scheduling_key,
                int(identity_proven),
                candidate_branch,
                workspace_key,
                int(workspace_proven),
                execution_mode,
                now,
                now,
            ),
        )
        # Fetch the authoritative row by the durable unique enrollment key.
        # On first enrollment there is intentionally no pre-existing row, while
        # ON CONFLICT re-enrollment preserves the same (repo, run_id) identity.
        row = conn.execute(
            "SELECT * FROM jobs WHERE repo=? AND run_id=?", (repo, run_id)
        ).fetchone()
        hold = _holds_mod._hold_row(conn, int(row["id"])) if row is not None else None
        if dispatch_hold_kind is not None:
            if row is None:
                raise RuntimeError("dispatch hold enrollment lost job row")
            if hold is None:
                hold = {
                    "hold_id": uuid.uuid4().hex,
                    "job_id": int(row["id"]),
                    "repo": repo,
                    "run_id": run_id,
                    "kind": dispatch_hold_kind,
                    "previous_checkpoint_id": dispatch_hold_previous_checkpoint_id,
                    "next_checkpoint_id": dispatch_hold_next_checkpoint_id,
                    "state": "ARMED",
                    "armed_at": now,
                    "held_at": None,
                    "released_at": None,
                    "cancelled_at": None,
                    "last_error": None,
                    "updated_at": now,
                }
                conn.execute(
                    """INSERT INTO dispatch_holds
                       (hold_id, job_id, repo, run_id, kind,
                        previous_checkpoint_id, next_checkpoint_id, state,
                        armed_at, held_at, released_at, cancelled_at,
                        last_error, updated_at)
                       VALUES (?, ?, ?, ?, ?, ?, ?, 'ARMED', ?, NULL, NULL,
                               NULL, NULL, ?)""",
                    (
                        hold["hold_id"], hold["job_id"], hold["repo"], hold["run_id"],
                        hold["kind"], hold["previous_checkpoint_id"],
                        hold["next_checkpoint_id"], hold["armed_at"], hold["updated_at"],
                    ),
                )
                hold = _holds_mod._hold_row(conn, int(row["id"]))
            else:
                if (
                    str(hold["kind"]) != dispatch_hold_kind
                    or str(hold["previous_checkpoint_id"]) != str(dispatch_hold_previous_checkpoint_id)
                    or str(hold["next_checkpoint_id"]) != str(dispatch_hold_next_checkpoint_id)
                ):
                    raise ValueError("dispatch hold intent conflicts with existing job hold")
        result = _readmodel_mod._job_dict(row, db)
        result["dispatch_hold"] = _holds_mod._hold_dict(hold)
    return result




def _take_next_job(conn: sqlite3.Connection) -> sqlite3.Row | None:
    _recovery_mod._recover_stale_running(conn)
    while True:
        now = time.time()
        candidates = conn.execute(
            """
            SELECT * FROM jobs
            WHERE status IN ('QUEUED','BACKOFF') AND next_attempt_at <= ?
            ORDER BY last_dispatch_sequence, created_at, id
            """,
            (now,),
        ).fetchall()
        if not candidates:
            return None

        # Persisted two-to-one SINGLE preference, with least-recently-served
        # ordering inside each class.  The counter lives in the ledger so a
        # supervisor restart cannot reset a continuously eligible PROGRAM.
        meta = conn.execute(
            "SELECT dispatch_sequence, single_since_program FROM scheduler_meta WHERE id=1"
        ).fetchone()
        observed_dispatch_sequence = int(meta["dispatch_sequence"] if meta is not None else 0)
        single_since_program = int(meta["single_since_program"] if meta is not None else 0)

        def _fair_order(rows: list[sqlite3.Row]) -> list[sqlite3.Row]:
            return sorted(
                rows,
                key=lambda r: (
                    int(r["last_dispatch_sequence"] or 0),
                    float(r["created_at"]),
                    int(r["id"]),
                ),
            )

        singles = _fair_order([
            r for r in candidates
            if str(r["execution_mode"] or "SINGLE") == "SINGLE"
        ])
        programs = _fair_order([
            r for r in candidates
            if str(r["execution_mode"] or "SINGLE") == "PROGRAM"
        ])
        # Prefer the configured class but retain the other class as fallback.
        # Otherwise a HELD or same-repository-blocked preferred job can strand
        # a free slot while an unrelated job is eligible.
        if singles and programs:
            candidates = (
                singles + programs
                if single_since_program < 2
                else programs + singles
            )
        else:
            candidates = singles or programs

        retry_candidates = False
        for candidate in candidates:
            hold, decision = _holds_mod._hold_matches_before_claim(conn, candidate)
            if decision == "HELD":
                # A held job remains QUEUED and is intentionally skipped so a
                # different repository/run may use the operational slot.
                continue
            if decision in {"invalid_hold_state", "unsupported_hold_kind"}:
                # A malformed operational hold is never interpreted as an
                # absent hold.  Leave the job queued and fail closed; the
                # diagnostic remains inspectable through hold status.
                continue
            if decision.startswith("engineering_state_unavailable"):
                # A hold whose engineering truth cannot be verified is never
                # treated as released. Leave the job queued and fail closed.
                continue
            if decision == "MATCH":
                # The slow authoritative read happened outside SQLite write
                # ownership. Revalidate both rows before the CAS transition.
                conn.execute("BEGIN IMMEDIATE")
                current = conn.execute(
                    "SELECT * FROM jobs WHERE id=?", (int(candidate["id"]),)
                ).fetchone()
                current_hold = _holds_mod._hold_row(conn, int(candidate["id"]))
                active = int(conn.execute(
                    "SELECT COUNT(*) FROM jobs WHERE status='RUNNING'"
                ).fetchone()[0])
                config = conn.execute(
                    "SELECT value FROM supervisor_config WHERE key=?",
                    (_db_mod._CONFIG_MAX_CONCURRENCY,),
                ).fetchone()
                max_concurrency = _db_mod._validate_max_concurrency(
                    config[0] if config is not None else DEFAULT_MAX_CONCURRENCY
                )
                same_workspace = conn.execute(
                    """SELECT id FROM jobs WHERE status=\'RUNNING\'
                       AND workspace_scheduling_key=? LIMIT 1""",
                    (str(candidate["workspace_scheduling_key"] or ""),),
                ).fetchone()
                if (
                    current is None
                    or current["status"] not in ("QUEUED", "BACKOFF")
                    or float(current["next_attempt_at"] or 0) > time.time()
                    or current_hold is None
                    or current_hold["state"] != "ARMED"
                    or active >= max_concurrency
                    or same_workspace is not None
                    or int(current["repository_identity_proven"] or 0) != 1
                    or int(current["workspace_identity_proven"] or 0) != 1
                ):
                    conn.commit()
                    continue
                held_at = time.time()
                conn.execute(
                    """UPDATE dispatch_holds
                       SET state='HELD', held_at=?, updated_at=?, last_error=NULL
                       WHERE hold_id=? AND job_id=? AND state='ARMED'""",
                    (held_at, held_at, current_hold["hold_id"], int(candidate["id"])),
                )
                conn.commit()
                # Re-scan in case another queued job can safely run while
                # this run waits for its explicit operational release.
                continue

            # Normal no-hold or predicate-false claim. Revalidate the job
            # after the out-of-transaction hold observation.
            conn.execute("BEGIN IMMEDIATE")
            current = conn.execute(
                "SELECT * FROM jobs WHERE id=?", (int(candidate["id"]),)
            ).fetchone()
            active = int(conn.execute(
                "SELECT COUNT(*) FROM jobs WHERE status='RUNNING'"
            ).fetchone()[0])
            config = conn.execute(
                "SELECT value FROM supervisor_config WHERE key=?",
                (_db_mod._CONFIG_MAX_CONCURRENCY,),
            ).fetchone()
            max_concurrency = _db_mod._validate_max_concurrency(
                config[0] if config is not None else DEFAULT_MAX_CONCURRENCY
            )
            current_meta = conn.execute(
                "SELECT dispatch_sequence, single_since_program FROM scheduler_meta WHERE id=1"
            ).fetchone()
            if (
                current_meta is None
                or int(current_meta["dispatch_sequence"] or 0) != observed_dispatch_sequence
                or int(current_meta["single_since_program"] or 0) != single_since_program
            ):
                # Another lane committed a scheduling decision after our
                # observation. Retry from fresh fairness truth instead of
                # allowing multiple lanes to spend the same 2:1 preference.
                conn.commit()
                retry_candidates = True
                break
            same_workspace = conn.execute(
                """SELECT id FROM jobs WHERE status=\'RUNNING\'
                   AND workspace_scheduling_key=? LIMIT 1""",
                (str(candidate["workspace_scheduling_key"] or ""),),
            ).fetchone()
            if (
                current is None
                or current["status"] not in ("QUEUED", "BACKOFF")
                or float(current["next_attempt_at"] or 0) > time.time()
                or active >= max_concurrency
                or same_workspace is not None
                or int(current["repository_identity_proven"] or 0) != 1
                or int(current["workspace_identity_proven"] or 0) != 1
            ):
                conn.commit()
                continue
            conn.execute(
                """
                UPDATE jobs SET
                  status='RUNNING',
                  worker_pid=?,
                  worker_started_at=?,
                  worker_role='dispatching',
                  dispatch_count=dispatch_count+1,
                  updated_at=?
                WHERE id=? AND status IN ('QUEUED','BACKOFF')
                """,
                (os.getpid(), now, now, int(candidate["id"])),
            )
            sequence = observed_dispatch_sequence + 1
            mode = str(current["execution_mode"] or "SINGLE")
            next_single_since_program = 0 if mode == "PROGRAM" else single_since_program + 1
            conn.execute(
                "UPDATE jobs SET last_dispatch_sequence=?, updated_at=? WHERE id=?",
                (sequence, time.time(), int(candidate["id"])),
            )
            conn.execute(
                "UPDATE scheduler_meta SET dispatch_sequence=?, single_since_program=?, updated_at=? WHERE id=1",
                (sequence, next_single_since_program, time.time()),
            )
            conn.commit()
            return conn.execute(
                "SELECT * FROM jobs WHERE id=?", (int(candidate["id"]),)
            ).fetchone()
        if not retry_candidates:
            return None




def _scheduler_submission_budget(
    *,
    db_path: Path,
    configured: int,
    local_inflight: int,
) -> int:
    """Bound useful lane probes without becoming scheduling authority.

    The transactional claim path still owns capacity and workspace exclusion.
    This read-only projection prevents a high max_concurrency setting from
    creating an idle SQLite/thread storm. If projection is unavailable, one
    authoritative run_one probe is allowed so bootstrap/recovery cannot stall.
    """
    local_room = max(0, int(configured) - int(local_inflight))
    if local_room <= 0:
        return 0
    try:
        with _db_mod._managed_connect_readonly(db_path) as conn:
            active = int(conn.execute(
                "SELECT COUNT(*) FROM jobs WHERE status='RUNNING'"
            ).fetchone()[0])
            durable_room = max(0, int(configured) - active)
            due = int(conn.execute(
                """SELECT COUNT(*)
                     FROM jobs j
                     LEFT JOIN dispatch_holds h ON h.job_id=j.id
                    WHERE j.status IN ('QUEUED','BACKOFF')
                      AND j.next_attempt_at <= ?
                      AND j.repository_identity_proven=1
                      AND j.workspace_identity_proven=1
                      AND (h.state IS NULL OR h.state != 'HELD')
                      AND NOT EXISTS (
                          SELECT 1 FROM jobs r
                           WHERE r.status='RUNNING'
                             AND r.workspace_scheduling_key=j.workspace_scheduling_key
                      )""",
                (time.time(),),
            ).fetchone()[0])
            useful = min(local_room, durable_room, max(0, due))
            # After supervisor restart, durable RUNNING rows may have no local
            # Future. Keep one reconciliation probe alive even at full durable
            # capacity so dead workers cannot strand the fleet forever.
            orphan_probe = 1 if active > int(local_inflight) else 0
            return min(local_room, max(useful, orphan_probe))
    except (OSError, sqlite3.Error, ValueError):
        return min(local_room, 1)

