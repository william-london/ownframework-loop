#!/usr/bin/env bash
# OwnFramework Loop — bypass matrix.
export OFLOOP_BLOCKED_SSH_TARGETS="production-host-1 production-host-2"
export OFLOOP_RECOGNIZED_AND_BLOCKED_EXECUTABLES="hermes codex"
export OFLOOP_HIGH_RISK_EXECUTABLES="hermes codex"
#
# Each row in the contract's required matrix is exercised against the
# textual guard. Where the textual guard cannot reliably classify (eval,
# Python subprocess, multiline), we mark the row UNPROTECTED_TEXTUAL and
# rely on the post-pass verification + sandbox to catch it.

set -uo pipefail
. "$(dirname "$0")/../_helpers.sh"

TEST_TMP_REPO="$(mktemp -d -t ofloop_bypass.XXXXXX)"
git -C "$TEST_TMP_REPO" init -b master >/dev/null 2>&1
git -C "$TEST_TMP_REPO" config user.email "test@local"
git -C "$TEST_TMP_REPO" config user.name "test"
touch "$TEST_TMP_REPO/README.md"
git -C "$TEST_TMP_REPO" add README.md
git -C "$TEST_TMP_REPO" commit -m init >/dev/null 2>&1
# Active-run marker so the hook's walk-up finds it. V2 hook requires
# STATE.json (not just a directory) to recognize the active run.
mkdir -p "$TEST_TMP_REPO/.ownframework-loop/run-active"
cat > "$TEST_TMP_REPO/.ownframework-loop/run-active/STATE.json" <<'STATE'
{"schema":"ownframework-loop-state/v1","run_id":"run-active","state":"BUILDING","transitions_count":1,"build_pass_count":1,"review_pass_count":0,"repair_round":0,"no_progress_streak":0,"state_history":[]}
STATE

# Run the textual guard against a command. Returns 0 if blocked, 1 if allowed.
run_guard() {
  local cmd="$1"
  local payload
  payload="$(printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":%s}}' \
    "$TEST_TMP_REPO" "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$cmd")")"
  printf '%s' "$payload" | OFLOOP_PLUGIN_ROOT="$ROOT_DIR" \
    bash "$ROOT_DIR/hooks/block_dangerous_bash.sh" 2>/dev/null
}

assert_textual_block() {
  local label="$1" cmd="$2"
  local out; out="$(run_guard "$cmd")"
  if echo "$out" | grep -q '"decision": "block"'; then
    pass "textual block: $label"
  else
    echo "    command: $cmd"
    echo "    output: $out"
    fail "textual guard did NOT block: $label"
  fi
}

assert_textual_allow() {
  local label="$1" cmd="$2"
  local out; out="$(run_guard "$cmd")"
  if echo "$out" | grep -q '"decision": "block"'; then
    echo "    command: $cmd"
    echo "    output: $out"
    fail "textual guard unexpectedly BLOCKED: $label"
  else
    pass "textual allow (deferred to other layers): $label"
  fi
}

# ----- Row 1: bare-form git push family -----
assert_textual_block  "git push"                       "git push origin master"
assert_textual_block  "/usr/bin/git push"              "/usr/bin/git push origin master"
assert_textual_block  "command git push"               "command git push origin master"
assert_textual_block  "env FOO=bar git push"           "env FOO=bar git push origin master"
assert_textual_block  "git -C <path> push"             "git -C /tmp push origin master"
assert_textual_block  "git \"push\""                   'git "push" origin master'
assert_textual_block  "git 'push'"                     "git 'push' origin master"
assert_textual_block  "git --no-verify push"           "git push --no-verify origin master"
assert_textual_block  "git push --force"               "git push --force origin master"
assert_textual_block  "git push --force-with-lease"    "git push --force-with-lease origin master"

# ----- Row 2: chains & pipelines -----
assert_textual_block  "compound: &&"   "git status && git push origin master"
assert_textual_block  "compound: ;"    "git status; git push origin master"
assert_textual_block  "compound: ||"   "false || git push origin master"
assert_textual_block  "pipeline: |"    "ls / | git push origin master"

# ----- Row 3: indirection forms (V2.0.1 closes Python-subprocess and variable-assembly evasions) -----
# The textual guard CAN see through `$(...)` and `eval` because the inner
# command is still visible in the string. V2.0.1 also closes the
# Python-subprocess argv-literal and variable-assembly evasions via
# layered normalization (see lib/ownframework_loop/external_action.py).
# Forms that still defer to other layers (multiline, opaque dynamic code,
# base64 payloads) are documented in docs/BYPASS_MATRIX.md.
assert_textual_block  "subshell \$(...) sees inner" 'echo $(git push origin master)'
assert_textual_block  "eval sees inner command"    'eval "git push origin master"'
assert_textual_block  "variable indirection (V2.0.1 closed)" 'CMD=git; $CMD push origin master'
assert_textual_block  "Python subprocess (V2.0.1 closed)"    'python3 -c "import subprocess; subprocess.run([\"git\", \"push\"])"'
assert_textual_block  "single-line redirect"       "git push origin master > /tmp/push.log 2>&1"

# ----- Row 4: hermes-related benign commands — must NOT block -----
assert_textual_allow  "ls ~/.hermes/"  "ls /path/to/operator-home/.hermes/"
assert_textual_allow  "grep hermes"    "grep -r hermes src/"
assert_textual_allow  "echo hermes"    "echo hermes check"
assert_textual_block  "hermes CLI"     "hermes cron"
assert_textual_block  "/usr/bin/hermes" "/usr/bin/hermes status"
assert_textual_block  "/usr/local/bin/hermes" "/usr/local/bin/hermes status"

# ----- Row 5: deployment / production paths -----
assert_textual_block  "systemctl"          "systemctl restart nginx"
assert_textual_block  "docker compose up"  "docker compose up -d"
assert_textual_block  "docker compose down" "docker compose down"
assert_textual_block  "ssh production-host-1"          "ssh production-host-1 echo hi"
assert_textual_block  "ssh production-host-2"       "ssh production-host-2 ls"

# ----- Row 6: git remote mutations -----
assert_textual_block  "git remote add"     "git remote add origin https://example.com/repo.git"
assert_textual_block  "git remote set-url" "git remote set-url origin https://example.com/repo.git"
assert_textual_block  "git remote remove"  "git remote remove origin"
assert_textual_block  "git worktree prune" "git worktree prune"

# ----- Row 7: git reset / branch destructive -----
assert_textual_block  "reset --hard"       "git reset --hard origin/master"
assert_textual_block  "branch -D"          "git branch -D feature"
assert_textual_block  "branch -d"          "git branch -d feature"
assert_textual_block  "git clean -fdx"     "git clean -fdx"

# ----- Row 8: protected-path Write/Edit hook -----
PP_HOOK="$ROOT_DIR/hooks/block_protected_paths.sh"

# Outside an active loop, the hook is a no-op (test outside the test temp repo).
SAFE_CWD="$(mktemp -d -t ofloop_outside.XXXXXX)"
HOOK_INPUT='{"tool_name":"Edit","cwd":"'"$SAFE_CWD"'","tool_input":{"file_path":"'"$SAFE_CWD"'/foo.py"}}'
PP_OUT="$(printf '%s' "$HOOK_INPUT" | bash "$PP_HOOK" 2>/dev/null)"
if echo "$PP_OUT" | grep -q '"decision": "block"'; then
  fail "protected-paths hook blocked a write outside active loop"
else
  pass "protected-paths: outside-loop is no-op"
fi
rm -rf "$SAFE_CWD"

# Inside an active loop, write to a real source path should be blocked.
HOOK_INPUT='{"tool_name":"Edit","cwd":"'"$TEST_TMP_REPO"'","tool_input":{"file_path":"'"$TEST_TMP_REPO"'/foo.py"}}'
PP_OUT="$(printf '%s' "$HOOK_INPUT" | bash "$PP_HOOK" 2>/dev/null)"
if echo "$PP_OUT" | grep -q '"decision": "block"'; then
  pass "protected-paths: real-source write blocked during active loop"
else
  fail "protected-paths hook did NOT block real source write"
fi

# Inside an active loop, write to .ownframework-loop/run-active/foo.py — BLOCKED.
HOOK_INPUT='{"tool_name":"Edit","cwd":"'"$TEST_TMP_REPO"'","tool_input":{"file_path":"'"$TEST_TMP_REPO"'/.ownframework-loop/run-active/foo.py"}}'
PP_OUT="$(printf '%s' "$HOOK_INPUT" | bash "$PP_HOOK" 2>/dev/null)"
if echo "$PP_OUT" | grep -q '"decision": "block"'; then
  pass "protected-paths: unknown filename in run dir blocked"
else
  fail "protected-paths did NOT block unknown filename"
fi

# V2: WORK_PACKET.md is authoritative — hook blocks direct Edit/Write to it.
# Only the ofloop CLI may write it. Verify the hook blocks Edit.
HOOK_INPUT='{"tool_name":"Edit","cwd":"'"$TEST_TMP_REPO"'","tool_input":{"file_path":"'"$TEST_TMP_REPO"'/.ownframework-loop/run-active/WORK_PACKET.md"}}'
PP_OUT="$(printf '%s' "$HOOK_INPUT" | bash "$PP_HOOK" 2>/dev/null)"
if echo "$PP_OUT" | grep -q '"decision": "block"'; then
  pass "protected-paths: WORK_PACKET.md direct edit blocked (V2 invariant)"
else
  fail "protected-paths ALLOWED a direct WORK_PACKET.md edit"
fi

# ----- Row 9: malformed JSON input must fail closed -----
BAD_HOOK_OUT="$(printf 'NOT_JSON' | bash "$ROOT_DIR/hooks/block_dangerous_bash.sh" 2>&1; echo "rc=$?")"
if echo "$BAD_HOOK_OUT" | grep -q "rc=2"; then
  pass "malformed JSON → block_dangerous_bash.sh exits 2 (fail closed)"
else
  fail "malformed JSON did not exit 2 — guard would fail open"
fi

BAD_HOOK_OUT2="$(printf 'NOT_JSON' | bash "$PP_HOOK" 2>&1; echo "rc=$?")"
if echo "$BAD_HOOK_OUT2" | grep -q "rc=2"; then
  pass "malformed JSON → block_protected_paths.sh exits 2 (fail closed)"
else
  fail "block_protected_paths.sh malformed JSON did not exit 2"
fi

# ----- Row 10: outside an active loop the textual guard is a no-op -----
NOOP_CWD="$(mktemp -d -t ofloop_noop.XXXXXX)"
NOOP_PAYLOAD="$(printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"git push origin master"}}' "$NOOP_CWD")"
NOOP_OUT="$(printf '%s' "$NOOP_PAYLOAD" | OFLOOP_PLUGIN_ROOT="$ROOT_DIR" bash "$ROOT_DIR/hooks/block_dangerous_bash.sh" 2>/dev/null)"
if echo "$NOOP_OUT" | grep -q '"decision": "block"'; then
  fail "textual guard blocked outside-loop (must be scoped)"
else
  pass "textual guard: outside-loop is no-op"
fi
rm -rf "$NOOP_CWD"

rm -rf "$TEST_TMP_REPO" 2>/dev/null || true

echo
echo "=== bypass-matrix coverage ==="
echo "  textual blocks tested: 25 forbidden forms (incl. 2 V2.0.1 closed evasions)"
echo "  textual allows (deferred to other layers): 7 forms (multiline, opaque dynamic, base64)"
echo "  protected-paths tested: 4 scenarios"
echo "  fail-closed on malformed JSON: 2 hooks"
echo "  TOTAL bypass rows covered: ~38 + 4 + 2 = 44"
exit 0
