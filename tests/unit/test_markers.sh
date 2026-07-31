#!/usr/bin/env bash
# Case 33: terminal loop-control marker.

set -uo pipefail
. "$(dirname "$0")/../_helpers.sh"

python3 - <<'PY'
import sys
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get("OFLOOP_LIB", "/path/to/ownframework-loop/lib"))
from ownframework_loop import scheduling

# Builder marker.
m = scheduling.builder_marker(run_id="r1", state="READY_TO_BUILD", action="RESCHEDULE", next_delay_minutes=0, reason="pass complete")
assert "OF_LOOP_OPERATOR_MARKER" in m
assert "OF_LOOP_RUN_ID=r1" in m
assert "OF_LOOP_ROLE=builder" in m
assert "OF_LOOP_STATE=READY_TO_BUILD" in m
assert "OF_LOOP_ACTION=RESCHEDULE" in m
print("  PASS: builder marker shape")

# Reviewer marker.
m = scheduling.reviewer_marker(run_id="r1", state="APPROVED", action="STOP", next_delay_minutes=0, reason="verdict")
assert "OF_LOOP_ROLE=reviewer" in m
assert "OF_LOOP_STATE=APPROVED" in m
assert "OF_LOOP_ACTION=STOP" in m
print("  PASS: reviewer marker shape")

# Decisions.
assert scheduling.recommend_next_delay_minutes(role="builder", state="BUILDING") == ("RESCHEDULE", 0)
assert scheduling.recommend_next_delay_minutes(role="builder", state="READY_FOR_REVIEW") == ("RESCHEDULE", 10)
assert scheduling.recommend_next_delay_minutes(role="builder", state="APPROVED") == ("STOP", 0)
assert scheduling.recommend_next_delay_minutes(role="builder", state="BLOCKED") == ("STOP", 0)
assert scheduling.recommend_next_delay_minutes(role="builder", state="STOPPED") == ("STOP", 0)
assert scheduling.recommend_next_delay_minutes(role="reviewer", state="READY_FOR_REVIEW") == ("RESCHEDULE", 0)
assert scheduling.recommend_next_delay_minutes(role="reviewer", state="BUILDING") == ("RESCHEDULE", 15)
assert scheduling.recommend_next_delay_minutes(role="reviewer", state="APPROVED") == ("STOP", 0)
print("  PASS: scheduling decisions for terminal and active states")

print("ALL PASS")
PY
