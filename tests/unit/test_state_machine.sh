#!/usr/bin/env bash
# Case 6: valid state transitions.
# Case 7: invalid transition refusal.

set -uo pipefail
. "$(dirname "$0")/../_helpers.sh"

python3 - <<'PY'
import sys
sys.path.insert(0, "/Users/mr.mrs.london/projects/plugins/ownframework-loop/lib")
from ownframework_loop import transitions

# Valid transitions
valid = [
    ("AWAITING_APPROVAL", "READY_TO_BUILD"),
    ("READY_TO_BUILD", "BUILDING"),
    ("BUILDING", "READY_FOR_REVIEW"),
    ("READY_FOR_REVIEW", "REVIEWING"),
    ("REVIEWING", "APPROVED"),
    ("REVIEWING", "CHANGES_REQUESTED"),
    ("REVIEWING", "BLOCKED"),
    ("REVIEWING", "STOPPED"),
    ("REVIEWING", "READY_FOR_REVIEW"),
    ("CHANGES_REQUESTED", "READY_TO_BUILD"),
]
for f, t in valid:
    assert transitions.is_valid(f, t), f"expected valid: {f} -> {t}"
    transitions.assert_valid(f, t)
print(f"  PASS: {len(valid)} valid transitions accepted")

# Invalid transitions
invalid = [
    ("APPROVED", "BUILDING"),
    ("STOPPED", "BUILDING"),
    ("BLOCKED", "BUILDING"),
    ("APPROVED", "CHANGES_REQUESTED"),
    ("AWAITING_APPROVAL", "BUILDING"),
    ("READY_TO_BUILD", "APPROVED"),
    ("BUILDING", "APPROVED"),
]
for f, t in invalid:
    assert not transitions.is_valid(f, t), f"expected invalid: {f} -> {t}"
    try:
        transitions.assert_valid(f, t)
    except transitions.InvalidTransitionError:
        pass
    else:
        raise AssertionError(f"did not raise for {f} -> {t}")
print(f"  PASS: {len(invalid)} invalid transitions rejected")

# Terminal states
assert transitions.is_terminal("APPROVED")
assert transitions.is_terminal("BLOCKED")
assert transitions.is_terminal("STOPPED")
assert not transitions.is_terminal("BUILDING")
print("  PASS: terminal states correctly classified")

print("ALL PASS")
PY
