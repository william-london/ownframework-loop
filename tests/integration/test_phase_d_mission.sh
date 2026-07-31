#!/usr/bin/env bash
# Phase D — end-to-end unattended mission execution.
#
# This is the canonical "program checkpoint": it runs a full
# spec → build → review cycle through the orchestrator under the
# realistic operator workflow:
#   1. spec new (creates run id)
#   2. operator writes WORK_PACKET.md
#   3. operator writes APPROVAL.json (out-of-band, with confirmation token)
#   4. operator transitions state to READY_TO_BUILD
#   5. builder creates candidate worktree + commit
#   6. ofloop loop run --run-id <id>  (drives build + review to APPROVED)
#
# The orchestrator must reach APPROVED with the deterministic
# finalizers writing every artifact (BUILD_RECEIPT, REVIEW_VERDICT,
# run state, EVENTS.log).

set -uo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

OFLOOP_BIN="$BIN_DIR/ofloop"
LIB_DIR="$ROOT_DIR/lib"

# Make a tmp repo + run.
REPO="$(make_tmp_repo)"
RUN_ID="$(make_approved_run "$REPO" FEATURE low "phase-d-mission")"
echo "REPO=$REPO RUN_ID=$RUN_ID"

# Transition to READY_TO_BUILD so the builder can claim.
python3 - "$REPO" "$RUN_ID" <<'PY'
import sys, os as _os
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get("OFLOOP_LIB", "/path/to/ownframework-loop/lib"))
from ownframework_loop import state as state_mod
from pathlib import Path
repo = Path(sys.argv[1])
rid = sys.argv[2]
cur = state_mod.load(repo, rid)
print("pre-transition state:", cur.get("state"))
state_mod.transition(repo, rid, to_state="READY_TO_BUILD", actor="phase-d-test", reason="x")
PY

# Build the candidate on a worktree.
WT="$REPO/.worktrees/ownframework-loop/$RUN_ID/builder"
git -C "$REPO" worktree add -b "factory/candidate/$RUN_ID" "$WT" master >/dev/null 2>&1
mkdir -p "$WT/src"
cat > "$WT/src/marker.py" <<'PY'
def marker():
    return 42
PY
git -C "$WT" add src/marker.py && git -C "$WT" commit -m "feat: add marker" >/dev/null 2>&1
CAND_SHA=$(git -C "$WT" rev-parse HEAD)
echo "CAND_SHA=$CAND_SHA"

# Run the orchestrator end-to-end.
ORCH_OUT="$("$OFLOOP_BIN" loop run "$REPO" --run-id "$RUN_ID" 2>&1)"
echo "ORCH_OUT=$ORCH_OUT"

# Verify the orchestrator reported success.
assert_contains "$ORCH_OUT" '"ok": true' "orchestrator reports ok=true"
assert_contains "$ORCH_OUT" '"terminal_state": "APPROVED"' "terminal_state is APPROVED"
assert_contains "$ORCH_OUT" '"rounds": 1' "cycle reached terminal in 1 round"

# Verify the deterministic state.
FINAL_STATE="$(python3 -c "import json; print(json.load(open('$REPO/.ownframework-loop/$RUN_ID/STATE.json'))['state'])")"
assert_eq "$FINAL_STATE" "APPROVED" "STATE.json.state == APPROVED"

# Verify all artifacts are present.
assert_file_exists "$REPO/.ownframework-loop/$RUN_ID/APPROVAL.json" "APPROVAL.json present"
assert_file_exists "$REPO/.ownframework-loop/$RUN_ID/BUILD_RECEIPT.json" "BUILD_RECEIPT.json present"
assert_file_exists "$REPO/.ownframework-loop/$RUN_ID/REVIEW_VERDICT.json" "REVIEW_VERDICT.json present"
assert_file_exists "$REPO/.ownframework-loop/$RUN_ID/EVENTS.log" "EVENTS.log present"

# Verify the BUILD_RECEIPT candidate_sha matches the worktree HEAD.
BUILD_SHA="$(python3 -c "import json; print(json.load(open('$REPO/.ownframework-loop/$RUN_ID/BUILD_RECEIPT.json'))['candidate_sha'])")"
assert_eq "$BUILD_SHA" "$CAND_SHA" "BUILD_RECEIPT.candidate_sha matches worktree HEAD"

# Verify the REVIEW_VERDICT candidate_sha_reviewed matches the build receipt.
REVIEW_SHA="$(python3 -c "import json; print(json.load(open('$REPO/.ownframework-loop/$RUN_ID/REVIEW_VERDICT.json'))['candidate_sha_reviewed'])")"
assert_eq "$REVIEW_SHA" "$CAND_SHA" "REVIEW_VERDICT.candidate_sha_reviewed matches build SHA"

# Verify the AC was satisfied by checking the actual file in the worktree.
grep -q "return 42" "$WT/src/marker.py" \
  && pass "acceptance criterion AC-1 satisfied (marker.py returns 42)" \
  || fail "AC-1 not satisfied in $WT/src/marker.py"

# Cleanup.
git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true

echo "PHASE_D_MISSION=PASS"
