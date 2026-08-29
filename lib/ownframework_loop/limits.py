"""Repair-limit constants and helpers — v0.3.7 plumbing-autonomy.

V1 caps are EMERGENCY CEILINGS, not floors. Packets control normal work
via `risk_budget.*` overrides and may freely raise or lower these values
within the absolute budget envelope defined by `util.ABSOLUTE_BUDGET_CEILING`.

The semantics are now:
  * V1 caps (MAX_* constants below): emergency runaway fuse. Pathological
    execution that exceeds V1 is presumed broken and is refused with
    RepairLimitExceeded. Operators / runbooks should still see the V1
    value as the conservative "ask for human help" signal.
  * Packet `risk_budget.*`: authoritative for the run. May raise up to
    the absolute ceiling. The packet is the operator's deliberate budget
    declaration, not a malicious input.
  * `util.ABSOLUTE_BUDGET_CEILING`: hard physical envelope. Past this
    requires packet-level elevation or a separate run.
"""


from __future__ import annotations


# Emergency V1 caps — generous defaults that sane runs never approach.
MAX_BUILD_PASSES = 32
MAX_REVIEW_PASSES = 32
MAX_REPAIR_ROUNDS = 32
MAX_CONSECUTIVE_NO_PROGRESS_PASSES = 16
MAX_IDENTICAL_FINDING_REPEATS = 8

# Counter names (used as keys in STATE.json).
COUNTER_LIMITS: dict[str, int] = {
    "build_pass_count": MAX_BUILD_PASSES,
    "review_pass_count": MAX_REVIEW_PASSES,
    "repair_round": MAX_REPAIR_ROUNDS,
    "no_progress_streak": MAX_CONSECUTIVE_NO_PROGRESS_PASSES,
}

# Map counter -> absolute-ceiling key in util.ABSOLUTE_BUDGET_CEILING.
# Importing util at module load would create a circular import; resolve
# the ceiling lazily inside the helpers.
_ABSOLUTE_KEYMAP = {
    "build_pass_count": "max_build_passes",
    "review_pass_count": "max_review_passes",
    "repair_round": "max_repair_rounds",
    "no_progress_streak": "max_consecutive_no_progress_passes",
}


class RepairLimitExceeded(RuntimeError):
    """Raised when a counter would exceed the absolute or V1 emergency cap.

    Caller should transition to BLOCKED or STOPPED and surface this as
    a durable event in EVENTS.log.
    """


def cap_for(counter: str) -> int | None:
    """Return the V1 (emergency) cap for a counter, or None if no cap applies."""
    return COUNTER_LIMITS.get(counter)


def _absolute_cap(counter: str) -> int | None:
    """Return the absolute envelope for the counter, or None.

    Imported lazily to avoid a circular import with util.
    """
    from . import util as _util
    key = _ABSOLUTE_KEYMAP.get(counter, "")
    if not key:
        return None
    return _util.ABSOLUTE_BUDGET_CEILING.get(key)


def packet_lowers_cap(counter: str, packet: dict | None) -> int | None:
    """Return the packet's declared cap for this counter, or None.

    v0.3.7 (F-3-01): the packet is the operator's budget declaration
    and may raise above the V1 emergency cap up to the absolute
    ceiling. The previous "must not raise V1" wording was the bug
    that prevented max_repair_rounds=6 / 12 / 25 from working.
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
    if override is None:
        return None
    absolute = _absolute_cap(counter)
    if absolute is not None and int(override) > int(absolute):
        raise RepairLimitExceeded(
            f"packet {counter} override={override} exceeds absolute ceiling {absolute}"
        )
    return int(override)


def effective_cap(counter: str, packet: dict | None) -> int | None:
    """Return the cap that actually applies to this counter for this run.

    Precedence (highest to lowest):
      1. packet.risk_budget.<key>            (operator declaration)
      2. util.ABSOLUTE_BUDGET_CEILING.<key>  (physical envelope)
      3. limits.MAX_*                        (emergency V1 fuse)
    """
    pkt_cap = packet_lowers_cap(counter, packet)
    if pkt_cap is not None:
        return pkt_cap
    absolute = _absolute_cap(counter)
    if absolute is not None:
        return absolute
    return cap_for(counter)


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
