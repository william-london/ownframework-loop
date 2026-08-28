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

# 3. Fresh human-originated run dispatches BUILD with deterministic preparation.
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

# 4. Re-dispatch of same claimed pass is replay, not another budget unit.
OUT2="$($OFLOOP dispatch claim "$T" "$RID")"
assert_eq "$(printf '%s' "$OUT2" | jq -r '.decision')" "BUILD" "re-dispatch remains BUILD"
assert_eq "$(printf '%s' "$OUT2" | jq -r '.replayed')" "true" "re-dispatch is replay"
assert_eq "$(jq -r '.build_pass_count' "$T/.ownframework-loop/$RID/STATE.json")" "1" "re-dispatch consumes one pass"

# 5. Packet-supplied validation commands are mechanically classified before execution.
grep -Fq 'required_validation command refused by deterministic guard' "$ROOT/lib/ownframework_loop/build_finalize.py" \
  || fail "build finalizer missing required-validation guard"
grep -Fq 'required_validation command refused by deterministic guard' "$ROOT/lib/ownframework_loop/review_finalize.py" \
  || fail "review finalizer missing required-validation guard"
pass "required-validation shell authority is mechanically guarded"

# 6. Supervisor contains no engineering-state transition table.
if grep -Eq 'READY_TO_BUILD|READY_FOR_REVIEW|CHANGES_REQUESTED|REVIEWING|BUILDING' "$ROOT/lib/ownframework_loop/supervisor.py"; then
  fail "supervisor reimplemented engineering state machine"
fi
grep -Fq 'dispatch_mod.claim_next' "$ROOT/lib/ownframework_loop/supervisor.py" \
  || fail "supervisor does not consume dispatch owner"
pass "supervisor is execution clock, not second engineering state machine"

echo "V060_SUPERVISOR_ARCHITECTURE=PASS"
