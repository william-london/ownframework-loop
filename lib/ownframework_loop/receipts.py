"""Build receipt — create, validate, and inspect."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from . import git_checks, schema_validate, worktrees
from .util import (
    atomic_write_json, builder_worktree, run_dir, run_subprocess,
    short_sha, utc_now_iso,
)


SCHEMA_VERSION = "ownframework-loop-build-receipt/v2"


def receipt_path(canonical_repo: Path, run_id: str) -> Path:
    return run_dir(canonical_repo, run_id) / "BUILD_RECEIPT.json"


def new_receipt(
    *,
    run_id: str,
    packet_sha256: str,
    approval_sha256: str,
    work_unit_id: str,
    baseline_sha: str,
    candidate_sha: str,
    candidate_branch: str,
    builder_worktree: str,
    builder_pass_number: int,
    repair_round: int,
    files_changed: int,
    added_lines: int,
    removed_lines: int,
    changed_paths: list[str],
    validation: list[dict[str, Any]],
    protected_path_check: dict[str, Any],
    secret_scan_check: dict[str, Any],
    scope_check: dict[str, Any],
    sensitive_path_assessment: dict[str, Any],
    additional_review_required: bool,
    builder_agent: str,
    next_state: str,
    agent_summary: str | None = None,
    blocker_reason: str | None = None,
    escalation_recommended: bool = False,
    escalation_reason: str | None = None,
    review_pass_number_ref: int | None = None,
    notes: str | None = None,
) -> dict[str, Any]:
    """Build a build-receipt document. Does not write.

    All fields are required to validate against schemas/build-receipt.schema.json,
    which has additionalProperties: false. Pass-through fields are typed
    dicts so the caller is responsible for shape conformance to the schema.
    """
    out: dict[str, Any] = {
        "schema": SCHEMA_VERSION,
        "run_id": run_id,
        "packet_sha256": packet_sha256,
        "approval_sha256": approval_sha256,
        "work_unit_id": work_unit_id,
        "baseline_sha": baseline_sha,
        "candidate_sha": candidate_sha,
        "candidate_branch": candidate_branch,
        "builder_worktree": builder_worktree,
        "builder_pass_number": builder_pass_number,
        "repair_round": repair_round,
        "files_changed": files_changed,
        "added_lines": added_lines,
        "removed_lines": removed_lines,
        "changed_paths": changed_paths,
        "validation": validation,
        "protected_path_check": protected_path_check,
        "secret_scan_check": secret_scan_check,
        "scope_check": scope_check,
        "sensitive_path_assessment": sensitive_path_assessment,
        "additional_review_required": additional_review_required,
        "timestamp": utc_now_iso(),
        "builder_agent": builder_agent,
        "next_state": next_state,
        "escalation_recommended": escalation_recommended,
    }
    if review_pass_number_ref is not None:
        out["review_pass_number_ref"] = review_pass_number_ref
    if agent_summary is not None:
        out["agent_summary"] = agent_summary
    if blocker_reason is not None:
        out["blocker_reason"] = blocker_reason
    if escalation_reason is not None:
        out["escalation_reason"] = escalation_reason
    if notes is not None:
        out["notes"] = notes
    return out


def _assert_exact_clean_builder_candidate(
    canonical_repo: Path,
    run_id: str,
    receipt: dict[str, Any],
) -> None:
    """Fail closed unless the authoritative receipt describes the exact clean tree.

    The deterministic finalizer validates commands against the builder worktree.
    The receipt must therefore never be written while that worktree contains
    staged, tracked, or untracked changes outside the recorded candidate commit.
    Otherwise validation could observe bytes that are absent from candidate_sha.
    """
    wt = builder_worktree(canonical_repo, run_id)
    if not wt.exists():
        raise RuntimeError("refusing BUILD_RECEIPT: builder worktree missing")
    expected_sha = str(receipt.get("candidate_sha") or "")
    expected_branch = str(receipt.get("candidate_branch") or "")
    actual_sha = git_checks.current_head(wt)
    actual_branch = git_checks.current_branch(wt)
    if not expected_sha or actual_sha != expected_sha:
        raise RuntimeError(
            f"refusing BUILD_RECEIPT: builder HEAD {actual_sha!r} != candidate {expected_sha!r}"
        )
    if not expected_branch or actual_branch != expected_branch:
        raise RuntimeError(
            f"refusing BUILD_RECEIPT: builder branch {actual_branch!r} != candidate branch {expected_branch!r}"
        )
    if not worktrees.is_registered_worktree(canonical_repo, wt):
        raise RuntimeError(
            "refusing BUILD_RECEIPT: builder path is not a registered worktree of the canonical repository"
        )
    cleanliness = git_checks.dirty_status(wt)
    if cleanliness == "unknown":
        raise RuntimeError(
            "refusing BUILD_RECEIPT: builder worktree cleanliness is unknown; cannot prove candidate SHA describes validated filesystem"
        )
    if cleanliness == "dirty":
        raise RuntimeError(
            "refusing BUILD_RECEIPT: builder worktree is dirty; candidate SHA does not describe validated filesystem"
        )


def validate_receipt_contract(receipt: dict[str, Any]) -> None:
    errors = schema_validate.validate_receipt(receipt)
    if errors:
        raise RuntimeError(
            "refusing BUILD_RECEIPT: schema invalid: " + "; ".join(errors[:20])
        )


def write_receipt(canonical_repo: Path, run_id: str, receipt: dict[str, Any]) -> Path:
    _assert_exact_clean_builder_candidate(canonical_repo, run_id, receipt)
    p = receipt_path(canonical_repo, run_id)
    atomic_write_json(p, receipt, mode=0o600)
    return p


def load_receipt(canonical_repo: Path, run_id: str) -> dict[str, Any] | None:
    p = receipt_path(canonical_repo, run_id)
    if not p.exists():
        return None
    import json
    return json.loads(p.read_text(encoding="utf-8"))


def compute_diff_stats(worktree: Path, baseline_sha: str, candidate_sha: str) -> dict[str, int]:
    """Compute files_changed, added_lines, removed_lines for a candidate commit.

    FAIL-CLOSED: any git-diff failure raises RuntimeError. The historical
    behavior of returning {0,0,0} on diff failure was fail-open: a corrupt
    object store or hostile GIT_DIR override would produce zero diff, the
    budget/scope/protected checks would iterate over an empty change set,
    and a wildly out-of-scope candidate could pass review.
    """
    if not git_checks.commit_exists(worktree, candidate_sha):
        raise RuntimeError(
            f"candidate commit does not exist or is not a commit object: {candidate_sha}"
        )
    r = run_subprocess(
        ["git", "-C", str(worktree), "diff", "--numstat", baseline_sha, candidate_sha],
        timeout=30,
    )
    if r.returncode != 0:
        raise RuntimeError(
            f"git diff --numstat failed rc={r.returncode} for "
            f"{baseline_sha[:12]}..{candidate_sha[:12]}: {r.stderr.strip()}"
        )
    files = 0
    added = 0
    removed = 0
    for line in r.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 3:
            files += 1
            try:
                added += int(parts[0]) if parts[0] != "-" else 0
                removed += int(parts[1]) if parts[1] != "-" else 0
            except ValueError:
                pass
    return {"files_changed": files, "added_lines": added, "removed_lines": removed}


def list_changed_files(worktree: Path, baseline_sha: str, candidate_sha: str) -> list[str]:
    """Return the list of changed paths in a candidate commit.

    FAIL-CLOSED: any git-diff failure raises RuntimeError. Empty diff
    evidence on a diff failure is fail-open and is no longer permitted.
    """
    if not git_checks.commit_exists(worktree, candidate_sha):
        raise RuntimeError(
            f"candidate commit does not exist or is not a commit object: {candidate_sha}"
        )
    r = run_subprocess(
        ["git", "-C", str(worktree), "diff", "--name-only", baseline_sha, candidate_sha],
        timeout=30,
    )
    if r.returncode != 0:
        raise RuntimeError(
            f"git diff --name-only failed rc={r.returncode} for "
            f"{baseline_sha[:12]}..{candidate_sha[:12]}: {r.stderr.strip()}"
        )
    return [line.strip() for line in r.stdout.splitlines() if line.strip()]


def is_candidate_branch_contains_sha(worktree: Path, branch: str, sha: str) -> bool:
    """Return True iff `branch` contains `sha`."""
    r = run_subprocess(
        ["git", "-C", str(worktree), "merge-base", "--is-ancestor", sha, branch],
        timeout=10,
    )
    return r.returncode == 0
