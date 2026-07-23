"""Review verdict — write, validate, and stale-SHA detection."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .util import atomic_write_json, run_dir, utc_now_iso


SCHEMA_VERSION = "ownframework-loop-review-verdict/v1"


VERDICTS = {"APPROVED", "CHANGES_REQUESTED", "BLOCKED", "HUMAN_REVIEW_REQUIRED", "STALE_CANDIDATE"}


def verdict_path(canonical_repo: Path, run_id: str) -> Path:
    return run_dir(canonical_repo, run_id) / "REVIEW_VERDICT.json"


def new_verdict(
    *,
    run_id: str,
    packet_sha256: str,
    candidate_sha_reviewed: str,
    baseline_sha: str,
    review_pass_number: int,
    verdict: str,
    acceptance_results: list[dict[str, Any]],
    non_goal_results: list[dict[str, Any]],
    findings: list[dict[str, Any]],
    reviewer_identity: str,
    recommended_next_state: str,
    tracked_mutation_check: dict[str, Any] | None = None,
    stale_sha_check: dict[str, Any] | None = None,
    validation_results: list[dict[str, Any]] | None = None,
    commands_executed: list[str] | None = None,
    codex_escalation_recommended: bool = False,
    codex_reason: str | None = None,
) -> dict[str, Any]:
    """Build a review-verdict document. Does not write."""
    if verdict not in VERDICTS:
        raise ValueError(f"invalid verdict: {verdict}")
    return {
        "schema": SCHEMA_VERSION,
        "run_id": run_id,
        "packet_sha256": packet_sha256,
        "candidate_sha_reviewed": candidate_sha_reviewed,
        "baseline_sha": baseline_sha,
        "review_pass_number": review_pass_number,
        "verdict": verdict,
        "acceptance_results": acceptance_results,
        "non_goal_results": non_goal_results,
        "findings": findings,
        "commands_executed": commands_executed or [],
        "validation_results": validation_results or [],
        "tracked_mutation_check": tracked_mutation_check or {
            "detected": False, "before_sha": candidate_sha_reviewed,
            "after_sha": candidate_sha_reviewed, "changed_paths": []
        },
        "stale_sha_check": stale_sha_check or {
            "sha_match": True, "receipt_match": True, "packet_hash_match": True,
        },
        "reviewer_identity": reviewer_identity,
        "timestamp": utc_now_iso(),
        "recommended_next_state": recommended_next_state,
        "codex_escalation_recommended": codex_escalation_recommended,
        "codex_reason": codex_reason,
    }


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
