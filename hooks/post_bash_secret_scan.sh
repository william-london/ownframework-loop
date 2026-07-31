#!/usr/bin/env bash
# OwnFramework Loop V2 — PostToolUse Bash secret scan.
#
# Inspects the output of a Bash command for secret-shaped content using
# the REDACTED scanner. The literal matched value is NEVER persisted.
# Findings are recorded as redacted-finding records to the active run's
# EVENTS.log. Hard-severity findings are also recorded as a discrete
# event so the orchestrator can refuse the next transition.
#
# Detection-only hook. The forbidden-bash guard runs in PreToolUse.
#
# v0.3.4 hook bytecode suppression: export PYTHONDONTWRITEBYTECODE=1
# BEFORE every Python invocation so this hook does NOT write .pyc files
# into the active managed plugin cache tree. Every `python3` here is
# also invoked with `-B`.

set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

input="$(cat 2>/dev/null || true)"
if [[ -z "$input" ]]; then
  exit 0
fi

tool_name="$(printf '%s' "$input" | python3 -B -c 'import sys, json; print(json.load(sys.stdin).get("tool_name", ""))' 2>/dev/null || true)"

if [[ "$tool_name" != "Bash" ]]; then
  exit 0
fi

# Pass the tool output through stdin so the secret material never
# lands in any Python source as a string literal.
output_b64="$(printf '%s' "$input" | python3 -B -c 'import sys, json, base64; print(base64.b64encode(json.load(sys.stdin).get("tool_output", "").encode("utf-8", errors="replace")).decode("ascii"))' 2>/dev/null || true)"
if [[ -z "$output_b64" ]]; then
  exit 0
fi

if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
  exit 0
fi

CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" encoded="$output_b64" python3 -B - <<'PY' 2>/dev/null || true
import base64, json, os, sys
from pathlib import Path
sys.path.insert(0, os.path.join(os.environ["CLAUDE_PLUGIN_ROOT"], "lib"))
from ownframework_loop import secrets_v2, state as state_mod

raw = base64.b64decode(os.environ["encoded"]).decode("utf-8", errors="replace")
findings = secrets_v2.scan_text_for_redacted(raw, source="bash_output")
if not findings:
    raise SystemExit(0)

# Belt-and-suspenders: drop any field that might leak the matched value.
redacted = secrets_v2.redact_findings_for_event(findings)

# Find the active run directory by walking up from cwd.
cwd = Path(os.getcwd()).resolve(strict=False)
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
    reason=f"{len(redacted)} redacted secret-pattern match(es)",
    extras={"findings": redacted[:10]},
)

if any(f.get("severity") == "hard" for f in redacted):
    state_mod.append_event(
        run_dir.parent, run_dir.name,
        event_type="hard_secret_detected",
        old_state=None, new_state=None,
        actor="hook",
        reason="hard secret pattern in bash output",
        extras={"hard_findings": [f for f in redacted if f.get("severity") == "hard"][:5]},
    )
raise SystemExit(0)
PY

exit 0
