"""State machine for OwnFramework Loop V1 — exactly the 9 specified states."""

from __future__ import annotations

from typing import FrozenSet, Mapping


# The 9 states from the design contract.
STATES: FrozenSet[str] = frozenset({
    "AWAITING_APPROVAL",
    "READY_TO_BUILD",
    "BUILDING",
    "READY_FOR_REVIEW",
    "REVIEWING",
    "CHANGES_REQUESTED",
    "APPROVED",
    "BLOCKED",
    "STOPPED",
})

# Allowed transitions. Any transition not listed is rejected.
ALLOWED: Mapping[str, FrozenSet[str]] = {
    "AWAITING_APPROVAL": frozenset({"READY_TO_BUILD", "BLOCKED", "STOPPED"}),
    "READY_TO_BUILD":    frozenset({"BUILDING", "BLOCKED", "STOPPED"}),
    "BUILDING":          frozenset({"READY_FOR_REVIEW", "BLOCKED", "STOPPED"}),
    "READY_FOR_REVIEW":  frozenset({"REVIEWING", "BLOCKED", "STOPPED"}),
    "REVIEWING":         frozenset({
        "APPROVED", "CHANGES_REQUESTED", "BLOCKED", "STOPPED",
        "READY_FOR_REVIEW",  # candidate changed during review
    }),
    "CHANGES_REQUESTED": frozenset({"READY_TO_BUILD", "BLOCKED", "STOPPED"}),
    # Terminal:
    "APPROVED":          frozenset(),
    "BLOCKED":           frozenset(),
    "STOPPED":           frozenset(),
}


TERMINAL_STATES: FrozenSet[str] = frozenset({"APPROVED", "BLOCKED", "STOPPED"})


class InvalidTransitionError(ValueError):
    """Raised when a transition is not in ALLOWED."""


def is_valid(from_state: str, to_state: str) -> bool:
    """Return True if the transition is allowed."""
    if from_state not in STATES:
        return False
    return to_state in ALLOWED.get(from_state, frozenset())


def assert_valid(from_state: str, to_state: str) -> None:
    """Raise InvalidTransitionError if not allowed."""
    if from_state not in STATES:
        raise InvalidTransitionError(f"unknown source state: {from_state}")
    if to_state not in STATES:
        raise InvalidTransitionError(f"unknown target state: {to_state}")
    if not is_valid(from_state, to_state):
        raise InvalidTransitionError(
            f"transition not allowed: {from_state} -> {to_state}"
        )


def is_terminal(state: str) -> bool:
    return state in TERMINAL_STATES
