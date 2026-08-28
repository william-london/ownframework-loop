"""Retired legacy unattended orchestrator.

The pre-0.6 `ofloop loop run` path drove deterministic finalizers without a
real semantic builder/reviewer process. That could create an APPROVED review
verdict without semantic reviewer evidence. It is intentionally disabled.

Interactive `/loop /of-loop:build` and `/loop /of-loop:review` remain valid
adapter UX. Durable unattended execution belongs to dispatch.py +
supervisor.py.
"""
from __future__ import annotations

from pathlib import Path
from typing import Any

TERMINAL_STATES = {"APPROVED", "BLOCKED", "STOPPED"}
MAX_REPAIR_ROUNDS_DEFAULT = 3
RETIREMENT_REASON = "legacy_unattended_orchestrator_retired_use_supervisor"


def _retired(run_id: str | None = None) -> dict[str, Any]:
    return {
        "ok": False,
        "run_id": run_id,
        "terminal_state": None,
        "reason": RETIREMENT_REASON,
        "replacement": "ofloop supervisor enqueue <repo> <run-id> && ofloop supervisor serve",
    }


def run_single_mode(
    *,
    canonical_repo: Path,
    run_id: str | None = None,
    mission: str | None = None,
    max_repair_rounds: int | None = None,
) -> dict[str, Any]:
    return _retired(run_id)


def run_program_mode(
    *,
    canonical_repo: Path,
    run_id: str | None = None,
    mission: str | None = None,
    max_repair_rounds: int | None = None,
) -> dict[str, Any]:
    return _retired(run_id)


def dispatch_run_mode(
    *,
    canonical_repo: Path,
    run_id: str | None = None,
    mission: str | None = None,
    max_repair_rounds: int | None = None,
) -> dict[str, Any]:
    return _retired(run_id)
