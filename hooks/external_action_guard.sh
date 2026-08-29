#!/usr/bin/env bash
# OwnFramework Loop — External Action Guard.
#
# v0.6.1 execution-context contract: this hook is a NO-OP outside an
# active OwnFramework Loop semantic lane. Provenance is established by
# env markers (OFLOOP_SEMANTIC_CONTEXT=1 + OFLOOP_RUN_ID/ROLE/CANONICAL_REPO)
# OR by a marker file .ownframework-loop/_semantic_context at the cwd
# repo root — same contract as block_dangerous_bash.sh.
#
# The historical path-based heuristic (cwd has .ownframework-loop
# ancestor implies active run) over-scoped ordinary interactive Claude
# sessions inside a repository that happened to own historical run
# state. That heuristic has been removed.

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

if [[ -z "$tool_name" ]]; then
  exit 0
fi

cwd="$(printf '%s' "$parsed" | python3 -B -c 'import sys, json; print(json.loads(sys.stdin.read()).get("cwd", ""))' 2>/dev/null || true)"
if [[ -z "$cwd" ]]; then
  cwd="$(pwd 2>/dev/null || true)"
fi

if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
  echo "  [of-loop hook] CLAUDE_PLUGIN_ROOT not provided; refusing for safety" 1>&2
  exit 2
fi

context="$(CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" python3 -B - "$cwd" 2>/dev/null <<'PY_END' || echo "CTX_ERROR"
import json, sys, os
from pathlib import Path
sys.path.insert(0, os.path.join(os.environ.get("CLAUDE_PLUGIN_ROOT", ""), "lib"))
from ownframework_loop import role_context
cwd = sys.argv[1] if len(sys.argv) > 1 else ""
ctx = None
prov = None
try:
    env_ctx = role_context.read_env()
except Exception:
    env_ctx = None
if env_ctx is not None:
    if role_context.context_canonical_repo_matches(env_ctx, cwd or "."):
        ctx = env_ctx
        prov = "env"
    else:
        print(json.dumps({"status": "smuggle_refused", "expected": env_ctx.get("canonical_repo"), "cwd": cwd}))
        sys.exit(0)
if ctx is None and cwd:
    d = Path(cwd).expanduser().resolve(strict=False)
    marker = d / ".ownframework-loop" / "_semantic_context"
    if marker.is_file():
        m_ctx = role_context.read_marker(d)
        if m_ctx is not None:
            ctx = m_ctx
            prov = "marker"
if ctx is None:
    print(json.dumps({"status": "no_context"}))
    sys.exit(0)
print(json.dumps({"status": "active", "provenance": prov, **ctx}))
PY_END
)"

if [[ "$context" == "CTX_ERROR" || -z "$context" ]]; then
  exit 0
fi

status="$(printf '%s' "$context" | python3 -B -c 'import json,sys; print(json.loads(sys.stdin.read()).get("status",""))' 2>/dev/null || true)"
if [[ "$status" != "active" ]]; then
  exit 0
fi

canonical_repo="$(printf '%s' "$context" | python3 -B -c 'import json,sys; print(json.loads(sys.stdin.read()).get("canonical_repo",""))' 2>/dev/null || true)"
active_run="$canonical_repo"

encoded="$(printf '%s' "$parsed" | base64)"

decision="$(CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" encoded_payload="$encoded" encoded_tool="$tool_name" python3 -B - <<'PY' 2>/dev/null || echo "ALLOW"
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
  python3 -B - "$tool_name" "$active_run" <<'PY' 2>/dev/null || true
import sys, os
log_dir = os.path.join(os.environ.get("CLAUDE_PLUGIN_ROOT", ""), "logs")
os.makedirs(log_dir, exist_ok=True)
log_path = os.path.join(log_dir, "external_action_diagnostics.log")
with open(log_path, "a", encoding="utf-8") as f:
    f.write(f"tool={sys.argv[1]} active_run={sys.argv[2]} decision=ALLOW_WITH_DIAGNOSTIC\n")
PY
  exit 0
fi

code="$(printf '%s' "$decision" | head -n1 | tr -d ' ')"
reason="$(printf '%s' "$decision" | tail -n +2)"
reason_b64="$(printf '%s' "$reason" | base64)"
reason_b64="$reason_b64" code="$code" python3 -B - <<'PY'
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
