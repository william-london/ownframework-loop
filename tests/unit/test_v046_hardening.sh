#!/usr/bin/env bash
# v0.4.6 production lifecycle integrity regressions.
set -euo pipefail
. "$(dirname "$0")/../_helpers.sh"
export PYTHONPATH="$LIB_DIR${PYTHONPATH:+:$PYTHONPATH}"
export OFLOOP_ROOT="$ROOT_DIR"

python3 -B <<'PY'
import hashlib, json, os, subprocess, sys, tempfile
from pathlib import Path
from ownframework_loop import approval, program, reconcile, state as state_mod
# Crash-state seeding is a TEST-ONLY seam: production save() can never change
# transition identity; fixtures simulate the durable state a crash leaves.
sys.path.insert(0, str(Path(os.environ["OFLOOP_ROOT"]) / "tests" / "helpers"))
from state_seed import seed_state

def mkrepo():
    p=Path(tempfile.mkdtemp(prefix="ofloop-v046-"))
    subprocess.run(["git","init","-q","-b","master",str(p)],check=True)
    subprocess.run(["git","-C",str(p),"config","user.email","v046@loop"],check=True)
    subprocess.run(["git","-C",str(p),"config","user.name","v046"],check=True)
    (p/"README.md").write_text("baseline\n")
    subprocess.run(["git","-C",str(p),"add","README.md"],check=True)
    subprocess.run(["git","-C",str(p),"commit","-q","-m","baseline"],check=True)
    return p

def head(repo):
    return subprocess.run(["git","-C",str(repo),"rev-parse","HEAD"],capture_output=True,text=True,check=True).stdout.strip()

def simple_run(repo,rid,state_name):
    run=repo/".ownframework-loop"/rid; run.mkdir(parents=True)
    pp=run/"WORK_PACKET.md"; pp.write_text("single-mode packet\n")
    sha=hashlib.sha256(pp.read_bytes()).hexdigest(); base=head(repo)
    app={"schema":"ownframework-loop-approval/v1","run_id":rid,"packet_sha256":sha,
         "approved_at":"2026-08-28T00:00:00Z","approved_actor":"test",
         "canonical_repo":str(repo.resolve()),"baseline_branch":"master","baseline_sha":base,
         "candidate_branch":f"factory/candidate/{rid}","packet_schema":"ownframework-work-packet/v2",
         "approval_method":"tty_confirmation","confirmation_token":approval.derive_confirmation_token(sha)}
    (run/"APPROVAL.json").write_text(json.dumps(app))
    s=state_mod.initial_state(rid); s["state"]=state_name; seed_state(repo,rid,s)
    return run,app

# 1. Wrong-lane claims and counter-mirror drift are refused atomically.
repo=mkrepo(); rid="run-v046-phase"; run=repo/".ownframework-loop"/rid; run.mkdir(parents=True)
packet={"schema":"ownframework-work-packet/v3","execution_mode":"program",
 "risk_budget":{"max_build_passes":3,"max_review_passes":3,"max_repair_rounds":1},
 "checkpoint_graph":{"execution_order":["CP-1"],"checkpoints":[{"id":"CP-1","title":"one","scope":"one","depends_on":[],
 "risk_budget":{"max_build_passes":3,"max_review_passes":3,"max_repair_rounds":1}}]}}
ps=program.materialise_initial_program_state(packet,baseline_sha="a"*40,candidate_branch="factory/candidate/x")
s=state_mod.initial_state(rid); s.update({"schema":state_mod.PROGRAM_STATE_SCHEMA_VERSION,"program":ps,"state":"READY_FOR_REVIEW"})
seed_state(repo,rid,s)
try: program.claim_build_pass(canonical_repo=repo,run_id=rid,packet=packet)
except program.ClaimRefused: pass
else: raise AssertionError("wrong-lane build claim accepted")
a=state_mod.load(repo,rid); assert a["state"]=="READY_FOR_REVIEW" and a["program"]["cumulative_counters"]["build_pass_count"]==0
a["state"]="READY_TO_BUILD"; seed_state(repo,rid,a)
try: program.claim_review_pass(canonical_repo=repo,run_id=rid,packet=packet)
except program.ClaimRefused: pass
else: raise AssertionError("wrong-lane review claim accepted")
a=state_mod.load(repo,rid); assert a["program"]["cumulative_counters"]["review_pass_count"]==0
a["build_pass_count"]=1; seed_state(repo,rid,a)
try: program.claim_build_pass(canonical_repo=repo,run_id=rid,packet=packet)
except program.ClaimRefused as e: assert "mirror drift" in str(e)
else: raise AssertionError("counter mirror drift accepted")
print("PASS atomic PROGRAM claim phase/mirror gate")

# 2. Idle states and prior-pass artifacts are never crash-adopted.
repo=mkrepo(); run,app=simple_run(repo,"run-v046-stale","READY_TO_BUILD"); rid=app["run_id"]
(run/"BUILD_RECEIPT.json").write_text(json.dumps({"packet_sha256":app["packet_sha256"],"builder_pass_number":1,"next_state":"READY_FOR_REVIEW","candidate_sha":app["baseline_sha"]}))
r=reconcile.reconcile_run(canonical_repo=repo,run_id=rid); assert r["ok"] and not r["artifact_adopted"]; assert state_mod.load(repo,rid)["state"]=="READY_TO_BUILD"
s=state_mod.load(repo,rid); s["state"]="READY_FOR_REVIEW"; seed_state(repo,rid,s)
(run/"REVIEW_VERDICT.json").write_text(json.dumps({"packet_sha256":app["packet_sha256"],"review_pass_number":1,"verdict":"APPROVED","recommended_next_state":"APPROVED","candidate_sha_reviewed":app["baseline_sha"]}))
r=reconcile.reconcile_run(canonical_repo=repo,run_id=rid); assert r["ok"] and not r["artifact_adopted"]; assert state_mod.load(repo,rid)["state"]=="READY_FOR_REVIEW"
print("PASS idle states ignore stale run-root artifacts")

repo=mkrepo(); run,app=simple_run(repo,"run-v046-pass","BUILDING"); rid=app["run_id"]
s=state_mod.load(repo,rid); s["build_pass_count"]=2; seed_state(repo,rid,s)
(run/"BUILD_RECEIPT.json").write_text(json.dumps({"packet_sha256":app["packet_sha256"],"builder_pass_number":1,"next_state":"READY_FOR_REVIEW","candidate_sha":app["baseline_sha"]}))
r=reconcile.reconcile_run(canonical_repo=repo,run_id=rid); assert r["ok"] and state_mod.load(repo,rid)["state"]=="BUILDING"; assert any("skip_stale_build_receipt_pass" in x for x in r["actions"])
s=state_mod.load(repo,rid); s["state"]="REVIEWING"; s["review_pass_count"]=2; seed_state(repo,rid,s)
(run/"REVIEW_VERDICT.json").write_text(json.dumps({"packet_sha256":app["packet_sha256"],"review_pass_number":1,"verdict":"APPROVED","recommended_next_state":"APPROVED","candidate_sha_reviewed":app["baseline_sha"]}))
r=reconcile.reconcile_run(canonical_repo=repo,run_id=rid); assert r["ok"] and state_mod.load(repo,rid)["state"]=="REVIEWING"; assert any("skip_stale_review_verdict_pass" in x for x in r["actions"])
print("PASS in-flight recovery requires exact pass identity")

# 3. Exact-current single-mode half-commits still recover.
repo=mkrepo(); run,app=simple_run(repo,"run-v046-current","BUILDING"); rid=app["run_id"]
s=state_mod.load(repo,rid); s["build_pass_count"]=1; seed_state(repo,rid,s)
(run/"BUILD_RECEIPT.json").write_text(json.dumps({"packet_sha256":app["packet_sha256"],"builder_pass_number":1,"next_state":"READY_FOR_REVIEW","candidate_sha":app["baseline_sha"]}))
r=reconcile.reconcile_run(canonical_repo=repo,run_id=rid); assert r["ok"] and r["artifact_adopted"]; assert state_mod.load(repo,rid)["state"]=="READY_FOR_REVIEW"
s=state_mod.load(repo,rid); s["state"]="REVIEWING"; s["review_pass_count"]=1; seed_state(repo,rid,s)
(run/"REVIEW_VERDICT.json").write_text(json.dumps({"packet_sha256":app["packet_sha256"],"review_pass_number":1,"verdict":"APPROVED","recommended_next_state":"APPROVED","candidate_sha_reviewed":app["baseline_sha"]}))
r=reconcile.reconcile_run(canonical_repo=repo,run_id=rid); assert r["ok"] and r["artifact_adopted"]; assert state_mod.load(repo,rid)["state"]=="APPROVED"
print("PASS exact-current single-mode crash recovery")

def program_fixture(two=True, verdict="APPROVED"):
    repo=mkrepo(); rid="run-v046-program-"+verdict.lower(); run=repo/".ownframework-loop"/rid; run.mkdir(parents=True)
    base=head(repo); branch=f"factory/candidate/{rid}"
    cps=[{"id":"CP-1","title":"one","scope":"one","depends_on":[],"risk_budget":{"max_build_passes":2,"max_review_passes":2,"max_repair_rounds":1}}]
    order=["CP-1"]
    if two:
        cps.append({"id":"CP-2","title":"two","scope":"two","depends_on":["CP-1"],"risk_budget":{"max_build_passes":2,"max_review_passes":2,"max_repair_rounds":1}}); order.append("CP-2")
    packet={"schema":"ownframework-work-packet/v3","packet_id":"p-v046","created_at":"2026-08-28T00:00:00Z","work_class":"FEATURE","risk_class":"low","title":"recovery",
      "target":{"repo":str(repo),"branch":"master","classification":"local_only"},"execution_mode":"program",
      "checkpoint_graph":{"execution_order":order,"checkpoints":cps},"promotion_policy":"human_gate","acceptance_criteria":[],"non_goals":[],
      "allowed_paths":["src/"],"protected_paths":[".ownframework-loop/"],"work_units":[{"id":"UNIT-1","title":"u","scope":"s"}],
      "merge_authority":"human_only","deploy_authority":"human_only","push_authority":"human_only","external_action_authority":"none",
      "risk_budget":{"max_build_passes":4,"max_review_passes":4,"max_repair_rounds":2,"max_files_changed":20,"max_diff_lines":500}}
    pp=run/"WORK_PACKET.md"; pp.write_text("```json\n"+json.dumps(packet,sort_keys=True)+"\n```\n"); sha=hashlib.sha256(pp.read_bytes()).hexdigest()
    app={"schema":"ownframework-loop-approval/v1","run_id":rid,"packet_sha256":sha,"approved_at":"2026-08-28T00:00:00Z","approved_actor":"test",
      "canonical_repo":str(repo.resolve()),"baseline_branch":"master","baseline_sha":base,"candidate_branch":branch,"packet_schema":"ownframework-work-packet/v3",
      "approval_method":"tty_confirmation","confirmation_token":approval.derive_confirmation_token(sha)}
    (run/"APPROVAL.json").write_text(json.dumps(app))
    ps=program.materialise_initial_program_state(packet,baseline_sha=base,candidate_branch=branch)
    cp=ps["checkpoints"][0]; cp["build_pass_count"]=1; cp["review_pass_count"]=1; ps["cumulative_counters"]["build_pass_count"]=1; ps["cumulative_counters"]["review_pass_count"]=1
    state=state_mod.initial_state(rid); state.update({"schema":state_mod.PROGRAM_STATE_SCHEMA_VERSION,"state":"REVIEWING","program":ps,"build_pass_count":1,"review_pass_count":1,"last_candidate_sha":base}); seed_state(repo,rid,state)
    next_state="APPROVED" if verdict=="APPROVED" else "CHANGES_REQUESTED"
    (run/"REVIEW_VERDICT.json").write_text(json.dumps({"packet_sha256":sha,"review_pass_number":1,"verdict":verdict,"recommended_next_state":next_state,"candidate_sha_reviewed":base}))
    return repo,rid

# 4. PROGRAM approval crash recovery finalizes CP-1 and advances to CP-2.
repo,rid=program_fixture(two=True,verdict="APPROVED"); r=reconcile.reconcile_run(canonical_repo=repo,run_id=rid); assert r["ok"] and r["artifact_adopted"],r
a=state_mod.load(repo,rid); assert a["state"]=="READY_TO_BUILD",a; assert a["program"]["current_checkpoints"]==["CP-2"]; assert [x["id"] for x in a["program"]["finalized_checkpoints"]]==["CP-1"]
print("PASS PROGRAM approval crash recovery uses canonical advancement")

# 5. PROGRAM repair crash recovery claims repair budget exactly once.
repo,rid=program_fixture(two=False,verdict="CHANGES_REQUESTED"); r=reconcile.reconcile_run(canonical_repo=repo,run_id=rid); assert r["ok"],r
a=state_mod.load(repo,rid); assert a["state"]=="CHANGES_REQUESTED"; assert a["repair_round"]==1; assert a["program"]["cumulative_counters"]["repair_round_count"]==1; assert a["program"]["checkpoints"][0]["repair_round_count"]==1
print("PASS PROGRAM repair crash recovery preserves repair accounting")
PY

# Teardown must consume the frozen approved branch resolver, never reconstruct a default.
grep -q "_require_valid_approval(repo, args.run_id)" "$ROOT_DIR/lib/ownframework_loop/cli.py"
grep -q "branch_resolver.resolve_candidate_branch" "$ROOT_DIR/lib/ownframework_loop/cli.py"
! grep -q 'branch = f"factory/candidate/{args.run_id}"' "$ROOT_DIR/lib/ownframework_loop/cli.py"
pass "teardown is approval-bound and branch-resolved"

echo "V046_HARDENING_TESTS=PASS"
