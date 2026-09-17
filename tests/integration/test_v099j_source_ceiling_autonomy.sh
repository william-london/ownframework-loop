#!/usr/bin/env bash
# v0.9.9-j: repairable source-budget breach → CHANGES_REQUESTED
# autonomous transition (no continue-program ceremony required).
#
# The clean source-budget breach (program_source_ceiling_check=fail with
# scope/protected/secret/identity clean and validation_status=PASS) used to
# require operator `continue-program` to authorize a fresh repair round.
# Now the build finalizer atomically funds a repair entitlement and
# transitions BUILDING → CHANGES_REQUESTED, surfacing the source-budget
# breach evidence through the dispatch site's repair context.
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

# TEST A - dispatch repair_context_from_receipt surfaces source-budget breach.
A_OUT="$(python3 <<'PYEOF'
import sys
sys.path.insert(0, "/Users/mr.mrs.london/projects/ownframework-loop/lib")
import json
from ownframework_loop import dispatch
state = {
  "state": "BUILDING",
  "repair_round": 1,
  "last_candidate_sha": "8832aa1ccc1e85e64162eee8e77ac64e41826555",
  "program": {
    "current_checkpoints": ["CP-10"],
    "checkpoints": [],
  },
}
receipt = {
  "schema": "ownframework-loop-build-receipt/v2",
  "run_id": "run-x",
  "candidate_sha": "8832aa1ccc1e85e64162eee8e77ac64e41826555",
  "next_state": "CHANGES_REQUESTED",
  "validation": [{"name": "v", "passed": True, "exit_code": 0,
                 "expected_exit_code": 0, "duration_seconds": 1.0}],
  "validation_status": "PASS",
  "scope_check": {"result": "pass", "findings": []},
  "protected_path_check": {"result": "pass", "offending_paths": []},
  "secret_scan_check": {"result": "pass", "findings": []},
  "program_source_ceiling_check": {
    "result": "fail",
    "accounting": "absolute_baseline_to_candidate",
    "diff_lines_total": 33521,
    "effective_max_diff_lines": 30000,
    "files_changed_unique": 240,
    "effective_max_files_changed": 500,
    "breach": "over by 3521 diff_lines",
  },
}
ctx = dispatch._repair_context_from_receipt(
    canonical_repo=__import__("pathlib").Path("/tmp/none"),
    run_id="run-x",
    state_doc=state,
)
# Inject the receipt path so we can monkey-patch read
class _P:
    def __init__(self, p):
        self._p = p
    def resolve(self, strict=False):
        return self._p
import unittest.mock as _mock
real_path = dispatch._repair_context_from_receipt.__globals__["state_mod"].run_dir
real_path_resolved = "/Users/mr.mrs.london/.local/state/ownframework-loop/run-x"
with _mock.patch.object(dispatch, "_load_json_file", return_value=receipt), \
     _mock.patch.object(dispatch.state_mod, "run_dir",
                        return_value=__import__("pathlib").Path(real_path_resolved)):
    ctx = dispatch._repair_context_from_receipt(
        canonical_repo=__import__("pathlib").Path("/tmp/none"),
        run_id="run-x",
        state_doc=state,
    )
print("ctx_present", ctx is not None)
if ctx is not None:
    print("failure_reason", ctx.get("failure_reason"))
    breach = ctx.get("source_ceiling_breach")
    print("breach_present", breach is not None)
    if breach is not None:
        print("breach_checkpoint", breach.get("checkpoint_id"))
        print("breach_diff_lines", breach.get("measured_diff_lines"))
        print("breach_max_diff", breach.get("effective_max_diff_lines"))
        print("breach_files", breach.get("measured_files"))
        print("breach_max_files", breach.get("effective_max_files"))
        print("breach_text", breach.get("breach"))
PYEOF
)"
assert_in "$A_OUT" "ctx_present True" "TEST A: repair context returned for CHANGES_REQUESTED receipt"
assert_in "$A_OUT" "failure_reason build_finalizer_source_budget_breach" "TEST A: failure_reason names source-budget breach"
assert_in "$A_OUT" "breach_present True" "TEST A: source_ceiling_breach evidence surfaced"
assert_in "$A_OUT" "breach_checkpoint CP-10" "TEST A: breach carries checkpoint_id"
assert_in "$A_OUT" "breach_diff_lines 33521" "TEST A: breach carries measured diff_lines"
assert_in "$A_OUT" "breach_max_diff 30000" "TEST A: breach carries effective max diff_lines"
assert_in "$A_OUT" "breach_files 240" "TEST A: breach carries measured files"
assert_in "$A_OUT" "breach_max_files 500" "TEST A: breach carries effective max files"

# TEST B - failure_reason priority: source-budget wins over validation.
B_OUT="$(python3 <<'PYEOF'
import sys
sys.path.insert(0, "/Users/mr.mrs.london/projects/ownframework-loop/lib")
import unittest.mock as _mock
import pathlib
from ownframework_loop import dispatch
state = {
  "state": "BUILDING",
  "repair_round": 1,
  "last_candidate_sha": "8832aa1ccc1e85e64162eee8e77ac64e41826555",
  "program": {"current_checkpoints": ["CP-10"], "checkpoints": []},
}
receipt = {
  "schema": "ownframework-loop-build-receipt/v2",
  "run_id": "run-x",
  "candidate_sha": "8832aa1ccc1e85e64162eee8e77ac64e41826555",
  "next_state": "CHANGES_REQUESTED",
  "validation": [
    {"name": "v1", "passed": False, "exit_code": 1,
     "expected_exit_code": 0, "duration_seconds": 1.0},
    {"name": "v2", "passed": True, "exit_code": 0,
     "expected_exit_code": 0, "duration_seconds": 1.0},
  ],
  "validation_status": "FAIL",
  "scope_check": {"result": "pass", "findings": []},
  "protected_path_check": {"result": "pass", "offending_paths": []},
  "secret_scan_check": {"result": "pass", "findings": []},
  "program_source_ceiling_check": {
    "result": "fail",
    "accounting": "absolute_baseline_to_candidate",
    "diff_lines_total": 35000,
    "effective_max_diff_lines": 30000,
    "files_changed_unique": 240,
    "effective_max_files_changed": 500,
    "breach": "over by 5000 diff_lines",
  },
}
with _mock.patch.object(dispatch, "_load_json_file", return_value=receipt), \
     _mock.patch.object(dispatch.state_mod, "run_dir",
                        return_value=pathlib.Path("/tmp/x")):
    ctx = dispatch._repair_context_from_receipt(
        canonical_repo=pathlib.Path("/tmp/none"),
        run_id="run-x",
        state_doc=state,
    )
print("failure_reason", ctx.get("failure_reason") if ctx else None)
print("breach_present", (ctx or {}).get("source_ceiling_breach") is not None)
print("failed_validations_count", len((ctx or {}).get("failed_validation_results") or []))
PYEOF
)"
assert_in "$B_OUT" "failure_reason build_finalizer_source_budget_breach" "TEST B: source-budget reason wins when both fail"
assert_in "$B_OUT" "breach_present True" "TEST B: source-budget breach evidence preserved on co-failure"
assert_in "$B_OUT" "failed_validations_count 1" "TEST B: failed validation rows still surfaced for co-failure context"

# TEST C - validation-only failure keeps validation failure_reason.
C_OUT="$(python3 <<'PYEOF'
import sys
sys.path.insert(0, "/Users/mr.mrs.london/projects/ownframework-loop/lib")
import unittest.mock as _mock
import pathlib
from ownframework_loop import dispatch
state = {
  "state": "BUILDING",
  "repair_round": 1,
  "last_candidate_sha": "8832aa1ccc1e85e64162eee8e77ac64e41826555",
  "program": {"current_checkpoints": ["CP-10"], "checkpoints": []},
}
receipt = {
  "schema": "ownframework-loop-build-receipt/v2",
  "run_id": "run-x",
  "candidate_sha": "8832aa1ccc1e85e64162eee8e77ac64e41826555",
  "next_state": "CHANGES_REQUESTED",
  "validation": [{"name": "format_check", "passed": False,
                 "exit_code": 1, "expected_exit_code": 0, "duration_seconds": 1.0}],
  "validation_status": "FAIL",
  "scope_check": {"result": "pass", "findings": []},
  "protected_path_check": {"result": "pass", "offending_paths": []},
  "secret_scan_check": {"result": "pass", "findings": []},
}
with _mock.patch.object(dispatch, "_load_json_file", return_value=receipt), \
     _mock.patch.object(dispatch.state_mod, "run_dir",
                        return_value=pathlib.Path("/tmp/x")):
    ctx = dispatch._repair_context_from_receipt(
        canonical_repo=pathlib.Path("/tmp/none"),
        run_id="run-x",
        state_doc=state,
    )
print("failure_reason", ctx.get("failure_reason") if ctx else None)
print("breach_present", (ctx or {}).get("source_ceiling_breach") is not None)
PYEOF
)"
assert_in "$C_OUT" "failure_reason build_finalizer_validation_failed" "TEST C: validation-only keeps validation failure_reason"
assert_in "$C_OUT" "breach_present False" "TEST C: validation-only has no source_ceiling_breach block"

# TEST D - BLOCKED receipt for source-budget still requires continuation.
D_OUT="$(python3 <<'PYEOF'
import sys
sys.path.insert(0, "/Users/mr.mrs.london/projects/ownframework-loop/lib")
from ownframework_loop import dispatch
receipt_blocked = {
  "schema": "ownframework-loop-build-receipt/v2",
  "run_id": "run-x",
  "next_state": "BLOCKED",
  "candidate_sha": "8832aa1ccc1e85e64162eee8e77ac64e41826555",
  "validation": [{"name": "v", "passed": True, "exit_code": 0,
                 "expected_exit_code": 0, "duration_seconds": 1.0}],
  "validation_status": "PASS",
  "scope_check": {"result": "pass", "findings": []},
  "protected_path_check": {"result": "pass", "offending_paths": []},
  "secret_scan_check": {"result": "pass", "findings": []},
  "program_source_ceiling_check": {
    "result": "fail",
    "accounting": "absolute_baseline_to_candidate",
    "diff_lines_total": 35000,
    "effective_max_diff_lines": 30000,
    "files_changed_unique": 240,
    "effective_max_files_changed": 500,
    "breach": "over by 5000 diff_lines",
  },
}
# Without a continuation receipt, BLOCKED source-budget must remain BLOCKED.
ps = dispatch._blocked_evidence_is_repairable(receipt_blocked)
print("ps_blocked_no_continuation", ps is not None)
PYEOF
)"
assert_in "$D_OUT" "ps_blocked_no_continuation True" "TEST D: BLOCKED source-budget evidence is still recognized (for legacy continuation path)"

exit 0
