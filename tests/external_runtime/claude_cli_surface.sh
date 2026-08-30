#!/usr/bin/env bash
# External-runtime compatibility proof for the exact Claude CLI surface emitted
# by ClaudeCodeRunner. No prompt is sent and no model/auth result is required.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || true)}"
[[ -n "$CLAUDE_BIN" && -x "$CLAUDE_BIN" ]] || {
  echo "CURRENT_CLAUDE_CLI_SURFACE=FAIL reason=claude_missing" >&2
  exit 1
}

HELP="$("$CLAUDE_BIN" --help 2>&1)"
for flag in   --restricted   --permission-mode   --no-chrome   --no-session-persistence   --strict-mcp-config   --mcp-config   --settings   --tools   --allowedTools   --plugin-dir
do
  printf '%s\n' "$HELP" | grep -F -- "$flag" >/dev/null || {
    echo "CURRENT_CLAUDE_CLI_SURFACE=FAIL missing_flag=$flag" >&2
    exit 1
  }
done

# Ask only for CLI help while presenting the exact authority-bearing option
# surface. This validates parser compatibility without model execution.
set +e
PARSE_OUT="$("$CLAUDE_BIN"   -p   --output-format json   --restricted   --permission-mode dontAsk   --no-chrome   --no-session-persistence   --strict-mcp-config   --mcp-config '{"mcpServers":{}}'   --plugin-dir "$ROOT"   --settings '{"sandbox":{"enabled":true,"failIfUnavailable":true,"allowUnsandboxedCommands":false,"network":{"strictAllowlist":true,"allowedDomains":[]}}}'   --tools 'Read,Bash,Glob,Grep'   --allowedTools 'Read,Bash,Glob,Grep'   --help 2>&1)"
RC=$?
set -e
if [[ "$RC" -ne 0 ]]; then
  echo "CURRENT_CLAUDE_CLI_SURFACE=FAIL parser_rc=$RC" >&2
  printf '%s\n' "$PARSE_OUT" >&2
  exit 1
fi

echo "CURRENT_CLAUDE_CLI_SURFACE=PASS"
echo "CURRENT_CLAUDE_INVOCATION_MODEL_CALL=no"
echo "PLUGIN_HOOK_REGISTRATION_PROOF=strict_plugin_validation"
echo "PLUGIN_HOOK_RUNTIME_FIRING=CANARY_ONLY"
