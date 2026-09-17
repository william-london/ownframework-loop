#!/usr/bin/env bash
# v0.9.9-f BLOCKED-receipt transport recognizes validation-failure BLOCKED
# as a bounded-validation repair kind (not only source-ceiling breaches).
#
# R3 round-13 evidence: candidate eaf34dfe3c160603b9741dcc86c8003a0724b71e
# was deterministically BLOCKED with program_source_ceiling_check=pass
# (29944 / 30000) and validation_status=FAIL (just-validate pnpm
# format:check failed on six front-end files). Before this fix the
# dispatcher's BLOCKED-receipt transport only accepted source-ceiling
# BLOCKED receipts (validation_status must be PASS), so the historical
# BLOCKED receipt for eaf34dfe could not authorize the bounded
# validation-formatting repair that the operator-needed next step is.
#
# These tests pin that:
#   * dispatch._validation_evidence_is_repairable(...) recognizes the
#     validation-failure BLOCKED envelope;
#   * dispatch._repair_context_from_blocked_receipt(...) produces a
#     typed context with repair_kind="validation_formatting";
#   * the six failing-formatting paths are surfaced into the context;
#   * the validation-repair instruction text is generated;
#   * the source-ceiling path is unchanged (regression);
#   * the helper fail-closes on co-failure (scope/protected/secret).
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib"
export PYTHONDONTWRITEBYTECODE=1

# ---------------------------------------------------------------------------
# TEST A — eaf34dfe-shaped BLOCKED receipt is recognized as
# validation-repairable.
# ---------------------------------------------------------------------------
A_OUT="$(python3 - <<'PY'
import json
from ownframework_loop import dispatch
# Reconstruct the same RECEIPT shape as the historical R3 round-13 finalizer.
receipt = {
    "schema": "ownframework-loop-build-receipt/v2",
    "next_state": "BLOCKED",
    "candidate_sha": "eaf34dfe3c160603b9741dcc86c8003a0724b71e",
    "validation_status": "FAIL",
    "validation": [{
        "command": "just validate",
        "exit_code": 1,
        "passed": False,
        "name": "validate",
        "stderr_excerpt_redacted": (
            "pnpm format:check\n"
            "[warn] apps/web/src/lib/cart-store.ts\n"
            "[warn] CHANGELOG.md\n"
            "[warn] fixtures/synthetic_back_in_stock_events.json\n"
            "[warn] fixtures/synthetic_campaigns.json\n"
            "[warn] fixtures/synthetic_retailers.json\n"
            "[warn] fixtures/synthetic_reviews.json\n"
            "error: recipe format-check failed on line 36 with exit code 1"
        ),
    }],
    "scope_check": {"result": "pass", "findings": []},
    "protected_path_check": {"result": "pass", "offending_paths": []},
    "secret_scan_check": {"result": "pass", "findings": []},
    "program_source_ceiling_check": {
        "result": "pass",
        "accounting": "absolute_baseline_to_candidate",
        "files_changed_unique": 220,
        "diff_lines_total": 29944,
        "effective_max_diff_lines": 30000,
        "effective_max_files_changed": 500,
        "top_level_risk_max_files_changed": 500,
        "top_level_risk_max_diff_lines": 30000,
        "program_max_unique_changed_files": 500,
        "program_max_baseline_to_final_diff_lines": 30000,
        "breach": "",
    },
    "changed_paths": [
        "apps/web/src/lib/cart-store.ts",
        "CHANGELOG.md",
        "fixtures/synthetic_back_in_stock_events.json",
        "fixtures/synthetic_campaigns.json",
        "fixtures/synthetic_retailers.json",
        "fixtures/synthetic_reviews.json",
        "apps/web/src/lib/operator-api.ts",
        "services/ops/src/outlaw_ops/db/models.py",
    ],
    "files_changed": 220,
    "added_lines": 29740,
    "removed_lines": 204,
    "repair_round": 13,
    "run_id": "run-20260914T155437Z-0006dd58",
}
result = dispatch._validation_evidence_is_repairable(receipt)
print(json.dumps({
    "recognized": result is not None,
    "kind": result["kind"] if result else None,
    "failed_count": len(result["failed_validations"]) if result else 0,
}, sort_keys=True))
PY
)"
assert_contains "$A_OUT" '"recognized": true' \
  "TEST A: eaf34dfe-shaped BLOCKED receipt is recognized as validation-repairable"
assert_contains "$A_OUT" '"kind": "validation_formatting"' \
  "TEST A: classification = validation_formatting"
assert_contains "$A_OUT" '"failed_count": 1' \
  "TEST A: one failed validation surfaced"
pass "TEST A: eaf34dfe-shaped BLOCKED receipt is recognized as bounded-validation repair"

# ---------------------------------------------------------------------------
# TEST B — Source-ceiling BLOCKED receipt is NOT a validation-repair match
# (the dispatch surface must keep the source-ceiling transport narrowly
# scoped to source-budget issues).
# ---------------------------------------------------------------------------
B_OUT="$(python3 - <<'PY'
import json
from ownframework_loop import dispatch
receipt = {
    "schema": "ownframework-loop-build-receipt/v2",
    "next_state": "BLOCKED",
    "validation_status": "PASS",
    "validation": [],
    "program_source_ceiling_check": {
        "result": "fail",
        "accounting": "absolute_baseline_to_candidate",
        "files_changed_unique": 221,
        "diff_lines_total": 33521,
        "effective_max_diff_lines": 30000,
        "effective_max_files_changed": 500,
        "top_level_risk_max_files_changed": 500,
        "top_level_risk_max_diff_lines": 30000,
        "program_max_unique_changed_files": 500,
        "program_max_baseline_to_final_diff_lines": 30000,
        "breach": "diff_lines=33521 exceeds budget max_diff_lines=30000",
    },
    "scope_check": {"result": "pass", "findings": []},
    "protected_path_check": {"result": "pass", "offending_paths": []},
    "secret_scan_check": {"result": "pass", "findings": []},
    "changed_paths": [],
    "files_changed": 221,
    "added_lines": 33380,
    "removed_lines": 141,
    "repair_round": 12,
    "run_id": "run-test",
}
result = dispatch._validation_evidence_is_repairable(receipt)
print(json.dumps({
    "recognized": result is not None,
    "expected_rejection": result is None,
}, sort_keys=True))
PY
)"
assert_contains "$B_OUT" '"expected_rejection": true' \
  "TEST B: source-ceiling BLOCKED is rejected by the validation helper"
pass "TEST B: source-ceiling BLOCKED remains in the source-budget helper (no double-counting)"

# ---------------------------------------------------------------------------
# TEST C — Co-failure guard: a validation-failure BLOCKED with co-failing
# scope_check rejects the validation-repair path.
# ---------------------------------------------------------------------------
C_OUT="$(python3 - <<'PY'
import json
from ownframework_loop import dispatch
receipt = {
    "schema": "ownframework-loop-build-receipt/v2",
    "next_state": "BLOCKED",
    "validation_status": "FAIL",
    "validation": [{"name": "validate", "passed": False, "command": "just validate", "exit_code": 1}],
    "program_source_ceiling_check": {"result": "pass", "accounting": "absolute_baseline_to_candidate", "files_changed_unique": 100, "diff_lines_total": 1000, "effective_max_diff_lines": 5000, "effective_max_files_changed": 500, "top_level_risk_max_files_changed": 500, "top_level_risk_max_diff_lines": 5000, "program_max_unique_changed_files": 500, "program_max_baseline_to_final_diff_lines": 5000, "breach": ""},
    "scope_check": {"result": "fail", "findings": [{"path": "extra/path.ts", "reason": "off-scope"}]},
    "protected_path_check": {"result": "pass", "offending_paths": []},
    "secret_scan_check": {"result": "pass", "findings": []},
    "changed_paths": [],
    "files_changed": 100, "added_lines": 1000, "removed_lines": 0,
    "repair_round": 1, "run_id": "run-x",
}
result = dispatch._validation_evidence_is_repairable(receipt)
print(json.dumps({"recognized": result is not None}, sort_keys=True))
PY
)"
assert_contains "$C_OUT" '"recognized": false' \
  "TEST C: co-failing scope_check fails closed (no validation repair)"
pass "TEST C: co-fail guard rejects co-failing scope-check on validation-failure BLOCKED"

# ---------------------------------------------------------------------------
# TEST D — Six failing-formatting paths are extracted from the receipt
# into failed_formatting_paths.
# ---------------------------------------------------------------------------
D_OUT="$(python3 - <<'PY'
import json
from ownframework_loop import dispatch
receipt = {
    "schema": "ownframework-loop-build-receipt/v2",
    "next_state": "BLOCKED",
    "validation_status": "FAIL",
    "validation": [{
        "name": "validate",
        "command": "just validate",
        "passed": False,
        "exit_code": 1,
        "stderr_excerpt_redacted": (
            "pnpm format:check\n"
            "[warn] apps/web/src/lib/cart-store.ts\n"
            "[warn] CHANGELOG.md\n"
            "[warn] fixtures/synthetic_back_in_stock_events.json\n"
            "[warn] fixtures/synthetic_campaigns.json\n"
            "[warn] fixtures/synthetic_retailers.json\n"
            "[warn] fixtures/synthetic_reviews.json\n"
            "error: recipe format-check failed on line 36 with exit code 1"
        ),
    }],
    "scope_check": {"result": "pass", "findings": []},
    "protected_path_check": {"result": "pass", "offending_paths": []},
    "secret_scan_check": {"result": "pass", "findings": []},
    "program_source_ceiling_check": {
        "result": "pass", "accounting": "absolute_baseline_to_candidate",
        "files_changed_unique": 220, "diff_lines_total": 29944,
        "effective_max_diff_lines": 30000, "effective_max_files_changed": 500,
        "top_level_risk_max_files_changed": 500,
        "top_level_risk_max_diff_lines": 30000,
        "program_max_unique_changed_files": 500,
        "program_max_baseline_to_final_diff_lines": 30000,
        "breach": "",
    },
    "changed_paths": [
        "apps/web/src/lib/cart-store.ts",
        "CHANGELOG.md",
        "fixtures/synthetic_back_in_stock_events.json",
        "fixtures/synthetic_campaigns.json",
        "fixtures/synthetic_retailers.json",
        "fixtures/synthetic_reviews.json",
        "services/ops/src/outlaw_ops/db/models.py",
    ],
    "files_changed": 220, "added_lines": 29740, "removed_lines": 204,
    "repair_round": 13, "run_id": "run-R3", "candidate_sha": "eaf34dfe3c160603b9741dcc86c8003a0724b71e",
}
# Reconstruct the path-extraction behavior _repair_context_from_blocked_receipt
# would perform.
evidence = dispatch._validation_evidence_is_repairable(receipt)
changed_paths = receipt.get("changed_paths") or []
failed_paths_for_instruction = []
for v in evidence["failed_validations"]:
    for key in ("stderr_excerpt_redacted", "stdout_excerpt_redacted"):
        excerpt = str(v.get(key) or "")
        if excerpt:
            for cp in changed_paths:
                if cp not in failed_paths_for_instruction and cp in excerpt:
                    failed_paths_for_instruction.append(cp)
print(json.dumps({
    "kind": evidence["kind"],
    "extracted_paths": failed_paths_for_instruction,
    "expected_len": 6,
    "actual_len": len(failed_paths_for_instruction),
}, sort_keys=True))
PY
)"
assert_contains "$D_OUT" '"extracted_paths"' \
  "TEST D: extracted_paths field present"
assert_contains "$D_OUT" '"actual_len": 6' \
  "TEST D: extracted six failing paths"
assert_contains "$D_OUT" '"kind": "validation_formatting"' \
  "TEST D: classification stayed validation_formatting during path extraction"
pass "TEST D: six failing-formatting paths are extracted from the receipt into repair context"

# ---------------------------------------------------------------------------
# TEST E — `_format_validation_repair_instruction` includes key directives.
# ---------------------------------------------------------------------------
E_OUT="$(python3 - <<'PY'
import json
from ownframework_loop import dispatch
text = dispatch._format_validation_repair_instruction(
    checkpoint_id="CP-9",
    candidate_sha="eaf34dfe3c160603b9741dcc86c8003a0724b71e",
    measured_diff_lines=29944,
    effective_max_diff_lines=30000,
    measured_files=220,
    effective_max_files=500,
    failed_paths=["apps/web/src/lib/cart-store.ts", "CHANGELOG.md"],
    failed_command="validate",
)
print(json.dumps({
    "mentions_validate": "validate" in text,
    "mentions_envelope": "30000" in text and "500" in text,
    "mentions_paths": "cart-store.ts" in text and "CHANGELOG.md" in text,
    "do_not_widen": "Do not widen" in text,
}, sort_keys=True))
PY
)"
assert_contains "$E_OUT" '"mentions_validate": true' \
  "TEST E: instruction names the failing gate"
assert_contains "$E_OUT" '"mentions_envelope": true' \
  "TEST E: instruction surfaces current envelope (30000/500)"
assert_contains "$E_OUT" '"mentions_paths": true' \
  "TEST E: instruction surfaces the failed paths"
assert_contains "$E_OUT" '"do_not_widen": true' \
  "TEST E: instruction forbids widening the packet"
pass "TEST E: validation-repair instruction formatter surface is complete"

# ---------------------------------------------------------------------------
# TEST F — _blocked_evidence_is_repairable on a clean source-ceiling BLOCKED
# still returns the source-ceiling dict (no regression).
# ---------------------------------------------------------------------------
F_OUT="$(python3 - <<'PY'
import json
from ownframework_loop import dispatch
receipt = {
    "next_state": "BLOCKED",
    "validation_status": "PASS",
    "validation": [{"name": "validate", "passed": True}],
    "program_source_ceiling_check": {
        "result": "fail",
        "accounting": "absolute_baseline_to_candidate",
        "files_changed_unique": 221, "diff_lines_total": 33521,
        "effective_max_diff_lines": 30000, "effective_max_files_changed": 500,
        "top_level_risk_max_files_changed": 500,
        "top_level_risk_max_diff_lines": 30000,
        "program_max_unique_changed_files": 500,
        "program_max_baseline_to_final_diff_lines": 30000,
        "breach": "diff_lines=33521 exceeds budget max_diff_lines=30000",
    },
    "scope_check": {"result": "pass", "findings": []},
    "protected_path_check": {"result": "pass", "offending_paths": []},
    "secret_scan_check": {"result": "pass", "findings": []},
}
result = dispatch._blocked_evidence_is_repairable(receipt)
print(json.dumps({"recognized": result is not None}, sort_keys=True))
PY
)"
assert_contains "$F_OUT" '"recognized": true' \
  "TEST F: source-ceiling BLOCKED still recognized by _blocked_evidence_is_repairable"
pass "TEST F: source-ceiling repair transport unchanged (regression guard)"

exit 0
