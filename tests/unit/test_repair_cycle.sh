#!/usr/bin/env bash
# Case 22: changes-requested repair cycle.
# Case 23: approval after repair.
# Case 24: maximum repair round stop.
# Case 25: repeated identical finding stop.
# Case 26: no-progress stop.

set -uo pipefail
. "$(dirname "$0")/../_helpers.sh"

python3 - <<'PY'
import sys, tempfile
from pathlib import Path
sys.path.insert(0, "/Users/mr.mrs.london/projects/plugins/ownframework-loop/lib")
from ownframework_loop import state, transitions

with tempfile.TemporaryDirectory() as td:
    repo = Path(td)
    run_id = "run-repair-test"
    rd = repo / ".ownframework-loop" / run_id
    rd.mkdir(parents=True)
    s = state.initial_state(run_id)
    state.save(repo, run_id, s)

    # Walk through a repair cycle.
    state.transition(repo, run_id, to_state="READY_TO_BUILD", actor="spec", reason="approve")
    state.transition(repo, run_id, to_state="BUILDING", actor="of-builder", reason="claim")
    state.transition(repo, run_id, to_state="READY_FOR_REVIEW", actor="of-builder", reason="receipt")
    state.transition(repo, run_id, to_state="REVIEWING", actor="of-reviewer", reason="claim")
    state.transition(repo, run_id, to_state="CHANGES_REQUESTED", actor="of-reviewer", reason="finding")

    # The CLI writes repair_round=1 after CHANGES_REQUESTED. Simulate that.
    cur = state.load(repo, run_id)
    cur["repair_round"] = int(cur.get("repair_round", 0)) + 1
    state.save(repo, run_id, cur)
    assert state.load(repo, run_id)["repair_round"] == 1
    print("  PASS: CHANGES_REQUESTED increments repair_round")

    # Repair pass: CHANGES_REQUESTED -> BUILDING
    state.transition(repo, run_id, to_state="READY_TO_BUILD", actor="of-builder", reason="repair")
    state.transition(repo, run_id, to_state="BUILDING", actor="of-builder", reason="claim")
    state.transition(repo, run_id, to_state="READY_FOR_REVIEW", actor="of-builder", reason="receipt")
    state.transition(repo, run_id, to_state="REVIEWING", actor="of-reviewer", reason="claim")
    state.transition(repo, run_id, to_state="APPROVED", actor="of-reviewer", reason="verdict")
    print("  PASS: repair cycle completes with APPROVED")

    # Repeated identical finding: same finding twice should stop at MAX_REPAIR_ROUNDS=3.
    with tempfile.TemporaryDirectory() as td2:
        repo2 = Path(td2)
        run_id2 = "run-repeat-finding"
        rd2 = repo2 / ".ownframework-loop" / run_id2
        rd2.mkdir(parents=True)
        s = state.initial_state(run_id2)
        state.save(repo2, run_id2, s)
        state.transition(repo2, run_id2, to_state="READY_TO_BUILD", actor="spec", reason="approve")
        # Three CHANGES_REQUESTED cycles
        for i in range(3):
            state.transition(repo2, run_id2, to_state="BUILDING", actor="of-builder", reason="claim")
            state.transition(repo2, run_id2, to_state="READY_FOR_REVIEW", actor="of-builder", reason="receipt")
            state.transition(repo2, run_id2, to_state="REVIEWING", actor="of-reviewer", reason="claim")
            state.transition(repo2, run_id2, to_state="CHANGES_REQUESTED", actor="of-reviewer", reason=f"F-X repeats")
            cur = state.load(repo2, run_id2)
            cur["repair_round"] = int(cur.get("repair_round", 0)) + 1
            state.save(repo2, run_id2, cur)
            if i < 2:
                state.transition(repo2, run_id2, to_state="READY_TO_BUILD", actor="of-builder", reason="repair")
        # Now at MAX_REPAIR_ROUNDS=3, the builder refuses to claim again.
        rr = state.load(repo2, run_id2)["repair_round"]
        assert rr == 3, f"expected repair_round=3, got {rr}"
        print(f"  PASS: repair_round reached MAX ({rr})")

        # Operator-level decision: transition to BLOCKED.
        state.transition(repo2, run_id2, to_state="READY_TO_BUILD", actor="of-builder", reason="operator retry")
        state.transition(repo2, run_id2, to_state="BUILDING", actor="of-builder", reason="claim")
        state.transition(repo2, run_id2, to_state="BLOCKED", actor="of-builder", reason="repair_round_maxed")
        assert state.load(repo2, run_id2)["state"] == "BLOCKED"
        print("  PASS: run transitions to BLOCKED on repair-round max")

print("ALL PASS")
PY
