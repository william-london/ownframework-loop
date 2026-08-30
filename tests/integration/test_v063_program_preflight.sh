#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
export PYTHONPATH="$ROOT/lib"
python3 -B <<'PY'
from ownframework_loop import limits, packet, supervisor
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
assert supervisor.resolve_semantic_timeout(base, 0) == 7200
assert supervisor.resolve_semantic_timeout(base, 3600) == 3600
no_pass={**base,"risk_budget":{k:v for k,v in base["risk_budget"].items() if k!="max_pass_runtime_seconds"}}
assert supervisor.resolve_semantic_timeout(no_pass, 0) == 3600
assert limits.effective_cap("build_pass_count", None) == 32
assert limits.effective_cap("review_pass_count", None) == 32
assert limits.effective_cap("build_pass_count", {"risk_budget":{"max_build_passes":74}}) == 74
builder_tools=set(supervisor.CLAUDE_BUILDER_TOOLS.split(","))
reviewer_tools=set(supervisor.CLAUDE_REVIEWER_TOOLS.split(","))
assert builder_tools == {"Read","Edit","Write","NotebookEdit","Bash","Glob","Grep"}, builder_tools
assert reviewer_tools == {"Read","Bash","Glob","Grep"}, reviewer_tools
for forbidden in ("Agent","Task","TaskOutput","TaskStop","Skill","WebSearch","WebFetch"):
    assert forbidden not in builder_tools, (forbidden,builder_tools)
    assert forbidden not in reviewer_tools, (forbidden,reviewer_tools)
assert not {"Edit","Write","NotebookEdit"}.intersection(reviewer_tools), reviewer_tools
from ownframework_loop import guards
assert guards.classify_bash_command("docker compose up -d")["severity"] == "allowed"
assert guards.classify_bash_command("curl -fsS http://127.0.0.1:3000/health")["severity"] == "allowed"
assert guards.classify_bash_command("git push origin master")["severity"] == "forbidden"
print("V063_PROGRAM_PREFLIGHT=PASS")
PY
