"""Loop scheduling — emit the compact operator marker for /loop self-pacing."""

from __future__ import annotations

from typing import Any


def builder_marker(
    *,
    run_id: str,
    state: str,
    action: str,
    next_delay_minutes: int,
    reason: str,
) -> str:
    """Return the operator marker for a builder pass completion."""
    return _marker(
        run_id=run_id,
        role="builder",
        state=state,
        action=action,
        next_delay_minutes=next_delay_minutes,
        reason=reason,
    )


def reviewer_marker(
    *,
    run_id: str,
    state: str,
    action: str,
    next_delay_minutes: int,
    reason: str,
) -> str:
    return _marker(
        run_id=run_id,
        role="reviewer",
        state=state,
        action=action,
        next_delay_minutes=next_delay_minutes,
        reason=reason,
    )


def _marker(
    *,
    run_id: str,
    role: str,
    state: str,
    action: str,
    next_delay_minutes: int,
    reason: str,
) -> str:
    lines = [
        "OF_LOOP_OPERATOR_MARKER",
        f"OF_LOOP_RUN_ID={run_id}",
        f"OF_LOOP_ROLE={role}",
        f"OF_LOOP_STATE={state}",
        f"OF_LOOP_ACTION={action}",
        f"OF_LOOP_NEXT_DELAY_MINUTES={next_delay_minutes}",
        f"OF_LOOP_REASON={reason}",
    ]
    return "\n".join(lines) + "\n"


def recommend_next_delay_minutes(
    *, role: str, state: str
) -> tuple[str, int]:
    """Pick the next-delay recommendation for self-paced /loop.

    Returns (action, next_delay_minutes). Action is RESCHEDULE or STOP.
    """
    if role == "builder":
        return _builder_decision(state)
    if role == "reviewer":
        return _reviewer_decision(state)
    raise ValueError(f"unknown role: {role}")


def _builder_decision(state: str) -> tuple[str, int]:
    if state in ("READY_TO_BUILD", "BUILDING", "CHANGES_REQUESTED"):
        return "RESCHEDULE", 0
    if state == "AWAITING_APPROVAL":
        # Pre-start is STARTABLE: the builder owns the first claim, which
        # creates the execution seal. Never STOP a startable run.
        return "RESCHEDULE", 0
    if state == "READY_FOR_REVIEW":
        # The next semantic action (review) is available immediately. The
        # builder lane hands over with zero idle delay.
        return "RESCHEDULE", 0
    if state == "REVIEWING":
        return "RESCHEDULE", 5
    if state in ("APPROVED", "BLOCKED", "STOPPED"):
        return "STOP", 0
    return "STOP", 0


def _reviewer_decision(state: str) -> tuple[str, int]:
    if state == "READY_FOR_REVIEW":
        return "RESCHEDULE", 0
    if state in ("READY_TO_BUILD", "CHANGES_REQUESTED"):
        # The builder owns these phases, but the next candidate may complete
        # at any moment: keep polling with zero idle delay so the review
        # starts immediately.
        return "RESCHEDULE", 0
    if state == "AWAITING_APPROVAL":
        # The builder owns first start; the reviewer lane waits briefly
        # instead of terminating, so it picks up the first candidate.
        return "RESCHEDULE", 5
    if state in ("BUILDING", "REVIEWING"):
        return "RESCHEDULE", 5
    if state in ("APPROVED", "BLOCKED", "STOPPED"):
        return "STOP", 0
    return "STOP", 0


def decide_action_after_pass(state: str) -> str:
    """Return STOP if state is terminal; RESCHEDULE otherwise."""
    if state in ("APPROVED", "BLOCKED", "STOPPED"):
        return "STOP"
    return "RESCHEDULE"
