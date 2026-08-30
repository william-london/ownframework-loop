#!/usr/bin/env bash
# v0.8.1 closure — runtime-generation contract, install/refresh safety, and
# ledger migration semantics.
#
# Independent-review findings covered:
#   F1  runtime-generation safety: a sealed unfinished PROGRAM must not
#       silently change runtime generation between passes (QUEUED, BACKOFF,
#       QUARANTINED-but-resumable all count); terminal DONE jobs never
#       block a normal install; explicit unsafe migration override;
#       fail-closed execution on generation mismatch; clean resume rebind.
#   F3  ledger defaults: fresh databases and migrations must not inject
#       the retired $25 / 8-hour conservation ceilings; explicitly
#       configured historical limits are preserved.
#
# ALL installer invocations here are hermetic: fake HOME, fake
# XDG_STATE_HOME, and a launchctl shim that refuses to touch the real
# machine even if the guard regressed. No model is called.

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

TMP="$(mktemp -d -t ofloop_v080_gen.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

GUARD_HOME="$TMP/home"
GUARD_SHIMS="$TMP/shims"
mkdir -p "$GUARD_HOME" "$GUARD_SHIMS"
printf '#!/bin/sh\necho "launchctl disabled in hermetic test" >&2\nexit 127\n' \
  > "$GUARD_SHIMS/launchctl"
chmod +x "$GUARD_SHIMS/launchctl"

run_installer() {
  # run_installer <state-root> [extra env KEY=VAL ...] — hermetic invocation.
  local state_root="$1"; shift
  env PATH="$GUARD_SHIMS:$PATH" HOME="$GUARD_HOME" XDG_STATE_HOME="$state_root" "$@" \
    bash "$ROOT_DIR/install-supervisor-macos.sh" 2>&1
}

make_ledger() {
  # make_ledger <state-root> -> creates supervisor.sqlite3 with jobs rows.
  local state_root="$1"
  mkdir -p "$state_root/ownframework-loop"
  PYTHONPATH="$LIB_DIR" python3 -B - "$state_root" <<'PY'
import sqlite3, sys, time
from pathlib import Path
db = Path(sys.argv[1]) / "ownframework-loop" / "supervisor.sqlite3"
conn = sqlite3.connect(str(db))
conn.executescript("""
CREATE TABLE jobs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repo TEXT NOT NULL, run_id TEXT NOT NULL,
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
  last_error TEXT, last_failure_class TEXT, last_failure_reason TEXT,
  next_attempt_at REAL NOT NULL DEFAULT 0,
  created_at REAL NOT NULL, updated_at REAL NOT NULL,
  worker_pid INTEGER, worker_started_at REAL, worker_role TEXT,
  max_total_cost_usd REAL NOT NULL DEFAULT 0,
  max_total_tokens INTEGER NOT NULL DEFAULT 0,
  max_wall_seconds INTEGER NOT NULL DEFAULT 0,
  execution_started_at REAL,
  worker_stdout_path TEXT, worker_stderr_path TEXT,
  runtime_generation TEXT NOT NULL DEFAULT '',
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
  failure_class TEXT,
  failure_reason TEXT
);
""")
conn.commit()
print(db)
PY
}

add_job() {
  # add_job <state-root> <run-id> <status> <generation> [worker-pid]
  local state_root="$1" run_id="$2" status="$3" gen="$4" pid="${5:-0}"
  sqlite3 "$state_root/ownframework-loop/supervisor.sqlite3" \
    "INSERT INTO jobs (repo, run_id, runner, status, worker_pid, worker_started_at, runtime_generation, created_at, updated_at)
     VALUES ('/tmp/anywhere', '$run_id', 'claude-code', '$status', $pid, $(date +%s), '$gen', $(date +%s), $(date +%s));"
}

INCOMING_GENERATION="$(PYTHONPATH="$LIB_DIR" python3 -B -c \
  'from ownframework_loop import supervisor; print(supervisor.runtime_generation())')"
OTHER_GENERATION="ofloop-0.0.1@deadbeefdeadbeef"

# ---------------------------------------------------------------------------
# T1: live semantic worker refuses replacement (regression, hermetic).
# ---------------------------------------------------------------------------
S1="$TMP/state-live-worker"
make_ledger "$S1" >/dev/null
add_job "$S1" "run-live" "RUNNING" "$INCOMING_GENERATION" "$$"
set +e
OUT1="$(run_installer "$S1")"; RC1=$?
set -e
[[ "$RC1" -eq 11 ]] || fail "T1 live worker must refuse rc=11 (rc=$RC1 out=$OUT1)"
assert_contains "$OUT1" "reason=active_semantic_work" "T1 live semantic worker refuses replacement"

# ---------------------------------------------------------------------------
# T2: QUEUED job bound to another generation refuses replacement.
# ---------------------------------------------------------------------------
S2="$TMP/state-queued"
make_ledger "$S2" >/dev/null
add_job "$S2" "run-queued" "QUEUED" "$OTHER_GENERATION"
set +e
OUT2="$(run_installer "$S2")"; RC2=$?
set -e
[[ "$RC2" -eq 13 ]] || fail "T2 QUEUED generation dependency must refuse rc=13 (rc=$RC2 out=$OUT2)"
assert_contains "$OUT2" "reason=runtime_generation_dependency" "T2 QUEUED run bound to another generation refuses"

# ---------------------------------------------------------------------------
# T3: BACKOFF job bound to another generation refuses replacement.
# ---------------------------------------------------------------------------
S3="$TMP/state-backoff"
make_ledger "$S3" >/dev/null
add_job "$S3" "run-backoff" "BACKOFF" "$OTHER_GENERATION"
set +e
OUT3="$(run_installer "$S3")"; RC3=$?
set -e
[[ "$RC3" -eq 13 ]] || fail "T3 BACKOFF generation dependency must refuse (rc=$RC3 out=$OUT3)"
assert_contains "$OUT3" "reason=runtime_generation_dependency" "T3 BACKOFF run bound to another generation refuses"

# ---------------------------------------------------------------------------
# T4: QUARANTINED-but-resumable job bound to another generation refuses.
# ---------------------------------------------------------------------------
S4="$TMP/state-quarantined"
make_ledger "$S4" >/dev/null
add_job "$S4" "run-quarantined" "QUARANTINED" "$OTHER_GENERATION"
set +e
OUT4="$(run_installer "$S4")"; RC4=$?
set -e
[[ "$RC4" -eq 13 ]] || fail "T4 QUARANTINED generation dependency must refuse (rc=$RC4 out=$OUT4)"
assert_contains "$OUT4" "reason=runtime_generation_dependency" "T4 resumable QUARANTINED run refuses generation swap"

# ---------------------------------------------------------------------------
# T5: RUNNING job with DEAD worker but foreign generation still refuses —
#     the live-worker probe passes, the generation dependency must catch it.
# ---------------------------------------------------------------------------
S5="$TMP/state-dead-worker"
make_ledger "$S5" >/dev/null
add_job "$S5" "run-dead-worker" "RUNNING" "$OTHER_GENERATION" 999999
set +e
OUT5="$(run_installer "$S5")"; RC5=$?
set -e
[[ "$RC5" -eq 13 ]] || fail "T5 dead-worker foreign generation must refuse (rc=$RC5 out=$OUT5)"
assert_contains "$OUT5" "reason=runtime_generation_dependency" "T5 dead worker does not hide a generation dependency"

# ---------------------------------------------------------------------------
# T6: terminal DONE jobs bound to another generation never block install.
# ---------------------------------------------------------------------------
S6="$TMP/state-done"
make_ledger "$S6" >/dev/null
add_job "$S6" "run-done" "DONE" "$OTHER_GENERATION"
set +e
OUT6="$(run_installer "$S6")"; RC6=$?
set -e
assert_not_contains "$OUT6" "SUPERVISOR_INSTALL=REFUSED" "T6 terminal DONE job never blocks a normal install"
# Hermetic end: the shim launchctl terminates the pass path harmlessly.
[[ "$RC6" -ne 11 && "$RC6" -ne 13 ]] || fail "T6 unexpected refusal rc=$RC6"
pass "T6 install proceeds past the guard for terminal-only ledgers"

# ---------------------------------------------------------------------------
# T7: same-generation refresh is allowed (QUEUED bound to incoming).
# ---------------------------------------------------------------------------
S7="$TMP/state-same-gen"
make_ledger "$S7" >/dev/null
add_job "$S7" "run-same" "QUEUED" "$INCOMING_GENERATION"
set +e
OUT7="$(run_installer "$S7")"; RC7=$?
set -e
assert_not_contains "$OUT7" "SUPERVISOR_INSTALL=REFUSED" "T7 same-generation refresh is not refused"
pass "T7 same-generation refresh proceeds (rc=$RC7 via hermetic shim)"

# ---------------------------------------------------------------------------
# T8: explicit migration override bypasses the generation guard (unsafe,
#     documented) — runs then quarantine-on-mismatch at serve time.
# ---------------------------------------------------------------------------
S8="$TMP/state-migration"
make_ledger "$S8" >/dev/null
add_job "$S8" "run-migrate" "QUEUED" "$OTHER_GENERATION"
set +e
OUT8="$(run_installer "$S8" OFLOOP_ALLOW_RUNTIME_GENERATION_MIGRATION=1)"; RC8=$?
set -e
assert_not_contains "$OUT8" "SUPERVISOR_INSTALL=REFUSED" "T8 explicit migration override bypasses the guard"
pass "T8 OFLOOP_ALLOW_RUNTIME_GENERATION_MIGRATION=1 is the explicit unsafe path"

# ---------------------------------------------------------------------------
# T9: supervisor execution contract — binding, mismatch fail-closed, adoption
#     of legacy unbound rows, and resume rebind (behavioral, no installer).
# ---------------------------------------------------------------------------
PYTHONPATH="$LIB_DIR" python3 -B - "$TMP" <<'PY'
import json, os, sqlite3, sys
sys.path.insert(0, os.path.join(os.getcwd(), "lib"))
from pathlib import Path
from ownframework_loop import supervisor

tmp = Path(sys.argv[1])
db = tmp / "contract.sqlite3"
repo = tmp / "contract-repo"
repo.mkdir(exist_ok=True)
gen = supervisor.runtime_generation()

# Enqueue binds the enqueuing generation.
job = supervisor.enqueue(canonical_repo=repo, run_id="run-gen", db_path=db)
conn = sqlite3.connect(str(db))
bound = conn.execute(
    "SELECT runtime_generation FROM jobs WHERE run_id='run-gen'"
).fetchone()[0]
assert bound == gen, (bound, gen)

# A job bound to a foreign generation is quarantined fail-closed by run_one.
conn.execute(
    "UPDATE jobs SET status='QUEUED', runtime_generation='ofloop-0.0.1@deadbeefdeadbeef', "
    "next_attempt_at=0 WHERE run_id='run-gen'"
)
conn.commit()
conn.close()
res = supervisor.run_one(db_path=db)
assert res["action"] == "QUARANTINED", res
assert res["reason"] == "runtime_generation_mismatch", res
assert res["bound_runtime_generation"] == "ofloop-0.0.1@deadbeefdeadbeef", res
assert res["serving_runtime_generation"] == gen, res

# Resume is the explicit migration: it rebinds and reports the previous binding.
res2 = supervisor.resume(canonical_repo=repo, run_id="run-gen", db_path=db)
assert res2["ok"], res2
assert res2["runtime_generation_previous"] == "ofloop-0.0.1@deadbeefdeadbeef", res2
assert res2["runtime_generation"] == gen, res2
print("GENERATION_CONTRACT=OK")
PY
pass "T9 generation binding: mismatch quarantines fail-closed; resume rebinds explicitly"

# ---------------------------------------------------------------------------
# T10: a legacy UNBOUND unfinished job fails closed until explicit migration.
# ---------------------------------------------------------------------------
PYTHONPATH="$LIB_DIR" python3 -B - "$TMP" <<'PY'
import sqlite3, sys
from pathlib import Path
sys.path.insert(0, str(Path.cwd() / "lib"))
from ownframework_loop import supervisor

tmp = Path(sys.argv[1])
db = tmp / "unbound.sqlite3"
repo = tmp / "unbound-repo"
repo.mkdir(exist_ok=True)

supervisor.enqueue(
    canonical_repo=repo,
    run_id="run-unbound",
    db_path=db,
    runtime_generation="ofloop-legacy@known",
)
conn = sqlite3.connect(str(db))
conn.execute(
    "UPDATE jobs SET runtime_generation='', status='QUEUED', next_attempt_at=0 "
    "WHERE run_id='run-unbound'"
)
conn.commit()
conn.close()

res = supervisor.run_one(db_path=db)
assert res["action"] == "QUARANTINED", res
assert res["reason"] == "runtime_generation_unbound", res

res2 = supervisor.resume(canonical_repo=repo, run_id="run-unbound", db_path=db)
assert res2["ok"], res2
assert res2["runtime_generation"], res2
assert res2["runtime_generation_previous"] == "", res2
print("LEGACY_UNBOUND_FAIL_CLOSED=OK")
PY
pass "T10 legacy unbound unfinished jobs fail closed until explicit resume/rebind"

# ---------------------------------------------------------------------------
# T11: ledger defaults — fresh databases are disabled-by-default; legacy
#      fingerprint rows are normalized once; explicit values preserved.
# ---------------------------------------------------------------------------
PYTHONPATH="$LIB_DIR" python3 -B - "$TMP" <<'PY'
import os, sqlite3, sys
sys.path.insert(0, os.path.join(os.getcwd(), "lib"))
from pathlib import Path
from ownframework_loop import supervisor

tmp = Path(sys.argv[1])
db = tmp / "ledger.sqlite3"
repo = tmp / "ledger-repo"
repo.mkdir(exist_ok=True)

# Fresh database: enqueue materializes DISABLED ceilings, not $25/8h.
job = supervisor.enqueue(canonical_repo=repo, run_id="run-fresh-ledger", db_path=db)
conn = sqlite3.connect(str(db))
row = conn.execute(
    "SELECT max_total_cost_usd, max_wall_seconds, max_total_tokens FROM jobs WHERE run_id='run-fresh-ledger'"
).fetchone()
assert tuple(row) == (0.0, 0, 0), row
conn.close()

# Legacy ledger with retired-default rows BEFORE first upgraded contact.
db2 = tmp / "ledger2.sqlite3"
conn = sqlite3.connect(str(db2))
conn.executescript("""
CREATE TABLE jobs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repo TEXT NOT NULL, run_id TEXT NOT NULL,
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
  last_error TEXT, last_failure_class TEXT, last_failure_reason TEXT,
  next_attempt_at REAL NOT NULL DEFAULT 0,
  created_at REAL NOT NULL, updated_at REAL NOT NULL,
  worker_pid INTEGER, worker_started_at REAL, worker_role TEXT,
  max_total_cost_usd REAL NOT NULL DEFAULT 25,
  max_total_tokens INTEGER NOT NULL DEFAULT 0,
  max_wall_seconds INTEGER NOT NULL DEFAULT 28800,
  execution_started_at REAL,
  worker_stdout_path TEXT, worker_stderr_path TEXT,
  UNIQUE(repo, run_id)
);
""")
conn.execute(
    "INSERT INTO jobs (repo, run_id, runner, status, max_total_cost_usd, max_wall_seconds, created_at, updated_at) "
    "VALUES (?,?,?,'DONE',25.0,28800,1,1)", (str(repo), "run-legacy-default", "claude-code"))
conn.execute(
    "INSERT INTO jobs (repo, run_id, runner, status, max_total_cost_usd, max_total_tokens, max_wall_seconds, created_at, updated_at) "
    "VALUES (?,?,?,'DONE',25.0,500,28800,1,1)", (str(repo), "run-explicit-intent", "claude-code"))
conn.commit()
conn.close()

supervisor.enqueue(canonical_repo=repo, run_id="run-fresh2", db_path=db2)
conn = supervisor._connect(db2)
rows = {
    r["run_id"]: (
        r["max_total_cost_usd"], r["max_wall_seconds"],
        r["max_total_tokens"], r["legacy_budget_ambiguous"],
    )
    for r in conn.execute(
        "SELECT run_id, max_total_cost_usd, max_wall_seconds, "
        "max_total_tokens, legacy_budget_ambiguous FROM jobs"
    ).fetchall()
}
assert rows["run-legacy-default"] == (25.0, 28800, 0, 1), rows
assert rows["run-explicit-intent"] == (25.0, 28800, 500, 0), rows
assert rows["run-fresh2"] == (0.0, 0, 0, 0), rows
assert int(conn.execute("PRAGMA user_version").fetchone()[0]) == supervisor.SCHEMA_DATA_VERSION
conn.close()
print("LEDGER_DEFAULTS=OK")
PY
pass "T11 fresh defaults disabled; ambiguous historical fingerprint preserved and flagged"

echo "V080_RUNTIME_GENERATION=PASS"
