#!/usr/bin/env bash
# v0.6 supervisor architecture — no model/provider required.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

ROOT="$ROOT_DIR"
OFLOOP="$OFLOOP_BIN"

# 1. Legacy unattended orchestrator is retired, not silently approving.
set +e
LEGACY_OUT="$($OFLOOP loop run /tmp --run-id ghost 2>&1)"
LEGACY_RC=$?
set -e
[[ "$LEGACY_RC" -ne 0 ]] || fail "legacy loop run unexpectedly succeeded"
echo "$LEGACY_OUT" | grep -Fq 'legacy_unattended_orchestrator_retired_use_supervisor' \
  || fail "legacy loop run did not surface retirement reason"
pass "legacy unattended orchestrator is retired"

# 2. Supervisor store is durable/idempotent operational state only.
DB="$(mktemp -t ofloop-supervisor.XXXXXX.sqlite3)"
PYTHONPATH="$LIB_DIR" python3 - "$DB" <<'PY'
import sys, tempfile
from pathlib import Path
from ownframework_loop import supervisor

db = Path(sys.argv[1])
repo = Path(tempfile.mkdtemp(prefix="ofloop-supervisor-repo-"))
a = supervisor.enqueue(canonical_repo=repo, run_id="run-test", db_path=db)
b = supervisor.enqueue(canonical_repo=repo, run_id="run-test", db_path=db)
s = supervisor.status(canonical_repo=repo, run_id="run-test", db_path=db)
assert a["id"] == b["id"] == s["id"], (a, b, s)
assert s["status"] == "QUEUED", s
print("PASS supervisor queue idempotent")
PY

# 3. Stale RUNNING recovery is PID-aware and never duplicates a live owner.
PYTHONPATH="$LIB_DIR" python3 - "$DB" <<'PY'
import os, sqlite3, sys, tempfile
from pathlib import Path
from ownframework_loop import supervisor

db = Path(sys.argv[1])
repo = Path(tempfile.mkdtemp(prefix="ofloop-supervisor-recovery-"))
supervisor.enqueue(canonical_repo=repo, run_id="run-dead", db_path=db)
supervisor.enqueue(canonical_repo=repo, run_id="run-live", db_path=db)
with supervisor._connect(db) as conn:
    conn.execute(
        "UPDATE jobs SET status='RUNNING', worker_pid=? WHERE run_id='run-dead'",
        (99999999,),
    )
    conn.execute(
        "UPDATE jobs SET status='RUNNING', worker_pid=? WHERE run_id='run-live'",
        (os.getpid(),),
    )
    conn.commit()
    recovered = supervisor._recover_stale_running(conn)
    dead = conn.execute("SELECT status FROM jobs WHERE run_id='run-dead'").fetchone()[0]
    live = conn.execute("SELECT status FROM jobs WHERE run_id='run-live'").fetchone()[0]
assert recovered == 1, recovered
assert dead == "QUEUED", dead
assert live == "RUNNING", live
assert supervisor._take_next_job(conn) is None, "global worker fence allowed a second job"
print("PASS supervisor recovery preserves live owner and global one-worker fence")
PY

# Operational budgets are durable supervisor policy, not protocol state.
DB_CAP="$(mktemp -t ofloop-supervisor-cap.XXXXXX.sqlite3)"
PYTHONPATH="$LIB_DIR" python3 - "$DB_CAP" <<'PY'
import sys, tempfile
from pathlib import Path
from ownframework_loop import supervisor
db = Path(sys.argv[1])
repo = Path(tempfile.mkdtemp(prefix="ofloop-supervisor-caps-"))
supervisor.enqueue(
    canonical_repo=repo,
    run_id="run-cap",
    db_path=db,
    max_total_cost_usd=7.5,
    max_wall_seconds=1234,
)
s = supervisor.status(canonical_repo=repo, run_id="run-cap", db_path=db)
assert s["max_total_cost_usd"] == 7.5, s
assert s["max_wall_seconds"] == 1234, s
print("PASS supervisor operational ceilings persist")
PY

# 4. Fresh human-originated run dispatches BUILD with deterministic preparation.
T="$(make_tmp_repo)"
RID="$(make_approved_run_unapproved "$T" FEATURE low "v060-dispatch")"
OUT="$($OFLOOP dispatch claim "$T" "$RID")"
assert_eq "$(printf '%s' "$OUT" | jq -r '.decision')" "BUILD" "dispatch decision BUILD"
assert_eq "$(printf '%s' "$OUT" | jq -r '.state')" "BUILDING" "dispatch state BUILDING"
SEM="$(printf '%s' "$OUT" | jq -r '.semantic_path')"
WT="$(printf '%s' "$OUT" | jq -r '.worktree')"
assert_file_exists "$SEM" "dispatch materialized pass-scoped builder semantic skeleton"
assert_dir_exists "$WT" "dispatch materialized deterministic builder worktree"
assert_eq "$(jq -r '.approval_method' "$T/.ownframework-loop/$RID/APPROVAL.json")" "build_start" "dispatch uses no-ceremony execution seal"

# Skeleton presence is not semantic completion.
PYTHONPATH="$LIB_DIR" python3 - "$T" "$RID" "$OUT" <<'PY'
import json, sys
from pathlib import Path
from ownframework_loop import dispatch
order = json.loads(sys.argv[3])
ready, reason = dispatch.semantic_result_ready(order)
assert not ready and reason == "builder_summary_empty", (ready, reason)
p = Path(order["semantic_path"])
d = json.loads(p.read_text())
d["summary"] = "semantic work completed"
d["unit_ids_completed"] = ["UNIT-1"]
d["acceptance_addressed"] = ["AC-1"]
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
ready, reason = dispatch.semantic_result_ready(order)
assert ready and reason == "ready", (ready, reason)
print("PASS semantic completion distinguishes skeleton from completed pass")
PY

# 5. Re-dispatch of same claimed pass is replay, not another budget unit.
OUT2="$($OFLOOP dispatch claim "$T" "$RID")"
assert_eq "$(printf '%s' "$OUT2" | jq -r '.decision')" "BUILD" "re-dispatch remains BUILD"
assert_eq "$(printf '%s' "$OUT2" | jq -r '.replayed')" "true" "re-dispatch is replay"
assert_eq "$(jq -r '.build_pass_count' "$T/.ownframework-loop/$RID/STATE.json")" "1" "re-dispatch consumes one pass"

# 6. Packet-supplied validation commands are mechanically classified before execution.
grep -Fq 'required_validation command refused by deterministic guard' "$ROOT/lib/ownframework_loop/build_finalize.py" \
  || fail "build finalizer missing required-validation guard"
grep -Fq 'required_validation command refused by deterministic guard' "$ROOT/lib/ownframework_loop/review_finalize.py" \
  || fail "review finalizer missing required-validation guard"
pass "required-validation shell authority is mechanically guarded"

# 7. Supervisor contains no engineering-state transition table.
if grep -Eq 'READY_TO_BUILD|READY_FOR_REVIEW|CHANGES_REQUESTED|REVIEWING|BUILDING' "$ROOT/lib/ownframework_loop/supervisor.py"; then
  fail "supervisor reimplemented engineering state machine"
fi
grep -Fq 'dispatch_mod.claim_next' "$ROOT/lib/ownframework_loop/supervisor.py" \
  || fail "supervisor does not consume dispatch owner"
pass "supervisor is execution clock, not second engineering state machine"

# 8. macOS service packaging is syntax-valid and launchd-owned.
bash -n "$ROOT/install-supervisor-macos.sh"
bash -n "$ROOT/uninstall-supervisor-macos.sh"
grep -Fq 'launchctl bootstrap' "$ROOT/install-supervisor-macos.sh" \
  || fail "macOS supervisor installer does not bootstrap launchd"
pass "macOS supervisor service packaging is present"

# 9. Deterministic finalizers themselves require semantic evidence.
grep -Fq 'semantic BUILD_AGENT_RESULT.json is required' "$ROOT/lib/ownframework_loop/build_finalize.py" \
  || fail "build finalizer still permits missing semantic builder result"
grep -Fq 'semantic REVIEW_AGENT_ASSESSMENT.json is required' "$ROOT/lib/ownframework_loop/review_finalize.py" \
  || fail "review finalizer still permits missing semantic reviewer result"
pass "finalizer authority cannot approve without semantic passes"

echo "V060_SUPERVISOR_ARCHITECTURE=PASS"
