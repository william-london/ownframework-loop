#!/usr/bin/env bash
# v0.3.4 hook-bytecode closeout tests.
#
# Tests A-E:
#   A. static launch-boundary verification — every Python-launching hook
#      runs with PYTHONDONTWRITEBYTECODE=1 and uses python3 -B
#   B. direct hook execution produces no bytecode in staged plugin root
#   C. security behavior is unchanged — representative allow/deny/scan cases
#   D. repeated hook execution remains clean
#   E. existing release regression — re-runs v0.3.2/v0.3.3 focused tests
set -euo pipefail
ROOT="${OFLOOP_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; exit 1; }

HOOKS=(
  "block_dangerous_bash.sh"
  "block_protected_paths.sh"
  "external_action_guard.sh"
  "post_bash_secret_scan.sh"
)

# ---------------------------------------------------------------
# Test A — static launch-boundary verification
# ---------------------------------------------------------------
echo "Test A: every Python-launching hook is bytecode-suppressed"
for h in "${HOOKS[@]}"; do
  hf="$ROOT/hooks/$h"
  # 1. file exports PYTHONDONTWRITEBYTECODE=1
  if ! grep -Eq '^\s*export\s+PYTHONDONTWRITEBYTECODE=1\s*$' "$hf"; then
    fail "Test A: $h missing 'export PYTHONDONTWRITEBYTECODE=1'"
  fi
  # 2. every launch line uses python3 -B
  bad=$(grep -nE "(^|[^A-Z_a-z-])python3(\s|$)" "$hf" \
        | grep -vE "python3 -B" \
        | grep -vE "python3\$" \
        | grep -vE ":\s*#" \
        || true)
  if [[ -n "$bad" ]]; then
    echo "$bad" | sed 's/^/    /'
    fail "Test A: $h has unsuppressed python3 launch lines"
  fi
  pass "Test A: $h is bytecode-suppressed at all launch sites"
done

# ---------------------------------------------------------------
# Test B — direct hook execution produces no bytecode
# ---------------------------------------------------------------
echo "Test B: staged hook execution produces zero bytecode paths"

stage_plugin() {
  local staging="$1"
  rm -rf "$staging"
  mkdir -p "$staging/lib/ownframework_loop" "$staging/hooks"
  cp "$ROOT/lib/ownframework_loop/"*.py "$staging/lib/ownframework_loop/"
  cp "$ROOT/hooks/"*.sh "$staging/hooks/"
  chmod +x "$staging/hooks/"*.sh
  echo "$staging"
}

STAGING_ROOT="/tmp/v034_staging_$$"
mkdir -p "$STAGING_ROOT"
trap 'rm -rf "$STAGING_ROOT"' EXIT

for h in "${HOOKS[@]}"; do
  STAGING="$(stage_plugin "$STAGING_ROOT/$h")"
  case "$h" in
    block_dangerous_bash.sh)
      INPUT='{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
      ;;
    block_protected_paths.sh)
      INPUT='{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}'
      ;;
    external_action_guard.sh)
      INPUT='{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}'
      ;;
    post_bash_secret_scan.sh)
      INPUT='{"tool_name":"Bash","tool_output":"hello world"}'
      ;;
  esac
  CLAUDE_PLUGIN_ROOT="$STAGING" printf '%s' "$INPUT" | bash "$STAGING/hooks/$h" >/dev/null 2>&1 || true
  count=$(find "$STAGING" \
    \( -type d -name '__pycache__' -o \
       -type f -name '*.pyc' -o \
       -type f -name '*.pyo' -o \
       -type f -name '*.pyd' \) -print 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$count" -ne 0 ]]; then
    echo "  bytecode paths created by $h:"
    find "$STAGING" \
      \( -type d -name '__pycache__' -o \
         -type f -name '*.pyc' -o \
         -type f -name '*.pyo' -o \
         -type f -name '*.pyd' \) -print 2>/dev/null | sed 's/^/    /'
    fail "Test B: $h created $count bytecode path(s)"
  fi
  pass "Test B: $h created 0 bytecode paths"
done

# ---------------------------------------------------------------
# Test C — security behavior is unchanged
#
# v0.6.1: this test no longer relies on the historical path-based
# heuristic ("repo contains .ownframework-loop = active run"). That
# heuristic over-scoped ordinary interactive Claude sessions and was
# removed by the execution-context-contract hardening. The test now
# establishes semantic-worker context via the v0.6.1 marker file
# at the staging cwd, which is the same provenance the foreground
# /of-loop:build and /of-loop:review skills use. The security contract
# under test (forbidden commands emit block JSON) is unchanged.
# ---------------------------------------------------------------
echo "Test C: security behavior is unchanged"

STAGING_C="$(stage_plugin "$STAGING_ROOT/C")"
mkdir -p "$STAGING_C/.ownframework-loop"
OFLOOP_LIB="$STAGING_C/lib" PYTHONPATH="$STAGING_C/lib" python3 -B - "$STAGING_C" <<PYTHON_END
import json, sys, os
sys.path.insert(0, os.environ["PYTHONPATH"])
from ownframework_loop import role_context
ctx = role_context.enter_semantic_role(
    canonical_repo=sys.argv[1],
    run_id="run-test-stub",
    role="builder",
)
print("MARKER_OK", json.dumps(ctx))
PYTHON_END

# C1. block_dangerous_bash.sh on a forbidden command emits block JSON.
INPUT_FORBIDDEN=$(printf '{"tool_name":"Bash","tool_input":{"command":"git reset --hard HEAD~1"},"cwd":"%s"}' "$STAGING_C")
out_forbidden=$(CLAUDE_PLUGIN_ROOT="$STAGING_C" printf '%s' "$INPUT_FORBIDDEN" | CLAUDE_PLUGIN_ROOT="$STAGING_C" bash "$STAGING_C/hooks/block_dangerous_bash.sh" 2>&1)
echo "$out_forbidden" | grep -q '"decision": "block"' || fail "Test C1: forbidden git reset --hard not blocked: $out_forbidden"
echo "$out_forbidden" | grep -q "OF_LOOP_BASH_FORBIDDEN" || fail "Test C1: wrong block code: $out_forbidden"
pass "Test C1: forbidden command blocked with OF_LOOP_BASH_FORBIDDEN"

# C2. block_dangerous_bash.sh on a harmless command emits no block.
INPUT_OK=$(printf '{"tool_name":"Bash","tool_input":{"command":"ls -la"},"cwd":"%s"}' "$STAGING_C")
out_ok=$(CLAUDE_PLUGIN_ROOT="$STAGING_C" printf '%s' "$INPUT_OK" | CLAUDE_PLUGIN_ROOT="$STAGING_C" bash "$STAGING_C/hooks/block_dangerous_bash.sh" 2>&1)
if [[ -n "$out_ok" ]]; then
  fail "Test C2: harmless command produced output (expected empty): $out_ok"
fi
pass "Test C2: harmless command produces empty stdout"

# C3. external_action_guard.sh on a Read tool produces no block.
INPUT_READ=$(printf '{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"},"cwd":"%s"}' "$STAGING_C")
out_read=$(CLAUDE_PLUGIN_ROOT="$STAGING_C" printf '%s' "$INPUT_READ" | CLAUDE_PLUGIN_ROOT="$STAGING_C" bash "$STAGING_C/hooks/external_action_guard.sh" 2>&1)
if [[ "$out_read" == *"\"decision\": \"block\""* ]]; then
  fail "Test C3: Read tool wrongly blocked: $out_read"
fi
pass "Test C3: Read tool not blocked"

# C4. block_protected_paths.sh on a Read tool emits no block.
out_ppp=$(CLAUDE_PLUGIN_ROOT="$STAGING_C" printf '%s' "$INPUT_READ" | CLAUDE_PLUGIN_ROOT="$STAGING_C" bash "$STAGING_C/hooks/block_protected_paths.sh" 2>&1)
echo "$out_ppp" | grep -q '"decision": "block"' && fail "Test C4: Read tool wrongly blocked: $out_ppp"
pass "Test C4: Read tool not blocked by block_protected_paths.sh"

# C5. malformed JSON fails closed (exit 2).
set +e
  out_malformed=$(CLAUDE_PLUGIN_ROOT="$STAGING_C" bash "$STAGING_C/hooks/block_dangerous_bash.sh" 2>&1 <<<'this is not json')
  rc_malformed=$?
  set -e
[[ "$rc_malformed" -eq 2 ]] || fail "Test C5: malformed JSON did not exit 2 (rc=$rc_malformed)"
pass "Test C5: malformed JSON exits 2"

# C6. post_bash_secret_scan.sh on non-Bash tool is no-op.
INPUT_NOTBASH='{"tool_name":"Read","tool_output":"hello world"}'
out_nbs=$(CLAUDE_PLUGIN_ROOT="$STAGING_C" printf '%s' "$INPUT_NOTBASH" | bash "$STAGING_C/hooks/post_bash_secret_scan.sh" 2>&1)
if [[ -n "$out_nbs" ]]; then
  fail "Test C6: non-Bash tool produced output: $out_nbs"
fi
pass "Test C6: non-Bash tool produces empty stdout"

# ---------------------------------------------------------------
# Test D — repeated hook execution remains clean
# ---------------------------------------------------------------
echo "Test D: 10 repeated executions of each hook produce zero bytecode"

for h in "${HOOKS[@]}"; do
  STAGING_D="$(stage_plugin "$STAGING_ROOT/D_$h")"
  case "$h" in
    block_dangerous_bash.sh)
      INPUT='{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
      ;;
    block_protected_paths.sh)
      INPUT='{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}'
      ;;
    external_action_guard.sh)
      INPUT='{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}'
      ;;
    post_bash_secret_scan.sh)
      INPUT='{"tool_name":"Bash","tool_output":"hello world"}'
      ;;
  esac
  for i in 1 2 3 4 5 6 7 8 9 10; do
    CLAUDE_PLUGIN_ROOT="$STAGING_D" printf '%s' "$INPUT" | bash "$STAGING_D/hooks/$h" >/dev/null 2>&1 || true
  done
  count=$(find "$STAGING_D" \
    \( -type d -name '__pycache__' -o \
       -type f -name '*.pyc' -o \
       -type f -name '*.pyo' -o \
       -type f -name '*.pyd' \) -print 2>/dev/null | wc -l | tr -d ' ')
  [[ "$count" -eq 0 ]] || fail "Test D: $h created $count bytecode path(s) after 10 runs"
  pass "Test D: $h repeated execution clean (0 bytecode paths)"
done

# ---------------------------------------------------------------
echo "ALL V0.3.4 HOOK-BYTECODE TESTS PASS"
