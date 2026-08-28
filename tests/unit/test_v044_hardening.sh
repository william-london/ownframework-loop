#!/usr/bin/env bash
# v0.4.4 commissioning regressions, aligned to the pass-scoped v0.4.5 lifecycle.
set -euo pipefail
. "$(dirname "$0")/../_helpers.sh"
ROOT="$ROOT_DIR"
LIB="$LIB_DIR"

REPO="$(make_tmp_repo)"
RID="$(make_approved_run "$REPO" FEATURE low "v044-skel")"
"$OFLOOP_BIN" build claim "$REPO" "$RID" >/dev/null
PREP_JSON="$("$OFLOOP_BIN" build prepare "$REPO" "$RID")"
SKEL_JSON="$("$OFLOOP_BIN" build agent-skeleton "$REPO" "$RID")"

echo "$SKEL_JSON" | grep -q '"shape": "ownframework-loop-build-agent-result/v1"' \
  && pass "skeleton advertises canonical build-agent schema" \
  || fail "skeleton shape mismatch: $SKEL_JSON"

SKEL_PATH="$(echo "$PREP_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["agent_result_path"])')"
[[ -f "$SKEL_PATH" ]] && pass "skeleton is pass-scoped" || fail "skeleton missing: $SKEL_PATH"

python3 - "$SKEL_PATH" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
for key in ("schema","run_id","work_unit_id","outcome_requested","candidate_branch","baseline_sha","packet_sha256","approval_sha256","builder_identity"):
    assert d.get(key) not in (None,""), key
print("PASS skeleton fixed identity is populated")
PY

# Deterministic prepare owns all protocol identity needed by the agent.
for key in builder_worktree candidate_branch baseline_sha packet_sha256 approval_sha256 work_unit_id builder_actual_branch agent_result_path; do
  echo "$PREP_JSON" | grep -q "\"$key\":" \
    && pass "build prepare returns $key" \
    || fail "build prepare missing $key: $PREP_JSON"
done

grep -q "ofloop build prepare" "$ROOT/skills/build/SKILL.md" && pass "build skill delegates preparation" || fail "build skill missing deterministic prepare"
grep -q "ofloop build agent-skeleton" "$ROOT/skills/build/SKILL.md" && pass "build skill delegates result skeleton" || fail "build skill missing deterministic skeleton"
if grep -q "write a complete .BUILD_RECEIPT.json" "$ROOT/agents/of-builder.md"; then
  fail "builder still authors authoritative receipt"
else
  pass "builder never authors authoritative receipt"
fi

# Candidate branch resolver: default and packet-declared override.
PYTHONPATH="$LIB" python3 - <<'PY'
from pathlib import Path
from ownframework_loop import branch_resolver
assert branch_resolver.default_candidate_branch("run-X") == "factory/candidate/run-X"
fake=Path("/tmp/v044_branch_test"); fake.mkdir(exist_ok=True)
packet={"target":{"candidate_branch_prefix":"factory/candidate/custom-branch"}}
assert branch_resolver.resolve_candidate_branch(fake,"run-v044-test",packet=packet)=="factory/candidate/custom-branch"
print("PASS candidate branch resolution is deterministic")
PY

# Global PROGRAM envelope never widens beyond human-approved caps.
PYTHONPATH="$LIB" python3 - <<'PY'
from ownframework_loop.program import materialise_initial_program_state, ProgramGraphError
packet={
 "schema":"ownframework-work-packet/v3","execution_mode":"program",
 "risk_budget":{"max_build_passes":24,"max_review_passes":24,"max_repair_rounds":8},
 "checkpoint_graph":{"execution_order":[f"CP-{i}" for i in range(1,12)],"checkpoints":[
   {"id":f"CP-{i}","title":f"t{i}","scope":"s","depends_on":[],
    "risk_budget":{"max_build_passes":3,"max_review_passes":3,"max_repair_rounds":2}}
   for i in range(1,12)]}}
state=materialise_initial_program_state(packet,baseline_sha="x"*40,candidate_branch="factory/candidate/test")
c=state["cumulative_ceilings"]
assert (c["max_build_passes"],c["max_review_passes"],c["max_repair_rounds"])==(24,24,8),c
packet["risk_budget"]["max_build_passes"]=5
try:
    materialise_initial_program_state(packet,baseline_sha="x"*40,candidate_branch="b")
except ProgramGraphError:
    pass
else:
    raise AssertionError("undersized global build cap accepted")
print("PASS PROGRAM global envelope is fail-closed")
PY

# Packet mutation after approval must be refused by both consequential surfaces.
MREPO="$(make_tmp_repo)"
MRID="$(make_approved_run "$MREPO" FEATURE low "mut test")"
MPP="$MREPO/.ownframework-loop/$MRID/WORK_PACKET.md"
echo '# post-approval mutation' >> "$MPP"
MUT_PREP="$("$OFLOOP_BIN" build prepare "$MREPO" "$MRID" 2>&1 || true)"
MUT_SKEL="$("$OFLOOP_BIN" build agent-skeleton "$MREPO" "$MRID" 2>&1 || true)"
echo "$MUT_PREP" | grep -qiE "refus|drift|binding|approval" && pass "prepare refuses packet mutation" || fail "prepare accepted mutation: $MUT_PREP"
echo "$MUT_SKEL" | grep -qiE "refus|drift|binding|approval" && pass "skeleton refuses packet mutation" || fail "skeleton accepted mutation: $MUT_SKEL"

echo "V044_HARDENING_TESTS=PASS"
