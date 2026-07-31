"""Review verdict — write, validate, and stale-SHA detection."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .util import atomic_write_json, run_dir, utc_now_iso


SCHEMA_VERSION = "ownframework-loop-review-verdict/v2"


VERDICTS = {"APPROVED", "CHANGES_REQUESTED", "BLOCKED", "HUMAN_REVIEW_REQUIRED", "STALE_CANDIDATE"}


def verdict_path(canonical_repo: Path, run_id: str) -> Path:
    return run_dir(canonical_repo, run_id) / "REVIEW_VERDICT.json"


def new_verdict(
    *,
    run_id: str,
    packet_sha256: str,
    approval_sha256: str,
    candidate_sha_reviewed: str,
    baseline_sha: str,
    review_pass_number: int,
    verdict: str,
    acceptance_results: list[dict[str, Any]],
    non_goal_results: list[dict[str, Any]],
    findings: list[dict[str, Any]],
    tracked_mutation_check: dict[str, Any],
    stale_sha_check: dict[str, Any],
    integrity_check: dict[str, Any],
    protected_path_check: dict[str, Any],
    secret_scan_check: dict[str, Any],
    scope_check: dict[str, Any],
    sensitive_path_assessment: dict[str, Any],
    reviewer_identity: str,
    recommended_next_state: str,
    failure_reason: str = "",
    escalation_recommended: bool = False,
    escalation_reason: str | None = None,
    validation_results: list[dict[str, Any]] | None = None,
    commands_executed: list[str] | None = None,
    builder_pass_number_ref: int | None = None,
) -> dict[str, Any]:
    """Build a review-verdict document. Does not write.

    All required fields are accepted as positional kwargs; the verdict
    is schema-valid by construction (additionalProperties: false).
    """
    if verdict not in VERDICTS:
        raise ValueError(f"invalid verdict: {verdict}")
    out: dict[str, Any] = {
        "schema": SCHEMA_VERSION,
        "run_id": run_id,
        "packet_sha256": packet_sha256,
        "approval_sha256": approval_sha256,
        "candidate_sha_reviewed": candidate_sha_reviewed,
        "baseline_sha": baseline_sha,
        "review_pass_number": review_pass_number,
        "verdict": verdict,
        "acceptance_results": acceptance_results,
        "non_goal_results": non_goal_results,
        "findings": findings,
        "commands_executed": list(commands_executed or []),
        "validation_results": list(validation_results or []),
        "tracked_mutation_check": tracked_mutation_check,
        "stale_sha_check": stale_sha_check,
        "integrity_check": integrity_check,
        "protected_path_check": protected_path_check,
        "secret_scan_check": secret_scan_check,
        "scope_check": scope_check,
        "sensitive_path_assessment": sensitive_path_assessment,
        "reviewer_identity": reviewer_identity,
        "timestamp": utc_now_iso(),
        "recommended_next_state": recommended_next_state,
        "failure_reason": failure_reason,
        "escalation_recommended": escalation_recommended,
    }
    if builder_pass_number_ref is not None:
        out["builder_pass_number_ref"] = builder_pass_number_ref
    if escalation_reason is not None:
        out["escalation_reason"] = escalation_reason
    return out


def write_verdict(canonical_repo: Path, run_id: str, verdict: dict[str, Any]) -> Path:
    p = verdict_path(canonical_repo, run_id)
    atomic_write_json(p, verdict, mode=0o600)
    return p


def load_verdict(canonical_repo: Path, run_id: str) -> dict[str, Any] | None:
    p = verdict_path(canonical_repo, run_id)
    if not p.exists():
        return None
    return json.loads(p.read_text(encoding="utf-8"))


def check_stale(
    *,
    candidate_sha_reviewed: str,
    receipt_candidate_sha: str,
    receipt_run_id: str,
    receipt_match_run_id: str,
    packet_hash_matches: bool,
    branch_contains_sha: bool,
) -> dict[str, Any]:
    """Return the stale_sha_check sub-record before writing the verdict."""
    return {
        "sha_match": candidate_sha_reviewed == receipt_candidate_sha and branch_contains_sha,
        "receipt_match": receipt_match_run_id and receipt_run_id == receipt_match_run_id,
        "packet_hash_match": packet_hash_matches,
    }


def finding_key(finding: dict[str, Any]) -> str:
    """Stable identity key for a finding — survives repair rounds."""
    return "|".join([
        finding.get("finding_id", ""),
        finding.get("file", ""),
        str(finding.get("line", "")),
        finding.get("title", ""),
    ])


def classify_mutation(
    mutation: dict[str, Any],
    *,
    expected_candidate_sha: str | None = None,
) -> dict[str, Any]:
    """Wrap a diff_tracked_mutation() result and translate it to a verdict
    action.

    Returns `{kind, action, ...}` where `action` is one of:
      - `approve_candidate`  — no drift.
      - `controlled_refresh` — head moved but it was the reviewer's own re-pin.
      - `external_drift_block` — external drift, must BLOCK.
      - `unexpected_initial_drift_block` — must BLOCK.

    The reviewer must call this before stamping the verdict and adapt the
    recommended_next_state per the action.
    """
    kind = mutation.get("kind", "no_change")
    if kind == "no_change":
        return {"kind": kind, "action": "approve_candidate"}
    if kind == "controlled_refresh":
        return {"kind": kind, "action": "controlled_refresh"}
    if kind == "unexpected_initial_drift":
        return {"kind": kind, "action": "unexpected_initial_drift_block"}
    return {"kind": kind, "action": "external_drift_block"}
