#!/usr/bin/env bash
# OwnFramework Loop V2 — External Action Guard.
#
# During an active OwnFramework Loop run, this hook blocks tool calls
# that would have external side effects: emails, SMS, DMs, calendar
# events, payments, GitHub PR/merge/push, deploys, destructive cloud
# changes, customer-system mutations.
#
# It permits:
#   - Bash (validated by block_dangerous_bash.sh)
#   - WebSearch / WebFetch (read-only)
#   - Read / Glob / Grep (always)
#   - read-only MCP integrations (search/list/get/status/inspect)
#   - local repository tools
#   - local test tools
#   - local compilers / package managers
#   - the dedicated ofloop CLI
#
# Policy is implemented in lib/ownframework_loop/external_action.py
# so the same classification can be unit-tested and reused by the
# orchestrator.

set -eo pipefail

input="$(cat 2>/dev/null || true)"
if [[ -z "$input" ]]; then
  exit 2
fi

parsed="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    obj = json.loads(sys.stdin.read())
except Exception as e:
    print("PARSE_ERROR", e); sys.exit(0)
print(json.dumps(obj))
' 2>/dev/null || echo "PARSE_ERROR")"

if [[ "$parsed" == "PARSE_ERROR"* ]]; then
  echo "  [of-loop hook] malformed JSON; refusing for safety" 1>&2
  exit 2
fi

tool_name="$(printf '%s' "$parsed" | python3 -c 'import sys, json; print(json.loads(sys.stdin.read()).get("tool_name", ""))' 2>/dev/null || true)"

if [[ -z "$tool_name" ]]; then
  exit 0
fi

# Active run detection.
cwd="$(printf '%s' "$parsed" | python3 -c 'import sys, json; print(json.loads(sys.stdin.read()).get("cwd", ""))' 2>/dev/null || true)"
if [[ -z "$cwd" ]]; then
  cwd="$(pwd 2>/dev/null || true)"
fi

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

# Outside an active run: no-op.
if [[ -z "$active_run" ]]; then
  exit 0
fi

# Resolve plugin root.
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
  echo "  [of-loop hook] CLAUDE_PLUGIN_ROOT not provided; refusing for safety" 1>&2
  exit 2
fi

# Encode arguments safely via base64 to avoid shell quoting.
encoded="$(printf '%s' "$parsed" | base64)"

decision="$(CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" encoded_payload="$encoded" encoded_tool="$tool_name" python3 - <<'PY' 2>/dev/null || echo "ALLOW"
import sys, os, base64, json
sys.path.insert(0, os.path.join(os.environ["CLAUDE_PLUGIN_ROOT"], "lib"))
from ownframework_loop import external_action
try:
    payload = json.loads(base64.b64decode(os.environ["encoded_payload"]).decode("utf-8", errors="replace"))
    tool = payload.get("tool_name", "")
    decision = external_action.classify_tool_call(
        tool_name=tool,
        tool_input=payload.get("tool_input", {}) or {},
        active_run=os.environ.get("active_run", ""),
    )
    print(decision)
except Exception:
    print("ALLOW_WITH_DIAGNOSTIC")
PY
)"

if [[ "$decision" == "ALLOW" ]]; then
  exit 0
fi

if [[ "$decision" == "ALLOW_WITH_DIAGNOSTIC" ]]; then
  # Redacted diagnostic to a log file; do not block.
  python3 - "$tool_name" "$active_run" <<'PY' 2>/dev/null || true
import sys, os
log_dir = os.path.join(os.environ.get("CLAUDE_PLUGIN_ROOT", ""), "logs")
os.makedirs(log_dir, exist_ok=True)
log_path = os.path.join(log_dir, "external_action_diagnostics.log")
with open(log_path, "a", encoding="utf-8") as f:
    f.write(f"tool={sys.argv[1]} active_run={sys.argv[2]} decision=ALLOW_WITH_DIAGNOSTIC\n")
PY
  exit 0
fi

# Otherwise: emit a block decision.
code="$(printf '%s' "$decision" | head -n1 | tr -d ' ')"
reason="$(printf '%s' "$decision" | tail -n +2)"
# Pass reason via base64 to avoid shell quote injection.
reason_b64="$(printf '%s' "$reason" | base64)"
reason_b64="$reason_b64" code="$code" python3 - <<'PY'
import json, os, base64
reason = base64.b64decode(os.environ["reason_b64"]).decode("utf-8", errors="replace")
code = os.environ["code"]
print(json.dumps({
    "decision": "block",
    "reason": f"[OF_LOOP_EXTERNAL_ACTION] {reason}",
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": code or "OF_LOOP_EXTERNAL_ACTION",
    }
}))
PY
exit 0
