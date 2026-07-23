"""Repair-limit constants and helpers — enforces the V1 caps in code.

V1 caps (hard maxima). Packets may lower these but must NOT silently
raise them. Every counter increment goes through `enforce_limit`
which refuses to let any counter exceed the cap and raises a
deterministic, recoverable error.
"""

from __future__ import annotations


# V1 caps — these are the absolute maximums. Packets may lower them via
# `packet.meta.risk_budget.*` overrides, but the cap here is the floor.
MAX_BUILD_PASSES = 8
MAX_REVIEW_PASSES = 8
MAX_REPAIR_ROUNDS = 3
MAX_CONSECUTIVE_NO_PROGRESS_PASSES = 2
MAX_IDENTICAL_FINDING_REPEATS = 2

# Counter names (used as keys in STATE.json).
COUNTER_LIMITS: dict[str, int] = {
    "build_pass_count": MAX_BUILD_PASSES,
    "review_pass_count": MAX_REVIEW_PASSES,
    "repair_round": MAX_REPAIR_ROUNDS,
    "no_progress_streak": MAX_CONSECUTIVE_NO_PROGRESS_PASSES,
}


class RepairLimitExceeded(RuntimeError):
    """Raised when a counter would exceed the V1 cap.

    Caller should transition to BLOCKED or STOPPED and surface this as
    a durable event in EVENTS.log.
    """


def cap_for(counter: str) -> int | None:
    """Return the V1 cap for a counter, or None if no cap applies."""
    return COUNTER_LIMITS.get(counter)


def packet_lowers_cap(counter: str, packet: dict | None) -> int | None:
    """If the packet lowers the cap for this counter, return the lower value.

    Returns None if no override applies or no packet provided.
    """
    if not packet:
        return None
    risk_budget = packet.get("risk_budget") or {}
    keymap = {
        "build_pass_count": "max_build_passes",
        "review_pass_count": "max_review_passes",
        "repair_round": "max_repair_rounds",
        "no_progress_streak": "max_consecutive_no_progress_passes",
    }
    override = risk_budget.get(keymap.get(counter, "")) if isinstance(risk_budget, dict) else None
    v1_cap = COUNTER_LIMITS.get(counter)
    if override is None:
        return v1_cap
    # The packet may lower the cap but MUST not raise the V1 maximum.
    if v1_cap is not None and int(override) > v1_cap:
        raise RepairLimitExceeded(
            f"packet attempts to raise V1 cap for {counter} to {override} > {v1_cap}"
        )
    return int(override)


def effective_cap(counter: str, packet: dict | None) -> int | None:
    """Return the smaller of the V1 cap and the packet's override."""
    v1_cap = cap_for(counter)
    pkt_cap = packet_lowers_cap(counter, packet)
    if v1_cap is None:
        return pkt_cap
    if pkt_cap is None:
        return v1_cap
    return min(v1_cap, pkt_cap)


def enforce(counter: str, current_value: int, packet: dict | None) -> int:
    """Refuse to let `current_value` exceed the effective cap.

    Returns the cap if enforcement passes (raises otherwise).
    """
    cap = effective_cap(counter, packet)
    if cap is None:
        return current_value
    if current_value >= cap:
        raise RepairLimitExceeded(
            f"counter {counter}={current_value} reached cap={cap}"
        )
    return cap
