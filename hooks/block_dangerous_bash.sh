#!/usr/bin/env bash
# OwnFramework Loop — PreToolUse Bash guard.
#
# Receives the hook input as JSON on stdin. Emits an empty stdout and
# exit code 0 when allowed; emits a JSON decision object on stdout when
# blocking (Claude Code reads the JSON to decide).
#
# v0.6.1 EXECUTION-CONTEXT CONTRACT
# =================================
#
# The guard is ONLY active when the current bash invocation is provably
# inside an OwnFramework Loop semantic lane. Provenance is determined by
# TWO independent sources, either of which establishes semantic-worker
# context:
#
#   (a) ENVIRONMENT MARKERS — set by the Loop supervisor when launching a
#       Claude Code worker subprocess:
#         OFLOOP_SEMANTIC_CONTEXT=1
#         OFLOOP_RUN_ID=<exact>
#         OFLOOP_ROLE=builder|reviewer
#         OFLOOP_CANONICAL_REPO=<resolved repo path>
#
#   (b) MARKER FILE — `.ownframework-loop/_semantic_context` in the cwd's
#       canonical repo root. The foreground `/of-loop:build` and
#       `/of-loop:review` skills (and any other supported foreground
#       builder/reviewer lane) call `ofloop role enter` to write this
#       file on lane entry and `ofloop role exit` to remove it on lane
#       exit. The marker is JSON with the same schema as (a).
#
# OUTSIDE both provenances the hook is a NO-OP. A normal operator-
# authorized interactive Claude session inside a repository that happens
# to contain `.ownframework-loop/run-<id>/` state from a historical run
# is NOT a semantic worker and is NOT scoped by this guard.
#
# INSIDE an active semantic lane the guard refuses:
#   * any role: external-action patterns (git push, git push --no-verify,
#     git merge, git reset --hard, git clean -fd, git remote add,
#     docker compose up/down/restart, operator-blocked SSH targets,
#     operator-blocked executables) — see FORBIDDEN_PATTERNS;
#   * reviewer role: ANY command outside the read-only allowlist
#     (REVIEWER_ALLOWLIST_PATTERNS) — read-only inspection of the
#     candidate SHA only.
#
# Anti-smuggling: when (a) is used, the hook resolves the cwd's git
# toplevel and compares it to the env-declared OFLOOP_CANONICAL_REPO. A
# context declared for repo A cannot be used to enforce restrictions on
# bash commands running in repo B.
#
# Fail-closed on malformed JSON, missing CLAUDE_PLUGIN_ROOT /
# OFLOOP_PLUGIN_ROOT, partial environment markers, marker file with
# invalid role or run_id, or unparseable role.
#
# V1 has NO operator escape hatch and NO model-controllable bypass.
# The hook does NOT weaken semantic-worker restrictions and does NOT
# grant push/merge/deploy to unattended workers.
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
  exit 2
fi

parsed="$(printf '%s' "$input" | python3 -B -c '
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

tool_name="$(printf '%s' "$parsed" | python3 -B -c 'import sys, json; print(json.loads(sys.stdin.read()).get("tool_name", ""))' 2>/dev/null || true)"

if [[ "$tool_name" != "Bash" ]]; then
  exit 0
fi

command="$(printf '%s' "$parsed" | python3 -B -c 'import sys, json; print(json.loads(sys.stdin.read()).get("tool_input", {}).get("command", ""))' 2>/dev/null || true)"

if [[ -z "$command" ]]; then
  exit 0
fi

cwd="$(printf '%s' "$parsed" | python3 -B -c 'import sys, json; print(json.loads(sys.stdin.read()).get("cwd", ""))' 2>/dev/null || true)"
if [[ -z "$cwd" ]]; then
  cwd="$(pwd 2>/dev/null || true)"
fi

if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" && -z "${OFLOOP_PLUGIN_ROOT:-}" ]]; then
  echo "  [of-loop hook] CLAUDE_PLUGIN_ROOT not provided by Claude Code and OFLOOP_PLUGIN_ROOT not set in environment; refusing for safety" 1>&2
  exit 2
fi
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-${OFLOOP_PLUGIN_ROOT}}"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# === v0.6.1 EXECUTION-CONTEXT DETECTION ===
# Provenance: env-marker (supervisor-launched) or marker-file (foreground
# lane). Outside both, the hook is a no-op.
encoded_command_b64="$(printf '%s' "$command" | base64)"
encoded_cwd_b64="$(printf '%s' "$cwd" | base64)"
context="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" python3 -B - "$encoded_command_b64" "$encoded_cwd_b64" 2>/dev/null <<'PY' || echo "CTX_ERROR"
import json, sys, base64, os
try:
    cmd = base64.b64decode(sys.argv[1]).decode("utf-8", errors="replace")
    cwd = base64.b64decode(sys.argv[2]).decode("utf-8", errors="replace")
except Exception:
    print("CTX_ERROR"); sys.exit(0)
sys.path.insert(0, os.path.join(os.environ.get("CLAUDE_PLUGIN_ROOT", ""), "lib"))
from ownframework_loop import role_context
ctx = None
provenance = None
try:
    env_ctx = role_context.read_env()
except Exception:
    env_ctx = None
# Partial env: OFLOOP_SEMANTIC_CONTEXT=1 is set but role/run_id/
# canonical_repo are missing or invalid. Fail closed: this is a
# misconfigured supervisor, NOT a no-context session. Silently
# downgrading to no-context would let the supervisor effectively
# disable its own role contract.
if role_context.is_env_partial():
    print(json.dumps({"status": "partial_env_refused"}))
    sys.exit(0)
if env_ctx is not None:
    if role_context.context_canonical_repo_matches(env_ctx, cwd or "."):
        ctx = env_ctx
        provenance = "env"
    else:
        print(json.dumps({"status": "smuggle_refused", "expected": env_ctx.get("canonical_repo"), "cwd": cwd}))
        sys.exit(0)
if ctx is None and cwd:
    from pathlib import Path
    d = Path(cwd).expanduser().resolve(strict=False)
    # Marker lookup: check cwd only (no ancestor walk, no git rev-parse).
    # The foreground `/of-loop:build` and `/of-loop:review` skills run
    # from the canonical repo root, so cwd IS the repo root when the
    # marker is present. A worker running with cwd = a per-pass worktree
    # is inside a supervisor-spawned ClaudeCodeRunner subprocess that
    # already has env markers set, so it never reaches this branch.
    # Keeping the lookup narrow avoids invoking `git` (which would be
    # PATH-lookup-vulnerable in test fixtures) and keeps the marker
    # search O(1).
    marker = d / ".ownframework-loop" / "_semantic_context"
    if marker.is_file():
        m_ctx = role_context.read_marker(d)
        if m_ctx is not None:
            ctx = m_ctx
            provenance = "marker"
if ctx is None:
    print(json.dumps({"status": "no_context"}))
    sys.exit(0)
print(json.dumps({"status": "active", "provenance": provenance, **ctx}))
PY
)"

if [[ "$context" == "CTX_ERROR" ]]; then
  exit 0
fi

status="$(printf '%s' "$context" | python3 -B -c 'import json,sys; print(json.loads(sys.stdin.read()).get("status",""))' 2>/dev/null || true)"

if [[ "$status" == "smuggle_refused" ]]; then
  expected="$(printf '%s' "$context" | python3 -B -c 'import json,sys; print(json.loads(sys.stdin.read()).get("expected",""))' 2>/dev/null || true)"
  cwd_out="$(printf '%s' "$context" | python3 -B -c 'import json,sys; print(json.loads(sys.stdin.read()).get("cwd",""))' 2>/dev/null || true)"
  reason="[OF_LOOP_BASH_FORBIDDEN] OwnFramework Loop: semantic-context env markers declared for repo ${expected} but bash cwd is ${cwd_out}; refusing to enforce role restrictions across repos."
  reasons_b64="$(printf '%s' "$reason" | base64)"
  reasons_b64="$reasons_b64" python3 -B - <<'PY'
import json, sys, base64, os
print(json.dumps({
    "decision": "block",
    "reason": base64.b64decode(os.environ["reasons_b64"]).decode("utf-8"),
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": "OF_LOOP_BASH_FORBIDDEN"
    }
}))
PY
  exit 0
fi

if [[ "$status" == "partial_env_refused" ]]; then
  reason="[OF_LOOP_BASH_FORBIDDEN] OwnFramework Loop: semantic context declared via OFLOOP_SEMANTIC_CONTEXT=1 but OFLOOP_ROLE/OFLOOP_RUN_ID/OFLOOP_CANONICAL_REPO are missing or invalid. The misconfigured supervisor must be fixed; this hook will not honor a partial role contract."
  reasons_b64="$(printf '%s' "$reason" | base64)"
  reasons_b64="$reasons_b64" python3 -B - <<'PY'
import json, sys, base64, os
print(json.dumps({
    "decision": "block",
    "reason": base64.b64decode(os.environ["reasons_b64"]).decode("utf-8"),
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": "OF_LOOP_BASH_FORBIDDEN"
    }
}))
PY
  exit 0
fi

if [[ "$status" != "active" ]]; then
  # No semantic context: NO-OP. General Claude/native permission model applies.
  exit 0
fi

role="$(printf '%s' "$context" | python3 -B -c 'import json,sys; print(json.loads(sys.stdin.read()).get("role",""))' 2>/dev/null || true)"
run_id="$(printf '%s' "$context" | python3 -B -c 'import json,sys; print(json.loads(sys.stdin.read()).get("run_id",""))' 2>/dev/null || true)"
canon_repo="$(printf '%s' "$context" | python3 -B -c 'import json,sys; print(json.loads(sys.stdin.read()).get("canonical_repo",""))' 2>/dev/null || true)"
export OFLOOP_SEMANTIC_CONTEXT=1
export OFLOOP_RUN_ID="$run_id"
export OFLOOP_ROLE="$role"
export OFLOOP_CANONICAL_REPO="$canon_repo"

result="$(python3 -B - "$encoded_command_b64" 2>/dev/null <<'PY' || echo "CLASSIFY_ERROR"
import sys, os, base64
sys.path.insert(0, os.path.join(os.environ.get("CLAUDE_PLUGIN_ROOT", ""), "lib"))
from ownframework_loop import guards
try:
    cmd = base64.b64decode(sys.argv[1]).decode("utf-8", errors="replace")
    cls = guards.classify_bash_command_with_env(cmd)
    print(cls["severity"])
    if cls["forbidden"]:
        print(";".join(cls["forbidden"]))
    if cls.get("partial_env"):
        print("PARTIAL_ENV")
except Exception:
    print("CLASSIFY_ERROR")
PY
)"

if [[ "$result" == "CLASSIFY_ERROR" ]]; then
  exit 0
fi

severity="$(printf '%s' "$result" | head -n1 || true)"
partial_env_marker="$(printf '%s' "$result" | grep -c '^PARTIAL_ENV$' || true)"
reasons="$(printf '%s' "$result" | grep -v '^PARTIAL_ENV$' | tail -n +2 || true)"
reasons="${reasons:0:380}"

if [[ "$severity" == "forbidden" ]]; then
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

if [[ "$partial_env_marker" -gt 0 ]]; then
  reason="[OF_LOOP_BASH_FORBIDDEN] OwnFramework Loop: semantic context declared via OFLOOP_SEMANTIC_CONTEXT=1 but OFLOOP_ROLE/OFLOOP_RUN_ID/OFLOOP_CANONICAL_REPO are missing or invalid. The misconfigured supervisor must be fixed."
  reasons_b64="$(printf '%s' "$reason" | base64)"
  reasons_b64="$reasons_b64" python3 -B - <<'PY'
import json, sys, base64, os
print(json.dumps({
    "decision": "block",
    "reason": base64.b64decode(os.environ["reasons_b64"]).decode("utf-8"),
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
