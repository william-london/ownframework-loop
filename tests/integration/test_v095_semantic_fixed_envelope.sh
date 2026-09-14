#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib"
export PYTHONDONTWRITEBYTECODE=1

BUILDER_VALUES='{"schema":"ownframework-loop-build-agent-result/vX","run_id":"run-other","work_unit_id":"UNIT-other","candidate_branch":"other-branch","baseline_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","packet_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","approval_sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","builder_identity":"of-builder-other"}'

REPO="$(make_tmp_repo)"
RUN="$(make_approved_run "$REPO" FEATURE low builder-fixed-values)"
ORDER="$($OFLOOP_BIN dispatch claim "$REPO" "$RUN")"
SEM="$(printf '%s' "$ORDER" | jq -r '.semantic_path')"
BUILDER_RESULT="$(ORDER_JSON="$ORDER" SEM="$SEM" VALUES="$BUILDER_VALUES" python3 - <<'PY'
import json, os
from pathlib import Path
from ownframework_loop import build_agent, dispatch, util
order=json.loads(os.environ["ORDER_JSON"]); sem=Path(os.environ["SEM"]); values=json.loads(os.environ["VALUES"])
out=[]
for field, value in values.items():
    d=build_agent.build_skeleton(Path(order["canonical_repo"]), order["run_id"])
    d.update({"summary":"valid", "unit_ids_completed":["UNIT-1"], "acceptance_addressed":["AC-1"], field:value})
    util.atomic_write_json(sem, d)
    ready, reason=dispatch.semantic_result_ready(order)
    assert not ready, (field, ready, reason)
    assert reason in dispatch._RETRYABLE_SEMANTIC_RESULT_REASONS, (field, reason)
    out.append(field+":"+reason)
print(";".join(out))
PY
)"
assert_contains "$BUILDER_RESULT" "schema:builder_schema_mismatch" "builder schema drift rejected"
assert_contains "$BUILDER_RESULT" "run_id:semantic_run_id_mismatch" "builder run identity drift rejected"
assert_contains "$BUILDER_RESULT" "work_unit_id:builder_fixed_identity_mismatch" "builder work-unit drift rejected"
assert_contains "$BUILDER_RESULT" "packet_sha256:builder_fixed_identity_mismatch" "builder packet drift rejected"
assert_contains "$BUILDER_RESULT" "approval_sha256:builder_fixed_identity_mismatch" "builder approval drift rejected"
assert_contains "$BUILDER_RESULT" "baseline_sha:builder_fixed_identity_mismatch" "builder baseline drift rejected"
echo "BUILDER_FIXED_VALUE_POISONING=PASS"

REPO2="$(make_tmp_repo)"
RUN2="$(make_approved_run "$REPO2" FEATURE low reviewer-fixed-values)"
ORDER2="$($OFLOOP_BIN dispatch claim "$REPO2" "$RUN2")"
SEM2="$(printf '%s' "$ORDER2" | jq -r '.semantic_path')"
python3 - "$SEM2" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); d=json.loads(p.read_text())
d.update({"summary":"valid","unit_ids_completed":["UNIT-1"],"acceptance_addressed":["AC-1"]})
p.write_text(json.dumps(d,sort_keys=True)+"\n")
PY
"$OFLOOP_BIN" dispatch finalize "$REPO2" "$RUN2" BUILD "$SEM2" >/dev/null
RO2="$($OFLOOP_BIN dispatch claim "$REPO2" "$RUN2")"
RS2="$(printf '%s' "$RO2" | jq -r '.semantic_path')"
REVIEW_VALUES='{"schema":"ownframework-loop-review-agent-assessment/vX","run_id":"run-other","candidate_sha_claimed":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","reviewer_worktree":"/tmp/other-reviewer","reviewer_head_before":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","reviewer_head_after":"cccccccccccccccccccccccccccccccccccccccc","packet_sha256_recomputed":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","approval_sha256":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","build_receipt_sha256":"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff","scope_findings":[{"path":"poison"}],"protected_findings":[{"path":"poison"}],"secret_findings":[{"path":"poison"}],"reviewer_identity":"of-reviewer-other"}'
REVIEW_RESULT="$(ORDER_JSON="$RO2" SEM="$RS2" VALUES="$REVIEW_VALUES" python3 - <<'PY'
import json, os
from pathlib import Path
from ownframework_loop import assessment, dispatch, util
order=json.loads(os.environ["ORDER_JSON"]); sem=Path(os.environ["SEM"]); values=json.loads(os.environ["VALUES"])
out=[]
for field, value in values.items():
    d=assessment.build_skeleton(Path(order["canonical_repo"]), order["run_id"])
    d.update({"validation_results":[],"acceptance_results":[{"id":"AC-1","result":"pass","evidence":"valid"}],"non_goal_results":[],"findings":[],"recommended_verdict":"APPROVED",field:value})
    util.atomic_write_json(sem, d)
    ready, reason=dispatch.semantic_result_ready(order)
    assert not ready, (field, ready, reason)
    assert reason in dispatch._RETRYABLE_SEMANTIC_RESULT_REASONS, (field, reason)
    out.append(field+":"+reason)
print(";".join(out))
PY
)"
assert_contains "$REVIEW_RESULT" "schema:review_schema_mismatch" "reviewer schema drift rejected"
assert_contains "$REVIEW_RESULT" "run_id:semantic_run_id_mismatch" "reviewer run identity drift rejected"
assert_contains "$REVIEW_RESULT" "candidate_sha_claimed:review_fixed_identity_mismatch" "reviewer candidate drift rejected"
assert_contains "$REVIEW_RESULT" "reviewer_worktree:review_fixed_identity_mismatch" "reviewer worktree drift rejected"
assert_contains "$REVIEW_RESULT" "packet_sha256_recomputed:review_fixed_identity_mismatch" "reviewer packet drift rejected"
assert_contains "$REVIEW_RESULT" "build_receipt_sha256:review_fixed_identity_mismatch" "reviewer receipt drift rejected"
assert_contains "$REVIEW_RESULT" "scope_findings:review_fixed_identity_mismatch" "reviewer scope drift rejected"
assert_contains "$REVIEW_RESULT" "reviewer_identity:review_fixed_identity_mismatch" "reviewer identity drift rejected"
echo "REVIEWER_FIXED_VALUE_POISONING=PASS"
echo "SEMANTIC_FIXED_ENVELOPE_REGRESSION=PASS"
