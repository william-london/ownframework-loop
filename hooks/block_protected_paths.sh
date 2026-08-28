#!/usr/bin/env bash
# OwnFramework Loop — PreToolUse Write/Edit/MultiEdit/NotebookEdit guard.
#
# Builder source writes are confined to the exact builder worktree. Reviewer
# source is read-only. Semantic result/assessment writes are confined to the
# exact active run AND exact currently claimed pass. Authoritative protocol
# artifacts must be written by the deterministic ofloop CLI.

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
file_path="$(printf '%s' "$parsed" | python3 -B -c 'import sys,json; print(json.loads(sys.stdin.read()).get("tool_input",{}).get("file_path",""))' 2>/dev/null || true)"
[[ -n "$file_path" ]] || exit 0
cwd="$(printf '%s' "$parsed" | python3 -B -c 'import sys,json; print(json.loads(sys.stdin.read()).get("cwd",""))' 2>/dev/null || true)"
[[ -n "$cwd" ]] || cwd="$(pwd 2>/dev/null || true)"

abs_path="$(python3 -B -c 'import sys
from pathlib import Path
p=sys.argv[1] if len(sys.argv)>1 else ""
print(str(Path(p).expanduser().resolve(strict=False))) if p else print("")' "$file_path" 2>/dev/null || echo "$file_path")"
abs_cwd="$(python3 -B -c 'import sys
from pathlib import Path
c=sys.argv[1] if len(sys.argv)>1 else ""
print(str(Path(c).expanduser().resolve(strict=False))) if c else print("")' "$cwd" 2>/dev/null || echo "$cwd")"

canonical_repo=""
if [[ -n "$abs_cwd" ]]; then
  d="$abs_cwd"
  while [[ -n "$d" && "$d" != "/" ]]; do
    if [[ -d "$d/.ownframework-loop" ]]; then canonical_repo="$d"; break; fi
    parent="$(dirname "$d" 2>/dev/null)"
    [[ -n "$parent" && "$parent" != "$d" ]] || break
    d="$parent"
  done
fi
[[ -n "$canonical_repo" ]] || exit 0
run_root="$canonical_repo/.ownframework-loop"
wt_root="$canonical_repo/.worktrees/ownframework-loop"

emit_block() {
  local code="$1" reason="$2"
  python3 -B - "$code" "$reason" <<'PY'
import json,sys
code,reason=sys.argv[1],sys.argv[2]
print(json.dumps({"decision":"block","reason":f"[OF_LOOP_{code}] {reason}","hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":f"OF_LOOP_{code}"}}))
PY
}

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
active_run_id=""
for rid in "${RUN_IDS[@]}"; do
  if [[ "$abs_cwd" == "$run_root/$rid" || "$abs_cwd" == "$run_root/$rid/"* ||
        "$abs_cwd" == "$wt_root/$rid/builder" || "$abs_cwd" == "$wt_root/$rid/builder/"* ||
        "$abs_cwd" == "$wt_root/$rid/reviewer" || "$abs_cwd" == "$wt_root/$rid/reviewer/"* ]]; then
    active_run_id="$rid"; break
  fi
done
if [[ -n "$target_run_id" && -n "$active_run_id" && "$target_run_id" != "$active_run_id" ]]; then
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
if [[ "$abs_path" == "$wt_root"/*/builder || "$abs_path" == "$wt_root"/*/builder/* ]]; then is_builder_wt=1; fi
if [[ "$abs_path" == "$wt_root"/*/reviewer || "$abs_path" == "$wt_root"/*/reviewer/* ]]; then is_reviewer_wt=1; fi

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
