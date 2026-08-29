#!/usr/bin/env bash
# OwnFramework Loop — PostToolUse Bash secret scan.
#
# Records redacted secret-shaped Bash output ONLY for the exact active semantic
# run. Historical .ownframework-loop directories are not evidence of an active
# role and are never searched/picked heuristically.
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

input="$(cat 2>/dev/null || true)"
[[ -n "$input" ]] || exit 0

tool_name="$(printf '%s' "$input" | python3 -B -c 'import sys,json; print(json.load(sys.stdin).get("tool_name",""))' 2>/dev/null || true)"
[[ "$tool_name" == "Bash" ]] || exit 0
[[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]] || exit 0

output_b64="$(printf '%s' "$input" | python3 -B -c 'import sys,json,base64; print(base64.b64encode(str(json.load(sys.stdin).get("tool_output","")).encode("utf-8",errors="replace")).decode("ascii"))' 2>/dev/null || true)"
[[ -n "$output_b64" ]] || exit 0
hook_cwd="$(printf '%s' "$input" | python3 -B -c 'import sys,json; print(json.load(sys.stdin).get("cwd",""))' 2>/dev/null || true)"
[[ -n "$hook_cwd" ]] || hook_cwd="$(pwd 2>/dev/null || true)"

CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" encoded="$output_b64" HOOK_CWD="$hook_cwd" python3 -B - <<'PY' 2>/dev/null || true
import base64, os, subprocess, sys
from pathlib import Path

sys.path.insert(0, os.path.join(os.environ["CLAUDE_PLUGIN_ROOT"], "lib"))
from ownframework_loop import role_context, secrets_v2, state as state_mod

cwd = Path(os.environ.get("HOOK_CWD") or ".").expanduser().resolve(strict=False)
ctx = role_context.read_env()
if ctx is not None:
    if not role_context.context_canonical_repo_matches(ctx, cwd):
        raise SystemExit(0)
else:
    # Foreground semantic lanes use the marker at the canonical Git toplevel.
    try:
        r = subprocess.run(
            ["git", "-C", str(cwd), "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=False, timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        raise SystemExit(0)
    if r.returncode != 0 or not r.stdout.strip():
        raise SystemExit(0)
    repo = Path(r.stdout.strip()).resolve(strict=False)
    ctx = role_context.read_marker(repo)
    if ctx is None or not role_context.context_canonical_repo_matches(ctx, cwd):
        raise SystemExit(0)

canonical_repo = Path(ctx["canonical_repo"]).expanduser().resolve(strict=False)
run_id = ctx["run_id"]
state_mod.validate_run_id(run_id)
if not state_mod.run_dir(canonical_repo, run_id).is_dir():
    raise SystemExit(0)

raw = base64.b64decode(os.environ["encoded"]).decode("utf-8", errors="replace")
findings = secrets_v2.scan_text_for_redacted(raw, source="bash_output")
if not findings:
    raise SystemExit(0)
redacted = secrets_v2.redact_findings_for_event(findings)

state_mod.append_event(
    canonical_repo, run_id,
    event_type="secret_scan_positive",
    old_state=None, new_state=None,
    actor="hook",
    reason=f"{len(redacted)} redacted secret-pattern match(es)",
    extras={"findings": redacted[:10]},
)
if any(f.get("severity") == "hard" for f in redacted):
    state_mod.append_event(
        canonical_repo, run_id,
        event_type="hard_secret_detected",
        old_state=None, new_state=None,
        actor="hook",
        reason="hard secret pattern in bash output",
        extras={"hard_findings": [f for f in redacted if f.get("severity") == "hard"][:5]},
    )
PY
exit 0
