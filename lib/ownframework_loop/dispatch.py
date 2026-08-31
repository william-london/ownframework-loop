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
import subprocess
from pathlib import Path
from typing import Any

from . import (
    approval as approval_mod,
    assessment as assessment_mod,
    build_agent as build_agent_mod,
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
    "review_schema_mismatch",
    "review_candidate_mismatch",
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
    """
    path = state_mod.run_dir(canonical_repo, run_id) / "BUILD_RECEIPT.json"
    receipt = _load_json_file(path)
    if receipt is None:
        return None
    if str(receipt.get("next_state") or "") != "CHANGES_REQUESTED":
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

    return {
        "schema": "ownframework-loop-repair-context/v1",
        "source": str(path.resolve(strict=False)),
        "source_kind": "build_receipt",
        "repair_round": int(state_doc.get("repair_round") or 0),
        "candidate_sha_reviewed": receipt_candidate,
        "verdict": "CHANGES_REQUESTED",
        "failure_reason": "build_finalizer_validation_failed",
        "failed_validation_results": failed_validations,
        "scope_findings": scope_check.get("findings") or [],
        "protected_path_findings": protected_check.get("offending_paths") or [],
        "secret_findings": (secret_check.get("findings") or [])[:10],
        "blocker_reason": receipt.get("blocker_reason"),
        "escalation_recommended": bool(receipt.get("escalation_recommended")),
        "escalation_reason": receipt.get("escalation_reason"),
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
                    "checkpoint_id": prep.get("cp_id"),
                    "acceptance_criterion_ids": prep.get("acceptance_criterion_ids"),
                    "repair_context": repair_context,
                    "network_read_allowlist": list(pmeta.get("network_read_allowlist") or []),
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
                    "candidate_sha": prep.get("candidate_sha"),
                    "checkpoint_id": prep.get("checkpoint_id"),
                    "acceptance_criterion_ids": prep.get("acceptance_criterion_ids"),
                    "non_goal_ids": [
                        str(item.get("id"))
                        for item in (pmeta.get("non_goals") or [])
                        if isinstance(item, dict) and item.get("id")
                    ],
                    "network_read_allowlist": list(pmeta.get("network_read_allowlist") or []),
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
    "semantic_result_ready",
]
