"""Supervisor durable persistence owner.

Owns the supervisor ledger's persistence primitives — connection
creation, transaction context managers, schema constants, schema
bootstrap, file-mode protection, and the canonical DB-path
resolver.  Domain decisions (which job may run, whether repair is
funded, recovery policy, hold lifecycle, claims, attempts) are
**not** owned here; they live in their respective domain
authorities.  The DB owner's role is to open transactions,
execute durable mutations, and keep the schema up to date — not
to decide which mutations are allowed.

Hierarchy:

    domain authorities (claims / attempts / recovery / holds /
    read-model / operator mutations / accounting)
        ↓
    supervisor_db  (THIS MODULE — connection + schema + transaction)
        ↓
    sqlite3

Dependency direction: this module does NOT import
``supervisor`` and is imported by every domain authority.
``supervisor.py`` re-exports / delegates the public persistence
seam so historical callers keep working.

Schema bootstrap detail:

    The bootstrap is split into two pieces:

      * ``bootstrap_schema(conn)`` — pure DB schema creation
        (CREATE TABLE IF NOT EXISTS, column migrations via
        ALTER TABLE, config-row priming).  No domain policy.

      * ``_apply_data_migrations(conn)`` — supervisor-owned data
        migrations that need identity / packet helpers
        (``_repository_scheduling_identity``,
        ``_workspace_scheduling_identity``, ``_packet_execution_mode``).
        Lives in ``supervisor.py`` for now because it crosses
        the DB/identity boundary; the bootstrap calls it via the
        explicit ``data_migrations`` callable seam so this module
        never imports ``supervisor``.

Constants surfaced:

    ``SCHEMA`` — supervisor-ledger schema identifier string.
    ``SCHEMA_DATA_VERSION`` — current ``PRAGMA user_version``.
    ``DEFAULT_MAX_CONCURRENCY`` — default execution capacity.
    ``IMPLEMENTATION_MAX_CONCURRENCY`` — hard cap on the value
      accepted by ``_validate_max_concurrency``.
    ``_CONFIG_MAX_CONCURRENCY`` — config-table key.
    ``_LEGACY_BUDGET_DEFAULT_FINGERPRINT`` — historical
      $25 / 0-token / 28800-second tuple that is flagged (not
      rewritten) by ``_apply_data_migrations``.
"""
from __future__ import annotations

import os
import sqlite3
import threading
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable, Iterator


# Schema identity + persistence constants.  These are the
# canonical owners; ``supervisor.py`` re-exports them so existing
# callers (96 internal ``SCHEMA`` references + 4 external
# ``default_db_path`` callers + many more) keep working without an
# import rewrite.

SCHEMA = "ownframework-loop-supervisor/v1"
SCHEMA_DATA_VERSION = 7
DEFAULT_MAX_CONCURRENCY = 1
IMPLEMENTATION_MAX_CONCURRENCY = 64
_CONFIG_MAX_CONCURRENCY = "max_concurrency"
_LEGACY_BUDGET_DEFAULT_FINGERPRINT = (25.0, 0, 28800)


# Per-thread connection depth tracking.  Held by the supervisor
# execution-lock author in ``supervisor.py``; this module only
# owns the dict (shared mutable state must live in one place to
# avoid import-order surprises).  Tests that want a clean depth
# map should use ``reset_thread_depth()`` below.

_LOCAL_CONNECTION_DEPTH: dict[int, int] = {}
_LOCAL_EXECUTION_LOCK = threading.Lock()


def reset_thread_depth() -> None:
    """Forget any per-thread connection depth.  ``supervisor.py``
    keeps a matching thread-depth dict for its execution-lock
    ownership; both must be cleared together.  Reserved for
    tests."""
    with _LOCAL_EXECUTION_LOCK:
        _LOCAL_CONNECTION_DEPTH.clear()


# ---------------------------------------------------------------------------
# File-mode protection helpers.
# ---------------------------------------------------------------------------

def _ensure_private_dir(path: Path) -> Path:
    """Create/repair a supervisor-owned private directory (0700 on POSIX)."""
    p = Path(path).expanduser().resolve(strict=False)
    p.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(p, 0o700)
    except OSError:
        pass
    return p


def _ensure_private_file_mode(path: Path) -> None:
    """Force a supervisor-owned file to 0600 where POSIX modes are available."""
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Canonical DB path resolution.
# ---------------------------------------------------------------------------

def default_db_path() -> Path:
    """Return the canonical ledger path under XDG_STATE_HOME or ~/.local/state.

    Stable across macOS / Linux commissioning; the installer resolves
    the same path so a manually launched supervisor and a launchd /
    systemd supervisor share the same DB.
    """
    root = os.environ.get("XDG_STATE_HOME", "").strip()
    base = Path(root).expanduser() if root else Path.home() / ".local" / "state"
    return base / "ownframework-loop" / "supervisor.sqlite3"


# ---------------------------------------------------------------------------
# Schema bootstrap (pure DB; no domain policy).
# ---------------------------------------------------------------------------

def bootstrap_schema(
    conn: sqlite3.Connection,
    *,
    data_migrations: Callable[[sqlite3.Connection], None] | None = None,
) -> None:
    """Create the schema, apply column migrations, and prime config rows.

    ``data_migrations`` is an optional supervisor-owned callback that
    runs after the column migrations complete.  It is the seam
    where cross-domain migrations (identity / packet) plug into the
    pure DB schema bootstrap without ``supervisor_db`` having to
    import ``supervisor``.  Pass ``None`` to skip data migrations —
    callers that need a fully migrated ledger should pass the
    supervisor's ``_apply_data_migrations`` callable.
    """
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS jobs (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          repo TEXT NOT NULL,
          run_id TEXT NOT NULL,
          runner TEXT NOT NULL DEFAULT 'claude-code',
          status TEXT NOT NULL DEFAULT 'QUEUED',
          infra_failures INTEGER NOT NULL DEFAULT 0,
          max_infra_failures INTEGER NOT NULL DEFAULT 3,
          transient_failures INTEGER NOT NULL DEFAULT 0,
          max_transient_failures INTEGER NOT NULL DEFAULT 8,
          transient_recovery_cycles INTEGER NOT NULL DEFAULT 0,
          max_transient_recovery_cycles INTEGER NOT NULL DEFAULT 2,
          total_cost_usd REAL NOT NULL DEFAULT 0,
          total_input_tokens INTEGER NOT NULL DEFAULT 0,
          total_output_tokens INTEGER NOT NULL DEFAULT 0,
          total_cache_read_tokens INTEGER NOT NULL DEFAULT 0,
          total_cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
          last_error TEXT,
          last_failure_class TEXT,
          last_failure_reason TEXT,
          next_attempt_at REAL NOT NULL DEFAULT 0,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          worker_pid INTEGER,
          worker_started_at REAL,
          worker_pgid INTEGER,
          worker_deadline_at REAL,
          worker_start_identity TEXT,
          worker_role TEXT,
          max_total_cost_usd REAL NOT NULL DEFAULT 0,
          max_total_tokens INTEGER NOT NULL DEFAULT 0,
          max_wall_seconds INTEGER NOT NULL DEFAULT 0,
          execution_started_at REAL,
          worker_stdout_path TEXT,
          worker_stderr_path TEXT,
          runtime_generation TEXT NOT NULL DEFAULT '',
          legacy_budget_ambiguous INTEGER NOT NULL DEFAULT 0,
          repository_scheduling_key TEXT NOT NULL DEFAULT '',
          repository_identity_proven INTEGER NOT NULL DEFAULT 0,
          candidate_branch TEXT NOT NULL DEFAULT '',
          workspace_scheduling_key TEXT NOT NULL DEFAULT '',
          workspace_identity_proven INTEGER NOT NULL DEFAULT 0,
          execution_mode TEXT NOT NULL DEFAULT 'SINGLE',
          dispatch_count INTEGER NOT NULL DEFAULT 0,
          last_dispatch_sequence INTEGER NOT NULL DEFAULT 0,
          UNIQUE(repo, run_id)
        );
        CREATE TABLE IF NOT EXISTS cost_attempts (
          job_id INTEGER NOT NULL,
          attempt_digest TEXT NOT NULL,
          cost_usd REAL NOT NULL,
          recorded_at REAL NOT NULL,
          PRIMARY KEY (job_id, attempt_digest)
        );
        CREATE TABLE IF NOT EXISTS semantic_attempts (
          attempt_id TEXT PRIMARY KEY,
          job_id INTEGER NOT NULL,
          role TEXT NOT NULL,
          status TEXT NOT NULL,
          started_at REAL NOT NULL,
          completed_at REAL,
          worker_pid INTEGER,
          worker_pgid INTEGER,
          deadline_at REAL,
          worker_start_identity TEXT,
          stdout_path TEXT NOT NULL,
          stderr_path TEXT NOT NULL,
          returncode INTEGER,
          cost_usd REAL NOT NULL DEFAULT 0,
          cost_accounted INTEGER NOT NULL DEFAULT 0,
          semantic_accepted INTEGER NOT NULL DEFAULT 0,
          cost_known INTEGER NOT NULL DEFAULT 1,
          launch_gate_version INTEGER NOT NULL DEFAULT 0,
          input_tokens INTEGER NOT NULL DEFAULT 0,
          output_tokens INTEGER NOT NULL DEFAULT 0,
          cache_read_tokens INTEGER NOT NULL DEFAULT 0,
          cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
          tokens_known INTEGER NOT NULL DEFAULT 0,
          failure_class TEXT,
          failure_reason TEXT,
          effective_model TEXT NOT NULL DEFAULT '',
          model_usage_json TEXT NOT NULL DEFAULT ''
        );
        CREATE INDEX IF NOT EXISTS semantic_attempts_job_idx
          ON semantic_attempts(job_id, started_at);
        CREATE TABLE IF NOT EXISTS dispatch_holds (
          hold_id TEXT PRIMARY KEY,
          job_id INTEGER NOT NULL UNIQUE,
          repo TEXT NOT NULL,
          run_id TEXT NOT NULL,
          kind TEXT NOT NULL,
          previous_checkpoint_id TEXT NOT NULL,
          next_checkpoint_id TEXT NOT NULL,
          state TEXT NOT NULL,
          armed_at REAL NOT NULL,
          held_at REAL,
          released_at REAL,
          cancelled_at REAL,
          last_error TEXT,
          updated_at REAL NOT NULL,
          UNIQUE(repo, run_id, kind)
        );
        CREATE INDEX IF NOT EXISTS dispatch_holds_state_idx
          ON dispatch_holds(state, updated_at);
        CREATE TABLE IF NOT EXISTS supervisor_config (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL,
          updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS scheduler_meta (
          id INTEGER PRIMARY KEY CHECK (id=1),
          dispatch_sequence INTEGER NOT NULL DEFAULT 0,
          single_since_program INTEGER NOT NULL DEFAULT 0,
          updated_at REAL NOT NULL
        );
        """
    )

    columns = {
        str(row["name"])
        for row in conn.execute("PRAGMA table_info(jobs)").fetchall()
    }
    job_migrations = {
        "worker_pid": "ALTER TABLE jobs ADD COLUMN worker_pid INTEGER",
        "worker_started_at": "ALTER TABLE jobs ADD COLUMN worker_started_at REAL",
        "worker_pgid": "ALTER TABLE jobs ADD COLUMN worker_pgid INTEGER",
        "worker_deadline_at": "ALTER TABLE jobs ADD COLUMN worker_deadline_at REAL",
        "worker_start_identity": "ALTER TABLE jobs ADD COLUMN worker_start_identity TEXT",
        "worker_role": "ALTER TABLE jobs ADD COLUMN worker_role TEXT",
        "max_total_cost_usd": "ALTER TABLE jobs ADD COLUMN max_total_cost_usd REAL NOT NULL DEFAULT 0",
        "max_wall_seconds": "ALTER TABLE jobs ADD COLUMN max_wall_seconds INTEGER NOT NULL DEFAULT 0",
        "execution_started_at": "ALTER TABLE jobs ADD COLUMN execution_started_at REAL",
        "worker_stdout_path": "ALTER TABLE jobs ADD COLUMN worker_stdout_path TEXT",
        "worker_stderr_path": "ALTER TABLE jobs ADD COLUMN worker_stderr_path TEXT",
        "worker_attempt_id": "ALTER TABLE jobs ADD COLUMN worker_attempt_id TEXT",
        "latest_attempt_id": "ALTER TABLE jobs ADD COLUMN latest_attempt_id TEXT",
        "transient_failures": "ALTER TABLE jobs ADD COLUMN transient_failures INTEGER NOT NULL DEFAULT 0",
        "max_transient_failures": "ALTER TABLE jobs ADD COLUMN max_transient_failures INTEGER NOT NULL DEFAULT 8",
        "transient_recovery_cycles": "ALTER TABLE jobs ADD COLUMN transient_recovery_cycles INTEGER NOT NULL DEFAULT 0",
        "max_transient_recovery_cycles": "ALTER TABLE jobs ADD COLUMN max_transient_recovery_cycles INTEGER NOT NULL DEFAULT 2",
        "total_input_tokens": "ALTER TABLE jobs ADD COLUMN total_input_tokens INTEGER NOT NULL DEFAULT 0",
        "total_output_tokens": "ALTER TABLE jobs ADD COLUMN total_output_tokens INTEGER NOT NULL DEFAULT 0",
        "total_cache_read_tokens": "ALTER TABLE jobs ADD COLUMN total_cache_read_tokens INTEGER NOT NULL DEFAULT 0",
        "total_cache_creation_tokens": "ALTER TABLE jobs ADD COLUMN total_cache_creation_tokens INTEGER NOT NULL DEFAULT 0",
        "max_total_tokens": "ALTER TABLE jobs ADD COLUMN max_total_tokens INTEGER NOT NULL DEFAULT 0",
        "last_failure_class": "ALTER TABLE jobs ADD COLUMN last_failure_class TEXT",
        "last_failure_reason": "ALTER TABLE jobs ADD COLUMN last_failure_reason TEXT",
        "runtime_generation": "ALTER TABLE jobs ADD COLUMN runtime_generation TEXT NOT NULL DEFAULT ''",
        "legacy_budget_ambiguous": "ALTER TABLE jobs ADD COLUMN legacy_budget_ambiguous INTEGER NOT NULL DEFAULT 0",
        "repository_scheduling_key": "ALTER TABLE jobs ADD COLUMN repository_scheduling_key TEXT NOT NULL DEFAULT ''",
        "repository_identity_proven": "ALTER TABLE jobs ADD COLUMN repository_identity_proven INTEGER NOT NULL DEFAULT 0",
        "candidate_branch": "ALTER TABLE jobs ADD COLUMN candidate_branch TEXT NOT NULL DEFAULT ''",
        "workspace_scheduling_key": "ALTER TABLE jobs ADD COLUMN workspace_scheduling_key TEXT NOT NULL DEFAULT ''",
        "workspace_identity_proven": "ALTER TABLE jobs ADD COLUMN workspace_identity_proven INTEGER NOT NULL DEFAULT 0",
        "execution_mode": "ALTER TABLE jobs ADD COLUMN execution_mode TEXT NOT NULL DEFAULT 'SINGLE'",
        "dispatch_count": "ALTER TABLE jobs ADD COLUMN dispatch_count INTEGER NOT NULL DEFAULT 0",
        "last_dispatch_sequence": "ALTER TABLE jobs ADD COLUMN last_dispatch_sequence INTEGER NOT NULL DEFAULT 0",
    }
    for name, statement in job_migrations.items():
        if name not in columns:
            conn.execute(statement)

    attempt_columns = {
        str(row["name"])
        for row in conn.execute("PRAGMA table_info(semantic_attempts)").fetchall()
    }
    attempt_migrations = {
        "worker_pgid": "ALTER TABLE semantic_attempts ADD COLUMN worker_pgid INTEGER",
        "deadline_at": "ALTER TABLE semantic_attempts ADD COLUMN deadline_at REAL",
        "worker_start_identity": "ALTER TABLE semantic_attempts ADD COLUMN worker_start_identity TEXT",
        "cost_known": "ALTER TABLE semantic_attempts ADD COLUMN cost_known INTEGER NOT NULL DEFAULT 1",
        "semantic_accepted": "ALTER TABLE semantic_attempts ADD COLUMN semantic_accepted INTEGER NOT NULL DEFAULT 0",
        "launch_gate_version": "ALTER TABLE semantic_attempts ADD COLUMN launch_gate_version INTEGER NOT NULL DEFAULT 0",
        "input_tokens": "ALTER TABLE semantic_attempts ADD COLUMN input_tokens INTEGER NOT NULL DEFAULT 0",
        "output_tokens": "ALTER TABLE semantic_attempts ADD COLUMN output_tokens INTEGER NOT NULL DEFAULT 0",
        "cache_read_tokens": "ALTER TABLE semantic_attempts ADD COLUMN cache_read_tokens INTEGER NOT NULL DEFAULT 0",
        "cache_creation_tokens": "ALTER TABLE semantic_attempts ADD COLUMN cache_creation_tokens INTEGER NOT NULL DEFAULT 0",
        "tokens_known": "ALTER TABLE semantic_attempts ADD COLUMN tokens_known INTEGER NOT NULL DEFAULT 0",
        "failure_class": "ALTER TABLE semantic_attempts ADD COLUMN failure_class TEXT",
        "failure_reason": "ALTER TABLE semantic_attempts ADD COLUMN failure_reason TEXT",
        "effective_model": "ALTER TABLE semantic_attempts ADD COLUMN effective_model TEXT NOT NULL DEFAULT ''",
        "model_usage_json": "ALTER TABLE semantic_attempts ADD COLUMN model_usage_json TEXT NOT NULL DEFAULT ''",
        "accepted_semantic_sha256": "ALTER TABLE semantic_attempts ADD COLUMN accepted_semantic_sha256 TEXT NOT NULL DEFAULT ''",
        "accepted_candidate_sha": "ALTER TABLE semantic_attempts ADD COLUMN accepted_candidate_sha TEXT NOT NULL DEFAULT ''",
        "accepted_at": "ALTER TABLE semantic_attempts ADD COLUMN accepted_at REAL NOT NULL DEFAULT 0",
    }
    cost_known_added = "cost_known" not in attempt_columns
    for name, statement in attempt_migrations.items():
        if name not in attempt_columns:
            conn.execute(statement)
    if cost_known_added:
        conn.execute(
            "UPDATE semantic_attempts SET cost_known=0 WHERE status='COST_UNKNOWN'"
        )

    if data_migrations is not None:
        data_migrations(conn)

    import time as _time
    now = _time.time()
    conn.execute(
        "INSERT OR IGNORE INTO supervisor_config(key, value, updated_at) VALUES (?, ?, ?)",
        (_CONFIG_MAX_CONCURRENCY, str(DEFAULT_MAX_CONCURRENCY), now),
    )
    conn.execute(
        "INSERT OR IGNORE INTO scheduler_meta(id, dispatch_sequence, single_since_program, updated_at) VALUES (1, 0, 0, ?)",
        (now,),
    )
    conn.commit()


# ---------------------------------------------------------------------------
# Connection management.
# ---------------------------------------------------------------------------

def _connect(
    path: Path,
    *,
    data_migrations: Callable[[sqlite3.Connection], None] | None = None,
) -> sqlite3.Connection:
    """Open (and create if missing) the supervisor ledger with full bootstrap.

    ``data_migrations`` is the supervisor-owned cross-domain migration
    seam — see ``bootstrap_schema`` for the rationale.
    """
    path = Path(path).expanduser().resolve(strict=False)
    path.parent.mkdir(parents=True, exist_ok=True)
    managed_state_root = default_db_path().parent.expanduser().resolve(strict=False)
    if path.parent == managed_state_root:
        _ensure_private_dir(path.parent)
    conn = sqlite3.connect(path, timeout=30)
    _ensure_private_file_mode(path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=FULL")
    bootstrap_schema(conn, data_migrations=data_migrations)
    return conn


@contextmanager
def _managed_connect(
    path: Path,
    *,
    data_migrations: Callable[[sqlite3.Connection], None] | None = None,
) -> Iterator[sqlite3.Connection]:
    """Commit/rollback through sqlite's context protocol, then close it.

    ``sqlite3.Connection`` implements transaction context management
    but does not close itself on ``__exit__``.  This distinction
    becomes a descriptor leak when multiple execution lanes
    repeatedly open their own connections.  ``_managed_connect``
    closes the connection on exit and tracks per-thread connection
    depth so the supervisor's execution-lock author can reason
    about nested DB usage.
    """
    conn = _connect(path, data_migrations=data_migrations)
    tid = threading.get_ident()
    with _LOCAL_EXECUTION_LOCK:
        _LOCAL_CONNECTION_DEPTH[tid] = _LOCAL_CONNECTION_DEPTH.get(tid, 0) + 1
    try:
        with conn:
            yield conn
    finally:
        conn.close()
        with _LOCAL_EXECUTION_LOCK:
            remaining = _LOCAL_CONNECTION_DEPTH.get(tid, 1) - 1
            if remaining <= 0:
                _LOCAL_CONNECTION_DEPTH.pop(tid, None)
            else:
                _LOCAL_CONNECTION_DEPTH[tid] = remaining


def _connect_readonly(path: Path) -> sqlite3.Connection:
    """Open an existing supervisor ledger without schema/data mutation."""
    p = Path(path).expanduser().resolve(strict=False)
    if not p.is_file():
        raise FileNotFoundError(str(p))
    conn = sqlite3.connect(f"file:{p}?mode=ro", uri=True, timeout=5)
    conn.row_factory = sqlite3.Row
    return conn


@contextmanager
def _managed_connect_readonly(path: Path) -> Iterator[sqlite3.Connection]:
    """Context manager wrapping ``_connect_readonly`` with explicit close."""
    conn = _connect_readonly(path)
    try:
        yield conn
    finally:
        conn.close()
