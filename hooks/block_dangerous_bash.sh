#!/usr/bin/env bash
# OwnFramework Loop V1 — PreToolUse Bash guard.
#
# Receives the hook input as JSON on stdin. Emits an empty stdout and
# exit code 0 when allowed; emits a JSON decision object on stdout when
# blocking (Claude Code reads the JSON to decide).
#
# Scope: only enforces when an OWNFRAMEWORK LOOP RUN is active in the
# current working directory or one of its ancestors. Outside an active
# run, this hook is a no-op — unrelated commands are not blocked.
#
# Fail-closed on malformed JSON: if the input is not parseable, the
# hook exits with code 2 (Claude Code treats non-zero as a refusal and
# surfaces the stderr).
#
# V1 has NO operator escape hatch and NO model-controllable bypass.

set -eo pipefail

input="$(cat 2>/dev/null || true)"
if [[ -z "$input" ]]; then
  exit 2  # fail closed — no input means we cannot reason about it
fi

# Parse JSON robustly via Python (always available alongside this plugin).
parsed="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    obj = json.loads(sys.stdin.read())
except Exception as e:
    print("PARSE_ERROR", e); sys.exit(0)
print(json.dumps(obj))
' 2>/dev/null || echo "PARSE_ERROR")"

if [[ "$parsed" == "PARSE_ERROR"* ]]; then
  # Malformed JSON: fail closed.
  echo "  [of-loop hook] malformed JSON; refusing for safety" 1>&2
  exit 2
fi

tool_name="$(printf '%s' "$parsed" | python3 -c 'import sys, json; print(json.loads(sys.stdin.read()).get("tool_name", ""))' 2>/dev/null || true)"

if [[ "$tool_name" != "Bash" ]]; then
  exit 0
fi

command="$(printf '%s' "$parsed" | python3 -c 'import sys, json; print(json.loads(sys.stdin.read()).get("tool_input", {}).get("command", ""))' 2>/dev/null || true)"

if [[ -z "$command" ]]; then
  exit 0
fi

# Find cwd to scope protection to an active loop.
cwd="$(printf '%s' "$parsed" | python3 -c 'import sys, json; print(json.loads(sys.stdin.read()).get("cwd", ""))' 2>/dev/null || true)"
if [[ -z "$cwd" ]]; then
  cwd="$(pwd 2>/dev/null || true)"
fi

# Active-run detection: walk up from cwd looking for an OwnFramework Loop
# state directory.
active_run=""
if [[ -n "$cwd" ]]; then
  d="$cwd"
  while [[ -n "$d" && "$d" != "/" ]]; do
    if [[ -d "$d/.ownframework-loop" ]]; then
      active_run="$d"
      break
    fi
    parent="$(dirname "$d" 2>/dev/null)"
    if [[ -z "$parent" || "$parent" == "$d" ]]; then break; fi
    d="$parent"
  done
fi

if [[ -z "$active_run" ]]; then
  # No active loop run — the hook is a contextual guard, not a global one.
  # Unrelated commands pass through.
  exit 0
fi

# Use the Python guard library for structural classification.
result="$(CLAUDE_PLUGIN_ROOT="${OFLOOP_PLUGIN_ROOT:-$HOME/.claude/skills/of-loop}" python3 - <<PY 2>/dev/null || echo "CLASSIFY_ERROR"
import sys, os
sys.path.insert(0, os.path.join(os.environ.get("CLAUDE_PLUGIN_ROOT", "/Users/mr.mrs.london/.claude/skills/of-loop"), "lib"))
from ownframework_loop import guards
try:
    cls = guards.classify_bash_command("""$command""")
    print(cls["severity"])
    if cls["forbidden"]:
        print(";".join(cls["forbidden"]))
except Exception:
    print("CLASSIFY_ERROR")
PY
)"

if [[ "$result" == "CLASSIFY_ERROR" ]]; then
  # Classifier crash: defer to sandbox + post-pass. Do NOT block with a
  # traceback. Exit clean.
  exit 0
fi

severity="$(printf '%s' "$result" | head -n1 || true)"
if [[ "$severity" == "forbidden" ]]; then
  reasons="$(printf '%s' "$result" | tail -n +2 || true)"
  STABLE_CODE="OF_LOOP_BASH_FORBIDDEN"
  python3 - <<PY
import json, sys
print(json.dumps({
    "decision": "block",
    "reason": "[$STABLE_CODE] OwnFramework Loop: dangerous Bash command refused by textual guardrail. ${reasons:0:380}",
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": "$STABLE_CODE"
    }
}))
PY
  exit 0
fi

exit 0
