#!/usr/bin/env bash
# v0.5 compatibility regressions. Current high-pressure concurrency/recovery
# coverage lives in tests/integration/test_v054_execution_start.sh.
set -euo pipefail
. "$(dirname "$0")/../_helpers.sh"

ROOT="$ROOT_DIR"
OFLOOP="$OFLOOP_BIN"

# 1. Fresh unsealed run auto-seals at first legitimate build claim.
T="$(make_tmp_repo)"
RID="$(make_approved_run_unapproved "$T" FEATURE low "v050-auto-seal")"
[[ ! -e "$T/.ownframework-loop/$RID/APPROVAL.json" ]] || fail "fresh run unexpectedly pre-sealed"
OUT="$($OFLOOP build claim "$T" "$RID" --actor builder)"
assert_file_exists "$T/.ownframework-loop/$RID/APPROVAL.json" "first build claim creates execution seal"
assert_eq "$(jq -r '.approval_method' "$T/.ownframework-loop/$RID/APPROVAL.json")" "build_start" "normal binding method is build_start"
assert_eq "$(jq -r '.binding_kind' "$T/.ownframework-loop/$RID/APPROVAL.json")" "execution_seal" "normal binding kind is execution_seal"
assert_eq "$(jq -r '.build_pass_count' "$T/.ownframework-loop/$RID/STATE.json")" "1" "first claim consumes one pass"
assert_contains "$OUT" '"replayed": false' "first claim is fresh"

# 2. Seal binds exact packet SHA, full baseline SHA, and candidate branch.
python3 - "$T" "$RID" <<'PY'
import hashlib, json, subprocess, sys
from pathlib import Path
repo=Path(sys.argv[1]); rid=sys.argv[2]
run=repo/'.ownframework-loop'/rid
seal=json.load(open(run/'APPROVAL.json'))
packet=run/'WORK_PACKET.md'
assert seal['packet_sha256']==hashlib.sha256(packet.read_bytes()).hexdigest()
head=subprocess.run(['git','-C',str(repo),'rev-parse','HEAD'],capture_output=True,text=True,check=True).stdout.strip()
assert seal['baseline_sha']==head and len(head)==40
assert seal['candidate_branch']==f'factory/candidate/{rid}'
print('PASS exact packet/baseline/candidate binding')
PY

# 3. Post-seal packet mutation refuses and seal bytes are unchanged.
SEAL_HASH_BEFORE="$(python3 - "$T/.ownframework-loop/$RID/APPROVAL.json" <<'PY'
import hashlib,sys
print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())
PY
)"
echo '# mutation' >> "$T/.ownframework-loop/$RID/WORK_PACKET.md"
set +e
MUT_OUT="$($OFLOOP build claim "$T" "$RID" 2>&1)"; MUT_RC=$?
set -e
[[ "$MUT_RC" -ne 0 ]] || fail "post-seal packet mutation unexpectedly accepted"
echo "$MUT_OUT" | grep -qiE 'drift|invalid|refus' || fail "packet mutation refusal reason missing"
SEAL_HASH_AFTER="$(python3 - "$T/.ownframework-loop/$RID/APPROVAL.json" <<'PY'
import hashlib,sys
print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())
PY
)"
assert_eq "$SEAL_HASH_AFTER" "$SEAL_HASH_BEFORE" "packet drift does not rewrite seal"

# 4. Tracked/staged dirty canonical source refuses before seal creation.
T2="$(make_tmp_repo)"
RID2="$(make_approved_run_unapproved "$T2" BUG low "v050-dirty")"
echo dirty > "$T2/dirty.txt"
git -C "$T2" add dirty.txt
set +e
DIRTY_OUT="$($OFLOOP build claim "$T2" "$RID2" 2>&1)"; DIRTY_RC=$?
set -e
[[ "$DIRTY_RC" -ne 0 ]] || fail "dirty source unexpectedly sealed"
echo "$DIRTY_OUT" | grep -qiE 'dirty|tracked|staged|refus' || fail "dirty-source refusal reason missing"
[[ ! -e "$T2/.ownframework-loop/$RID2/APPROVAL.json" ]] || fail "failed dirty start wrote seal"
pass "dirty source refuses before seal"

# 5. Malformed existing seal is preserved byte-for-byte and refuses overwrite.
T3="$(make_tmp_repo)"
RID3="$(make_approved_run_unapproved "$T3" BUG low "v050-malformed")"
BAD="$T3/.ownframework-loop/$RID3/APPROVAL.json"
printf '{not-json\n' > "$BAD"
BAD_HASH_BEFORE="$(python3 - "$BAD" <<'PY'
import hashlib,sys
print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())
PY
)"
set +e
BAD_OUT="$($OFLOOP build claim "$T3" "$RID3" 2>&1)"; BAD_RC=$?
set -e
[[ "$BAD_RC" -ne 0 ]] || fail "malformed seal unexpectedly accepted"
echo "$BAD_OUT" | grep -qiE 'malformed|invalid|refus' || fail "malformed seal refusal reason missing"
BAD_HASH_AFTER="$(python3 - "$BAD" <<'PY'
import hashlib,sys
print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())
PY
)"
assert_eq "$BAD_HASH_AFTER" "$BAD_HASH_BEFORE" "malformed seal evidence preserved"

# 6. V3 PROGRAM graph materializes automatically at first build start.
T4="$(make_tmp_repo)"
RID4="$($OFLOOP spec new "$T4" 'v050-program' | jq -r '.run_id')"
PP="$T4/.ownframework-loop/$RID4/WORK_PACKET.md"
python3 - "$PP" "$T4" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); repo=sys.argv[2]
packet={
 'schema':'ownframework-work-packet/v3','packet_id':'v050-program','created_at':'2026-08-28T00:00:00Z',
 'work_class':'FEATURE','risk_class':'low','title':'program','target':{'repo':repo,'branch':'master','classification':'local_only'},
 'execution_mode':'program','checkpoint_graph':{'execution_order':['CP-1'],'checkpoints':[{
   'id':'CP-1','title':'one','scope':'one','depends_on':[],
   'risk_budget':{'max_build_passes':2,'max_review_passes':2,'max_repair_rounds':1}}]},
 'promotion_policy':'human_gate','acceptance_criteria':[{'id':'AC-1','text':'ok'}],'non_goals':[],
 'allowed_paths':['src/'],'protected_paths':['.ownframework-loop/'],'work_units':[{'id':'UNIT-1','title':'u','scope':'s'}],
 'merge_authority':'human_only','deploy_authority':'human_only','push_authority':'human_only','external_action_authority':'none',
 'risk_budget':{'max_build_passes':2,'max_review_passes':2,'max_repair_rounds':1,'max_files_changed':25,'max_diff_lines':1000}}
p.write_text('```json\n'+json.dumps(packet,sort_keys=True)+'\n```\n')
PY
$OFLOOP build claim "$T4" "$RID4" >/dev/null
python3 - "$T4" "$RID4" <<'PY'
import json,sys
from pathlib import Path
s=json.load(open(Path(sys.argv[1])/'.ownframework-loop'/sys.argv[2]/'STATE.json'))
assert s['schema']=='ownframework-loop-state/v2',s
assert s['state']=='BUILDING',s
assert s['program']['current_checkpoints']==['CP-1'],s['program']
assert s['program']['cumulative_counters']['build_pass_count']==1,s['program']
print('PASS PROGRAM auto-materializes and claims CP-1')
PY

# 7. Historical TTY binding remains valid compatibility input.
T5="$(make_tmp_repo)"
RID5="$(make_legacy_tty_approved_run "$T5" BUG low "v050-legacy")"
LEGACY_OUT="$($OFLOOP build claim "$T5" "$RID5" --actor builder)"
assert_contains "$LEGACY_OUT" '"ok": true' "legacy tty_confirmation binding remains readable"

# 8. Current active skill semantics are direct-start/no-ceremony.
grep -Fq 'AWAITING_APPROVAL / READY_TO_START | STARTABLE' "$ROOT/skills/build/SKILL.md" || fail "build skill does not expose READY_TO_START"
grep -Fq '/loop /of-loop:build <run-id>' "$ROOT/skills/spec/SKILL.md" || fail "spec skill missing builder handoff"
grep -Fq '/loop /of-loop:review <run-id>' "$ROOT/skills/spec/SKILL.md" || fail "spec skill missing reviewer handoff"
grep -Fq 'AWAITING_APPROVAL / READY_TO_START | WAIT' "$ROOT/skills/review/SKILL.md" || fail "review skill does not wait before first start"
pass "active skills expose direct start semantics"

# 9. External-action guard machinery remains present.
[[ -f "$LIB_DIR/ownframework_loop/guards.py" ]] || fail "guards.py missing"
grep -q 're.compile' "$LIB_DIR/ownframework_loop/guards.py" || fail "guard matcher machinery missing"
pass "external-action guard machinery preserved"

echo 'V050_HARDENING_TESTS=PASS'
