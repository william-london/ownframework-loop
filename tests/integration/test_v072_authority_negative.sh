#!/usr/bin/env bash
# v0.7.2 architecture closure — NEGATIVE authority-boundary tests.
#
# Regression coverage for the independent source-review findings:
#   F1  external-action guard fails CLOSED on classifier crash/garbage
#   F5  reviewer "read-only" Bash policy admits no mutating forms
#   F6  external-action coverage: registry/GitHub mutation, compound MCP
#       verbs, mutating HTTP toward non-loopback hosts
#   F7  macOS supervisor install/refresh refuses while semantic work is live
#   F9  supervisor resume preserves the funded wall-clock origin by default
#   F10 repeated enqueue preserves configured operational ceilings
#   F12 approval refuses packets that are not executable under the current
#       authority contract (delegated / merge_on_approved)
#
# These are NEGATIVE tests: they prove refusals happen, not merely that
# allow paths exist. No model is called.

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

OFLOOP="$OFLOOP_BIN"
TMP="$(mktemp -d -t ofloop_v072_auth.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# T1/T2: external-action guard fail-closed + coverage (hook level).
# ---------------------------------------------------------------------------
REPO="$TMP/repo-ext"
mkdir -p "$REPO/.ownframework-loop/run-ext"
python3 - "$REPO" "$LIB_DIR" <<'PY'
import sys
sys.path.insert(0, sys.argv[2])
from ownframework_loop import role_context
role_context.enter_semantic_role(canonical_repo=sys.argv[1], run_id="run-ext", role="builder")
PY

mkpayload() {
  python3 -c 'import json,sys;print(json.dumps({"tool_name":sys.argv[2],"cwd":sys.argv[1],"tool_input":({"command":sys.argv[3]} if sys.argv[2]=="Bash" else {})}))' "$REPO" "$1" "$2"
}

hook_expect_block() {
  local desc="$1" tool="$2" cmd="$3" root="$4"
  local out
  out="$(mkpayload "$tool" "$cmd" | CLAUDE_PLUGIN_ROOT="$root" bash "$ROOT_DIR/hooks/external_action_guard.sh" 2>/dev/null || true)"
  if ! printf '%s' "$out" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
assert raw, "hook emitted nothing"
o = json.loads(raw)
assert o["decision"] == "block", o
assert o["hookSpecificOutput"]["permissionDecisionReason"].startswith("BLOCK:OF_LOOP_"), o
'; then
    fail "external-action guard did not BLOCK: $desc (output: $out)"
  fi
  pass "external-action guard BLOCK: $desc"
}

hook_expect_allow() {
  local desc="$1" tool="$2" cmd="$3"
  local out
  out="$(mkpayload "$tool" "$cmd" | CLAUDE_PLUGIN_ROOT="$ROOT_DIR" bash "$ROOT_DIR/hooks/external_action_guard.sh" 2>/dev/null; echo "EXIT:$?")"
  [[ "$out" == "EXIT:0" ]] || fail "external-action guard should stay silent: $desc (output: $out)"
  pass "external-action guard allows: $desc"
}

# F1: classifier import crash must fail CLOSED, never ALLOW.
ROOT_CRASH="$TMP/root-crash"
mkdir -p "$ROOT_CRASH/lib/ownframework_loop"
cp "$LIB_DIR/ownframework_loop/role_context.py" "$ROOT_CRASH/lib/ownframework_loop/"
echo '"""stub"""' > "$ROOT_CRASH/lib/ownframework_loop/__init__.py"
printf 'raise RuntimeError("boom: classifier broken")\n' > "$ROOT_CRASH/lib/ownframework_loop/external_action.py"
hook_expect_block "classifier import crash fails closed" "Bash" "git push origin master" "$ROOT_CRASH"

# F1: a classifier returning an unrecognized decision must fail CLOSED.
ROOT_GARBAGE="$TMP/root-garbage"
mkdir -p "$ROOT_GARBAGE/lib/ownframework_loop"
cp "$LIB_DIR/ownframework_loop/role_context.py" "$ROOT_GARBAGE/lib/ownframework_loop/"
echo '"""stub"""' > "$ROOT_GARBAGE/lib/ownframework_loop/__init__.py"
printf 'def classify_tool_call(**kwargs):\n    return "GARBAGE_DECISION"\n' > "$ROOT_GARBAGE/lib/ownframework_loop/external_action.py"
hook_expect_block "garbage classifier decision fails closed" "Bash" "git push origin master" "$ROOT_GARBAGE"

# F6 coverage: registry / GitHub / release mutation forms.
hook_expect_block "git push" "Bash" "git push origin master" "$ROOT_DIR"
hook_expect_block "npm publish" "Bash" "npm publish" "$ROOT_DIR"
hook_expect_block "docker push" "Bash" "docker push myimg:latest" "$ROOT_DIR"
hook_expect_block "twine upload" "Bash" "twine upload dist/*" "$ROOT_DIR"
hook_expect_block "gh pr merge" "Bash" "gh pr merge 42" "$ROOT_DIR"
hook_expect_block "gh pr close" "Bash" "gh pr close 42" "$ROOT_DIR"
hook_expect_block "gh api mutation" "Bash" "gh api repos/x/y/issues -X POST -f title=hi" "$ROOT_DIR"
hook_expect_block "gh repo create" "Bash" "gh repo create newrepo --private" "$ROOT_DIR"
hook_expect_block "gh release create" "Bash" "gh release create v1.0" "$ROOT_DIR"
# F6: mutating HTTP toward a non-loopback host.
hook_expect_block "curl POST to external host" "Bash" "curl -X POST https://api.example.com/things -d @x" "$ROOT_DIR"
hook_expect_block "curl --data to external host" "Bash" "curl --data urlencoded=1 https://example.org/api" "$ROOT_DIR"
hook_expect_block "wget --post-data to external host" "Bash" "wget --post-data='a=1' https://example.net/api" "$ROOT_DIR"
# Local development capability stays broad: loopback mutations allowed.
hook_expect_allow "curl POST to loopback" "Bash" "curl -X POST http://127.0.0.1:8000/api -d @x"
hook_expect_allow "pytest run" "Bash" "pytest tests/ -x"
hook_expect_allow "docker compose up local" "Bash" "docker compose up -d"
hook_expect_allow "curl GET external (read)" "Bash" "curl -s https://example.com/status"

# F6: compound MCP operation names fail closed on any mutating verb.
hook_expect_block "mcp create_issue" "mcp__tracker__create_issue" "" "$ROOT_DIR"
hook_expect_block "mcp compound create_and_get" "mcp__tracker__create_and_get" "" "$ROOT_DIR"
hook_expect_block "mcp unknown verb fails closed" "mcp__tracker__frobnicate" "" "$ROOT_DIR"
hook_expect_allow "mcp read-only list_issues" "mcp__tracker__list_issues" ""
hook_expect_allow "mcp read-only vps_status" "mcp__ownframework-vps__vps_status" ""

# F1/F6: empty tool name fails closed during an active run.
EMPTY_PAYLOAD="$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"","cwd":sys.argv[1],"tool_input":{}}))' "$REPO")"
EMPTY_OUT="$(printf '%s' "$EMPTY_PAYLOAD" | CLAUDE_PLUGIN_ROOT="$ROOT_DIR" bash "$ROOT_DIR/hooks/external_action_guard.sh" 2>/dev/null || true)"
printf '%s' "$EMPTY_OUT" | python3 -c '
import json, sys
o = json.loads(sys.stdin.read())
assert o["decision"] == "block", o
' || fail "empty tool name must fail closed (got: $EMPTY_OUT)"
pass "external-action guard BLOCK: empty tool name fails closed"

# No semantic context: the hook must remain a NO-OP (developer capability).
rm -f "$REPO/.ownframework-loop/_semantic_context"
NOCTX_OUT="$(mkpayload "Bash" "git push origin master" | CLAUDE_PLUGIN_ROOT="$ROOT_DIR" bash "$ROOT_DIR/hooks/external_action_guard.sh" 2>/dev/null; echo "EXIT:$?")"
[[ "$NOCTX_OUT" == "EXIT:0" ]] || fail "hook must be a no-op outside semantic context (got: $NOCTX_OUT)"
pass "external-action guard is a no-op outside semantic context"

# ---------------------------------------------------------------------------
# T3: reviewer read-only policy negative matrix (F5).
# ---------------------------------------------------------------------------
python3 - "$LIB_DIR" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from ownframework_loop import guards

reviewer_blocked = [
    "git branch new-feature",
    "git branch -f hotfix",
    "git branch -m old new",
    "git branch -d feature",
    "git branch -v newbranch",
    "git branch --set-upstream-to=origin/x",
    "echo pwned > /tmp/x",
    "echo x >> log.txt",
    "cat foo >& outfile",
    "cmd &> all.log",
    "find . -name '*.pyc' -delete",
    "find . -exec rm {} ;",
    "rm -rf build",
    "git status && git push origin master",
    "echo hi; git branch sneaky",
]
reviewer_allowed = [
    "git branch",
    "git branch --list",
    "git branch -a",
    "git branch --contains HEAD",
    "git status --porcelain 2>&1",
    "git show HEAD 2>/dev/null | head -20",
    "make test 1>&2",
    "find . -name '*.py' -type f",
    "pytest tests/ -q",
    "curl -s http://127.0.0.1:8000/health",
]
for cmd in reviewer_blocked:
    r = guards.classify_bash_command(cmd, role="reviewer")
    assert r["severity"] == "forbidden", f"reviewer lane must forbid: {cmd!r}"
for cmd in reviewer_allowed:
    r = guards.classify_bash_command(cmd, role="reviewer")
    assert r["severity"] == "allowed", f"reviewer lane must allow: {cmd!r} -> {r['forbidden']}"
# Builder lane keeps broad local engineering capability.
for cmd in ["git branch new-feature", "echo x > /tmp/y", "find . -delete"]:
    r = guards.classify_bash_command(cmd, role="builder")
    assert r["severity"] == "allowed", f"builder lane must allow: {cmd!r}"
print("REVIEWER_POLICY_MATRIX=OK")
PY
pass "reviewer read-only policy: mutation forms refused, listing/redirect-capture allowed"

# ---------------------------------------------------------------------------
# T4: approval refuses non-executable authority packets (F12).
# ---------------------------------------------------------------------------
AUTH_REPO="$(make_tmp_repo)"
AUTH_RUN="$(make_approved_run_unapproved "$AUTH_REPO" FEATURE low "authority-gate")"
AUTH_PP="$AUTH_REPO/.ownframework-loop/$AUTH_RUN/WORK_PACKET.md"
python3 - "$AUTH_PP" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
text = p.read_text()
text = text.replace('"external_action_authority": "none"',
                    '"external_action_authority": "delegated"')
p.write_text(text)
PY
set +e
AUTH_OUT="$("$OFLOOP" spec approve "$AUTH_REPO" "$AUTH_RUN" --actor test </dev/null 2>&1)"
AUTH_RC=$?
set -e
[[ "$AUTH_RC" -ne 0 ]] || fail "spec approve must refuse a delegated-authority packet"
assert_contains "$AUTH_OUT" "not executable under current authority" \
  "approval refuses delegated external_action_authority before the TTY gate"

PROMO_REPO="$(make_tmp_repo)"
PROMO_RUN="$(make_approved_run_unapproved "$PROMO_REPO" FEATURE low "promotion-gate")"
PROMO_PP="$PROMO_REPO/.ownframework-loop/$PROMO_RUN/WORK_PACKET.md"
python3 - "$PROMO_PP" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
text = p.read_text()
text = text.replace('"schema": "ownframework-work-packet/v2"',
                    '"schema": "ownframework-work-packet/v2", "promotion_policy": "merge_on_approved"')
p.write_text(text)
PY
set +e
PROMO_OUT="$("$OFLOOP" spec approve "$PROMO_REPO" "$PROMO_RUN" --actor test </dev/null 2>&1)"
PROMO_RC=$?
set -e
[[ "$PROMO_RC" -ne 0 ]] || fail "spec approve must refuse merge_on_approved promotion policy"
assert_contains "$PROMO_OUT" "not executable under current authority" \
  "approval refuses merge_on_approved before the TTY gate"

# ---------------------------------------------------------------------------
# T5: supervisor installer live-work guard (F7).
#
# HERMETIC BY CONSTRUCTION: even if the guard regressed, this test can
# never touch the real machine — HOME points at a throwaway directory (the
# plist is generated there) and launchctl is shimmed to a stub that fails
# before any real bootstrap. The fixture worker_pid is the LIVE test-shell
# pid so the guard sees a genuinely alive worker (a dead pid is correctly
# classified as stale and would not refuse).
# ---------------------------------------------------------------------------
GUARD_STATE="$TMP/guard-state"
GUARD_HOME="$TMP/guard-home"
GUARD_BIN_SHIM="$TMP/guard-shims"
mkdir -p "$GUARD_STATE/ownframework-loop" "$GUARD_HOME" "$GUARD_BIN_SHIM"
printf '#!/bin/sh\necho "launchctl disabled in hermetic test" >&2\nexit 127\n' \
  > "$GUARD_BIN_SHIM/launchctl"
chmod +x "$GUARD_BIN_SHIM/launchctl"
GUARD_DB="$GUARD_STATE/ownframework-loop/supervisor.sqlite3"
TEST_LIVE_PID="$$" python3 - "$LIB_DIR" "$GUARD_DB" <<'PY'
import os, sys, time
sys.path.insert(0, sys.argv[1])
from pathlib import Path
from ownframework_loop import supervisor

db = Path(sys.argv[2])
repo = Path(os.path.dirname(str(db))) / "repo"
repo.mkdir(exist_ok=True)
job = supervisor.enqueue(
    canonical_repo=repo, run_id="run-guard", db_path=db, max_wall_seconds=600
)
import sqlite3
conn = sqlite3.connect(str(db))
conn.execute(
    "UPDATE jobs SET status='RUNNING', worker_pid=?, worker_started_at=? WHERE id=?",
    (int(os.environ["TEST_LIVE_PID"]), time.time(), int(job["id"])),
)
conn.commit()
PY
set +e
GUARD_OUT="$(PATH="$GUARD_BIN_SHIM:$PATH" HOME="$GUARD_HOME" XDG_STATE_HOME="$GUARD_STATE" \
  bash "$ROOT_DIR/install-supervisor-macos.sh" 2>&1)"
GUARD_RC=$?
set -e
[[ "$GUARD_RC" -eq 11 ]] || fail "installer must refuse with exit 11 while semantic work is live (rc=$GUARD_RC out=$GUARD_OUT)"
assert_contains "$GUARD_OUT" "reason=active_semantic_work" \
  "installer refuses replacement while a semantic worker is live"

# ---------------------------------------------------------------------------
# T6: supervisor envelope preservation + wall-clock origin (F9, F10).
# ---------------------------------------------------------------------------
python3 - "$LIB_DIR" "$TMP" <<'PY'
import sys, time
sys.path.insert(0, sys.argv[1])
from pathlib import Path
from ownframework_loop import supervisor

db = Path(sys.argv[2]) / "supervisor-envelope.sqlite3"
repo = Path(sys.argv[2]) / "repo-env"
repo.mkdir(exist_ok=True)

# F10: configured ceilings survive a repeated enqueue that omits them.
first = supervisor.enqueue(
    canonical_repo=repo, run_id="run-env", db_path=db,
    max_wall_seconds=600, max_total_cost_usd=5.0, max_total_tokens=1000,
    max_infra_failures=5,
)
assert first["max_wall_seconds"] == 600, first
again = supervisor.enqueue(canonical_repo=repo, run_id="run-env", db_path=db)
assert again["max_wall_seconds"] == 600, f"re-enqueue wiped wall ceiling: {again}"
assert again["max_total_cost_usd"] == 5.0, f"re-enqueue wiped cost ceiling: {again}"
assert again["max_total_tokens"] == 1000, f"re-enqueue wiped token ceiling: {again}"
assert again["max_infra_failures"] == 5, f"re-enqueue wiped infra ceiling: {again}"

# An EXPLICIT value still overwrites (operator intent, including disable).
disabled = supervisor.enqueue(
    canonical_repo=repo, run_id="run-env", db_path=db, max_wall_seconds=0
)
assert disabled["max_wall_seconds"] == 0, disabled
assert disabled["max_total_cost_usd"] == 5.0, "explicit wall must not wipe cost"

# F9: resume preserves the funded wall-clock origin by default.
import sqlite3
conn = sqlite3.connect(str(db))
conn.execute(
    "UPDATE jobs SET status='QUARANTINED', execution_started_at=1000.0 WHERE run_id='run-env'"
)
conn.commit()
conn.close()
resumed = supervisor.resume(canonical_repo=repo, run_id="run-env", db_path=db)
assert resumed["ok"], resumed
assert float(resumed["execution_started_at"]) == 1000.0, (
    f"resume reset the funded wall-clock origin by default: {resumed}"
)
# Quarantine again, then prove an EXPLICIT reset is still possible.
conn = sqlite3.connect(str(db))
conn.execute("UPDATE jobs SET status='QUARANTINED' WHERE run_id='run-env'")
conn.commit()
conn.close()
fresh = supervisor.resume(
    canonical_repo=repo, run_id="run-env", db_path=db,
    reset_execution_started_at=True,
)
assert fresh["ok"], fresh
assert float(fresh["execution_started_at"]) > 1000.0, fresh
print("SUPERVISOR_ENVELOPE=OK")
PY
pass "supervisor: re-enqueue preserves ceilings; resume keeps the wall-clock origin unless explicitly reset"

echo "V072_AUTHORITY_NEGATIVE=PASS"
