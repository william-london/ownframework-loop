#!/usr/bin/env bash
# v1.0.0 progress-watchdog coverage.
#
# The watchdog detects the "Claude alive, zero observable progress" failure
# mode that the wallclock deadline alone cannot: a worker that occupies
# a pass slot for the full max_pass_runtime_seconds without producing
# any token or tool-output progress.
#
# These tests:
#   1. prove the deterministic Signature comparison (advanced=vs=)
#   2. prove the watchdog window derivation against packet budgets
#   3. prove the supervisor tick terminates a no-progress worker and
#      queues a retry rather than waiting the full deadline.
set -euo pipefail
. "$(dirname "$0")/../_helpers.sh"

ROOT="$ROOT_DIR"

# ---------------------------------------------------------------------------
# 1. Pure-logic signature comparison
# ---------------------------------------------------------------------------
python3 - "$ROOT" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / "lib"))
from ownframework_loop import progress_watchdog as pw

before = pw.Signature(stdout_size=0, stdout_mtime=1, stderr_size=302, stderr_mtime=1, worktree_head="abc", worktree_max_mtime=100, worktree_file_count=3)

# a. any single surface advance counts
advance_stdout  = pw.Signature(**{**before.__dict__, "stdout_size": 1})
advance_stderr  = pw.Signature(**{**before.__dict__, "stderr_size": 303})
advance_head    = pw.Signature(**{**before.__dict__, "worktree_head": "def"})
advance_maxm    = pw.Signature(**{**before.__dict__, "worktree_max_mtime": 101})
advance_count   = pw.Signature(**{**before.__dict__, "worktree_file_count": 4})
unchanged       = pw.Signature(**before.__dict__)

assert pw.signature_advanced(before, advance_stdout), "stdout size must advance"
assert pw.signature_advanced(before, advance_stderr), "stderr size must advance"
assert pw.signature_advanced(before, advance_head),   "worktree HEAD change must advance"
assert pw.signature_advanced(before, advance_maxm),   "worktree max-mtime forward must advance"
assert pw.signature_advanced(before, advance_count),  "worktree file-count change must advance"
assert not pw.signature_advanced(before, unchanged),   "identical signature must NOT advance"
assert not pw.signature_advanced(before, before),     "self must NOT advance"
print("PASS signature_advanced recognizes every axis + non-advance")
PY

# ---------------------------------------------------------------------------
# 2. Window derivation
# ---------------------------------------------------------------------------
python3 - "$ROOT" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / "lib"))
from ownframework_loop.progress_watchdog import watchdog_window_seconds, DEFAULT_WATCHDOG_WINDOW_SECONDS

# Default floor for any positive budget
assert watchdog_window_seconds(0)  == DEFAULT_WATCHDOG_WINDOW_SECONDS
assert watchdog_window_seconds(30) == DEFAULT_WATCHDOG_WINDOW_SECONDS

# Sub-floor budgets honor DEFAULT
assert watchdog_window_seconds(59) == DEFAULT_WATCHDOG_WINDOW_SECONDS

# Floor+budget-6th for reasonable budgets
assert watchdog_window_seconds(60)  == DEFAULT_WATCHDOG_WINDOW_SECONDS     # 60//6 == 10 < default
assert watchdog_window_seconds(180) == DEFAULT_WATCHDOG_WINDOW_SECONDS     # 180//6 == 30 < default
assert watchdog_window_seconds(1800) == 300                                # 1800//6 == 300
assert watchdog_window_seconds(3600) == 600                                # 3600//6 == 600
assert watchdog_window_seconds(7200) == 1200                               # 7200//6 == 1200
print("PASS watchdog_window_seconds honors bounded floor+budget // 6")
PY

# ---------------------------------------------------------------------------
# 3. Tick terminates a no-progress worker
# ---------------------------------------------------------------------------
python3 - "$ROOT" <<'PY'
import sys, time, sqlite3
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / "lib"))

# Build a minimal sqlite ledger that mirrors the supervisor schema columns
# the watchdog tick touches. We deliberately avoid bootstrap_schema so this
# test does not depend on the entire supervisor init.
tmpdir = Path("/tmp/ofloop-watchdog-test-tick")
if tmpdir.exists():
    import shutil
    shutil.rmtree(str(tmpdir))
tmpdir.mkdir()
db = tmpdir / "ledger.sqlite3"

SCHEMA = """
CREATE TABLE jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    repo TEXT NOT NULL,
    run_id TEXT NOT NULL,
    runner TEXT NOT NULL DEFAULT 'claude-code',
    status TEXT NOT NULL DEFAULT 'QUEUED',
    infra_failures INTEGER NOT NULL DEFAULT 0,
    max_infra_failures INTEGER NOT NULL DEFAULT 3,
    progress_stall_count INTEGER NOT NULL DEFAULT 0,
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
    worker_attempt_id TEXT,
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
    max_pass_runtime_seconds INTEGER NOT NULL DEFAULT 1800,
    progress_signature_stdout_size INTEGER NOT NULL DEFAULT -1,
    progress_signature_stdout_mtime REAL NOT NULL DEFAULT 0,
    progress_signature_stderr_size INTEGER NOT NULL DEFAULT -1,
    progress_signature_stderr_mtime REAL NOT NULL DEFAULT 0,
    progress_signature_worktree_head TEXT NOT NULL DEFAULT '',
    progress_signature_worktree_max_mtime REAL NOT NULL DEFAULT 0,
    progress_signature_worktree_file_count INTEGER NOT NULL DEFAULT -1,
    progress_signature_at REAL NOT NULL DEFAULT 0,
    progress_watchdog_window_seconds INTEGER NOT NULL DEFAULT 0,
    latest_attempt_id TEXT NOT NULL DEFAULT '',
    UNIQUE(repo, run_id)
);
CREATE TABLE semantic_attempts (
    attempt_id TEXT PRIMARY KEY,
    job_id INTEGER NOT NULL,
    role TEXT NOT NULL,
    status TEXT NOT NULL,
    started_at REAL NOT NULL,
    completed_at REAL,
    worker_pid INTEGER,
    stdout_path TEXT NOT NULL,
    stderr_path TEXT NOT NULL,
    returncode INTEGER,
    cost_usd REAL NOT NULL DEFAULT 0,
    cost_accounted INTEGER NOT NULL DEFAULT 0,
    input_tokens INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0,
    cache_read_tokens INTEGER NOT NULL DEFAULT 0,
    cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
    tokens_known INTEGER NOT NULL DEFAULT 0,
    cost_known INTEGER NOT NULL DEFAULT 1,
    failure_class TEXT,
    failure_reason TEXT
);
"""
conn = sqlite3.connect(str(db))
conn.executescript(SCHEMA)
conn.commit()
conn.close()

import importlib
pw = importlib.import_module("ownframework_loop.progress_watchdog")

conn = sqlite3.connect(str(db))
conn.row_factory = sqlite3.Row
now = time.time()

# Insert one running job whose stored signature is far in the past (worker
# is supposedly running but produced nothing for >> window).
conn.execute(
    """INSERT INTO jobs(
        repo, run_id, status, worker_pid, worker_started_at,
        worker_pgid, worker_role, worker_stdout_path, worker_stderr_path,
        worker_deadline_at, max_pass_runtime_seconds,
        progress_signature_at,
        progress_signature_stdout_size, progress_signature_stdout_mtime,
        progress_signature_stderr_size, progress_signature_stderr_mtime,
        progress_signature_worktree_head, progress_signature_worktree_max_mtime,
        progress_signature_worktree_file_count,
        created_at, updated_at, latest_attempt_id
    ) VALUES (
        '/tmp/somewhere', 'run-progress-stall-test', 'RUNNING',
        99999, ?, 99999, 'builder',
        '/tmp/does-not-exist-stdout.log',
        '/tmp/does-not-exist-stderr.log',
        ?, 1800, ?, 0, 0, 0, 0, '', 0, -1, ?, ?, 'attempt-stall-test'
    )""",
    (
        now - 60,         # worker_started_at (recent)
        now + 1740,       # worker_deadline_at (well in the future)
        now - 600,        # progress_signature_at (window of 180s ago)
        now,              # created_at
        now,              # updated_at
    ),
)
# Insert a matching semantic_attempts RUNNING row that the tick will mark FAILED
conn.execute(
    """INSERT INTO semantic_attempts(
        attempt_id, job_id, role, status, started_at,
        stdout_path, stderr_path
    ) VALUES (
        'attempt-stall-test', 1, 'builder', 'RUNNING', ?,
        '/tmp/does-not-exist-stdout.log', '/tmp/does-not-exist-stderr.log'
    )""",
    (now - 600,),
)
conn.commit()

# Fake terminate: accept everything, record invocations
calls = []
def fake_term(pid, pgid, identity, started_at):
    calls.append((pid, pgid, identity, started_at))
    return True

summary = pw.tick(conn, terminate=fake_term)
print("tick summary:", summary)

# Debug the row contents + tick math
import time as _t
_now = _t.time()
for r in conn.execute(
    "SELECT id, run_id, status, worker_deadline_at, max_pass_runtime_seconds, "
    "       progress_signature_at, worker_role, worker_pid FROM jobs WHERE run_id='run-progress-stall-test'"
).fetchall():
    d = dict(r)
    print("row:", d)
    _d = d["worker_deadline_at"] or 0
    print("  now:", _now, "deadline:", d["worker_deadline_at"],
          "deadline>now:", bool(_d and _d > _now),
          "sig_at:", d["progress_signature_at"],
          "window:", max(pw.DEFAULT_WATCHDOG_WINDOW_SECONDS, d["max_pass_runtime_seconds"] // 6),
          "elapsed_since_sig:", _now - d["progress_signature_at"])

assert summary["terminated"] == 1, f"expected 1 terminate, got {summary['terminated']}"
assert calls, "terminate callable not invoked"

# Job should now be QUEUED with progress_stall_count incremented and
# transient_failures incremented (bounded retry).
row = conn.execute(
    "SELECT status, last_failure_class, progress_stall_count, "
    "       transient_failures, worker_pid FROM jobs WHERE run_id='run-progress-stall-test'"
).fetchone()
assert row[0] == "QUEUED", f"job status after stall: {row[0]}"
assert row[1] == "progress_stalled", f"failure class: {row[1]}"
assert int(row[2]) == 1, f"progress_stall_count: {row[2]}"
assert int(row[3]) == 1, f"transient_failures: {row[3]}"
assert row[4] is None, f"worker_pid: {row[4]} (should be NULL)"

# semantic_attempts should now be FAILED with class progress_stalled
att = conn.execute(
    "SELECT status, failure_class, failure_reason FROM semantic_attempts WHERE attempt_id='attempt-stall-test'"
).fetchone()
assert att[0] == "FAILED", f"attempt status: {att[0]}"
assert att[1] == "progress_stalled", f"attempt class: {att[1]}"
assert "watchdog_no_progress_window" in att[2], f"attempt reason: {att[2]}"

print("PASS tick terminates stuck attempt + queues retry + records FAILED row")
PY

echo
echo "ALL PROGRESS-WATCHDOG TESTS PASS"
