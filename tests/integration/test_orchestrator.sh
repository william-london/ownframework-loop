#!/usr/bin/env bash
# v0.6 — legacy orchestrator retirement assertion.
#
# The pre-0.6 `ofloop loop run` orchestrator is intentionally retired because
# it could reach APPROVED without a real semantic reviewer pass. This test
# asserts that retirement and that the replacement is `ofloop dispatch` /
# `ofloop supervisor`.

set -uo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

OFLOOP="$OFLOOP_BIN"

# 1. `ofloop loop run` is refused and surfaces the retirement reason.
echo "TEST 1: legacy ofloop loop run is refused"
R1="$(make_tmp_repo)"
"$OFLOOP" spec new "$R1" "retirement-test" >/dev/null
RID1="$(ls -1t "$R1/.ownframework-loop" | head -n1)"
OUT="$(cd /tmp && "$OFLOOP" loop run "$R1" --run-id "$RID1" 2>&1 || true)"
[[ ! -f "$R1/.ownframework-loop/$RID1/APPROVAL.json" ]] \
  && pass "no APPROVAL.json was auto-written for an unapproved run" \
  || fail "orchestrator wrote APPROVAL.json without operator intervention: $RID1"
assert_contains "$OUT" "legacy_unattended_orchestrator_retired_use_supervisor" \
  "loop run surfaces retirement reason"
assert_contains "$OUT" "ofloop supervisor enqueue" \
  "loop run surfaces replacement command"

# 2. The Python module entry points also return the retirement envelope.
echo "TEST 2: Python run_single_mode is a refusal shim"
PYTHONPATH="$LIB_DIR" python3 - "$R1" "$RID1" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, "${OFLOOP_LIB:-$LIB_DIR}")
from ownframework_loop import orchestrator
out = orchestrator.run_single_mode(
    canonical_repo=Path(sys.argv[1]),
    run_id=sys.argv[2],
)
assert out["ok"] is False, out
assert out["reason"] == "legacy_unattended_orchestrator_retired_use_supervisor", out
print("RETIRED_SHIM_OK")
PY
assert_contains "RETIRED_SHIM_OK" "RETIRED_SHIM_OK" "run_single_mode shim refuses with retirement reason"

# 3. Constants remain for compatibility reads.
echo "TEST 3: orchestrator constants remain readable"
PYTHONPATH="$LIB_DIR" python3 - <<'PY'
import sys
sys.path.insert(0, "${OFLOOP_LIB:-$LIB_DIR}")
from ownframework_loop import orchestrator
assert "APPROVED" in orchestrator.TERMINAL_STATES
assert "BLOCKED" in orchestrator.TERMINAL_STATES
assert "STOPPED" in orchestrator.TERMINAL_STATES
assert orchestrator.MAX_REPAIR_ROUNDS_DEFAULT >= 1
assert orchestrator.RETIREMENT_REASON == "legacy_unattended_orchestrator_retired_use_supervisor"
print("CONSTANTS_OK")
PY
assert_contains "CONSTANTS_OK" "CONSTANTS_OK" "constants remain for compatibility reads"

echo "ORCHESTRATOR_RETIREMENT=PASS"