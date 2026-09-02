#!/usr/bin/env bash
# v0.4.5 commissioning regressions for lifecycle/exact-SHA closure.
set -euo pipefail
. "$(dirname "$0")/../_helpers.sh"

python3 -B <<'PY'
from ownframework_loop import program

packet = {
    "schema": "ownframework-work-packet/v3",
    "execution_mode": "program",
    "risk_budget": {"max_build_passes": 3, "max_review_passes": 3, "max_repair_rounds": 1},
    "checkpoint_graph": {
        "execution_order": ["CP-1"],
        "checkpoints": [{
            "id": "CP-1", "title": "one", "scope": "one", "depends_on": [],
            "risk_budget": {"max_build_passes": 2, "max_review_passes": 2, "max_repair_rounds": 1},
        }],
    },
}
ps = program.materialise_initial_program_state(packet, baseline_sha="a"*40, candidate_branch="factory/candidate/test")
cp = ps["checkpoints"][0]
assert cp["terminal"] == "", cp
cp["build_pass_count"] = 1
cp["review_pass_count"] = 1
ps["cumulative_counters"]["build_pass_count"] = 1
ps["cumulative_counters"]["review_pass_count"] = 1
out = program.finalize_checkpoint(
    program_state=ps, cp_id="CP-1", terminal_state="APPROVED",
    evidence_manifest={"_packet": packet, "candidate_sha": "b"*40},
)
assert out["checkpoints"][0]["terminal"] == "APPROVED", out
assert len(out["finalized_checkpoints"]) == 1, out
try:
    program.finalize_checkpoint(
        program_state=out, cp_id="CP-1", terminal_state="APPROVED",
        evidence_manifest={"_packet": packet},
    )
except program.ProgramStateError:
    pass
else:
    raise AssertionError("duplicate checkpoint finalization was accepted")
print("PASS fresh checkpoint finalizes exactly once")
PY

REPO="$(make_tmp_repo)"
RID="run-v045-exact"
mkdir -p "$REPO/.ownframework-loop/$RID"
BASE="$(git -C "$REPO" rev-parse HEAD)"
BRANCH="factory/candidate/$RID"
WT="$REPO/.worktrees/ownframework-loop/$RID/builder"
mkdir -p "$(dirname "$WT")"
git -C "$REPO" worktree add -b "$BRANCH" "$WT" "$BASE" >/dev/null 2>&1

# Clean builder candidate may produce an authoritative receipt.
REPO="$REPO" RID="$RID" BRANCH="$BRANCH" python3 -B <<'PY'
import os
from pathlib import Path
from ownframework_loop import git_checks, receipts
repo=Path(os.environ["REPO"]); rid=os.environ["RID"]; branch=os.environ["BRANCH"]
wt=repo/".worktrees"/"ownframework-loop"/rid/"builder"
sha=git_checks.current_head(wt)
receipts.write_receipt(repo, rid, {"candidate_sha": sha, "candidate_branch": branch})
assert receipts.receipt_path(repo,rid).exists()
receipts.receipt_path(repo,rid).unlink()
print("PASS clean exact builder can write receipt")
PY

echo dirty > "$WT/uncommitted.txt"
if REPO="$REPO" RID="$RID" BRANCH="$BRANCH" python3 -B <<'PY'
import os
from pathlib import Path
from ownframework_loop import git_checks, receipts
repo=Path(os.environ["REPO"]); rid=os.environ["RID"]; branch=os.environ["BRANCH"]
wt=repo/".worktrees"/"ownframework-loop"/rid/"builder"
try:
    receipts.write_receipt(repo, rid, {"candidate_sha": git_checks.current_head(wt), "candidate_branch": branch})
except RuntimeError:
    raise SystemExit(0)
raise SystemExit(1)
PY
then pass "dirty builder refused before authoritative receipt"; else fail "dirty builder accepted"; fi
rm "$WT/uncommitted.txt"

# Detached builder worktree is not allowed to masquerade as the expected branch.
git -C "$WT" checkout --detach >/dev/null 2>&1
if REPO="$REPO" RID="$RID" BRANCH="$BRANCH" python3 -B <<'PY'
import os
from pathlib import Path
from ownframework_loop import worktrees
repo=Path(os.environ["REPO"])
try:
    worktrees.add_builder_worktree(repo, os.environ["RID"], branch=os.environ["BRANCH"])
except worktrees.WorktreeError:
    raise SystemExit(0)
raise SystemExit(1)
PY
then pass "detached builder worktree refused"; else fail "detached builder worktree accepted"; fi

# Reviewer verdict is exact-SHA + clean-tree gated.
RWT="$REPO/.worktrees/ownframework-loop/$RID/reviewer"
git -C "$REPO" worktree add --detach "$RWT" "$BASE" >/dev/null 2>&1
REPO="$REPO" RID="$RID" BASE="$BASE" python3 -B <<'PY'
import os
from pathlib import Path
from ownframework_loop import verdicts
repo=Path(os.environ["REPO"]); rid=os.environ["RID"]
verdicts.write_verdict(repo, rid, {"candidate_sha_reviewed": os.environ["BASE"]})
verdicts.verdict_path(repo,rid).unlink()
print("PASS clean exact reviewer can write verdict")
PY

echo dirty > "$RWT/uncommitted.txt"
# Untracked files do NOT modify the reviewed candidate SHA. The verdict
# writer must remain authoritative so packet-declared validation commands
# that produce coverage reports or build caches cannot wedge the run.
if REPO="$REPO" RID="$RID" BASE="$BASE" python3 -B <<'PY'
import os
from pathlib import Path
from ownframework_loop import verdicts
repo=Path(os.environ["REPO"])
try:
    verdicts.write_verdict(repo, os.environ["RID"], {"candidate_sha_reviewed": os.environ["BASE"]})
    raise SystemExit(0)
except RuntimeError:
    raise SystemExit(1)
PY
then pass "untracked-only reviewer dirt tolerated by verdict writer"; else fail "untracked-only reviewer dirt refused"; fi

# A tracked mutation (which DOES modify the reviewed SHA) must still be
# refused, even though HEAD has not moved.
echo "tracked mutation" > "$RWT/src_module.py"
git -C "$RWT" add src_module.py >/dev/null 2>&1
if REPO="$REPO" RID="$RID" BASE="$BASE" python3 -B <<'PY'
import os
from pathlib import Path
from ownframework_loop import verdicts
repo=Path(os.environ["REPO"])
try:
    verdicts.write_verdict(repo, os.environ["RID"], {"candidate_sha_reviewed": os.environ["BASE"]})
except RuntimeError:
    raise SystemExit(0)
raise SystemExit(1)
PY
then pass "tracked-mutation reviewer refused before authoritative verdict"; else fail "tracked-mutation reviewer accepted"; fi

# PROGRAM provenance is a valid resolver fallback when approval is absent.
BREPO="$(make_tmp_repo)"
BRID="run-v045-provenance"
mkdir -p "$BREPO/.ownframework-loop/$BRID"
BREPO="$BREPO" BRID="$BRID" python3 -B <<'PY'
import json, os
from pathlib import Path
from ownframework_loop import branch_resolver
repo=Path(os.environ["BREPO"]); rid=os.environ["BRID"]
state={"program":{"source_sha_provenance":{"candidate_branch":"factory/candidate/from-program"}}}
(repo/".ownframework-loop"/rid/"STATE.json").write_text(json.dumps(state))
assert branch_resolver.resolve_candidate_branch(repo,rid)=="factory/candidate/from-program"
print("PASS PROGRAM provenance branch fallback")
PY

# Repair-cap exhaustion must seal the run BLOCKED, never reopen READY_TO_BUILD.
PREPO="$(make_tmp_repo)"
PRID="run-v045-repair-cap"
mkdir -p "$PREPO/.ownframework-loop/$PRID"
PREPO="$PREPO" PRID="$PRID" ROOT_DIR="$ROOT_DIR" python3 -B <<'PY'
import os, sys
from pathlib import Path
from ownframework_loop import program, state as state_mod
sys.path.insert(0, str(Path(os.environ["ROOT_DIR"]) / "tests" / "helpers"))
from state_seed import seed_state
repo=Path(os.environ["PREPO"]); rid=os.environ["PRID"]
packet={
 "schema":"ownframework-work-packet/v3","execution_mode":"program",
 "risk_budget":{"max_build_passes":2,"max_review_passes":2,"max_repair_rounds":1},
 "checkpoint_graph":{"execution_order":["CP-1"],"checkpoints":[{
   "id":"CP-1","title":"one","scope":"one","depends_on":[],
   "risk_budget":{"max_build_passes":2,"max_review_passes":2,"max_repair_rounds":1}}]}}
state=state_mod.initial_state(rid)
state["schema"]=state_mod.PROGRAM_STATE_SCHEMA_VERSION
state["state"]="CHANGES_REQUESTED"
state["program"]=program.materialise_initial_program_state(packet, baseline_sha="a"*40, candidate_branch="factory/candidate/x")
state["program"]["checkpoints"][0]["repair_round_count"]=1
state["program"]["cumulative_counters"]["repair_round_count"]=1
state["repair_round"]=1
seed_state(repo, rid, state, reason="fixture PROGRAM repair-cap crash state")
try:
    program.claim_repair_round(canonical_repo=repo,run_id=rid,packet=packet,source_evidence_sha="e"*40)
except program.ClaimRefused:
    pass
else:
    raise AssertionError("repair cap was bypassed")
assert state_mod.load(repo,rid)["state"]=="BLOCKED", state_mod.load(repo,rid)
print("PASS repair-cap refusal seals PROGRAM run BLOCKED")
PY

# Current-pass hook: exact pass is writable; historical/future pass is not.
HREPO="$(make_tmp_repo)"
HRID="run-v045-hook"
mkdir -p "$HREPO/.ownframework-loop/$HRID/scratch/builder/pass-0001" "$HREPO/.ownframework-loop/$HRID/scratch/builder/pass-0002"
HREPO="$HREPO" HRID="$HRID" python3 -B <<'PY'
import json, os, sys
from pathlib import Path
sys.path.insert(0, os.environ.get("OFLOOP_LIB", ""))
repo=Path(os.environ["HREPO"]); rid=os.environ["HRID"]
(repo/".ownframework-loop"/rid/"STATE.json").write_text(json.dumps({"state":"BUILDING","build_pass_count":2,"review_pass_count":0}))
# v0.7.0: the write guard is scoped by the explicit execution-context
# contract. Establish a foreground builder lane so the current-pass
# scoping is active.
from ownframework_loop import role_context
role_context.enter_semantic_role(canonical_repo=repo, run_id=rid, role="builder")
PY
hook_call() {
  local target="$1"
  python3 - "$HREPO" "$target" <<'PY' | OFLOOP_PLUGIN_ROOT="$ROOT_DIR" bash "$ROOT_DIR/hooks/block_protected_paths.sh"
import json,sys
print(json.dumps({"tool_name":"Write","cwd":sys.argv[1],"tool_input":{"file_path":sys.argv[2]}}))
PY
}
OLD_OUT="$(hook_call "$HREPO/.ownframework-loop/$HRID/scratch/builder/pass-0001/BUILD_AGENT_RESULT.json")"
NEW_OUT="$(hook_call "$HREPO/.ownframework-loop/$HRID/scratch/builder/pass-0002/BUILD_AGENT_RESULT.json")"
[[ "$OLD_OUT" == *"OF_LOOP_PROTECTED_PATH"* ]] && pass "historical builder scratch refused" || fail "historical builder scratch writable"
[[ -z "$NEW_OUT" ]] && pass "exact current builder scratch allowed" || fail "current builder scratch refused: $NEW_OUT"

echo "V045_HARDENING_TESTS=PASS"
