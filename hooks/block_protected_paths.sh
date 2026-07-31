#!/usr/bin/env bash
# OwnFramework Loop V2 — PreToolUse Write/Edit/MultiEdit/NotebookEdit guard.
#
# Exact-run / exact-role scoping:
#
#   Hook authority derives from the actual canonical execution context:
#     - cwd exactly equals ".worktrees/ownframework-loop/<run-id>/builder"  -> builder
#     - cwd exactly equals ".worktrees/ownframework-loop/<run-id>/reviewer" -> reviewer
#     - any path inside .ownframework-loop/<run-id>/                        -> exact-run-state
#     - any other cwd under an active ownframework-loop repo                -> no authority
#
#   Builder sources may edit ANY path inside the exact builder worktree.
#   Reviewer sources may write ONLY to:
#     - <repo>/.ownframework-loop/<run-id>/scratch/reviewer/  (BOUNDED scratch)
#     - the exact reviewer worktree (ignored artifacts only)
#   The reviewer MAY NOT edit candidate source under any circumstance.
#
#   Authoritative artifacts (WORK_PACKET.md, APPROVAL.json, STATE.json,
#   BUILD_RECEIPT.json, REVIEW_VERDICT.json, EVENTS.log) may NOT be written
#   via Write/Edit directly; they MUST go through the ofloop CLI.
#
#   Cross-run writes (Run A writing to Run B's state or worktree) are refused.
#   Writes to the canonical checkout during an active build are refused.
#
# Outside an active run, the hook is a no-op.
#
# Hook failure policy:
#   - malformed JSON                                -> refuse (exit 2)
#   - tool classification error (high-risk target)  -> refuse
#   - read-only inspection tools                    -> allow and log
#   - unknown external-side-effect tool             -> refuse during active run
#   - ordinary engineering tool                     -> allow
#
# This hook NEVER modifies permission settings, sandbox, or model routing.
#
# v0.3.4 hook bytecode suppression: export PYTHONDONTWRITEBYTECODE=1
# BEFORE every Python invocation so this hook does NOT write .pyc files
# into the active managed plugin cache tree. Every `python3` here is
# also invoked with `-B`.

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

case "$tool_name" in
  Write|Edit|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

file_path="$(printf '%s' "$parsed" | python3 -B -c 'import sys, json; print(json.loads(sys.stdin.read()).get("tool_input", {}).get("file_path", ""))' 2>/dev/null || true)"

if [[ -z "$file_path" ]]; then
  exit 0
fi

cwd="$(printf '%s' "$parsed" | python3 -B -c 'import sys, json; print(json.loads(sys.stdin.read()).get("cwd", ""))' 2>/dev/null || true)"
if [[ -z "$cwd" ]]; then
  cwd="$(pwd 2>/dev/null || true)"
fi

# Resolve both paths to canonical absolute form (macOS /var/folders → /private/var/folders).
abs_path="$(python3 -B -c 'import sys
from pathlib import Path
p = sys.argv[1] if len(sys.argv) > 1 else ""
print(str(Path(p).expanduser().resolve(strict=False))) if p else print("")' "$file_path" 2>/dev/null || echo "$file_path")"
abs_cwd="$(python3 -B -c 'import sys
from pathlib import Path
c = sys.argv[1] if len(sys.argv) > 1 else ""
print(str(Path(c).expanduser().resolve(strict=False))) if c else print("")' "$cwd" 2>/dev/null || echo "$cwd")"

# Find the canonical repo by walking up from cwd.
canonical_repo=""
if [[ -n "$abs_cwd" ]]; then
  d="$abs_cwd"
  while [[ -n "$d" && "$d" != "/" ]]; do
    if [[ -d "$d/.ownframework-loop" ]]; then
      canonical_repo="$d"
      break
    fi
    parent="$(dirname "$d" 2>/dev/null)"
    if [[ -z "$parent" || "$parent" == "$d" ]]; then break; fi
    d="$parent"
  done
fi

# Outside an active run: no-op.
if [[ -z "$canonical_repo" ]]; then
  exit 0
fi

run_root="$canonical_repo/.ownframework-loop"
wt_root="$canonical_repo/.worktrees/ownframework-loop"

# --------------- shared helper ----------------
emit_block() {
  local code="$1"
  local reason="$2"
  python3 -B - "$code" "$reason" <<'PY'
import json, sys
code, reason = sys.argv[1], sys.argv[2]
print(json.dumps({
    "decision": "block",
    "reason": f"[OF_LOOP_{code}] {reason}",
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": f"OF_LOOP_{code}"
    }
}))
PY
}

# --------------- discover runs ----------------
declare -a RUN_IDS
for d in "$run_root"/*/; do
  [[ -d "$d" ]] || continue
  rid="$(basename "$d")"
  [[ -n "$rid" && "$rid" != "*" ]] && RUN_IDS+=("$rid")
done

# --------------- cross-run block ----------------
# If the target hits another run's directory while the active context
# belongs to a different run, refuse.
target_run_id=""
for rid in "${RUN_IDS[@]}"; do
  if [[ "$abs_path" == "$run_root/$rid"/* || "$abs_path" == "$run_root/$rid" ]]; then
    target_run_id="$rid"
    break
  fi
  if [[ "$abs_path" == "$wt_root/$rid"/* ]]; then
    target_run_id="$rid"
    break
  fi
done

active_run_id=""
for rid in "${RUN_IDS[@]}"; do
  if [[ "$abs_cwd" == "$run_root/$rid"/* || "$abs_cwd" == "$run_root/$rid" ]]; then
    active_run_id="$rid"
    break
  fi
  if [[ "$abs_cwd" == "$wt_root/$rid/builder"* || "$abs_cwd" == "$wt_root/$rid/reviewer"* ]]; then
    active_run_id="$rid"
    break
  fi
done

if [[ -n "$target_run_id" && -n "$active_run_id" && "$target_run_id" != "$active_run_id" ]]; then
  emit_block "CROSS_RUN_WRITE" \
    "Cross-run write refused: active run=$active_run_id, target run=$target_run_id"
  exit 0
fi

# --------------- hard rules ----------------

# Refuse writes to .git metadata anywhere.
if [[ "$abs_path" == *"/.git/"* || "$abs_path" == *"/.git" ]]; then
  emit_block "GIT_METADATA" "Writes to .git metadata are refused."
  exit 0
fi

# Authoritative artifacts may NOT be written via Edit/Write/NotebookEdit.
case "$(basename "$abs_path")" in
  WORK_PACKET.md|APPROVAL.json|STATE.json|BUILD_RECEIPT.json|REVIEW_VERDICT.json|EVENTS.log|LOCK|STOP)
    if [[ "$abs_path" == "$run_root"/* ]]; then
      emit_block "AUTHORITATIVE_ARTIFACT_VIA_WRITE" \
        "Authoritative artifact $(basename "$abs_path") must be written through the ofloop CLI, not via Write/Edit."
      exit 0
    fi
    ;;
esac

# Builder worktree writable, reviewer worktree restricted.
is_builder_wt=0
is_reviewer_wt=0
if [[ "$abs_path" == "$wt_root"/*/builder"* || "$abs_path" == "$wt_root"/*/builder/"* ]]; then
  is_builder_wt=1
fi
if [[ "$abs_path" == "$wt_root"/*/reviewer"* || "$abs_path" == "$wt_root"/*/reviewer/"* ]]; then
  is_reviewer_wt=1
fi

# Canonical checkout outside worktrees: refuse during an active build/review.
if [[ "$abs_path" == "$canonical_repo"/* && "$abs_path" != "$run_root"/*" && "$abs_path" != "$wt_root"/*" ]]; then
  for rid in "${RUN_IDS[@]}"; do
    state_file="$run_root/$rid/STATE.json"
    if [[ -f "$state_file" ]]; then
      cur_state="$(python3 -B -c 'import sys, json
p = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    print(json.load(open(p)).get("state",""))
except Exception:
    pass' "$state_file" 2>/dev/null || true)"
      if [[ "$cur_state" == "BUILDING" || "$cur_state" == "REVIEWING" ]]; then
        emit_block "CANONICAL_CHECKOUT_WRITE_DURING_BUILD" \
          "Writes to canonical checkout refused while run $rid is in $cur_state. Builder writes go through the builder worktree."
        exit 0
      fi
    fi
  done
fi

# Reviewer worktree: only approved scratch allowed.
if [[ "$is_reviewer_wt" -eq 1 ]]; then
  for rid in "${RUN_IDS[@]}"; do
    if [[ "$abs_path" == "$run_root/$rid/scratch/reviewer"* || "$abs_path" == "$run_root/$rid/scratch/reviewer/"* ]]; then
      exit 0
    fi
  done
  emit_block "REVIEWER_SOURCE_WRITE" \
    "Reviewer may not write to candidate source. Only .ownframework-loop/<run-id>/scratch/reviewer/ is writable."
  exit 0
fi

# Builder worktree: allow any path inside it.
if [[ "$is_builder_wt" -eq 1 ]]; then
  exit 0
fi

# Anything else: refuse to be safe.
emit_block "PROTECTED_PATH" \
  "Write refused: target $abs_path is not within the active builder worktree or approved scratch."
exit 0
