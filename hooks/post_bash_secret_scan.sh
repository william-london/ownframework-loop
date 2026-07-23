#!/usr/bin/env bash
# OwnFramework Loop V1 — PostToolUse Bash secret scan.
#
# Inspects the output of a Bash command for secret-shaped content. If a
# known secret pattern is detected, logs an event to the active run's
# EVENTS.log. This is post-only; it does not refuse the call.
#
# Detection-only hook. The forbidden-bash guard runs in PreToolUse.

set -euo pipefail

input="$(cat)"
tool_name="$(printf '%s' "$input" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("tool_name", ""))' 2>/dev/null || true)"

if [[ "$tool_name" != "Bash" ]]; then
  exit 0
fi

output="$(printf '%s' "$input" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("tool_output", ""))' 2>/dev/null || true)"
if [[ -z "$output" ]]; then
  exit 0
fi

python3 - <<PY 2>/dev/null || exit 0
import os, sys
sys.path.insert(0, os.path.join(os.environ.get("CLAUDE_PLUGIN_ROOT", "."), "lib"))
from ownframework_loop import guards, state as state_mod
from pathlib import Path

findings = guards.scan_text_for_secrets("""$output""")
if not findings:
    raise SystemExit(0)

# Find the active run directory by walking up from cwd.
cwd = Path.cwd().resolve(strict=False)
run_dir = None
for parent in (cwd, *cwd.parents):
    of_root = parent / ".ownframework-loop"
    if of_root.exists() and of_root.is_dir():
        for child in sorted(of_root.iterdir()):
            if child.is_dir():
                run_dir = child
                break
        if run_dir:
            break

if run_dir is None:
    raise SystemExit(0)

state_mod.append_event(
    run_dir.parent, run_dir.name,
    event_type="secret_scan_positive",
    old_state=None, new_state=None,
    actor="hook",
    reason=f"{len(findings)} secret-pattern match(es)",
    extras={"findings": findings[:10]},
)
raise SystemExit(0)
PY

exit 0
