#!/usr/bin/env bash
# OwnFramework Loop V2 — release gate (single execution).
#
# This is the single, authoritative release gate. It runs every
# test_*.sh file under tests/ and reports PASS/FAIL counts. Each test
# exits 0 on PASS, non-zero on FAIL. A single failure here is a release
# blocker.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB_DIR="$ROOT/lib"

export OFLOOP_LIB="$LIB_DIR"
export PYTHONPATH="$LIB_DIR${PYTHONPATH:+:$PYTHONPATH}"
export OFLOOP_ROOT="$ROOT"

TOTAL=0
PASSED=0
FAILED=0
FAILED_TESTS=()

# Discover tests.
shopt -s nullglob
TESTS=(
  "$HERE"/unit/test_trust_*.sh
  "$HERE"/unit/test_*.sh
  "$HERE"/integration/test_*.sh
  "$HERE"/smoke/smoke.sh
  "$HERE"/fixtures/test_*.sh
)

echo "=== OwnFramework Loop V2 — release gate ==="
echo "OF_LOOP_OPERATOR_MARKER"
echo "OF_LOOP_RELEASE_GATE=single"
OF_LOOP_PLUGIN_VERSION="$(PYTHONDONTWRITEBYTECODE=1 python3 -B -c "import sys; sys.path.insert(0, '$LIB_DIR'); from ownframework_loop import __version__; print(__version__)")"
echo "OF_LOOP_PLUGIN_VERSION=$OF_LOOP_PLUGIN_VERSION"
echo

for t in "${TESTS[@]}"; do
  [[ -e "$t" ]] || continue
  TOTAL=$((TOTAL+1))
  name="$(basename "$t")"
  echo "--- $name ---"
  if bash "$t"; then
    PASSED=$((PASSED+1))
  else
    FAILED=$((FAILED+1))
    FAILED_TESTS+=("$name")
  fi
done

echo
echo "=== RESULTS ==="
echo "OF_LOOP_TOTAL=$TOTAL"
echo "OF_LOOP_PASSED=$PASSED"
echo "OF_LOOP_FAILED=$FAILED"
if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
  echo "OF_LOOP_FAILED_NAMES=${FAILED_TESTS[*]}"
fi

if [[ "$FAILED" -gt 0 ]]; then
  echo "OF_LOOP_RELEASE_GATE_RESULT=BLOCKED"
  exit 1
fi
echo "OF_LOOP_RELEASE_GATE_RESULT=PASS"
exit 0

