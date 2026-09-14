#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib"
export PYTHONDONTWRITEBYTECODE=1

state_counts() {
  python3 - "$1" "$2" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1]) / ".ownframework-loop" / sys.argv[2] / "STATE.json"
d = json.loads(p.read_text())
print(json.dumps({k: d.get(k) for k in ("build_pass_count", "review_pass_count", "repair_round")}, sort_keys=True))
PY
}

write_poison() {
  python3 - "$1" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
preset = json.loads(p.read_text())
p.write_text(json.dumps({
    "agent": "of-builder",
    "schema_version": "1",
    "pass_number": 1,
    "checkpoint_id": "",
    "branch": "wrong",
    "commit_sha": "wrong",
    "run_id": preset.get("run_id"),
    "outcome_requested": "candidate_ready",
    "summary": "poison",
}, sort_keys=True) + "\n")
PY
}

# Builder crash/restart: the same pass and canonical path are retained.
REPO="$(make_tmp_repo)"
RUN="$(make_approved_run "$REPO" FEATURE low atomic-builder)"
ORDER="$($OFLOOP_BIN dispatch claim "$REPO" "$RUN")"
SEM="$(printf '%s' "$ORDER" | jq -r '.semantic_path')"
WT="$(printf '%s' "$ORDER" | jq -r '.worktree')"
mkdir -p "$WT/src"
printf '%s\n' 'def preserved(): return True' > "$WT/src/preserved.py"
git -C "$WT" add src/preserved.py
git -C "$WT" commit -m 'test: preserve candidate during retry reseed' >/dev/null
COUNTS_BEFORE="$(state_counts "$REPO" "$RUN")"
write_poison "$SEM"
READY="$(ORDER_JSON="$ORDER" python3 -c 'import json,os; from ownframework_loop import dispatch; print("|".join(map(str,dispatch.semantic_result_ready(json.loads(os.environ["ORDER_JSON"])))) )')"
assert_eq "$READY" "False|builder_schema_mismatch" "builder poison is retryable"
FIRST="$(ORDER_JSON="$ORDER" python3 -c 'import json,os; from ownframework_loop import dispatch; print(json.dumps(dispatch.reseed_semantic_artifact_for_retry(json.loads(os.environ["ORDER_JSON"]),previous_attempt_id="builder-crash-attempt"),sort_keys=True))')"
ARCHIVE="$(printf '%s' "$FIRST" | jq -r '.archive_path')"
assert_file_exists "$ARCHIVE" "builder malformed archive exists"
SECOND="$(ORDER_JSON="$ORDER" python3 -c 'import json,os; from ownframework_loop import dispatch; print(json.dumps(dispatch.reseed_semantic_artifact_for_retry(json.loads(os.environ["ORDER_JSON"]),previous_attempt_id="builder-crash-attempt"),sort_keys=True))')"
assert_eq "$(printf '%s' "$SECOND" | jq -r '.already_reseeded')" "true" "builder restart detects completed reseed"
assert_eq "$(state_counts "$REPO" "$RUN")" "$COUNTS_BEFORE" "builder crash reseed preserves budgets"
assert_eq "$(git -C "$WT" rev-parse HEAD)" "$(git -C "$REPO" rev-parse "factory/candidate/$RUN")" "builder crash reseed preserves source"
assert_eq "$(python3 -c 'import os,sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "o"))' "$ARCHIVE")" "600" "builder archive remains private"
python3 - "$SEM" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1]); d = json.loads(p.read_text())
d.update({"summary": "valid retry", "unit_ids_completed": ["UNIT-1"], "acceptance_addressed": ["AC-1"], "outcome_requested": "candidate_ready"})
p.write_text(json.dumps(d, sort_keys=True) + "\n")
PY
"$OFLOOP_BIN" dispatch finalize "$REPO" "$RUN" BUILD "$SEM" >/dev/null
assert_eq "$(jq -r '.state' "$REPO/.ownframework-loop/$RUN/STATE.json")" "READY_FOR_REVIEW" "builder retry finalizes"
echo "BUILDER_CRASH_RESTART=PASS"

# Reviewer crash/restart: same review pass and canonical path are retained.
RORDER="$($OFLOOP_BIN dispatch claim "$REPO" "$RUN")"
RSEM="$(printf '%s' "$RORDER" | jq -r '.semantic_path')"
RCOUNTS_BEFORE="$(state_counts "$REPO" "$RUN")"
write_poison "$RSEM"
RREADY="$(RORDER_JSON="$RORDER" python3 -c 'import json,os; from ownframework_loop import dispatch; print("|".join(map(str,dispatch.semantic_result_ready(json.loads(os.environ["RORDER_JSON"])))) )')"
assert_eq "$RREADY" "False|review_schema_mismatch" "reviewer poison is retryable"
R1="$(RORDER_JSON="$RORDER" python3 -c 'import json,os; from ownframework_loop import dispatch; print(json.dumps(dispatch.reseed_semantic_artifact_for_retry(json.loads(os.environ["RORDER_JSON"]),previous_attempt_id="reviewer-crash-attempt"),sort_keys=True))')"
RARCHIVE="$(printf '%s' "$R1" | jq -r '.archive_path')"
R2="$(RORDER_JSON="$RORDER" python3 -c 'import json,os; from ownframework_loop import dispatch; print(json.dumps(dispatch.reseed_semantic_artifact_for_retry(json.loads(os.environ["RORDER_JSON"]),previous_attempt_id="reviewer-crash-attempt"),sort_keys=True))')"
assert_eq "$(printf '%s' "$R2" | jq -r '.already_reseeded')" "true" "reviewer restart detects completed reseed"
assert_eq "$(state_counts "$REPO" "$RUN")" "$RCOUNTS_BEFORE" "reviewer crash reseed preserves budgets"
assert_eq "$(python3 -c 'import os,sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "o"))' "$RARCHIVE")" "600" "reviewer archive remains private"
python3 - "$RSEM" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1]); d = json.loads(p.read_text())
d.update({"validation_results": [], "acceptance_results": [{"id": "AC-1", "result": "pass", "evidence": "valid retry"}], "non_goal_results": [], "findings": [], "recommended_verdict": "APPROVED"})
p.write_text(json.dumps(d, sort_keys=True) + "\n")
PY
"$OFLOOP_BIN" dispatch finalize "$REPO" "$RUN" REVIEW "$RSEM" >/dev/null
assert_eq "$(jq -r '.verdict' "$REPO/.ownframework-loop/$RUN/REVIEW_VERDICT.json")" "APPROVED" "reviewer retry finalizes"
echo "REVIEWER_CRASH_RESTART=PASS"

echo "SEMANTIC_RETRY_ATOMIC_ENVELOPE_REGRESSION=PASS"
