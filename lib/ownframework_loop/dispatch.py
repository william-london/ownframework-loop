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

from . import reconcile as reconcile_mod, state as state_mod
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
    if semantic.stat().st_size <= 2:
        raise DispatchError("semantic result is empty; refusing finalization")

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
]
