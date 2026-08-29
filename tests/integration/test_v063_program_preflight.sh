#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
export PYTHONPATH="$ROOT/lib"
python3 -B <<'PY'
from ownframework_loop import packet
base = {
 "schema":"ownframework-work-packet/v3","packet_id":"v063","created_at":"2026-08-29T00:00:00Z",
 "work_class":"NEW_REPOSITORY","risk_class":"medium","title":"v063",
 "target":{"repo":"/tmp/v063","branch":"master","classification":"local_only"},
 "execution_mode":"program","promotion_policy":"human_gate",
 "acceptance_criteria":[{"id":"AC-1","text":"one"},{"id":"AC-2","text":"two"}],
 "non_goals":[],"allowed_paths":["src/**"],"protected_paths":[".ownframework-loop/**"],
 "work_units":[{"id":"UNIT-1","title":"u","scope":"src"}],
 "merge_authority":"human_only","deploy_authority":"human_only","push_authority":"human_only","external_action_authority":"none",
 "risk_budget":{"max_build_passes":3,"max_review_passes":3,"max_repair_rounds":1,"max_files_changed":500,"max_diff_lines":30000,"max_pass_runtime_seconds":7200},
 "checkpoint_graph":{"execution_order":["CP-0","CP-1"],"checkpoints":[
  {"id":"CP-0","title":"one","scope":"one","depends_on":[],"acceptance_criterion_ids":["AC-1"],"risk_budget":{"max_build_passes":2,"max_review_passes":2,"max_repair_rounds":1}},
  {"id":"CP-1","title":"two","scope":"two","depends_on":["CP-0"],"acceptance_criterion_ids":["AC-2"],"risk_budget":{"max_build_passes":2,"max_review_passes":2,"max_repair_rounds":1}}
 ],"global_source_ceilings":{"max_unique_changed_files":500,"max_baseline_to_final_diff_lines":30000}}
}
assert packet.validate_packet_metadata(base) == []
bad={**base,"risk_budget":{**base["risk_budget"],"max_diff_lines":50000}}
errs=packet.validate_packet_metadata(bad)
assert any("max_diff_lines=50000 exceeds executable ceiling 30000" in e for e in errs), errs
bad2={**base,"risk_budget":{**base["risk_budget"],"max_build_passes":2,"max_review_passes":2}}
errs=packet.validate_packet_metadata(bad2)
assert any("cannot realize max_repair_rounds=1" in e for e in errs), errs
badcp={**base,"checkpoint_graph":{**base["checkpoint_graph"],"checkpoints":[dict(base["checkpoint_graph"]["checkpoints"][0]),base["checkpoint_graph"]["checkpoints"][1]]}}
badcp["checkpoint_graph"]["checkpoints"][0].pop("acceptance_criterion_ids")
badcp["checkpoint_graph"]["checkpoints"][0]["acceptance_criteria"]=["AC-1"]
errs=packet.validate_packet_metadata(badcp)
assert any("acceptance_criteria" in e and "acceptance_criterion_ids" in e for e in errs), errs
print("V063_PROGRAM_PREFLIGHT=PASS")
PY
