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

# NOTE: an empty tool_name is NOT an early exit. Outside an active semantic
# lane the context check below still no-ops; INSIDE an active lane the
# classifier fails closed on an unidentifiable (empty) tool name. An
# external-authority gate must not treat "cannot identify the tool" as
# "allowed".

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
if role_context.is_env_partial():
    print(json.dumps({"status": "partial_env_refused"}))
    sys.exit(0)
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
        else:
            print(json.dumps({"status": "marker_invalid_refused"}))
            sys.exit(0)
if ctx is None:
    print(json.dumps({"status": "no_context"}))
    sys.exit(0)
print(json.dumps({"status": "active", "provenance": prov, **ctx}))
PY_END
)"

if [[ "$context" == "CTX_ERROR" || -z "$context" ]]; then
  if [[ "${OFLOOP_SEMANTIC_CONTEXT:-}" == "1" || -f "$cwd/.ownframework-loop/_semantic_context" ]]; then
    printf '%s\n' '{"decision":"block","reason":"[OF_LOOP_EXTERNAL_ACTION] semantic context verification failed; refusing external actions","hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"OF_LOOP_EXTERNAL_UNKNOWN"}}'
    exit 0
  fi
  exit 0
fi

status="$(printf '%s' "$context" | python3 -B -c 'import json,sys; print(json.loads(sys.stdin.read()).get("status",""))' 2>/dev/null || true)"
if [[ "$status" == "smuggle_refused" || "$status" == "partial_env_refused" || "$status" == "marker_invalid_refused" ]]; then
  printf '%s\n' '{"decision":"block","reason":"[OF_LOOP_EXTERNAL_ACTION] invalid or cross-repository semantic context; refusing external actions","hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"OF_LOOP_EXTERNAL_UNKNOWN"}}'
  exit 0
fi
if [[ "$status" != "active" ]]; then
  exit 0
fi

canonical_repo="$(printf '%s' "$context" | python3 -B -c 'import json,sys; print(json.loads(sys.stdin.read()).get("canonical_repo",""))' 2>/dev/null || true)"
# Evidence/observability integrity: diagnostics and classifier context are
# bound to the EXACT semantic-context run id, not the repo path. The repo
# path stays available as canonical_repo for cross-referencing.
run_id="$(printf '%s' "$context" | python3 -B -c 'import json,sys; print(json.loads(sys.stdin.read()).get("run_id",""))' 2>/dev/null || true)"
active_run="$run_id"

encoded="$(printf '%s' "$parsed" | base64)"

# Fail-closed contract: a classifier crash, import failure, missing
# interpreter, or unrecognized decision text must all yield a BLOCK.
# An external-authority gate must never degrade to ALLOW because its
# own machinery is unavailable. The classifier emits exactly one of
# ALLOW, ALLOW_WITH_DIAGNOSTIC, or "BLOCK:<CODE>" + newline + reason;
# anything else — including empty output from a dead interpreter — is
# an external-authority failure and is refused.
decision="$(CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" encoded_payload="$encoded" encoded_tool="$tool_name" active_run="$active_run" python3 -B - <<'PY' 2>/dev/null
import sys, os, base64, json
try:
    sys.path.insert(0, os.path.join(os.environ["CLAUDE_PLUGIN_ROOT"], "lib"))
    from ownframework_loop import external_action
    payload = json.loads(base64.b64decode(os.environ["encoded_payload"]).decode("utf-8", errors="replace"))
    tool = payload.get("tool_name", "")
    decision = external_action.classify_tool_call(
        tool_name=tool,
        tool_input=payload.get("tool_input", {}) or {},
        active_run=os.environ.get("active_run", ""),
    )
    print(decision)
except Exception:
    print("BLOCK:OF_LOOP_EXTERNAL_UNKNOWN\nactive semantic external-action classifier failed")
PY
)"

case "$decision" in
  ALLOW|ALLOW_WITH_DIAGNOSTIC|BLOCK:*) ;;
  *) decision="BLOCK:OF_LOOP_EXTERNAL_UNKNOWN
external-action classifier unavailable or returned an unrecognized decision; refusing external action fail-closed" ;;
esac

if [[ "$decision" == "ALLOW" ]]; then
  exit 0
fi

# Evidence trail: every non-allow decision in a governed lane records the
# exact run id, canonical repo, tool, and decision code.
decision_code="$(printf '%s' "$decision" | head -n1 | tr -d ' ')"
active_run="$active_run" canonical_repo="$canonical_repo" tool_name="$tool_name" decision_code="$decision_code" python3 -B - <<'PY' 2>/dev/null || true
import os
log_dir = os.path.join(os.environ.get("CLAUDE_PLUGIN_ROOT", ""), "logs")
os.makedirs(log_dir, exist_ok=True)
log_path = os.path.join(log_dir, "external_action_diagnostics.log")
with open(log_path, "a", encoding="utf-8") as f:
    f.write(
        f"run_id={os.environ.get('active_run', '')} "
        f"canonical_repo={os.environ.get('canonical_repo', '')} "
        f"tool={os.environ.get('tool_name', '')} "
        f"decision={os.environ.get('decision_code', '')}\n"
    )
PY

if [[ "$decision" == "ALLOW_WITH_DIAGNOSTIC" ]]; then
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
