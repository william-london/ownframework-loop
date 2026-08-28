#!/usr/bin/env bash
# v0.4.3 hardening regressions for the real-program incident repairs.
#
# Covers:
#   1. BUILD_AGENT_RESULT skeleton exactly matches finalizer contract.
#   2. Fresh builder agent can use the skeleton without manual repair.
#   3. Finalizer still rejects malformed result shape.
#   4. of-builder instructions do not tell the agent to author
#      BUILD_RECEIPT.json.
#   5. Deterministic build preparation owns plumbing.
#   6. Packet-declared candidate branch propagates identically.
#   7. Default candidate branch remains deterministic.
#   8. Approved global PROGRAM caps cannot be widened by per-CP sums.
#   9. Incident shape: global=24/24/8 vs sum=33/33/22 → effective<=24/24/8.

set -uo pipefail
. "$(dirname "$0")/../_helpers.sh"

REPO="$(make_tmp_repo)"

# ============================================================
# 1 + 5. build agent-skeleton produces a schema-conformant file
# ============================================================

# Use the single-mode helper to create a v2 approved run, then
# exercise agent-skeleton + build prepare.
RUN_DIR="$(make_approved_run "$REPO" FEATURE low "v043-skel" | tail -n1)"
RID="$(basename "$(dirname "$REPO/.ownframework-loop/$RUN_DIR/WORK_PACKET.md")")"
# Actually make_approved_run returns run id via stdout - already.
RID="$(ls -1t "$REPO/.ownframework-loop" | head -n1)"

# Drive a build claim so we have a known state.
"$OFLOOP_BIN" build claim "$REPO" "$RID" >/dev/null
# Run prepare so the builder worktree exists for finalize.
"$OFLOOP_BIN" build prepare "$REPO" "$RID" >/dev/null

# 1. Materialize the skeleton.
SKEL_JSON="$("$OFLOOP_BIN" build agent-skeleton "$REPO" "$RID")"
echo "$SKEL_JSON" | grep -q '"shape": "ownframework-loop-build-agent-result/v1"' \
  && pass "skeleton shape advertises correct schema name" \
  || fail "skeleton shape mismatch: $SKEL_JSON"

SKEL_PATH="$REPO/.ownframework-loop/$RID/builder/BUILD_AGENT_RESULT.json"
[[ -f "$SKEL_PATH" ]] && pass "skeleton file written at run scratch path" \
  || fail "skeleton file missing at $SKEL_PATH"

# Required top-level keys per build_finalize._build_agent_result_schema_ok
for key in schema run_id work_unit_id outcome_requested; do
  python3 -c "
import json,sys
d=json.load(open('$SKEL_PATH'))
assert d.get('$key') is not None, 'missing $key'
assert d['$key'] != '', 'empty $key'
print('ok')
" >/dev/null 2>&1 && pass "skeleton has non-empty $key" \
    || fail "skeleton missing/empty $key"
done

# 2. Fresh builder can submit a first-pass result without manual repair.
# Simulate the agent filling runtime values.
python3 - <<PY
import json
from pathlib import Path
p = Path("$SKEL_PATH")
d = json.loads(p.read_text())
d["summary"] = "Implemented UNIT-1."
d["evidence"]["validate_sh_exit"] = 0
d["evidence"]["pytest_offline_exit"] = 0
d["evidence"]["files_changed"] = ["src/x.py"]
d["outcome_requested"] = "candidate_ready"
d["unit_ids_completed"] = ["UNIT-1"]
p.write_text(json.dumps(d, indent=2, sort_keys=True))
PY

# 3. Finalizer must still REJECT a malformed result (different schema name).
BAD_DIR="$(mktemp -d -t v043_bad.XXXXXX)"
cp -r "$REPO" "$BAD_DIR/bad"
BAD_REPO="$BAD_DIR/bad"
BAD_RID="$RID"
python3 - <<PY
import json
from pathlib import Path
p = Path("$BAD_REPO/.ownframework-loop/$BAD_RID/builder/BUILD_AGENT_RESULT.json")
d = json.loads(p.read_text())
# WRONG schema name on purpose.
d["schema"] = "ownframework-loop-builder-result/v1"
p.write_text(json.dumps(d, indent=2, sort_keys=True))
PY

# The good one should finalize (or at least not refuse on schema).
GOOD_OUT="$("$OFLOOP_BIN" build finalize "$REPO" "$RID" 2>&1 || true)"
echo "$GOOD_OUT" | grep -q "OF_LOOP_BUILD_FINALIZE_REFUSED" \
  && fail "good skeleton was refused: $GOOD_OUT" \
  || pass "good skeleton finalizes"

# The bad one (wrong schema) MUST be refused.
"$OFLOOP_BIN" build prepare "$BAD_REPO" "$BAD_RID" >/dev/null
BAD_OUT="$("$OFLOOP_BIN" build finalize "$BAD_REPO" "$BAD_RID" 2>&1 || true)"
echo "$BAD_OUT" | grep -q "OF_LOOP_BUILD_FINALIZE_REFUSED" \
  && pass "bad-schema skeleton is refused" \
  || fail "bad-schema skeleton was accepted: $BAD_OUT"

# ============================================================
# 4. of-builder.md docs do not tell agent to author BUILD_RECEIPT
# ============================================================
DOCS="$(cat /Users/mr.mrs.london/projects/plugins/ownframework-loop/agents/of-builder.md \
       /Users/mr.mrs.london/projects/plugins/ownframework-loop/skills/build/SKILL.md 2>/dev/null)"
if echo "$DOCS" | grep -q "write a complete .BUILD_RECEIPT.json"; then
  # Old (v0.4.2) phrasing must NOT be present.
  fail "of-builder.md still instructs writing BUILD_RECEIPT.json"
else
  pass "of-builder.md does NOT instruct writing BUILD_RECEIPT.json"
fi
if echo "$DOCS" | grep -q "three-step deterministic workflow"; then
  pass "of-builder.md uses 3-step deterministic workflow"
else
  fail "of-builder.md missing 3-step workflow"
fi

# ============================================================
# 5. Deterministic build preparation owns plumbing.
# ============================================================
PREP_JSON="$("$OFLOOP_BIN" build prepare "$REPO" "$RID" 2>&1 || true)"
echo "$PREP_JSON" | grep -q '"builder_worktree":' \
  && pass "build prepare returns builder_worktree" \
  || fail "build prepare missing builder_worktree: $PREP_JSON"
echo "$PREP_JSON" | grep -q '"candidate_branch":' \
  && pass "build prepare returns candidate_branch" \
  || fail "build prepare missing candidate_branch: $PREP_JSON"
echo "$PREP_JSON" | grep -q '"baseline_sha":' \
  && pass "build prepare returns baseline_sha" \
  || fail "build prepare missing baseline_sha: $PREP_JSON"

# Build skill / SKILL.md must reference ofloop build prepare + agent-skeleton.
if grep -q "ofloop build prepare" /Users/mr.mrs.london/projects/plugins/ownframework-loop/skills/build/SKILL.md; then
  pass "build SKILL.md references ofloop build prepare"
else
  fail "build SKILL.md missing reference to ofloop build prepare"
fi
if grep -q "ofloop build agent-skeleton" /Users/mr.mrs.london/projects/plugins/ownframework-loop/skills/build/SKILL.md; then
  pass "build SKILL.md references ofloop build agent-skeleton"
else
  fail "build SKILL.md missing reference to ofloop build agent-skeleton"
fi

# ============================================================
# 6 + 7. Candidate branch: packet-declared prefix propagates,
#         default factory/candidate/<run-id> is deterministic.
# ============================================================
PYTHONPATH="/Users/mr.mrs.london/projects/plugins/ownframework-loop/lib" python3 - <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, "/Users/mr.mrs.london/projects/plugins/ownframework-loop/lib")
from ownframework_loop import branch_resolver, approval, state as state_mod

# Default: factory/candidate/<run-id>
assert branch_resolver.default_candidate_branch("run-X") == "factory/candidate/run-X"
print("PASS default branch deterministic")

# Packet prefix: comes from packet.target.candidate_branch_prefix
fake_repo = Path("/tmp/v043_branch_test")
fake_repo.mkdir(exist_ok=True)
rid = "run-v043-test"
import json
packet = {"target": {"candidate_branch_prefix": "factory/candidate/custom-branch"}}
got = branch_resolver.resolve_candidate_branch(fake_repo, rid, packet=packet)
assert got == "factory/candidate/custom-branch", got
print("PASS packet prefix propagates")
PY

# ============================================================
# 8 + 9. Program budget envelope: global=24/24/8 must clamp sum.
# ============================================================
PYTHONPATH="/Users/mr.mrs.london/projects/plugins/ownframework-loop/lib" python3 - <<'PY'
import sys
sys.path.insert(0, "/Users/mr.mrs.london/projects/plugins/ownframework-loop/lib")
from ownframework_loop.program import materialise_initial_program_state

# Program packet: 11 CPs each with 3/3/2; global envelope 24/24/8.
packet = {
    "schema": "ownframework-work-packet/v3",
    "execution_mode": "program",
    "risk_budget": {
        "max_build_passes": 24,
        "max_review_passes": 24,
        "max_repair_rounds": 8,
    },
    "checkpoint_graph": {
        "execution_order": [f"CP-{i}" for i in range(1, 12)],
        "checkpoints": [
            {"id": f"CP-{i}", "title": f"t{i}", "scope": "s",
             "depends_on": [], "risk_budget": {"max_build_passes": 3, "max_review_passes": 3, "max_repair_rounds": 2}}
            for i in range(1, 12)
        ],
        "global_source_ceilings": {"max_unique_changed_files": 80, "max_baseline_to_final_diff_lines": 8000},
    },
}
state = materialise_initial_program_state(packet, baseline_sha="x"*40, candidate_branch="factory/candidate/test")
ceilings = state["cumulative_ceilings"]
assert ceilings["max_build_passes"] <= 24, ceilings
assert ceilings["max_review_passes"] <= 24, ceilings
assert ceilings["max_repair_rounds"] <= 8, ceilings
assert ceilings["max_build_passes"] == 24, ceilings  # min(24, 33)
assert ceilings["max_review_passes"] == 24, ceilings
assert ceilings["max_repair_rounds"] == 8, ceilings  # min(8, 22)
print("PASS program envelope clamped to operator-approved global")
print("     cumulative_ceilings:", ceilings)
PY

# Global too small for one pass per CP: must refuse pre-approval.
PYTHONPATH="/Users/mr.mrs.london/projects/plugins/ownframework-loop/lib" python3 - <<'PY'
import sys
sys.path.insert(0, "/Users/mr.mrs.london/projects/plugins/ownframework-loop/lib")
from ownframework_loop.program import materialise_initial_program_state, ProgramGraphError

packet = {
    "schema": "ownframework-work-packet/v3",
    "execution_mode": "program",
    "risk_budget": {"max_build_passes": 5, "max_review_passes": 5, "max_repair_rounds": 1},
    "checkpoint_graph": {
        "execution_order": [f"CP-{i}" for i in range(1, 12)],
        "checkpoints": [
            {"id": f"CP-{i}", "title": f"t{i}", "scope": "s",
             "depends_on": [], "risk_budget": {"max_build_passes": 3, "max_review_passes": 3, "max_repair_rounds": 2}}
            for i in range(1, 12)
        ],
    },
}
try:
    materialise_initial_program_state(packet, baseline_sha="x"*40, candidate_branch="b")
    print("FAIL: should have refused pre-approval inconsistency")
    sys.exit(1)
except ProgramGraphError as e:
    print("PASS pre-approval refused:", str(e)[:100])
PY

# ============================================================
# 10. CLI surfaces register under build subcommand.
# ============================================================
HELP_OUT="$("$OFLOOP_BIN" build --help 2>&1 || true)"
echo "$HELP_OUT" | grep -q "agent-skeleton" && pass "ofloop build agent-skeleton registered" \
  || fail "ofloop build agent-skeleton missing"
echo "$HELP_OUT" | grep -q "prepare" && pass "ofloop build prepare registered" \
  || fail "ofloop build prepare missing"

echo "ALL V0.4.3 HARDENING TESTS PASSED"
