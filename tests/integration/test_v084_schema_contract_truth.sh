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
REVIEW_PASS_BEFORE_BAD="$(jq -r '.review_pass_count' "$SINGLE/.ownframework-loop/$RID/STATE.json")"
REPAIR_BEFORE_BAD="$(jq -r '.repair_round' "$SINGLE/.ownframework-loop/$RID/STATE.json")"
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
assert_eq "$(jq -r '.review_pass_count' "$SINGLE/.ownframework-loop/$RID/STATE.json")" "$REVIEW_PASS_BEFORE_BAD" "malformed review transport preserves same pass"
assert_eq "$(jq -r '.repair_round' "$SINGLE/.ownframework-loop/$RID/STATE.json")" "$REPAIR_BEFORE_BAD" "malformed review transport does not fund repair"
[[ ! -e "$SINGLE/.ownframework-loop/$RID/REVIEW_VERDICT.json" ]] || fail "malformed review transport must not create authoritative verdict"

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

python3 - "$PROGRAM_REPO" <<'PY'
import copy
import importlib
import sys
import types
from pathlib import Path
from ownframework_loop import packet as packet_mod, schema_validate

repo=str(Path(sys.argv[1]).resolve())
base={
 "schema":"ownframework-work-packet/v3","packet_id":"schema-admission",
 "created_at":"2026-08-30T00:00:00Z","work_class":"FEATURE","risk_class":"low",
 "title":"schema admission proof",
 "target":{"repo":repo,"branch":"master","classification":"local_only"},
 "execution_mode":"program",
 "checkpoint_graph":{
   "execution_order":["CP-1"],
   "checkpoints":[{
     "id":"CP-1","title":"one","scope":"src/","depends_on":[],
     "acceptance_criterion_ids":["AC-1"],
     "risk_budget":{"max_build_passes":2,"max_review_passes":2,"max_repair_rounds":1}
   }]
 },
 "promotion_policy":"human_gate",
 "acceptance_criteria":[{"id":"AC-1","text":"one"}],
 "non_goals":[{"id":"NG-1","text":"none"}],
 "allowed_paths":["src/"],"protected_paths":[".ownframework-loop/"],
 "work_units":[{"id":"UNIT-1","title":"program","scope":"src/"}],
 "merge_authority":"human_only","deploy_authority":"human_only",
 "push_authority":"human_only","external_action_authority":"none"
}
assert schema_validate.validate_packet(base) == [], schema_validate.validate_packet(base)
assert packet_mod.validate_packet_for_approval(base) == [], packet_mod.validate_packet_for_approval(base)

cases={}
bad=copy.deepcopy(base); bad["acceptance_criteria"][0]["id"]="AC-BAD"; cases["INVALID_AC_ID"]=bad
bad=copy.deepcopy(base); bad["non_goals"][0]["id"]="NG-BAD"; cases["INVALID_NG_ID"]=bad
bad=copy.deepcopy(base); bad["work_units"][0]["id"]="UNIT-BAD"; cases["INVALID_UNIT_ID"]=bad
bad=copy.deepcopy(base); bad["checkpoint_graph"]["execution_order"][0]="CP-BAD"; cases["INVALID_CP_ID"]=bad
bad=copy.deepcopy(base); bad["unexpected_packet_key"]=True; cases["EXTRA_PACKET_PROPERTY"]=bad
bad=copy.deepcopy(base); bad["acceptance_criteria"]="AC-1"; cases["MALFORMED_PACKET_FIELD_TYPE"]=bad
bad=copy.deepcopy(base); bad["target"]={"repo":repo}; cases["MALFORMED_REQUIRED_NESTED_OBJECT"]=bad
bad=copy.deepcopy(base); bad["created_at"]="2026-08-30"; cases["INVALID_CREATED_AT"]=bad
for label, candidate in cases.items():
    errors=packet_mod.validate_packet_for_approval(candidate)
    assert errors and errors[0].startswith("schema:"), (label, errors)
    print(f"{label}_PRESEAL_REJECT=PASS")

coverage=schema_validate.schema_keyword_coverage_errors()
assert coverage == [], coverage
print("SCHEMA_KEYWORD_COVERAGE=PASS")

baseline=schema_validate.validate_packet(base)
fake=types.ModuleType("jsonschema")
sys.modules["jsonschema"]=fake
importlib.reload(schema_validate)
with_fake=schema_validate.validate_packet(base)
sys.modules.pop("jsonschema", None)
importlib.reload(schema_validate)
without_fake=schema_validate.validate_packet(base)
assert baseline == with_fake == without_fake == [], (baseline,with_fake,without_fake)
assert not hasattr(schema_validate, "jsonschema")
print("AMBIENT_JSONSCHEMA_INDEPENDENCE=PASS")
PY

BAD_PACKET_REPO="$(make_tmp_repo)"
"$OFLOOP_BIN" spec new "$BAD_PACKET_REPO" "schema-preseal-rejection" >/dev/null
BAD_PACKET_RID="$(ls -1t "$BAD_PACKET_REPO/.ownframework-loop" | head -n1)"
BAD_PACKET_PATH="$BAD_PACKET_REPO/.ownframework-loop/$BAD_PACKET_RID/WORK_PACKET.md"
python3 - "$BAD_PACKET_PATH" <<'PY'
import json,sys
from pathlib import Path
from ownframework_loop import packet
p=Path(sys.argv[1])
meta,text=packet.parse_packet_file(p)
meta["acceptance_criteria"][0]["id"]="AC-BAD"
fence=chr(96)*3
start=text.find(fence+"json")
end=text.find("\n"+fence,start)
assert start >= 0 and end >= 0
replacement=fence+"json\n"+json.dumps(meta,sort_keys=True)+"\n"+fence
p.write_text(text[:start]+replacement+text[end+4:])
PY
set +e
BAD_PRESEAL_OUT="$(python3 - "$BAD_PACKET_REPO" "$BAD_PACKET_RID" <<'PY' 2>&1
import sys
from pathlib import Path
from ownframework_loop import execution_start
execution_start.ensure_executable(canonical_repo=Path(sys.argv[1]),run_id=sys.argv[2],actor="schema-preseal-proof")
PY
)"
BAD_PRESEAL_RC=$?
set -e
[[ "$BAD_PRESEAL_RC" -ne 0 ]] || fail "schema-invalid packet unexpectedly sealed"
printf '%s' "$BAD_PRESEAL_OUT" | grep -Fq "packet invalid: schema:" || fail "schema-invalid packet refusal was not structural"
[[ ! -e "$BAD_PACKET_REPO/.ownframework-loop/$BAD_PACKET_RID/APPROVAL.json" ]] || fail "schema-invalid packet created execution seal"
echo "PACKET_SCHEMA_PRESEAL_REJECTION=PASS"

python3 - <<'PY'
import json
import tempfile
from pathlib import Path
from ownframework_loop import assessment, build_agent, dispatch
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
bad=dict(base); bad["evidence"]=["wrong-type"]
ok, errors = _build_agent_result_schema_ok(bad)
assert not ok and any("evidence" in e for e in errors), errors

assert build_agent.validate_agent_result_contract(base) == []
ok, final_errors = _build_agent_result_schema_ok(base)
assert ok and final_errors == []
with tempfile.TemporaryDirectory() as td:
    semantic=Path(td)/"BUILD_AGENT_RESULT.json"
    terminal=dict(base)
    terminal["outcome_requested"]="blocked"
    terminal["blocker_reason"]="synthetic terminal"
    semantic.write_text(json.dumps(terminal))
    work_order={
        "schema":dispatch.SCHEMA,
        "decision":"BUILD",
        "role":"builder",
        "run_id":"run-contract",
        "canonical_repo":td,
        "worktree":td,
        "semantic_path":str(semantic),
    }
    ready,reason=dispatch.semantic_result_ready(work_order)
    assert ready and reason=="ready", (ready,reason)
    terminal["evidence"]=["wrong-type"]
    semantic.write_text(json.dumps(terminal))
    ready,reason=dispatch.semantic_result_ready(work_order)
    assert not ready and reason=="builder_semantic_shape_invalid", (ready,reason)
    ok, final_errors=_build_agent_result_schema_ok(terminal)
    assert not ok and any("evidence" in e for e in final_errors), final_errors
print("DISPATCH_FINALIZER_BUILDER_CONTRACT_PARITY=PASS")
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

import inspect
from ownframework_loop import build_finalize, review_finalize
build_src=inspect.getsource(build_finalize.finalize_build)
review_src=inspect.getsource(review_finalize.finalize_review)
assert build_src.index("receipts.validate_receipt_contract(receipt)") < build_src.index("# 21. Persist atomically")
assert review_src.index("verdicts.validate_verdict_contract(new_verdict)") < review_src.index("verdicts.write_verdict")
assert review_src.index("verdicts.write_verdict") < review_src.index("program_mod.advance_after_review_approval")
print("AUTHORITATIVE_PREWRITE_GATE=PASS")
print("CONTRACT_DRIFT_REGRESSION=PASS")
PY

echo "V084_SCHEMA_CONTRACT_TRUTH=PASS"
