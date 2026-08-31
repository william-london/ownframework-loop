#!/usr/bin/env bash
# v0.8.4 machine-contract truth: current engine artifacts validate against every
# JSON schema the repository presents as a current authoritative artifact contract.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

validate_run() {
  local repo="$1" rid="$2" label="$3"
  python3 - "$repo" "$rid" "$label" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import schema_validate
repo=Path(sys.argv[1]); rid=sys.argv[2]; label=sys.argv[3]
out=schema_validate.validate_all_for_run(repo,rid)
bad={k:v for k,v in out.items() if v}
assert not bad, f"{label}: schema mismatches: {bad}"
print(f"{label}=SCHEMA_VALID artifacts={','.join(sorted(out))}")
PY
}

SINGLE="$(make_tmp_repo)"
RID="$(make_approved_run "$SINGLE" FEATURE low "schema-contract-single")"
validate_run "$SINGLE" "$RID" "SINGLE_START"

ORDER="$("$OFLOOP_BIN" dispatch claim "$SINGLE" "$RID")"
assert_eq "$(printf '%s' "$ORDER" | jq -r '.decision')" "BUILD" "schema contract BUILD claim"
WT="$(printf '%s' "$ORDER" | jq -r '.worktree')"
SEM="$(printf '%s' "$ORDER" | jq -r '.semantic_path')"
mkdir -p "$WT/src"
printf 'def schema_contract():\n    return "ok"\n' > "$WT/src/schema_contract.py"
git -C "$WT" add src/schema_contract.py
git -C "$WT" commit -m "test: schema contract candidate" >/dev/null
python3 - "$SEM" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); d=json.loads(p.read_text())
d["summary"]="schema contract builder"
d["outcome_requested"]="candidate_ready"
d["unit_ids_completed"]=["UNIT-1"]
d["acceptance_addressed"]=["AC-1"]
p.write_text(json.dumps(d,indent=2,sort_keys=True)+"\n")
PY
"$OFLOOP_BIN" dispatch finalize "$SINGLE" "$RID" BUILD "$SEM" >/dev/null
validate_run "$SINGLE" "$RID" "SINGLE_BUILD"

RORDER="$("$OFLOOP_BIN" dispatch claim "$SINGLE" "$RID")"
assert_eq "$(printf '%s' "$RORDER" | jq -r '.decision')" "REVIEW" "schema contract REVIEW claim"
RSEM="$(printf '%s' "$RORDER" | jq -r '.semantic_path')"
python3 - "$RSEM" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); d=json.loads(p.read_text())
d["validation_results"]=[]
d["acceptance_results"]=[{"id":"AC-1","result":"SATISFIED","evidence":"synthetic invalid vocabulary"}]
d["non_goal_results"]=[]
d["findings"]=[]
d["recommended_verdict"]="APPROVED"
p.write_text(json.dumps(d,indent=2,sort_keys=True)+"\n")
PY
BAD_READY="$(RORDER_JSON="$RORDER" python3 - <<'PY'
import json,os
from ownframework_loop import dispatch
ready,reason=dispatch.semantic_result_ready(json.loads(os.environ["RORDER_JSON"]))
print(f"{ready}|{reason}")
PY
)"
assert_eq "$BAD_READY" "False|review_acceptance_result_invalid" "semantic synonym rejected before finalizer"

python3 - "$RSEM" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); d=json.loads(p.read_text())
d["acceptance_results"]=[{"id":"AC-1","result":"PASS","evidence":"exact-SHA synthetic contract proof"}]
p.write_text(json.dumps(d,indent=2,sort_keys=True)+"\n")
PY
"$OFLOOP_BIN" dispatch finalize "$SINGLE" "$RID" REVIEW "$RSEM" >/dev/null
assert_eq "$(jq -r '.acceptance_results[0].result' "$SINGLE/.ownframework-loop/$RID/REVIEW_VERDICT.json")" "pass" "authoritative verdict canonicalizes case-only semantic result"
validate_run "$SINGLE" "$RID" "SINGLE_REVIEW"

PROGRAM_REPO="$(make_tmp_repo)"
"$OFLOOP_BIN" spec new "$PROGRAM_REPO" "schema-contract-program" >/dev/null
PRID="$(ls -1t "$PROGRAM_REPO/.ownframework-loop" | head -n1)"
PP="$PROGRAM_REPO/.ownframework-loop/$PRID/WORK_PACKET.md"
python3 - "$PP" "$PROGRAM_REPO" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); repo=sys.argv[2]
packet={
 "schema":"ownframework-work-packet/v3","packet_id":"schema-program",
 "created_at":"2026-08-30T00:00:00Z","work_class":"FEATURE","risk_class":"low",
 "title":"schema contract program",
 "target":{"repo":repo,"branch":"master","classification":"local_only"},
 "execution_mode":"program",
 "checkpoint_graph":{
   "execution_order":["CP-1","CP-2"],
   "checkpoints":[
     {"id":"CP-1","title":"one","scope":"src/","depends_on":[],"acceptance_criterion_ids":["AC-1"],
      "risk_budget":{"max_build_passes":2,"max_review_passes":2,"max_repair_rounds":1}},
     {"id":"CP-2","title":"two","scope":"src/","depends_on":["CP-1"],"acceptance_criterion_ids":["AC-2"],
      "risk_budget":{"max_build_passes":2,"max_review_passes":2,"max_repair_rounds":1}}
   ]
 },
 "promotion_policy":"human_gate",
 "acceptance_criteria":[{"id":"AC-1","text":"one"},{"id":"AC-2","text":"two"}],
 "non_goals":[],"allowed_paths":["src/"],"protected_paths":[".ownframework-loop/"],
 "work_units":[{"id":"UNIT-1","title":"program","scope":"src/"}],
 "merge_authority":"human_only","deploy_authority":"human_only","push_authority":"human_only",
 "external_action_authority":"none",
 "risk_budget":{"max_build_passes":4,"max_review_passes":4,"max_repair_rounds":2,"max_files_changed":25,"max_diff_lines":1000}
}
fence=chr(96)*3
p.write_text(fence+"json\n"+json.dumps(packet,sort_keys=True)+"\n"+fence+"\n")
PY
python3 - "$PROGRAM_REPO" "$PRID" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import execution_start
execution_start.ensure_executable(canonical_repo=Path(sys.argv[1]),run_id=sys.argv[2],actor="schema-contract")
PY
validate_run "$PROGRAM_REPO" "$PRID" "PROGRAM_START"

python3 - <<'PY'
from ownframework_loop import assessment
from ownframework_loop.build_finalize import _build_agent_result_schema_ok

rows, errors = assessment.canonicalize_result_rows(
    [{"id":"AC-1","result":" PASS ","evidence":"x"}], kind="acceptance"
)
assert not errors and rows[0]["result"] == "pass", (rows, errors)
rows, errors = assessment.canonicalize_result_rows(
    [{"id":"NG-1","result":"PRESERVED","evidence":"x"}], kind="non_goal"
)
assert not errors and rows[0]["result"] == "preserved", (rows, errors)
_, errors = assessment.canonicalize_result_rows(
    [{"id":"NG-1","result":"SATISFIED","evidence":"x"}], kind="non_goal"
)
assert errors, "non-goal SATISFIED must not be guessed into preserved"
_, errors = assessment.canonicalize_result_rows(
    [{"id":"AC-1","result":"pass","evidence":"x","notes":"extra"}], kind="acceptance"
)
assert errors, "semantic row extra keys must be refused"

valid_finding={
    "finding_id":"F-contract",
    "severity":"medium",
    "classification":"must_fix",
    "title":"contract",
    "description":"synthetic contract finding",
}
assert assessment.validate_findings([valid_finding]) == []
assert assessment.validate_findings([{**valid_finding,"extra":"forbidden"}])

base={
    "schema":"ownframework-loop-build-agent-result/v1",
    "run_id":"run-contract",
    "work_unit_id":"UNIT-1",
    "outcome_requested":"candidate_ready",
    "summary":"ok",
    "evidence":{},
    "blocker_reason":None,
    "escalation_recommended":False,
    "escalation_reason":None,
    "unit_ids_completed":["UNIT-1"],
    "acceptance_addressed":["AC-1"],
    "notes":"",
}
ok, errors = _build_agent_result_schema_ok(base)
assert ok, errors
bad=dict(base); bad["escalation_recommended"]="false"
ok, errors = _build_agent_result_schema_ok(bad)
assert not ok and any("boolean" in e for e in errors), errors
bad=dict(base); bad["unit_ids_completed"]="UNIT-1"
ok, errors = _build_agent_result_schema_ok(bad)
assert not ok and any("unit_ids_completed" in e for e in errors), errors
print("SEMANTIC_ARTIFACT_BOUNDARY=PASS")
PY

python3 - "$ROOT_DIR" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import schema_validate
root=Path(sys.argv[1])
expected=set(schema_validate.CURRENT_SCHEMA_FILES)
actual={p.name for p in (root/"schemas").glob("*.schema.json")}
assert actual == expected, f"schema inventory drift: actual={sorted(actual)} expected={sorted(expected)}"
print("SCHEMA_INVENTORY=EXACT")
PY

echo "V084_SCHEMA_CONTRACT_TRUTH=PASS"
