#!/usr/bin/env bash
# v0.8.1 closure — mutating-HTTP fail-closed authority and run-id
# diagnostic observability.
#
# Independent-review findings covered:
#   F2  chained (&&, ||, |, ;, newline) mutating HTTP forms and
#       unresolved destinations fail closed; provably-loopback mutation
#       stays allowed; guards.py and external_action.py share ONE shell
#       chain parser.
#   F4  external-action diagnostics bind the exact semantic-context
#       run id (not the repo path).
#
# All checks drive the real hook end-to-end. No model is called.

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

TMP="$(mktemp -d -t ofloop_v080_http.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

REPO="$TMP/repo-http"
RUN_ID="run-http-$(date -u +%H%M%S)"
mkdir -p "$REPO/.ownframework-loop/$RUN_ID"
# The semantic context stores the RESOLVED canonical repo path
# (/var -> /private/var on macOS); diagnostics must match that form.
REPO_REAL="$(python3 -c 'import sys; from pathlib import Path; print(Path(sys.argv[1]).resolve())' "$REPO")"
python3 - "$REPO" "$RUN_ID" "$LIB_DIR" <<'PY'
import sys
sys.path.insert(0, sys.argv[3])
from ownframework_loop import role_context
role_context.enter_semantic_role(canonical_repo=sys.argv[1], run_id=sys.argv[2], role="builder")
PY

mkpayload() {
  python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$REPO" "$1"
}

hook_expect_block() {
  local desc="$1" cmd="$2"
  local out
  out="$(mkpayload "$cmd" | CLAUDE_PLUGIN_ROOT="$ROOT_DIR" bash "$ROOT_DIR/hooks/external_action_guard.sh" 2>/dev/null || true)"
  printf '%s' "$out" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
assert raw, "hook emitted nothing"
o = json.loads(raw)
assert o["decision"] == "block", o
code = o["hookSpecificOutput"]["permissionDecisionReason"]
assert code.startswith("BLOCK:OF_LOOP_"), code
' || fail "expected BLOCK: $desc (output: $out)"
  pass "HTTP authority BLOCK: $desc"
}

hook_expect_allow() {
  local desc="$1" cmd="$2"
  local out
  out="$(mkpayload "$cmd" | CLAUDE_PLUGIN_ROOT="$ROOT_DIR" bash "$ROOT_DIR/hooks/external_action_guard.sh" 2>/dev/null; echo "EXIT:$?")"
  [[ "$out" == "EXIT:0" ]] || fail "expected silent allow: $desc (output: $out)"
  pass "HTTP authority allows: $desc"
}

# --- Chained mutating HTTP forms (F2) -----------------------------------
hook_expect_block "curl POST hidden after &&" \
  'echo ok && curl -X POST https://api.example.com/x'
hook_expect_block "curl POST hidden after ||" \
  'true || curl -X POST https://api.example.com/x'
hook_expect_block "curl POST hidden after ; chain" \
  'echo ok; curl -X POST https://api.example.com/x'
hook_expect_block "curl POST piped from echo" \
  'echo x | curl -d @- https://api.example.com/x'
hook_expect_block "newline-hidden curl POST" \
  "$(printf 'echo harmless\ncurl -X POST https://api.example.com/y')"
hook_expect_block "wget post hidden after &&" \
  'echo ok && wget --post-data=a=1 https://example.net/api'

# --- Variable-resolved and unresolved destinations (F2) -----------------
hook_expect_block "assigned external URL via \$URL" \
  'URL=https://api.example.com/x; curl -X POST "$URL"'
hook_expect_block "unresolved \$URL destination fails closed" \
  'curl -X POST "$URL"'
hook_expect_block "no destination at all fails closed" \
  'curl -X POST'
hook_expect_block "unresolved bare \$TARGET with data" \
  'curl --data @payload.json $TARGET'

# --- Provably-loopback mutation remains allowed (developer capability) --
hook_expect_allow "loopback POST via 127.0.0.1" \
  'curl -X POST http://127.0.0.1:8000/api -d @x'
hook_expect_allow "loopback POST via localhost" \
  'curl -X POST http://localhost:9000/api --json {}'
hook_expect_allow "assigned loopback URL via \$URL" \
  'URL=http://localhost:9000/x; curl -X POST "$URL"'
hook_expect_allow "loopback chained after &&" \
  'make build && curl -X POST http://127.0.0.1:8080/reindex'

# --- Ordinary external GET/read research preserved ----------------------
hook_expect_allow "external GET read" \
  'curl -s https://example.com/status'
hook_expect_allow "external wget read" \
  'wget -qO- https://example.com/file.tar.gz'

# --- One shared chain parser (F2 consistency) ---------------------------
PYTHONPATH="$LIB_DIR" python3 -B <<'PY'
import os, sys
sys.path.insert(0, os.environ["PYTHONPATH"])
from ownframework_loop import external_action, guards

# Identity: exactly one implementation serves both classifiers.
assert guards._split_command_chain is external_action._split_command_chain
assert guards._split_single_line is external_action._split_single_line

# Agreement: a chained external push must be forbidden by BOTH paths.
chained = "echo ok && git push origin master"
g = guards.classify_bash_command(chained, role="builder")
assert g["severity"] == "forbidden", g
e = external_action.classify_tool_call(
    tool_name="Bash", tool_input={"command": chained}, active_run="run-x")
assert e.startswith("BLOCK:"), e

# Agreement on the reviewer lane with fd redirects (2>&1 stays usable).
r = guards.classify_bash_command("git status --porcelain 2>&1", role="reviewer")
assert r["severity"] == "allowed", r
print("SHARED_CHAIN_PARSER=OK")
PY
pass "guards.py and external_action.py share one chain parser and agree"

# --- Run-id diagnostic binding (F4) -------------------------------------
rm -rf "$ROOT_DIR/logs/external_action_diagnostics.log" 2>/dev/null || true
rm -f "$ROOT_DIR/logs/external_action_diagnostics.log"

# ALLOW_WITH_DIAGNOSTIC path: read-only MCP tool.
DIAG_PAYLOAD="$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"mcp__tracker__list_issues","cwd":sys.argv[1],"tool_input":{}}))' "$REPO")"
printf '%s' "$DIAG_PAYLOAD" | CLAUDE_PLUGIN_ROOT="$ROOT_DIR" bash "$ROOT_DIR/hooks/external_action_guard.sh" >/dev/null 2>&1 || true

# BLOCK path: external mutation.
mkpayload 'curl -X POST https://api.example.com/z' | CLAUDE_PLUGIN_ROOT="$ROOT_DIR" bash "$ROOT_DIR/hooks/external_action_guard.sh" >/dev/null 2>&1 || true

LOG="$ROOT_DIR/logs/external_action_diagnostics.log"
assert_file_exists "$LOG" "external-action diagnostics log written"
DIAG_CONTENTS="$(cat "$LOG")"
assert_contains "$DIAG_CONTENTS" "run_id=$RUN_ID" \
  "diagnostics bind the exact semantic-context run id"
assert_contains "$DIAG_CONTENTS" "canonical_repo=$REPO_REAL" \
  "diagnostics keep the canonical repo for cross-reference"
assert_contains "$DIAG_CONTENTS" "decision=ALLOW_WITH_DIAGNOSTIC" \
  "read-only diagnostic decisions are recorded"
assert_contains "$DIAG_CONTENTS" "decision=BLOCK:OF_LOOP_EXTERNAL_UNKNOWN" \
  "block decisions are recorded in the evidence trail"
assert_not_contains "$DIAG_CONTENTS" "run_id=$REPO_REAL" \
  "diagnostics never mislabel the repo path as the run id"

# The refusal reason itself carries the exact run id.
REASON_OUT="$(mkpayload 'git push origin master' | CLAUDE_PLUGIN_ROOT="$ROOT_DIR" bash "$ROOT_DIR/hooks/external_action_guard.sh" 2>/dev/null || true)"
REASON_JSON="$REASON_OUT" python3 - "$RUN_ID" <<'PY' || fail "block reason must carry the exact run id (output: $REASON_OUT)"
import json, os, sys
run_id = sys.argv[1]
o = json.loads(os.environ["REASON_JSON"])
assert o["decision"] == "block", o
reason = o["reason"]
assert f"[active run: {run_id}]" in reason, reason
PY
pass "block reasons identify the exact protected run"

echo "V080_HTTP_MUTATION_DIAGNOSTICS=PASS"
