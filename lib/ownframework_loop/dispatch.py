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

from . import packet as packet_mod, reconcile as reconcile_mod, state as state_mod
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

BUILD_AGENT_SCHEMA = "ownframework-loop-build-agent-result/v1"
REVIEW_AGENT_SCHEMA = "ownframework-loop-review-agent-assessment/v1"
BUILD_OUTCOMES = {"candidate_ready", "blocked", "stopped"}
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
        summary = str(data.get("summary") or "").strip()
        if outcome == "candidate_ready":
            addressed = data.get("acceptance_addressed") or []
            completed = data.get("unit_ids_completed") or []
            if not summary:
                return False, "builder_summary_empty"
            if not addressed and not completed:
                return False, "builder_completion_evidence_empty"
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
    if not isinstance(data.get("findings"), list):
        return False, "review_findings_invalid"

    repo = Path(str(work_order.get("canonical_repo") or "")).resolve(strict=False)
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

    expected_ac = expected_ids(meta.get("acceptance_criteria") or [], "AC")
    expected_ng = expected_ids(meta.get("non_goals") or [], "NG")
    ac = data.get("acceptance_results")
    ng = data.get("non_goal_results")
    if not isinstance(ac, list) or not isinstance(ng, list):
        return False, "review_coverage_not_lists"
    ac_ids = {str(x.get("id") or "") for x in ac if isinstance(x, dict)}
    ng_ids = {str(x.get("id") or "") for x in ng if isinstance(x, dict)}
    if ac_ids != expected_ac:
        return False, "review_acceptance_coverage_incomplete"
    if ng_ids != expected_ng:
        return False, "review_non_goal_coverage_incomplete"
    return True, "ready"


def _ofloop_bin() -> str:
    explicit = os.environ.get("OFLOOP_BIN", "").strip()
    if explicit:
        return explicit
    sibling = Path(__file__).resolve().parent.parent.parent / "bin" / "ofloop"
    return str(sibling) if sibling.exists() else "ofloop"


def _run_cli(args: list[str]) -> dict[str, Any]:
    proc = subprocess.run(
        [_ofloop_bin(), *args],
        capture_output=True,
        text=True,
        check=False,
    )
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

            cur = state_mod.load(repo, run_id)
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
                claim = _run_cli(
                    ["build", "claim", str(repo), run_id, "--actor", "ofloop-supervisor"]
                )
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
                    "claim": claim,
                    "prepare": prep,
                }

            if state in REVIEW_STATES:
                claim = _run_cli(
                    ["review", "claim", str(repo), run_id, "--actor", "ofloop-supervisor"]
                )
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


def finalize_work_order(work_order: dict[str, Any]) -> dict[str, Any]:
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
    ready, reason = semantic_result_ready(work_order)
    if not ready:
        raise DispatchError(
            f"semantic result is incomplete ({reason}); refusing finalization"
        )

    if decision == "BUILD":
        result = _run_cli(["build", "finalize", repo, run_id, str(semantic)])
    else:
        result = _run_cli(["review", "finalize", repo, run_id, str(semantic)])
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
