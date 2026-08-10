#!/usr/bin/env bash
# OwnFramework Loop — PreToolUse Bash guard.
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
#
# v0.3.4 hook bytecode suppression: export PYTHONDONTWRITEBYTECODE=1
# BEFORE every Python invocation so this hook does NOT write .pyc files
# into the active managed plugin cache tree. Every `python3` here is
# also invoked with `-B` for belt-and-braces correctness when this hook
# is launched in a child shell that has cleared the env.

set -eo pipefail
export PYTHONDONTWRITEBYTECODE=1

input="$(cat 2>/dev/null || true)"
if [[ -z "$input" ]]; then
  exit 2  # fail closed — no input means we cannot reason about it
fi

# Parse JSON robustly via Python (always available alongside this plugin).
parsed="$(printf '%s' "$input" | python3 -B -c '
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

tool_name="$(printf '%s' "$parsed" | python3 -B -c 'import sys, json; print(json.loads(sys.stdin.read()).get("tool_name", ""))' 2>/dev/null || true)"

if [[ "$tool_name" != "Bash" ]]; then
  exit 0
fi

command="$(printf '%s' "$parsed" | python3 -B -c 'import sys, json; print(json.loads(sys.stdin.read()).get("tool_input", {}).get("command", ""))' 2>/dev/null || true)"

if [[ -z "$command" ]]; then
  exit 0
fi

# Find cwd to scope protection to an active loop.
cwd="$(printf '%s' "$parsed" | python3 -B -c 'import sys, json; print(json.loads(sys.stdin.read()).get("cwd", ""))' 2>/dev/null || true)"
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
# Encode the command as base64 to safely embed it in the Python source.
#
# F-001 closure: refuse to silently fall back to a hardcoded operator
# installation path. If CLAUDE_PLUGIN_ROOT (or OFLOOP_PLUGIN_ROOT) is
# unset, fail closed with a clear operator action.
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" && -z "${OFLOOP_PLUGIN_ROOT:-}" ]]; then
  echo "  [of-loop hook] CLAUDE_PLUGIN_ROOT not provided by Claude Code and OFLOOP_PLUGIN_ROOT not set in environment; refusing for safety" 1>&2
  exit 2
fi
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-${OFLOOP_PLUGIN_ROOT}}"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
encoded_command="$(printf '%s' "$command" | base64)"
result="$(python3 -B - "$encoded_command" 2>/dev/null <<'PY' || echo "CLASSIFY_ERROR"
import sys, os, base64
sys.path.insert(0, os.path.join(os.environ.get("CLAUDE_PLUGIN_ROOT", ""), "lib"))
from ownframework_loop import guards
try:
    cmd = base64.b64decode(sys.argv[1]).decode("utf-8", errors="replace")
    cls = guards.classify_bash_command(cmd)
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
  reasons="${reasons:0:380}"
  # Pass reasons via stdin (as base64) so shell quotes in the matched
  # command cannot break Python source parsing.
  reasons_b64="$(printf '%s' "$reasons" | base64)"
  reasons_b64="$reasons_b64" python3 -B - <<'PY'
import json, sys, base64, os
reasons = base64.b64decode(os.environ["reasons_b64"]).decode("utf-8", errors="replace")
print(json.dumps({
    "decision": "block",
    "reason": "[OF_LOOP_BASH_FORBIDDEN] OwnFramework Loop: dangerous Bash command refused by textual guardrail. " + reasons,
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": "OF_LOOP_BASH_FORBIDDEN"
    }
}))
PY
  exit 0
fi

exit 0
