#!/usr/bin/env bash
# v0.6 — repair cycle through the typed dispatch boundary.
#
# Drives one CHANGES_REQUESTED cycle followed by an APPROVED cycle through
# the dispatch + deterministic finalizer path. The supervisor (or a
# replacement supervisor) replays the same claimed pass; the pass count is
# never double-consumed for restart replays.
#
# No model is called; synthetic semantic results are schema-correct.

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

OFLOOP="$OFLOOP_BIN"
LIB_DIR="$ROOT_DIR/lib"

REP="$(make_tmp_repo)"
RUN_ID="$(make_approved_run "$REP" FEATURE low "repair-dispatch-loop")"

# Auto-seal already leaves the run ready for a BUILD work order.

# Round 0: build candidate + produce a CHANGES_REQUESTED verdict.
WT1="$REP/.worktrees/ownframework-loop/$RUN_ID/builder"
git -C "$REP" worktree add -b "factory/candidate/$RUN_ID" "$WT1" master >/dev/null 2>&1
mkdir -p "$WT1/src"
cat > "$WT1/src/v1.py" <<'PY'
def v1():
    return "first"
PY
git -C "$WT1" add src/v1.py && git -C "$WT1" commit -m "v1" >/dev/null 2>&1
SHA1="$(git -C "$WT1" rev-parse HEAD)"

BUILD1="$("$OFLOOP" dispatch claim "$REP" "$RUN_ID")"
assert_eq "$(printf '%s' "$BUILD1" | jq -r '.decision')" "BUILD" "round 1 dispatch BUILD"
assert_eq "$(printf '%s' "$BUILD1" | jq -r '.repair_context')" "null" "initial build has no repair context"
BSEM1="$(printf '%s' "$BUILD1" | jq -r '.semantic_path')"
python3 - "$BSEM1" "$RUN_ID" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
d = json.loads(p.read_text())
d["summary"] = "round 1 synthetic builder result"
d["outcome_requested"] = "candidate_ready"
d["unit_ids_completed"] = ["UNIT-1"]
d["acceptance_addressed"] = ["AC-1"]
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
"$OFLOOP" dispatch finalize "$REP" "$RUN_ID" BUILD "$BSEM1" >/dev/null

REVIEW1="$("$OFLOOP" dispatch claim "$REP" "$RUN_ID")"
assert_eq "$(printf '%s' "$REVIEW1" | jq -r '.decision')" "REVIEW" "round 1 dispatch REVIEW"
RSEM1="$(printf '%s' "$REVIEW1" | jq -r '.semantic_path')"
python3 - "$RSEM1" "$RUN_ID" "$SHA1" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
d = json.loads(p.read_text())
d["validation_results"] = []
d["acceptance_results"] = [{"id": "AC-1", "result": "fail", "evidence": "needs repair"}]
d["non_goal_results"] = []
d["findings"] = [{
    "finding_id": "F-1",
    "severity": "medium",
    "classification": "must_fix",
    "title": "repair required",
    "description": "needs repair",
}]
d["recommended_verdict"] = "CHANGES_REQUESTED"
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
"$OFLOOP" dispatch finalize "$REP" "$RUN_ID" REVIEW "$RSEM1" >/dev/null

# After CHANGES_REQUESTED the deterministic state is READY_TO_BUILD for the
# next build pass; the verdict artifact carries the CHANGES_REQUESTED signal.
VERDICT_AFTER_1="$(jq -r '.verdict' "$REP/.ownframework-loop/$RUN_ID/REVIEW_VERDICT.json")"
assert_eq "$VERDICT_AFTER_1" "CHANGES_REQUESTED" "review verdict is CHANGES_REQUESTED"
STATE_AFTER_1="$(jq -r '.state' "$REP/.ownframework-loop/$RUN_ID/STATE.json")"
assert_eq "$STATE_AFTER_1" "READY_TO_BUILD" "state advances back to READY_TO_BUILD for the next build"
REPAIR_R1="$(jq -r '.repair_round' "$REP/.ownframework-loop/$RUN_ID/STATE.json")"
assert_eq "$REPAIR_R1" "1" "repair_round incremented after CHANGES_REQUESTED"

# Round 2: operator updates source; run continues through the same
# dispatch boundary to APPROVED. NO separate "loop run" command is needed.
WT2="$REP/.worktrees/ownframework-loop/$RUN_ID/builder"
git -C "$REP" worktree add -b "factory/candidate/$RUN_ID-r2" "$WT2" master >/dev/null 2>&1 || true
mkdir -p "$WT2/src"
cat > "$WT2/src/v2.py" <<'PY'
def v2():
    return "second"
PY
git -C "$WT2" add src/v2.py && git -C "$WT2" commit -m "v2" >/dev/null 2>&1
SHA2="$(git -C "$WT2" rev-parse HEAD)"

# The state must be advanced back to READY_TO_BUILD after CHANGES_REQUESTED;
# the dispatch boundary takes care of that automatically. Replay the dispatch
# claim — it must return BUILD for the same claimed pass without double-counting
# engineering passes.
BUILD2="$("$OFLOOP" dispatch claim "$REP" "$RUN_ID")"
assert_eq "$(printf '%s' "$BUILD2" | jq -r '.decision')" "BUILD" "round 2 dispatch BUILD"
assert_eq "$(printf '%s' "$BUILD2" | jq -r '.replayed')" "false" "round 2 is a fresh pass, not a replay"
assert_eq "$(printf '%s' "$BUILD2" | jq -r '.repair_context.schema')" "ownframework-loop-repair-context/v1" "repair context schema"
assert_eq "$(printf '%s' "$BUILD2" | jq -r '.repair_context.verdict')" "CHANGES_REQUESTED" "repair context carries prior verdict"
assert_eq "$(printf '%s' "$BUILD2" | jq -r '.repair_context.candidate_sha_reviewed')" "$SHA1" "repair context exact reviewed SHA"
assert_eq "$(printf '%s' "$BUILD2" | jq -r '.repair_context.failed_acceptance_results[0].id')" "AC-1" "repair context carries failed AC"
assert_eq "$(printf '%s' "$BUILD2" | jq -r '.repair_context.findings[0].description')" "needs repair" "repair context carries reviewer finding"
BSEM2="$(printf '%s' "$BUILD2" | jq -r '.semantic_path')"
python3 - "$BSEM2" "$RUN_ID" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
d = json.loads(p.read_text())
d["summary"] = "round 2 synthetic builder result"
d["outcome_requested"] = "candidate_ready"
d["unit_ids_completed"] = ["UNIT-1"]
d["acceptance_addressed"] = ["AC-1"]
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
"$OFLOOP" dispatch finalize "$REP" "$RUN_ID" BUILD "$BSEM2" >/dev/null

REVIEW2="$("$OFLOOP" dispatch claim "$REP" "$RUN_ID")"
RSEM2="$(printf '%s' "$REVIEW2" | jq -r '.semantic_path')"
python3 - "$RSEM2" "$RUN_ID" "$SHA2" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
d = json.loads(p.read_text())
d["validation_results"] = []
d["acceptance_results"] = [{"id": "AC-1", "result": "pass", "evidence": "round 2 exact-SHA review"}]
d["non_goal_results"] = []
d["findings"] = []
d["recommended_verdict"] = "APPROVED"
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
"$OFLOOP" dispatch finalize "$REP" "$RUN_ID" REVIEW "$RSEM2" >/dev/null

FINAL_STATE="$(jq -r '.state' "$REP/.ownframework-loop/$RUN_ID/STATE.json")"
assert_eq "$FINAL_STATE" "APPROVED" "final state is APPROVED"
BUILD_PASSES="$(jq -r '.build_pass_count' "$REP/.ownframework-loop/$RUN_ID/STATE.json")"
assert_eq "$BUILD_PASSES" "2" "two build passes recorded"
REVIEW_PASSES="$(jq -r '.review_pass_count' "$REP/.ownframework-loop/$RUN_ID/STATE.json")"
assert_eq "$REVIEW_PASSES" "2" "two review passes recorded"

# Cleanup.
git -C "$REP" worktree remove --force "$WT1" >/dev/null 2>&1 || true
git -C "$REP" worktree remove --force "$WT2" >/dev/null 2>&1 || true

echo "REPAIR_LOOP_DISPATCH=PASS"