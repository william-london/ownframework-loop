#!/usr/bin/env bash
# Case 8: concurrent state updates serialize correctly.
# Atomic write + flock test.

set -uo pipefail
. "$(dirname "$0")/../_helpers.sh"

python3 - <<'PY'
import sys, os, tempfile, threading, time
from pathlib import Path
sys.path.insert(0, "/Users/mr.mrs.london/projects/plugins/ownframework-loop/lib")
from ownframework_loop import locking, state, transitions, util

with tempfile.TemporaryDirectory() as td:
    run_id = "run-atomic-test"
    rd = Path(td) / ".ownframework-loop" / run_id
    rd.mkdir(parents=True)
    initial = state.initial_state(run_id)
    state.save(Path(td), run_id, initial)
    print("  PASS: initial state saved")

    # Concurrent transitions: only the valid ones win.
    results = []
    def worker():
        try:
            state.transition(Path(td), run_id, to_state="READY_TO_BUILD", actor="t", reason="r")
            results.append("READY_TO_BUILD")
        except transitions.InvalidTransitionError:
            results.append("rejected")

    threads = [threading.Thread(target=worker) for _ in range(5)]
    for t in threads: t.start()
    for t in threads: t.join()

    # Exactly one transition should succeed; the others must be rejected.
    successes = results.count("READY_TO_BUILD")
    assert successes == 1, f"expected exactly 1 success, got {successes}: {results}"
    print(f"  PASS: concurrent transitions serialized ({successes} success, {5-successes} rejected)")

    # Verify EVENTS.log has exactly one state_transition entry.
    events = (rd / "EVENTS.log").read_text().strip().splitlines()
    transition_events = [e for e in events if '"event_type":"state_transition"' in e]
    assert len(transition_events) == 1, f"expected 1 transition event, got {len(transition_events)}"
    print(f"  PASS: EVENTS.log has exactly 1 transition entry")

print("ALL PASS")
PY
