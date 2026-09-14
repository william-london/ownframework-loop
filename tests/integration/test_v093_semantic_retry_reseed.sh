#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib"
export PYTHONDONTWRITEBYTECODE=1

REPO="$(make_tmp_repo)"
RUN="$(make_approved_run "$REPO" FEATURE low "semantic-retry-reseed")"
ORDER="$("$OFLOOP_BIN" dispatch claim "$REPO" "$RUN")"
SEM="$(printf '%s' "$ORDER" | jq -r '.semantic_path')"
WT="$(printf '%s' "$ORDER" | jq -r '.worktree')"
mkdir -p "$WT/src"
printf '%s\n' 'def retry_reseed(): return "preserved"' > "$WT/src/retry_reseed.py"
git -C "$WT" add src/retry_reseed.py
git -C "$WT" commit -m "test: preserve source across semantic retry" >/dev/null

python3 -c 'import json,sys; from pathlib import Path; p=Path(sys.argv[1]); p.write_text(json.dumps({"agent":"of-builder","schema_version":"1","run_id":sys.argv[2],"pass_number":1,"work_unit_id":"UNIT-1","checkpoint_id":"","branch":"master","commit_sha":"placeholder","outcome_requested":"candidate_ready","summary":"poison"},indent=2)+"\n")' "$SEM" "$RUN"
READY="$(ORDER_JSON="$ORDER" python3 -c 'import json,os; from ownframework_loop import dispatch; print("|".join(map(str,dispatch.semantic_result_ready(json.loads(os.environ["ORDER_JSON"])))) )')"
assert_eq "$READY" "False|builder_schema_mismatch" "malformed builder schema is retryable"

RESEED="$(ORDER_JSON="$ORDER" python3 -c 'import json,os; from ownframework_loop import dispatch; print(json.dumps(dispatch.reseed_semantic_artifact_for_retry(json.loads(os.environ["ORDER_JSON"]),previous_attempt_id="builder-attempt-1"),sort_keys=True))')"
ARCHIVE="$(printf '%s' "$RESEED" | jq -r '.archive_path')"
assert_file_exists "$ARCHIVE" "malformed builder artifact archived"
assert_eq "$(python3 -c 'import os,sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "o"))' "$ARCHIVE")" "600" "builder archive mode"
assert_eq "$(jq -r '.schema' "$SEM")" "ownframework-loop-build-agent-result/v1" "builder skeleton reseeded"
assert_eq "$(git -C "$WT" rev-parse HEAD)" "$(git -C "$REPO" rev-parse "factory/candidate/$RUN")" "source work preserved"
COLLISION="$(ORDER_JSON="$ORDER" python3 -c 'import json,os; from ownframework_loop import dispatch
try: dispatch.reseed_semantic_artifact_for_retry(json.loads(os.environ["ORDER_JSON"]),previous_attempt_id="builder-attempt-1")
except Exception as e: print(type(e).__name__)')"
assert_eq "$COLLISION" "DispatchError" "archive collision fails closed"

python3 -c 'import json,sys; from pathlib import Path; p=Path(sys.argv[1]); d=json.loads(p.read_text()); d.update({"summary":"valid second semantic attempt","unit_ids_completed":["UNIT-1"],"acceptance_addressed":["AC-1"],"outcome_requested":"candidate_ready"}); p.write_text(json.dumps(d,indent=2,sort_keys=True)+"\n")' "$SEM"
"$OFLOOP_BIN" dispatch finalize "$REPO" "$RUN" BUILD "$SEM" >/dev/null
assert_eq "$(jq -r '.state' "$REPO/.ownframework-loop/$RUN/STATE.json")" "READY_FOR_REVIEW" "valid reseeded builder can finalize"

RORDER="$("$OFLOOP_BIN" dispatch claim "$REPO" "$RUN")"
RSEM="$(printf '%s' "$RORDER" | jq -r '.semantic_path')"
python3 -c 'import json,sys; from pathlib import Path; p=Path(sys.argv[1]); d=json.loads(p.read_text()); p.write_text(json.dumps({"schema_version":"1","run_id":sys.argv[2],"candidate_sha_claimed":d["candidate_sha_claimed"]},indent=2)+"\n")' "$RSEM" "$RUN"
RREADY="$(RORDER_JSON="$RORDER" python3 -c 'import json,os; from ownframework_loop import dispatch; print("|".join(map(str,dispatch.semantic_result_ready(json.loads(os.environ["RORDER_JSON"])))) )')"
assert_eq "$RREADY" "False|review_schema_mismatch" "malformed reviewer schema is retryable"
RRESEED="$(RORDER_JSON="$RORDER" python3 -c 'import json,os; from ownframework_loop import dispatch; print(json.dumps(dispatch.reseed_semantic_artifact_for_retry(json.loads(os.environ["RORDER_JSON"]),previous_attempt_id="review-attempt-1"),sort_keys=True))')"
RARCHIVE="$(printf '%s' "$RRESEED" | jq -r '.archive_path')"
assert_file_exists "$RARCHIVE" "malformed reviewer artifact archived"
assert_eq "$(python3 -c 'import os,sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "o"))' "$RARCHIVE")" "600" "reviewer archive mode"
assert_eq "$(jq -r '.schema' "$RSEM")" "ownframework-loop-review-agent-assessment/v1" "reviewer skeleton reseeded"

python3 -c 'from ownframework_loop import assessment,build_agent; good={k:"x" for k in build_agent.FIXED_KEYS}; good.update({"schema":build_agent.SCHEMA_AGENT_RESULT,"builder_identity":"of-builder","outcome_requested":"candidate_ready"}); assert build_agent.validate_agent_result_contract({**good,"schema":"wrong"}); assert build_agent.validate_agent_result_contract({**good,"builder_identity":"wrong"}); assert any("unsupported top-level keys" in e for e in build_agent.validate_agent_result_contract({**good,"unexpected":True})); review={k:"x" for k in assessment.FIXED_KEYS}; review.update({"schema":assessment.SCHEMA_AGENT_ASSESSMENT,"reviewer_identity":"of-reviewer"}); assert any("unsupported top-level keys" in e for e in assessment.validate_assessment_envelope_contract({**review,"unexpected":True})); print("FIXED_FIELDS_AND_UNKNOWN_KEYS_FAIL_CLOSED=PASS")'
python3 -c 'import json,sys; from pathlib import Path; p=Path(sys.argv[1]); d=json.loads(p.read_text()); d.update({"validation_results":[],"acceptance_results":[{"id":"AC-1","result":"pass","evidence":"reseeded review"}],"non_goal_results":[],"findings":[],"recommended_verdict":"APPROVED"}); p.write_text(json.dumps(d,indent=2,sort_keys=True)+"\n")' "$RSEM"
"$OFLOOP_BIN" dispatch finalize "$REPO" "$RUN" REVIEW "$RSEM" >/dev/null
assert_eq "$(jq -r '.verdict' "$REPO/.ownframework-loop/$RUN/REVIEW_VERDICT.json")" "APPROVED" "valid reseeded reviewer can finalize"
echo "SEMANTIC_RETRY_RESEED_REGRESSION=PASS"
