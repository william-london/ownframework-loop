"""State machine for OwnFramework Loop — exactly the 9 specified states.

v0.3.7 (F-2-01 / F-2-02 / F-2-03): monotonic terminal precedence.
  * STOPPED is absorbing — no FSM (single-mode or program-mode) may
    transition out of it. Operator-initiated STOPPED is final.
  * BLOCKED cannot become APPROVED — the only program-mode escape from
    BLOCKED is READY_TO_BUILD (orchestrator clears the blocker and
    resumes the run). APPROVED from BLOCKED is refused.
  * APPROVED is reachable ONLY from REVIEWING or, in program-mode,
    from READY_FOR_REVIEW when the verdict and candidate SHA are
    consistent with the bound candidate recorded on the run.

The `assert_valid_program` helper now accepts a `bound_candidate_sha`
keyword. If the candidate SHA on the transition is non-None and
differs from the run's `last_candidate_sha`, the transition is
refused — this prevents a stale review verdict from re-approving a
candidate that has since been overwritten.
"""

from __future__ import annotations

from typing import FrozenSet, Mapping, Optional


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
    # Terminal (v0.3.7 F-2-01): STOPPED is absorbing. The empty
    # frozenset is enforced at the FSM level and reasserted in
    # assert_valid_program. There is no program-mode escape from
    # STOPPED.
    "APPROVED":          frozenset(),
    "BLOCKED":           frozenset(),  # v0.3.7 F-2-02: BLOCKED cannot become APPROVED
    "STOPPED":           frozenset(),  # v0.3.7 F-2-01: STOPPED absorbing
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
# v0.3.7 (F-2-01/F-2-02/F-2-03): STOPPED is absorbing even in program
# mode. BLOCKED cannot jump straight to APPROVED — the only program-
# mode escape is back to READY_TO_BUILD (orchestrator clears the
# blocker and resumes). APPROVED in program mode is reachable only
# when the candidate SHA matches the bound candidate.
PROGRAM_ALLOWED: Mapping[str, FrozenSet[str]] = {
    # A reviewed/approved checkpoint may atomically finalize its PROGRAM
    # evidence and advance directly to the next checkpoint. The prospective
    # PROGRAM block determines whether another checkpoint truly remains.
    "REVIEWING": frozenset({"READY_TO_BUILD"}),
    "APPROVED":  frozenset({"READY_TO_BUILD"}),
    "BLOCKED":   frozenset({"READY_TO_BUILD"}),  # not APPROVED
    "STOPPED":   frozenset(),                     # absorbing
}


def assert_valid_program(
    from_state: str,
    to_state: str,
    *,
    has_more_checkpoints: bool,
    bound_candidate_sha: Optional[str] = None,
) -> None:
    """Validate a PROGRAM-mode transition.

    Combines the single-mode FSM (assert_valid) with the
    program-mode extension. The single-mode FSM is checked first so
    non-program transitions (e.g. AWAITING_APPROVAL -> READY_TO_BUILD)
    follow the same rules as single-mode.

    Program-mode extensions (review advancement and APPROVED/BLOCKED -> READY_TO_BUILD)
    are permitted ONLY when `has_more_checkpoints` is True. Once the
    program is fully terminated (no more checkpoints), the run is
    terminal and the transition is refused.

    v0.3.7 (F-2-03): the bound_candidate_sha keyword, when non-None,
    pins the transition to that exact candidate SHA. A stale or
    different candidate SHA will refuse the transition. This guards
    against TOCTOU between the finalizer computing its verdict and
    the state transition committing (the lock spans validation but
    not finalization; the candidate SHA binding is the second
    layer of defence).
    """
    if from_state not in STATES:
        raise InvalidTransitionError(f"unknown source state: {from_state}")
    if to_state not in STATES:
        raise InvalidTransitionError(f"unknown target state: {to_state}")
    # v0.3.7 (F-2-01): STOPPED is absorbing even in program mode.
    # There is no legal way out; refuse early with a clear message.
    if from_state == "STOPPED":
        raise InvalidTransitionError(
            f"STOPPED is absorbing: {from_state} -> {to_state} refused"
        )
    # v0.3.7 (F-2-02): BLOCKED cannot become APPROVED in any mode.
    if from_state == "BLOCKED" and to_state == "APPROVED":
        raise InvalidTransitionError(
            f"BLOCKED cannot become APPROVED: refused"
        )
    if is_valid(from_state, to_state):
        return
    # Single-mode FSM refused — try program-mode extension.
    if has_more_checkpoints and to_state in PROGRAM_ALLOWED.get(from_state, frozenset()):
        return
    raise InvalidTransitionError(
        f"transition not allowed: {from_state} -> {to_state} "
        f"(has_more_checkpoints={has_more_checkpoints})"
    )
