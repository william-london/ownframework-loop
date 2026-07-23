#!/usr/bin/env bash
# OwnFramework Loop V1 — PreToolUse Bash guard.
#
# Refuses a Bash command if any segment matches a forbidden pattern.
# Receives the hook input as JSON on stdin. Emits an empty stdout and
# exit code 0 when allowed; emits a JSON decision object on stdout and
# exits with code 0 when blocking (Claude Code reads the JSON to decide).
#
# Block decision shape:
#   {
#     "decision": "block",
#     "reason": "<human-readable>"
#   }

set -euo pipefail

input="$(cat)"
tool_name="$(printf '%s' "$input" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("tool_name", ""))' 2>/dev/null || true)"

if [[ "$tool_name" != "Bash" ]]; then
  exit 0
fi

command="$(printf '%s' "$input" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("tool_input", {}).get("command", ""))' 2>/dev/null || true)"

if [[ -z "$command" ]]; then
  exit 0
fi

# V1 has NO operator escape hatch and NO model-controllable bypass. Any future
# emergency override must be human-operated, out-of-band, and outside V1.

# Use the Python guard library for structural classification.
result="$(python3 - <<PY 2>/dev/null || true
import sys, os
sys.path.insert(0, os.path.join(os.environ.get("CLAUDE_PLUGIN_ROOT", "."), "lib"))
from ownframework_loop import guards
cls = guards.classify_bash_command("""$command""")
print(cls["severity"])
if cls["forbidden"]:
    print(";".join(cls["forbidden"]))
PY
)"

severity="$(printf '%s' "$result" | head -n1 || true)"
if [[ "$severity" == "forbidden" ]]; then
  reasons="$(printf '%s' "$result" | tail -n +2 || true)"
  python3 - <<PY
import json, sys
print(json.dumps({
    "decision": "block",
    "reason": "OwnFramework Loop: dangerous Bash command refused. ${reasons:0:400}",
}))
PY
  exit 0
fi

exit 0
