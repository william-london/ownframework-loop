"""Typed operational dispatch-hold predicates.

This module reads verified repository engineering state but never mutates it.
The supervisor owns the durable hold lifecycle; this module only answers the
single supported PROGRAM boundary question.
"""
from __future__ import annotations

from pathlib import Path
from typing import Any

from . import state as state_mod

PROGRAM_CHECKPOINT_BOUNDARY = "PROGRAM_CHECKPOINT_BOUNDARY"


def engineering_boundary_matches(
    *, repo: Path, run_id: str, hold: Any,
) -> tuple[bool, str]:
    if str(hold["kind"]) != PROGRAM_CHECKPOINT_BOUNDARY:
        return False, "unsupported_hold_kind"
    try:
        snapshot = state_mod.load_verified(repo, run_id)
    except Exception as exc:
        return False, f"engineering_state_unavailable:{type(exc).__name__}"
    program = snapshot.get("program") or {}
    previous = str(hold["previous_checkpoint_id"])
    following = str(hold["next_checkpoint_id"])
    finalized = {
        str(item.get("id")): str(item.get("terminal_state") or "")
        for item in program.get("finalized_checkpoints", [])
        if isinstance(item, dict)
    }
    checkpoints = {
        str(item.get("id")): item
        for item in program.get("checkpoints", [])
        if isinstance(item, dict)
    }
    previous_cp = checkpoints.get(previous) or {}
    next_cp = checkpoints.get(following) or {}
    if not previous_cp or not next_cp:
        return False, "checkpoint_identity_not_found"
    if finalized.get(previous) != "APPROVED" or previous_cp.get("terminal") != "APPROVED":
        return False, "previous_checkpoint_not_approved"
    if (program.get("current_checkpoints") or []) != [following]:
        return False, "next_checkpoint_not_current"
    if snapshot.get("state") != "READY_TO_BUILD":
        return False, "top_level_state_not_ready_to_build"
    if any(int(next_cp.get(key, 0) or 0) != 0 for key in (
        "build_pass_count", "review_pass_count", "repair_round_count"
    )):
        return False, "next_checkpoint_already_progressed"
    return True, PROGRAM_CHECKPOINT_BOUNDARY
