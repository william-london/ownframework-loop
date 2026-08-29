#!/usr/bin/env bash
# v0.6.1 execution-context contract — 12 deterministic regression tests.
#
# The OwnFramework Loop textual bash guard (hooks/block_dangerous_bash.sh)
# MUST NOT scope ordinary operator-authorized interactive Claude
# sessions. It is ONLY active when the bash invocation is provably inside
# a Loop semantic lane, established by EITHER:
#
#   (a) Environment markers OFLOOP_SEMANTIC_CONTEXT=1, OFLOOP_RUN_ID,
#       OFLOOP_ROLE, OFLOOP_CANONICAL_REPO set by the Loop supervisor
#       when launching a ClaudeCodeRunner worker.
#
#   (b) Marker file `.ownframework-loop/_semantic_context` at the cwd's
#       repo root, written by the foreground `/of-loop:build` and
#       `/of-loop:review` skills via `ofloop role enter`.
#
# Outside both provenances the hook is a NO-OP for that bash invocation.
# The tests below prove:
#
#   T01: interactive git push NOT blocked by .ownframework-loop ancestor
#        alone (no marker, no env).
#   T02: semantic builder push blocked via env markers.
#   T03: semantic reviewer push blocked via env markers.
#   T04: semantic builder alternate push forms blocked (env path).
#   T05: semantic reviewer alternate push forms blocked (env path).
#   T06: ordinary interactive local engineering commands (commit, pytest,
#        npm install) unaffected when no context.
#   T07: stale `.ownframework-loop/run-X/` directories from historical
#        runs do NOT activate the guard.
#   T08: explicit role context cannot bleed from a worker into an
#        unrelated interactive session (env smuggle refused when
#        canonical_repo does not match cwd's git toplevel).
#   T09: supervisor-launched builder receives OFLOOP_SEMANTIC_CONTEXT=1
#        and the role/run_id/canonical_repo vars in subprocess env.
#   T10: supervisor-launched reviewer receives the same.
#   T11: foreground /of-loop:build + /of-loop:review retain correct
#        restrictions via the marker-file path.
#   T12: no command grants push/merge/deploy to unattended semantic
#        workers — the partial-env / smuggling / malformed-role paths
#        all fail closed.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LIB="$ROOT/lib"
HOOK="$ROOT/hooks/block_dangerous_bash.sh"
PLUGIN_BIN="$ROOT/bin/ofloop"

export PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$LIB"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

# Sandbox: a fresh tmpdir per test run; never seen by the parent shell's PATH.
SANDBOX="$(mktemp -d -t ofloop-exec-ctx.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

# Fake git/docker/ssh on a private PATH so a real `git push` would never
# actually publish, and so we can detect that the hook let the command
# through to the shell (sentinel touched) vs refused it (sentinel absent).
# DO NOT fake `python3` — the hook itself invokes python3 to parse the
# JSON payload, and a fake python3 would silently fail every invocation.
SENTINEL="$SANDBOX/sentinel.touched"
write_fake() {
  local name="$1"
  cat > "$SANDBOX/$name" <<FAKE_EOF
#!/usr/bin/env bash
touch "$SENTINEL"
exit 99
FAKE_EOF
  chmod +x "$SANDBOX/$name"
}
for t in git docker ssh npm pytest cargo go; do write_fake "$t"; done

# Drive the hook with one invocation. Caller sets env, writes marker
# files, etc. Returns "rc<TAB>output".
#
# IMPORTANT: the cmd string can contain shell metacharacters
# (`&&`, `||`, `;`, `|`, `$()`, newlines) that we MUST NOT let bash
# re-interpret when building the JSON payload. We therefore build the
# payload via a Python helper that reads the cmd from a temp file, so
# the only place the cmd is parsed is inside Python (which json-escapes
# it). This keeps multiline/`&&`/`$()` commands literal.
write_payload() {
  local cwd="$1"
  local cmd="$2"
  local out_file="$3"
  # Pass cmd as the third positional arg (after the two flags). We
  # cannot use stdin to feed cmd because the python -c / heredoc path
  # may consume stdin for the script source. Using sys.argv is the
  # simplest robust path that keeps metacharacters literal.
  PYTHONDONTWRITEBYTECODE=1 python3 -B - "$cwd" "$out_file" "CMD_PLACEHOLDER" <<'PY_END'
import json, sys, os
cmd = os.environ.get("OFLOOP_TEST_CMD", "")
if not cmd and len(sys.argv) > 3 and sys.argv[3] != "CMD_PLACEHOLDER":
    cmd = sys.argv[3]
print(json.dumps({
    "tool_name": "Bash",
    "tool_input": {"command": cmd},
    "cwd": sys.argv[1],
}), file=open(sys.argv[2], "w", encoding="utf-8"))
PY_END
}

invoke_hook() {
  local cwd="$1"
  local cmd="$2"
  local payload_file
  payload_file="$(mktemp -p "$SANDBOX" payload.XXXXXX.json)"
  # Feed cmd via OFLOOP_TEST_CMD env so metacharacters are literal.
  OFLOOP_TEST_CMD="$cmd" write_payload "$cwd" "$cmd" "$payload_file"
  local payload
  payload="$(cat "$payload_file")"
  rm -f "$SENTINEL" "$payload_file"
  local out rc
  set +e
  out="$(printf '%s' "$payload" | CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$SANDBOX:$PATH" bash "$HOOK" 2>&1)"
  rc=$?
  set -e
  printf 'rc=%s\n' "$rc"
  printf '%s\n' "$out"
}

# Helper: detect "block decision" in hook output.
is_block_decision() {
  grep -Fq '"decision": "block"' <<<"$1"
}

# Helper: detect OF_LOOP_BASH_FORBIDDEN in hook output.
has_forbidden_marker() {
  grep -Fq 'OF_LOOP_BASH_FORBIDDEN' <<<"$1"
}

# Drive the hook with semantic-context env vars exported. Many shells
# under `set -u` silently drop prefix env-var assignments when the
# command is a $(...) subshell; exporting first and passing explicitly
# is the most reliable path. The cwd argument is the canonical_repo
# the env vars declare — the hook will cross-check them.
invoke_with_env() {
  local role="$1"
  local run_id="$2"
  local canonical_repo="$3"
  local cwd="$4"
  local cmd="$5"
  OFLOOP_SEMANTIC_CONTEXT=1 \
  OFLOOP_RUN_ID="$run_id" \
  OFLOOP_ROLE="$role" \
  OFLOOP_CANONICAL_REPO="$canonical_repo" \
  invoke_hook "$cwd" "$cmd"
}

# Build a minimal git repo at $1 with optional marker write.
make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  (cd "$dir" && git init -q -b master && git config user.email "t@t" && git config user.name "t" && echo x > x && git add x && git commit -q -m x)
}

write_marker() {
  local dir="$1"
  local role="$2"
  local run_id="${3:-run-20260829T999999Z-test}"
  OFLOOP_LIB="$LIB" python3 -B - "$dir" "$run_id" "$role" <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["OFLOOP_LIB"])
from ownframework_loop import role_context
ctx = role_context.enter_semantic_role(
    canonical_repo=sys.argv[1], run_id=sys.argv[2], role=sys.argv[3],
)
print("MARKER_OK", json.dumps(ctx))
PY
}

clear_marker() {
  local dir="$1"
  rm -f "$dir/.ownframework-loop/_semantic_context"
}

add_stale_run() {
  local dir="$1"
  mkdir -p "$dir/.ownframework-loop/run-20260101T000000Z-stale"
  echo '{"state":"BUILDING"}' > "$dir/.ownframework-loop/run-20260101T000000Z-stale/STATE.json"
}

# =====================================================================
# T01: interactive git push NOT blocked by .ownframework-loop ancestor
# =====================================================================
echo ""
echo "=== T01: interactive git push not blocked by stale run dir ==="
T01_REPO="$SANDBOX/T01/repo"
make_repo "$T01_REPO"
add_stale_run "$T01_REPO"
# no marker, no env → hook is a no-op
OUT=$(invoke_hook "$T01_REPO" "git push origin master")
if is_block_decision "$OUT"; then
  fail "T01: hook blocked interactive git push despite no context. out=$OUT"
else
  pass "T01: interactive git push not blocked by stale run dir alone"
fi
if has_forbidden_marker "$OUT"; then
  fail "T01: hook emitted OF_LOOP_BASH_FORBIDDEN without semantic context. out=$OUT"
else
  pass "T01: hook emitted no OF_LOOP_BASH_FORBIDDEN for interactive session"
fi

# =====================================================================
# T02: semantic builder push blocked via env markers
# =====================================================================
echo ""
echo "=== T02: semantic builder push blocked via env markers ==="
T02_REPO="$SANDBOX/T02/repo"
make_repo "$T02_REPO"
OUT=$(OFLOOP_SEMANTIC_CONTEXT=1 \
      OFLOOP_RUN_ID="run-T02" \
      OFLOOP_ROLE="builder" \
      OFLOOP_CANONICAL_REPO="$T02_REPO" \
      invoke_hook "$T02_REPO" "git push origin master")
if is_block_decision "$OUT"; then
  pass "T02: env-marker builder push blocked"
else
  fail "T02: env-marker builder push NOT blocked. out=$OUT"
fi
if has_forbidden_marker "$OUT"; then
  pass "T02: env-marker builder push surfaces OF_LOOP_BASH_FORBIDDEN"
else
  fail "T02: env-marker builder push missing OF_LOOP_BASH_FORBIDDEN. out=$OUT"
fi

# =====================================================================
# T03: semantic reviewer push blocked via env markers
# =====================================================================
echo ""
echo "=== T03: semantic reviewer push blocked via env markers ==="
T03_REPO="$SANDBOX/T03/repo"
make_repo "$T03_REPO"
OUT=$(OFLOOP_SEMANTIC_CONTEXT=1 \
      OFLOOP_RUN_ID="run-T03" \
      OFLOOP_ROLE="reviewer" \
      OFLOOP_CANONICAL_REPO="$T03_REPO" \
      invoke_hook "$T03_REPO" "git push origin master")
if is_block_decision "$OUT" && has_forbidden_marker "$OUT"; then
  pass "T03: env-marker reviewer push blocked with OF_LOOP_BASH_FORBIDDEN"
else
  fail "T03: env-marker reviewer push NOT blocked correctly. out=$OUT"
fi

# =====================================================================
# T04: alternate push forms blocked (env path)
# =====================================================================
echo ""
echo "=== T04: alternate push forms blocked under builder context ==="
T04_REPO="$SANDBOX/T04/repo"
make_repo "$T04_REPO"
ALL_BLOCKED=yes
for cmd in \
  "git push --force-with-lease origin master" \
  "git push origin HEAD:refs/heads/master" \
  "git push --no-verify origin master" \
  "echo hi && git push origin master" \
  "git push -u origin master" ; do
  OUT=$(OFLOOP_SEMANTIC_CONTEXT=1 \
        OFLOOP_RUN_ID="run-T04" \
        OFLOOP_ROLE="builder" \
        OFLOOP_CANONICAL_REPO="$T04_REPO" \
        invoke_hook "$T04_REPO" "$cmd")
  if ! (is_block_decision "$OUT" && has_forbidden_marker "$OUT"); then
    ALL_BLOCKED=no
    fail "T04: alternate push form NOT blocked: '$cmd'. out=$OUT"
  fi
done
if [[ "$ALL_BLOCKED" == "yes" ]]; then
  pass "T04: all alternate push forms blocked under builder env"
fi

# =====================================================================
# T05: alternate push forms blocked under reviewer context
# =====================================================================
echo ""
echo "=== T05: alternate push forms blocked under reviewer context ==="
T05_REPO="$SANDBOX/T05/repo"
make_repo "$T05_REPO"
ALL_BLOCKED=yes
for cmd in \
  "git push --mirror origin" \
  "git push --tags origin" \
  "git push origin master:dev" \
  "git merge --no-ff origin/master" \
  "git reset --hard origin/master" ; do
  OUT=$(OFLOOP_SEMANTIC_CONTEXT=1 \
        OFLOOP_RUN_ID="run-T05" \
        OFLOOP_ROLE="reviewer" \
        OFLOOP_CANONICAL_REPO="$T05_REPO" \
        invoke_hook "$T05_REPO" "$cmd")
  if ! (is_block_decision "$OUT" && has_forbidden_marker "$OUT"); then
    ALL_BLOCKED=no
    fail "T05: reviewer alternate form NOT blocked: '$cmd'. out=$OUT"
  fi
done
if [[ "$ALL_BLOCKED" == "yes" ]]; then
  pass "T05: all reviewer-alternate forms blocked"
fi

# =====================================================================
# T06: ordinary interactive commands unaffected when no context
# =====================================================================
echo ""
echo "=== T06: ordinary interactive commands allowed without context ==="
T06_REPO="$SANDBOX/T06/repo"
make_repo "$T06_REPO"
ALL_OK=yes
for cmd in \
  "git status" \
  "git log --oneline -1" \
  "git commit -m ok" \
  "git add ." \
  "pytest -q" \
  "npm install" \
  "python3 -c 'print(1)'" ; do
  rm -f "$SENTINEL"
  OUT=$(invoke_hook "$T06_REPO" "$cmd")
  if is_block_decision "$OUT" || has_forbidden_marker "$OUT"; then
    ALL_OK=no
    fail "T06: ordinary command wrongly blocked: '$cmd'. out=$OUT"
  fi
done
if [[ "$ALL_OK" == "yes" ]]; then
  pass "T06: all ordinary interactive commands allowed without context"
fi

# =====================================================================
# T07: stale .ownframework-loop/run-X/ does NOT activate the guard
# =====================================================================
echo ""
echo "=== T07: stale .ownframework-loop/run-X/ does NOT activate guard ==="
T07_REPO="$SANDBOX/T07/repo"
make_repo "$T07_REPO"
add_stale_run "$T07_REPO"
# Sanity: the stale run dir is present
[[ -d "$T07_REPO/.ownframework-loop/run-20260101T000000Z-stale" ]] \
  || fail "T07 fixture setup failed: stale run dir missing"
ALL_OK=yes
for cmd in "git push origin master" "git reset --hard HEAD~1" "git clean -fd" "docker compose up"; do
  OUT=$(invoke_hook "$T07_REPO" "$cmd")
  if is_block_decision "$OUT" || has_forbidden_marker "$OUT"; then
    ALL_OK=no
    fail "T07: stale run dir activated guard for: '$cmd'. out=$OUT"
  fi
done
if [[ "$ALL_OK" == "yes" ]]; then
  pass "T07: stale .ownframework-loop/run-X/ alone does not activate guard"
fi

# =====================================================================
# T08: explicit context cannot bleed from one repo to another
# =====================================================================
echo ""
echo "=== T08: explicit context cannot bleed across repos ==="
T08A_REPO="$SANDBOX/T08/A/repo"
T08B_REPO="$SANDBOX/T08/B/repo"
make_repo "$T08A_REPO" >/dev/null
make_repo "$T08B_REPO" >/dev/null
# Env declares canonical_repo=A but bash cwd=B (smuggle attempt).
OUT=$(OFLOOP_SEMANTIC_CONTEXT=1 \
      OFLOOP_RUN_ID="run-T08" \
      OFLOOP_ROLE="builder" \
      OFLOOP_CANONICAL_REPO="$T08A_REPO" \
      invoke_hook "$T08B_REPO" "git status")
if is_block_decision "$OUT" && has_forbidden_marker "$OUT"; then
  pass "T08: cross-repo env smuggling refused with OF_LOOP_BASH_FORBIDDEN"
else
  fail "T08: cross-repo env smuggling NOT refused. out=$OUT"
fi
# Reverse direction: cwd is A, env claims B → still refused.
OUT=$(OFLOOP_SEMANTIC_CONTEXT=1 \
      OFLOOP_RUN_ID="run-T08b" \
      OFLOOP_ROLE="builder" \
      OFLOOP_CANONICAL_REPO="$T08B_REPO" \
      invoke_hook "$T08A_REPO" "git push origin master")
if is_block_decision "$OUT" && has_forbidden_marker "$OUT"; then
  pass "T08: reverse cross-repo smuggling also refused"
else
  fail "T08: reverse cross-repo smuggling NOT refused. out=$OUT"
fi

# =====================================================================
# T09: supervisor-launched builder env includes markers
# =====================================================================
echo ""
echo "=== T09: hermetic_subprocess_env sets semantic markers for builder ==="
T09_REPO="$SANDBOX/T09/repo"
make_repo "$T09_REPO" >/dev/null
ENV_DUMP="$(PYTHONDONTWRITEBYTECODE=1 python3 -B - "$T09_REPO" <<'PY'
import os, sys
sys.path.insert(0, os.environ.get("PYTHONPATH", ""))
from pathlib import Path
from ownframework_loop import runtime_env
env = runtime_env.hermetic_subprocess_env(
    Path(sys.argv[1]),
    "run-20260829T-T09-builder",
    "builder",
)
print("OFLOOP_SEMANTIC_CONTEXT=" + str(env.get("OFLOOP_SEMANTIC_CONTEXT")))
print("OFLOOP_ROLE=" + str(env.get("OFLOOP_ROLE")))
print("OFLOOP_RUN_ID=" + str(env.get("OFLOOP_RUN_ID")))
print("OFLOOP_CANONICAL_REPO=" + str(env.get("OFLOOP_CANONICAL_REPO")))
PY
)"
[[ "$ENV_DUMP" == *"OFLOOP_SEMANTIC_CONTEXT=1"* ]] \
  && pass "T09: builder hermetic env sets OFLOOP_SEMANTIC_CONTEXT=1" \
  || fail "T09: builder hermetic env missing OFLOOP_SEMANTIC_CONTEXT=1. dump=$ENV_DUMP"
[[ "$ENV_DUMP" == *"OFLOOP_ROLE=builder"* ]] \
  && pass "T09: builder hermetic env sets OFLOOP_ROLE=builder" \
  || fail "T09: builder hermetic env missing OFLOOP_ROLE=builder. dump=$ENV_DUMP"
[[ "$ENV_DUMP" == *"OFLOOP_RUN_ID=run-20260829T-T09-builder"* ]] \
  && pass "T09: builder hermetic env sets OFLOOP_RUN_ID" \
  || fail "T09: builder hermetic env missing OFLOOP_RUN_ID. dump=$ENV_DUMP"
CANON="$(printf '%s\n' "$ENV_DUMP" | grep '^OFLOOP_CANONICAL_REPO=' | head -1)"
RESOLVED_CANON="${CANON#OFLOOP_CANONICAL_REPO=}"
RESOLVED_T09="$(cd "$T09_REPO" && pwd -P)"
[[ "$RESOLVED_CANON" == "$RESOLVED_T09" ]] \
  && pass "T09: OFLOOP_CANONICAL_REPO resolves to expected repo path" \
  || fail "T09: OFLOOP_CANONICAL_REPO=$RESOLVED_CANON != $RESOLVED_T09"

# =====================================================================
# T10: supervisor-launched reviewer env includes markers
# =====================================================================
echo ""
echo "=== T10: hermetic_subprocess_env sets semantic markers for reviewer ==="
T10_REPO="$SANDBOX/T10/repo"
make_repo "$T10_REPO" >/dev/null
ENV_DUMP="$(PYTHONDONTWRITEBYTECODE=1 python3 -B - "$T10_REPO" <<'PY'
import os, sys
sys.path.insert(0, os.environ.get("PYTHONPATH", ""))
from pathlib import Path
from ownframework_loop import runtime_env
env = runtime_env.hermetic_subprocess_env(
    Path(sys.argv[1]),
    "run-20260829T-T10-reviewer",
    "reviewer",
)
print("OFLOOP_SEMANTIC_CONTEXT=" + str(env.get("OFLOOP_SEMANTIC_CONTEXT")))
print("OFLOOP_ROLE=" + str(env.get("OFLOOP_ROLE")))
print("OFLOOP_RUN_ID=" + str(env.get("OFLOOP_RUN_ID")))
PY
)"
[[ "$ENV_DUMP" == *"OFLOOP_SEMANTIC_CONTEXT=1"* ]] \
  && pass "T10: reviewer hermetic env sets OFLOOP_SEMANTIC_CONTEXT=1" \
  || fail "T10: reviewer hermetic env missing OFLOOP_SEMANTIC_CONTEXT=1. dump=$ENV_DUMP"
[[ "$ENV_DUMP" == *"OFLOOP_ROLE=reviewer"* ]] \
  && pass "T10: reviewer hermetic env sets OFLOOP_ROLE=reviewer" \
  || fail "T10: reviewer hermetic env missing OFLOOP_ROLE=reviewer. dump=$ENV_DUMP"

# =====================================================================
# T11: foreground /of-loop:build + /of-loop:review retain restrictions
#      via the marker-file path
# =====================================================================
echo ""
echo "=== T11: foreground marker-file path enforces role restrictions ==="
T11_REPO="$SANDBOX/T11/repo"
make_repo "$T11_REPO"
write_marker "$T11_REPO" "builder" "run-T11-builder"
# Builder lane: push forbidden via marker path
OUT=$(invoke_hook "$T11_REPO" "git push origin master")
if is_block_decision "$OUT" && has_forbidden_marker "$OUT"; then
  pass "T11: marker-file builder push blocked"
else
  fail "T11: marker-file builder push NOT blocked. out=$OUT"
fi
# Switch to reviewer: push forbidden + commit (mutation) forbidden
clear_marker "$T11_REPO"
write_marker "$T11_REPO" "reviewer" "run-T11-reviewer"
OUT=$(invoke_hook "$T11_REPO" "git commit -m 'should be refused'")
if is_block_decision "$OUT" && has_forbidden_marker "$OUT"; then
  pass "T11: marker-file reviewer commit (mutation) blocked"
else
  fail "T11: marker-file reviewer commit NOT blocked. out=$OUT"
fi
OUT=$(invoke_hook "$T11_REPO" "git status")
if is_block_decision "$OUT"; then
  fail "T11: marker-file reviewer git status wrongly blocked. out=$OUT"
else
  pass "T11: marker-file reviewer git status allowed"
fi
# Remove marker; subsequent interactive session is unrestricted
clear_marker "$T11_REPO"
OUT=$(invoke_hook "$T11_REPO" "git push origin master")
if is_block_decision "$OUT"; then
  fail "T11: post-exit interactive push wrongly blocked. out=$OUT"
else
  pass "T11: post-exit interactive push allowed"
fi

# =====================================================================
# T12: partial / malformed / smuggling paths all fail closed
# =====================================================================
echo ""
echo "=== T12: partial + malformed contexts fail closed ==="
T12_REPO="$SANDBOX/T12/repo"
make_repo "$T12_REPO"

# T12a: OFLOOP_SEMANTIC_CONTEXT=1 with no role/run_id/canonical_repo →
# hook blocks because the role contract is incomplete (misconfigured
# supervisor).
OFLOOP_SEMANTIC_CONTEXT=1
export OFLOOP_SEMANTIC_CONTEXT
OUT=$(invoke_hook "$T12_REPO" "git status")
unset OFLOOP_SEMANTIC_CONTEXT
if is_block_decision "$OUT" && has_forbidden_marker "$OUT"; then
  pass "T12a: partial env (context flag without role) refused"
else
  fail "T12a: partial env not refused. out=$OUT"
fi

# T12b: invalid role string
OFLOOP_SEMANTIC_CONTEXT=1
OFLOOP_ROLE="hacker"
OFLOOP_RUN_ID="run-x"
OFLOOP_CANONICAL_REPO="$T12_REPO"
export OFLOOP_SEMANTIC_CONTEXT OFLOOP_ROLE OFLOOP_RUN_ID OFLOOP_CANONICAL_REPO
OUT=$(invoke_hook "$T12_REPO" "git status")
unset OFLOOP_SEMANTIC_CONTEXT OFLOOP_ROLE OFLOOP_RUN_ID OFLOOP_CANONICAL_REPO
if is_block_decision "$OUT" && has_forbidden_marker "$OUT"; then
  pass "T12b: invalid role string refused"
else
  fail "T12b: invalid role NOT refused. out=$OUT"
fi

# T12c: malformed run_id (path separators)
OFLOOP_SEMANTIC_CONTEXT=1
OFLOOP_ROLE="builder"
OFLOOP_RUN_ID="../escape/../../etc"
OFLOOP_CANONICAL_REPO="$T12_REPO"
export OFLOOP_SEMANTIC_CONTEXT OFLOOP_ROLE OFLOOP_RUN_ID OFLOOP_CANONICAL_REPO
OUT=$(invoke_hook "$T12_REPO" "git status")
unset OFLOOP_SEMANTIC_CONTEXT OFLOOP_ROLE OFLOOP_RUN_ID OFLOOP_CANONICAL_REPO
if is_block_decision "$OUT" && has_forbidden_marker "$OUT"; then
  pass "T12c: malformed run_id refused"
else
  fail "T12c: malformed run_id NOT refused. out=$OUT"
fi

# T12d: marker file with invalid role (tampered)
T12D_REPO="$SANDBOX/T12/d/repo"
make_repo "$T12D_REPO"
mkdir -p "$T12D_REPO/.ownframework-loop"
cat > "$T12D_REPO/.ownframework-loop/_semantic_context" <<EOF
{"schema":"of-loop/semantic-context/v1","run_id":"run-bad","role":"hacker","canonical_repo":"$T12D_REPO"}
EOF
OUT=$(invoke_hook "$T12D_REPO" "git status")
# A tampered marker with an invalid role must NOT be honored. The hook
# reads via role_context.read_marker which validates role ∈ {builder,reviewer}.
if is_block_decision "$OUT"; then
  fail "T12d: tampered marker with invalid role was honored. out=$OUT"
else
  pass "T12d: tampered marker with invalid role rejected; hook no-op"
fi

# T12e: marker file outside canonical_repo (smuggle via path)
T12E_REPO="$SANDBOX/T12/e/repo"
make_repo "$T12E_REPO"
# Write a marker at a different location and cd elsewhere
T12E_OTHER="$SANDBOX/T12/e/elsewhere"
mkdir -p "$T12E_OTHER/.ownframework-loop"
cat > "$T12E_OTHER/.ownframework-loop/_semantic_context" <<EOF
{"schema":"of-loop/semantic-context/v1","run_id":"run-s","role":"builder","canonical_repo":"$T12E_OTHER"}
EOF
OUT=$(invoke_hook "$T12E_REPO" "git push origin master")
# Repo T12E_REPO has no marker at its own cwd; marker at elsewhere/.ownframework-loop
# is NOT seen because the hook only looks at cwd. → no-op → push not blocked.
if is_block_decision "$OUT"; then
  fail "T12e: marker in another directory wrongly enforced. out=$OUT"
else
  pass "T12e: marker in another directory not enforced (cwd-only lookup)"
fi

echo ""
if [[ $FAIL -eq 0 ]]; then
  echo "EXECUTION_CONTEXT_CONTRACT=PASS"
  exit 0
else
  echo "EXECUTION_CONTEXT_CONTRACT=FAIL count=$FAIL"
  exit 1
fi
