"""Supervisor attempts — semantic-attempt lifecycle owner.

Canonical body owner of the supervisor's semantic-attempt lifecycle
surface.  The implementations live here; supervisor.py exposes
thin delegating wrappers for backward compatibility.

This module owns:

  * attempt reservation / creation;
  * attempt durable mutation (binding worker pid / role / attempt);
  * provenance gate (the canonical check that decides whether
    an attempt may be accepted for the requested profile);
  * replay identity (the canonical SHA used by replay logic);
  * acceptance publication (the durable mark that the latest
    artifact is accepted as the canonical semantic result);
  * exactly-once semantic acceptance (idempotent re-publication);
  * semantic artifact completion (the fillable-completion path);
  * attempt-level cost / token / model attachment;
  * cost-budget remaining and unknown-cost counter helpers.

What stays in ``supervisor.py``:

  * The composition facade (``serve``, ``run_one``, ``enqueue``,
    ``resume``, ``retire``).
  * Composition/orchestration remains in ``supervisor.py``.
  * Process identity is owned by ``supervisor_process`` and runner
    output paths are owned by ``supervisor_runner_io``.

Dependency direction:

  supervisor_attempts -> supervisor_db (write primitives,
      including the generic ``_update_job`` transition)
  supervisor_attempts -> supervisor_accounting (parsers)
  supervisor_attempts -> supervisor_runner_registry (runner lookup)
  supervisor_attempts -> supervisor_process + supervisor_runner_io
"""
from __future__ import annotations

import hashlib
import math
import sqlite3
import time
import uuid
from pathlib import Path
from typing import Any

from . import packet as packet_mod
from . import util
from . import git_checks
from . import state as state_mod
from . import capabilities as capabilities_mod
from . import supervisor_db as _db_mod
from . import supervisor_accounting as _accounting_mod
from . import supervisor_runner_registry as _runner_registry_mod
from . import supervisor_process as _process_mod
from . import supervisor_runner_io as _runner_io_mod


def _replay_candidate_sha(
    *,
    role: str,
    work_order: dict[str, Any],
    repo: str,
    run_id: str,
) -> str:
    """Resolve the candidate SHA a replay would operate on for this role.

    For a builder role the candidate is the builder worktree's current HEAD
    (which review_prepare/build_prepare have anchored at the build pass's
    exact candidate). For a reviewer role the candidate is whatever the
    protocol state currently records as last_candidate_sha — the review
    finalizer is read-only against the reviewer worktree and never advances
    it. Either way, the answer is empty string if unresolvable; the gate
    then refuses replay rather than inferring.
    """
    if role == "builder":
        wt = work_order.get("worktree") or ""
        if not wt:
            return ""
        try:
            head = git_checks.current_head(Path(str(wt)))
        except OSError:
            return ""
        return str(head or "")
    if role == "reviewer":
        if not repo or not run_id:
            return ""
        try:
            state = state_mod.load_verified(Path(str(repo)), str(run_id))
        except Exception:
            return ""
        return str((state or {}).get("last_candidate_sha") or "")
    return ""




def _attempt_provenance_gate(
    conn: sqlite3.Connection,
    *,
    job: sqlite3.Row,
    work_order: dict[str, Any],
    attempt_id: str,
) -> tuple[bool, str, dict[str, Any] | None]:
    """Prove a complete semantic artifact belongs to an accepted launch attempt."""
    role = str(work_order.get("role") or "")
    if role not in {"builder", "reviewer"}:
        return False, "semantic_replay_role_invalid", None
    if not attempt_id:
        return False, "semantic_replay_attempt_missing", None
    attempt = conn.execute(
        "SELECT * FROM semantic_attempts WHERE attempt_id=? AND job_id=?",
        (attempt_id, int(job["id"])),
    ).fetchone()
    if attempt is None:
        return False, "semantic_replay_attempt_missing", None
    if str(attempt["role"] or "") != role:
        return False, "semantic_replay_attempt_role_mismatch", None
    if not bool(int(attempt["cost_accounted"] or 0)):
        return False, "semantic_replay_attempt_unaccounted", None
    if not bool(int(attempt["semantic_accepted"] or 0)):
        return False, "semantic_replay_attempt_not_accepted", None
    if attempt["failure_class"] or attempt["failure_reason"]:
        return False, "semantic_replay_attempt_previously_failed", None
    # v0.9.1 terminal closure: the acceptance publication captured the exact
    # semantic artifact digest and the exact role-specific finalization
    # identity. Both must still hold before a zero-cost replay is permitted.
    # Old rows with semantic_accepted=1 but no captured identity are ambiguous
    # across a crash and therefore remain replay-ineligible.
    accepted_semantic_sha = str(attempt["accepted_semantic_sha256"] or "")
    accepted_candidate_sha = str(attempt["accepted_candidate_sha"] or "")
    if not accepted_semantic_sha:
        return False, "semantic_replay_legacy_artifact_unproven", None
    if not accepted_candidate_sha:
        return False, "semantic_replay_legacy_candidate_unproven", None
    semantic_path = str(work_order.get("semantic_path") or "")
    if not semantic_path:
        return False, "semantic_replay_artifact_path_missing", None
    try:
        current_semantic_bytes = Path(str(semantic_path)).read_bytes()
    except OSError as exc:
        return False, f"semantic_replay_artifact_unreadable:{type(exc).__name__}", None
    current_semantic_sha = hashlib.sha256(current_semantic_bytes).hexdigest()
    if current_semantic_sha != accepted_semantic_sha:
        return False, "semantic_replay_artifact_changed", None
    current_candidate_sha = _replay_candidate_sha(
        role=role,
        work_order=work_order,
        repo=str(job["repo"] or ""),
        run_id=str(job["run_id"] or ""),
    )
    if not current_candidate_sha:
        return False, "semantic_replay_candidate_unresolvable", None
    if current_candidate_sha != accepted_candidate_sha:
        return False, "semantic_replay_candidate_changed", None
    runner_impl = _runner_registry_mod.get_runner(str(job["runner"]))
    if not bool(getattr(runner_impl, "requires_capability_receipt", False)):
        return True, "", None
    try:
        receipt = capabilities_mod.read_resolution_receipt(
            Path(str(job["repo"])),
            str(job["run_id"]),
            role,
            attempt_id,
            allow_historical_binding=True,
        )
    except capabilities_mod.CapabilityResolutionError:
        return False, "semantic_replay_capability_receipt_invalid", None
    requested_profile = receipt.get("requested_runner_profile") or {}
    strict_reason = _accounting_mod.strict_profile_model_violation(
        str(requested_profile.get("model") or ""),
        result_ok=True,
        effective_model=str(attempt["effective_model"] or ""),
    )
    if strict_reason:
        return False, strict_reason, receipt
    return True, "", receipt




def _account_attempt_cost(
    conn: sqlite3.Connection,
    *,
    job_id: int,
    attempt_id: str,
    cost_usd: float,
    returncode: int | None = None,
    status_value: str = "COMPLETED",
    cost_known: bool = True,
    input_tokens: int = 0,
    output_tokens: int = 0,
    cache_read_tokens: int = 0,
    cache_creation_tokens: int = 0,
    tokens_known: bool = False,
    manage_transaction: bool = True,
    effective_model: str | None = None,
    model_usage_json: str | None = None,
) -> float:
    """Account one durable semantic attempt exactly once by attempt identity.

    Cost and token telemetry share the same attempt-identity fence so retries
    can never double-count either resource. `effective_model` records the
    model the provider PROVABLY reported ("" when unprovable), kept distinct
    from the requested profile; `model_usage_json` preserves the FULL
    provider-reported usage so multi-model mixes are never collapsed.
    """
    if not math.isfinite(float(cost_usd)) or float(cost_usd) < 0:
        raise RuntimeError("semantic attempt cost is not a finite non-negative value")
    usage_values = (
        int(input_tokens),
        int(output_tokens),
        int(cache_read_tokens),
        int(cache_creation_tokens),
    )
    if any(value < 0 for value in usage_values):
        raise RuntimeError("semantic attempt token usage must be non-negative")
    if manage_transaction:
        conn.execute("BEGIN IMMEDIATE")
    attempt = conn.execute(
        "SELECT * FROM semantic_attempts WHERE attempt_id=? AND job_id=?",
        (attempt_id, int(job_id)),
    ).fetchone()
    if attempt is None:
        conn.rollback()
        raise RuntimeError(f"semantic attempt missing: {attempt_id}")
    already = bool(int(attempt["cost_accounted"] or 0))
    if not already:
        conn.execute(
            """UPDATE semantic_attempts SET status=?, completed_at=?,
               returncode=?, cost_usd=?, cost_accounted=1, cost_known=?,
               input_tokens=?, output_tokens=?, cache_read_tokens=?,
               cache_creation_tokens=?, tokens_known=?, effective_model=?,
               model_usage_json=?
               WHERE attempt_id=?""",
            (
                status_value,
                time.time(),
                returncode,
                float(cost_usd),
                1 if cost_known else 0,
                *usage_values,
                1 if tokens_known else 0,
                str(effective_model or ""),
                str(model_usage_json or ""),
                attempt_id,
            ),
        )
        conn.execute(
            """UPDATE jobs SET
               total_cost_usd=total_cost_usd+?,
               total_input_tokens=total_input_tokens+?,
               total_output_tokens=total_output_tokens+?,
               total_cache_read_tokens=total_cache_read_tokens+?,
               total_cache_creation_tokens=total_cache_creation_tokens+?,
               updated_at=?
               WHERE id=?""",
            (
                float(cost_usd),
                *usage_values,
                time.time(),
                int(job_id),
            ),
        )
    else:
        conn.execute(
            """UPDATE semantic_attempts SET status=?,
               completed_at=COALESCE(completed_at, ?),
               returncode=COALESCE(returncode, ?)
               WHERE attempt_id=?""",
            (status_value, time.time(), returncode, attempt_id),
        )
    if manage_transaction:
        conn.commit()
    row = conn.execute("SELECT total_cost_usd FROM jobs WHERE id=?", (int(job_id),)).fetchone()
    return float(row[0] or 0.0)




def _publish_semantic_acceptance(
    conn: sqlite3.Connection,
    *,
    job_id: int,
    attempt_id: str,
    semantic_path: str,
    candidate_sha: str,
) -> None:
    """Durably authorize deterministic finalization for one exact attempt.

    This publication is intentionally separate from resource accounting.
    Callers may reach it only after the live RunnerResult succeeded, required
    capability receipt/model checks passed, and the semantic artifact was
    proven ready for deterministic finalization. Historical/ambiguous rows
    default to semantic_accepted=0 and are never inferred accepted.

    v0.9.1 terminal closure: this publication captures the exact semantic
    artifact digest (accepted_semantic_sha256) and the exact role-specific
    finalization identity (accepted_candidate_sha). Zero-cost replay
    re-proves both identities; changed semantic bytes or changed candidate
    HEAD refuse replay. Old rows with semantic_accepted=1 but no captured
    identity remain fail-closed; the supervisor never silently rewrites a
    historical acceptance.
    """
    if not semantic_path:
        raise RuntimeError("semantic acceptance requires the semantic artifact path")
    if not candidate_sha:
        raise RuntimeError("semantic acceptance requires the candidate SHA")
    try:
        semantic_bytes = Path(str(semantic_path)).read_bytes()
    except OSError as exc:
        raise RuntimeError(
            f"semantic artifact unreadable at acceptance: {type(exc).__name__}: {exc}"
        )
    semantic_sha256 = hashlib.sha256(semantic_bytes).hexdigest()
    conn.execute("BEGIN IMMEDIATE")
    attempt = conn.execute(
        "SELECT * FROM semantic_attempts WHERE attempt_id=? AND job_id=?",
        (attempt_id, int(job_id)),
    ).fetchone()
    if attempt is None:
        conn.rollback()
        raise RuntimeError(f"semantic attempt missing: {attempt_id}")
    if not bool(int(attempt["cost_accounted"] or 0)):
        conn.rollback()
        raise RuntimeError("semantic acceptance requires durable resource accounting")
    if attempt["failure_class"] or attempt["failure_reason"]:
        conn.rollback()
        raise RuntimeError("failed semantic attempt cannot be accepted")
    if bool(int(attempt["semantic_accepted"] or 0)):
        conn.rollback()
        existing_artifact = str(attempt["accepted_semantic_sha256"] or "")
        existing_candidate = str(attempt["accepted_candidate_sha"] or "")
        if (
            existing_artifact == semantic_sha256
            and existing_candidate == candidate_sha
        ):
            conn.commit()
            return
        # Never silently rewrite a historical acceptance with a different
        # identity. The original acceptance already bound whatever it bound;
        # a subsequent attempt to re-publish with different bytes/candidate
        # is a fail-closed ambiguity.
        raise RuntimeError(
            "semantic acceptance already published with different identity; "
            "refusing to silently update"
        )
    cur = conn.execute(
        """UPDATE semantic_attempts
              SET semantic_accepted=1,
                  accepted_semantic_sha256=?,
                  accepted_candidate_sha=?,
                  accepted_at=?
            WHERE attempt_id=? AND job_id=?
              AND cost_accounted=1
              AND semantic_accepted=0
              AND failure_class IS NULL
              AND failure_reason IS NULL""",
        (
            semantic_sha256,
            candidate_sha,
            time.time(),
            attempt_id,
            int(job_id),
        ),
    )
    if cur.rowcount != 1:
        conn.rollback()
        raise RuntimeError("semantic acceptance publication lost its authority fence")
    conn.commit()




def _remaining_funded_cost_budget(max_total_cost_usd: float, spent_cost_usd: float) -> float | None:
    """Return the authoritative native per-pass cap; None means unfunded."""
    maximum = float(max_total_cost_usd or 0.0)
    spent = float(spent_cost_usd or 0.0)
    if maximum <= 0:
        return None
    return max(0.0, maximum - spent)




def _unknown_cost_attempt_count(conn: sqlite3.Connection, job_id: int) -> int:
    # TOKENS_UNKNOWN attempts can also carry unknown provider cost; a funded
    # cost ceiling must fail closed on them exactly like COST_UNKNOWN rows.
    row = conn.execute(
        """SELECT COUNT(*) FROM semantic_attempts
           WHERE job_id=? AND cost_known=0
             AND status IN ('COMPLETED','COST_UNKNOWN','TOKENS_UNKNOWN','RECOVERED')""",
        (int(job_id),),
    ).fetchone()
    return int((row[0] if row is not None else 0) or 0)


# Failure reasons that PROVE a semantic attempt never reached provider exec.
# Each is set only on a provably pre-provider terminalization:
#   worker_launch_failed            — WorkerLaunchError before/after the gate, provider never exec'd
#   capability_resolution_failed    — capability plane refused before any model call
#   capability_binding_failed       — run-binding drift/refusal before any model call
#   runner_profile_resolution_failed — profile plane refused before any model call
#   worker_ownership_not_published  — crash recovery of a gated RESERVED attempt whose
#                                     release byte was never written (provider never released)
# A first capability binding may be created after any number of such attempts,
# because none of them could have observed or bound a prior capability set.
PRE_PROVIDER_FAILURE_REASONS = frozenset({
    "worker_launch_failed",
    "capability_resolution_failed",
    "capability_binding_failed",
    "runner_profile_resolution_failed",
    "worker_ownership_not_published",
})




def _reserve_semantic_attempt(
    conn: sqlite3.Connection,
    *,
    job: sqlite3.Row,
    role: str,
) -> tuple[str, tuple[Path, Path]]:
    worker_log_paths = _runner_io_mod.worker_log_paths
    attempt_id = uuid.uuid4().hex
    durable_files = worker_log_paths(
        Path(str(job["repo"])),
        str(job["run_id"]),
        int(job["id"]),
        role,
        attempt_id,
    )
    now = time.time()
    runner_impl = _runner_registry_mod.get_runner(str(job["runner"]))
    launch_gate_version = int(
        getattr(runner_impl, "launch_gate_version", 0) or 0
    )
    conn.execute(
        """INSERT INTO semantic_attempts
           (attempt_id, job_id, role, status, started_at, stdout_path, stderr_path,
            launch_gate_version)
           VALUES (?, ?, ?, 'RESERVED', ?, ?, ?, ?)""",
        (
            attempt_id, int(job["id"]), role, now,
            str(durable_files[0]), str(durable_files[1]),
            launch_gate_version,
        ),
    )
    cur = conn.execute(
        """UPDATE jobs SET worker_attempt_id=?, latest_attempt_id=?,
           worker_stdout_path=?, worker_stderr_path=?, updated_at=?
           WHERE id=? AND status='RUNNING'""",
        (attempt_id, attempt_id, str(durable_files[0]), str(durable_files[1]),
         now, int(job["id"])),
    )
    if cur.rowcount != 1:
        conn.rollback()
        raise RuntimeError("semantic attempt reservation lost RUNNING ownership")
    conn.commit()
    return attempt_id, durable_files




def _set_worker_pid(
    conn: sqlite3.Connection,
    job_id: int,
    pid: int,
    role: str,
    *,
    out_path: Path | None = None,
    err_path: Path | None = None,
    attempt_id: str | None = None,
    deadline_at: float | None = None,
) -> None:
    _read_pid_start_identity = _process_mod._read_pid_start_identity
    started = time.time()
    cur = conn.execute(
        """
        UPDATE jobs SET worker_pid=?, worker_started_at=?, worker_pgid=?,
          worker_deadline_at=?, worker_start_identity=?, worker_role=?,
          worker_stdout_path=?, worker_stderr_path=?,
          worker_attempt_id=COALESCE(?, worker_attempt_id), updated_at=?
        WHERE id=? AND status='RUNNING'
        """,
        (
            int(pid),
            started,
            int(pid),
            float(deadline_at) if deadline_at is not None else None,
            _read_pid_start_identity(int(pid)),
            role,
            str(out_path) if out_path else None,
            str(err_path) if err_path else None,
            attempt_id,
            started,
            job_id,
        ),
    )
    if cur.rowcount != 1:
        conn.rollback()
        raise RuntimeError("worker PID persistence lost RUNNING ownership")
    if attempt_id:
        a = conn.execute(
            """UPDATE semantic_attempts SET status='RUNNING', worker_pid=?,
               worker_pgid=?, deadline_at=?, worker_start_identity=?, started_at=?
               WHERE attempt_id=? AND job_id=?""",
            (
                int(pid), int(pid),
                float(deadline_at) if deadline_at is not None else None,
                _read_pid_start_identity(int(pid)),
                started, attempt_id, int(job_id),
            ),
        )
        if a.rowcount != 1:
            conn.rollback()
            raise RuntimeError("semantic attempt row missing during worker start")
    conn.commit()




def _ensure_execution_started(conn: sqlite3.Connection, job_id: int) -> float:
    """Start the operational wall clock only when semantic execution can run."""
    now = time.time()
    conn.execute(
        """UPDATE jobs SET execution_started_at=COALESCE(execution_started_at, ?),
           updated_at=? WHERE id=?""",
        (now, now, int(job_id)),
    )
    conn.commit()
    row = conn.execute(
        "SELECT execution_started_at FROM jobs WHERE id=?", (int(job_id),)
    ).fetchone()
    if row is None or row[0] is None:
        raise RuntimeError("failed to persist execution_started_at")
    return float(row[0])




def _maybe_complete_semantic_artifact(
    *,
    conn: sqlite3.Connection,
    work_order: dict[str, Any],
    semantic_reason: str,
    job_id: int,
) -> bool:
    """One-shot deterministic completion of the typed semantic-result contract.

    Returns True iff the existing on-disk artifact was rendered valid by
    authoritative-source fillable completion (no provider spend, no model
    call, no repair-counter increment, no engineering replay).

    v0.9.9-i: BUILD-only. REVIEW dispatches must NEVER route through this
    helper. Reviewer verdict is a separate authority class; only the
    provenance-publication follow-on (`_publish_acceptance_for_ready_artifact`)
    is safe to invoke for review, never the builder-side fillable completion.

    Conditions for invoking the completion path:

      * the worker has already terminated (semantic_result_ready returned False),
      * worktree is clean at `git status --porcelain`,
      * a candidate HEAD exists on the prepared candidate branch,
      * all fixed-identity fields the supervisor can re-prove are intact,
      * only fillable/runtime fields are blank — never identity fields.

    When any of these conditions fail, the function returns False and the
    supervisor falls through to its retry path. The retry path itself is
    unchanged; this function only short-circuits a subset of retryable
    failures that turn out to be a missing typed-artifact, not a missing
    engineering pass.

    On success, this function also publishes the latest attempt's
    `semantic_accepted` flag with the completed artifact's digest and the
    candidate SHA so the downstream `_attempt_provenance_gate` recognizes
    the zero-cost replay as the durable accepted artifact.
    """
    if not isinstance(work_order, dict):
        return False
    decision = str(work_order.get("decision") or "")
    # v0.9.9-i: explicit BUILD/REVIEW role boundary. REVIEW must never
    # invoke builder-side fillable completion; verdict is a separate
    # authority class that only the model can author.
    if decision != "BUILD":
        return False
    canonical_repo = work_order.get("canonical_repo")
    run_id = str(work_order.get("run_id") or "")
    worktree = work_order.get("worktree")
    baseline_sha = str(work_order.get("baseline_sha") or "")
    branch = str(work_order.get("candidate_branch") or "")
    cp_id = str(work_order.get("cp_id") or "")
    role = str(work_order.get("role") or "")
    if not all([canonical_repo, run_id, worktree, baseline_sha, branch]):
        return False
    try:
        wt_path = Path(str(worktree)).resolve(strict=False)
        repo_path = Path(str(canonical_repo)).resolve(strict=False)
    except Exception:
        return False
    if not wt_path.is_dir():
        return False

    cleanliness = git_checks.dirty_status(wt_path)
    if cleanliness not in ("clean",):
        return False

    head = git_checks.current_head(wt_path)
    if not head:
        return False

    actual_branch = git_checks.current_branch(wt_path) or ""
    if branch and actual_branch and branch != actual_branch:
        return False

    current = util.run_subprocess(
        ["git", "-C", str(repo_path), "rev-parse", "--verify", f"{branch}^{{commit}}"],
    )
    candidate_sha = (current.stdout or "").strip() if hasattr(current, "stdout") else ""
    if not candidate_sha:
        return False

    from . import packet as packet_mod
    try:
        packet_path = Path(repo_path) / ".ownframework-loop" / str(run_id) / "WORK_PACKET.md"
        if not packet_path.is_file():
            packet = None
        else:
            packet, _raw = packet_mod.parse_packet_file(packet_path)
            if not isinstance(packet, dict):
                packet = None
    except Exception:
        packet = None

    # v0.9.9-i: decision is always "BUILD" here (early return above).
    if role == "":
        role = "builder"

    completed = build_agent_mod.semantically_complete_artifact(
        canonical_repo=repo_path,
        run_id=run_id,
        worktree=wt_path,
        baseline_sha=baseline_sha,
        current_sha=candidate_sha,
        role=role,
        cp_id=cp_id,
        packet=packet if isinstance(packet, dict) else None,
    )
    if completed is None:
        return False

    # Publish the completion's accepted identity so the downstream
    # `_attempt_provenance_gate` recognizes the zero-cost replay as the
    # durable accepted artifact rather than failing on the prior
    # worker's unaccepted envelope.
    completion_attempt_id = str(
        conn.execute(
            "SELECT latest_attempt_id FROM jobs WHERE id=?", (int(job_id),)
        ).fetchone()["latest_attempt_id"] or ""
    )
    semantic_path = str(work_order.get("semantic_path") or "")
    if completion_attempt_id and semantic_path and candidate_sha:
        try:
            _publish_semantic_acceptance(
                conn,
                job_id=int(job_id),
                attempt_id=completion_attempt_id,
                semantic_path=semantic_path,
                candidate_sha=candidate_sha,
            )
        except Exception:
            # Publication is best-effort here: the gate below will surface
            # any persistent provenance mismatch as a structured replay
            # rejection, leaving the run retryable rather than silently
            # consuming the attempt.
            pass
    return True




def _publish_acceptance_for_ready_artifact(
    *,
    conn: sqlite3.Connection,
    work_order: dict[str, Any],
    job_id: int,
) -> None:
    """Publish the latest attempt's acceptance for an already-valid artifact.

    This is a focused recovery path for the v0.9.9-h scenario where the
    worker's typed contract completion happened in a prior tick but the
    publish step was bypassed. The dispatch site invokes this whenever
    `semantic_result_ready` returns True for a job whose latest attempt
    is still unaccepted, so the downstream provenance gate recognizes
    the zero-cost replay as the durable accepted artifact.
    """
    semantic_path = str(work_order.get("semantic_path") or "")
    if not semantic_path:
        return
    try:
        repo_path = Path(str(work_order.get("canonical_repo") or "")).resolve(strict=False)
        branch = str(work_order.get("candidate_branch") or "")
        if not repo_path.is_dir() or not branch:
            return
        current = util.run_subprocess(
            ["git", "-C", str(repo_path), "rev-parse", "--verify", f"{branch}^{{commit}}"],
        )
    except Exception:
        return
    candidate_sha = (current.stdout or "").strip() if hasattr(current, "stdout") else ""
    if not candidate_sha:
        return
    try:
        row = conn.execute(
            "SELECT latest_attempt_id FROM jobs WHERE id=?", (int(job_id),)
        ).fetchone()
    except Exception:
        return
    if row is None:
        return
    completion_attempt_id = str(row["latest_attempt_id"] or "")
    if not completion_attempt_id:
        return
    try:
        _publish_semantic_acceptance(
            conn,
            job_id=int(job_id),
            attempt_id=completion_attempt_id,
            semantic_path=semantic_path,
            candidate_sha=candidate_sha,
        )
    except Exception:
        pass

PRE_PROVIDER_FAILURE_REASONS = frozenset({
    "worker_launch_failed",
    "capability_resolution_failed",
    "capability_binding_failed",
    "runner_profile_resolution_failed",
    "worker_ownership_not_published",
})

def _capability_binding_creation_allowed(
    conn: sqlite3.Connection,
    job_id: int,
) -> bool:
    """Allow first binding only when no provider-reachable historical attempt exists."""
    rows = conn.execute(
        """SELECT status, failure_reason, cost_accounted, cost_usd
             FROM semantic_attempts WHERE job_id=?""",
        (int(job_id),),
    ).fetchall()
    if not rows:
        return True
    return all(
        str(row["status"] or "") == "FAILED"
        and str(row["failure_reason"] or "") in PRE_PROVIDER_FAILURE_REASONS
        and int(row["cost_accounted"] or 0) == 1
        and float(row["cost_usd"] or 0.0) == 0.0
        for row in rows
    )

def _mark_attempt_launch_failed(
    conn: sqlite3.Connection,
    *,
    job_id: int,
    attempt_id: str,
    detail: str,
    failure_reason: str = "worker_launch_failed",
) -> None:
    """Terminalize only a semantic attempt proven not to have reached provider exec."""
    conn.execute("BEGIN IMMEDIATE")
    cur = conn.execute(
        """UPDATE semantic_attempts SET
             status='FAILED', completed_at=?, returncode=NULL,
             worker_pid=NULL, worker_pgid=NULL, deadline_at=NULL,
             worker_start_identity=NULL,
             cost_usd=0, cost_accounted=1, cost_known=1,
             input_tokens=0, output_tokens=0, cache_read_tokens=0,
             cache_creation_tokens=0, tokens_known=1,
             failure_class='configuration', failure_reason=?
           WHERE attempt_id=? AND job_id=?
             AND (
               status='RESERVED'
               OR (status='RUNNING' AND launch_gate_version>=1)
             )""",
        (time.time(), failure_reason, attempt_id, int(job_id)),
    )
    if cur.rowcount != 1:
        conn.rollback()
        raise RuntimeError(
            f"launch-failed attempt was not provably pre-provider: "
            f"{attempt_id}: {detail[-500:]}"
        )
    conn.commit()

