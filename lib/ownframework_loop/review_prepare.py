"""Deterministic reviewer preparation.

v0.4.5 mirrors build_prepare: the parent review skill does not choose a
candidate, branch, baseline, worktree path, or semantic scratch path. This
module validates the approved run + authoritative BUILD_RECEIPT, pins the exact
candidate SHA, creates/reuses the detached reviewer worktree, and returns one
machine-readable context for the fresh reviewer agent.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from . import (
    approval,
    assessment,
    git_checks,
    packet as packet_mod,
    receipts,
    state as state_mod,
    util,
    worktrees,
)


class ReviewPrepareRefused(RuntimeError):
    """Raised when deterministic reviewer preparation cannot prove identity."""


def _ancestor_of(repo: Path, candidate_sha: str, baseline_sha: str) -> bool:
    r = util.run_subprocess(
        ["git", "-C", str(repo), "merge-base", "--is-ancestor", baseline_sha, candidate_sha],
        timeout=10,
    )
    return r.returncode == 0


def _branch_contains(repo: Path, branch: str, candidate_sha: str) -> bool:
    r = util.run_subprocess(
        ["git", "-C", str(repo), "merge-base", "--is-ancestor", candidate_sha, branch],
        timeout=10,
    )
    return r.returncode == 0


def prepare(*, canonical_repo: Path, run_id: str) -> dict[str, Any]:
    canonical_repo = Path(canonical_repo).resolve(strict=False)
    if not git_checks.is_git_repo(canonical_repo):
        raise ReviewPrepareRefused(f"not a git repository: {canonical_repo}")

    packet_path = state_mod.run_dir(canonical_repo, run_id) / "WORK_PACKET.md"
    if not packet_path.exists():
        raise ReviewPrepareRefused("WORK_PACKET.md missing")
    meta, _ = packet_mod.parse_packet_file(packet_path)
    errors = packet_mod.validate_packet_for_approval(meta)
    if errors:
        raise ReviewPrepareRefused("packet invalid: " + "; ".join(errors))

    approval_doc = approval.load_approval(canonical_repo, run_id)
    ok, msg = approval.validate_approval_binding(
        canonical_repo=canonical_repo,
        run_id=run_id,
        approval=approval_doc,
        packet=meta,
        packet_path=packet_path,
    )
    if not ok:
        raise ReviewPrepareRefused(f"approval invalid: {msg}")

    state = state_mod.load(canonical_repo, run_id)
    if not state or state.get("state") != "REVIEWING":
        raise ReviewPrepareRefused(
            f"review preparation requires REVIEWING state, got {(state or {}).get('state')!r}"
        )

    receipt = receipts.load_receipt(canonical_repo, run_id)
    if not receipt:
        raise ReviewPrepareRefused("BUILD_RECEIPT.json missing")
    if receipt.get("run_id") != run_id:
        raise ReviewPrepareRefused("BUILD_RECEIPT run_id mismatch")

    candidate_sha = str(receipt.get("candidate_sha") or "")
    baseline_sha = str((approval_doc or {}).get("baseline_sha") or "")
    candidate_branch = str((approval_doc or {}).get("candidate_branch") or "")
    if not candidate_sha or not baseline_sha or not candidate_branch:
        raise ReviewPrepareRefused("missing frozen candidate/baseline/branch identity")

    if receipt.get("packet_sha256") != approval_doc.get("packet_sha256"):
        raise ReviewPrepareRefused("BUILD_RECEIPT packet SHA does not match approval")
    expected_approval_sha = approval.approval_artifact_sha256(approval_doc)
    if receipt.get("approval_sha256") != expected_approval_sha:
        raise ReviewPrepareRefused("BUILD_RECEIPT approval SHA does not match current approval")
    if receipt.get("baseline_sha") != baseline_sha:
        raise ReviewPrepareRefused("BUILD_RECEIPT baseline SHA mismatch")
    if receipt.get("candidate_branch") != candidate_branch:
        raise ReviewPrepareRefused("BUILD_RECEIPT candidate branch mismatch")
    if state.get("last_candidate_sha") != candidate_sha:
        raise ReviewPrepareRefused("STATE last_candidate_sha does not match BUILD_RECEIPT candidate")
    if not git_checks.commit_exists(canonical_repo, candidate_sha):
        raise ReviewPrepareRefused("candidate SHA missing from repository")
    if not _ancestor_of(canonical_repo, candidate_sha, baseline_sha):
        raise ReviewPrepareRefused("candidate does not descend from approved baseline")
    if not _branch_contains(canonical_repo, candidate_branch, candidate_sha):
        raise ReviewPrepareRefused("approved candidate branch does not contain candidate SHA")

    wt_info = worktrees.add_reviewer_worktree(
        canonical_repo,
        run_id,
        candidate_sha=candidate_sha,
        expected_setup_sha=candidate_sha,
    )
    reviewer_wt = Path(wt_info["path"]).resolve(strict=False)
    actual_head = git_checks.current_head(reviewer_wt)
    if actual_head != candidate_sha:
        raise ReviewPrepareRefused(
            f"reviewer worktree HEAD {actual_head!r} != candidate {candidate_sha}"
        )

    assessment_path = assessment.assessment_path(canonical_repo, run_id)
    return {
        "schema": "ownframework-loop-review-prepare/v1",
        "canonical_repo": str(canonical_repo),
        "run_id": run_id,
        "execution_mode": "program" if state_mod.is_program_state(state) else "single",
        "candidate_sha": candidate_sha,
        "baseline_sha": baseline_sha,
        "candidate_branch": candidate_branch,
        "packet_sha256": approval_doc["packet_sha256"],
        "approval_sha256": expected_approval_sha,
        "build_receipt_sha256": util.sha256_file(receipts.receipt_path(canonical_repo, run_id)),
        "review_pass_number": int(state.get("review_pass_count") or 0),
        "reviewer_worktree": str(reviewer_wt),
        "reviewer_head": actual_head,
        "reviewer_worktree_existed": bool(wt_info.get("existed")),
        "assessment_path": str(assessment_path),
        "assessment_exists": assessment_path.exists(),
        "preparation_owner": "ofloop review prepare",
        "prepared_at": util.utc_now_iso(),
    }
