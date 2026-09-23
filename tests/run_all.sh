#!/usr/bin/env bash
# OwnFramework Loop — release gate (single execution).
#
# This is the single, authoritative release gate. It runs every
# canonical test listed in tests/canonical.txt and reports PASS/FAIL
# counts. Each test exits 0 on PASS, non-zero on FAIL. A single failure
# here is a release blocker.
#
# v0.3.5 (A6-F12/A6-F13): tests are discovered from an explicit
# allow-list (tests/canonical.txt) rather than by glob.
#
# Final hardening: every canonical test runs in its own process group through
# Python's portable POSIX subprocess API. On timeout the entire group is
# terminated and reaped, so a test cannot leave a background descendant alive
# after the gate records it as timed out. The invocation is wrapped in an
# explicit if/else so `set -e` never short-circuits aggregate failure reporting.

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

echo "=== OwnFramework Loop — release gate ==="
echo "OF_LOOP_OPERATOR_MARKER"
echo "OF_LOOP_RELEASE_GATE=single"
OF_LOOP_PLUGIN_VERSION="$(PYTHONDONTWRITEBYTECODE=1 python3 -B -c "import sys; sys.path.insert(0, '$LIB_DIR'); from ownframework_loop import __version__; print(__version__)")"
echo "OF_LOOP_PLUGIN_VERSION=$OF_LOOP_PLUGIN_VERSION"
echo

run_test_bounded() {
  local test_path="$1"
  python3 - "$test_path" <<'PY'
import os
import signal
import subprocess
import sys

path = sys.argv[1]
proc = subprocess.Popen(["bash", path], start_new_session=True)
try:
    rc = proc.wait(timeout=180)
except subprocess.TimeoutExpired:
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()
    rc = 124
except BaseException:
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()
    raise
sys.exit(rc)
PY
}

while IFS= read -r rel; do
  [[ -z "$rel" || "$rel" == \#* ]] && continue
  full="$ROOT/$rel"
  [[ -e "$full" ]] || { echo "MISSING: $rel" >&2; FAILED_TESTS+=("$rel"); FAILED=$((FAILED+1)); TOTAL=$((TOTAL+1)); continue; }
  TOTAL=$((TOTAL+1))
  name="$(basename "$full")"
  echo "--- $name ---"
  if run_test_bounded "$full"; then
    rc=0
  else
    rc=$?
  fi
  if [[ $rc -eq 0 ]]; then
    PASSED=$((PASSED+1))
  else
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
