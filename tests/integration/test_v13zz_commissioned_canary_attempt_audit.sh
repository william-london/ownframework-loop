#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"

AUDIT="$ROOT_DIR/tests/canary/commissioned_program_attempt_audit.py"
HARNESS="$ROOT_DIR/tests/canary/commissioned_program_canary.sh"
bash -n "$HARNESS" || fail "commissioned canary shell syntax invalid"

PYTHONDONTWRITEBYTECODE=1 python3 -B - "$AUDIT" <<'PY' || fail "semantic-attempt audit invariant failed"
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("canary_attempt_audit", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

roles = ["builder", "reviewer", "builder", "reviewer", "builder", "reviewer", "reviewer"]
def row(index, role, *, status="COMPLETED", accepted=True, failure_class=None, failure_reason=None):
    return {
        "attempt_id": f"attempt-{index}",
        "role": role,
        "status": status,
        "semantic_accepted": int(accepted),
        "started_at": index * 20 + 1,
        "completed_at": index * 20 + 10,
        "returncode": 0,
        "cost_usd": 0.25,
        "cost_accounted": 1,
        "cost_known": 1,
        "tokens_known": 1,
        "input_tokens": 10,
        "output_tokens": 5,
        "cache_read_tokens": 7,
        "cache_creation_tokens": 0,
        "failure_class": failure_class,
        "failure_reason": failure_reason,
        "accepted_semantic_sha256": "a" * 64 if accepted else "",
        "accepted_candidate_sha": "f" * 40 if accepted else "",
        "accepted_at": index * 20 + 11 if accepted else 0,
    }

def totals(rows):
    return {
        "total_cost_usd": sum(r["cost_usd"] for r in rows),
        "total_input_tokens": sum(r["input_tokens"] for r in rows),
        "total_output_tokens": sum(r["output_tokens"] for r in rows),
        "total_cache_read_tokens": sum(r["cache_read_tokens"] for r in rows),
        "total_cache_creation_tokens": sum(r["cache_creation_tokens"] for r in rows),
    }

base = [row(i, role) for i, role in enumerate(roles)]
assert module.audit_semantic_attempts(
    base, expected_accepted_roles=roles, final_candidate_sha="f" * 40,
    job_totals=totals(base),
)["failed_retry_count"] == 0

with_retry = [row(i, role) for i, role in enumerate(roles[:-1])]
with_retry.extend([
    row(6, "reviewer", status="FAILED", accepted=False,
        failure_class="runner", failure_reason="semantic_result_incomplete"),
    row(7, "reviewer"),
])
assert module.audit_semantic_attempts(
    with_retry, expected_accepted_roles=roles, final_candidate_sha="f" * 40,
    job_totals=totals(with_retry),
)["failed_retry_count"] == 1

def rejected(rows, label):
    try:
        module.audit_semantic_attempts(
            rows, expected_accepted_roles=roles, final_candidate_sha="f" * 40,
            job_totals=totals(rows),
        )
    except (AssertionError, KeyError, TypeError, ValueError):
        return
    raise AssertionError(f"audit accepted invalid fixture: {label}")

unaccounted = [dict(r) for r in with_retry]
unaccounted[6]["cost_accounted"] = 0
rejected(unaccounted, "unaccounted failure")
rejected(with_retry[:-1], "failure without retry")
wrong_class = [dict(r) for r in with_retry]
wrong_class[6]["failure_reason"] = "unknown_failure"
rejected(wrong_class, "unclassified failure")
wrong_total = totals(with_retry)
wrong_total["total_output_tokens"] += 1
try:
    module.audit_semantic_attempts(
        with_retry, expected_accepted_roles=roles, final_candidate_sha="f" * 40,
        job_totals=wrong_total,
    )
except AssertionError:
    pass
else:
    raise AssertionError("audit accepted inconsistent token totals")

print("CANARY_ACCEPTS_AUTHORIZED_FAILED_AND_ACCOUNTED_RETRY=PASS")
print("CANARY_REJECTS_UNACCOUNTED_OR_ORPHAN_FAILURE=PASS")
print("CANARY_REJECTS_UNKNOWN_FAILURE_CLASS=PASS")
print("CANARY_RECONCILES_COST_AND_TOKEN_TOTALS=PASS")
PY

pass "commissioned canary verifies semantic lifecycle and accounting independent of raw attempt count"
echo "V13ZZ_COMMISSIONED_CANARY_ATTEMPT_AUDIT=PASS"
