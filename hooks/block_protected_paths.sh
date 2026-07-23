#!/usr/bin/env bash
# OwnFramework Loop V1 — PreToolUse Write/Edit/MultiEdit/NotebookEdit guard.
#
# Refuses writes to paths that would mutate a protected area when an
# active OwnFramework Loop run is detected. "Active run" means the
# current working directory (or one of its ancestors) contains a
# `.ownframework-loop/` directory.
#
# Allowlist (active run):
#   Inside `.ownframework-loop/<run-id>/` — WORK_PACKET.md,
#     STATE.json, BUILD_RECEIPT.json, REVIEW_VERDICT.json, EVENTS.log,
#     LOCK, STOP. Anything else is refused.
#   Inside `.worktrees/ownframework-loop/<run-id>/builder/` — any path
#     is allowed (builder worktree is the one writable worktree).
#   Inside `.worktrees/ownframework-loop/<run-id>/reviewer/` — write
#     paths are refused (reviewer is read-only against source).
#
# Outside an active run, the hook is a no-op.
#
# Fail-closed on malformed JSON: input parse failure exits 2.

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

case "$tool_name" in
  Write|Edit|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

file_path="$(printf '%s' "$parsed" | python3 -c 'import sys, json; print(json.loads(sys.stdin.read()).get("tool_input", {}).get("file_path", ""))' 2>/dev/null || true)"

if [[ -z "$file_path" ]]; then
  exit 0
fi

cwd="$(printf '%s' "$parsed" | python3 -c 'import sys, json; print(json.loads(sys.stdin.read()).get("cwd", ""))' 2>/dev/null || true)"
if [[ -z "$cwd" ]]; then
  cwd="$(pwd 2>/dev/null || true)"
fi

# Detect active run by walking up from cwd.
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
  exit 0
fi

# Resolve file_path AND active_run to absolute, normalized form. macOS
# resolves /var/folders → /private/var/folders, so both must be canonical
# to compare correctly.
resolved_paths="$(python3 - "$file_path" "$active_run" <<'PY' 2>/dev/null || true
import sys
from pathlib import Path
fp = sys.argv[1]
ar = sys.argv[2]
try:
    print(str(Path(fp).expanduser().resolve(strict=False)))
except Exception:
    print(fp)
try:
    print(str(Path(ar).expanduser().resolve(strict=False)))
except Exception:
    print(ar)
PY
)"
abs_path="$(printf '%s\n' "$resolved_paths" | sed -n '1p')"
active_run="$(printf '%s\n' "$resolved_paths" | sed -n '2p')"

run_root="$active_run/.ownframework-loop"
wt_root="$active_run/.worktrees/ownframework-loop"

# Refuse writes to .git metadata anywhere.
if [[ "$abs_path" == *"/.git/"* || "$abs_path" == *"/.git" ]]; then
  python3 - <<PY
import json
print(json.dumps({
    "decision": "block",
    "reason": "[OF_LOOP_PROTECTED_PATH] Writes to .git metadata are refused.",
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": "OF_LOOP_GIT_METADATA"
    }
}))
PY
  exit 0
fi

ALLOWED=0
# Allow writes inside the run dir for the 5 sanctioned files.
if [[ "$abs_path" == "$run_root"/* ]]; then
  name="$(basename "$abs_path")"
  case "$name" in
    WORK_PACKET.md|STATE.json|BUILD_RECEIPT.json|REVIEW_VERDICT.json|EVENTS.log|STOP|LOCK)
      ALLOWED=1 ;;
  esac
fi

# Builder worktree is writable; reviewer worktree is read-only.
if [[ "$abs_path" == "$wt_root"/*/builder"* || "$abs_path" == "$wt_root"/*/builder/"* ]]; then
  ALLOWED=1
fi
if [[ "$abs_path" == "$wt_root"/*/reviewer" || "$abs_path" == "$wt_root"/*/reviewer/"* ]]; then
  ALLOWED=0
fi

if [[ "$ALLOWED" -eq 1 ]]; then
  exit 0
fi

python3 - <<PY
import json
print(json.dumps({
    "decision": "block",
    "reason": "[OF_LOOP_PROTECTED_PATH] OwnFramework Loop refused write to protected path while a loop run is active. Active run: $active_run. Target: $abs_path. Allowed files inside run dir: WORK_PACKET.md, BUILD_RECEIPT.json, REVIEW_VERDICT.json, STATE.json, EVENTS.log, LOCK, STOP. Builder worktree is the only writable worktree.",
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": "OF_LOOP_PROTECTED_PATH"
    }
}))
PY
exit 0
