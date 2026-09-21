"""Durable, vendor-thin supervisor for OwnFramework Loop.

Protocol truth remains in the repository's OwnFramework Loop artifacts. SQLite
stores only machine operations: queue state, retries, backoff, runner identity,
and cost/runtime observations.

The supervisor consumes typed work orders from dispatch.py. It never decides
engineering transitions itself.
"""
from __future__ import annotations
import sys

from concurrent.futures import Future, ThreadPoolExecutor
import hashlib
import json
import math
import re
import os
import shlex
import signal
import sqlite3
import shutil
import stat
import subprocess
import threading
import time
import uuid
from contextlib import contextmanager
from dataclasses import dataclass
from functools import wraps
from pathlib import Path
from typing import Any

from . import (
    approval as approval_mod,
    branch_resolver as branch_resolver_mod,
    build_agent as build_agent_mod,
    capabilities as capabilities_mod,
    capability_binding as capability_binding_mod,
    continuation_authority as continuation_authority_mod,
    dispatch as dispatch_mod,
    dispatch_hold as dispatch_hold_mod,
    git_checks,
    packet as packet_mod,
    program as program_mod,
    protected_recovery,
    runner_profiles as runner_profiles_mod,
    runtime_env,
    state as state_mod,
    transitions,
    util,
    runtime_identity,
)
from .locking import flock_exclusive
from . import supervisor_db as _db_mod
from . import supervisor_holds as _holds_mod
from . import supervisor_runner_io as _runner_io_mod
from . import supervisor_identity as _identity_mod
from . import supervisor_readmodel as _readmodel_mod
from . import supervisor_recovery as _recovery_mod
from . import supervisor_attempts as _attempts_mod
from . import supervisor_claims as _claims_mod
from . import supervisor_process as _process_mod
from . import supervisor_runtime as _runtime_mod
from . import supervisor_prompts as _prompts_mod
from . import supervisor_runner_registry as _runner_registry_mod
from . import supervisor_runner as _runner_mod
from . import progress_watchdog as _watchdog_mod

SCHEMA = _db_mod.SCHEMA
DISPATCH_HOLD_KIND = _holds_mod.DISPATCH_HOLD_KIND
DISPATCH_HOLD_STATES = _holds_mod.DISPATCH_HOLD_STATES
CLAUDE_PROVIDER_ENVELOPE_MAX_BYTES = _runner_io_mod.CLAUDE_PROVIDER_ENVELOPE_MAX_BYTES
RUNNER_DIAGNOSTIC_MAX_CHARS = _runner_io_mod.RUNNER_DIAGNOSTIC_MAX_CHARS
# Per-pass runaway fuse fallback. A semantic worker that neither declared a
# packet budget nor got an operational narrowing is bounded to one hour so a
# stuck worker cannot hold the single global execution slot indefinitely.
# Long PROGRAM passes are funded deliberately through
# risk_budget.max_pass_runtime_seconds (packet authority; up to 28800 for v3)
# rather than by widening the default fuse.
DEFAULT_SEMANTIC_TIMEOUT_SECONDS = 3600
# Commissioned semantic passes are sealed local workers.  Builder and reviewer
# intentionally get different first-party Claude capability sets so reviewer
# source immutability is structural, not merely a prompt/hook convention.
CLAUDE_BUILDER_TOOLS = "Read,Edit,Write,NotebookEdit,Bash,Glob,Grep"
CLAUDE_REVIEWER_TOOLS = "Read,Bash,Glob,Grep"

# A worker child can finish before its execution lane has durably accounted the
# result and finalized the engineering artifact. During that handoff window
# the child PID is necessarily dead, but the current supervisor still owns the
# job. Keep this narrow process-local fence so another lane in this same
# supervisor cannot perform stale recovery against the lane that is finishing.
# A replacement supervisor has a different process and an empty registry, so
# crash recovery remains durable/ledger-authoritative rather than depending on
# this optimization.
_LOCAL_EXECUTION_LOCK = _process_mod._LOCAL_EXECUTION_LOCK
_LOCAL_EXECUTION_JOBS = _process_mod._LOCAL_EXECUTION_JOBS
# _LOCAL_CONNECTION_DEPTH is owned by supervisor_db (the canonical
# persistence owner).  We additionally keep a parallel depth counter here
# so the supervisor can clear _LOCAL_EXECUTION_JOBS on depth=0 — the
# previous design coupled connection lifecycle to execution-job lifecycle
# for the per-thread connection ownership check.
_LOCAL_CONNECTION_DEPTH_SUPERVISOR = _process_mod._LOCAL_CONNECTION_DEPTH_SUPERVISOR
_SUPERVISOR_LIFECYCLE_LOCK_NAME = "SUPERVISOR_LIFECYCLE.lock"


def _supervisor_lifecycle_lock_path(canonical_repo: Path, run_id: str) -> Path:
    state_mod.validate_run_id(run_id)
    return state_mod.run_dir(canonical_repo, run_id) / _SUPERVISOR_LIFECYCLE_LOCK_NAME


def _serialize_run_lifecycle(func):
    """Serialize supported operator transitions for one logical run.

    Capability resolution is intentionally performed while this narrow
    per-run lock is held.  The SQLite transaction remains short, while resume,
    retire, enqueue, and PROGRAM continuation cannot invalidate the
    QUARANTINED eligibility snapshot mid-migration.
    """
    @wraps(func)
    def guarded(*args, **kwargs):
        canonical_repo = kwargs.get("canonical_repo")
        run_id = kwargs.get("run_id")
        if canonical_repo is None or run_id is None:
            raise TypeError("lifecycle operation requires canonical_repo and run_id")
        with flock_exclusive(
            _supervisor_lifecycle_lock_path(Path(canonical_repo), str(run_id)),
            blocking=True,
            timeout_seconds=30,
        ):
            return func(*args, **kwargs)
    return guarded


def _register_local_execution(job_id: int) -> None:
    _process_mod._register_local_execution(job_id)


def _local_execution_owned(job_id: int) -> bool:
    return _process_mod._local_execution_owned(job_id)


def _clear_local_executions_for_thread() -> None:
    _process_mod._clear_local_executions_for_thread()


# A commissioned service may need provider authentication/model aliases that a
# launchd/systemd user manager does not inherit from the operator shell. Those
# values live in one private Loop-owned JSON file, never in the service
# definition or runtime provenance. Only this explicit whitelist may be loaded.
_SERVICE_ENV_FILE_VAR = _runtime_mod._SERVICE_ENV_FILE_VAR
_SERVICE_ENV_ALLOWED_KEYS = _runtime_mod._SERVICE_ENV_ALLOWED_KEYS


def _private_mode(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


def _ensure_private_dir(path: Path) -> Path:
    """Create/repair a supervisor-owned private directory (0700 on POSIX).

    Thin delegate to ``supervisor_db._ensure_private_dir``.  Kept as
    a module-local symbol so existing callers do not need an import
    rewrite; the canonical owner is ``supervisor_db``.
    """
    return _db_mod._ensure_private_dir(path)


def _ensure_private_file_mode(path: Path) -> None:
    """Force a supervisor-owned file to 0600 where POSIX modes are available.

    Thin delegate to ``supervisor_db._ensure_private_file_mode``.
    Canonical owner is ``supervisor_db``.
    """
    _db_mod._ensure_private_file_mode(path)


def _load_service_env_file() -> list[str]:
    return _runtime_mod._load_service_env_file()

TERMINAL_SEMANTIC_ATTEMPT_STATUSES = frozenset({
    "COMPLETED", "COST_UNKNOWN", "TOKENS_UNKNOWN",
    "FAILED", "RECOVERED", "SUPERSEDED",
})


WorkerLaunchError = _runner_mod.WorkerLaunchError


# The OS child is born as this tiny gate, not as the model process. It inherits
# one read end of a pipe. The parent publishes exact PID/attempt/deadline
# ownership to SQLite and commits it before writing the release byte. If the
# parent dies in the post-Popen/pre-publication window, the write end closes
# and the gate exits without ever exec'ing the semantic provider.
_WORKER_RELEASE_GATE_CODE = r"""
import os
import sys
fd = int(sys.argv[1])
try:
    token = os.read(fd, 1)
finally:
    os.close(fd)
if token != b"1":
    os._exit(125)
argv = sys.argv[2:]
if not argv:
    os._exit(126)
os.execvpe(argv[0], argv, os.environ)
"""

# --restricted is Claude Code's native scripted/evaluation boundary for shared
# machines. It confines built-in file tools to working directories, ignores
# user/project/local settings, refuses bypass/cloud sessions, and removes
# command/code/web tools unless explicitly named. Available from v2.1.248.
MIN_SECURE_CLAUDE_CODE_VERSION = (2, 1, 248)

# Claude print-mode JSON is authoritative runner transport. Commissioned runs
# spool it to disk, so bound every subsequent in-memory parse without regressing
# legitimate >64 KiB responses. 8 MiB is intentionally far above diagnostic
# retention while preventing accidental/malicious unbounded supervisor reads.
# Canonical owners are in ``supervisor_runner_io``; the names below are
# re-bindings so existing callers keep the same identifier.


def _read_durable_provider_envelope(path: Path) -> str:
    """Thin delegate to ``supervisor_runner_io._read_durable_provider_envelope``."""
    return _runner_io_mod._read_durable_provider_envelope(path)


def _read_durable_diagnostic_tail(path: Path) -> str:
    """Thin delegate to ``supervisor_runner_io._read_durable_diagnostic_tail``."""
    return _runner_io_mod._read_durable_diagnostic_tail(path)

# Extra arguments are operator convenience only. They must never be able to
# replace the unattended worker's tool boundary, sandbox, project-root, or
# settings-source authority.
_CLAUDE_EXTRA_ARG_AUTHORITY_FLAGS = {
    "--settings",
    "--setting-sources",
    "--tools",
    "--allowedTools",
    "--allowed-tools",
    "--disallowedTools",
    "--disallowed-tools",
    "--permission-mode",
    "--dangerously-skip-permissions",
    "--allow-dangerously-skip-permissions",
    "--add-dir",
    "--cwd",
    "--plugin-dir",
    "--mcp-config",
    "--strict-mcp-config",
    "--chrome",
    "--no-chrome",
    "--remote",
    "--teleport",
    "--no-session-persistence",
    "--restricted",
    "--model",
    "--effort",
    "--max-budget-usd",
}


def _claude_cli_version(executable: str):
    return _runner_mod._claude_cli_version(executable)


def _validate_claude_extra_args(extra: list[str]) -> None:
    _runner_mod._validate_claude_extra_args(extra)


def _parse_adapter_auth_read_paths() -> list[str]:
    return _runner_mod._parse_adapter_auth_read_paths()


def _semantic_worker_settings(**kwargs):
    return _runner_mod._semantic_worker_settings(**kwargs)


def resolve_semantic_timeout(
    packet_meta: dict[str, Any] | None,
    supervisor_timeout_seconds: int | float = 0,
) -> int:
    """Resolve one semantic-pass timeout.

    Packet max_pass_runtime_seconds is authority. A positive supervisor
    timeout may narrow it operationally but cannot widen it. With neither,
    preserve the historical one-hour fallback fuse for both single and
    PROGRAM runs; a PROGRAM funds wider passes through its packet budget.
    """
    rb = (packet_meta or {}).get("risk_budget") or {}
    packet_limit = 0
    if isinstance(rb, dict):
        try:
            packet_limit = int(rb.get("max_pass_runtime_seconds") or 0)
        except (TypeError, ValueError):
            packet_limit = 0
    try:
        operational = int(supervisor_timeout_seconds or 0)
    except (TypeError, ValueError):
        operational = 0
    if packet_limit > 0 and operational > 0:
        return min(packet_limit, operational)
    if packet_limit > 0:
        return packet_limit
    if operational > 0:
        return operational
    return DEFAULT_SEMANTIC_TIMEOUT_SECONDS

ACTIVE = {"QUEUED", "BACKOFF", "RUNNING"}
TERMINAL = {"DONE", "QUARANTINED", "RETIRED"}


def runtime_generation() -> str:
    return _runtime_mod.runtime_generation()


# Alias so enqueue() can compute the default binding even though its
# ``runtime_generation`` parameter shadows the function name.
_current_runtime_generation = runtime_generation


def default_db_path() -> Path:
    """Thin delegate to ``supervisor_db.default_db_path`` (canonical owner)."""
    return _db_mod.default_db_path()


def default_worker_log_dir() -> Path:
    return _runner_io_mod.default_worker_log_dir()


def _runtime_cache_run_root(canonical_repo: Path, run_id: str) -> Path:
    return _runtime_mod._runtime_cache_run_root(canonical_repo, run_id)


def _cleanup_terminal_runtime_cache(canonical_repo: Path, run_id: str) -> dict[str, Any]:
    return _runtime_mod._cleanup_terminal_runtime_cache(canonical_repo, run_id)


def _cleanup_done_runtime_caches(db_path: Path | None = None) -> list[dict[str, Any]]:
    return _runtime_mod._cleanup_done_runtime_caches(db_path)


def _publish_startup_ready_attestation(db_path: Path | None) -> None:
    """Write the durable supervisor's startup-ready attestation.

    The launcher (pre-exec) wrote an activation receipt that proves
    the launcher's pre-exec identity.  That receipt alone does NOT
    prove the durable supervisor actually entered its scheduler
    loop.  This helper derives the durable supervisor's own
    post-exec identity independently from the receipt (Seam 1 of
    the residual-closure) and publishes a startup-ready attestation
    only when the durable process's own observations match the
    receipt.  Any mismatch fails closed; the supervisor logs the
    refusal to stderr and the launchd installer — the load-bearing
    authority for SUPERVISOR_INSTALL verification — observes a
    missing/mismatched attestation and REFUSES PASS.

    Independent derivation sources:

    - ``ofloop_bin`` and ``runtime_root``: ``sys.argv`` of THIS
      post-exec supervisor (it was exec'd with the ofloop binary as
      argv[0]).
    - ``runtime_generation``: recomputed through the same
      ``runtime_identity.runtime_generation_for_root`` against the
      runtime root THIS supervisor observes.  ``env_fallback`` is
      not accepted at commissioning time (Seam 2).
    - ``supervisor_db``: the ``db_path`` this serve() instance is
      bound to, canonicalized.  When ``db_path`` is None, the
      canonical ``default_db_path()`` is used.
    - ``ledger_marker``: derived from the canonical state root the
      durable supervisor reads from.
    - ``activation_id`` and ``label``: read from the launchd env
      (commissioned activation context), exact-matched against the
      receipt.
    """
    from . import service_identity  # local import to avoid startup cycles

    activation_id = os.environ.get("OFLOOP_ACTIVATION_ID", "").strip()
    if not activation_id:
        # No active commissioning attempt.  The supervisor may have
        # been launched directly (e.g. ``ofloop supervisor serve``
        # from an operator's shell).  Nothing to attest.
        return
    receipt_path_env = os.environ.get("OFLOOP_RECEIPT_PATH", "").strip()
    if not receipt_path_env:
        print(
            "SUPERVISOR_STARTUP_READY=skipped reason=receipt_path_unset",
            file=sys.stderr,
        )
        return
    try:
        receipt = service_identity.load_receipt(Path(receipt_path_env))
    except (FileNotFoundError, ValueError, OSError) as exc:
        print(
            "SUPERVISOR_STARTUP_READY=skipped reason=receipt_unreadable detail="
            + str(exc),
            file=sys.stderr,
        )
        return
    # Resolve canonical state root for ledger_marker derivation.
    # The supervisor's own canonical db path provides this.  When
    # ``db_path`` is None we fall through to ``default_db_path()``
    # which honours XDG_STATE_HOME the same way the launcher did.
    if db_path is None:
        actual_db = default_db_path()
    else:
        actual_db = Path(db_path).expanduser().resolve(strict=False)
    # state_root: the parent directory of ``ownframework-loop/`` that
    # contains ``supervisor.sqlite3`` (mirrors the launcher's
    # ``default_receipt_path`` derivation).
    actual_db_path = Path(actual_db).expanduser().resolve(strict=False)
    actual_state_root = actual_db_path.parent.parent  # ../.. from <state>/ownframework-loop/supervisor.sqlite3

    try:
        attestation = service_identity.derive_startup_ready(
            receipt=receipt,
            ready_pid=os.getpid(),
            actual_argv=list(sys.argv),
            actual_env=os.environ,
            actual_db_path=actual_db_path,
            actual_state_root=actual_state_root,
        )
    except ValueError as exc:
        print(
            "SUPERVISOR_STARTUP_READY=refused reason=durable_identity_mismatch detail="
            + str(exc),
            file=sys.stderr,
        )
        return
    ready_path = Path(receipt_path_env).with_name("supervisor-startup-ready.json")
    try:
        service_identity.write_receipt_atomic(attestation, ready_path)
    except OSError as exc:
        print(
            "SUPERVISOR_STARTUP_READY=skipped reason=write_failed detail="
            + str(exc),
            file=sys.stderr,
        )
        return
    print(
        "SUPERVISOR_STARTUP_READY=ATTESTED",
        f"activation_id={attestation['activation_id']}",
        f"ready_pid={attestation['ready_pid']}",
        f"attestation={ready_path}",
    )


def _slug_repo(canonical_repo: Path) -> str:
    return _runner_io_mod._slug_repo(canonical_repo)


def worker_log_paths(canonical_repo: Path, run_id: str, job_id: int, role: str, attempt_id: str | None = None) -> tuple[Path, Path]:
    return _runner_io_mod.worker_log_paths(canonical_repo, run_id, job_id, role, attempt_id)


# Ledger data-version. Existing resource ceilings are durable operator state.
# Historical rows may carry the old $25 / unlimited-token / 8h fingerprint,
# but that tuple is indistinguishable from an operator explicitly selecting it.
# Preserve it and mark ambiguity rather than inventing intent.
# Canonical owners are in ``supervisor_db``; the names below are re-bindings
# so existing callers (96 internal SCHEMA references + 4 external
# default_db_path callers + many more) keep the same identifier.
SCHEMA_DATA_VERSION = _db_mod.SCHEMA_DATA_VERSION
DEFAULT_MAX_CONCURRENCY = _db_mod.DEFAULT_MAX_CONCURRENCY
IMPLEMENTATION_MAX_CONCURRENCY = _db_mod.IMPLEMENTATION_MAX_CONCURRENCY
_CONFIG_MAX_CONCURRENCY = _db_mod._CONFIG_MAX_CONCURRENCY
_LEGACY_BUDGET_DEFAULT_FINGERPRINT = _db_mod._LEGACY_BUDGET_DEFAULT_FINGERPRINT
_CONTINUATION_SCHEMA = "ownframework-loop-program-continuation/v1"
_PROGRAM_READY_STATE = next(
    value for value in transitions.STATES
    if value.startswith("READY_TO_") and value.endswith("_BUILD")
)

# v0.10.0-dev a002: default wall budget for the build/review finalize CLI
# subprocess when the operator did not declare max_wall_seconds. The packet-
# derived path (max_wall > 0) feeds the remaining wall budget through; this
# default is the upper bound for unfunded/unbounded runs so a wedged CLI
# child cannot stall the durable execution clock indefinitely.
#
# Rationale: finalize CLI subprocesses commit build/review receipts and
# run deterministic proof (validation, secret scan, protected-path check).
# Legitimate finalize runs complete in tens of seconds; large validation
# suites can take minutes. 3600s (the historical cli.py fallback) is a
# generous safety fuse that matches the per-pass fallback used elsewhere.
# When the operator declares max_wall_seconds via enqueue, that value is
# used instead — so an explicitly-authorized long finalization is not
# killed.
_DEFAULT_FINALIZER_TIMEOUT_SECONDS = 3600


def _repository_scheduling_identity(repo: Path) -> tuple[str, bool]:
    """Thin delegate to ``supervisor_identity._repository_scheduling_identity``."""
    return _identity_mod._repository_scheduling_identity(repo)


def _workspace_scheduling_identity(
    repo: Path,
    run_id: str,
    *,
    repository_key: str,
    repository_proven: bool,
) -> tuple[str, str, bool]:
    """Thin delegate to ``supervisor_identity._workspace_scheduling_identity``."""
    return _identity_mod._workspace_scheduling_identity(
        repo, run_id,
        repository_key=repository_key,
        repository_proven=repository_proven,
    )


def _packet_execution_mode(repo: Path, run_id: str) -> str:
    """Thin delegate to ``supervisor_identity._packet_execution_mode``."""
    return _identity_mod._packet_execution_mode(repo, run_id)


def _continuation_path(canonical_repo: Path, run_id: str, continuation_id: str) -> Path:
    return (
        state_mod.run_dir(canonical_repo, run_id)
        / "continuations"
        / f"{continuation_id}.json"
    )


def _continuation_id(run_id: str, checkpoint_id: str, candidate_sha: str, reason: str) -> str:
    # Canonical writer of continuation identity. Continuation-Authority
    # (`continuation_authority.derive_continuation_id`) must always agree
    # byte-for-byte with this hash so the dispatcher can reproduce the file
    # path when validating the durable ledger.
    return continuation_authority_mod.derive_continuation_id(
        run_id=run_id,
        checkpoint_id=checkpoint_id,
        candidate_sha=candidate_sha,
        reason=reason,
    )


def _continuation_read(path: Path) -> dict[str, Any] | None:
    value = util.read_private_json(path)
    return value if isinstance(value, dict) else None


def _continuation_write(path: Path, payload: dict[str, Any]) -> None:
    util.atomic_write_json(path, payload, mode=0o600)


def _continuation_conflict(
    repo_path: Path,
    run_id: str,
    *,
    checkpoint_id: str,
    candidate_sha: str,
    continuation_id: str,
    target_repair_round: int | None = None,
) -> bool:
    """Refuse only when ANOTHER funded continuation exists at the same
    (run, checkpoint, candidate, target_repair_round). Prior-round
    continuations are NOT a conflict — they record historical funding
    events that already played out and do not block new rounds. Without
    `target_repair_round`, fall back to the historical scope (any same
    (run, checkpoint, candidate) receipt in PENDING/FUNDED/QUEUED) for
    backwards compatibility.
    """
    directory = state_mod.run_dir(repo_path, run_id) / "continuations"
    if not directory.is_dir():
        return False
    for path in directory.glob("*.json"):
        if path.name == f"{continuation_id}.json":
            continue
        value = _continuation_read(path)
        if not isinstance(value, dict):
            return True
        if not (
            value.get("schema") == _CONTINUATION_SCHEMA
            and value.get("run_id") == run_id
            and value.get("checkpoint_id") == checkpoint_id
            and value.get("candidate_sha") == candidate_sha
            and value.get("status") in {"PENDING", "FUNDED", "QUEUED"}
        ):
            continue
        if target_repair_round is not None:
            before = value.get("before") or {}
            try:
                before_round = int(before.get("repair_round") or -1)
            except (TypeError, ValueError):
                before_round = -1
            # Same run/cp/candidate AND same pre-funding repair_round →
            # conflict. Different round → not a conflict. continue_program
            # captures current.repair_round into before.repair_round BEFORE
            # the eventual increment, so each funded round has a distinct
            # before.repair_round and never blocks its successor.
            if before_round != int(target_repair_round):
                continue
        return True
    return False


def _protected_terminal_recovery(
    *,
    canonical_repo: Path,
    run_id: str,
    packet: dict[str, Any],
    current_state: dict[str, Any],
    checkpoint_id: str,
    builder_worktree: Path,
    candidate_branch: str,
    candidate_sha: str,
) -> dict[str, Any] | None:
    """Recover a terminal protected-only candidate before re-funding a PROGRAM.

    This is the only continuation-specific source transition.  It is
    activated solely by a durable BUILD receipt proving that the terminal
    blocker was protected candidate drift without scope, secret, source-
    ceiling, or validation corruption.  The recovery primitive discards the
    entire candidate tree and returns a core-owned safe descendant.
    """
    path = state_mod.run_dir(canonical_repo, run_id) / "BUILD_RECEIPT.json"
    receipt = util.read_json(path, default=None)
    if not isinstance(receipt, dict):
        return None
    if str(receipt.get("next_state") or "") != "BLOCKED":
        return None
    protected = receipt.get("protected_path_check") or {}
    offending = protected.get("offending_paths") or []
    if str(protected.get("result") or "") != "fail" or not isinstance(offending, list) or not offending:
        return None
    for key in ("scope_check", "secret_scan_check", "program_source_check"):
        value = receipt.get(key) or {}
        if str(value.get("result") or "") == "fail":
            return None
    return protected_recovery.recover_candidate_only_protected_drift(
        canonical_repo=canonical_repo,
        run_id=run_id,
        packet=packet,
        current_state=current_state,
        checkpoint_id=checkpoint_id,
        builder_worktree=builder_worktree,
        candidate_branch=candidate_branch,
        candidate_sha=candidate_sha,
        offending_paths=[str(item) for item in offending],
    )


@_serialize_run_lifecycle
def continue_program(
    *,
    canonical_repo: Path,
    run_id: str,
    reason: str,
    expected_candidate_sha: str,
    db_path: Path | None = None,
) -> dict[str, Any]:
    """Continue one unfinished, blocked PROGRAM checkpoint safely.

    This public operator action is deliberately narrower than ``enqueue`` and
    ``resume``.  It consumes one protocol repair entitlement through the
    state owner, then reactivates the already-enrolled DONE ledger row without
    rebinding runtime, resetting the execution clock, or changing accounting.
    The private receipt makes the state/ledger boundary restart-safe.
    """
    state_mod.validate_run_id(run_id)
    repo_path = Path(canonical_repo).expanduser().resolve(strict=False)
    repo = str(repo_path)
    reason = str(reason or "").strip()
    expected_candidate_sha = str(expected_candidate_sha or "").strip().lower()
    if not reason:
        return {"schema": SCHEMA, "ok": False, "reason": "continuation_reason_required"}
    if not re.fullmatch(r"[0-9a-f]{40}", expected_candidate_sha):
        return {"schema": SCHEMA, "ok": False, "reason": "expected_candidate_sha_invalid"}
    db = db_path or default_db_path()

    with _managed_connect_readonly(db) as conn:
        job, lookup_reason = _logical_job_row(conn, repo_path, run_id)
        if job is None:
            return {
                "schema": SCHEMA, "ok": False, "reason": lookup_reason or "not_enqueued",
                "repo": repo, "run_id": run_id,
            }
        job = dict(job)

    if str(job.get("execution_mode") or "SINGLE").upper() != "PROGRAM":
        return {"schema": SCHEMA, "ok": False, "reason": "continuation_requires_program_mode"}
    if str(job.get("status") or "") not in {"DONE", "QUEUED"}:
        return {
            "schema": SCHEMA, "ok": False,
            "reason": "continuation_requires_done_or_queued_enrollment",
            "status": job.get("status"),
        }
    worker_pid = job.get("worker_pid")
    if worker_pid and _pid_alive(int(worker_pid), float(job.get("worker_started_at") or 0) or None):
        return {"schema": SCHEMA, "ok": False, "reason": "continuation_worker_still_alive"}

    packet_path = state_mod.run_dir(repo_path, run_id) / "WORK_PACKET.md"
    try:
        packet, _ = packet_mod.parse_packet_file(packet_path)
        current = state_mod.load_verified(repo_path, run_id)
    except Exception as exc:
        return {
            "schema": SCHEMA, "ok": False,
            "reason": "continuation_authority_unreadable",
            "error": f"{type(exc).__name__}: {exc}",
        }
    if str(packet.get("execution_mode") or "").lower() != "program":
        return {"schema": SCHEMA, "ok": False, "reason": "packet_is_not_program_mode"}
    if not isinstance(current, dict) or current.get("schema") != state_mod.PROGRAM_STATE_SCHEMA_VERSION:
        return {"schema": SCHEMA, "ok": False, "reason": "program_state_required"}
    program_state = current.get("program")
    if not isinstance(program_state, dict):
        return {"schema": SCHEMA, "ok": False, "reason": "program_state_missing"}
    checkpoint_id = program_mod.select_next_checkpoint(packet, program_state)
    if not checkpoint_id:
        return {"schema": SCHEMA, "ok": False, "reason": "no_unfinished_checkpoint"}
    continuation_id = _continuation_id(run_id, checkpoint_id, expected_candidate_sha, reason)
    receipt_path = _continuation_path(repo_path, run_id, continuation_id)
    receipt = _continuation_read(receipt_path)
    active_candidate_sha = expected_candidate_sha
    if isinstance(receipt, dict):
        recorded_active = str(receipt.get("active_candidate_sha") or "")
        if recorded_active:
            active_candidate_sha = recorded_active
    current_candidate_sha = str(current.get("last_candidate_sha") or "")
    if current_candidate_sha != expected_candidate_sha:
        if not (
            current.get("state") == _PROGRAM_READY_STATE
            and isinstance(receipt, dict)
            and receipt.get("candidate_sha") == expected_candidate_sha
            and receipt.get("active_candidate_sha") == current_candidate_sha
        ):
            return {"schema": SCHEMA, "ok": False, "reason": "candidate_sha_mismatch"}
    branch = str(job.get("candidate_branch") or "")
    if not branch:
        try:
            branch = branch_resolver_mod.resolve_candidate_branch(repo_path, run_id, packet=packet)
        except Exception as exc:
            return {"schema": SCHEMA, "ok": False, "reason": "candidate_branch_unresolved", "error": str(exc)}
    builder_path = util.builder_worktree(repo_path, run_id)
    if not builder_path.is_dir():
        return {"schema": SCHEMA, "ok": False, "reason": "builder_worktree_candidate_mismatch"}
    if git_checks.current_branch(builder_path) != branch:
        return {"schema": SCHEMA, "ok": False, "reason": "builder_worktree_branch_mismatch"}
    if current.get("state") == "BLOCKED" and active_candidate_sha == expected_candidate_sha:
        try:
            recovery = _protected_terminal_recovery(
                canonical_repo=repo_path,
                run_id=run_id,
                packet=packet,
                current_state=current,
                checkpoint_id=checkpoint_id,
                builder_worktree=builder_path,
                candidate_branch=branch,
                candidate_sha=expected_candidate_sha,
            )
        except protected_recovery.ProtectedDriftRecoveryError as exc:
            return {"schema": SCHEMA, "ok": False, "reason": "protected_drift_recovery_refused", "error": str(exc)}
        if recovery is not None:
            active_candidate_sha = str(recovery["candidate_sha"])
    if git_checks.branch_head(repo_path, branch) != active_candidate_sha:
        return {"schema": SCHEMA, "ok": False, "reason": "candidate_branch_head_mismatch", "candidate_branch": branch}
    if git_checks.current_head(builder_path) != active_candidate_sha:
        return {"schema": SCHEMA, "ok": False, "reason": "builder_worktree_candidate_mismatch"}
    cumulative_round = int(
        (((current.get("program") or {}).get("cumulative_counters") or {}).get(
            "repair_round_count"
        ) or 0)
    )
    pre_repair_round = int(current.get("repair_round") or 0)
    if _continuation_conflict(
        repo_path,
        run_id,
        checkpoint_id=checkpoint_id,
        candidate_sha=expected_candidate_sha,
        continuation_id=continuation_id,
        target_repair_round=pre_repair_round,
    ):
        return {"schema": SCHEMA, "ok": False, "reason": "continuation_receipt_conflict"}
    if current.get("state") == _PROGRAM_READY_STATE and receipt is None:
        return {"schema": SCHEMA, "ok": False, "reason": "continuation_receipt_missing"}
    before = {
        "build_pass_count": int(current.get("build_pass_count") or 0),
        "review_pass_count": int(current.get("review_pass_count") or 0),
        "repair_round": int(current.get("repair_round") or 0),
        "total_cost_usd": float(job.get("total_cost_usd") or 0),
        "total_input_tokens": int(job.get("total_input_tokens") or 0),
        "total_output_tokens": int(job.get("total_output_tokens") or 0),
        "total_cache_read_tokens": int(job.get("total_cache_read_tokens") or 0),
        "execution_started_at": job.get("execution_started_at"),
        "runtime_generation": str(job.get("runtime_generation") or ""),
    }
    receipt_before = receipt.get("before") if isinstance(receipt, dict) else None
    if receipt_before is not None and not isinstance(receipt_before, dict):
        return {"schema": SCHEMA, "ok": False, "reason": "continuation_receipt_conflict"}
    immutable_before = receipt_before if isinstance(receipt_before, dict) else before
    immutable = {
        "schema": _CONTINUATION_SCHEMA,
        "run_id": run_id,
        "checkpoint_id": checkpoint_id,
        "continuation_id": continuation_id,
        "candidate_sha": expected_candidate_sha,
        "active_candidate_sha": active_candidate_sha,
        "candidate_branch": branch,
        "reason": reason,
        "before": immutable_before,
    }
    immutable["active_candidate_sha"] = active_candidate_sha
    if receipt is None:
        if receipt_path.exists():
            return {"schema": SCHEMA, "ok": False, "reason": "continuation_receipt_invalid"}
        receipt = dict(immutable)
        receipt.update({"status": "PENDING", "created_at": util.utc_now_iso()})
        _continuation_write(receipt_path, receipt)
    else:
        for key in immutable:
            if receipt.get(key) != immutable[key]:
                return {"schema": SCHEMA, "ok": False, "reason": "continuation_receipt_conflict"}
        if receipt.get("status") not in {"PENDING", "FUNDED", "QUEUED"}:
            return {"schema": SCHEMA, "ok": False, "reason": "continuation_receipt_status_invalid"}
        if receipt.get("status") == "QUEUED" and str(job.get("status") or "") == "DONE":
            return {"schema": SCHEMA, "ok": False, "reason": "continuation_ledger_receipt_conflict"}
        before = immutable_before

    if current.get("state") == "BLOCKED":
        try:
            state_result = state_mod.continue_blocked_program(
                repo_path,
                run_id,
                packet=packet,
                actor="ofloop-operator-continuation",
                reason=reason,
                commit_sha=active_candidate_sha,
                expected_previous_candidate_sha=(
                    expected_candidate_sha
                    if active_candidate_sha != expected_candidate_sha else None
                ),
                continuation_id=continuation_id,
            )
        except (program_mod.ProgramStateError, transitions.InvalidTransitionError, ValueError) as exc:
            return {"schema": SCHEMA, "ok": False, "reason": "continuation_refused", "error": str(exc)}
    elif current.get("state") == _PROGRAM_READY_STATE:
        if receipt.get("status") not in {"PENDING", "FUNDED", "QUEUED"}:
            return {"schema": SCHEMA, "ok": False, "reason": "continuation_state_receipt_conflict"}
        state_result = {
            "ok": True, "continued": False, "idempotent": True,
            "state": _PROGRAM_READY_STATE, "checkpoint_id": checkpoint_id,
            "repair_round": int(current.get("repair_round") or 0),
            "cumulative_repair_round_count": int(
                program_state["cumulative_counters"].get("repair_round_count", 0)
            ),
        }
    else:
        return {"schema": SCHEMA, "ok": False, "reason": "continuation_requires_blocked_program_state", "state": current.get("state")}

    current_after = state_mod.load_verified(repo_path, run_id)
    after = {
        "build_pass_count": int(current_after.get("build_pass_count") or 0),
        "review_pass_count": int(current_after.get("review_pass_count") or 0),
        "repair_round": int(current_after.get("repair_round") or 0),
        "cumulative_repair_round_count": int(
            (current_after.get("program") or {}).get("cumulative_counters", {}).get("repair_round_count", 0)
        ),
    }
    receipt.update({"status": "FUNDED", "funded_at": receipt.get("funded_at") or util.utc_now_iso(), "after": after})
    _continuation_write(receipt_path, receipt)

    with _managed_connect(db) as conn:
        conn.execute("BEGIN IMMEDIATE")
        row = conn.execute("SELECT * FROM jobs WHERE id=?", (int(job["id"]),)).fetchone()
        if row is None:
            return {"schema": SCHEMA, "ok": False, "reason": "enrollment_disappeared"}
        if str(row["status"] or "") == "DONE":
            cur = conn.execute(
                "UPDATE jobs SET status='QUEUED', next_attempt_at=0, updated_at=? WHERE id=? AND status='DONE'",
                (time.time(), int(row["id"])),
            )
            if cur.rowcount != 1:
                row = conn.execute("SELECT * FROM jobs WHERE id=?", (int(row["id"]),)).fetchone()
                if row is None or str(row["status"] or "") != "QUEUED":
                    return {"schema": SCHEMA, "ok": False, "reason": "continuation_ledger_race"}
        elif str(row["status"] or "") != "QUEUED":
            return {"schema": SCHEMA, "ok": False, "reason": "continuation_ledger_state_conflict", "status": row["status"]}
        row = conn.execute("SELECT * FROM jobs WHERE id=?", (int(row["id"]),)).fetchone()
    receipt.update({"status": "QUEUED", "queued_at": receipt.get("queued_at") or util.utc_now_iso()})
    _continuation_write(receipt_path, receipt)
    out = _job_dict(row, db)
    out.update({
        "continuation": {
            "id": continuation_id,
            "checkpoint_id": checkpoint_id,
            "state": state_result,
            "repair_round_before": before["repair_round"],
            "repair_round_after": after["repair_round"],
            "cumulative_repair_round_before": before["repair_round"],
            "cumulative_repair_round_after": after["cumulative_repair_round_count"],
            "receipt": str(receipt_path),
        }
    })
    return out


def _validate_max_concurrency(value: Any) -> int:
    """Thin delegate to ``supervisor_db._validate_max_concurrency``."""
    return _db_mod._validate_max_concurrency(value)


def _apply_data_migrations(conn: sqlite3.Connection) -> None:
    """Versioned migrations; ambiguous historical limits are never rewritten."""
    version = int(conn.execute("PRAGMA user_version").fetchone()[0])
    if version < 3:
        conn.execute(
            """UPDATE jobs
               SET legacy_budget_ambiguous=1
               WHERE max_total_cost_usd=? AND max_total_tokens=?
                 AND max_wall_seconds=?""",
            _LEGACY_BUDGET_DEFAULT_FINGERPRINT,
        )
        conn.execute("PRAGMA user_version = 3")
        version = 3
    if version < 5:
        conn.execute("PRAGMA user_version = 5")
        version = 5
    if version < 6:
        # v0.9 scheduler metadata is operational authority for unfinished jobs.
        # Reconstruct it exactly once from local repository/packet truth instead
        # of paying for Git identity probes on every SQLite connection.
        rows = conn.execute(
            """SELECT id, repo, run_id, status
                 FROM jobs"""
        ).fetchall()
        for row in rows:
            status_value = str(row["status"] or "")
            if status_value in {"DONE", "RETIRED"}:
                continue
            repo = Path(str(row["repo"] or "")).expanduser().resolve(strict=False)
            if not repo.exists():
                # Unfinished work whose repository disappeared remains
                # identity-unproven and therefore cannot be scheduled.
                conn.execute(
                    "UPDATE jobs SET repository_identity_proven=0 WHERE id=?",
                    (int(row["id"]),),
                )
                continue
            key, proven = _repository_scheduling_identity(repo)
            mode = _packet_execution_mode(repo, str(row["run_id"]))
            conn.execute(
                """UPDATE jobs
                      SET repository_scheduling_key=?,
                          repository_identity_proven=?,
                          execution_mode=?
                    WHERE id=?""",
                (key, int(proven), mode, int(row["id"])),
            )
        conn.execute("PRAGMA user_version = 6")
        version = 6
        conn.commit()
    if version < 7:
        rows = conn.execute(
            """SELECT id, repo, run_id, status,
                      repository_scheduling_key, repository_identity_proven
                 FROM jobs"""
        ).fetchall()
        for row in rows:
            if str(row["status"] or "") in {"DONE", "RETIRED"}:
                continue
            repo = Path(str(row["repo"] or "")).expanduser().resolve(strict=False)
            if not repo.exists():
                conn.execute(
                    """UPDATE jobs
                          SET repository_identity_proven=0,
                              workspace_identity_proven=0
                        WHERE id=?""",
                    (int(row["id"]),),
                )
                continue
            repository_key = str(row["repository_scheduling_key"] or "")
            repository_proven = bool(int(row["repository_identity_proven"] or 0))
            if not repository_key or not repository_proven:
                repository_key, repository_proven = _repository_scheduling_identity(repo)
            candidate_branch, workspace_key, workspace_proven = _workspace_scheduling_identity(
                repo, str(row["run_id"]), repository_key=repository_key,
                repository_proven=repository_proven,
            )
            conn.execute(
                """UPDATE jobs
                      SET repository_scheduling_key=?, repository_identity_proven=?,
                          candidate_branch=?, workspace_scheduling_key=?,
                          workspace_identity_proven=?
                    WHERE id=?""",
                (repository_key, int(repository_proven), candidate_branch,
                 workspace_key, int(workspace_proven), int(row["id"])),
            )
        conn.execute(f"PRAGMA user_version = {SCHEMA_DATA_VERSION}")
        conn.commit()

def _connect(path: Path) -> sqlite3.Connection:
    """Thin delegate to ``supervisor_db._connect``.

    The canonical connection bootstrap (file-mode protection,
    schema CREATE TABLE statements, column migrations, config-row
    priming, ``PRAGMA journal_mode=WAL`` /
    ``PRAGMA synchronous=FULL``) lives in ``supervisor_db``.  This
    delegate wires the supervisor-owned data-migration callable
    (``_apply_data_migrations``) through the explicit
    ``data_migrations`` seam so the DB owner never imports this
    module.
    """
    return _db_mod._connect(path, data_migrations=_apply_data_migrations)



@contextmanager
def _managed_connect(path: Path):
    """Thin delegate to ``supervisor_db._managed_connect``.

    The context-manager wrapper (commit/rollback + close +
    per-thread depth tracking) lives in ``supervisor_db``.  This
    delegate threads the supervisor-owned data-migration callable
    through the same ``data_migrations`` seam as ``_connect`` so
    the two stay in lockstep.  It also keeps a parallel
    per-thread depth counter so that when the DB-level depth
    returns to zero the supervisor can clear its own
    ``_LOCAL_EXECUTION_JOBS`` for the thread — this preserves
    the historical coupling between connection lifecycle and
    per-thread execution ownership.
    """
    tid = threading.get_ident()
    with _LOCAL_EXECUTION_LOCK:
        _LOCAL_CONNECTION_DEPTH_SUPERVISOR[tid] = (
            _LOCAL_CONNECTION_DEPTH_SUPERVISOR.get(tid, 0) + 1
        )
    try:
        with _db_mod._managed_connect(
            path, data_migrations=_apply_data_migrations
        ) as conn:
            yield conn
    finally:
        with _LOCAL_EXECUTION_LOCK:
            remaining = _LOCAL_CONNECTION_DEPTH_SUPERVISOR.get(tid, 1) - 1
            if remaining <= 0:
                _LOCAL_CONNECTION_DEPTH_SUPERVISOR.pop(tid, None)
                _LOCAL_EXECUTION_JOBS.pop(tid, None)
            else:
                _LOCAL_CONNECTION_DEPTH_SUPERVISOR[tid] = remaining


def _connect_readonly(path: Path) -> sqlite3.Connection:
    """Thin delegate to ``supervisor_db._connect_readonly``."""
    return _db_mod._connect_readonly(path)


@contextmanager
def _managed_connect_readonly(path: Path):
    """Thin delegate to ``supervisor_db._managed_connect_readonly``."""
    with _db_mod._managed_connect_readonly(path) as conn:
        yield conn


def _pid_alive(pid: int | None, worker_started_at: float | None = None) -> bool:
    return _process_mod._pid_alive(pid, worker_started_at)


def _read_pid_start_identity(pid: int) -> str | None:
    return _process_mod._read_pid_start_identity(pid)


def _pid_identity_proven(pid: int | None, expected_identity: str | None) -> bool:
    return _process_mod._pid_identity_proven(pid, expected_identity)


def _terminate_owned_process_group(pid: int, pgid: int | None, expected_identity: str | None, worker_started_at: float | None) -> bool:
    return _process_mod._terminate_owned_process_group(pid, pgid, expected_identity, worker_started_at)


def _progress_watchdog_tick(db_path: Path) -> dict[str, int]:
    """Run one bounded no-progress watchdog tick.

    Fail-closed: write errors return an empty summary rather than
    triggering an exception in the supervisor's main loop.
    """
    try:
        with _managed_connect(db_path) as conn:
            return _watchdog_mod.tick(
                conn,
                terminate=_terminate_owned_process_group,
            )
    except (OSError, sqlite3.Error):
        return {"considered": 0, "advanced": 0, "terminated": 0, "skipped": 0}


def _read_pid_start_time(pid: int) -> float | None:
    return _process_mod._read_pid_start_time(pid)


_BOOT_TIME_CACHE: float | None = None


def _boot_time_unix() -> float | None:
    return _process_mod._boot_time_unix()


def _parse_cost_from_durable_stdout(path: str | None) -> float | None:
    # thin delegation: canonical implementation lives in
    # supervisor_accounting.py.
    from . import supervisor_accounting as _accounting_mod
    return _accounting_mod.parse_cost_from_durable_stdout(path)


def _parse_token_usage_from_durable_stdout(path: str | None) -> dict[str, int] | None:
    # thin delegation: canonical implementation lives in
    # supervisor_accounting.py.
    from . import supervisor_accounting as _accounting_mod
    return _accounting_mod.parse_token_usage_from_durable_stdout(path)


def _durable_envelope_payload(path: str | None) -> dict[str, Any] | None:
    from . import supervisor_accounting as _accounting_mod
    return _accounting_mod._durable_envelope_payload(path)


def _extract_effective_model_from_durable_stdout(path: str | None) -> str:
    from . import supervisor_accounting as _accounting_mod
    return _accounting_mod.extract_effective_model_from_durable_stdout(path)


def _extract_model_usage_json_from_durable_stdout(path: str | None) -> str:
    from . import supervisor_accounting as _accounting_mod
    return _accounting_mod.extract_model_usage_json_from_durable_stdout(path)


def _extract_effective_model(payload: dict[str, Any] | None) -> str:
    from . import supervisor_accounting as _accounting_mod
    return _accounting_mod.extract_effective_model(payload)


def _extract_model_usage_json(payload: dict[str, Any] | None) -> str:
    from . import supervisor_accounting as _accounting_mod
    return _accounting_mod.extract_model_usage_json(payload)


def _strict_profile_model_violation(
    requested_model: str, *, result_ok: bool, effective_model: str
) -> str:
    from . import supervisor_accounting as _accounting_mod
    return _accounting_mod.strict_profile_model_violation(
        requested_model, result_ok=result_ok, effective_model=effective_model,
    )


def _replay_candidate_sha(
    *,
    role: str,
    work_order: dict[str, Any],
    repo: str,
    run_id: str,
) -> str:
    """Thin delegate to ``supervisor_attempts._replay_candidate_sha``."""
    return _attempts_mod._replay_candidate_sha(
        role=role, work_order=work_order, repo=repo, run_id=run_id
    )


def _attempt_provenance_gate(
    conn: sqlite3.Connection,
    *,
    job: sqlite3.Row,
    work_order: dict[str, Any],
    attempt_id: str,
) -> tuple[bool, str, dict[str, Any] | None]:
    """Thin delegate to ``supervisor_attempts._attempt_provenance_gate``."""
    return _attempts_mod._attempt_provenance_gate(
        conn, job=job, work_order=work_order, attempt_id=attempt_id
    )




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
) -> float | None:
    """Thin delegate to ``supervisor_attempts._account_attempt_cost``."""
    return _attempts_mod._account_attempt_cost(
        conn,
        job_id=job_id,
        attempt_id=attempt_id,
        cost_usd=cost_usd,
        returncode=returncode,
        status_value=status_value,
        cost_known=cost_known,
        input_tokens=input_tokens,
        output_tokens=output_tokens,
        cache_read_tokens=cache_read_tokens,
        cache_creation_tokens=cache_creation_tokens,
        tokens_known=tokens_known,
        manage_transaction=manage_transaction,
        effective_model=effective_model,
        model_usage_json=model_usage_json,
    )


def _publish_semantic_acceptance(
    conn: sqlite3.Connection,
    *,
    job_id: int,
    attempt_id: str,
    semantic_path: Path,
    candidate_sha: str,
) -> None:
    """Thin delegate to ``supervisor_attempts._publish_semantic_acceptance``."""
    _attempts_mod._publish_semantic_acceptance(
        conn,
        job_id=job_id,
        attempt_id=attempt_id,
        semantic_path=semantic_path,
        candidate_sha=candidate_sha,
    )


def _remaining_funded_cost_budget(max_total_cost_usd: float, spent_cost_usd: float) -> float | None:
    """Thin delegate to ``supervisor_attempts._remaining_funded_cost_budget``."""
    return _attempts_mod._remaining_funded_cost_budget(
        max_total_cost_usd, spent_cost_usd
    )


def _unknown_cost_attempt_count(conn: sqlite3.Connection, job_id: int) -> int:
    """Thin delegate to ``supervisor_attempts._unknown_cost_attempt_count``."""
    return _attempts_mod._unknown_cost_attempt_count(conn, job_id)


PRE_PROVIDER_FAILURE_REASONS = _attempts_mod.PRE_PROVIDER_FAILURE_REASONS


def _capability_binding_creation_allowed(
    conn: sqlite3.Connection,
    job_id: int,
) -> bool:
    return _attempts_mod._capability_binding_creation_allowed(conn, job_id)


def _mark_attempt_launch_failed(
    conn: sqlite3.Connection,
    *,
    job_id: int,
    attempt_id: str,
    detail: str,
    failure_reason: str = "worker_launch_failed",
) -> None:
    _attempts_mod._mark_attempt_launch_failed(
        conn,
        job_id=job_id,
        attempt_id=attempt_id,
        detail=detail,
        failure_reason=failure_reason,
    )


_RECOVERY_OWNERSHIP_FIELDS = _recovery_mod._RECOVERY_OWNERSHIP_FIELDS


def _recovery_ownership_matches(
    current: sqlite3.Row | None,
    observed: sqlite3.Row,
) -> bool:
    """Thin delegate to ``supervisor_recovery._recovery_ownership_matches``."""
    return _recovery_mod._recovery_ownership_matches(current, observed)


def _recover_stale_running(conn: sqlite3.Connection) -> int:
    """Thin delegate to ``supervisor_recovery._recover_stale_running``."""
    return _recovery_mod._recover_stale_running(conn)


def _validate_dispatch_hold_request(
    kind: str | None,
    previous_checkpoint_id: str | None,
    next_checkpoint_id: str | None,
) -> None:
    """Thin delegate to ``supervisor_holds._validate_dispatch_hold_request``."""
    return _holds_mod._validate_dispatch_hold_request(
        kind, previous_checkpoint_id, next_checkpoint_id
    )


def _hold_row(conn: sqlite3.Connection, job_id: int) -> sqlite3.Row | None:
    """Thin delegate to ``supervisor_holds._hold_row``."""
    return _holds_mod._hold_row(conn, job_id)


def _hold_dict(row: sqlite3.Row | None) -> dict[str, Any] | None:
    """Thin delegate to ``supervisor_holds._hold_dict``."""
    return _holds_mod._hold_dict(row)


def _hold_matches_before_claim(
    conn: sqlite3.Connection,
    row: sqlite3.Row,
) -> tuple[sqlite3.Row | None, str]:
    """Thin delegate to ``supervisor_holds._hold_matches_before_claim``."""
    return _holds_mod._hold_matches_before_claim(conn, row)


@_serialize_run_lifecycle
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
    """Thin delegate to ``supervisor_claims.enqueue``."""
    return _claims_mod.enqueue(
        canonical_repo=canonical_repo,
        run_id=run_id,
        runner=runner,
        db_path=db_path,
        max_infra_failures=max_infra_failures,
        max_transient_failures=max_transient_failures,
        max_transient_recovery_cycles=max_transient_recovery_cycles,
        max_total_cost_usd=max_total_cost_usd,
        max_total_tokens=max_total_tokens,
        max_wall_seconds=max_wall_seconds,
        runtime_generation=runtime_generation,
        dispatch_hold_kind=dispatch_hold_kind,
        dispatch_hold_previous_checkpoint_id=dispatch_hold_previous_checkpoint_id,
        dispatch_hold_next_checkpoint_id=dispatch_hold_next_checkpoint_id,
    )


def _logical_job_row(
    conn: sqlite3.Connection,
    canonical_repo: Path,
    run_id: str,
) -> tuple[sqlite3.Row | None, str | None]:
    """Thin delegate to ``supervisor_db._logical_job_row``."""
    return _db_mod._logical_job_row(conn, canonical_repo, run_id)

def status(
    *,
    canonical_repo: Path,
    run_id: str,
    db_path: Path | None = None,
) -> dict[str, Any]:
    """Thin delegate to ``supervisor_readmodel.status``."""
    return _readmodel_mod.status(
        canonical_repo=canonical_repo, run_id=run_id, db_path=db_path
    )


def _readonly_columns(conn: sqlite3.Connection, table: str) -> set[str]:
    """Thin delegate to ``supervisor_readmodel._readonly_columns``."""
    return _readmodel_mod._readonly_columns(conn, table)


def _legacy_readonly_fleet_projection(
    conn: sqlite3.Connection, db: Path
) -> dict[str, Any]:
    """Thin delegate to ``supervisor_readmodel._legacy_readonly_fleet_projection``."""
    return _readmodel_mod._legacy_readonly_fleet_projection(conn, db)

def supervisor_config_get(*, db_path: Path | None = None) -> dict[str, Any]:
    """Thin delegate to ``supervisor_readmodel.supervisor_config_get``."""
    return _readmodel_mod.supervisor_config_get(db_path=db_path)


def supervisor_config_set(*, max_concurrency: Any, db_path: Path | None = None) -> dict[str, Any]:
    """Persist the bounded operational execution capacity."""
    from . import supervisor_operator as _operator_mod
    return _operator_mod.supervisor_config_set(
        max_concurrency=max_concurrency, db_path=db_path
    )


def fleet_status(*, db_path: Path | None = None) -> dict[str, Any]:
    """Thin delegate to ``supervisor_readmodel.fleet_status``."""
    return _readmodel_mod.fleet_status(db_path=db_path)


def dispatch_hold_status(
    *,
    canonical_repo: Path,
    run_id: str,
    hold_id: str | None = None,
    db_path: Path | None = None,
) -> dict[str, Any]:
    """Read-only operator view of one (or the active) dispatch hold."""
    return _holds_mod.dispatch_hold_status(
        canonical_repo=canonical_repo,
        run_id=run_id,
        hold_id=hold_id,
        db_path=db_path,
    )


def release_dispatch_hold(
    *,
    canonical_repo: Path,
    run_id: str,
    hold_id: str,
    db_path: Path | None = None,
) -> dict[str, Any]:
    """Release one HELD dispatch hold (idempotent on already-RELEASED)."""
    return _holds_mod.release_dispatch_hold(
        canonical_repo=canonical_repo,
        run_id=run_id,
        hold_id=hold_id,
        db_path=db_path,
    )


def cancel_dispatch_hold(
    *,
    canonical_repo: Path,
    run_id: str,
    hold_id: str,
    db_path: Path | None = None,
) -> dict[str, Any]:
    """Cancel one ARMED/HELD dispatch hold (refuses RELEASED)."""
    return _holds_mod.cancel_dispatch_hold(
        canonical_repo=canonical_repo,
        run_id=run_id,
        hold_id=hold_id,
        db_path=db_path,
    )


def _run_git_readonly(repo: Path, args: list[str], *, timeout: int = 10) -> dict[str, Any]:
    """Thin delegate to ``supervisor_readmodel._run_git_readonly``."""
    return _readmodel_mod._run_git_readonly(repo, args, timeout=timeout)


def _registered_worktree_paths(repo: Path) -> tuple[set[str], str | None]:
    """Thin delegate to ``supervisor_readmodel._registered_worktree_paths``."""
    return _readmodel_mod._registered_worktree_paths(repo)


def _worktree_visibility(
    canonical_repo: Path,
    path: Path,
    *,
    registered_paths: set[str],
    registry_error: str | None,
) -> dict[str, Any]:
    """Thin delegate to ``supervisor_readmodel._worktree_visibility``."""
    return _readmodel_mod._worktree_visibility(
        canonical_repo,
        path,
        registered_paths=registered_paths,
        registry_error=registry_error,
    )


def _candidate_diff_visibility(
    canonical_repo: Path,
    *,
    baseline_sha: str,
    candidate_sha: str,
    max_paths: int = 100,
) -> dict[str, Any]:
    """Thin delegate to ``supervisor_readmodel._candidate_diff_visibility``."""
    return _readmodel_mod._candidate_diff_visibility(
        canonical_repo,
        baseline_sha=baseline_sha,
        candidate_sha=candidate_sha,
        max_paths=max_paths,
    )


def _core_snapshot(repo: Path, run_id: str) -> dict[str, Any]:
    """Thin delegate to ``supervisor_readmodel._core_snapshot``."""
    return _readmodel_mod._core_snapshot(repo, run_id)

def _job_dict(row: sqlite3.Row, db: Path) -> dict[str, Any]:
    """Thin delegate to ``supervisor_readmodel._job_dict``."""
    return _readmodel_mod._job_dict(row, db)


def _source_root() -> Path:
    return _prompts_mod._source_root()


def _load_role_prompt(role: str) -> str:
    return _prompts_mod._load_role_prompt(role)


def _write_semantic_prompt_provenance(**kwargs):
    return _prompts_mod._write_semantic_prompt_provenance(**kwargs)


def _terminate_group(proc: subprocess.Popen[str], grace_seconds: float = 3.0) -> None:
    _runner_mod._terminate_group(proc, grace_seconds)


# RunnerResult / RunnerReadiness are owned by supervisor_runner_registry
# so the runner contract lives in one place.  Import them now so
# downstream code in this module uses the canonical classes, not a
# duplicate.  Existing call sites that reference
# ``supervisor.RunnerResult`` / ``supervisor.RunnerReadiness`` keep
# working because the supervisor module re-exports the same class
# objects via the post-import assignment below.
RunnerResult = _runner_registry_mod.RunnerResult
RunnerReadiness = _runner_registry_mod.RunnerReadiness


ClaudeCodeRunner = _runner_mod.ClaudeCodeRunner


# Vendor-neutral runner registry.  The canonical implementation lives
# in supervisor_runner_registry.py so the registry's authority is
# explicit (this module owns the runner contract; this module also
# owns ClaudeCodeRunner itself).  We re-export the registry
# internals here so existing call sites within supervisor.py keep
# working without an import-site rewrite.
from . import supervisor_runner_registry as _runner_registry_mod
_RUNNER_REGISTRY = _runner_registry_mod._RUNNER_REGISTRY


def register_runner(cls: type) -> type:
    return _runner_registry_mod.register_runner(cls)


def registered_runner_ids() -> tuple[str, ...]:
    return _runner_registry_mod.registered_runner_ids()


def _runner(name: str):
    return _runner_registry_mod.get_runner(name)


def _runner_preflight(name: str) -> RunnerReadiness:
    return _runner_registry_mod.runner_preflight(name)


_RegisteredClaudeCodeRunner = _runner_mod._RegisteredClaudeCodeRunner


def _classify_runner_failure(result: RunnerResult) -> tuple[str, str]:
    return _runner_mod._classify_runner_failure(result)


def _classify_exception(exc: BaseException) -> tuple[str, str, str]:
    return _runner_mod._classify_exception(exc)


def _apply_failure_policy(
    conn: sqlite3.Connection,
    *,
    job_id: int,
    failure_class: str,
    failure_reason: str,
    detail: str,
    total_cost_usd: float | None = None,
) -> dict[str, Any]:
    return _recovery_mod._apply_failure_policy(
        conn,
        job_id=job_id,
        failure_class=failure_class,
        failure_reason=failure_reason,
        detail=detail,
        total_cost_usd=total_cost_usd,
    )


def _take_next_job(conn: sqlite3.Connection) -> sqlite3.Row | None:
    """Thin delegate to ``supervisor_claims._take_next_job``."""
    return _claims_mod._take_next_job(conn)


def _reserve_semantic_attempt(
    conn: sqlite3.Connection,
    *,
    job: sqlite3.Row,
    role: str,
) -> tuple[str, dict[str, Any]]:
    """Thin delegate to ``supervisor_attempts._reserve_semantic_attempt``."""
    return _attempts_mod._reserve_semantic_attempt(conn, job=job, role=role)


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
    max_pass_runtime_seconds: int | None = None,
) -> None:
    """Thin delegate to ``supervisor_attempts._set_worker_pid``."""
    _attempts_mod._set_worker_pid(
        conn, job_id, pid, role,
        out_path=out_path, err_path=err_path,
        attempt_id=attempt_id, deadline_at=deadline_at,
        max_pass_runtime_seconds=max_pass_runtime_seconds,
    )


def _update_job(
    conn: sqlite3.Connection,
    job_id: int,
    *,
    status_value: str,
    infra_failures: int | None = None,
    transient_failures: int | None = None,
    transient_recovery_cycles: int | None = None,
    total_cost_usd: float | None = None,
    last_error: str | None = None,
    last_failure_class: str | None = None,
    last_failure_reason: str | None = None,
    next_attempt_at: float | None = None,
) -> None:
    """Thin delegate to ``supervisor_db._update_job``.

    ``_update_job`` is the generic durable job-state transition
    primitive.  Canonical owner is ``supervisor_db`` (DB layer);
    the supervisor facade re-exports it for backward compatibility.
    """
    _db_mod._update_job(
        conn,
        job_id,
        status_value=status_value,
        infra_failures=infra_failures,
        transient_failures=transient_failures,
        transient_recovery_cycles=transient_recovery_cycles,
        total_cost_usd=total_cost_usd,
        last_error=last_error,
        last_failure_class=last_failure_class,
        last_failure_reason=last_failure_reason,
        next_attempt_at=next_attempt_at,
    )


def _ensure_execution_started(conn: sqlite3.Connection, job_id: int) -> float:
    """Thin delegate to ``supervisor_attempts._ensure_execution_started``."""
    return _attempts_mod._ensure_execution_started(conn, job_id)


def _maybe_complete_semantic_artifact(
    *,
    conn: sqlite3.Connection,
    work_order: dict[str, Any],
    semantic_reason: str,
    job_id: int,
) -> bool:
    """Thin delegate to ``supervisor_attempts._maybe_complete_semantic_artifact``."""
    return _attempts_mod._maybe_complete_semantic_artifact(
        conn=conn, work_order=work_order,
        semantic_reason=semantic_reason, job_id=job_id,
    )


def _publish_acceptance_for_ready_artifact(
    *,
    conn: sqlite3.Connection,
    work_order: dict[str, Any],
    job_id: int,
) -> None:
    """Thin delegate to ``supervisor_attempts._publish_acceptance_for_ready_artifact``."""
    _attempts_mod._publish_acceptance_for_ready_artifact(
        conn=conn, work_order=work_order, job_id=job_id,
    )


def run_one(*, db_path: Path | None = None, timeout_seconds: int = 0) -> dict[str, Any]:
    """Execute at most one semantic BUILD/REVIEW action."""
    db = db_path or default_db_path()
    with _managed_connect(db) as conn:
        from . import supervisor_claims as _claims_mod
        job = _claims_mod._take_next_job(conn)
        if job is None:
            return {"schema": SCHEMA, "ok": True, "action": "IDLE", "db_path": str(db)}

        _register_local_execution(int(job["id"]))

        # RUNTIME-GENERATION CONTRACT. A job binds the generation that
        # enrolled it; executing it under a different generation is a
        # silent runtime switch of a sealed run and fails closed toward
        # quarantine. Legacy rows with no recorded binding are ambiguous
        # unfinished executions and fail closed; migration to a new generation
        # is an explicit operator act: re-enqueue or resume.
        bound_generation = str(job["runtime_generation"] or "")
        try:
            serving_generation = _current_runtime_generation()
        except Exception as exc:
            _update_job(
                conn,
                job["id"],
                status_value="QUARANTINED",
                last_error=(
                    "serving runtime generation could not be proven; refusing "
                    f"semantic execution: {type(exc).__name__}: {exc}"
                ),
                last_failure_class="runtime_generation_unavailable",
                last_failure_reason="runtime_generation_unavailable",
                next_attempt_at=0,
            )
            return {
                "schema": SCHEMA,
                "ok": False,
                "action": "QUARANTINED",
                "job_id": job["id"],
                "reason": "runtime_generation_unavailable",
                "bound_runtime_generation": bound_generation,
            }
        if bound_generation and bound_generation != serving_generation:
            _update_job(
                conn,
                job["id"],
                status_value="QUARANTINED",
                last_error=(
                    "runtime generation mismatch: job bound to "
                    f"{bound_generation}, serving runtime is "
                    f"{serving_generation}; refusing silent generation "
                    "switch — operator migration required "
                    "(supervisor resume rebinds the run)"
                ),
                last_failure_class="runtime_generation_mismatch",
                last_failure_reason="runtime_generation_mismatch",
                next_attempt_at=0,
            )
            return {
                "schema": SCHEMA,
                "ok": False,
                "action": "QUARANTINED",
                "job_id": job["id"],
                "reason": "runtime_generation_mismatch",
                "bound_runtime_generation": bound_generation,
                "serving_runtime_generation": serving_generation,
            }
        if not bound_generation:
            _update_job(
                conn,
                job["id"],
                status_value="QUARANTINED",
                last_error=(
                    "runtime generation is unbound for an unfinished legacy job; "
                    "refusing implicit adoption under a new serving runtime — "
                    "operator re-enqueue/resume is required"
                ),
                last_failure_class="runtime_generation_unbound",
                last_failure_reason="runtime_generation_unbound",
                next_attempt_at=0,
            )
            return {
                "schema": SCHEMA,
                "ok": False,
                "action": "QUARANTINED",
                "job_id": job["id"],
                "reason": "runtime_generation_unbound",
                "bound_runtime_generation": "",
                "serving_runtime_generation": serving_generation,
            }

        attempt_id: str | None = None
        try:
            work_order = dispatch_mod.claim_next(
                canonical_repo=Path(job["repo"]),
                run_id=str(job["run_id"]),
            )
            decision = str(work_order.get("decision") or "")
            if decision == "TERMINAL":
                _update_job(conn, job["id"], status_value="DONE", last_error=None)
                cache_cleanup = _cleanup_terminal_runtime_cache(
                    Path(job["repo"]), str(job["run_id"])
                )
                return {
                    "schema": SCHEMA,
                    "ok": True,
                    "action": "TERMINAL",
                    "job_id": job["id"],
                    "work_order": work_order,
                    "runtime_cache_cleanup": cache_cleanup,
                }
            if decision == "WAIT":
                # Bounded next-attempt delay so a recurring WAIT cannot
                # busy-spin the durable execution clock. The delay is short
                # (5s default) to remain responsive to genuine transitions
                # but long enough that a continuously-WAIT run does not
                # spam the supervisor stdout with IDLE/WAIT events.
                wait_seconds = 5.0
                _update_job(
                    conn,
                    job["id"],
                    status_value="QUEUED",
                    last_error=None,
                    next_attempt_at=time.time() + wait_seconds,
                )
                return {
                    "schema": SCHEMA,
                    "ok": True,
                    "action": "WAIT",
                    "job_id": job["id"],
                    "wait_seconds": wait_seconds,
                    "work_order": work_order,
                }

            semantic_ready, semantic_reason = dispatch_mod.semantic_result_ready(
                work_order
            )
            if not semantic_ready:
                # v0.9.9-h: deterministic semantic-result completion recovery.
                #
                # When a paid semantic pass exits with the engineering work
                # already durably complete (clean worktree, candidate HEAD
                # exists on the right branch, all fixed-identity fields intact)
                # but the typed JSON contract is still unpopulated, the
                # core fills the deterministic fillable fields itself rather
                # than burning another full provider call to redo engineering
                # that already exists.
                completed = _maybe_complete_semantic_artifact(
                    conn=conn, work_order=work_order, semantic_reason=semantic_reason,
                    job_id=int(job["id"]),
                )
                if completed:
                    # v0.9.9-h: completion also publishes the latest
                    # attempt's `semantic_accepted` flag inside
                    # `_maybe_complete_semantic_artifact` so the
                    # provenance gate below recognizes the zero-cost
                    # replay as the durable accepted artifact.
                    semantic_ready, semantic_reason = dispatch_mod.semantic_result_ready(work_order)
            if semantic_ready:
                # v0.9.9-h: when the artifact is already valid (either
                # because completion filled it, or because a prior tick
                # already completed it but acceptance was not yet
                # published), make sure the latest attempt's
                # `semantic_accepted` flag is recorded before the gate
                # inspects it. Best-effort: any publish failure is
                # surfaced by the gate's structured replay rejection.
                _publish_acceptance_for_ready_artifact(
                    conn=conn, work_order=work_order, job_id=int(job["id"]),
                )
                replay_attempt_id = str(job["latest_attempt_id"] or "")
                replay_ok, replay_reason, _receipt = _attempt_provenance_gate(
                    conn,
                    job=job,
                    work_order=work_order,
                    attempt_id=replay_attempt_id,
                )
                if not replay_ok:
                    _update_job(
                        conn,
                        job["id"],
                        status_value="QUARANTINED",
                        last_error=(
                            "semantic artifact exists but its durable launch "
                            f"provenance cannot be certified: {replay_reason}"
                        ),
                        last_failure_class="replay_provenance",
                        last_failure_reason=replay_reason,
                        next_attempt_at=0,
                    )
                    return {
                        "schema": SCHEMA,
                        "ok": False,
                        "action": "QUARANTINED",
                        "job_id": job["id"],
                        "reason": replay_reason,
                        "semantic_replay": True,
                    }
                finalized = dispatch_mod.finalize_work_order(work_order)
                _update_job(
                    conn,
                    job["id"],
                    status_value="QUEUED",
                    infra_failures=0,
                    transient_failures=0,
                    transient_recovery_cycles=0,
                    last_error=None,
                    last_failure_class=None,
                    last_failure_reason=None,
                    next_attempt_at=0,
                )
                return {
                    "schema": SCHEMA,
                    "ok": True,
                    "action": f"{decision}_REPLAY_FINALIZED",
                    "job_id": job["id"],
                    "cost_usd": 0.0,
                    "semantic_replay": True,
                    "finalized": finalized,
                }

            # A retryable semantic-shape failure belongs to the same claimed
            # engineering pass, but its model-authored envelope is poisoned.
            # Preserve that envelope privately and reseed the exact same
            # canonical path before launching a fresh provider process. Resume
            # intentionally clears operational error fields, so consult the
            # durable prior attempt row as well as the job projection.
            prior_attempt_id = str(job["latest_attempt_id"] or "")
            prior_attempt_reason = ""
            if prior_attempt_id:
                prior_attempt = conn.execute(
                    "SELECT status, failure_reason FROM semantic_attempts "
                    "WHERE attempt_id=? AND job_id=?",
                    (prior_attempt_id, int(job["id"])),
                ).fetchone()
                if prior_attempt is not None:
                    prior_attempt_reason = str(prior_attempt["failure_reason"] or "")
            prior_shape_failure = (
                prior_attempt_id
                and prior_attempt_reason == "semantic_result_incomplete"
            ) or str(job["last_failure_reason"] or "") == "semantic_result_incomplete"
            if (
                not semantic_ready
                and semantic_reason in dispatch_mod._RETRYABLE_SEMANTIC_RESULT_REASONS
                and prior_shape_failure
            ):
                dispatch_mod.reseed_semantic_artifact_for_retry(
                    work_order,
                    previous_attempt_id=prior_attempt_id,
                )

            readiness = _runner_preflight(str(job["runner"]))
            if not readiness.ready:
                if readiness.classification == "environment_wait":
                    retry_after = max(5.0, float(readiness.retry_after_seconds))
                    _update_job(
                        conn,
                        job["id"],
                        status_value="BACKOFF",
                        last_error=readiness.detail,
                        last_failure_class=readiness.classification,
                        last_failure_reason=readiness.reason,
                        next_attempt_at=time.time() + retry_after,
                    )
                    return {
                        "schema": SCHEMA,
                        "ok": True,
                        "action": "RUNNER_WAIT",
                        "job_id": job["id"],
                        "reason": readiness.reason,
                        "retry_after_seconds": retry_after,
                        "semantic_attempt_created": False,
                        "execution_clock_started": False,
                    }
                policy = _apply_failure_policy(
                    conn,
                    job_id=int(job["id"]),
                    failure_class=readiness.classification,
                    failure_reason=readiness.reason,
                    detail=readiness.detail,
                    total_cost_usd=float(job["total_cost_usd"] or 0.0),
                )
                return {
                    "schema": SCHEMA,
                    "ok": False,
                    "action": policy["status"],
                    "job_id": job["id"],
                    "reason": readiness.reason,
                    "semantic_attempt_created": False,
                    "execution_clock_started": False,
                    **policy,
                }

            started_at = _ensure_execution_started(conn, int(job["id"]))
            elapsed = max(0.0, time.time() - started_at)
            max_wall = int(job["max_wall_seconds"] or 0)
            max_cost = float(job["max_total_cost_usd"] or 0.0)
            spent = float(job["total_cost_usd"] or 0.0)
            remaining_cost_budget = _remaining_funded_cost_budget(max_cost, spent)
            if max_cost > 0:
                unknown_cost_attempts = _unknown_cost_attempt_count(
                    conn, int(job["id"])
                )
                if unknown_cost_attempts:
                    _update_job(
                        conn,
                        job["id"],
                        status_value="QUARANTINED",
                        last_error=(
                            "finite cost ceiling cannot be enforced from a known "
                            f"baseline: {unknown_cost_attempts} historical semantic "
                            "attempt(s) have unknown provider cost"
                        ),
                        last_failure_class="usage_unknown",
                        last_failure_reason="historical_cost_unknown",
                        next_attempt_at=0,
                    )
                    return {
                        "schema": SCHEMA,
                        "ok": False,
                        "action": "QUARANTINED",
                        "job_id": job["id"],
                        "reason": "historical_cost_unknown",
                        "unknown_cost_attempts": unknown_cost_attempts,
                    }
            max_tokens = int(job["max_total_tokens"] or 0)
            spent_tokens = (
                int(job["total_input_tokens"] or 0)
                + int(job["total_output_tokens"] or 0)
                + int(job["total_cache_read_tokens"] or 0)
                + int(job["total_cache_creation_tokens"] or 0)
            )
            if max_wall > 0 and elapsed >= max_wall:
                _update_job(
                    conn,
                    job["id"],
                    status_value="QUARANTINED",
                    last_error=f"operational wall-clock ceiling reached: {elapsed:.1f}s >= {max_wall}s",
                    next_attempt_at=0,
                )
                return {
                    "schema": SCHEMA,
                    "ok": False,
                    "action": "QUARANTINED",
                    "job_id": job["id"],
                    "reason": "wall_clock_ceiling",
                    "elapsed_seconds": elapsed,
                    "max_wall_seconds": max_wall,
                }
            if max_cost > 0 and spent >= max_cost:
                _update_job(
                    conn,
                    job["id"],
                    status_value="QUARANTINED",
                    last_error=f"operational model-cost ceiling reached: ${spent:.4f} >= ${max_cost:.4f}",
                    next_attempt_at=0,
                )
                return {
                    "schema": SCHEMA,
                    "ok": False,
                    "action": "QUARANTINED",
                    "job_id": job["id"],
                    "reason": "cost_ceiling",
                    "total_cost_usd": spent,
                    "max_total_cost_usd": max_cost,
                }

            if max_tokens > 0 and spent_tokens >= max_tokens:
                _update_job(
                    conn,
                    job["id"],
                    status_value="QUARANTINED",
                    last_error=(
                        f"operational token ceiling reached: "
                        f"{spent_tokens} >= {max_tokens}"
                    ),
                    last_failure_class="usage_ceiling",
                    last_failure_reason="token_ceiling",
                    next_attempt_at=0,
                )
                return {
                    "schema": SCHEMA,
                    "ok": False,
                    "action": "QUARANTINED",
                    "job_id": job["id"],
                    "reason": "token_ceiling",
                    "observed_total_tokens": spent_tokens,
                    "max_total_tokens": max_tokens,
                }

            role = str(work_order.get("role") or "builder")
            binding_create_allowed = _capability_binding_creation_allowed(
                conn, int(job["id"])
            )
            attempt_id, durable_files = _reserve_semantic_attempt(
                conn, job=job, role=role
            )

            packet_path = state_mod.run_dir(
                Path(str(job["repo"])), str(job["run_id"])
            ) / "WORK_PACKET.md"
            packet_meta, _ = packet_mod.parse_packet_file(packet_path)
            semantic_timeout_seconds = resolve_semantic_timeout(
                packet_meta, timeout_seconds
            )
            # The whole-run wall ceiling must constrain the pass actually
            # launched, not only the between-pass checks: a pass started
            # with one minute of budget left may not run for its full
            # packet timeout. Clamp the pass timeout to the remaining wall
            # budget whenever a wall ceiling is funded.
            if max_wall > 0:
                remaining_wall = max(0, int(max_wall - elapsed))
                semantic_timeout_seconds = min(
                    semantic_timeout_seconds, remaining_wall
                )

            runner_work_order = dict(work_order)
            runner_work_order["attempt_id"] = attempt_id
            runner_work_order["allow_capability_binding_create"] = binding_create_allowed
            if remaining_cost_budget is not None:
                runner_work_order["max_budget_usd"] = remaining_cost_budget
            runner_impl = _runner(str(job["runner"]))
            result = runner_impl.run(
                runner_work_order,
                timeout_seconds=semantic_timeout_seconds,
                on_start=lambda pid, started_role: _set_worker_pid(
                    conn,
                    int(job["id"]),
                    pid,
                    started_role,
                    out_path=durable_files[0],
                    err_path=durable_files[1],
                    attempt_id=attempt_id,
                    deadline_at=time.time() + semantic_timeout_seconds,
                    max_pass_runtime_seconds=semantic_timeout_seconds,
                ),
                durable_files=durable_files,
            )
            if not result.cost_known:
                # Cost-telemetry fail-closed applies only while an operator
                # cost ceiling is actually active. Without a ceiling, unknown
                # cost cannot breach any declared budget; the attempt is
                # recorded COST_UNKNOWN at zero and execution continues so an
                # unattended PROGRAM is not stopped by telemetry loss.
                conn.execute(
                    """UPDATE semantic_attempts SET status='COST_UNKNOWN',
                       completed_at=?, returncode=?, cost_known=0
                       WHERE attempt_id=? AND job_id=?""",
                    (time.time(), int(result.returncode), attempt_id, int(job["id"])),
                )
                conn.commit()
                if float(job["max_total_cost_usd"] or 0) > 0:
                    _update_job(
                        conn,
                        job["id"],
                        status_value="QUARANTINED",
                        last_error=(
                            "semantic worker completed without a trustworthy finite "
                            "total_cost_usd while a cost ceiling is active; refusing "
                            "to assume zero cost"
                        ),
                        last_failure_class=(
                            "timeout_usage_unknown"
                            if int(result.returncode) == 124
                            else "usage_unknown"
                        ),
                        last_failure_reason=(
                            "runner_timeout_cost_unknown"
                            if int(result.returncode) == 124
                            else "model_cost_unknown"
                        ),
                        next_attempt_at=0,
                    )
                    return {
                        "schema": SCHEMA,
                        "ok": False,
                        "action": "QUARANTINED",
                        "job_id": job["id"],
                        "reason": "model_cost_unknown",
                        "attempt_id": attempt_id,
                    }

            if int(job["max_total_tokens"] or 0) > 0 and not result.tokens_known:
                # Account the completed attempt exactly once BEFORE the
                # TOKENS_UNKNOWN quarantine. Terminalizing the attempt without
                # accounting would leave cost_accounted=0 forever: a provable
                # provider cost would never reach jobs.total_cost_usd (a funded
                # cost ceiling would then under-count spend across the
                # quarantine/resume cycle), and an unprovable cost would keep
                # the INSERT-default cost_known=1 instead of the honest 0.
                tokens_unknown_total = _account_attempt_cost(
                    conn,
                    job_id=int(job["id"]),
                    attempt_id=attempt_id,
                    cost_usd=float(result.cost_usd),
                    returncode=int(result.returncode),
                    status_value="TOKENS_UNKNOWN",
                    cost_known=result.cost_known,
                    tokens_known=False,
                    effective_model=result.effective_model,
                    model_usage_json=result.model_usage_json,
                )
                conn.execute(
                    """UPDATE semantic_attempts SET
                       failure_class='usage_unknown',
                       failure_reason='token_usage_unknown'
                       WHERE attempt_id=? AND job_id=?""",
                    (attempt_id, int(job["id"])),
                )
                conn.commit()
                _update_job(
                    conn,
                    job["id"],
                    status_value="QUARANTINED",
                    total_cost_usd=tokens_unknown_total,
                    last_error=(
                        "semantic worker completed without trustworthy token usage "
                        "while a token ceiling is enabled"
                    ),
                    last_failure_class="usage_unknown",
                    last_failure_reason="token_usage_unknown",
                    next_attempt_at=0,
                )
                return {
                    "schema": SCHEMA,
                    "ok": False,
                    "action": "QUARANTINED",
                    "job_id": job["id"],
                    "reason": "token_usage_unknown",
                    "attempt_id": attempt_id,
                }

            new_cost = _account_attempt_cost(
                conn,
                job_id=int(job["id"]),
                attempt_id=attempt_id,
                cost_usd=float(result.cost_usd),
                returncode=int(result.returncode),
                status_value=("COMPLETED" if result.cost_known else "COST_UNKNOWN"),
                cost_known=result.cost_known,
                input_tokens=result.input_tokens,
                output_tokens=result.output_tokens,
                cache_read_tokens=result.cache_read_tokens,
                cache_creation_tokens=result.cache_creation_tokens,
                tokens_known=result.tokens_known,
                effective_model=result.effective_model,
                model_usage_json=result.model_usage_json,
            )

            # Strict-profile truth: a profile that REQUESTED an explicit model
            # is certified only when the provider PROVABLY ran that model. A
            # provable substitution — or an unprovable effective model under a
            # strict request — fails closed here. The attempt's cost was
            # already accounted above; the envelope truth (full modelUsage) is
            # preserved in the ledger either way.
            strict_failure_reason = ""
            strict_failure_class = ""
            if bool(getattr(runner_impl, "requires_capability_receipt", False)):
                try:
                    receipt = capabilities_mod.read_resolution_receipt(
                        Path(str(job["repo"])),
                        str(job["run_id"]),
                        role,
                        attempt_id,
                    )
                except capabilities_mod.CapabilityResolutionError:
                    strict_failure_reason = "semantic_attempt_capability_receipt_invalid"
                    strict_failure_class = "invariant"
                else:
                    requested_profile = receipt.get("requested_runner_profile") or {}
                    strict_model = str(requested_profile.get("model") or "")
                    strict_failure_reason = _strict_profile_model_violation(
                        strict_model,
                        result_ok=bool(result.ok),
                        effective_model=str(result.effective_model or ""),
                    )
                    if strict_failure_reason:
                        strict_failure_class = "configuration"

            if not result.ok or strict_failure_reason:
                if strict_failure_reason:
                    failure_class, failure_reason = (
                        strict_failure_class or "configuration", strict_failure_reason,
                    )
                else:
                    failure_class, failure_reason = _classify_runner_failure(result)
                # v1.0.0 progress-watchdog: if the watchdog already
                # classified this kill as progress_stalled, keep its
                # authoritative classification and skip overwriting the
                # semantic_attempts row with the runner classifier's
                # output. Watchdog already wrote 'progress_stalled'
                # before this exit handler ran.
                try:
                    current_lfc_row = conn.execute(
                        "SELECT last_failure_class FROM jobs WHERE id=?",
                        (int(job["id"]),),
                    ).fetchone()
                    if (
                        current_lfc_row is not None
                        and str(current_lfc_row[0] or "") == "progress_stalled"
                    ):
                        failure_class = "progress_stalled"
                        failure_reason = "watchdog_no_progress_window"
                except sqlite3.Error:
                    pass
                detail = (
                    f"runner rc={result.returncode}: "
                    f"{result.stderr or result.stdout}"
                )[-4000:]
                conn.execute(
                    """UPDATE semantic_attempts SET
                       failure_class=?, failure_reason=?
                       WHERE attempt_id=? AND job_id=?""",
                    (
                        failure_class,
                        failure_reason,
                        attempt_id,
                        int(job["id"]),
                    ),
                )
                conn.commit()
                policy = _apply_failure_policy(
                    conn,
                    job_id=int(job["id"]),
                    failure_class=failure_class,
                    failure_reason=failure_reason,
                    detail=detail,
                    total_cost_usd=new_cost,
                )
                return {
                    "schema": SCHEMA,
                    "ok": False,
                    "action": policy["status"],
                    "job_id": job["id"],
                    "returncode": result.returncode,
                    "cost_usd": result.cost_usd,
                    **policy,
                }

            # A successful provider envelope is not itself replay authority.
            # Prove the exact semantic artifact is structurally ready, then
            # publish an explicit durable entitlement BEFORE deterministic
            # finalization. A crash before this point fails closed; a crash
            # after it may legitimately replay at zero semantic cost.
            #
            # The acceptance publication captures the exact semantic artifact
            # digest and the exact role-specific finalization identity so a
            # subsequent zero-cost replay can re-prove them. Zero-cost replay
            # without identity binding would let a crashed-pending replay
            # operate on different bytes/HEAD than what was accepted.
            acceptance_ready, acceptance_reason = dispatch_mod.semantic_result_ready(
                work_order
            )
            if not acceptance_ready:
                raise dispatch_mod.SemanticResultIncomplete(acceptance_reason)
            acceptance_candidate_sha = _replay_candidate_sha(
                role=role,
                work_order=work_order,
                repo=str(job["repo"] or ""),
                run_id=str(job["run_id"] or ""),
            )
            if not acceptance_candidate_sha:
                raise RuntimeError(
                    f"semantic acceptance cannot resolve candidate SHA for role={role!r}"
                )
            _publish_semantic_acceptance(
                conn,
                job_id=int(job["id"]),
                attempt_id=attempt_id,
                semantic_path=str(work_order.get("semantic_path") or ""),
                candidate_sha=acceptance_candidate_sha,
            )

            finalizer_timeout: int | None = None
            if max_wall > 0:
                elapsed_after_worker = max(0.0, time.time() - started_at)
                remaining_after_worker = int(max_wall - elapsed_after_worker)
                if remaining_after_worker <= 0:
                    _update_job(
                        conn,
                        job["id"],
                        status_value="QUARANTINED",
                        total_cost_usd=new_cost,
                        last_error=(
                            "operational wall-clock ceiling exhausted after semantic "
                            "worker completed; semantic artifact preserved for "
                            "zero-cost replay after explicit operator action"
                        ),
                        last_failure_class="usage_ceiling",
                        last_failure_reason="wall_clock_ceiling_before_finalization",
                        next_attempt_at=0,
                    )
                    return {
                        "schema": SCHEMA,
                        "ok": False,
                        "action": "QUARANTINED",
                        "job_id": job["id"],
                        "reason": "wall_clock_ceiling_before_finalization",
                        "elapsed_seconds": elapsed_after_worker,
                        "max_wall_seconds": max_wall,
                        "semantic_artifact_preserved": True,
                    }
                finalizer_timeout = remaining_after_worker

            # v0.10.0-dev a002: default finalize timeout for unfunded runs.
            # When the operator omits max_wall_seconds, the CLI subprocess
            # would otherwise hang forever on a wedged build/review finalize.
            # The packet-derived max_runtime_seconds already feeds this when
            # max_wall > 0; we keep that path and add a hard upper bound for
            # the unfunded path so the durable clock always recovers.
            effective_finalizer_timeout = (
                int(finalizer_timeout)
                if finalizer_timeout and int(finalizer_timeout) > 0
                else _DEFAULT_FINALIZER_TIMEOUT_SECONDS
            )
            finalized = dispatch_mod.finalize_work_order(
                work_order, timeout_seconds=effective_finalizer_timeout
            )
            _update_job(
                conn,
                job["id"],
                status_value="QUEUED",
                infra_failures=0,
                transient_failures=0,
                transient_recovery_cycles=0,
                total_cost_usd=new_cost,
                last_error=None,
                last_failure_class=None,
                last_failure_reason=None,
                next_attempt_at=0,
            )
            return {
                "schema": SCHEMA,
                "ok": True,
                "action": decision,
                "job_id": job["id"],
                "cost_usd": result.cost_usd,
                "finalized": finalized,
            }
        except Exception as exc:
            if attempt_id and isinstance(
                exc,
                (
                    WorkerLaunchError,
                    capabilities_mod.CapabilityResolutionError,
                    capability_binding_mod.CapabilityBindingError,
                    runner_profiles_mod.RunnerProfileError,
                ),
            ):
                _mark_attempt_launch_failed(
                    conn,
                    job_id=int(job["id"]),
                    attempt_id=attempt_id,
                    detail=str(exc),
                    failure_reason=(
                        "capability_binding_failed"
                        if isinstance(exc, capability_binding_mod.CapabilityBindingError)
                        else "runner_profile_resolution_failed"
                        if isinstance(exc, runner_profiles_mod.RunnerProfileError)
                        else "capability_resolution_failed"
                        if isinstance(exc, capabilities_mod.CapabilityResolutionError)
                        else "worker_launch_failed"
                    ),
                )
            elif attempt_id and isinstance(exc, dispatch_mod.SemanticResultIncomplete):
                conn.execute(
                    """UPDATE semantic_attempts SET status='FAILED',
                       failure_class=?, failure_reason=?, completed_at=COALESCE(completed_at, ?)
                       WHERE attempt_id=? AND job_id=?""",
                    (
                        "runner" if exc.retryable else "invariant",
                        "semantic_result_incomplete",
                        time.time(),
                        attempt_id,
                        int(job["id"]),
                    ),
                )
                conn.commit()
            # Completed semantic attempts are accounted transactionally by
            # attempt identity. If an exception happened before completion,
            # stale-worker recovery will inspect the durable attempt/output;
            # never synthesize cost from output digests here.
            current_cost_row = conn.execute(
                "SELECT total_cost_usd FROM jobs WHERE id=?", (job["id"],)
            ).fetchone()
            total_attempted_cost = float(
                (current_cost_row[0] if current_cost_row is not None else 0.0) or 0.0
            )
            failure_class, failure_reason = _classify_exception(exc)
            detail = f"{type(exc).__name__}: {exc}"[-4000:]
            policy = _apply_failure_policy(
                conn,
                job_id=int(job["id"]),
                failure_class=failure_class,
                failure_reason=failure_reason,
                detail=detail,
                total_cost_usd=total_attempted_cost,
            )
            return {
                "schema": SCHEMA,
                "ok": False,
                "action": policy["status"],
                "job_id": job["id"],
                "error": str(exc),
                **policy,
            }


def _scheduler_submission_budget(
    *,
    db_path: Path,
    configured: int,
    local_inflight: int,
) -> int:
    """Thin delegate to ``supervisor_claims._scheduler_submission_budget``."""
    return _claims_mod._scheduler_submission_budget(
        db_path=db_path,
        configured=configured,
        local_inflight=local_inflight,
    )


def serve(
    *,
    db_path: Path | None = None,
    poll_seconds: float = 2.0,
    timeout_seconds: int = 0,
    once: bool = False,
) -> dict[str, Any] | None:
    """Run the durable execution clock. Idle iterations make zero model calls."""
    _load_service_env_file()
    _cleanup_done_runtime_caches(db_path)
    _publish_startup_ready_attestation(db_path)
    if once:
        return run_one(db_path=db_path, timeout_seconds=timeout_seconds)
    last_emit: float = 0.0
    idle_log_interval = max(60.0, float(poll_seconds) * 30)
    # One durable scheduler process owns a bounded pool of execution lanes.
    # SQLite, rather than pool occupancy, remains the capacity authority.
    futures: set[Future[dict[str, Any]]] = set()
    with ThreadPoolExecutor(max_workers=IMPLEMENTATION_MAX_CONCURRENCY) as pool:
        while True:
            db = db_path or default_db_path()
            try:
                with _managed_connect_readonly(db) as read_conn:
                    cfg = read_conn.execute(
                        "SELECT value FROM supervisor_config WHERE key=?",
                        (_CONFIG_MAX_CONCURRENCY,),
                    ).fetchone()
                    configured = _validate_max_concurrency(
                        cfg[0] if cfg is not None else DEFAULT_MAX_CONCURRENCY
                    )
            except (OSError, sqlite3.Error, ValueError):
                configured = DEFAULT_MAX_CONCURRENCY
            # v1.0.0 progress-watchdog: force-terminate any inflight attempt
            # whose observable durable IO has not advanced within the bounded
            # window (ownframework_loop.progress_watchdog for the model).
            # This catches the "Claude alive but producing 0 tokens/0 stdout
            # for the full per-pass deadline" failure mode that the wallclock
            # deadline alone cannot detect.  The tick MUST run BEFORE we
            # process completed futures: a force-terminated worker's pool
            # future can become done before the watchdog tick in the same
            # iteration; processing it first would let the dispatcher's
            # runner-classifier overwrite the watchdog's authoritative
            # progress_stalled classification on jobs/semantic_attempts.
            try:
                _progress_watchdog_tick(Path(db))
            except Exception:
                pass
            # Retire completed lanes and emit their durable result. A failed
            # lane is isolated; the scheduler continues to reconcile others.
            completed = {f for f in futures if f.done()}
            for future in completed:
                futures.remove(future)
                try:
                    event = future.result()
                except Exception as exc:  # pragma: no cover - defensive lane fence
                    event = {"schema": SCHEMA, "ok": False, "action": "LANE_ERROR",
                             "error": f"{type(exc).__name__}: {exc}"}
                action = event.get("action")
                now = time.time()
                if action != "IDLE" or (now - last_emit) >= idle_log_interval:
                    print(json.dumps(event, sort_keys=True), flush=True)
                    last_emit = now
            # SQLite remains authority; this projection only limits pointless
            # idle probes when configured capacity is much larger than demand.
            submit_count = _scheduler_submission_budget(
                db_path=Path(db),
                configured=configured,
                local_inflight=len(futures),
            )
            for _ in range(submit_count):
                futures.add(pool.submit(
                    run_one, db_path=db_path, timeout_seconds=timeout_seconds
                ))
            if not futures and submit_count == 0:
                time.sleep(max(0.25, float(poll_seconds)))
            else:
                time.sleep(max(0.1, min(float(poll_seconds), 1.0)))


def _migrate_quarantined_run_capabilities(
    *,
    canonical_repo: Path,
    run_id: str,
    existing: sqlite3.Row,
    reason: str,
    actor: str,
) -> dict[str, Any]:
    """Resolve and explicitly migrate one quarantined run's capabilities."""
    if str(existing["status"] or "") != "QUARANTINED":
        raise RuntimeError("capability migration requires QUARANTINED enrollment")
    if existing["worker_pid"]:
        if _pid_alive(
            int(existing["worker_pid"]),
            float(existing["worker_started_at"])
            if existing["worker_started_at"] is not None else None,
        ):
            raise RuntimeError("capability migration refused while semantic worker is live")
        if not existing["worker_start_identity"] or existing["worker_started_at"] is None:
            raise RuntimeError("capability migration refused for ambiguous worker identity")

    repo_path = canonical_repo.resolve(strict=False)
    current_state = state_mod.load_verified(repo_path, run_id)
    if transitions.is_terminal(str(current_state.get("state") or "")):
        raise RuntimeError("capability migration refused for terminal engineering state")

    packet_path = state_mod.run_dir(repo_path, run_id) / "WORK_PACKET.md"
    packet_meta, _ = packet_mod.parse_packet_file(packet_path)
    packet_errors = packet_mod.validate_packet_for_approval(packet_meta)
    if packet_errors:
        raise RuntimeError("packet authority invalid: " + "; ".join(packet_errors))
    approval_doc = approval_mod.load_approval(repo_path, run_id)
    approval_ok, approval_reason = approval_mod.validate_approval_binding(
        canonical_repo=repo_path,
        run_id=run_id,
        approval=approval_doc,
        packet=packet_meta,
        packet_path=packet_path,
    )
    if not approval_ok:
        raise RuntimeError("approval authority invalid: " + approval_reason)

    requested = packet_meta.get("capabilities")
    if not isinstance(requested, list) or not all(isinstance(item, str) for item in requested):
        raise RuntimeError("packet capability authority is malformed")
    runner_name = str(existing["runner"] or "")
    runner_impl = _runner(runner_name)
    provider = str(getattr(runner_impl, "runner_id", runner_name))
    profile = runner_profiles_mod.resolve_profile(
        str(packet_meta.get("runner_profile") or "default"),
        provider=provider,
    )
    runner_profiles_mod.verify_profile_integrity(profile)
    attestation = runner_profiles_mod.verify_effort_attestation(profile)
    if attestation is not None:
        profile = dict(profile)
        profile["effort_attestation"] = attestation

    resolution = capabilities_mod.resolve_capabilities(
        [str(item) for item in requested],
        canonical_repo=repo_path,
        role="reviewer",
        repo_cache_root=runtime_env.repo_tool_cache_dir(repo_path),
        ephemeral_cache_root=(
            runtime_env.runtime_cache_dir(repo_path, run_id, "validation")
            / "capability-cache"
        ),
        packet_network_allowlist=[
            str(item) for item in (packet_meta.get("network_read_allowlist") or [])
        ],
    )
    capability_binding_mod._assert_runtime_ready_resolution(resolution, requested)
    program = current_state.get("program") or {}
    checkpoints = program.get("current_checkpoints") or []
    context = {
        "runtime_generation": str(existing["runtime_generation"] or ""),
        "engineering_state": str(current_state.get("state") or ""),
        "checkpoint": str(checkpoints[0]) if checkpoints else "",
        "supervisor_job_id": int(existing["id"]),
        "packet_sha256": util.sha256_text(packet_path.read_text(encoding="utf-8")),
        "approval_sha256": approval_mod.approval_artifact_sha256(approval_doc or {}),
    }
    return capability_binding_mod.migrate_run_binding(
        repo_path,
        run_id,
        resolution,
        profile,
        reason=reason,
        actor=actor,
        context=context,
        requested_capabilities=requested,
    )


__all__ = [
    "SCHEMA",
    "ClaudeCodeRunner",
    "RunnerReadiness",
    "default_db_path",
    "default_worker_log_dir",
    "DISPATCH_HOLD_KIND",
    "DISPATCH_HOLD_STATES",
    "dispatch_hold_status",
    "release_dispatch_hold",
    "cancel_dispatch_hold",
    "supervisor_config_get",
    "supervisor_config_set",
    "fleet_status",
    "enqueue",
    "continue_program",
    "register_runner",
    "resume",
    "run_one",
    "serve",
    "status",
    "worker_log_paths",
]


@_serialize_run_lifecycle
def resume(
    *,
    canonical_repo: Path,
    run_id: str,
    db_path: Path | None = None,
    max_infra_failures: int | None = None,
    max_transient_failures: int | None = None,
    max_transient_recovery_cycles: int | None = None,
    max_total_cost_usd: float | None = None,
    max_total_tokens: int | None = None,
    max_wall_seconds: int | None = None,
    reset_execution_started_at: bool = False,
    rebind_capabilities: bool = False,
    capability_migration_reason: str = "explicit operator recovery from trusted capability drift",
    capability_migration_actor: str = "operator",
) -> dict[str, Any]:
    """Clear operational quarantine and reset operational counters only.

    Does NOT alter STATE.json, packet scope, candidate SHA, review verdict, or
    engineering pass counters. Cumulative observed cost is preserved.

    The wall-clock origin is PRESERVED by default: resuming a run that
    exhausted its funded wall budget must not silently grant a fresh
    budget — the ceiling check would quarantine the run again, and
    silently resetting the clock would make the funded wall ceiling
    unenforceable across resumes. A fresh clock is an explicit budget
    decision: pass ``reset_execution_started_at=True`` (operator
    ``--reset-execution-clock``) — normally together with a widened
    ``max_wall_seconds``.

    Runtime-generation migration: resume is an explicit operator act, so
    it also REBINDS the job to the resuming runtime's generation. This is
    the clean migration path after a deliberate runtime replacement: the
    run was quarantined on the generation mismatch, the operator inspects
    and resumes, and the run continues under the new generation with the
    rebinding recorded. The previous binding is reported in the result.

    Capability migration is separate and opt-in through
    ``rebind_capabilities=True``. It validates and records the new trusted
    capability authority before this operational resume transaction; ordinary
    resume never silently changes capability binding.

    Returns the updated job dict (or NOT_ENQUEUED).
    """
    state_mod.validate_run_id(run_id)
    repo = str(Path(canonical_repo).resolve(strict=False))
    db = db_path or default_db_path()
    now = time.time()
    # Resume is exclusively a QUARANTINED -> QUEUED recovery action. Any
    # other state is refused without changing budgets, wall-clock origin, PID
    # ownership, backoff or error evidence.
    with _managed_connect(db) as conn:
        existing, lookup_reason = _logical_job_row(conn, canonical_repo, run_id)
    if existing is None:
        return {
            "schema": SCHEMA,
            "ok": False,
            "repo": repo,
            "run_id": run_id,
            "status": "NOT_ENQUEUED",
            "db_path": str(db),
            "resumed": False,
            "reason": "not_enqueued",
        }
    # Retired enrollments are durable historical evidence; ``supervisor resume``
    # must not accidentally resurrect them. The architecture intentionally
    # exposes no reactivation command — preserved historical enrollments must
    # stay preserved. Fail closed with a precise retirement diagnostic that
    # operators can grep, distinct from the generic QUARANTINED-required one.
    if str(existing["status"] or "") == "RETIRED":
        result = _job_dict(existing, db)
        result.update({
            "ok": False,
            "resumed": False,
            "reason": "resume_refuses_retired_enrollment",
        })
        return result
    if str(existing["status"]) != "QUARANTINED":
        result = _job_dict(existing, db)
        result.update({
            "ok": False,
            "resumed": False,
            "reason": "resume_requires_quarantined",
        })
        return result
    if existing["worker_pid"] and _pid_alive(
        int(existing["worker_pid"]),
        float(existing["worker_started_at"]) if existing["worker_started_at"] else None,
    ):
        result = _job_dict(existing, db)
        result.update({
            "ok": False,
            "resumed": False,
            "reason": "quarantined_worker_still_alive",
        })
        return result

    migration = None
    if rebind_capabilities:
        try:
            migration = _migrate_quarantined_run_capabilities(
                canonical_repo=canonical_repo,
                run_id=run_id,
                existing=existing,
                reason=capability_migration_reason,
                actor=capability_migration_actor,
            )
        except Exception as exc:  # deterministic refusal; no supervisor write yet
            result = _job_dict(existing, db)
            result.update({
                "ok": False,
                "resumed": False,
                "reason": "capability_rebind_refused",
                "error": str(exc),
            })
            return result

    sets = [
        "status='QUEUED'",
        "infra_failures=0",
        "transient_failures=0",
        "transient_recovery_cycles=0",
        "next_attempt_at=0",
        "last_error=NULL",
        "last_failure_class=NULL",
        "last_failure_reason=NULL",
        "worker_pid=NULL",
        "worker_started_at=NULL",
        "worker_pgid=NULL",
        "worker_deadline_at=NULL",
        "worker_start_identity=NULL",
        "worker_role=NULL",
        "updated_at=?",
    ]
    params: list[Any] = [now]
    if max_infra_failures is not None:
        sets.append("max_infra_failures=?")
        params.append(int(max_infra_failures))
    if max_transient_failures is not None:
        sets.append("max_transient_failures=?")
        params.append(int(max_transient_failures))
    if max_transient_recovery_cycles is not None:
        sets.append("max_transient_recovery_cycles=?")
        params.append(int(max_transient_recovery_cycles))
    if max_total_cost_usd is not None:
        sets.append("max_total_cost_usd=?")
        params.append(float(max_total_cost_usd))
    if max_total_tokens is not None:
        sets.append("max_total_tokens=?")
        params.append(int(max_total_tokens))
    if max_wall_seconds is not None:
        sets.append("max_wall_seconds=?")
        params.append(int(max_wall_seconds))
    if (
        max_total_cost_usd is not None
        and max_total_tokens is not None
        and max_wall_seconds is not None
    ):
        sets.append("legacy_budget_ambiguous=0")
    if reset_execution_started_at:
        sets.append("execution_started_at=?")
        params.append(now)
    # Explicit operator migration: rebind the run to the resuming
    # runtime's generation (recorded; previous binding reported back).
    previous_generation = str(existing["runtime_generation"] or "")
    sets.append("runtime_generation=?")
    params.append(_current_runtime_generation())
    params.extend([int(existing["id"]), previous_generation])
    with _managed_connect(db) as conn:
        cur = conn.execute(
            f"UPDATE jobs SET {', '.join(sets)} "
            "WHERE id=? AND status='QUARANTINED' AND runtime_generation=?",
            params,
        )
        row = conn.execute(
            "SELECT * FROM jobs WHERE id=?", (int(existing["id"]),)
        ).fetchone()
        if cur.rowcount != 1:
            result = _job_dict(row, db) if row is not None else {
                "schema": SCHEMA,
                "ok": False,
                "repo": repo,
                "run_id": run_id,
                "status": "NOT_ENQUEUED",
                "db_path": str(db),
            }
            result.update({
                "ok": False,
                "resumed": False,
                "reason": "resume_lost_quarantine_race",
            })
            if migration is not None:
                result.update({
                    "capability_migration_completed": True,
                    "capability_migration": migration,
                    "safe_retry": "supervisor resume --rebind-capabilities",
                })
            return result
    if row is None:
        return {
            "schema": SCHEMA,
            "ok": False,
            "repo": repo,
            "run_id": run_id,
            "status": "NOT_ENQUEUED",
            "db_path": str(db),
        }
    result = _job_dict(row, db)
    result["resumed"] = True
    result["runtime_generation_previous"] = previous_generation
    if migration is not None:
        result["capability_migration"] = migration
    return result


@_serialize_run_lifecycle
def retire(
    *,
    canonical_repo: Path,
    run_id: str,
    db_path: Path | None = None,
) -> dict[str, Any]:
    """Non-destructively retire a historical supervisor enrollment.

    Retirement is a SUPERVISOR-LEDGER lifecycle transition only. It MUST NOT
    modify the target repository, .ownframework-loop run artifacts, WORK_PACKET.md,
    STATE.json, EVENTS.log, APPROVAL.json, scratch evidence, candidate refs,
    runtime_generation, semantic-attempt history, or cost/token/retry evidence.

    Supported transition: ``QUARANTINED -> RETIRED`` only. ``QUEUED``,
    ``BACKOFF``, ``RUNNING``, ``DONE``, and ``RETIRED`` are refused because
    retirement is not a reactivation, migration, or completion.

    A live or ambiguous semantic worker / attempt refuses retirement; the
    enrollment must first drain through the normal supervisor lifecycle.

    A retired row's existing ``runtime_generation`` value (including an empty
    legacy ``UNBOUND`` value) is preserved. Retirement never masquerades as
    migration or successful completion. The retired enrollment is excluded
    from runtime-generation dependency checks at install/refresh time, so
    normal future supervisor replacement no longer requires the migration
    override to bypass durable historical evidence.

    ``supervisor resume`` continues to refuse ``RETIRED`` rows because it
    requires the source status to be exactly ``QUARANTINED``. The architecture
    intentionally does not expose a reactivation command — preserved historical
    enrollments must stay preserved.
    """
    state_mod.validate_run_id(run_id)
    repo = str(Path(canonical_repo).resolve(strict=False))
    db = db_path or default_db_path()
    now = time.time()
    with _managed_connect(db) as conn:
        existing, lookup_reason = _logical_job_row(conn, canonical_repo, run_id)
    if existing is None:
        return {
            "schema": SCHEMA,
            "ok": False,
            "repo": repo,
            "run_id": run_id,
            "status": "NOT_ENQUEUED",
            "db_path": str(db),
            "retired": False,
            "reason": "not_enqueued",
        }
    current_status = str(existing["status"] or "")
    if current_status != "QUARANTINED":
        result = _job_dict(existing, db)
        result.update({
            "ok": False,
            "retired": False,
            "reason": (
                "retire_requires_quarantined"
                if current_status in ("QUEUED", "BACKOFF", "RUNNING")
                else "retire_refuses_terminal_enrollment"
            ),
        })
        return result
    # An unresolved semantic-attempt row is ambiguous paid/model execution
    # evidence even when the job-level PID is empty or dead. Retirement must
    # not hide it behind a historical status before crash reconciliation has
    # proven the attempt terminal.
    with _managed_connect_readonly(db) as attempt_conn:
        attempt_rows = attempt_conn.execute(
            "SELECT attempt_id,status,worker_pid FROM semantic_attempts "
            "WHERE job_id=? ORDER BY started_at DESC",
            (int(existing["id"]),),
        ).fetchall()
    unresolved_attempts = [
        row for row in attempt_rows
        if str(row["status"] or "") not in TERMINAL_SEMANTIC_ATTEMPT_STATUSES
    ]
    if unresolved_attempts:
        result = _job_dict(existing, db)
        result.update({
            "ok": False,
            "retired": False,
            "reason": "retire_refuses_unresolved_semantic_attempt",
            "unresolved_attempts": [
                {
                    "attempt_id": str(row["attempt_id"] or ""),
                    "status": str(row["status"] or ""),
                    "worker_pid": row["worker_pid"],
                }
                for row in unresolved_attempts[:8]
            ],
        })
        return result

    # Live job ownership also refuses retirement. The operator must wait for
    # the worker to drain through the normal supervisor lifecycle before
    # retiring the enrollment.
    if existing["worker_pid"] and _pid_alive(
        int(existing["worker_pid"]),
        float(existing["worker_started_at"]) if existing["worker_started_at"] else None,
    ):
        result = _job_dict(existing, db)
        result.update({
            "ok": False,
            "retired": False,
            "reason": "quarantined_worker_still_alive",
        })
        return result
    # Preserve runtime_generation verbatim, including legacy empty / UNBOUND.
    preserved_runtime_generation = str(existing["runtime_generation"] or "")
    preserved_cost_usd = float(existing["total_cost_usd"] or 0.0)
    preserved_attempt_id = str(existing["latest_attempt_id"] or "")
    with _managed_connect(db) as conn:
        cur = conn.execute(
            """UPDATE jobs SET
                 status='RETIRED',
                 updated_at=?
               WHERE id=? AND status='QUARANTINED'""",
            (now, int(existing["id"])),
        )
        if cur.rowcount != 1:
            # Concurrent transition lost; refuse without rewriting state.
            row = conn.execute(
                "SELECT * FROM jobs WHERE id=?", (int(existing["id"]),)
            ).fetchone()
            result = _job_dict(row, db) if row is not None else {
                "schema": SCHEMA, "ok": False, "status": "NOT_ENQUEUED",
            }
            result.update({
                "ok": False,
                "retired": False,
                "reason": "retire_lost_quarantine_race",
            })
            return result
        # Read back the exact logical enrollment we just retired. The
        # operator may have addressed it through a symlink or linked worktree,
        # so the caller's literal repo path is not durable row identity.
        row = conn.execute(
            "SELECT * FROM jobs WHERE id=?", (int(existing["id"]),)
        ).fetchone()
    if row is None:
        return {
            "schema": SCHEMA,
            "ok": False,
            "repo": repo,
            "run_id": run_id,
            "status": "NOT_ENQUEUED",
            "db_path": str(db),
            "retired": False,
        }
    # Defensive: confirm the preservation contract held end-to-end.
    actual_runtime_generation = str(row["runtime_generation"] or "")
    if actual_runtime_generation != preserved_runtime_generation:
        raise RuntimeError(
            "retire must preserve runtime_generation verbatim; "
            f"expected {preserved_runtime_generation!r}, got {actual_runtime_generation!r}"
        )
    if float(row["total_cost_usd"] or 0.0) != preserved_cost_usd:
        raise RuntimeError("retire must preserve total_cost_usd verbatim")
    if str(row["latest_attempt_id"] or "") != preserved_attempt_id:
        raise RuntimeError("retire must preserve latest_attempt_id verbatim")
    result = _job_dict(row, db)
    result["retired"] = True
    result["runtime_generation_preserved"] = preserved_runtime_generation
    return result
