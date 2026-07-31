#!/usr/bin/env bash
# Case 43: normal unrelated Claude command not blocked by plugin hooks.
# (Hook is scoped to active runs; ordinary commands outside .ownframework-loop/
# and .worktrees/ownframework-loop/ are allowed.)

set -uo pipefail
. "$(dirname "$0")/../_helpers.sh"

# Simulate the hook on a benign command in a context with NO active run.
TMP=$(mktemp -d)
cd "$TMP"
INPUT='{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
OUT=$(echo "$INPUT" | CLAUDE_PLUGIN_ROOT=/path/to/ownframework-loop bash /path/to/ownframework-loop/hooks/block_dangerous_bash.sh)
assert_eq "$OUT" "" "benign bash command produces no block"

# Same for the protected-path hook on a file outside an active run.
INPUT2='{"tool_name":"Write","tool_input":{"file_path":"/tmp/x.txt"}}'
OUT2=$(echo "$INPUT2" | CLAUDE_PLUGIN_ROOT=/path/to/ownframework-loop bash /path/to/ownframework-loop/hooks/block_protected_paths.sh)
assert_eq "$OUT2" "" "benign write outside active run produces no block"

# Cleanup.
rm -rf "$TMP"
echo "ALL PASS"
