"""Atomic dispatch boundary for unattended OwnFramework Loop execution.

The supervisor never interprets the engineering state machine itself. It asks
this module for the next typed action. Dispatch serializes reconciliation +
claim + deterministic preparation + semantic skeleton materialization and
returns one immutable work order.

The work order is non-authoritative transport. Core artifacts remain the source
of truth.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path
from typing import Any

from . import (
    approval as approval_mod,
    assessment as assessment_mod,
    build_agent as build_agent_mod,
    continuation_authority as continuation_authority_mod,
    git_checks as git_checks_mod,
    packet as packet_mod,
    program as program_mod,
    reconcile as reconcile_mod,
    state as state_mod,
    util,
    worktrees as worktrees_mod,
)
from .locking import LockBusyError, flock_exclusive

SCHEMA = "ownframework-loop-dispatch/v1"
TERMINAL_STATES = {"APPROVED", "BLOCKED", "STOPPED"}
BUILD_STATES = {
    "AWAITING_APPROVAL",
    "READY_TO_BUILD",
    "CHANGES_REQUESTED",
    "BUILDING",
}
REVIEW_STATES = {"READY_FOR_REVIEW", "REVIEWING"}


class DispatchError(RuntimeError):
    """Deterministic dispatch refusal."""


_RETRYABLE_SEMANTIC_RESULT_REASONS = frozenset({
    "semantic_artifact_missing_or_invalid",
    "semantic_run_id_mismatch",
    "builder_schema_mismatch",
    "builder_outcome_invalid",
    "builder_summary_empty",
    "builder_completion_evidence_empty",
    "builder_semantic_shape_invalid",
    "builder_work_unit_mismatch",
    "builder_fixed_identity_mismatch",
    # A completed BUILD whose builder author left useful work in the worktree
    # but failed to commit a candidate is NOT an invariant failure: the
    # artifact path is irreparably unfit for deterministic finalization, but
    # the worktree still carries the author's staged bytes and a fresh
    # provider process on the same claimed pass can finish the work. Treat
    # the same way as the other retryable shape failures: archive the
    # poisoned envelope privately, reseed the canonical artifact path, and
    # requeue a fresh builder on the same claimed pass without consuming the
    # engineering repair budget.
    "builder_worktree_dirty",
    "review_schema_mismatch",
    "review_candidate_mismatch",
    "review_fixed_identity_mismatch",
    "review_recommendation_invalid",
    "review_findings_invalid",
    "review_coverage_not_lists",
    "review_acceptance_coverage_incomplete",
    "review_non_goal_coverage_incomplete",
    "review_acceptance_result_incomplete",
    "review_non_goal_result_incomplete",
    "review_acceptance_result_invalid",
    "review_non_goal_result_invalid",
    "review_escalation_invalid",
    "review_semantic_shape_invalid",
})

_RESEED_RECEIPT_SCHEMA = "ownframework-loop-semantic-reseed/v1"


class SemanticResultIncomplete(DispatchError):
    """Semantic output exists but cannot safely enter deterministic finalization."""

    def __init__(self, reason: str):
        self.reason = str(reason)
        self.retryable = self.reason in _RETRYABLE_SEMANTIC_RESULT_REASONS
        super().__init__(
            f"semantic result is incomplete ({self.reason}); refusing finalization"
        )


BUILD_AGENT_SCHEMA = build_agent_mod.SCHEMA_AGENT_RESULT
REVIEW_AGENT_SCHEMA = "ownframework-loop-review-agent-assessment/v1"
BUILD_OUTCOMES = set(build_agent_mod.ALLOWED_OUTCOMES)
REVIEW_VERDICTS = {
    "APPROVED",
    "CHANGES_REQUESTED",
    "BLOCKED",
    "HUMAN_REVIEW_REQUIRED",
    "STALE_CANDIDATE",
}


def _load_json_file(path: Path) -> dict[str, Any] | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def _canonical_json_bytes(payload: dict[str, Any]) -> bytes:
    return json.dumps(payload, indent=2, sort_keys=True).encode("utf-8")


def _skeletons_equivalent(left: bytes, right: bytes) -> bool:
    """Compare fresh semantic skeletons while ignoring their timestamp field."""
    try:
        left_doc = json.loads(left)
        right_doc = json.loads(right)
    except (TypeError, json.JSONDecodeError):
        return False
    if not isinstance(left_doc, dict) or not isinstance(right_doc, dict):
        return False
    left_doc.pop("timestamp", None)
    right_doc.pop("timestamp", None)
    return left_doc == right_doc


def _fresh_semantic_skeleton(
    decision: str,
    repo: Path,
    run_id: str,
) -> tuple[Path, dict[str, Any], bytes, str]:
    if decision == "BUILD":
        target = build_agent_mod.agent_result_path(repo, run_id)
        skeleton = build_agent_mod.build_skeleton(repo, run_id)
    else:
        target = assessment_mod.assessment_path(repo, run_id)
        skeleton = assessment_mod.build_skeleton(repo, run_id)
    encoded = _canonical_json_bytes(skeleton)
    return target.resolve(strict=False), skeleton, encoded, util.sha256_bytes(encoded)


def _reseed_receipt_path(semantic: Path, attempt_id: str) -> Path:
    return semantic.parent / "reseed-receipts" / f"{attempt_id}.json"


def _load_reseed_receipt(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    receipt = util.read_private_json(path)
    if not isinstance(receipt, dict):
        raise DispatchError("semantic retry reseed receipt is invalid")
    return receipt


def _validate_reseed_receipt(
    receipt: dict[str, Any],
    *,
    decision: str,
    attempt_id: str,
    semantic: Path,
    archive_path: Path | None,
    archive_sha256: str,
    fresh_skeleton_sha256: str,
) -> None:
    expected = {
        "schema": _RESEED_RECEIPT_SCHEMA,
        "decision": decision,
        "previous_attempt_id": attempt_id,
        "semantic_path": str(semantic),
        "archive_path": str(archive_path) if archive_path else None,
        "archived_artifact_sha256": archive_sha256,
        "fresh_skeleton_sha256": fresh_skeleton_sha256,
    }
    for key, value in expected.items():
        if receipt.get(key) != value:
            raise DispatchError(f"semantic retry reseed receipt mismatch: {key}")


def _write_reseed_receipt(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    if path.exists():
        existing = util.read_private_json(path)
        if existing != payload:
            raise DispatchError("semantic retry reseed receipt collision")
        return
    util.atomic_write_json(path, payload, mode=0o600)
    written = util.read_private_json(path)
    if written != payload:
        raise DispatchError("semantic retry reseed receipt verification failed")


def reseed_semantic_artifact_for_retry(
    work_order: dict[str, Any],
    *,
    previous_attempt_id: str,
) -> dict[str, Any]:
    """Archive a failed semantic envelope and reseed the same pass path.

    A retryable semantic-shape failure is transport failure, not engineering
    progress. The claimed pass, worktree, and canonical path remain fixed, but
    the next provider must start from fresh core-owned bytes. The archive is
    private forensic evidence and is never read by a finalizer.
    """
    decision = str(work_order.get("decision") or "")
    if decision not in {"BUILD", "REVIEW"}:
        raise DispatchError("semantic retry reseed requires BUILD or REVIEW")
    attempt_id = str(previous_attempt_id or "")
    if not attempt_id:
        raise DispatchError("semantic retry reseed requires prior attempt identity")
    if not re.fullmatch(r"[A-Za-z0-9._-]+", attempt_id):
        raise DispatchError("semantic retry attempt identity is unsafe")

    semantic = Path(str(work_order.get("semantic_path") or "")).resolve(strict=False)
    if not semantic.is_absolute():
        raise DispatchError("semantic retry path must be absolute")
    repo = Path(str(work_order.get("canonical_repo") or "")).resolve(strict=False)
    run_id = str(work_order.get("run_id") or "")
    target, _skeleton, fresh_bytes, fresh_skeleton_sha256 = _fresh_semantic_skeleton(
        decision, repo, run_id
    )
    if target != semantic:
        raise DispatchError("semantic retry reseed changed canonical artifact path")

    receipt_path = _reseed_receipt_path(semantic, attempt_id)
    existing_receipt = _load_reseed_receipt(receipt_path)
    raw = semantic.read_bytes() if semantic.exists() else b""
    archive_path: Path | None = (
        semantic.parent / "rejected-attempts" / f"{attempt_id}.json"
        if semantic.exists() or existing_receipt is not None
        else None
    )

    if existing_receipt is not None:
        receipt_archive = existing_receipt.get("archive_path")
        expected_archive_path = semantic.parent / "rejected-attempts" / f"{attempt_id}.json"
        if receipt_archive is not None and Path(str(receipt_archive)).resolve(strict=False) != expected_archive_path.resolve(strict=False):
            raise DispatchError("semantic retry reseed receipt archive path mismatch")
        archive_path = expected_archive_path if receipt_archive else None
        archive_bytes = archive_path.read_bytes() if archive_path else b""
        archive_sha256 = util.sha256_bytes(archive_bytes)
        recorded_fresh_skeleton_sha256 = str(
            existing_receipt.get("fresh_skeleton_sha256") or ""
        )
        if not re.fullmatch(r"[0-9a-f]{64}", recorded_fresh_skeleton_sha256):
            raise DispatchError("semantic retry reseed receipt fresh skeleton digest invalid")
        _validate_reseed_receipt(
            existing_receipt,
            decision=decision,
            attempt_id=attempt_id,
            semantic=semantic,
            archive_path=archive_path,
            archive_sha256=archive_sha256,
            fresh_skeleton_sha256=recorded_fresh_skeleton_sha256,
        )
        if util.sha256_bytes(raw) != recorded_fresh_skeleton_sha256:
            raise DispatchError("semantic retry reseed receipt exists but artifact drifted")
        return {
            "decision": decision,
            "attempt_id": attempt_id,
            "semantic_path": str(semantic),
            "archive_path": str(archive_path) if archive_path else None,
            "archive_sha256": archive_sha256,
            "fresh_skeleton_sha256": recorded_fresh_skeleton_sha256,
            "reseeded": False,
            "already_reseeded": True,
        }

    archive_sha256 = util.sha256_bytes(raw)
    already_reseeded = False
    if archive_path is not None:
        archive_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(archive_path.parent, 0o700)
        if archive_path.exists():
            prior = archive_path.read_bytes()
            if (
                raw != fresh_bytes
                and not _skeletons_equivalent(raw, fresh_bytes)
                and prior != raw
            ):
                raise DispatchError(
                    f"semantic retry archive collision for attempt {attempt_id}"
                )
            if prior != raw:
                # The process may have crashed after installing the fresh
                # skeleton but before writing the reseed receipt.  The
                # archived bytes and the canonical fresh bytes prove that the
                # operation completed; do not treat this as a collision.
                already_reseeded = True
                fresh_bytes = raw
                fresh_skeleton_sha256 = util.sha256_bytes(fresh_bytes)
                archive_sha256 = util.sha256_bytes(prior)
            else:
                archive_sha256 = util.sha256_bytes(prior)
        else:
            fd = os.open(
                str(archive_path),
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
            )
            try:
                with os.fdopen(fd, "wb") as handle:
                    handle.write(raw)
                    handle.flush()
                    os.fsync(handle.fileno())
            except Exception:
                try:
                    archive_path.unlink()
                except FileNotFoundError:
                    pass
                raise
            os.chmod(archive_path, 0o600)
            util.fsync_dir(archive_path.parent)
            archive_sha256 = util.sha256_bytes(archive_path.read_bytes())
        if not archive_path.is_file():
            raise DispatchError("semantic retry archive verification failed")

    if raw != fresh_bytes:
        if decision == "BUILD":
            target = build_agent_mod.write_skeleton(repo, run_id, overwrite=True)
        else:
            target = assessment_mod.write_skeleton(repo, run_id, overwrite=True)
        if target.resolve(strict=False) != semantic:
            raise DispatchError("semantic retry reseed changed canonical artifact path")
        # build_skeleton()/assessment.build_skeleton() include a current UTC
        # timestamp, so the bytes materialized by write_skeleton() are the
        # authoritative fresh skeleton for this reseed operation.
        fresh_bytes = semantic.read_bytes()
        fresh_skeleton_sha256 = util.sha256_bytes(fresh_bytes)
    if not semantic.is_file() or semantic.read_bytes() != fresh_bytes:
        raise DispatchError("fresh semantic skeleton verification failed")

    receipt_payload = {
        "schema": _RESEED_RECEIPT_SCHEMA,
        "decision": decision,
        "previous_attempt_id": attempt_id,
        "semantic_path": str(semantic),
        "archive_path": str(archive_path) if archive_path else None,
        "archived_artifact_sha256": archive_sha256,
        "fresh_skeleton_sha256": fresh_skeleton_sha256,
        "recorded_at": util.utc_now_iso(),
    }
    _write_reseed_receipt(receipt_path, receipt_payload)
    if semantic.read_bytes() != fresh_bytes:
        raise DispatchError("semantic retry artifact changed after reseed receipt")
    return {
        "decision": decision,
        "attempt_id": attempt_id,
        "semantic_path": str(semantic),
        "archive_path": str(archive_path) if archive_path else None,
        "archive_sha256": archive_sha256,
        "fresh_skeleton_sha256": fresh_skeleton_sha256,
        "reseeded": not already_reseeded,
        "already_reseeded": already_reseeded,
    }


def _fixed_identity_mismatch(
    work_order: dict[str, Any],
    data: dict[str, Any],
    *,
    decision: str,
) -> str | None:
    """Compare supplied core-owned envelope values to a fresh authority skeleton."""
    repo = Path(str(work_order.get("canonical_repo") or "")).resolve(strict=False)
    run_id = str(work_order.get("run_id") or "")
    # Preserve compatibility with tiny synthetic contract fixtures that do
    # not represent a real sealed repository. Real dispatched work always has
    # a valid repository and therefore receives the exact comparison.
    if not git_checks_mod.is_git_repo(repo):
        return None
    try:
        _target, expected, _bytes, _sha = _fresh_semantic_skeleton(
            decision, repo, run_id
        )
    except Exception:
        prefix = "builder" if decision == "BUILD" else "review"
        return f"{prefix}_fixed_identity_authority_unavailable"
    fixed_keys = (
        build_agent_mod.FIXED_KEYS
        if decision == "BUILD"
        else assessment_mod.FIXED_KEYS
    )
    for field in sorted(fixed_keys):
        # A real dispatched artifact is always scaffolded by the core.  The
        # complete fixed envelope is therefore required, not merely
        # type-checked when the model happens to echo a field.  Tiny
        # non-repository contract fixtures retain their historical shape-only
        # compatibility through the early return above.
        if field not in data or data.get(field) != expected.get(field):
            prefix = "builder" if decision == "BUILD" else "review"
            return f"{prefix}_fixed_identity_mismatch"
    return None


def semantic_result_ready(work_order: dict[str, Any]) -> tuple[bool, str]:
    """Prove that a semantic worker actually completed the claimed pass.

    Skeleton existence is never completion: skeletons intentionally contain
    placeholder defaults. This check is used both before deterministic
    finalization and after supervisor restart so a completed semantic artifact
    can be finalized without paying for a duplicate model call.

    v0.6.1 hardening: a BUILD semantic artifact is NOT sufficient to claim
    readiness. The exact prepared builder worktree must already be structurally
    finalizable — i.e. clean at `git status --porcelain`. If the worktree is
    dirty, replay-finalizing the same semantic artifact cannot repair the
    filesystem, and we must report not-ready so the supervisor dispatches a
    fresh semantic builder for the SAME claimed pass (same run_id, same pass
    number, same checkpoint, same candidate branch, same worktree, same
    semantic artifact path) instead of incurring another dispatch-only
    retry that would only re-trigger the deterministic dirty-worktree refusal.
    """
    if work_order.get("schema") != SCHEMA:
        return False, "invalid_work_order_schema"
    decision = str(work_order.get("decision") or "")
    if decision not in {"BUILD", "REVIEW"}:
        return False, "not_semantic_work"

    semantic = Path(str(work_order.get("semantic_path") or "")).resolve(strict=False)
    data = _load_json_file(semantic)
    if data is None:
        return False, "semantic_artifact_missing_or_invalid"

    run_id = str(work_order.get("run_id") or "")
    if data.get("run_id") != run_id:
        return False, "semantic_run_id_mismatch"

    if decision == "BUILD":
        if data.get("schema") != BUILD_AGENT_SCHEMA:
            return False, "builder_schema_mismatch"
        outcome = data.get("outcome_requested")
        if outcome not in BUILD_OUTCOMES:
            return False, "builder_outcome_invalid"
        if build_agent_mod.validate_agent_result_contract(data):
            return False, "builder_semantic_shape_invalid"
        fixed_reason = _fixed_identity_mismatch(
            work_order, data, decision="BUILD"
        )
        if fixed_reason:
            return False, fixed_reason
        expected_work_unit = str(work_order.get("work_unit_id") or "")
        if expected_work_unit and data.get("work_unit_id") != expected_work_unit:
            return False, "builder_work_unit_mismatch"
        summary = str(data.get("summary") or "").strip()
        if outcome == "candidate_ready":
            addressed = data.get("acceptance_addressed") or []
            completed = data.get("unit_ids_completed") or []
            if not summary:
                return False, "builder_summary_empty"
            if not addressed and not completed:
                return False, "builder_completion_evidence_empty"
            repo = Path(str(work_order.get("canonical_repo") or "")).resolve(strict=False)
            if not repo.is_dir():
                return False, "canonical_repo_missing"
            expected_wt = util.builder_worktree(repo, run_id).resolve(strict=False)
            supplied_wt = str(work_order.get("worktree") or "")
            if not supplied_wt:
                return False, "builder_worktree_missing"
            wt_path = Path(supplied_wt).resolve(strict=False)
            if wt_path != expected_wt:
                return False, "builder_worktree_path_mismatch"
            if not wt_path.is_dir():
                return False, "builder_worktree_missing"
            if not worktrees_mod.is_registered_worktree(repo, wt_path):
                return False, "builder_worktree_not_registered"
            approval_doc = approval_mod.load_approval(repo, run_id)
            if not isinstance(approval_doc, dict):
                return False, "approval_missing"
            expected_branch = str(approval_doc.get("candidate_branch") or "")
            actual_branch = git_checks_mod.current_branch(wt_path)
            if not actual_branch:
                return False, "builder_branch_unresolved"
            if actual_branch != expected_branch:
                return False, "builder_branch_mismatch"
            head = git_checks_mod.current_head(wt_path)
            if not head or not git_checks_mod.commit_exists(repo, head):
                return False, "builder_head_unresolved"
            cleanliness = git_checks_mod.dirty_status(wt_path)
            if cleanliness == "unknown":
                return False, "builder_worktree_cleanliness_unknown"
            if cleanliness == "dirty":
                return False, "builder_worktree_dirty"
        elif not summary and not str(data.get("blocker_reason") or "").strip():
            return False, "builder_terminal_reason_empty"
        return True, "ready"

    if data.get("schema") != REVIEW_AGENT_SCHEMA:
        return False, "review_schema_mismatch"
    fixed_reason = _fixed_identity_mismatch(
        work_order, data, decision="REVIEW"
    )
    if fixed_reason:
        return False, fixed_reason
    candidate = str(work_order.get("candidate_sha") or "")
    if candidate and data.get("candidate_sha_claimed") != candidate:
        return False, "review_candidate_mismatch"
    if data.get("recommended_verdict") not in REVIEW_VERDICTS:
        return False, "review_recommendation_invalid"
    if assessment_mod.validate_findings(data.get("findings")):
        return False, "review_findings_invalid"
    if (
        "escalation_recommended" in data
        and not isinstance(data.get("escalation_recommended"), bool)
    ):
        return False, "review_escalation_invalid"
    escalation_reason = data.get("escalation_reason")
    if escalation_reason is not None and not isinstance(escalation_reason, str):
        return False, "review_escalation_invalid"

    repo = Path(str(work_order.get("canonical_repo") or "")).resolve(strict=False)
    if not repo.is_dir():
        return False, "canonical_repo_missing"
    expected_wt = util.reviewer_worktree(repo, run_id).resolve(strict=False)
    supplied_wt = str(work_order.get("worktree") or "")
    if not supplied_wt:
        return False, "reviewer_worktree_missing"
    reviewer_wt = Path(supplied_wt).resolve(strict=False)
    if reviewer_wt != expected_wt:
        return False, "reviewer_worktree_path_mismatch"
    if not reviewer_wt.is_dir():
        return False, "reviewer_worktree_missing"
    if not worktrees_mod.is_registered_worktree(repo, reviewer_wt):
        return False, "reviewer_worktree_not_registered"
    if not candidate:
        return False, "review_candidate_missing"
    reviewer_head = git_checks_mod.current_head(reviewer_wt)
    if reviewer_head != candidate:
        return False, "reviewer_head_mismatch"
    reviewer_cleanliness = git_checks_mod.dirty_status(reviewer_wt)
    if reviewer_cleanliness == "unknown":
        return False, "reviewer_worktree_cleanliness_unknown"
    if reviewer_cleanliness == "dirty":
        return False, "reviewer_worktree_dirty"

    packet_path = state_mod.run_dir(repo, run_id) / "WORK_PACKET.md"
    try:
        meta, _ = packet_mod.parse_packet_file(packet_path)
    except (OSError, ValueError):
        return False, "packet_unreadable"

    def expected_ids(items: list[Any], prefix: str) -> set[str]:
        out: set[str] = set()
        for idx, item in enumerate(items, start=1):
            if isinstance(item, dict) and isinstance(item.get("id"), str):
                out.add(item["id"])
            else:
                out.add(f"{prefix}-{idx}")
        return out

    state_doc = state_mod.load_verified(repo, run_id)
    if state_mod.is_program_state(state_doc):
        expected_ac = set(
            program_mod.current_checkpoint_acceptance_criterion_ids(
                meta, (state_doc or {}).get("program") or {}
            )
        )
    else:
        expected_ac = expected_ids(meta.get("acceptance_criteria") or [], "AC")
    expected_ng = expected_ids(meta.get("non_goals") or [], "NG")
    ac = data.get("acceptance_results")
    ng = data.get("non_goal_results")
    if not isinstance(ac, list) or not isinstance(ng, list):
        return False, "review_coverage_not_lists"
    ac_ids = [str(x.get("id") or "") for x in ac if isinstance(x, dict)]
    ng_ids = [str(x.get("id") or "") for x in ng if isinstance(x, dict)]
    if (
        len(ac_ids) != len(ac)
        or len(set(ac_ids)) != len(ac_ids)
        or set(ac_ids) != expected_ac
    ):
        return False, "review_acceptance_coverage_incomplete"
    if (
        len(ng_ids) != len(ng)
        or len(set(ng_ids)) != len(ng_ids)
        or set(ng_ids) != expected_ng
    ):
        return False, "review_non_goal_coverage_incomplete"
    if any(
        not str(item.get("result") or "").strip()
        or not str(item.get("evidence") or "").strip()
        for item in ac
        if isinstance(item, dict)
    ):
        return False, "review_acceptance_result_incomplete"
    if any(
        not str(item.get("result") or "").strip()
        or not str(item.get("evidence") or "").strip()
        for item in ng
        if isinstance(item, dict)
    ):
        return False, "review_non_goal_result_incomplete"
    _, ac_result_errors = assessment_mod.canonicalize_result_rows(
        ac, kind="acceptance"
    )
    if ac_result_errors:
        return False, "review_acceptance_result_invalid"
    _, ng_result_errors = assessment_mod.canonicalize_result_rows(
        ng, kind="non_goal"
    )
    if ng_result_errors:
        return False, "review_non_goal_result_invalid"

    # The detailed checks above retain stable refusal classifications. This
    # shared residual gate catches any remaining shape/type drift (for example
    # validation_results as an object) before a paid pass reaches a finalizer
    # that would reject the same semantic artifact.
    if assessment_mod.validate_assessment_contract(data):
        return False, "review_semantic_shape_invalid"
    return True, "ready"


def _ofloop_bin() -> str:
    explicit = os.environ.get("OFLOOP_BIN", "").strip()
    if explicit:
        return explicit
    sibling = Path(__file__).resolve().parent.parent.parent / "bin" / "ofloop"
    return str(sibling) if sibling.exists() else "ofloop"


def _run_cli(
    args: list[str],
    *,
    timeout_seconds: int | None = None,
) -> dict[str, Any]:
    try:
        proc = subprocess.run(
            [_ofloop_bin(), *args],
            capture_output=True,
            text=True,
            check=False,
            timeout=(int(timeout_seconds) if timeout_seconds and timeout_seconds > 0 else None),
        )
    except subprocess.TimeoutExpired as exc:
        raise DispatchError(
            f"ofloop {' '.join(args)} exceeded finalization wall budget "
            f"({int(timeout_seconds or 0)}s)"
        ) from exc
    if proc.returncode != 0:
        raise DispatchError(
            f"ofloop {' '.join(args)} failed rc={proc.returncode}: "
            f"{proc.stderr.strip() or proc.stdout.strip()}"
        )
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise DispatchError(
            f"ofloop {' '.join(args)} returned non-JSON output"
        ) from exc
    if not isinstance(payload, dict):
        raise DispatchError("ofloop command returned non-object JSON")
    return payload


def _terminal(run_id: str, state: str) -> dict[str, Any]:
    return {
        "schema": SCHEMA,
        "decision": "TERMINAL",
        "run_id": run_id,
        "state": state,
    }


def _truncate_evidence_text(value: Any, limit: int = 4000) -> str:
    text = str(value or "")
    return text if len(text) <= limit else text[:limit] + "...[truncated]"


def _repair_context_from_receipt(
    *,
    canonical_repo: Path,
    run_id: str,
    state_doc: dict[str, Any],
) -> dict[str, Any] | None:
    """Return deterministic build-validation feedback for a repair builder.

    A CHANGES_REQUESTED state can originate from the deterministic build
    finalizer (required validation failed / scope / protected / secret
    findings) without any fresh review verdict. The authoritative
    BUILD_RECEIPT.json then carries the exact failed evidence; transport it
    so the fresh builder does not have to rediscover the failure blindly.

    A BLOCKED state can originate from a deterministic source-budget breach
    (or other bounded structural stop) — but a BLOCKED receipt by itself is
    NOT authority to run another build. The repair context is produced only
    when a matching supported continuation receipt at the same checkpoint,
    candidate, and funded repair round exists. Fail closed otherwise.
    """
    path = state_mod.run_dir(canonical_repo, run_id) / "BUILD_RECEIPT.json"
    receipt = _load_json_file(path)
    if receipt is None:
        return None
    receipt_next = str(receipt.get("next_state") or "")

    if receipt_next == "BLOCKED":
        return _repair_context_from_blocked_receipt(
            canonical_repo=canonical_repo,
            run_id=run_id,
            state_doc=state_doc,
            receipt=receipt,
        )

    if receipt_next != "CHANGES_REQUESTED":
        return None
    receipt_candidate = str(receipt.get("candidate_sha") or "")
    state_candidate = str(state_doc.get("last_candidate_sha") or "")
    if not receipt_candidate or (state_candidate and receipt_candidate != state_candidate):
        return None

    validations = receipt.get("validation") or []
    failed_validations: list[dict[str, Any]] = []
    for item in validations if isinstance(validations, list) else []:
        if not isinstance(item, dict) or bool(item.get("passed")):
            continue
        failed_validations.append({
            "name": item.get("name"),
            "command": item.get("command"),
            "exit_code": item.get("exit_code"),
            "expected_exit_code": item.get("expected_exit_code"),
            "timed_out": bool(item.get("timed_out")),
            "duration_seconds": item.get("duration_seconds"),
            "stdout": _truncate_evidence_text(item.get("stdout")),
            "stderr": _truncate_evidence_text(item.get("stderr")),
        })
        if len(failed_validations) >= 10:
            break

    scope_check = receipt.get("scope_check") or {}
    protected_check = receipt.get("protected_path_check") or {}
    secret_check = receipt.get("secret_scan_check") or {}
    recovery = receipt.get("protected_drift_recovery") or {}
    # v0.9.9-i: source-budget breach evidence (program_source_ceiling_check).
    # When this receipt carries a clean source-budget breach, surface it so
    # the next builder pass can read the recorded breach and shrink to the
    # sealed envelope rather than rediscover it.
    source_ceiling_check = receipt.get("program_source_ceiling_check") or {}
    source_ceiling_breach = (
        isinstance(source_ceiling_check, dict)
        and str(source_ceiling_check.get("result") or "") == "fail"
        and str(source_ceiling_check.get("accounting") or "")
        == "absolute_baseline_to_candidate"
    )
    measured_diff_lines = (
        int(source_ceiling_check.get("diff_lines_total") or 0)
        if source_ceiling_breach
        else 0
    )
    effective_max_diff_lines = (
        int(source_ceiling_check.get("effective_max_diff_lines") or 0)
        if source_ceiling_breach
        else 0
    )
    measured_files = (
        int(source_ceiling_check.get("files_changed_unique") or 0)
        if source_ceiling_breach
        else 0
    )
    effective_max_files = (
        int(source_ceiling_check.get("effective_max_files_changed") or 0)
        if source_ceiling_breach
        else 0
    )
    breach_text = (
        str(source_ceiling_check.get("breach") or "") if source_ceiling_breach else ""
    )
    current_checkpoints = (state_doc.get("program") or {}).get(
        "current_checkpoints"
    ) or []
    checkpoint_id = str(current_checkpoints[0]) if current_checkpoints else ""

    # v0.9.9-i: pick the most authoritative failure_reason so the builder
    # knows which deterministic finalizer gate failed (source-budget is
    # checked first because it is the only check that blocks via envelope,
    # not via scope/protected/secret/identity).
    failure_reason = "build_finalizer_validation_failed"
    if source_ceiling_breach:
        failure_reason = "build_finalizer_source_budget_breach"
    elif scope_check and str(scope_check.get("result") or "") == "fail":
        failure_reason = "build_finalizer_scope_drift"
    elif protected_check and str(protected_check.get("result") or "") == "fail":
        failure_reason = "build_finalizer_protected_path_violation"
    elif failed_validations:
        failure_reason = "build_finalizer_validation_failed"
    elif secret_check and str(secret_check.get("result") or "") == "fail":
        failure_reason = "build_finalizer_secret_scan"

    out: dict[str, Any] = {
        "schema": "ownframework-loop-repair-context/v1",
        "source": str(path.resolve(strict=False)),
        "source_kind": "build_receipt",
        "repair_round": int(state_doc.get("repair_round") or 0),
        "candidate_sha_reviewed": receipt_candidate,
        "verdict": "CHANGES_REQUESTED",
        "failure_reason": failure_reason,
        "failed_validation_results": failed_validations,
        "scope_findings": scope_check.get("findings") or [],
        "protected_path_findings": protected_check.get("offending_paths") or [],
        "prior_candidate_rejected_whole": bool(
            recovery.get("prior_attempt_rejected_whole")
        ),
        "discarded_candidate_sha": recovery.get("previous_candidate_sha"),
        "checkpoint_entry_candidate_sha": recovery.get("checkpoint_entry_candidate_sha"),
        "checkpoint_entry_tree_sha": recovery.get("checkpoint_entry_tree_sha"),
        "recovery_offending_paths": recovery.get("offending_paths") or [],
        "repair_instruction": (
            "The prior entire candidate attempt was rejected because it changed "
            "protected authority. Reimplement this checkpoint from the safe "
            "checkpoint-entry source; no source from that attempt was preserved."
            if recovery.get("prior_attempt_rejected_whole") else None
        ),
        "secret_findings": (secret_check.get("findings") or [])[:10],
        "blocker_reason": receipt.get("blocker_reason"),
        "escalation_recommended": bool(receipt.get("escalation_recommended")),
        "escalation_reason": receipt.get("escalation_reason"),
    }
    # v0.9.9-i: surface the source-budget breach evidence so the next
    # builder pass can read the exact measured/envelope pair.
    if source_ceiling_breach:
        out["source_ceiling_breach"] = {
            "checkpoint_id": checkpoint_id,
            "measured_diff_lines": measured_diff_lines,
            "effective_max_diff_lines": effective_max_diff_lines,
            "measured_files": measured_files,
            "effective_max_files": effective_max_files,
            "breach": breach_text,
            "repair_instruction": _format_repair_instruction(
                measured_diff_lines=measured_diff_lines,
                effective_max_diff_lines=effective_max_diff_lines,
                measured_files=measured_files,
                effective_max_files=effective_max_files,
                breach_text=breach_text,
                checkpoint_id=checkpoint_id,
                candidate_sha=receipt_candidate,
            ),
        }
    return out


def _blocked_evidence_is_repairable(receipt: dict[str, Any]) -> dict[str, Any] | None:
    """Return the program_source_ceiling_check evidence iff the receipt's
    BLOCKED state actually originated from a bounded source-budget breach.

    Other BLOCKED categories (authority corruption, hard secrets, packet
    corruption, ambiguous lineage) must NOT be silently converted into a
    model repair mission — they are terminal and require operator-gated
    adjudication through channels other than a deterministic bounded
    repair. This gate keeps the BLOCKED repair context narrowly scoped.
    """
    ps = receipt.get("program_source_ceiling_check")
    if not isinstance(ps, dict):
        return None
    if str(ps.get("result") or "") != "fail":
        return None
    if str(ps.get("accounting") or "") != "absolute_baseline_to_candidate":
        return None
    # Other checks must NOT also fail; if scope/protected/secret/validation
    # co-failed with source-budget, this is not a clean source-budget repair.
    for key in ("scope_check", "protected_path_check", "secret_scan_check"):
        chk = receipt.get(key)
        if isinstance(chk, dict) and str(chk.get("result") or "") == "fail":
            return None
    # v0.9.9-i: validation must PASS to authorize a clean source-budget
    # repair. UNKNOWN fails closed.
    if str(receipt.get("validation_status") or "") != "PASS":
        return None
    return ps


def _validation_evidence_is_repairable(
    receipt: dict[str, Any],
) -> dict[str, Any] | None:
    """Return a typed validation-failure evidence iff the BLOCKED state
    actually originated from a deterministic validation-gate failure on a
    source-envelope-clean candidate.

    Round-13 R3 evidence: candidate eaf34dfe… had
    program_source_ceiling_check.result=pass (29944 / 30000) but
    validation_pass=false because `just validate`'s pnpm format:check
    reported six front-end files. Before this helper the dispatcher's
    BLOCKED-receipt transport would refuse the receipt outright
    (validation_pass=False ⇒ not repairable), forcing a manual continuation
    that may repeat the R3 cycle's mistake (source-ceiling focus) rather
    than authorize a coherent bounded formatting repair.

    Scope is deliberately narrow:

      * ``validation_pass`` MUST be False (the gateway was actually
        tripped; receipt records it);
      * ``program_source_ceiling_check.result`` MUST be ``pass`` (the
        source envelope was honored — source-budget is not the trip);
      * scope/protected/secret MUST NOT co-fail (those remain terminal);
      * at least one entry in ``receipt.validation`` must have
        ``passed=False``.
    """
    if not isinstance(receipt, dict):
        return None
    if str(receipt.get("validation_status") or "") != "FAIL":
        return None
    ps = receipt.get("program_source_ceiling_check")
    if not isinstance(ps, dict) or str(ps.get("result") or "") != "pass":
        return None
    for key in ("scope_check", "protected_path_check", "secret_scan_check"):
        chk = receipt.get(key)
        if isinstance(chk, dict) and str(chk.get("result") or "") == "fail":
            return None
    validations = receipt.get("validation") or []
    if not isinstance(validations, list):
        return None
    failed = [
        v
        for v in validations
        if isinstance(v, dict) and not bool(v.get("passed"))
    ]
    if not failed:
        return None
    return {
        "kind": "validation_formatting",
        "ps": ps,
        "failed_validations": failed,
    }


def _format_repair_instruction(
    *,
    measured_diff_lines: int,
    effective_max_diff_lines: int,
    measured_files: int,
    effective_max_files: int,
    breach_text: str,
    checkpoint_id: str,
    candidate_sha: str,
) -> str:
    """Deterministic Bounded-Source-Budget Repair instruction.

    The model must NOT have to invent why it was authorized. The core
    formulates the purpose from the receipt evidence: reduce the exact
    candidate's baseline-to-candidate source size to fit inside the exact
    effective envelope while preserving checkpoint acceptance.
    """
    over_lines = measured_diff_lines - effective_max_diff_lines
    return (
        f"The exact prior candidate {candidate_sha} for {checkpoint_id} was "
        f"deterministically BLOCKED because its baseline-to-candidate source "
        f"size ({measured_diff_lines} diff_lines across {measured_files} "
        f"files) exceeds the frozen approved effective source ceiling "
        f"({effective_max_diff_lines} diff_lines, {effective_max_files} "
        f"files) by {over_lines} diff_lines. Preserve the current "
        f"checkpoint's acceptance criteria while reducing the candidate "
        f"inside the recorded effective source envelope. Do not widen or "
        f"modify the packet. The recorded breach is: {breach_text}"
    )


def _format_validation_repair_instruction(
    *,
    checkpoint_id: str,
    candidate_sha: str,
    measured_diff_lines: int,
    effective_max_diff_lines: int,
    measured_files: int,
    effective_max_files: int,
    failed_paths: list[str],
    failed_command: str,
) -> str:
    """Bounded-validation-repair instruction.

    The model must NOT widen the packet or weaken acceptance: keep the
    absolute candidate inside the frozen 30,000-line / 500-file envelope,
    preserve checkpoint acceptance, repair only the named formatting
    failures referenced in the receipts.
    """
    paths_text = ", ".join(failed_paths) if failed_paths else "(none recorded)"
    return (
        f"The exact prior candidate {candidate_sha} for {checkpoint_id} was "
        f"deterministically BLOCKED with program_source_ceiling_check=pass "
        f"({measured_diff_lines}/{effective_max_diff_lines} diff lines and "
        f"{measured_files}/{effective_max_files} files) because the "
        f"`{failed_command}` validation failed. The recorded failing "
        f"paths are: {paths_text}. Repair ONLY the recorded formatting "
        f"validation failures while preserving the current checkpoint's "
        f"acceptance criteria and keeping the absolute baseline-to-candidate "
        f"size within the frozen effective envelope "
        f"({effective_max_diff_lines} diff lines, {effective_max_files} "
        f"files). Do not widen or modify the packet; do not relax or "
        f"delete any acceptance test."
    )


def _repair_context_from_blocked_receipt(
    *,
    canonical_repo: Path,
    run_id: str,
    state_doc: dict[str, Any],
    receipt: dict[str, Any],
) -> dict[str, Any] | None:
    """Return a typed BLOCKED repair context.

    Supports two narrowly-scoped kinds:

      * source-budget repair: the receipt's
        ``program_source_ceiling_check.result == fail`` with no co-failing
        scope/protected/secret/validation check;
      * bounded-validation repair: the receipt's
        ``validation_pass == False`` while
        ``program_source_ceiling_check.result == pass`` with no
        co-failing scope/protected/secret check.

    Authority is established only by the convergence of:

      * a clean BLOCKED BUILD_RECEIPT of one of the two kinds above;
      * a matching funded PROGRAM continuation receipt at the same
        checkpoint, candidate, and funded repair round.

    A BLOCKED BUILD_RECEIPT alone is never authoritative. The dispatcher
    fails closed when either side is missing or disagrees.
    """
    ps = _blocked_evidence_is_repairable(receipt)
    repair_kind = "source_ceiling"
    failed_validations: list[dict[str, Any]] = []
    failed_paths_for_instruction: list[str] = []
    failed_command_name = ""
    if ps is None:
        val_evidence = _validation_evidence_is_repairable(receipt)
        if val_evidence is None:
            return None
        repair_kind = "validation_formatting"
        ps = val_evidence["ps"]
        failed_validations = val_evidence["failed_validations"]
        # Extract named failing paths from the recorded stderr excerpt so the
        # builder does not need to rediscover them. Index candidate paths
        # against the receipt's documented changed_paths so format-check paths
        # (which may be top-level like CHANGELOG.md or nested) both surface.
        changed_paths = list(receipt.get("changed_paths") or [])
        for v in failed_validations:
            if not failed_command_name:
                failed_command_name = str(v.get("name") or v.get("command") or "")
            for key in ("stderr_excerpt_redacted", "stdout_excerpt_redacted"):
                excerpt = str(v.get(key) or "")
                if not excerpt:
                    continue
                for candidate_path in changed_paths:
                    if (
                        candidate_path
                        and candidate_path not in failed_paths_for_instruction
                        and candidate_path in excerpt
                    ):
                        failed_paths_for_instruction.append(candidate_path)

    continuation = continuation_authority_mod.find_supported_for_blocked_repair(
        canonical_repo=canonical_repo,
        run_id=run_id,
        state_doc=state_doc,
    )
    if continuation is None:
        return None

    program_state = state_doc.get("program") or {}
    current_checkpoints = program_state.get("current_checkpoints") or []
    checkpoint_id = str(current_checkpoints[0]) if current_checkpoints else ""

    measured_diff_lines = int(ps.get("diff_lines_total") or 0)
    effective_max_diff_lines = int(ps.get("effective_max_diff_lines") or 0)
    measured_files = int(ps.get("files_changed_unique") or 0)
    effective_max_files = int(ps.get("effective_max_files_changed") or 0)
    breach_text = str(ps.get("breach") or "")

    candidate_sha = str(receipt.get("candidate_sha") or "")

    if repair_kind == "source_ceiling":
        repair_instruction = _format_repair_instruction(
            measured_diff_lines=measured_diff_lines,
            effective_max_diff_lines=effective_max_diff_lines,
            measured_files=measured_files,
            effective_max_files=effective_max_files,
            breach_text=breach_text,
            checkpoint_id=checkpoint_id,
            candidate_sha=candidate_sha,
        )
    else:
        repair_instruction = _format_validation_repair_instruction(
            checkpoint_id=checkpoint_id,
            candidate_sha=candidate_sha,
            measured_diff_lines=measured_diff_lines,
            effective_max_diff_lines=effective_max_diff_lines,
            measured_files=measured_files,
            effective_max_files=effective_max_files,
            failed_paths=failed_paths_for_instruction,
            failed_command=failed_command_name or "validate",
        )

    return {
        "schema": "ownframework-loop-blocked-repair-context/v1",
        "source": str(
            state_mod.run_dir(canonical_repo, run_id) / "BUILD_RECEIPT.json"
        ),
        "source_kind": "blocked_build_receipt",
        "verification_chain": {
            "block_kind": (
                "frozen_source_budget_breach"
                if repair_kind == "source_ceiling"
                else "validation_failed_with_clean_source_envelope"
            ),
            "blocked_receipt_run_id": run_id,
            "blocked_receipt_candidate_sha": candidate_sha,
            "continuation_id": str(continuation.get("continuation_id") or ""),
            "continuation_run_id": str(continuation.get("run_id") or ""),
            "continuation_checkpoint_id": str(continuation.get("checkpoint_id") or ""),
            "continuation_candidate_sha": str(continuation.get("candidate_sha") or ""),
            "continuation_active_candidate_sha": str(
                continuation.get("active_candidate_sha") or ""
            ),
            "continuation_status": str(continuation.get("status") or ""),
            "current_repair_round": int(state_doc.get("repair_round") or 0),
            "current_checkpoints": list(current_checkpoints),
            "current_last_candidate_sha": str(state_doc.get("last_candidate_sha") or ""),
        },
        "checkpoint_id": checkpoint_id,
        "candidate_sha_reviewed": candidate_sha,
        "repair_round": int(state_doc.get("repair_round") or 0),
        "continuation_id": str(continuation.get("continuation_id") or ""),
        "continuation_reason": str(continuation.get("reason") or ""),
        "repair_kind": repair_kind,
        "measured_files_changed": measured_files,
        "measured_diff_lines": measured_diff_lines,
        "effective_max_files_changed": effective_max_files,
        "effective_max_diff_lines": effective_max_diff_lines,
        "top_level_risk_max_files_changed": int(
            ps.get("top_level_risk_max_files_changed") or 0
        ),
        "top_level_risk_max_diff_lines": int(
            ps.get("top_level_risk_max_diff_lines") or 0
        ),
        "program_max_unique_changed_files": int(
            ps.get("program_max_unique_changed_files") or 0
        ),
        "program_max_baseline_to_final_diff_lines": int(
            ps.get("program_max_baseline_to_final_diff_lines") or 0
        ),
        "program_source_ceiling_result": str(ps.get("result") or ""),
        "breach_text": breach_text,
        "failed_validations": failed_validations,
        "failed_formatting_paths": failed_paths_for_instruction,
        "repair_instruction": repair_instruction,
    }


def _repair_context_for_build(
    *,
    canonical_repo: Path,
    run_id: str,
    state_doc: dict[str, Any],
) -> dict[str, Any] | None:
    """Return deterministic feedback for a fresh repair builder pass.

    The context is non-authoritative transport. REVIEW_VERDICT.json and
    BUILD_RECEIPT.json remain authoritative. A fresh semantic worker should
    not have to rediscover the prior failure from scratch, but it remains
    free to reason about the best coherent fix.

    Two deterministic sources, in freshness order:

      1. The latest REVIEW_VERDICT.json, when it is CHANGES_REQUESTED and
         reviewed the exact current candidate.
      2. The latest BUILD_RECEIPT.json, when the deterministic build
         finalizer itself routed the run to CHANGES_REQUESTED for the exact
         current candidate (required validation failed).

    A stale verdict (reviewed an earlier candidate, e.g. the current
    CHANGES_REQUESTED came from build validation after a repair) is a
    legitimate state, not corruption: it simply is not fresh repair
    evidence, so the resolver falls through instead of hard-stopping the
    run. If no source is fresh, the builder proceeds without transport
    context — the packet and worktree remain sufficient authority.
    """
    state_candidate = str(state_doc.get("last_candidate_sha") or "")

    path = state_mod.run_dir(canonical_repo, run_id) / "REVIEW_VERDICT.json"
    verdict = _load_json_file(path)
    if (
        verdict is not None
        and verdict.get("schema") == "ownframework-loop-review-verdict/v2"
        and verdict.get("run_id") == run_id
        and verdict.get("verdict") == "CHANGES_REQUESTED"
    ):
        reviewed_sha = str(verdict.get("candidate_sha_reviewed") or "")
        if reviewed_sha and (not state_candidate or reviewed_sha == state_candidate):
            acceptance = verdict.get("acceptance_results") or []
            non_goals = verdict.get("non_goal_results") or []
            findings = verdict.get("findings") or []
            validations = verdict.get("validation_results") or []
            if all(
                isinstance(items, list)
                for items in (acceptance, non_goals, findings, validations)
            ):
                failed_acceptance = [
                    item for item in acceptance
                    if isinstance(item, dict)
                    and str(item.get("result") or "").lower() != "pass"
                ]
                violated_non_goals = [
                    item for item in non_goals
                    if isinstance(item, dict)
                    and str(item.get("result") or "").lower() != "preserved"
                ]
                return {
                    "schema": "ownframework-loop-repair-context/v1",
                    "source": str(path.resolve(strict=False)),
                    "source_kind": "review_verdict",
                    "repair_round": int(state_doc.get("repair_round") or 0),
                    "review_pass_number": verdict.get("review_pass_number"),
                    "candidate_sha_reviewed": reviewed_sha,
                    "verdict": "CHANGES_REQUESTED",
                    "failure_reason": verdict.get("failure_reason") or "",
                    "failed_acceptance_results": failed_acceptance,
                    "violated_non_goal_results": violated_non_goals,
                    "findings": findings,
                    "validation_results": validations,
                    "escalation_recommended": bool(verdict.get("escalation_recommended")),
                    "escalation_reason": verdict.get("escalation_reason"),
                }

    return _repair_context_from_receipt(
        canonical_repo=canonical_repo, run_id=run_id, state_doc=state_doc,
    )


def _checkpoint_authority_context(
    packet: dict[str, Any],
    state_doc: dict[str, Any],
    *,
    checkpoint_id: str,
    work_unit_id: str,
) -> dict[str, Any]:
    """Return explicit sealed scope authority for semantic workers.

    This is transport context only; deterministic finalizers remain the
    authority.  Keeping the exact packet lists in the work order prevents a
    builder from having to infer that a specific protected child overrides a
    broad allowed parent.

    v0.9.1+: when the durable ``program.review_scope == "program_final"``
    the checkpoint_id is forced empty and the AC list is the full packet
    contract — this is the whole-product review and is NOT scoped to any
    one checkpoint.
    """
    cp = None
    ac_ids: list[str] = []
    durable_scope = None
    if isinstance(state_doc, dict):
        program_state = state_doc.get("program") or {}
        if isinstance(program_state, dict):
            durable_scope = program_state.get("review_scope")
    if durable_scope == program_mod.REVIEW_SCOPE_PROGRAM_FINAL:
        # The final whole-product review sees the full packet contract;
        # no per-checkpoint scope applies.
        checkpoint_id = ""
        cp = None
        ac_ids = program_mod.packet_acceptance_criterion_ids(packet)
    else:
        cp = next(
            (item for item in (packet.get("checkpoint_graph") or {}).get("checkpoints", [])
             if isinstance(item, dict) and item.get("id") == checkpoint_id),
            None,
        )
        ac_ids = list((cp or {}).get("acceptance_criterion_ids") or [])
        if not ac_ids:
            ac_ids = program_mod.packet_acceptance_criterion_ids(packet)
    ac_by_id = {
        str(item.get("id")): str(item.get("text") or "")
        for item in packet.get("acceptance_criteria") or []
        if isinstance(item, dict) and item.get("id")
    }
    return {
        "checkpoint_id": checkpoint_id,
        "work_unit_id": work_unit_id,
        "checkpoint_scope": str((cp or {}).get("scope") or packet.get("scope") or ""),
        "review_scope": (
            durable_scope
            if durable_scope in (
                program_mod.REVIEW_SCOPE_CHECKPOINT,
                program_mod.REVIEW_SCOPE_PROGRAM_FINAL,
            )
            else program_mod.REVIEW_SCOPE_CHECKPOINT
        ),
        "acceptance_criterion_ids": ac_ids,
        "acceptance_criteria": [
            {"id": item, "text": ac_by_id.get(str(item), "")}
            for item in ac_ids
        ],
        "allowed_paths": list(packet.get("allowed_paths") or []),
        "elevated_allowed_paths": list(packet.get("elevated_allowed_paths") or []),
        "protected_paths": list(packet.get("protected_paths") or []),
        "protected_path_rule": (
            "Protected paths are immutable. A broad allowed parent never overrides "
            "a more-specific protected child; do not edit protected files unless "
            "the deterministic core performs a supported recovery."
        ),
    }


def _claim_or_terminal(
    args: list[str], *, repo: Path, run_id: str
) -> dict[str, Any]:
    """Run one claim CLI command; convert cap-exhaustion seals to TERMINAL.

    Claim owners fail closed toward BLOCKED when a packet-bound cap is
    exhausted. When the claim fails but the run is now terminal, dispatch
    surfaces the terminal result instead of an error, so the supervisor
    completes the job cleanly without an operator quarantine/resume cycle.
    """
    try:
        return _run_cli(args)
    except DispatchError:
        cur = state_mod.load_verified(repo, run_id)
        if isinstance(cur, dict):
            new_state = str(cur.get("state") or "")
            if new_state in TERMINAL_STATES:
                return _terminal(run_id, new_state)
        raise


def claim_next(*, canonical_repo: Path, run_id: str) -> dict[str, Any]:
    """Return exactly one BUILD, REVIEW, WAIT, or TERMINAL work order.

    The per-run DISPATCH_LOCK prevents two supervisors from materializing
    competing work orders. Existing build/review claim locks remain the final
    pass-counter authority and make replay idempotent.
    """
    repo = Path(canonical_repo).resolve(strict=False)
    if not repo.is_dir():
        raise DispatchError(f"repository not found: {repo}")

    run_dir = state_mod.run_dir(repo, run_id)
    lock_path = run_dir / "DISPATCH_LOCK"
    try:
        with flock_exclusive(lock_path, blocking=True, timeout_seconds=30):
            rr = reconcile_mod.reconcile_run(canonical_repo=repo, run_id=run_id)
            if not rr.get("ok"):
                raise DispatchError(
                    "reconciliation refused: " + "; ".join(rr.get("refused") or [])
                )

            cur = state_mod.load_verified(repo, run_id)
            if not isinstance(cur, dict):
                raise DispatchError(f"STATE.json missing or invalid for {run_id}")
            state = str(cur.get("state") or "")

            # v0.6 executable packet authority — refuse legacy/auto-promote shapes
            # before any core claim.
            #
            # Two distinct classifications with distinct narrow catches:
            #
            #   1. The packet file is unreadable / unparseable → "packet unreadable"
            #   2. The packet parses cleanly but is not executable under current
            #      authority (e.g. legacy `merge_authority=auto`, the
            #      `external_action_authority=delegated` shape, or
            #      `promotion_policy=merge_on_approved`) → "packet not
            #      executable under current authority"
            #
            # The previous `except (ValueError, Exception)` was equivalent to
            # `except Exception` and silently mislabeled legitimate
            # non-executable-authority refusals as "packet unreadable", AND
            # swallowed unexpected programmer defects in the authority path as
            # packet-read failures. We split the two phases so each phase
            # carries its own narrow, honest error classification, and any
            # unexpected internal exception from the authority evaluator
            # propagates unchanged so the supervisor sees the real failure.
            packet_path = run_dir / "WORK_PACKET.md"
            try:
                pmeta, _ = packet_mod.parse_packet_file(packet_path)
            except (OSError, ValueError) as exc:
                raise DispatchError(f"packet unreadable: {exc}") from exc

            ok, reasons = packet_mod.packet_is_executable_under_current_authority(pmeta)
            if not ok:
                raise DispatchError(
                    "packet not executable under current authority: "
                    + "; ".join(reasons)
                )

            if state in TERMINAL_STATES:
                return _terminal(run_id, state)

            if state in BUILD_STATES:
                repair_context = _repair_context_for_build(
                    canonical_repo=repo,
                    run_id=run_id,
                    state_doc=cur,
                )
                claim = _claim_or_terminal(
                    ["build", "claim", str(repo), run_id, "--actor", "ofloop-supervisor"],
                    repo=repo, run_id=run_id,
                )
                if claim.get("decision") == "TERMINAL":
                    return claim
                prep = _run_cli(["build", "prepare", str(repo), run_id])
                skel = _run_cli(["build", "agent-skeleton", str(repo), run_id])
                semantic_path = (
                    prep.get("agent_result_path") or skel.get("agent_result_path")
                )
                if not semantic_path:
                    raise DispatchError("build preparation returned no semantic path")
                work_unit_id = str(prep.get("work_unit_id") or "")
                checkpoint_id = str(prep.get("cp_id") or "")
                return {
                    "schema": SCHEMA,
                    "decision": "BUILD",
                    "role": "builder",
                    "run_id": run_id,
                    "state": "BUILDING",
                    "replayed": bool(claim.get("replayed")),
                    "canonical_repo": str(repo),
                    "worktree": prep.get("builder_worktree"),
                    "semantic_path": semantic_path,
                    "candidate_branch": prep.get("candidate_branch"),
                    "baseline_sha": prep.get("baseline_sha"),
                    "packet_sha256": prep.get("packet_sha256"),
                    "approval_sha256": prep.get("approval_sha256"),
                    "checkpoint_id": checkpoint_id,
                    "work_unit_id": work_unit_id,
                    "acceptance_criterion_ids": prep.get("acceptance_criterion_ids"),
                    "checkpoint_authority": _checkpoint_authority_context(
                        pmeta, cur, checkpoint_id=checkpoint_id, work_unit_id=work_unit_id
                    ),
                    "repair_context": repair_context,
                    "network_read_allowlist": list(pmeta.get("network_read_allowlist") or []),
                    "capabilities": list(pmeta.get("capabilities") or []),
                    "runner_profile": str(pmeta.get("runner_profile") or "default"),
                    "claim": claim,
                    "prepare": prep,
                }

            if state in REVIEW_STATES:
                claim = _claim_or_terminal(
                    ["review", "claim", str(repo), run_id, "--actor", "ofloop-supervisor"],
                    repo=repo, run_id=run_id,
                )
                if claim.get("decision") == "TERMINAL":
                    return claim
                prep = _run_cli(["review", "prepare", str(repo), run_id])
                skel = _run_cli(
                    ["review", "assessment-skeleton", str(repo), run_id]
                )
                semantic_path = prep.get("assessment_path") or skel.get(
                    "assessment_path"
                )
                if not semantic_path:
                    raise DispatchError("review preparation returned no semantic path")
                checkpoint_id = str(prep.get("checkpoint_id") or "")
                review_scope = str(prep.get("review_scope") or "checkpoint")
                return {
                    "schema": SCHEMA,
                    "decision": "REVIEW",
                    "role": "reviewer",
                    "run_id": run_id,
                    "state": "REVIEWING",
                    "replayed": bool(claim.get("replayed")),
                    "canonical_repo": str(repo),
                    "worktree": prep.get("reviewer_worktree"),
                    "semantic_path": semantic_path,
                    "candidate_branch": prep.get("candidate_branch"),
                    "baseline_sha": prep.get("baseline_sha"),
                    "packet_sha256": prep.get("packet_sha256"),
                    "approval_sha256": prep.get("approval_sha256"),
                    "build_receipt_sha256": prep.get("build_receipt_sha256"),
                    "candidate_sha": prep.get("candidate_sha"),
                    "checkpoint_id": checkpoint_id,
                    "review_scope": review_scope,
                    "acceptance_criterion_ids": prep.get("acceptance_criterion_ids"),
                    "checkpoint_authority": _checkpoint_authority_context(
                        pmeta, cur, checkpoint_id=checkpoint_id,
                        work_unit_id=str(prep.get("work_unit_id") or ""),
                    ),
                    "non_goal_ids": [
                        str(item.get("id"))
                        for item in (pmeta.get("non_goals") or [])
                        if isinstance(item, dict) and item.get("id")
                    ],
                    "network_read_allowlist": list(pmeta.get("network_read_allowlist") or []),
                    "capabilities": list(pmeta.get("capabilities") or []),
                    "runner_profile": str(pmeta.get("runner_profile") or "default"),
                    "claim": claim,
                    "prepare": prep,
                }

            return {
                "schema": SCHEMA,
                "decision": "WAIT",
                "run_id": run_id,
                "state": state,
                "reason": "state_not_actionable",
            }
    except LockBusyError as exc:
        raise DispatchError(f"dispatch lock contention: {exc}") from exc


def finalize_work_order(
    work_order: dict[str, Any],
    *,
    timeout_seconds: int | None = None,
) -> dict[str, Any]:
    """Finalize one semantic BUILD or REVIEW result through core-owned CLI."""
    if work_order.get("schema") != SCHEMA:
        raise DispatchError("invalid work-order schema")
    decision = str(work_order.get("decision") or "")
    if decision not in {"BUILD", "REVIEW"}:
        raise DispatchError(f"cannot finalize decision={decision!r}")

    repo = str(work_order.get("canonical_repo") or "")
    run_id = str(work_order.get("run_id") or "")
    semantic = Path(str(work_order.get("semantic_path") or "")).resolve(strict=False)
    if not repo or not run_id or not semantic.is_file():
        raise DispatchError("semantic result is missing; refusing finalization")

    # Finalization identity is deterministic core truth, not caller authority.
    # The supervisor may pass the original prepared work order, while the CLI
    # intentionally carries only repo/run/decision/semantic_path. Hydrate any
    # omitted identity from canonical protocol/runtime state and reject drift.
    repo_path = Path(repo).resolve(strict=False)
    hydrated = dict(work_order)
    if decision == "BUILD":
        expected_wt = util.builder_worktree(repo_path, run_id).resolve(strict=False)
        supplied_wt = str(hydrated.get("worktree") or "")
        if supplied_wt and Path(supplied_wt).resolve(strict=False) != expected_wt:
            raise DispatchError("builder worktree identity drift before finalization")
        hydrated["worktree"] = str(expected_wt)
    else:
        expected_wt = util.reviewer_worktree(repo_path, run_id).resolve(strict=False)
        supplied_wt = str(hydrated.get("worktree") or "")
        if supplied_wt and Path(supplied_wt).resolve(strict=False) != expected_wt:
            raise DispatchError("reviewer worktree identity drift before finalization")
        hydrated["worktree"] = str(expected_wt)

        state = state_mod.load_verified(repo_path, run_id)
        expected_candidate = str(state.get("last_candidate_sha") or "")
        if not expected_candidate:
            raise DispatchError("review candidate missing from protocol state")
        supplied_candidate = str(hydrated.get("candidate_sha") or "")
        if supplied_candidate and supplied_candidate != expected_candidate:
            raise DispatchError("review candidate identity drift before finalization")
        hydrated["candidate_sha"] = expected_candidate

    ready, reason = semantic_result_ready(hydrated)
    if not ready:
        raise SemanticResultIncomplete(reason)

    if decision == "BUILD":
        result = _run_cli(["build", "finalize", repo, run_id, str(semantic)], timeout_seconds=timeout_seconds)
    else:
        result = _run_cli(["review", "finalize", repo, run_id, str(semantic)], timeout_seconds=timeout_seconds)
    return {
        "schema": SCHEMA,
        "decision": decision,
        "run_id": run_id,
        "finalized": True,
        "result": result,
    }


__all__ = [
    "DispatchError",
    "SCHEMA",
    "claim_next",
    "finalize_work_order",
    "reseed_semantic_artifact_for_retry",
    "semantic_result_ready",
]
