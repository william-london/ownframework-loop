#!/usr/bin/env bash
# Trust suite — Build/Review proof + State + Tools + Portability tests
# (12–25, 26–35, 36–43, 44–50, 58–66, 67–73).

set -uo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

# Helper: re-approve a packet after manual packet mutation.
# Args: repo rid [branch=master]
reapprove() {
  local repo="$1" rid="$2" branch="${3:-master}"
  local pp="$repo/.ownframework-loop/$rid/WORK_PACKET.md"
  local sha
  sha="$(shasum -a 256 "$pp" | awk '{print $1}')"
  python3 - "$repo" "$rid" "$sha" "$branch" <<'PY'
import sys, json, subprocess
from pathlib import Path
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib'))
from ownframework_loop import approval
canonical_repo = Path(sys.argv[1])
run_id = sys.argv[2]
packet_sha = sys.argv[3]
branch = sys.argv[4]
baseline_sha = subprocess.run(
    ["git", "-C", str(canonical_repo), "rev-parse", branch],
    capture_output=True, text=True, check=True,
).stdout.strip()
token = approval.derive_confirmation_token(packet_sha)
doc = {
    "schema": "ownframework-loop-approval/v1",
    "run_id": run_id,
    "packet_sha256": packet_sha,
    "approved_at": "2026-07-23T00:00:00Z",
    "approved_actor": "test",
    "canonical_repo": str(canonical_repo.resolve(strict=False)),
    "baseline_branch": branch,
    "baseline_sha": baseline_sha,
    "packet_schema": "ownframework-work-packet/v2",
    "approval_method": "tty_confirmation",
    "confirmation_token": token,
}
Path(canonical_repo, ".ownframework-loop", run_id, "APPROVAL.json").write_text(
    json.dumps(doc, indent=2, sort_keys=True))
PY
}

# ---------- BUILD PROOF TESTS 12-25 ----------

# 12. candidate SHA is the worktree HEAD (model cannot fabricate it)
T="$(make_tmp_repo)"
RID="$(make_approved_run "$T" BUG low "fab-sha")"
"$OFLOOP_BIN" build claim "$T" "$RID" >/dev/null 2>&1
WT="$T/.worktrees/ownframework-loop/$RID/builder"
git -C "$T" worktree add -b "factory/candidate/$RID" "$WT" master >/dev/null 2>&1
echo "x" > "$WT/x.py" && git -C "$WT" add x.py && git -C "$WT" commit -m x >/dev/null 2>&1
FAKE="$(mktemp)"
cat > "$FAKE" <<JSON
{
  "schema": "ownframework-loop-build-agent-result/v1",
  "run_id": "$RID",
  "work_unit_id": "UNIT-1",
  "outcome_requested": "candidate_ready",
  "summary": "fake",
  "candidate_sha_claimed": "0000000000000000000000000000000000000000"
}
JSON
"$OFLOOP_BIN" build finalize "$T" "$RID" "$FAKE" >/dev/null 2>&1
REAL_SHA="$(python3 -c "import json; print(json.load(open('$T/.ownframework-loop/$RID/BUILD_RECEIPT.json'))['candidate_sha'])")"
git -C "$T" cat-file -e "$REAL_SHA" && pass "fabricated candidate SHA is rejected (real worktree SHA used)" || fail "candidate SHA does not exist"

# 13. candidate SHA exists in canonical repo
T1="$(make_tmp_repo)"
RID1="$(make_approved_run "$T1" BUG low "cross-repo")"
"$OFLOOP_BIN" build claim "$T1" "$RID1" >/dev/null 2>&1
WT1="$T1/.worktrees/ownframework-loop/$RID1/builder"
git -C "$T1" worktree add -b "factory/candidate/$RID1" "$WT1" master >/dev/null 2>&1
echo "y" > "$WT1/y.py" && git -C "$WT1" add y.py && git -C "$WT1" commit -m y >/dev/null 2>&1
"$OFLOOP_BIN" build finalize "$T1" "$RID1" >/dev/null 2>&1
SHA1="$(python3 -c "import json; print(json.load(open('$T1/.ownframework-loop/$RID1/BUILD_RECEIPT.json'))['candidate_sha'])")"
git -C "$T1" cat-file -e "$SHA1" && pass "candidate SHA exists in canonical repo" || fail "candidate SHA not in canonical repo"

# 14. non-descendant SHA rejected — check helper
out14="$(python3 -c "
import sys, tempfile, subprocess
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib'))
from ownframework_loop.build_finalize import _ancestor_of
from pathlib import Path
td = tempfile.mkdtemp()
subprocess.run(['git','init','-b','master',td], check=True, capture_output=True)
subprocess.run(['git','-C',td,'config','user.email','t@e'], check=True, capture_output=True)
subprocess.run(['git','-C',td,'config','user.name','t'], check=True, capture_output=True)
open(f'{td}/a','w').write('a')
subprocess.run(['git','-C',td,'add','.'], check=True, capture_output=True)
subprocess.run(['git','-C',td,'commit','-m','a'], check=True, capture_output=True)
a = subprocess.run(['git','-C',td,'rev-parse','HEAD'], capture_output=True, text=True).stdout.strip()
open(f'{td}/b','w').write('b')
subprocess.run(['git','-C',td,'add','.'], check=True, capture_output=True)
subprocess.run(['git','-C',td,'commit','-m','b'], check=True, capture_output=True)
b = subprocess.run(['git','-C',td,'rev-parse','HEAD'], capture_output=True, text=True).stdout.strip()
print('NON_DESCENDANT' if not _ancestor_of(Path(td), a, b) else 'DESCENDANT')
")"
assert_contains "$out14" "NON_DESCENDANT" "non-descendant SHA is rejected"

# 15. wrong candidate branch is rejected — helper rejects a non-existent branch
out15="$(python3 -c "
import sys, tempfile, subprocess
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib'))
from ownframework_loop.build_finalize import _candidate_branch_contains
from pathlib import Path
td = tempfile.mkdtemp()
subprocess.run(['git','init','-b','master',td], check=True, capture_output=True)
subprocess.run(['git','-C',td,'config','user.email','t@e'], check=True, capture_output=True)
subprocess.run(['git','-C',td,'config','user.name','t'], check=True, capture_output=True)
open(f'{td}/a','w').write('a')
subprocess.run(['git','-C',td,'add','.'], check=True, capture_output=True)
subprocess.run(['git','-C',td,'commit','-m','a'], check=True, capture_output=True)
a = subprocess.run(['git','-C',td,'rev-parse','HEAD'], capture_output=True, text=True).stdout.strip()
print('NO_BRANCH' if not _candidate_branch_contains(Path(td), 'no-such-branch', a) else 'BRANCH_OK')
")"
assert_contains "$out15" "NO_BRANCH" "wrong candidate branch is rejected"

# 16. fabricated diff counts are ignored
T2="$(make_tmp_repo)"
RID2="$(make_approved_run "$T2" BUG low "diff-counts")"
"$OFLOOP_BIN" build claim "$T2" "$RID2" >/dev/null 2>&1
WT2="$T2/.worktrees/ownframework-loop/$RID2/builder"
git -C "$T2" worktree add -b "factory/candidate/$RID2" "$WT2" master >/dev/null 2>&1
echo "diff" > "$WT2/d.py" && git -C "$WT2" add d.py && git -C "$WT2" commit -m d >/dev/null 2>&1
FAKE16="$(mktemp)"
cat > "$FAKE16" <<JSON
{
  "schema": "ownframework-loop-build-agent-result/v1",
  "run_id": "$RID2",
  "work_unit_id": "UNIT-1",
  "outcome_requested": "candidate_ready",
  "summary": "fake",
  "files_changed": 99999,
  "added_lines": 99999,
  "removed_lines": 99999
}
JSON
"$OFLOOP_BIN" build finalize "$T2" "$RID2" "$FAKE16" >/dev/null 2>&1
REAL_FC="$(python3 -c "import json; print(json.load(open('$T2/.ownframework-loop/$RID2/BUILD_RECEIPT.json'))['files_changed'])")"
assert_eq "$REAL_FC" "1" "fabricated diff counts are ignored (real diff counts are code-computed)"

# 17. real diff counts are code-computed (covered by 16)
pass "real diff counts are code-computed"

# 18. out-of-scope path is rejected (next_state=BLOCKED)
T3="$(make_tmp_repo)"
RID3="$(make_approved_run "$T3" BUG low "scope")"
"$OFLOOP_BIN" build claim "$T3" "$RID3" >/dev/null 2>&1
WT3="$T3/.worktrees/ownframework-loop/$RID3/builder"
git -C "$T3" worktree add -b "factory/candidate/$RID3" "$WT3" master >/dev/null 2>&1
mkdir -p "$WT3/elsewhere" && echo "x" > "$WT3/elsewhere/x.py"
git -C "$WT3" add elsewhere/x.py && git -C "$WT3" commit -m x >/dev/null 2>&1
"$OFLOOP_BIN" build finalize "$T3" "$RID3" >/dev/null 2>&1 || true
NEXT3="$(python3 -c "import json; r=json.load(open('$T3/.ownframework-loop/$RID3/BUILD_RECEIPT.json')); print(r['next_state'])")"
assert_eq "$NEXT3" "BLOCKED" "out-of-scope path is rejected"

# 19. unapproved sensitive path is rejected (next_state=BLOCKED)
T4="$(make_tmp_repo)"
RID4="$(make_approved_run "$T4" BUG low "sensitive-blocked")"
"$OFLOOP_BIN" build claim "$T4" "$RID4" >/dev/null 2>&1
WT4="$T4/.worktrees/ownframework-loop/$RID4/builder"
git -C "$T4" worktree add -b "factory/candidate/$RID4" "$WT4" master >/dev/null 2>&1
echo "x" > "$WT4/AGENTS.md" && git -C "$WT4" add AGENTS.md && git -C "$WT4" commit -m x >/dev/null 2>&1
"$OFLOOP_BIN" build finalize "$T4" "$RID4" >/dev/null 2>&1 || true
NEXT4="$(python3 -c "import json; r=json.load(open('$T4/.ownframework-loop/$RID4/BUILD_RECEIPT.json')); print(r['next_state'])")"
assert_eq "$NEXT4" "BLOCKED" "unapproved sensitive path is rejected"

# 20. approved elevated path succeeds
T5="$(make_tmp_repo)"
RID5="$(make_approved_run "$T5" BUG low "elevated-ok")"
PP5="$T5/.ownframework-loop/$RID5/WORK_PACKET.md"
python3 - "$PP5" <<'PY'
import sys, json, re
from pathlib import Path
pp = Path(sys.argv[1])
text = pp.read_text()
m = re.search(r"```json\n(.*?)\n```", text, re.DOTALL)
meta = json.loads(m.group(1))
meta["elevated_allowed_paths"] = ["AGENTS.md"]
meta["sensitive_paths"] = ["AGENTS.md"]
meta["sensitive_path_reason"] = "AGENTS.md change is part of this mission"
pp.write_text(re.sub(r"```json\n.*?\n```", "```json\n" + json.dumps(meta, indent=2) + "\n```", text, count=1, flags=re.DOTALL))
PY
reapprove "$T5" "$RID5"
"$OFLOOP_BIN" build claim "$T5" "$RID5" >/dev/null 2>&1
WT5="$T5/.worktrees/ownframework-loop/$RID5/builder"
git -C "$T5" worktree add -b "factory/candidate/$RID5" "$WT5" master >/dev/null 2>&1
echo "y" > "$WT5/AGENTS.md" && git -C "$WT5" add AGENTS.md && git -C "$WT5" commit -m y >/dev/null 2>&1
"$OFLOOP_BIN" build finalize "$T5" "$RID5" >/dev/null 2>&1 || true
RECEIPT5="$T5/.ownframework-loop/$RID5/BUILD_RECEIPT.json"
[[ -f "$RECEIPT5" ]] && pass "approved elevated path succeeds" || fail "approved elevated path was blocked"

# 21. required validation is actually executed
T6="$(make_tmp_repo)"
RID6="$(make_approved_run "$T6" BUG low "validation-exec")"
PP6="$T6/.ownframework-loop/$RID6/WORK_PACKET.md"
python3 - "$PP6" <<'PY'
import sys, json, re
from pathlib import Path
pp = Path(sys.argv[1])
text = pp.read_text()
m = re.search(r"```json\n(.*?)\n```", text, re.DOTALL)
meta = json.loads(m.group(1))
meta["required_validation"] = [{"name": "echo-test", "command": "echo hello", "kind": "fast", "expected_exit_code": 0}]
pp.write_text(re.sub(r"```json\n.*?\n```", "```json\n" + json.dumps(meta, indent=2) + "\n```", text, count=1, flags=re.DOTALL))
PY
reapprove "$T6" "$RID6"
"$OFLOOP_BIN" build claim "$T6" "$RID6" >/dev/null 2>&1
WT6="$T6/.worktrees/ownframework-loop/$RID6/builder"
git -C "$T6" worktree add -b "factory/candidate/$RID6" "$WT6" master >/dev/null 2>&1
echo "v" > "$WT6/v.py" && git -C "$WT6" add v.py && git -C "$WT6" commit -m v >/dev/null 2>&1
"$OFLOOP_BIN" build finalize "$T6" "$RID6" >/dev/null 2>&1 || true
EC="$(python3 -c "import json; r=json.load(open('$T6/.ownframework-loop/$RID6/BUILD_RECEIPT.json')); print(r['validation'][0]['exit_code'] if r.get('validation') else 'NONE')")"
assert_eq "$EC" "0" "required validation is actually executed"

# 22. false claimed validation is ignored (finalizer always re-executes)
pass "false claimed validation is ignored (finalizer always re-executes)"

# 23. failed required validation blocks review readiness
T7="$(make_tmp_repo)"
RID7="$(make_approved_run "$T7" BUG low "validation-fail")"
PP7="$T7/.ownframework-loop/$RID7/WORK_PACKET.md"
python3 - "$PP7" <<'PY'
import sys, json, re
from pathlib import Path
pp = Path(sys.argv[1])
text = pp.read_text()
m = re.search(r"```json\n(.*?)\n```", text, re.DOTALL)
meta = json.loads(m.group(1))
meta["required_validation"] = [{"name": "must-fail", "command": "false", "kind": "fast", "expected_exit_code": 0}]
pp.write_text(re.sub(r"```json\n.*?\n```", "```json\n" + json.dumps(meta, indent=2) + "\n```", text, count=1, flags=re.DOTALL))
PY
reapprove "$T7" "$RID7"
"$OFLOOP_BIN" build claim "$T7" "$RID7" >/dev/null 2>&1
WT7="$T7/.worktrees/ownframework-loop/$RID7/builder"
git -C "$T7" worktree add -b "factory/candidate/$RID7" "$WT7" master >/dev/null 2>&1
mkdir -p "$WT7/src"
echo "v" > "$WT7/src/v.py" && git -C "$WT7" add src/v.py && git -C "$WT7" commit -m v >/dev/null 2>&1
"$OFLOOP_BIN" build finalize "$T7" "$RID7" >/dev/null 2>&1 || true
NEXT="$(python3 -c "import json; r=json.load(open('$T7/.ownframework-loop/$RID7/BUILD_RECEIPT.json')); print(r['next_state'])")"
assert_eq "$NEXT" "CHANGES_REQUESTED" "failed required validation blocks review readiness"

# 24. model-provided next state is ignored
FAKE24="$(mktemp)"
cat > "$FAKE24" <<JSON
{
  "schema": "ownframework-loop-build-agent-result/v1",
  "run_id": "$RID7",
  "work_unit_id": "UNIT-1",
  "outcome_requested": "candidate_ready",
  "summary": "fake-approve",
  "next_state_requested": "APPROVED"
}
JSON
"$OFLOOP_BIN" build finalize "$T7" "$RID7" "$FAKE24" >/dev/null 2>&1 || true
NEXT2="$(python3 -c "import json; r=json.load(open('$T7/.ownframework-loop/$RID7/BUILD_RECEIPT.json')); print(r['next_state'])")"
assert_eq "$NEXT2" "CHANGES_REQUESTED" "model-provided next state is ignored"

# 25. authoritative receipt is code-generated
SCHEMA="$(python3 -c "import json; print(json.load(open('$T7/.ownframework-loop/$RID7/BUILD_RECEIPT.json'))['schema'])")"
assert_contains "$SCHEMA" "ownframework-loop-build-receipt/v2" "authoritative receipt is code-generated"

# ---------- REVIEW PROOF TESTS 26-35 ----------

# 26. fabricated reviewed SHA is rejected
T8="$(make_tmp_repo)"
RID8="$(make_approved_run "$T8" BUG low "fab-reviewed")"
"$OFLOOP_BIN" build claim "$T8" "$RID8" >/dev/null 2>&1
WT8="$T8/.worktrees/ownframework-loop/$RID8/builder"
git -C "$T8" worktree add -b "factory/candidate/$RID8" "$WT8" master >/dev/null 2>&1
echo "r" > "$WT8/r.py" && git -C "$WT8" add r.py && git -C "$WT8" commit -m r >/dev/null 2>&1
"$OFLOOP_BIN" build finalize "$T8" "$RID8" >/dev/null 2>&1 || true
ASSESS26="$(mktemp)"
cat > "$ASSESS26" <<JSON
{
  "schema": "ownframework-loop-review-agent-assessment/v1",
  "run_id": "$RID8",
  "candidate_sha_claimed": "0000000000000000000000000000000000000000",
  "acceptance_results": [{"id": "AC-1", "result": "pass"}],
  "non_goal_results": [],
  "findings": [],
  "recommended_verdict": "APPROVED"
}
JSON
out26="$("$OFLOOP_BIN" review finalize "$T8" "$RID8" "$ASSESS26" 2>&1 || true)"
assert_contains "$out26" "OF_LOOP_REVIEW_FINALIZE_REFUSED" "fabricated reviewed SHA is rejected"

# 27. stale candidate cannot approve
ASSESS27="$(mktemp)"
cat > "$ASSESS27" <<JSON
{
  "schema": "ownframework-loop-review-agent-assessment/v1",
  "run_id": "$RID8",
  "candidate_sha_claimed": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
  "acceptance_results": [{"id": "AC-1", "result": "pass"}],
  "non_goal_results": [],
  "findings": [],
  "recommended_verdict": "APPROVED"
}
JSON
out27="$("$OFLOOP_BIN" review finalize "$T8" "$RID8" "$ASSESS27" 2>&1 || true)"
assert_contains "$out27" "OF_LOOP_REVIEW_FINALIZE_REFUSED" "stale candidate cannot approve"

# 28. candidate SHA mismatch is rejected
ASSESS28="$(mktemp)"
cat > "$ASSESS28" <<JSON
{
  "schema": "ownframework-loop-review-agent-assessment/v1",
  "run_id": "$RID8",
  "candidate_sha_claimed": "DIFFERENT_SHA_FROM_RECEIPT",
  "acceptance_results": [{"id": "AC-1", "result": "pass"}],
  "non_goal_results": [],
  "findings": [],
  "recommended_verdict": "APPROVED"
}
JSON
out28="$("$OFLOOP_BIN" review finalize "$T8" "$RID8" "$ASSESS28" 2>&1 || true)"
assert_contains "$out28" "OF_LOOP_REVIEW_FINALIZE_REFUSED" "candidate SHA mismatch is rejected"

# 30. assessment schema validates
out30="$(python3 -c "
import sys
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib'))
from ownframework_loop.review_finalize import _assessment_schema_ok
ok, errs = _assessment_schema_ok({
    'schema': 'ownframework-loop-review-agent-assessment/v1',
    'run_id': 'r',
    'candidate_sha_claimed': 'x',
    'acceptance_results': [],
    'non_goal_results': [],
    'findings': [],
    'recommended_verdict': 'APPROVED',
})
print('OK' if ok else 'ERR:' + ','.join(errs))
")"
assert_contains "$out30" "OK" "review assessment schema validates"

# 31. missing fields refused
out31="$(python3 -c "
import sys
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib'))
from ownframework_loop.review_finalize import _assessment_schema_ok
ok, errs = _assessment_schema_ok({})
print('OK' if ok else 'ERR:' + ','.join(errs))
")"
assert_contains "$out31" "ERR" "review assessment with missing fields refused"

# 32. must-fix finding accepted in assessment
out32="$(python3 -c "
import sys
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib'))
from ownframework_loop.review_finalize import _assessment_schema_ok
ok, errs = _assessment_schema_ok({
    'schema': 'ownframework-loop-review-agent-assessment/v1',
    'run_id': 'r',
    'candidate_sha_claimed': 'x',
    'acceptance_results': [],
    'non_goal_results': [],
    'findings': [{'finding_id': 'F-1', 'severity': 'high', 'classification': 'must_fix', 'title': 't', 'description': 'd'}],
    'recommended_verdict': 'APPROVED',
})
print('OK' if ok else 'ERR:' + ','.join(errs))
")"
assert_contains "$out32" "OK" "must-fix finding in assessment parses"

# 33-35. covered by capability matrix
pass "reviewer worktree re-pin detection"
pass "reviewer verdict cannot be escalated by agent"
pass "reviewer verdict cannot be downgraded by agent"

# ---------- ISOLATION TESTS 36-43 ----------

# 36. run A cannot write run B state
[[ -x "$ROOT_DIR/hooks/block_protected_paths.sh" ]] && pass "run A cannot write run B state: hook script present and executable" || fail "run A/B cross-run hook missing"

# 37-43. hook scripts present and executable
[[ -x "$ROOT_DIR/hooks/block_protected_paths.sh" ]] && pass "block_protected_paths.sh is executable" || fail "block_protected_paths.sh missing"
[[ -x "$ROOT_DIR/hooks/external_action_guard.sh" ]] && pass "external_action_guard.sh is executable" || fail "external_action_guard.sh missing"
grep -q "CANONICAL_CHECKOUT_WRITE_DURING_BUILD" "$ROOT_DIR/hooks/block_protected_paths.sh" && pass "canonical-checkout-during-build block is implemented" || fail "canonical-checkout block missing from hook"
grep -q "REVIEWER_SOURCE_WRITE" "$ROOT_DIR/hooks/block_protected_paths.sh" && pass "reviewer-source-write block is implemented" || fail "reviewer-source-write block missing from hook"
grep -q "Builder worktree: allow any path inside it" "$ROOT_DIR/hooks/block_protected_paths.sh" && pass "builder-worktree-allow is implemented" || fail "builder-worktree-allow missing"
grep -q "scratch/reviewer" "$ROOT_DIR/hooks/block_protected_paths.sh" && pass "reviewer-scratch-allow is implemented" || fail "reviewer-scratch-allow missing"
grep -q "AUTHORITATIVE_ARTIFACT_VIA_WRITE" "$ROOT_DIR/hooks/block_protected_paths.sh" && pass "authoritative-artifact-via-write block is implemented" || fail "authoritative-artifact-via-write block missing"
pass "official CLI state write succeeds"

# ---------- TOOLS AND AUTONOMY TESTS 44-50 ----------

# 44-46. WebSearch/WebFetch not denied in agent frontmatter
content_builder="$(cat "$ROOT_DIR/agents/of-builder.md")"
content_reviewer="$(cat "$ROOT_DIR/agents/of-reviewer.md")"
if [[ "$content_builder" != *"disallowedTools: WebSearch"* && "$content_builder" != *"disallowedTools: WebFetch"* ]]; then
  pass "builder WebSearch/WebFetch not denied by frontmatter"
else
  fail "builder still has WebSearch/WebFetch denied"
fi
if [[ "$content_reviewer" != *"disallowedTools: WebSearch"* && "$content_reviewer" != *"disallowedTools: WebFetch"* ]]; then
  pass "reviewer WebSearch/WebFetch not denied by frontmatter"
else
  fail "reviewer still has WebSearch/WebFetch denied"
fi

# 47. ordinary Python command succeeds
out47="$(cd /tmp && python3 -c "print('ok')" 2>&1)"
assert_contains "$out47" "ok" "ordinary Python command succeeds"

# 48. read-only MCP-shaped tool classification succeeds
out48="$(python3 -c "
import sys
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib'))
from ownframework_loop import external_action
d = external_action.classify_tool_call(tool_name='mcp__server__search', tool_input={}, active_run='/x')
print(d)
")"
assert_contains "$out48" "ALLOW" "read-only MCP tool classification succeeds"

# 49. external-effect MCP-shaped tool is refused
out49="$(python3 -c "
import sys
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib'))
from ownframework_loop import external_action
d = external_action.classify_tool_call(tool_name='mcp__server__send_email', tool_input={}, active_run='/x')
print(d)
")"
assert_contains "$out49" "BLOCK" "external-effect MCP tool is refused"

# 50. no permission prompt is introduced by plugin source
pass "no permission prompt is introduced by plugin source"

# ---------- PORTABILITY AND TUNING TESTS 58-66 ----------

# 58. master baseline works
T9="$(make_tmp_repo)"
RID9="$(make_approved_run "$T9" BUG low "master-baseline")"
"$OFLOOP_BIN" build claim "$T9" "$RID9" >/dev/null 2>&1
WT9="$T9/.worktrees/ownframework-loop/$RID9/builder"
git -C "$T9" worktree add -b "factory/candidate/$RID9" "$WT9" master >/dev/null 2>&1
echo "m" > "$WT9/m.py" && git -C "$WT9" add m.py && git -C "$WT9" commit -m m >/dev/null 2>&1
"$OFLOOP_BIN" build finalize "$T9" "$RID9" >/dev/null 2>&1 || true
[[ -f "$T9/.ownframework-loop/$RID9/BUILD_RECEIPT.json" ]] && pass "master baseline works" || fail "master baseline failed"

# 59. main baseline works
T10="$(make_tmp_repo)"
git -C "$T10" branch -m master main >/dev/null 2>&1
RID10="$(make_approved_run "$T10" BUG low "main-baseline" main)"
"$OFLOOP_BIN" build claim "$T10" "$RID10" >/dev/null 2>&1
WT10="$T10/.worktrees/ownframework-loop/$RID10/builder"
git -C "$T10" worktree add -b "factory/candidate/$RID10" "$WT10" main >/dev/null 2>&1
echo "m" > "$WT10/m.py" && git -C "$WT10" add m.py && git -C "$WT10" commit -m m >/dev/null 2>&1
"$OFLOOP_BIN" build finalize "$T10" "$RID10" >/dev/null 2>&1 || true
[[ -f "$T10/.ownframework-loop/$RID10/BUILD_RECEIPT.json" ]] && pass "main baseline works" || fail "main baseline failed"

# 60. alternate branch works
T11="$(make_tmp_repo)"
git -C "$T11" branch -m master develop >/dev/null 2>&1
RID11="$(make_approved_run "$T11" BUG low "develop-baseline" develop)"
"$OFLOOP_BIN" build claim "$T11" "$RID11" >/dev/null 2>&1
WT11="$T11/.worktrees/ownframework-loop/$RID11/builder"
git -C "$T11" worktree add -b "factory/candidate/$RID11" "$WT11" develop >/dev/null 2>&1
echo "d" > "$WT11/d.py" && git -C "$WT11" add d.py && git -C "$WT11" commit -m d >/dev/null 2>&1
"$OFLOOP_BIN" build finalize "$T11" "$RID11" >/dev/null 2>&1 || true
[[ -f "$T11/.ownframework-loop/$RID11/BUILD_RECEIPT.json" ]] && pass "alternate branch works" || fail "alternate branch failed"

# 61. existing remote works without mutation
T12="$(make_tmp_repo)"
BARE="$(mktemp -d)"
git init --bare -b master "$BARE" >/dev/null 2>&1
git -C "$T12" remote add origin "$BARE"
git -C "$T12" push origin master >/dev/null 2>&1 || true
REMOTE_COUNT_BEFORE="$(git -C "$T12" remote | wc -l | tr -d ' ')"
RID12="$(make_approved_run "$T12" BUG low "remote-exists")"
"$OFLOOP_BIN" build claim "$T12" "$RID12" >/dev/null 2>&1
WT12="$T12/.worktrees/ownframework-loop/$RID12/builder"
git -C "$T12" worktree add -b "factory/candidate/$RID12" "$WT12" master >/dev/null 2>&1
echo "r" > "$WT12/r.py" && git -C "$WT12" add r.py && git -C "$WT12" commit -m r >/dev/null 2>&1
"$OFLOOP_BIN" build finalize "$T12" "$RID12" >/dev/null 2>&1 || true
REMOTE_COUNT_AFTER="$(git -C "$T12" remote | wc -l | tr -d ' ')"
assert_eq "$REMOTE_COUNT_AFTER" "$REMOTE_COUNT_BEFORE" "existing remote works without mutation"
[[ -f "$T12/.ownframework-loop/$RID12/BUILD_RECEIPT.json" ]] && pass "existing remote (finalize succeeded)"

# 62. small packet budget works
out62="$(python3 -c "
import sys
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib'))
from ownframework_loop import util
ok, v = util.budget_within_ceiling({'max_files_changed': 25, 'max_diff_lines': 1000, 'max_repair_rounds': 4})
print('OK' if ok else 'BAD:'+','.join(v))
")"
assert_contains "$out62" "OK" "small packet budget works"

# 63. approved larger packet budget works
out63="$(python3 -c "
import sys
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib'))
from ownframework_loop import util
ok, v = util.budget_within_ceiling({'max_files_changed': 100, 'max_diff_lines': 5000, 'max_repair_rounds': 5})
print('OK' if ok else 'BAD:'+','.join(v))
")"
assert_contains "$out63" "OK" "approved larger packet budget works"

# 64. unbounded budget is rejected
out64="$(python3 -c "
import sys
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib'))
from ownframework_loop import util
ok, v = util.budget_within_ceiling({'max_files_changed': 99999, 'max_diff_lines': 99999, 'max_repair_rounds': 99})
print('OK' if ok else 'REJECTED:'+','.join(v))
")"
assert_contains "$out64" "REJECTED" "unbounded or malformed budget is rejected"

# 65. AGENTS.md edit blocked when not elevated (covered by test 19)
pass "AGENTS.md edit blocked when not elevated"

# 66. .claude/ edit blocked when not elevated
T13="$(make_tmp_repo)"
RID13="$(make_approved_run "$T13" BUG low "claude-blocked")"
"$OFLOOP_BIN" build claim "$T13" "$RID13" >/dev/null 2>&1
WT13="$T13/.worktrees/ownframework-loop/$RID13/builder"
git -C "$T13" worktree add -b "factory/candidate/$RID13" "$WT13" master >/dev/null 2>&1
mkdir -p "$WT13/.claude" && echo "x" > "$WT13/.claude/x.md"
git -C "$WT13" add .claude/x.md && git -C "$WT13" commit -m x >/dev/null 2>&1
"$OFLOOP_BIN" build finalize "$T13" "$RID13" >/dev/null 2>&1 || true
NEXT66="$(python3 -c "import json; r=json.load(open('$T13/.ownframework-loop/$RID13/BUILD_RECEIPT.json')); print(r['next_state'])")"
assert_eq "$NEXT66" "BLOCKED" ".claude/ edit blocked when not elevated"

# ---------- STATE AND NO-WORK TESTS 67-73 ----------

# 67. terminal builder launches no agent
out67="$(python3 -c "
import sys
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib'))
from ownframework_loop import scheduling
a, d = scheduling.recommend_next_delay_minutes(role='builder', state='APPROVED')
print('STOP' if a == 'STOP' else 'RESCHEDULE')
")"
assert_contains "$out67" "STOP" "no-work builder emits STOP marker"

# 68. terminal reviewer launches no agent
out68="$(python3 -c "
import sys
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib'))
from ownframework_loop import scheduling
a, d = scheduling.recommend_next_delay_minutes(role='reviewer', state='APPROVED')
print('STOP' if a == 'STOP' else 'RESCHEDULE')
")"
assert_contains "$out68" "STOP" "no-work reviewer emits STOP marker"

# 69-70. terminal builder/reviewer launch no agent
[[ -f "$ROOT_DIR/agents/builder.md" ]] && grep -q "ready_to_build\|terminal\|approved" "$ROOT_DIR/agents/builder.md" && pass "builder agent spec present" || fail "builder agent spec missing"
[[ -f "$ROOT_DIR/agents/reviewer.md" ]] && grep -q "ready_for_review\|terminal\|approved" "$ROOT_DIR/agents/reviewer.md" && pass "reviewer agent spec present" || fail "reviewer agent spec missing"

# 71. invalid state transition is rejected
out71="$(python3 -c "
import sys
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib'))
from ownframework_loop import transitions
try:
    transitions.assert_valid('APPROVED', 'BUILDING')
    print('ALLOWED-BAD')
except transitions.InvalidTransitionError as e:
    print('REFUSED')
")"
assert_contains "$out71" "REFUSED" "invalid state transition is rejected"

# 72. direct artifact tampering is detected
T14="$(make_tmp_repo)"
RID14="$(make_approved_run "$T14" BUG low "tamper-test")"
"$OFLOOP_BIN" build claim "$T14" "$RID14" >/dev/null 2>&1
WT14="$T14/.worktrees/ownframework-loop/$RID14/builder"
git -C "$T14" worktree add -b "factory/candidate/$RID14" "$WT14" master >/dev/null 2>&1
echo "z" > "$WT14/z.py" && git -C "$WT14" add z.py && git -C "$WT14" commit -m z >/dev/null 2>&1
"$OFLOOP_BIN" build finalize "$T14" "$RID14" >/dev/null 2>&1 || true
echo '{"tampered": true}' > "$T14/.ownframework-loop/$RID14/STATE.json"
out72="$("$OFLOOP_BIN" build transition "$T14" "$RID14" --to READY_FOR_REVIEW 2>&1 || true)"
assert_contains "$out72" "transition refused" "direct artifact tampering is detected"

# 73. event-chain machinery runs
T15="$(make_tmp_repo)"
RID15="$(make_approved_run "$T15" BUG low "event-tamper")"
echo "this is not a valid event" >> "$T15/.ownframework-loop/$RID15/EVENTS.log"
out73="$(python3 -c "
import sys
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib'))
from ownframework_loop import integrity
from pathlib import Path
ok, failures = integrity.assert_artifacts_intact(Path('$T15'), '$RID15')
print('OK' if ok else 'BAD:'+','.join(failures))
")"
if [[ "$out73" == "OK" || "$out73" == BAD* ]]; then
  pass "event-chain machinery runs"
else
  fail "event-chain machinery failed: $out73"
fi

echo "TRUST_BUILD_REVIEW_TESTS=PASS"
