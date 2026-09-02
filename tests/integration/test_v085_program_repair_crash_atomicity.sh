#!/usr/bin/env bash
# v0.8.5 — A-03 PROGRAM review rejection + repair entitlement crash atomicity.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"

OFLOOP="$OFLOOP_BIN"
REPO="$(make_tmp_repo)"
"$OFLOOP" spec new "$REPO" "program-repair-crash-atomicity" >/dev/null
RUN_ID="$(ls -1t "$REPO/.ownframework-loop" | head -n1)"
PP="$REPO/.ownframework-loop/$RUN_ID/WORK_PACKET.md"

python3 -B - "$PP" "$REPO" <<'PY'
import json, sys
from pathlib import Path
p=Path(sys.argv[1]); repo=sys.argv[2]
meta={
 "schema":"ownframework-work-packet/v3",
 "packet_id":"v085-program-repair-crash",
 "created_at":"2026-08-30T00:00:00Z",
 "work_class":"HARDENING","risk_class":"low",
 "title":"PROGRAM repair crash atomicity",
 "target":{"repo":repo,"branch":"master","classification":"local_only"},
 "execution_mode":"program",
 "checkpoint_graph":{
   "execution_order":["CP-1"],
   "checkpoints":[{
     "id":"CP-1","title":"repair atomicity","scope":"src/ repair proof",
     "depends_on":[],"acceptance_criterion_ids":["AC-1"],
     "risk_budget":{"max_build_passes":3,"max_review_passes":3,"max_repair_rounds":1}
   }]
 },
 "promotion_policy":"human_gate",
 "acceptance_criteria":[{"id":"AC-1","text":"review-funded repair must be crash atomic"}],
 "non_goals":[],
 "network_read_allowlist":[],
 "allowed_paths":["src/"],"protected_paths":[".ownframework-loop/"],
 "work_units":[{"id":"UNIT-1","title":"repair proof","scope":"src/"}],
 "merge_authority":"human_only","deploy_authority":"human_only",
 "push_authority":"human_only","external_action_authority":"none",
 "risk_budget":{
   "max_build_passes":3,"max_review_passes":3,"max_repair_rounds":1,
   "max_files_changed":10,"max_diff_lines":500
 }
}
fence="```"
p.write_text(fence+"json\n"+json.dumps(meta,indent=2,sort_keys=True)+"\n"+fence+"\n",encoding="utf-8")
PY

fill_build() {
  local semantic="$1" label="$2"
  python3 -B - "$semantic" "$label" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); d=json.loads(p.read_text()); label=sys.argv[2]
d["summary"]="synthetic PROGRAM builder "+label
d["outcome_requested"]="candidate_ready"
d["unit_ids_completed"]=["UNIT-1"]
d["acceptance_addressed"]=["AC-1"]
d["notes"]="A-03 actual finalizer crash proof"
p.write_text(json.dumps(d,indent=2,sort_keys=True)+"\n")
PY
}

fill_reject() {
  local semantic="$1" label="$2"
  python3 -B - "$semantic" "$label" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); d=json.loads(p.read_text()); label=sys.argv[2]
d["validation_results"]=[]
d["acceptance_results"]=[{"id":"AC-1","result":"fail","evidence":"repair required "+label}]
d["non_goal_results"]=[]
d["findings"]=[{
    "finding_id":"F-A03",
    "severity":"medium",
    "classification":"must_fix",
    "title":"PROGRAM repair required",
    "description":"repair required "+label,
}]
d["recommended_verdict"]="CHANGES_REQUESTED"
p.write_text(json.dumps(d,indent=2,sort_keys=True)+"\n")
PY
}

# Initial PROGRAM BUILD through the normal dispatch path.
BUILD1="$("$OFLOOP" dispatch claim "$REPO" "$RUN_ID")"
assert_eq "$(printf '%s' "$BUILD1" | jq -r '.decision')" "BUILD" "A03 initial PROGRAM build claim"
assert_eq "$(printf '%s' "$BUILD1" | jq -r '.checkpoint_id')" "CP-1" "A03 initial checkpoint"
WT="$(printf '%s' "$BUILD1" | jq -r '.worktree')"
BSEM1="$(printf '%s' "$BUILD1" | jq -r '.semantic_path')"
mkdir -p "$WT/src"
cat >"$WT/src/a03.py" <<'PY'
def repair_state():
    return "needs-repair"
PY
git -C "$WT" add src/a03.py
git -C "$WT" commit -m "a03 initial candidate" >/dev/null
fill_build "$BSEM1" initial
"$OFLOOP" dispatch finalize "$REPO" "$RUN_ID" BUILD "$BSEM1" >/dev/null

# Exact PROGRAM REVIEW through normal dispatch; semantic result requests repair.
REVIEW1="$("$OFLOOP" dispatch claim "$REPO" "$RUN_ID")"
assert_eq "$(printf '%s' "$REVIEW1" | jq -r '.decision')" "REVIEW" "A03 initial review claim"
RSEM1="$(printf '%s' "$REVIEW1" | jq -r '.semantic_path')"
fill_reject "$RSEM1" first

# Invoke the actual review finalizer while faulting the real STATE_TXN boundary:
# journal + STATE have been published, state_transition event has not.
PYTHONDONTWRITEBYTECODE=1 python3 -B - "$REPO" "$RUN_ID" "$RSEM1" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import review_finalize, state
repo=Path(sys.argv[1]); rid=sys.argv[2]; assessment=Path(sys.argv[3])
real=state._append_event_locked
fired={"v":False}
def crash(*args, **kwargs):
    if (
        kwargs.get("event_type")=="state_transition"
        and kwargs.get("old_state")=="REVIEWING"
        and kwargs.get("new_state")=="CHANGES_REQUESTED"
    ):
        fired["v"]=True
        raise RuntimeError("A03 injected post-state/pre-event crash")
    return real(*args, **kwargs)
state._append_event_locked=crash
try:
    try:
        review_finalize.finalize_review(
            canonical_repo=repo, run_id=rid, assessment_path=assessment,
            actor="a03-crash-test",
        )
    except RuntimeError as exc:
        assert "A03 injected post-state/pre-event crash" in str(exc), exc
    else:
        raise AssertionError("A03 crash injection did not fire")
finally:
    state._append_event_locked=real
assert fired["v"]
healed=state.load_verified(repo,rid)
prog=healed["program"]
cp=prog["checkpoints"][0]
assert healed["state"]=="CHANGES_REQUESTED", healed
assert healed["repair_round"]==1, healed
assert prog["cumulative_counters"]["repair_round_count"]==1, prog
assert cp["repair_round_count"]==1, cp
assert healed["repair_round"]==prog["cumulative_counters"]["repair_round_count"]
print("PROGRAM_MODE=yes")
print("REVIEW_RESULT=CHANGES_REQUESTED")
print("CRASH_BOUNDARY=inside_or_immediately_around_atomic_rejection_repair_mutation")
print("STATE_TXN_RECOVERY=PASS")
print("REPAIR_ROUND_INCREMENT=exactly_1")
print("PROGRAM_CUMULATIVE_REPAIR_COUNT=exactly_1")
print("TOP_LEVEL_REPAIR_MIRROR=coherent")
PY

# Only after recovered entitlement does the normal dispatcher expose repair BUILD.
BUILD2="$("$OFLOOP" dispatch claim "$REPO" "$RUN_ID")"
assert_eq "$(printf '%s' "$BUILD2" | jq -r '.decision')" "BUILD" "A03 repair build becomes eligible"
assert_eq "$(jq -r '.repair_round' "$REPO/.ownframework-loop/$RUN_ID/STATE.json")" "1" "A03 entitlement precedes repair build"
echo "REPAIR_BUILD_ELIGIBLE_ONLY_AFTER_ENTITLEMENT=yes"
BSEM2="$(printf '%s' "$BUILD2" | jq -r '.semantic_path')"
cat >"$WT/src/a03.py" <<'PY'
def repair_state():
    return "repaired"
PY
git -C "$WT" add src/a03.py
git -C "$WT" commit -m "a03 funded repair candidate" >/dev/null
fill_build "$BSEM2" repair
"$OFLOOP" dispatch finalize "$REPO" "$RUN_ID" BUILD "$BSEM2" >/dev/null

# Reject again after the only funded repair round is already consumed.
REVIEW2="$("$OFLOOP" dispatch claim "$REPO" "$RUN_ID")"
assert_eq "$(printf '%s' "$REVIEW2" | jq -r '.decision')" "REVIEW" "A03 post-repair review claim"
RSEM2="$(printf '%s' "$REVIEW2" | jq -r '.semantic_path')"
fill_reject "$RSEM2" cap
"$OFLOOP" dispatch finalize "$REPO" "$RUN_ID" REVIEW "$RSEM2" >/dev/null
assert_eq "$(jq -r '.state' "$REPO/.ownframework-loop/$RUN_ID/STATE.json")" "BLOCKED" "A03 cap exhaustion blocks atomically"
assert_eq "$(jq -r '.repair_round' "$REPO/.ownframework-loop/$RUN_ID/STATE.json")" "1" "A03 cap exhaustion does not increment repair"

TERMINAL="$("$OFLOOP" dispatch claim "$REPO" "$RUN_ID")"
assert_eq "$(printf '%s' "$TERMINAL" | jq -r '.decision')" "TERMINAL" "A03 no repair build beyond cap"
assert_eq "$(printf '%s' "$TERMINAL" | jq -r '.state')" "BLOCKED" "A03 terminal blocked beyond cap"
echo "AT_REPAIR_CEILING_STATE=BLOCKED"
echo "AT_REPAIR_CEILING_BUILD_CLAIM=no"
echo "AT_REPAIR_CEILING_SEMANTIC_BUILDER_INVOCATION=no"
echo "A03_PROGRAM_CRASH_PROOF=PASS"
