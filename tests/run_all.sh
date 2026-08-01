#!/usr/bin/env bash
# OwnFramework Loop V2 — release gate (single execution).
#
# This is the single, authoritative release gate. It runs every
# canonical test listed in tests/canonical.txt and reports PASS/FAIL
# counts. Each test exits 0 on PASS, non-zero on FAIL. A single failure
# here is a release blocker.
#
# v0.3.5 (A6-F12/A6-F13): tests are discovered from an explicit
# allow-list (tests/canonical.txt) rather than by glob, and each test
# is wrapped in `timeout 180 bash` so a hung test cannot block the
# gate indefinitely.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB_DIR="$ROOT/lib"
CANONICAL_LIST="$HERE/canonical.txt"

export OFLOOP_LIB="$LIB_DIR"
export PYTHONPATH="$LIB_DIR${PYTHONPATH:+:$PYTHONPATH}"
export OFLOOP_ROOT="$ROOT"

TOTAL=0
PASSED=0
FAILED=0
FAILED_TESTS=()

if [[ ! -f "$CANONICAL_LIST" ]]; then
  echo "OF_LOOP_RELEASE_GATE=FAIL: canonical.txt missing at $CANONICAL_LIST" >&2
  exit 1
fi

echo "=== OwnFramework Loop V2 — release gate ==="
echo "OF_LOOP_OPERATOR_MARKER"
echo "OF_LOOP_RELEASE_GATE=single"
OF_LOOP_PLUGIN_VERSION="$(PYTHONDONTWRITEBYTECODE=1 python3 -B -c "import sys; sys.path.insert(0, '$LIB_DIR'); from ownframework_loop import __version__; print(__version__)")"
echo "OF_LOOP_PLUGIN_VERSION=$OF_LOOP_PLUGIN_VERSION"
echo

while IFS= read -r rel; do
  [[ -z "$rel" || "$rel" == \#* ]] && continue
  full="$ROOT/$rel"
  [[ -e "$full" ]] || { echo "MISSING: $rel" >&2; FAILED_TESTS+=("$rel"); FAILED=$((FAILED+1)); TOTAL=$((TOTAL+1)); continue; }
  TOTAL=$((TOTAL+1))
  name="$(basename "$full")"
  echo "--- $name ---"
  if timeout 180 bash "$full"; then
    PASSED=$((PASSED+1))
  else
    rc=$?
    FAILED=$((FAILED+1))
    FAILED_TESTS+=("$name (rc=$rc)")
  fi
done < "$CANONICAL_LIST"

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
