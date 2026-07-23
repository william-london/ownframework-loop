#!/usr/bin/env bash
# OwnFramework Loop V1 — PreToolUse Write|Edit|MultiEdit|NotebookEdit guard.
#
# Refuses writes to protected paths when an OwnFramework Loop run is active.
# "Active" means the current working directory or the target file path
# resolves to inside `.ownframework-loop/<run-id>/` or a builder/reviewer
# worktree under `.worktrees/ownframework-loop/<run-id>/`.
#
# Outside an active run, the hook allows normal Claude operation.
#
# Block decision shape:
#   {
#     "decision": "block",
#     "reason": "<human-readable>"
#   }

set -euo pipefail

input="$(cat)"
tool_name="$(printf '%s' "$input" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("tool_name", ""))' 2>/dev/null || true)"

case "$tool_name" in
  Write|Edit|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

file_path="$(printf '%s' "$input" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("tool_input", {}).get("file_path", ""))' 2>/dev/null || true)"

if [[ -z "$file_path" ]]; then
  exit 0
fi

python3 - <<PY 2>/dev/null || exit 0
import json, os, sys
sys.path.insert(0, os.path.join(os.environ.get("CLAUDE_PLUGIN_ROOT", "."), "lib"))
from pathlib import Path
from ownframework_loop import util

target = Path("""$file_path""").expanduser()
try:
    target_resolved = target.resolve(strict=False)
except Exception:
    target_resolved = target.absolute()

# Block writes to git metadata anywhere.
if any(part == ".git" for part in target_resolved.parts):
    print(json.dumps({"decision": "block",
        "reason": "OwnFramework Loop: writes to .git metadata are refused."}))
    raise SystemExit(0)

# Allow writes inside an active run directory (builder/reviewer artifacts).
# The agent and skill are the only legitimate writers.
cwd = Path.cwd().resolve(strict=False)
for parent in (cwd, *cwd.parents):
    of_root = parent / ".ownframework-loop"
    wt_root = parent / ".worktrees" / "ownframework-loop"
    if not (of_root.exists() or wt_root.exists()):
        continue
    # Allow writes inside a builder or reviewer worktree.
    try:
        if str(target_resolved).startswith(str(wt_root.resolve(strict=False)) + os.sep):
            raise SystemExit(0)
    except Exception:
        pass
    # Allow writes inside the run directory for state/receipt/verdict files.
    try:
        if str(target_resolved).startswith(str(of_root.resolve(strict=False)) + os.sep):
            # Allowed files: WORK_PACKET.md, STATE.json, BUILD_RECEIPT.json,
            # REVIEW_VERDICT.json, EVENTS.log (append only). Anything else
            # inside .ownframework-loop/ is suspicious.
            allowed_basenames = {
                "WORK_PACKET.md", "STATE.json", "BUILD_RECEIPT.json",
                "REVIEW_VERDICT.json", "EVENTS.log",
            }
            if target_resolved.name in allowed_basenames:
                raise SystemExit(0)
            print(json.dumps({"decision": "block",
                "reason": f"OwnFramework Loop: {target_resolved.name} is not an allowed run artifact."}))
            raise SystemExit(0)
    except SystemExit:
        raise
    except Exception:
        pass
    # Block direct edits to .ownframework-loop at root (root-level config is
    # human-only).
    print(json.dumps({"decision": "block",
        "reason": "OwnFramework Loop: cannot modify loop state files directly. Use the ofloop CLI."}))
    raise SystemExit(0)

# Outside an active loop: allow. (Hook is scoped to active runs by design.)
raise SystemExit(0)
PY

exit 0
