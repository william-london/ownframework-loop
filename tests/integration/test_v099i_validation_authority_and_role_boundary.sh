#!/usr/bin/env bash
# v0.9.9-i: generic validation-status canonicalization + explicit
# BUILD-vs-REVIEW semantic-completion role boundary.
#
# Three narrow generic defects are addressed:
#
#   1. The receipt top-level `validation_pass` boolean was missing — every
#      repair classifier defaulted `validation_pass=True`, so a real
#      validation-only failure (clean source envelope, FAIL validation)
#      could never be classified as a bounded-validation repair. The
#      canonical helper `compute_validation_status` derives PASS/FAIL/UNKNOWN
#      from the authoritative `validation` rows and writes it to the receipt.
#
#   2. `_program_source_ceiling_is_repairable` and
#      `_validation_evidence_is_repairable` both consumed the boolean
#      default. They now consume `validation_status` and fail closed on
#      UNKNOWN.
#
#   3. `_maybe_complete_semantic_artifact` was reachable from REVIEW
#      dispatches and operated on the builder artifact as a side effect.
#      REVIEW is now refused at the boundary; only `_publish_acceptance_for_ready_artifact`
#      is permitted for review provenance publication.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib"
export PYTHONDONTWRITEBYTECODE=1

assert_in() {
  local haystack="$1" needle="$2" msg="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "$msg: needle missing: $needle"
  fi
  pass "$msg"
}

# TEST A - canonical helper derivation PASS / FAIL / UNKNOWN.
A_OUT="$(python3 <<'PYEOF'
import json
from ownframework_loop import receipts
empty = receipts.compute_validation_status([])
malformed = receipts.compute_validation_status([{"foo": "bar"}])
mixed_pass = receipts.compute_validation_status([
    {"name": "v1", "passed": True, "exit_code": 0, "expected_exit_code": 0},
])
mixed_fail_passed = receipts.compute_validation_status([
    {"name": "v1", "passed": False, "exit_code": 1, "expected_exit_code": 0},
])
exit_code_mismatch = receipts.compute_validation_status([
    {"name": "v1", "passed": True, "exit_code": 2, "expected_exit_code": 0},
])
no_passed_key = receipts.compute_validation_status([
    {"name": "v1", "exit_code": 0, "expected_exit_code": 0},
])
non_list = receipts.compute_validation_status(None)
print(json.dumps({
  "empty": empty,
  "malformed": malformed,
  "all_pass": mixed_pass,
  "any_fail": mixed_fail_passed,
  "exit_mismatch": exit_code_mismatch,
  "no_passed_key": no_passed_key,
  "non_list": non_list,
}))
PYEOF
)"
assert_in "$A_OUT" '"all_pass": "PASS"' "TEST A: all rows passed → PASS"
assert_in "$A_OUT" '"any_fail": "FAIL"' "TEST A: any row passed=False → FAIL"
assert_in "$A_OUT" '"exit_mismatch": "FAIL"' "TEST A: exit_code mismatch → FAIL"
assert_in "$A_OUT" '"empty": "PASS"' "TEST A: explicit empty list → PASS"
assert_in "$A_OUT" '"malformed": "UNKNOWN"' "TEST A: malformed row → UNKNOWN"
assert_in "$A_OUT" '"no_passed_key": "UNKNOWN"' "TEST A: missing passed key → UNKNOWN"
assert_in "$A_OUT" '"non_list": "UNKNOWN"' "TEST A: non-list input → UNKNOWN"

# TEST B - receipt writer propagates validation_status.
B_OUT="$(python3 <<'PYEOF'
import json, tempfile, pathlib
from ownframework_loop import receipts
rec = receipts.new_receipt(
    run_id="run-x",
    packet_sha256="a" * 64,
    approval_sha256="b" * 64,
    work_unit_id="UNIT-1",
    baseline_sha="c" * 40,
    candidate_sha="d" * 40,
    candidate_branch="master",
    builder_worktree="/tmp/wt",
    builder_pass_number=1,
    repair_round=0,
    files_changed=0,
    added_lines=0,
    removed_lines=0,
    changed_paths=[],
    validation=[{"name": "v", "command": "echo", "passed": True,
                 "exit_code": 0, "expected_exit_code": 0, "duration_seconds": 0.0}],
    protected_path_check={"result": "pass", "offending_paths": []},
    secret_scan_check={"result": "pass", "findings": []},
    scope_check={"result": "pass", "findings": []},
    sensitive_path_assessment={"result": "none", "paths": []},
    additional_review_required=False,
    builder_agent="of-builder",
    next_state="READY_FOR_REVIEW",
)
print("status", rec.get("validation_status"))
print("schema", rec.get("schema"))
# Also test FAIL derivation:
rec_fail = receipts.new_receipt(
    run_id="run-x",
    packet_sha256="a" * 64,
    approval_sha256="b" * 64,
    work_unit_id="UNIT-1",
    baseline_sha="c" * 40,
    candidate_sha="d" * 40,
    candidate_branch="master",
    builder_worktree="/tmp/wt",
    builder_pass_number=1,
    repair_round=0,
    files_changed=0,
    added_lines=0,
    removed_lines=0,
    changed_paths=[],
    validation=[{"name": "v", "command": "echo", "passed": False,
                 "exit_code": 1, "expected_exit_code": 0, "duration_seconds": 0.0}],
    protected_path_check={"result": "pass", "offending_paths": []},
    secret_scan_check={"result": "pass", "findings": []},
    scope_check={"result": "pass", "findings": []},
    sensitive_path_assessment={"result": "none", "paths": []},
    additional_review_required=False,
    builder_agent="of-builder",
    next_state="CHANGES_REQUESTED",
)
print("status_fail", rec_fail.get("validation_status"))
PYEOF
)"
assert_in "$B_OUT" "status PASS" "TEST B: receipt writer derives PASS from rows"
assert_in "$B_OUT" "status_fail FAIL" "TEST B: receipt writer derives FAIL from rows"

# TEST C - dispatch consumers fail closed on UNKNOWN.
C_OUT="$(python3 <<'PYEOF'
import os
import sys
sys.path.insert(0, os.environ.get("OFLOOP_TEST_LIB") or (os.path.dirname(os.path.dirname(os.path.abspath(__file__))) + "/lib"))
from ownframework_loop import dispatch
unknown_receipt = {
  "program_source_ceiling_check": {
    "result": "fail", "accounting": "absolute_baseline_to_candidate",
    "diff_lines_total": 31000, "effective_max_diff_lines": 30000,
    "files_changed_unique": 240, "effective_max_files_changed": 500,
    "breach": "over by 1000 lines",
  },
  "scope_check": {"result": "pass", "findings": []},
  "protected_path_check": {"result": "pass", "offending_paths": []},
  "secret_scan_check": {"result": "pass", "findings": []},
  "validation": [],
}
# No validation_status key → UNKNOWN fail-closed
ps = dispatch._blocked_evidence_is_repairable(unknown_receipt)
print("ps_unknown", ps is None)
# Explicit UNKNOWN status → still fails closed
unknown_receipt["validation_status"] = "UNKNOWN"
ps2 = dispatch._blocked_evidence_is_repairable(unknown_receipt)
print("ps_explicit_unknown", ps2 is None)
# validation_formatting helper requires FAIL
val_evidence = dispatch._validation_evidence_is_repairable(unknown_receipt)
print("val_unknown", val_evidence is None)
# When status = FAIL, source-ceiling helper should still require PASS
fail_receipt = dict(unknown_receipt, validation_status="FAIL")
ps_fail = dispatch._blocked_evidence_is_repairable(fail_receipt)
print("ps_when_val_fail", ps_fail is None)
# When status = PASS, source-ceiling helper accepts
pass_receipt = dict(unknown_receipt, validation_status="PASS")
ps_pass = dispatch._blocked_evidence_is_repairable(pass_receipt)
print("ps_when_val_pass", ps_pass is not None)
PYEOF
)"
assert_in "$C_OUT" "ps_unknown True" "TEST C: missing validation_status fails closed (source-ceiling)"
assert_in "$C_OUT" "ps_explicit_unknown True" "TEST C: UNKNOWN status fails closed (source-ceiling)"
assert_in "$C_OUT" "val_unknown True" "TEST C: UNKNOWN status fails closed (validation)"
assert_in "$C_OUT" "ps_when_val_fail True" "TEST C: source-ceiling refuses co-failing validation"
assert_in "$C_OUT" "ps_when_val_pass True" "TEST C: source-ceiling accepts when validation PASS"

# TEST D - REVIEW dispatch refused at the completion boundary.
D_OUT="$(python3 <<'PYEOF'
import os, sqlite3, tempfile, pathlib
sys = __import__("sys")
sys.path.insert(0, os.environ.get("OFLOOP_TEST_LIB") or (os.path.dirname(os.path.dirname(os.path.abspath(__file__))) + "/lib"))
from ownframework_loop import supervisor
root = pathlib.Path(tempfile.mkdtemp(prefix="ofloop-h-d-"))
subprocess = __import__("subprocess")
subprocess.run(["git", "init", "-b", "master"], cwd=str(root), capture_output=True)
subprocess.run(["git", "config", "user.email", "t@t"], cwd=str(root), capture_output=True)
subprocess.run(["git", "config", "user.name", "t"], cwd=str(root), capture_output=True)
# A REVIEW work order
review_wo = {
  "schema": "ownframework-loop-dispatch/v1",
  "decision": "REVIEW",
  "role": "reviewer",
  "run_id": "run-x",
  "state": "REVIEWING",
  "canonical_repo": str(root),
  "worktree": str(root),
  "candidate_branch": "master",
  "baseline_sha": "x" * 40,
  "packet_sha256": "y" * 64,
  "approval_sha256": "z" * 64,
  "semantic_path": str(root / "review.json"),
}
conn = sqlite3.connect(":memory:")
result = supervisor._maybe_complete_semantic_artifact(
    conn=conn, work_order=review_wo,
    semantic_reason="review_recommended_verdict_empty",
    job_id=1,
)
print("review_refused", result is False)
# A BUILD work order
build_wo = dict(review_wo, decision="BUILD", role="builder",
               semantic_path=str(root / "build.json"))
result_b = supervisor._maybe_complete_semantic_artifact(
    conn=conn, work_order=build_wo,
    semantic_reason="builder_summary_empty",
    job_id=1,
)
print("build_no_artifact", result_b is False)
PYEOF
)"
assert_in "$D_OUT" "review_refused True" "TEST D: REVIEW dispatch is refused at completion boundary"
assert_in "$D_OUT" "build_no_artifact True" "TEST D: BUILD dispatch with missing artifact returns False (no false positive)"

exit 0
