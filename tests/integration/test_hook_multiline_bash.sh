#!/usr/bin/env bash
# v0.3.6 (A3-001 / Repair 6 carry-over): multiline bash input guard.
#
# DATA-ONLY: forbidden tokens are decoded via Python chr()/string
# concatenation at runtime and treated purely as JSON string data. The
# test NEVER executes them via eval/source/bash -c/sh -c. Behavioral
# execution is reserved for the real installed/staged hook binary,
# which we drive by feeding JSON on stdin.
#
# The test asserts:
#   - the hook exit status (allowed -> 0 empty stdout; blocked -> 0 + JSON)
#   - the structured block decision when forbidden
#   - a fake-target sentinel executable on PATH is never invoked
#   - harmless controls remain allowed
#   - no Python tracebacks or shell errors appear in hook output
#   - repeated hook execution produces zero bytecode paths

set -euo pipefail

HERE="${OFLOOP_TEST_HERE:-$(cd "$(dirname "$0")" && pwd)}"
ROOT="${OFLOOP_TEST_ROOT:-$(cd "$HERE/../.." && pwd)}"
LIB="$ROOT/lib"
HOOK="$ROOT/hooks/block_dangerous_bash.sh"
export PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$LIB"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

# ----------------------------------------------------------------------
# Fixture scaffolding
# ----------------------------------------------------------------------
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
SENTINEL="$SANDBOX/sentinel.invoked"

write_fake() {
  local name="$1"
  cat > "$SANDBOX/$name" <<FAKE_EOF
#!/usr/bin/env bash
touch "$SENTINEL"
exit 99
FAKE_EOF
  chmod +x "$SANDBOX/$name"
}
for t in git docker ssh; do write_fake "$t"; done

# Stage an active semantic lane so the hook does not bypass as a no-op.
# v0.6.1: provenance is the marker file `.ownframework-loop/_semantic_context`
# at the canonical repo root, NOT the mere presence of an `.ownframework-loop/`
# directory. The old path-based heuristic was over-scoped — ordinary
# interactive Claude sessions inside a repo that owns historical run state
# are not semantic workers.
ACTIVE_ROOT="$SANDBOX/active-loop"
mkdir -p "$ACTIVE_ROOT/.ownframework-loop/run-TEST"
echo '{"state":"BUILDING"}' > "$ACTIVE_ROOT/.ownframework-loop/run-TEST/STATE.json"
# Write the v0.6.1 marker file establishing semantic-worker context for
# this test fixture. Without this marker, the hook is a no-op and the
# FORBIDDEN cases below would all be classified as allowed.
OFLOOP_LIB="$LIB" python3 -B - "$ACTIVE_ROOT" <<'PY'
import json, sys, os
sys.path.insert(0, os.environ["OFLOOP_LIB"])
from ownframework_loop import role_context
ctx = role_context.enter_semantic_role(
    canonical_repo=sys.argv[1],
    run_id="run-TEST",
    role="builder",
)
print("MARKER_OK", json.dumps(ctx))
PY

# ----------------------------------------------------------------------
# Case generator: emits one JSON line per case via Python. Each line is
#   {"label": str, "cmd": str, "forbidden": bool}
# The python program is the SINGLE source of forbidden-token decoding.
# Bash consumes the JSON stream line-by-line. It NEVER eval/source.
# ----------------------------------------------------------------------
CASES_FILE="$SANDBOX/cases.jsonl"
PYTHONDONTWRITEBYTECODE=1 python3 -B - > "$CASES_FILE" <<'PYTHON_PROGRAM_END'
import json

TOK = {
    "GT":"git","PS":"push","RS":"reset","HR":"--hard","CL":"clean",
    "FD":"-fd","MG":"merge","RM":"remote","AD":"add","DC":"docker",
    "CP":"compose","UP":"up","EC":"echo","NL":"\n","SP":" ",
    "SC":";","DOLLAR":"$","LPAREN":"(","RPAREN":")",
    "AND":"&&","OR":"||",
}
RAW = {
    "HARM":"harmless","A":"a","CMT":"#","CMNT":"cmnt","FOO":"foo",
    "ORI":"origin","MAS":"master","HI":"hi","DONE":"done",
    "ECHIHI":"echo hi","SSH":"ssh example.invalid","LS":"ls -la",
    "STATUS":"status","B":"b",
}
def asm(parts):
    out = []
    for p in parts:
        if p in TOK: out.append(TOK[p])
        elif p in RAW: out.append(RAW[p])
        else: raise KeyError(p)
    return "".join(out)

FORBIDDEN = [
    ("variant 1: hidden push on second line",
     ["EC","SP","HARM","NL","GT","SP","PS","SP","ORI","SP","MAS"]),
    ("variant 2: push after comment-only line",
     ["EC","SP","A","NL","CMT","SP","CMNT","NL","GT","SP","PS"]),
    ("variant 3: reset hard on second line",
     ["EC","SP","A","NL","GT","SP","RS","SP","HR"]),
    ("variant 4: clean fd on second line",
     ["EC","SP","A","NL","GT","SP","CL","SP","FD"]),
    ("variant 5: merge on second line",
     ["EC","SP","A","NL","GT","SP","MG","SP","FOO"]),
    ("variant 6: remote add on second line",
     ["EC","SP","A","NL","GT","SP","RM","SP","AD","SP","ORI","SP","FOO"]),
    ("variant 7: docker push on second line",
     ["EC","SP","A","NL","DC","SP","PS"]),
    ("variant 8: push on second line (echo+a)",
     ["EC","SP","A","NL","GT","SP","PS"]),
    ("variant 9: push after &&",
     ["EC","SP","HI","SP","AND","SP","GT","SP","PS"]),
    ("variant 10: push after ||",
     ["EC","SP","HI","SP","OR","SP","GT","SP","PS"]),
    ("variant 11: uncommissioned docker compose is forbidden",
     ["DC","SP","CP","SP","UP"]),
]
ALLOWED = [
    ("control 0: ssh on second line (classifier allows ssh alone)",
     ["EC","SP","A","NL","SSH"]),
    ("control 1: harmless multi-statement (semicolon)",
     ["EC","SP","A","SC","EC","SP","B"]),
    ("control 2: plain ls", ["LS"]),
    ("control 3: plain git status", ["GT","SP","STATUS"]),
    ("control 4: two-line harmless",
     ["EC","SP","A","NL","EC","SP","B"]),
    ("control 5: harmless && chain",
     ["EC","SP","HI","SP","AND","SP","EC","SP","DONE"]),
    ("control 6: harmless command substitution",
     ["EC","SP","DOLLAR","LPAREN","ECHIHI","RPAREN"]),
]

for label, parts in FORBIDDEN + ALLOWED:
    cmd = asm(parts)
    print(json.dumps({"label": label, "cmd": cmd, "forbidden": True if (label, parts) in FORBIDDEN else False}))
PYTHON_PROGRAM_END

# Sanity: case file exists and is non-empty.
if [[ ! -s "$CASES_FILE" ]]; then
  fail "case generator produced empty cases.jsonl"
  exit 1
fi
pass "case generator emitted $(wc -l < "$CASES_FILE" | tr -d ' ') case lines"

# ----------------------------------------------------------------------
# Run hook against each case. Build JSON payload via Python json.dumps
# (safe serializer). Pipe to hook stdin. Inspect exit + stdout.
# ----------------------------------------------------------------------
make_payload() {
  local cmd="$1"
  PYTHONDONTWRITEBYTECODE=1 python3 -B -c '
import json, sys
print(json.dumps({
    "tool_name": "Bash",
    "tool_input": {"command": sys.argv[1]},
    "cwd": sys.argv[2],
}))
' "$cmd" "$ACTIVE_ROOT"
}

invoke_hook() {
  local payload="$1"
  local out rc
  set +e
  out="$(printf '%s' "$payload" | CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$SANDBOX:$PATH" bash "$HOOK" 2>&1)"
  rc=$?
  set -e
  printf '%s\t%s\n' "$rc" "$out"
}

while IFS= read -r line; do
  rm -f "$SENTINEL"
  info="$(PYTHONDONTWRITEBYTECODE=1 python3 -B -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])))' "$line")"
  label="$(PYTHONDONTWRITEBYTECODE=1 python3 -B -c 'import json,sys; print(json.loads(sys.argv[1])["label"])' "$info")"
  cmd="$(PYTHONDONTWRITEBYTECODE=1 python3 -B -c 'import json,sys; print(json.loads(sys.argv[1])["cmd"])' "$info")"
  forbidden="$(PYTHONDONTWRITEBYTECODE=1 python3 -B -c 'import json,sys; print(json.loads(sys.argv[1])["forbidden"])' "$info")"
  payload="$(make_payload "$cmd")"
  IFS=$'\t' read -r rc out < <(invoke_hook "$payload")
  if [[ -e "$SENTINEL" ]]; then
    fail "$label -- fake forbidden target was reached (sentinel exists)"
    continue
  fi
  if [[ "$rc" -ne 0 ]]; then
    fail "$label -- hook exited $rc (expected 0). output=$out"
    continue
  fi
  if [[ "$forbidden" == "True" ]]; then
    if [[ "$out" != *'"decision": "block"'* ]]; then
      fail "$label -- hook did not block forbidden command. output=$out"
      continue
    fi
    if [[ "$out" != *"OF_LOOP_BASH_FORBIDDEN"* ]]; then
      fail "$label -- hook output missing OF_LOOP_BASH_FORBIDDEN. output=$out"
      continue
    fi
  else
    if [[ "$out" == *'"decision": "block"'* ]]; then
      fail "$label -- hook wrongly blocked allowed command. output=$out"
      continue
    fi
  fi
  pass "$label"
done < "$CASES_FILE"

# Docker becomes valid local engineering only when the supervisor has resolved
# the privileged broker capability for this exact semantic pass.
docker_payload="$(make_payload "docker compose up")"
set +e
docker_out="$(
  printf '%s' "$docker_payload" |
  OFLOOP_PRIVILEGED_CAPABILITIES="container.docker"   CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$SANDBOX:$PATH" bash "$HOOK" 2>&1
)"
docker_rc=$?
set -e
if [[ "$docker_rc" -ne 0 || "$docker_out" == *'"decision": "block"'* ]]; then
  fail "commissioned docker compose capability should be admitted. output=$docker_out"
else
  pass "commissioned docker compose capability admitted"
fi

# Common wrapper forms must not bypass the capability requirement.
for wrapped in   'command docker compose up'   'env FOO=bar docker compose up'   "sh -c 'docker compose up'"
do
  wrapped_payload="$(make_payload "$wrapped")"
  IFS=# ----------------------------------------------------------------------
STAGING_ROOT="$SANDBOX/staged_plugin"
mkdir -p "$STAGING_ROOT/lib/ownframework_loop" "$STAGING_ROOT/hooks"
cp "$ROOT/lib/ownframework_loop/"*.py "$STAGING_ROOT/lib/ownframework_loop/"
cp "$ROOT/hooks/"*.sh "$STAGING_ROOT/hooks/"
chmod +x "$STAGING_ROOT/hooks/"*.sh
mkdir -p "$STAGING_ROOT/.ownframework-loop/run-TEST"
echo '{"state":"BUILDING"}' > "$STAGING_ROOT/.ownframework-loop/run-TEST/STATE.json"

for i in 1 2 3 4 5 6 7 8 9 10; do
  payload="$(make_payload "ls -la")"
  printf '%s' "$payload" | CLAUDE_PLUGIN_ROOT="$STAGING_ROOT" PATH="$SANDBOX:$PATH" bash "$STAGING_ROOT/hooks/block_dangerous_bash.sh" >/dev/null 2>&1 || true
done
bc_count=$(find "$STAGING_ROOT" \
  \( -type d -name "__pycache__" -o \
     -type f -name "*.pyc" -o \
     -type f -name "*.pyo" -o \
     -type f -name "*.pyd" \) -print 2>/dev/null | wc -l | tr -d " ")
if [[ "$bc_count" -ne 0 ]]; then
  fail "bytecode regression: $bc_count bytecode paths created after 10 hook runs"
else
  pass "bytecode regression: 0 bytecode paths after 10 hook runs"
fi

if [[ "$FAIL" -gt 0 ]]; then
  echo "OF_LOOP_MULTILINE_GUARD=FAIL count=$FAIL"
  exit 1
fi
echo "OF_LOOP_MULTILINE_GUARD=PASS"
echo "MULTILINE_BASH_TESTS=PASS"
\t' read -r wrapped_rc wrapped_out < <(invoke_hook "$wrapped_payload")
  if [[ "$wrapped_rc" -ne 0 || "$wrapped_out" != *'"decision": "block"'* ]]; then
    fail "uncommissioned Docker wrapper escaped capability gate: $wrapped output=$wrapped_out"
  else
    pass "uncommissioned Docker wrapper blocked: $wrapped"
  fi
done

# Registry mutation remains forbidden even when the local broker capability is
# present.
push_payload="$(make_payload "docker push example.invalid/image:latest")"
set +e
push_out="$(
  printf '%s' "$push_payload" |
  OFLOOP_PRIVILEGED_CAPABILITIES="container.docker"   CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$SANDBOX:$PATH" bash "$HOOK" 2>&1
)"
push_rc=$?
set -e
if [[ "$push_rc" -ne 0 || "$push_out" != *'"decision": "block"'* ]]; then
  fail "docker push must remain forbidden with container capability. output=$push_out"
else
  pass "docker push remains forbidden with container capability"
fi

# ----------------------------------------------------------------------
# Repeated hook execution produces zero bytecode paths
# ----------------------------------------------------------------------
STAGING_ROOT="$SANDBOX/staged_plugin"
mkdir -p "$STAGING_ROOT/lib/ownframework_loop" "$STAGING_ROOT/hooks"
cp "$ROOT/lib/ownframework_loop/"*.py "$STAGING_ROOT/lib/ownframework_loop/"
cp "$ROOT/hooks/"*.sh "$STAGING_ROOT/hooks/"
chmod +x "$STAGING_ROOT/hooks/"*.sh
mkdir -p "$STAGING_ROOT/.ownframework-loop/run-TEST"
echo '{"state":"BUILDING"}' > "$STAGING_ROOT/.ownframework-loop/run-TEST/STATE.json"

for i in 1 2 3 4 5 6 7 8 9 10; do
  payload="$(make_payload "ls -la")"
  printf '%s' "$payload" | CLAUDE_PLUGIN_ROOT="$STAGING_ROOT" PATH="$SANDBOX:$PATH" bash "$STAGING_ROOT/hooks/block_dangerous_bash.sh" >/dev/null 2>&1 || true
done
bc_count=$(find "$STAGING_ROOT" \
  \( -type d -name "__pycache__" -o \
     -type f -name "*.pyc" -o \
     -type f -name "*.pyo" -o \
     -type f -name "*.pyd" \) -print 2>/dev/null | wc -l | tr -d " ")
if [[ "$bc_count" -ne 0 ]]; then
  fail "bytecode regression: $bc_count bytecode paths created after 10 hook runs"
else
  pass "bytecode regression: 0 bytecode paths after 10 hook runs"
fi

if [[ "$FAIL" -gt 0 ]]; then
  echo "OF_LOOP_MULTILINE_GUARD=FAIL count=$FAIL"
  exit 1
fi
echo "OF_LOOP_MULTILINE_GUARD=PASS"
echo "MULTILINE_BASH_TESTS=PASS"
