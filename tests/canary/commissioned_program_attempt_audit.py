"""Semantic-attempt invariants for the commissioned PROGRAM canary."""

from __future__ import annotations

import math
from typing import Any, Iterable


_NONTERMINAL = {"RESERVED", "STARTED", "RUNNING", "CLAIMED"}
_RETRYABLE_FAILURES = {("runner", "semantic_result_incomplete")}


def audit_semantic_attempts(
    attempts: Iterable[dict[str, Any]],
    *,
    expected_accepted_roles: list[str],
    final_candidate_sha: str,
    job_totals: dict[str, Any],
) -> dict[str, int]:
    """Validate accepted work, authorized retries, and attempt-level totals.

    A failed semantic response is retained as a real, accounted attempt. It is
    not itself an accepted BUILD/REVIEW claim; the same role must subsequently
    complete successfully under Loop's retry path. The lifecycle expectation
    is therefore expressed over accepted semantic work, not raw attempt count.
    """
    rows = [dict(row) for row in attempts]
    if not rows:
        raise AssertionError("semantic attempt ledger is empty")

    ids = [str(row.get("attempt_id") or "") for row in rows]
    if any(not value for value in ids) or len(set(ids)) != len(ids):
        raise AssertionError("semantic attempt IDs are missing or duplicated")
    if any(str(row.get("status") or "") in _NONTERMINAL for row in rows):
        raise AssertionError("nonterminal semantic attempt remains at PROGRAM completion")

    accepted: list[dict[str, Any]] = []
    failed_retry_count = 0
    for index, row in enumerate(rows):
        status = str(row.get("status") or "")
        is_accepted = bool(int(row.get("semantic_accepted") or 0))
        if status == "COMPLETED":
            if not is_accepted:
                raise AssertionError(f"completed semantic attempt is not accepted: {ids[index]}")
            if not row.get("accepted_semantic_sha256") or float(row.get("accepted_at") or 0) <= 0:
                raise AssertionError(f"accepted semantic attempt lacks provenance: {ids[index]}")
            accepted.append(row)
            continue

        if status != "FAILED" or is_accepted:
            raise AssertionError(f"unexplained terminal attempt state for {ids[index]}: {status}")
        failure = (str(row.get("failure_class") or ""), str(row.get("failure_reason") or ""))
        if failure not in _RETRYABLE_FAILURES:
            raise AssertionError(f"failed attempt has no canary-authorized retry class: {failure}")
        if (
            not int(row.get("cost_accounted") or 0)
            or not int(row.get("cost_known") or 0)
            or not int(row.get("tokens_known") or 0)
            or row.get("completed_at") is None
            or row.get("returncode") != 0
            or row.get("accepted_semantic_sha256")
            or row.get("accepted_candidate_sha")
            or float(row.get("accepted_at") or 0) != 0
        ):
            raise AssertionError(f"failed attempt accounting/provenance is contradictory: {ids[index]}")
        if index + 1 >= len(rows):
            raise AssertionError(f"failed attempt has no subsequent authorized retry: {ids[index]}")
        retry = rows[index + 1]
        if (
            str(retry.get("status") or "") != "COMPLETED"
            or not int(retry.get("semantic_accepted") or 0)
            or str(retry.get("role") or "") != str(row.get("role") or "")
            or float(retry.get("started_at") or 0) < float(row.get("completed_at") or 0)
        ):
            raise AssertionError(f"failed attempt is not followed by a successful same-role retry: {ids[index]}")
        failed_retry_count += 1

    accepted_roles = [str(row.get("role") or "") for row in accepted]
    if accepted_roles != expected_accepted_roles:
        raise AssertionError(f"accepted lifecycle roles differ: {accepted_roles!r}")
    if str(rows[-1].get("attempt_id")) != str(accepted[-1].get("attempt_id")):
        raise AssertionError("the final ledger attempt is not the accepted terminal semantic result")
    if str(accepted[-1].get("role") or "") != "reviewer":
        raise AssertionError("the final accepted semantic operation is not REVIEW")
    if str(accepted[-1].get("accepted_candidate_sha") or "") != final_candidate_sha:
        raise AssertionError("the final reviewer is not bound to the final accepted candidate")

    for field in ("cost_known", "tokens_known"):
        if any(not int(row.get(field) or 0) for row in rows):
            raise AssertionError(f"attempt ledger contains UNKNOWN {field} evidence")
    if any(not int(row.get("cost_accounted") or 0) for row in rows):
        raise AssertionError("a semantic attempt was not accounted exactly once")

    total_cost = sum(float(row.get("cost_usd") or 0) for row in rows)
    if not math.isclose(total_cost, float(job_totals["total_cost_usd"]), rel_tol=0, abs_tol=1e-8):
        raise AssertionError("attempt cost sum does not match the supervisor job aggregate")
    token_fields = {
        "input_tokens": "total_input_tokens",
        "output_tokens": "total_output_tokens",
        "cache_read_tokens": "total_cache_read_tokens",
        "cache_creation_tokens": "total_cache_creation_tokens",
    }
    for attempt_field, job_field in token_fields.items():
        attempt_total = sum(int(row.get(attempt_field) or 0) for row in rows)
        if attempt_total != int(job_totals[job_field] or 0):
            raise AssertionError(f"attempt {attempt_field} sum does not match the supervisor aggregate")

    return {
        "attempt_count": len(rows),
        "accepted_attempt_count": len(accepted),
        "failed_retry_count": failed_retry_count,
    }
