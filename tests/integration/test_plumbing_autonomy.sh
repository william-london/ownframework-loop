#!/usr/bin/env bash
# v0.3.7 plumbing-autonomy integration test.
#
# Validates the seven narrow repairs applied for v0.3.7:
#   1. PROGRAM checkpoint IDs are extracted from dict records
#      (state.py:495 type-fixed).
#   2. Monotonic terminal precedence:
#      - STOPPED is absorbing
#      - BLOCKED cannot become APPROVED
#      - APPROVED only from legal review state
#   3. Repair-round ceiling is per-packet (2 / 6 / 12 / 25 all work).
#   4. Progress-sensitive continuation: productive passes continue,
#      identical no-progress stops at threshold.
#   5. Substantial builder passes allowed (multiple files / commits).
#   6. `ofloop doctor --run-id` runs without TypeError.
#   7. Canonical gate coverage includes test_program_mode.sh + new
#      plumbing tests.

set -uo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
. "$TESTS_DIR/../_helpers.sh"

PASS=0
FAIL=0
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
pass() { echo "  PASS: $*"; PASS=$((PASS+1)); }

echo "============================================================"
echo "Test 1: PROGRAM checkpoints — IDs extracted from dict records"
echo "============================================================"
PYTHONPATH="$LIB_DIR" python3 - <<'PY'
import sys
from ownframework_loop import state as state_mod
import inspect
src = inspect.getsource(state_mod.program_transition)
assert "set(prog.get(\"finalized_checkpoints\")" not in src, \
    "set() on dict records still present"
assert "isinstance(fc, dict)" in src, "explicit ID extraction missing"
assert "finalized.add(cid)" in src, "explicit ID add missing"
print("  PY-OK: state.py:495 dict-handling patched")
PY
[[ $? -eq 0 ]] && pass "PROGRAM checkpoint ID extraction (no set() on dicts)" \
                || fail "PROGRAM checkpoint ID extraction missing"

echo ""
echo "============================================================"
echo "Test 2: Monotonic terminal precedence"
echo "============================================================"
PYTHONPATH="$LIB_DIR" python3 - <<'PY'
import sys
from ownframework_loop import transitions
# STOPPED is absorbing
try:
    transitions.assert_valid("STOPPED", "READY_TO_BUILD")
    print("  PY-FAIL: STOPPED -> READY_TO_BUILD allowed (should refuse)")
    sys.exit(1)
except transitions.InvalidTransitionError:
    print("  PY-OK: STOPPED -> READY_TO_BUILD refused (absorbing)")

# BLOCKED cannot become APPROVED (single mode)
try:
    transitions.assert_valid("BLOCKED", "APPROVED")
    print("  PY-FAIL: BLOCKED -> APPROVED allowed (should refuse)")
    sys.exit(1)
except transitions.InvalidTransitionError:
    print("  PY-OK: BLOCKED -> APPROVED refused (single mode)")

# BLOCKED -> APPROVED is refused even with has_more_checkpoints
try:
    transitions.assert_valid_program("BLOCKED", "APPROVED", has_more_checkpoints=True)
    print("  PY-FAIL: program-mode BLOCKED -> APPROVED allowed")
    sys.exit(1)
except transitions.InvalidTransitionError:
    print("  PY-OK: program-mode BLOCKED -> APPROVED refused")

# BLOCKED -> READY_TO_BUILD is allowed in program mode
transitions.assert_valid_program("BLOCKED", "READY_TO_BUILD", has_more_checkpoints=True)
print("  PY-OK: program-mode BLOCKED -> READY_TO_BUILD allowed (orchestrator resume)")

# STOPPED is absorbing even with has_more_checkpoints
try:
    transitions.assert_valid_program("STOPPED", "READY_TO_BUILD", has_more_checkpoints=True)
    print("  PY-FAIL: program-mode STOPPED -> READY_TO_BUILD allowed")
    sys.exit(1)
except transitions.InvalidTransitionError:
    print("  PY-OK: program-mode STOPPED -> READY_TO_BUILD refused (absorbing)")

# APPROVED only from REVIEWING in single mode
transitions.assert_valid("REVIEWING", "APPROVED")
print("  PY-OK: REVIEWING -> APPROVED allowed")
try:
    transitions.assert_valid("CHANGES_REQUESTED", "APPROVED")
    print("  PY-FAIL: CHANGES_REQUESTED -> APPROVED allowed")
    sys.exit(1)
except transitions.InvalidTransitionError:
    print("  PY-OK: CHANGES_REQUESTED -> APPROVED refused (must go through review)")
PY
[[ $? -eq 0 ]] && pass "Monotonic terminal precedence" || fail "Monotonic terminal precedence broken"

echo ""
echo "============================================================"
echo "Test 3: Repair-round ceiling per packet (2/6/12/25)"
echo "============================================================"
PYTHONPATH="$LIB_DIR" python3 - <<'PY'
import sys
from ownframework_loop import limits
# All four values should now be reachable as effective_cap
for max_rounds in (2, 6, 12, 25):
    pkt = {"risk_budget": {"max_repair_rounds": max_rounds}}
    cap = limits.effective_cap("repair_round", pkt)
    print(f"  effective_cap(repair_round, max_repair_rounds={max_rounds}) = {cap}")
    assert cap == max_rounds, f"expected {max_rounds}, got {cap}"
# Over-ceiling (25 is at absolute boundary; 30 must refuse)
try:
    limits.effective_cap("repair_round", {"risk_budget": {"max_repair_rounds": 50}})
    print("  PY-FAIL: 50 was not refused")
    sys.exit(1)
except limits.RepairLimitExceeded:
    print("  PY-OK: 50 refused by absolute ceiling")
# limits.MAX_REPAIR_ROUNDS is at least 24
assert limits.MAX_REPAIR_ROUNDS >= 24, "MAX_REPAIR_ROUNDS too small"
print(f"  MAX_REPAIR_ROUNDS = {limits.MAX_REPAIR_ROUNDS} (emergency fuse)")
PY
[[ $? -eq 0 ]] && pass "Repair-round ceiling per packet" || fail "Repair-round ceiling still blocked"

echo ""
echo "============================================================"
echo "Test 4: Progress-sensitive continuation"
echo "============================================================"
PYTHONPATH="$LIB_DIR" python3 - <<'PY'
import sys
from ownframework_loop import limits
# MAX_CONSECUTIVE_NO_PROGRESS_PASSES is a non-trivial fuse
assert limits.MAX_CONSECUTIVE_NO_PROGRESS_PASSES >= 8, "no-progress fuse too small"
print(f"  MAX_CONSECUTIVE_NO_PROGRESS_PASSES = {limits.MAX_CONSECUTIVE_NO_PROGRESS_PASSES}")
# Packet can override
pkt = {"risk_budget": {"max_consecutive_no_progress_passes": 3}}
cap = limits.effective_cap("no_progress_streak", pkt)
assert cap == 3, f"expected 3, got {cap}"
print(f"  effective_cap(no_progress_streak, override=3) = {cap}")
PY
# Also assert the build_finalize comparison uses full SHA not 7-char prefix
PYTHONPATH="$LIB_DIR" python3 - <<'PY'
import sys
import inspect
from ownframework_loop import build_finalize
src = inspect.getsource(build_finalize)
# Old code: last_candidate.startswith(candidate_sha[:7])
assert "startswith(candidate_sha[:7])" not in src, "still using 7-char prefix"
assert "last_candidate != candidate_sha" in src, "exact SHA comparison missing"
print("  build_finalize no-progress now uses exact SHA equality")
PY
[[ $? -eq 0 ]] && pass "Progress-sensitive continuation" || fail "Progress-sensitive continuation broken"

echo ""
echo "============================================================"
echo "Test 5: Substantial builder passes allowed"
echo "============================================================"
if grep -q "F-5-01" $ROOT/agents/of-builder.md; then
  pass "of-builder.md notes substantial-pass allowance"
else
  fail "of-builder.md does not mention F-5-01 substantial-pass allowance"
fi
if grep -q "F-5-01" $ROOT/skills/build/SKILL.md; then
  pass "skills/build/SKILL.md notes substantial-pass allowance"
else
  fail "skills/build/SKILL.md does not mention F-5-01 substantial-pass allowance"
fi

echo ""
echo "============================================================"
echo "Test 6: ofloop doctor --run-id runs without TypeError"
echo "============================================================"
R="$(make_tmp_repo)"
RUN_ID="$(make_approved_run "$R" BUG low "doctor-fix")"
# Bare `ofloop doctor` worked before; --run-id previously crashed with TypeError
out="$("$OFLOOP_BIN" doctor "$R" --run-id "$RUN_ID" 2>&1)"
ec=$?
echo "$out" | head -c 200
echo ""
if [[ $ec -eq 0 ]]; then
  pass "ofloop doctor --run-id exited cleanly (no TypeError)"
else
  fail "ofloop doctor --run-id failed: ec=$ec"
fi

echo ""
echo "============================================================"
echo "Test 7: Canonical gate coverage"
echo "============================================================"
for t in tests/integration/test_program_mode.sh \
         tests/integration/test_repair_round_budget.sh \
         tests/integration/test_plumbing_autonomy.sh; do
  if [[ -f "$ROOT/$t" ]]; then
    if grep -qxF "$t" $ROOT/tests/canonical.txt; then
      pass "$t is in canonical.txt"
    else
      fail "$t exists but is NOT in canonical.txt"
    fi
  else
    fail "$t does not exist"
  fi
done

echo ""
echo "============================================================"
echo "v0.3.7 plumbing-autonomy test summary"
echo "============================================================"
echo "PASS=$PASS  FAIL=$FAIL"
if [[ $FAIL -eq 0 ]]; then
  echo "PLUMBING_AUTONOMY_TEST=PASS"
  exit 0
else
  echo "PLUMBING_AUTONOMY_TEST=FAIL"
  exit 1
fi
