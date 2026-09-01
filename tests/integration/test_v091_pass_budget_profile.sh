#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PYTHONPATH="$ROOT/lib${PYTHONPATH:+:$PYTHONPATH}"
python3 - <<'PY'
import json, os, tempfile
from pathlib import Path
from ownframework_loop import runner_profiles, supervisor

assert supervisor._remaining_funded_cost_budget(0,0) is None
assert supervisor._remaining_funded_cost_budget(10,3.25)==6.75
assert supervisor._remaining_funded_cost_budget(10,10)==0
assert 0 < supervisor._remaining_funded_cost_budget(10,9.999999) < 0.001
failure=supervisor.RunnerResult(
 ok=False,returncode=1,cost_usd=0.02,stdout="",stderr="Max budget limit reached",cost_known=True
)
assert supervisor._classify_runner_failure(failure)==("usage_ceiling","pass_budget_exhausted")

with tempfile.TemporaryDirectory() as td:
 root=Path(td); repo=root/"repo"; wt=root/"wt"; repo.mkdir(); wt.mkdir()
 os.environ["XDG_STATE_HOME"]=str(root/"state")
 capture=root/"args.json"; fake=root/"claude"
 fake.write_text("""#!/usr/bin/env python3
import json,os,sys
if "--version" in sys.argv:
 print("2.1.252"); raise SystemExit(0)
open(os.environ["OFLOOP_CAPTURE"],"w").write(json.dumps(sys.argv[1:]))
print(json.dumps({"is_error":False,"subtype":"success","result":"ok","total_cost_usd":0.01,"usage":{"input_tokens":1,"output_tokens":1}}))
""")
 fake.chmod(0o700)
 profiles=runner_profiles.default_manifest_path(); profiles.parent.mkdir(parents=True)
 profiles.write_text(json.dumps({
  "schema":runner_profiles.MANIFEST_SCHEMA,
  "profiles":{"deep":{"provider":"claude-code","model":"sonnet","effort":"high"}}
 })); profiles.chmod(0o600)
 os.environ["OFLOOP_CLAUDE_BIN"]=str(fake); os.environ["OFLOOP_CAPTURE"]=str(capture)
 result=supervisor.ClaudeCodeRunner().run({
  "schema":supervisor.SCHEMA,"decision":"BUILD","role":"builder","run_id":"r1",
  "state":"BUILDING","canonical_repo":str(repo),"worktree":str(wt),
  "semantic_path":str(wt/"result.json"),"network_read_allowlist":[],
  "capabilities":[],"runner_profile":"deep","attempt_id":"a1","max_budget_usd":2.75,
 },timeout_seconds=30)
 assert result.ok
 args=json.loads(capture.read_text())
 def val(flag): return args[args.index(flag)+1]
 assert val("--model")=="sonnet"
 assert val("--effort")=="high"
 assert val("--max-budget-usd")=="2.75"
 assert "--restricted" in args and val("--permission-mode")=="dontAsk"
 assert "--no-session-persistence" in args and "--no-chrome" in args

 os.environ["OFLOOP_CLAUDE_EXTRA_ARGS"]="--model opus"
 try:
  supervisor.ClaudeCodeRunner().run({
   "schema":supervisor.SCHEMA,"decision":"BUILD","role":"builder","run_id":"r2",
   "state":"BUILDING","canonical_repo":str(repo),"worktree":str(wt),
   "semantic_path":str(wt/"result2.json"),"network_read_allowlist":[],
   "capabilities":[],"runner_profile":"default","attempt_id":"a2",
  },timeout_seconds=30)
 except RuntimeError as exc:
  assert "may not override" in str(exc)
 else: raise AssertionError("free-form model override accepted")
 finally: os.environ.pop("OFLOOP_CLAUDE_EXTRA_ARGS",None)

print("OF_LOOP_V091_PASS_BUDGET_PROFILE=PASS")
PY
