#!/usr/bin/env bash
# OwnFramework Loop — PreToolUse Write/Edit/MultiEdit/NotebookEdit guard.
#
# Builder source writes are confined to the exact builder worktree. Reviewer
# source is read-only. Semantic result/assessment writes are confined to the
# exact active run AND exact currently claimed pass. Authoritative protocol
# artifacts must be written by the deterministic ofloop CLI.
#
# v0.7.0 EXECUTION-CONTEXT CONTRACT
# =================================
#
# The guard is ONLY active when the current write is provably inside an
# OwnFramework Loop semantic lane. Provenance uses the same two sources as
# block_dangerous_bash.sh:
#
#   (a) ENVIRONMENT MARKERS set by the Loop supervisor when launching a
#       Claude Code worker subprocess:
#         OFLOOP_SEMANTIC_CONTEXT=1
#         OFLOOP_RUN_ID=<exact>
#         OFLOOP_ROLE=builder|reviewer
#         OFLOOP_CANONICAL_REPO=<resolved repo path>
#
#   (b) MARKER FILE — `.ownframework-loop/_semantic_context` in the cwd's
#       canonical repo root, written by foreground lanes via
#       `ofloop role enter` and removed via `ofloop role exit`.
#
# OUTSIDE both provenances the hook is a NO-OP. The historical heuristic
# (any `.ownframework-loop/` ancestor of the cwd implies an active run)
# over-scoped ordinary operator-authorized interactive sessions and plain
# maintenance work in repositories that happened to own historical run
# state. That heuristic has been removed.
#
# Anti-smuggling: when (a) is used, the cwd must belong to the same Git
# repository (common-dir identity) as the declared OFLOOP_CANONICAL_REPO.
#
# Fail-closed on malformed JSON, missing CLAUDE_PLUGIN_ROOT /
# OFLOOP_PLUGIN_ROOT, partial environment markers, marker file with
# invalid role or run_id, or unparseable context.
#
# In-lane scratch allowances beyond the builder worktree and exact pass
# scratch: the supervisor-owned runtime-cache root (where hermetic
# validation env externalizes caches/TMPDIR) and ordinary system scratch
# directories (/tmp, /private/tmp, /var/folders). A system-scratch prefix
# NEVER overrides repository ownership: if the canonical repo itself lives
# under one of those roots, canonical/run/worktree paths still pass through
# the normal authority checks below.

set -eo pipefail
export PYTHONDONTWRITEBYTECODE=1

input="$(cat 2>/dev/null || true)"
if [[ -z "$input" ]]; then exit 2; fi
parsed="$(printf '%s' "$input" | python3 -B -c '
import json,sys
try: obj=json.loads(sys.stdin.read())
except Exception as e: print("PARSE_ERROR",e); sys.exit(0)
print(json.dumps(obj))
' 2>/dev/null || echo "PARSE_ERROR")"
if [[ "$parsed" == "PARSE_ERROR"* ]]; then
  echo "  [of-loop hook] malformed JSON; refusing for safety" 1>&2
  exit 2
fi

tool_name="$(printf '%s' "$parsed" | python3 -B -c 'import sys,json; print(json.loads(sys.stdin.read()).get("tool_name",""))' 2>/dev/null || true)"
case "$tool_name" in Write|Edit|MultiEdit|NotebookEdit) ;; *) exit 0 ;; esac
file_path="$(printf '%s' "$parsed" | python3 -B -c 'import sys,json; i=json.loads(sys.stdin.read()).get("tool_input",{}) or {}; print(i.get("file_path") or i.get("notebook_path") or "")' 2>/dev/null || true)"
cwd="$(printf '%s' "$parsed" | python3 -B -c 'import sys,json; print(json.loads(sys.stdin.read()).get("cwd",""))' 2>/dev/null || true)"
[[ -n "$cwd" ]] || cwd="$(pwd 2>/dev/null || true)"

if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" && -z "${OFLOOP_PLUGIN_ROOT:-}" ]]; then
  echo "  [of-loop hook] CLAUDE_PLUGIN_ROOT not provided by Claude Code and OFLOOP_PLUGIN_ROOT not set in environment; refusing for safety" 1>&2
  exit 2
fi
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-${OFLOOP_PLUGIN_ROOT}}"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

abs_path="$(python3 -B -c 'import sys
from pathlib import Path
p=sys.argv[1] if len(sys.argv)>1 else ""
print(str(Path(p).expanduser().resolve(strict=False))) if p else print("")' "$file_path" 2>/dev/null || echo "$file_path")"
abs_cwd="$(python3 -B -c 'import sys
from pathlib import Path
c=sys.argv[1] if len(sys.argv)>1 else ""
print(str(Path(c).expanduser().resolve(strict=False))) if c else print("")' "$cwd" 2>/dev/null || echo "$cwd")"

emit_block() {
  local code="$1" reason="$2"
  python3 -B - "$code" "$reason" <<'PY'
import json,sys
code,reason=sys.argv[1],sys.argv[2]
print(json.dumps({"decision":"block","reason":f"[OF_LOOP_{code}] {reason}","hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":f"OF_LOOP_{code}"}}))
PY
}

# === v0.7.0 EXECUTION-CONTEXT DETECTION ===
encoded_cwd_b64="$(printf '%s' "$abs_cwd" | base64)"
context="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" python3 -B - "$encoded_cwd_b64" 2>/dev/null <<'PY' || echo "CTX_ERROR"
import json, sys, base64, os
try:
    cwd = base64.b64decode(sys.argv[1]).decode("utf-8", errors="replace")
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
# Partial env: OFLOOP_SEMANTIC_CONTEXT=1 set but role/run_id/canonical_repo
# missing or invalid. Fail closed: a misconfigured supervisor must not
# silently disable its own write contract.
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
    marker = d / ".ownframework-loop" / "_semantic_context"
    if marker.is_file():
        m_ctx = role_context.read_marker(d)
        if m_ctx is not None:
            ctx = m_ctx
            provenance = "marker"
        else:
            print(json.dumps({"status": "marker_invalid_refused"}))
            sys.exit(0)
if ctx is None:
    print(json.dumps({"status": "no_context"}))
    sys.exit(0)
print(json.dumps({"status": "active", "provenance": provenance, **ctx}))
PY
)"

if [[ "$context" == "CTX_ERROR" ]]; then
  if [[ "${OFLOOP_SEMANTIC_CONTEXT:-}" == "1" || -f "$abs_cwd/.ownframework-loop/_semantic_context" ]]; then
    emit_block "PROTECTED_PATH" "OwnFramework Loop: write context was declared but context verification failed; refusing rather than disabling the write guard."
    exit 0
  fi
  exit 0
fi

status="$(printf '%s' "$context" | python3 -B -c 'import json,sys; print(json.loads(sys.stdin.read()).get("status",""))' 2>/dev/null || true)"

if [[ "$status" == "smuggle_refused" ]]; then
  emit_block "PROTECTED_PATH" "OwnFramework Loop: semantic-context env markers declared a different repository than the write cwd; refusing cross-repository write scoping."
  exit 0
fi
if [[ "$status" == "partial_env_refused" || "$status" == "marker_invalid_refused" ]]; then
  emit_block "PROTECTED_PATH" "OwnFramework Loop: semantic context declared but OFLOOP_ROLE/OFLOOP_RUN_ID/OFLOOP_CANONICAL_REPO are missing or invalid; refusing partial write contract."
  exit 0
fi
if [[ "$status" != "active" ]]; then
  # No semantic context: NO-OP. General Claude/native permission model applies.
  exit 0
fi

context_run_id="$(printf '%s' "$context" | python3 -B -c 'import json,sys; print(json.loads(sys.stdin.read()).get("run_id",""))' 2>/dev/null || true)"
context_role="$(printf '%s' "$context" | python3 -B -c 'import json,sys; print(json.loads(sys.stdin.read()).get("role",""))' 2>/dev/null || true)"
if [[ -z "$abs_path" ]]; then
  emit_block "PROTECTED_PATH" "OwnFramework Loop: active semantic write tool supplied no file_path/notebook_path; refusing fail-closed."
  exit 0
fi

canonical_repo="$(printf '%s' "$context" | python3 -B -c 'import json,sys
from pathlib import Path
raw=json.loads(sys.stdin.read()).get("canonical_repo","")
print(str(Path(raw).expanduser().resolve(strict=False))) if raw else print("")' 2>/dev/null || true)"
if [[ -z "$canonical_repo" || ! -d "$canonical_repo" ]]; then
  emit_block "PROTECTED_PATH" "OwnFramework Loop: active semantic context has no resolvable canonical repository; refusing for safety."
  exit 0
fi

run_root="$canonical_repo/.ownframework-loop"
wt_root="$canonical_repo/.worktrees/ownframework-loop"

declare -a RUN_IDS
for d in "$run_root"/*/; do
  [[ -d "$d" ]] || continue
  rid="$(basename "$d")"
  [[ -n "$rid" && "$rid" != "*" ]] && RUN_IDS+=("$rid")
done

target_run_id=""
for rid in "${RUN_IDS[@]}"; do
  if [[ "$abs_path" == "$run_root/$rid" || "$abs_path" == "$run_root/$rid/"* ||
        "$abs_path" == "$wt_root/$rid/builder" || "$abs_path" == "$wt_root/$rid/builder/"* ||
        "$abs_path" == "$wt_root/$rid/reviewer" || "$abs_path" == "$wt_root/$rid/reviewer/"* ]]; then
    target_run_id="$rid"; break
  fi
done
active_run_id="$context_run_id"
if [[ -n "$target_run_id" && "$target_run_id" != "$active_run_id" ]]; then
  emit_block "CROSS_RUN_WRITE" "Cross-run write refused: active run=$active_run_id, target run=$target_run_id"
  exit 0
fi

if [[ "$abs_path" == *"/.git/"* || "$abs_path" == *"/.git" ]]; then
  emit_block "GIT_METADATA" "Writes to .git metadata are refused."
  exit 0
fi
case "$(basename "$abs_path")" in
  WORK_PACKET.md|APPROVAL.json|STATE.json|BUILD_RECEIPT.json|REVIEW_VERDICT.json|EVENTS.log|LOCK|STOP)
    if [[ "$abs_path" == "$run_root"/* ]]; then
      emit_block "AUTHORITATIVE_ARTIFACT_VIA_WRITE" "Authoritative artifact $(basename "$abs_path") must be written through the ofloop CLI, not via Write/Edit."
      exit 0
    fi
    ;;
esac

# Loop-owned non-source scratch: the supervisor runtime-cache root (hermetic
# validation env externalizes caches/TMPDIR here) and ordinary system scratch
# directories. These never carry candidate source.
active_runtime_cache="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CANONICAL_REPO="$canonical_repo" ACTIVE_RUN="$active_run_id" ACTIVE_ROLE="$context_role" python3 -B -c '
import os, sys
sys.path.insert(0, os.path.join(os.environ.get("CLAUDE_PLUGIN_ROOT", ""), "lib"))
from pathlib import Path
from ownframework_loop import runtime_env
print(str(runtime_env.runtime_cache_path(
    Path(os.environ["CANONICAL_REPO"]),
    os.environ["ACTIVE_RUN"],
    os.environ["ACTIVE_ROLE"],
)))
' 2>/dev/null || true)"
if [[ -n "$active_runtime_cache" && ( "$abs_path" == "$active_runtime_cache" || "$abs_path" == "$active_runtime_cache/"* ) ]]; then
  exit 0
fi
case "$abs_path" in
  /tmp/*|/private/tmp/*|/var/folders/*)
    # Only genuine external scratch is exempt. Repository-owned paths must
    # continue through exact-pass/canonical/worktree authority checks even
    # when the repository itself resides under a system temporary root.
    if [[ "$abs_path" != "$canonical_repo" && "$abs_path" != "$canonical_repo/"* ]]; then
      exit 0
    fi
    ;;
esac

# Exact current-pass semantic scratch only.
if [[ -n "$target_run_id" ]]; then
  target_state_file="$run_root/$target_run_id/STATE.json"
  target_state=""; target_build_pass="0"; target_review_pass="0"
  if [[ -f "$target_state_file" ]]; then
    state_tuple="$(python3 -B -c 'import json,sys
try:
 d=json.load(open(sys.argv[1])); print("%s\t%s\t%s"%(d.get("state",""),int(d.get("build_pass_count") or 0),int(d.get("review_pass_count") or 0)))
except Exception: print("\t0\t0")' "$target_state_file" 2>/dev/null || printf '\t0\t0')"
    IFS=$'\t' read -r target_state target_build_pass target_review_pass <<< "$state_tuple"
  fi
  if [[ "$target_state" == "BUILDING" && "$target_build_pass" -gt 0 ]]; then
    printf -v expected_builder_pass 'pass-%04d' "$target_build_pass"
    expected_builder="$run_root/$target_run_id/scratch/builder/$expected_builder_pass/BUILD_AGENT_RESULT.json"
    [[ "$abs_path" == "$expected_builder" ]] && exit 0
  fi
  if [[ "$target_state" == "REVIEWING" && "$target_review_pass" -gt 0 ]]; then
    printf -v expected_reviewer_pass 'pass-%04d' "$target_review_pass"
    expected_reviewer="$run_root/$target_run_id/scratch/reviewer/$expected_reviewer_pass/REVIEW_AGENT_ASSESSMENT.json"
    [[ "$abs_path" == "$expected_reviewer" ]] && exit 0
  fi
fi

# Builder worktree: allow any path inside it.
is_builder_wt=0
is_reviewer_wt=0
if [[ -n "$active_run_id" && ( "$abs_path" == "$wt_root/$active_run_id/builder" || "$abs_path" == "$wt_root/$active_run_id/builder/"* ) ]]; then is_builder_wt=1; fi
if [[ -n "$active_run_id" && ( "$abs_path" == "$wt_root/$active_run_id/reviewer" || "$abs_path" == "$wt_root/$active_run_id/reviewer/"* ) ]]; then is_reviewer_wt=1; fi

if [[ "$abs_path" == "$canonical_repo"/* && "$abs_path" != "$run_root"/* && "$abs_path" != "$wt_root"/* ]]; then
  for rid in "${RUN_IDS[@]}"; do
    state_file="$run_root/$rid/STATE.json"
    if [[ -f "$state_file" ]]; then
      cur_state="$(python3 -B -c 'import sys,json
try: print(json.load(open(sys.argv[1])).get("state",""))
except Exception: pass' "$state_file" 2>/dev/null || true)"
      if [[ "$cur_state" == "BUILDING" || "$cur_state" == "REVIEWING" ]]; then
        emit_block "CANONICAL_CHECKOUT_WRITE_DURING_BUILD" "Writes to canonical checkout refused while run $rid is in $cur_state. Builder writes go through the builder worktree."
        exit 0
      fi
    fi
  done
fi
if [[ "$is_reviewer_wt" -eq 1 ]]; then
  emit_block "REVIEWER_SOURCE_WRITE" "Reviewer may not write candidate source. Only the exact current pass scratch/reviewer assessment is writable."
  exit 0
fi
if [[ "$is_builder_wt" -eq 1 ]]; then exit 0; fi
emit_block "PROTECTED_PATH" "Write refused: target $abs_path is not within the active builder worktree or exact current-pass scratch."
exit 0
