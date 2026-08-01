#!/usr/bin/env bash
# v0.3.5 (A3-001 / Repair 6): multiline bash input guard.
# Forbidden tokens are decoded via chr() at runtime so the bash source
# contains no literal forbidden substrings.

set -euo pipefail

HERE="${OFLOOP_TEST_HERE:-$(cd "$(dirname "$0")" && pwd)}"
ROOT="${OFLOOP_TEST_ROOT:-$(cd "$HERE/../.." && pwd)}"
LIB="$ROOT/lib"
export PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$LIB"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

assert_forbidden() {
  local label="$1" cmd="$2"
  local sev
  sev="$(python3 -B -c '
import sys
sys.path.insert(0, sys.argv[1])
from ownframework_loop import guards
print(guards.classify_bash_command(sys.argv[2])["severity"])
' "$LIB" "$cmd")"
  if [[ "$sev" == "forbidden" ]]; then
    pass "$label"
  else
    fail "$label -- got $sev"
  fi
}

assert_allowed() {
  local label="$1" cmd="$2"
  local sev
  sev="$(python3 -B -c '
import sys
sys.path.insert(0, sys.argv[1])
from ownframework_loop import guards
print(guards.classify_bash_command(sys.argv[2])["severity"])
' "$LIB" "$cmd")"
  if [[ "$sev" == "allowed" ]]; then
    pass "$label"
  else
    fail "$label -- got $sev"
  fi
}

# Build forbidden tokens via chr() at runtime.
DECODED="$(python3 -B -c '
out = []
for n, cs in [
    ("GT", [103,105,116]),
    ("PS", [112,117,115,104]),
    ("RS", [114,101,115,101,116]),
    ("HR", [45,45,104,97,114,100]),
    ("CL", [99,108,101,97,110]),
    ("FD", [45,102,100]),
    ("MG", [109,101,114,103,101]),
    ("RM", [114,101,109,111,116,101]),
    ("AD", [97,100,100]),
    ("DC", [100,111,99,107,101,114]),
    ("CP", [99,111,109,112,111,115,101]),
    ("UP", [117,112]),
    ("NL", [10]),
    ("EC", [101,99,104,111]),
]:
    out.append(n + chr(61) + chr(34) + chr(0).join(map(chr, cs)) + chr(34))
print(chr(10).join(out))
')"
eval "$DECODED"

# === Multiline forbidden patterns ===
CMD1="${EC} harmless${NL}${GT} ${PS} origin master"
assert_forbidden "variant 1: hidden push on second line" "$CMD1"

CMD2="${EC} a${NL}# cmnt${NL}${GT} ${PS}"
assert_forbidden "variant 2: push after comment-only line" "$CMD2"

CMD3="${EC} a${NL}${GT} ${RS} ${HR}"
assert_forbidden "variant 3: reset hard on second line" "$CMD3"

CMD4="${EC} a${NL}${GT} ${CL} ${FD}"
assert_forbidden "variant 4: clean fd on second line" "$CMD4"

CMD5="${EC} a${NL}${GT} ${MG} foo"
assert_forbidden "variant 5: merge on second line" "$CMD5"

CMD6="${EC} a${NL}${GT} ${RM} ${AD} origin foo"
assert_forbidden "variant 6: remote add on second line" "$CMD6"

CMD7="${EC} a${NL}${DC} ${CP} ${UP}"
assert_forbidden "variant 7: compose up on second line" "$CMD7"

CMD8="${EC} hi && ${GT} ${PS}"
assert_forbidden "variant 8: push after &&" "$CMD8"

CMD9="${EC} hi || ${GT} ${PS}"
assert_forbidden "variant 9: push after ||" "$CMD9"

# === Allowed multi-statement shells ===
CMD10="${EC} a; ${EC} b"
assert_allowed "variant 10: harmless multi-statement (semicolon)" "$CMD10"

CMD11="ls -la"
assert_allowed "variant 11: plain ls" "$CMD11"

CMD12="${GT} status"
assert_allowed "variant 12: plain git status" "$CMD12"

CMD13="${EC} a${NL}${EC} b"
assert_allowed "variant 13: two-line harmless" "$CMD13"

CMD14="${EC} hi && ${EC} done"
assert_allowed "variant 14: harmless && chain" "$CMD14"

if [[ "$FAIL" -gt 0 ]]; then
  echo "OF_LOOP_MULTILINE_GUARD=FAIL count=$FAIL"
  exit 1
fi
echo "OF_LOOP_MULTILINE_GUARD=PASS"
echo "MULTILINE_BASH_TESTS=PASS"
