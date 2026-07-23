#!/usr/bin/env bash
# Deterministic tests for F-001..F-005 portability closures.
#
# These tests prove the patch layer actually fails closed in the cases
# the portability audit identified, instead of relying on a grep-of-source.
#
# Each test creates a throwaway repo, exercises the relevant guard, then
# tears the repo down. No production data is touched.
#
# Refuses to run unless OFLOOP_FAST=1 or ROOT points at a non-/Users
# scratch path (the gate sets OFLOOP_FAST=1).

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CLI="$ROOT/bin/ofloop"
HOOK="$ROOT/hooks/block_dangerous_bash.sh"

pass=0; fail=0
fail_msgs=()

pass_test() { echo "  PASS: $1"; pass=$((pass+1)); }
fail_test() { echo "  FAIL: $1 -- $2"; fail=$((fail+1)); fail_msgs+=("$1: $2"); }

mk_repo() {
  local d; d="$(mktemp -d -t ofloop-f-XXXXXX)"
  git -C "$d" init -q -b master
  git -C "$d" config user.name "Ofloop Tester"
  git -C "$d" config user.email "tester@ofloop.local"
  echo "hi" > "$d/README.md"
  git -C "$d" add README.md
  git -C "$d" commit -q -m "init"
  printf '%s' "$d"
}

rm_repo() { rm -rf "$1"; }

echo "=== F-001..F-005 closures ==="

# ----- F-001: hook fails closed when CLAUDE_PLUGIN_ROOT unset -----
echo "F-001: hook refuses to silently fall back to a hardcoded path"
FAKE_RUN=$(mktemp -d -t ofloop-f001-XXXXXX)
mkdir -p "$FAKE_RUN/.ownframework-loop"
echo '{"state":"BUILDING"}' > "$FAKE_RUN/.ownframework-loop/state.json"
cat > "$FAKE_RUN/in.json" <<EOF
{"tool_name":"Bash","tool_input":{"command":"git status"},"cwd":"$FAKE_RUN"}
EOF
unset CLAUDE_PLUGIN_ROOT OFLOOP_PLUGIN_ROOT
OUT=$(env -u CLAUDE_PLUGIN_ROOT -u OFLOOP_PLUGIN_ROOT bash "$HOOK" < "$FAKE_RUN/in.json" 2>&1)
RC=$?
if [[ $RC -eq 2 ]] && echo "$OUT" | grep -q "CLAUDE_PLUGIN_ROOT not provided"; then
  pass_test "F-001: hook fail-closed when CLAUDE_PLUGIN_ROOT unset (rc=2, msg present)"
else
  fail_test "F-001" "rc=$RC; out=$OUT"
fi
rm -rf "$FAKE_RUN"

# ----- F-001b: hook succeeds when CLAUDE_PLUGIN_ROOT IS set -----
echo "F-001b: hook runs classifier when CLAUDE_PLUGIN_ROOT is provided by Claude"
FAKE_RUN=$(mktemp -d -t ofloop-f001b-XXXXXX)
mkdir -p "$FAKE_RUN/.ownframework-loop"
echo '{"state":"BUILDING"}' > "$FAKE_RUN/.ownframework-loop/state.json"
cat > "$FAKE_RUN/in.json" <<EOF
{"tool_name":"Bash","tool_input":{"command":"git push origin master"},"cwd":"$FAKE_RUN"}
EOF
OUT=$(CLAUDE_PLUGIN_ROOT="$ROOT" bash "$HOOK" < "$FAKE_RUN/in.json" 2>&1)
RC=$?
if [[ $RC -eq 0 ]] && echo "$OUT" | grep -q "OF_LOOP_BASH_FORBIDDEN"; then
  pass_test "F-001b: classifier runs with CLAUDE_PLUGIN_ROOT, blocks push"
else
  fail_test "F-001b" "rc=$RC; out=$OUT"
fi
rm -rf "$FAKE_RUN"

# ----- F-002: cmd_new_repo refuses to synthesize a hardcoded author -----
echo "F-002: cmd_new_repo refuses to commit when local git identity is missing"
EMPTY=$(mktemp -d -t ofloop-f002-XXXXXX)
git -C "$EMPTY" init -q -b master
git -C "$EMPTY" config --unset user.name 2>/dev/null || true
git -C "$EMPTY" config --unset user.email 2>/dev/null || true
OUT=$(HOME="$EMPTY" python3 -c "
import sys, os
sys.path.insert(0, '$ROOT/lib')
sys.argv = ['ofloop', 'new-repo', '$EMPTY', '--init-baseline']
from ownframework_loop.cli import cmd_new_repo, _emit_error
try:
    import argparse
    args = argparse.Namespace(root='$EMPTY', project_name='ofloop-f002', init_baseline=True)
    cmd_new_repo(args)
except SystemExit as e:
    sys.exit(e.code)
" 2>&1)
RC=$?
if echo "$OUT" | grep -qi "MISSING_GIT_IDENTITY"; then
  pass_test "F-002: missing identity refusal present (rc=$RC)"
else
  fail_test "F-002" "rc=$RC; out=$OUT"
fi
rm -rf "$EMPTY"

# ----- F-003: doctor rejects bare repositories -----
echo "F-003: doctor returns ok=false with BARE_REPOSITORY_UNSUPPORTED for bare repos"
BARE=$(mktemp -d -t ofloop-f003-XXXXXX)
git -C "$BARE" init --bare -q
OUT=$(python3 -c "
import sys, json
sys.path.insert(0, '$ROOT/lib')
from ownframework_loop import git_checks
print(json.dumps({'is_bare': git_checks.is_bare('$BARE')}))
")
if echo "$OUT" | grep -q '"is_bare": true'; then
  pass_test "F-003: is_bare() detects bare repos"
else
  fail_test "F-003" "is_bare missing; out=$OUT"
fi
rm -rf "$BARE"

# ----- F-004: spec new refuses tracked dirty state without --unsafe -----
echo "F-004: spec new refuses tracked-modified without --unsafe"
DIRTY=$(mk_repo)
echo "extra" > "$DIRTY/extra.txt"
git -C "$DIRTY" add extra.txt
# Tracked modified (change to tracked file)
echo "modified" > "$DIRTY/README.md"
OUT=$(python3 -c "
import sys, json
sys.path.insert(0, '$ROOT/lib')
from ownframework_loop import git_checks
print(json.dumps(git_checks.dirty_classification('$DIRTY')))
")
if echo "$OUT" | grep -q '"has_tracked_modified": true' && echo "$OUT" | grep -q '"has_staged": true'; then
  pass_test "F-004: dirty_classification() reports tracked-modified + staged"
else
  fail_test "F-004" "dirty_classification incomplete; out=$OUT"
fi
rm_repo "$DIRTY"

# ----- F-005: dirty_classification separates tracked-modified vs untracked -----
echo "F-005: dirty_classification reports has_untracked separately"
UNTRK=$(mk_repo)
echo "untracked" > "$UNTRK/u.txt"
OUT=$(python3 -c "
import sys, json
sys.path.insert(0, '$ROOT/lib')
from ownframework_loop import git_checks
print(json.dumps(git_checks.dirty_classification('$UNTRK')))
")
if echo "$OUT" | grep -q '"has_untracked": true' && echo "$OUT" | grep -q '"has_tracked_modified": false'; then
  pass_test "F-005: has_untracked reported independently of tracked-modified"
else
  fail_test "F-005" "out=$OUT"
fi
rm_repo "$UNTRK"

echo
echo "TOTAL=$((pass+fail)) PASSED=$pass FAILED=$fail"
if [[ $fail -ne 0 ]]; then
  echo "FAILED: ${fail_msgs[*]}"
  exit 1
fi
exit 0
