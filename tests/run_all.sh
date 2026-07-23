#!/usr/bin/env bash
# OwnFramework Loop V1 — fixture and integration test runner.
#
# Runs every test_*.sh file under tests/ and reports PASS/FAIL counts.
# Each test exits 0 on PASS, non-zero on FAIL.

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
  "$HERE"/unit/test_*.sh
  "$HERE"/integration/test_*.sh
  "$HERE"/fixtures/test_*.sh
)

if [[ "${OFLOOP_FAST:-1}" == "1" ]]; then
  echo "=== OwnFramework Loop V1 — fast test run ==="
else
  echo "=== OwnFramework Loop V1 — full test run ==="
fi

for t in "${TESTS[@]}"; do
  [[ -e "$t" ]] || continue
  TOTAL=$((TOTAL+1))
  name="$(basename "$t")"
  echo
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
echo "TOTAL=$TOTAL"
echo "PASSED=$PASSED"
echo "FAILED=$FAILED"
if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
  echo "FAILED_NAMES=${FAILED_TESTS[*]}"
fi

if [[ "$FAILED" -gt 0 ]]; then
  exit 1
fi
exit 0
