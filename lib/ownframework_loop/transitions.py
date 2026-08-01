"""State machine for OwnFramework Loop V2 — exactly the 9 specified states."""

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
    "BUILDING":          frozenset({"READY_FOR_REVIEW", "CHANGES_REQUESTED", "BLOCKED", "STOPPED"}),
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


# v0.3.5 (A1-001/A1-004/A1-005): PROGRAM-mode state machine extensions.
#
# In single-mode, APPROVED/BLOCKED/STOPPED are terminal (no outbound
# edges). In program-mode (v2 packets with a checkpoint graph), the
# orchestrator may legitimately transition APPROVED back to
# READY_TO_BUILD when there is another claimable checkpoint. The
# single-mode FSM table above is intentionally strict; this dict
# is consulted ONLY by state.program_transition() and only when the
# run carries a `program` sub-object (see state.is_program_state).
#
# The program-mode FSM does NOT make single-mode terminal states
# non-terminal globally. A single-mode run still has terminal
# APPROVED/BLOCKED/STOPPED. The program-mode transition is the
# orchestrator saying: "this run has more checkpoints; advance to
# the next one" — and it must be paired with a `has_more_checkpoints`
# guard so a stale run cannot escape its terminal.
PROGRAM_ALLOWED: Mapping[str, FrozenSet[str]] = {
    # APPROVED/BLOCKED/STOPPED are NOT terminal in program mode when
    # more checkpoints remain.
    "APPROVED":  frozenset({"READY_TO_BUILD"}),
    # BLOCKED in program mode is normally terminal, but the orchestrator
    # may legitimately reset to READY_TO_BUILD if a higher-level review
    # clears the blocker.
    "BLOCKED":   frozenset({"READY_TO_BUILD"}),
    # STOPPED is final once set (operator-initiated).
    "STOPPED":   frozenset(),
}


def assert_valid_program(
    from_state: str,
    to_state: str,
    *,
    has_more_checkpoints: bool,
) -> None:
    """Validate a PROGRAM-mode transition.

    Combines the single-mode FSM (assert_valid) with the
    program-mode extension. The single-mode FSM is checked first so
    non-program transitions (e.g. AWAITING_APPROVAL -> READY_TO_BUILD)
    follow the same rules as single-mode.

    Program-mode escape hatches (APPROVED/BLOCKED -> READY_TO_BUILD)
    are permitted ONLY when `has_more_checkpoints` is True. Once the
    program is fully terminated (no more checkpoints), the run is
    terminal and the transition is refused.
    """
    if from_state not in STATES:
        raise InvalidTransitionError(f"unknown source state: {from_state}")
    if to_state not in STATES:
        raise InvalidTransitionError(f"unknown target state: {to_state}")
    if is_valid(from_state, to_state):
        return
    # Single-mode FSM refused — try program-mode extension.
    if has_more_checkpoints and to_state in PROGRAM_ALLOWED.get(from_state, frozenset()):
        return
    raise InvalidTransitionError(
        f"transition not allowed: {from_state} -> {to_state} "
        f"(has_more_checkpoints={has_more_checkpoints})"
    )
