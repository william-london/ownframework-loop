#!/usr/bin/env bash
# OwnFramework Loop — integrity (tampering detection) + repair-limit tests.
#
# - Case A: STATE.json direct edit is detected by SHA chain on next transition.
# - Case B: BUILD_RECEIPT.json direct edit is detected.
# - Case C: A clean transition appends an event with the recorded SHA.
# - Case D: increment_counter refuses to push past the V1 cap by default.
# - Case E: Packet override may lower the cap but not raise V1.
# - Case F: Reviewer self-refresh is classified controlled, not external.

set -uo pipefail
. "$(dirname "$0")/../_helpers.sh"

python3 - <<'PY'
import sys, tempfile, json
from pathlib import Path
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get("OFLOOP_LIB", "/path/to/ownframework-loop/lib"))
from ownframework_loop import state, integrity, limits, worktrees

# ----- Case A: STATE tampering detected -----
with tempfile.TemporaryDirectory() as td:
    repo = Path(td); run_id = "run-tamper-A"
    s = state.initial_state(run_id)
    state.save(repo, run_id, s)
    state.transition(repo, run_id, to_state="READY_TO_BUILD", actor="spec", reason="approve")
    # Direct edit of STATE.json (bypass CLI)
    sp = state.state_path(repo, run_id)
    raw = json.loads(sp.read_text())
    raw["state"] = "APPROVED"  # forgery
    sp.write_text(json.dumps(raw, indent=2, sort_keys=True))
    try:
        state.transition(repo, run_id, to_state="BUILDING", actor="of-builder", reason="claim")
        print("  FAIL: tamper not detected")
        sys.exit(1)
    except integrity.TamperingDetected as e:
        print(f"  PASS: tampering detected (A): {e}")

# ----- Case B: Receipt tampering detected -----
with tempfile.TemporaryDirectory() as td:
    repo = Path(td); run_id = "run-tamper-B"
    s = state.initial_state(run_id)
    state.save(repo, run_id, s)
    # Record a synthetic receipt event.
    rp = repo / ".ownframework-loop" / run_id / "BUILD_RECEIPT.json"
    rp.parent.mkdir(parents=True, exist_ok=True)
    rp.write_text(json.dumps({"schema": "ownframework-loop-build-receipt/v1", "candidate_sha": "abc123"}))
    state.append_event(repo, run_id,
        event_type="receipt_written",
        old_state=None, new_state=None,
        actor="of-builder",
        commit_sha="abc123",
        extras={"BUILD_RECEIPT.json_sha256": integrity.sha256_file(rp)})
    # Edit the receipt directly.
    rp.write_text(json.dumps({"schema": "ownframework-loop-build-receipt/v1", "candidate_sha": "deadbeef"}))
    ok, msg = integrity.verify_artifact_sha(rp, state.events_path(repo, run_id), "BUILD_RECEIPT.json")
    assert not ok, f"FAIL: receipt tamper not detected: {msg}"
    print(f"  PASS: receipt tampering detected (B): {msg}")

# ----- Case C: Clean transition appends event with state_sha256 -----
with tempfile.TemporaryDirectory() as td:
    repo = Path(td); run_id = "run-chain"
    s = state.initial_state(run_id)
    state.save(repo, run_id, s)
    state.transition(repo, run_id, to_state="READY_TO_BUILD", actor="spec", reason="approve")
    chain = integrity.read_event_chain(state.events_path(repo, run_id))
    last = chain[-1]
    assert "state_sha256" in last, "FAIL: state_sha256 not recorded"
    print("  PASS: state_sha256 recorded in EVENTS.log on transition (C)")

# ----- Case D: increment_counter refuses past V1 cap -----
with tempfile.TemporaryDirectory() as td:
    repo = Path(td); run_id = "run-cap-D"
    s = state.initial_state(run_id)
    state.save(repo, run_id, s)
    state.transition(repo, run_id, to_state="READY_TO_BUILD", actor="spec", reason="approve")
    # Push build_pass_count to cap (V1=8). Packet=None means default cap.
    for i in range(limits.MAX_BUILD_PASSES):
        state.increment_counter(repo, run_id, counter="build_pass_count",
                                actor="of-builder", packet=None)
    try:
        state.increment_counter(repo, run_id, counter="build_pass_count",
                                actor="of-builder", packet=None)
        print("  FAIL: counter did not refuse past cap")
        sys.exit(1)
    except limits.RepairLimitExceeded as e:
        print(f"  PASS: build_pass_count cap enforced (D): {e}")

# ----- Case E: Packet may lower the cap but not raise V1 max -----
with tempfile.TemporaryDirectory() as td:
    repo = Path(td); run_id = "run-pkt-E"
    s = state.initial_state(run_id)
    state.save(repo, run_id, s)
    state.transition(repo, run_id, to_state="READY_TO_BUILD", actor="spec", reason="approve")
    # A packet lowering to 2 should be enforced.
    pkt = {"risk_budget": {"max_build_passes": 2}}
    state.increment_counter(repo, run_id, counter="build_pass_count",
                            actor="of-builder", packet=pkt)
    state.increment_counter(repo, run_id, counter="build_pass_count",
                            actor="of-builder", packet=pkt)
    try:
        state.increment_counter(repo, run_id, counter="build_pass_count",
                                actor="of-builder", packet=pkt)
        print("  FAIL: packet override did not lower the cap")
        sys.exit(1)
    except limits.RepairLimitExceeded as e:
        print(f"  PASS: packet override lowers cap (E): {e}")

# A packet attempting to raise V1 max must be rejected.
try:
    bad_pkt = {"risk_budget": {"max_build_passes": 999}}
    limits.enforce("build_pass_count", 8, bad_pkt)
    print("  FAIL: packet raising V1 max not rejected")
    sys.exit(1)
except limits.RepairLimitExceeded as e:
    print(f"  PASS: packet cannot raise V1 max (E2): {e}")

# ----- Case F: Reviewer self-refresh classified controlled -----
class FakeWT:
    pass

# Use real diff_tracked_mutation.
# Scenario: before.head == old sha, after.head == NEW sha, expected_candidate_sha == new sha.
before = {"head": "old_sha_aaa", "ts": "t0", "stage": "start"}
after = {"head": "new_sha_bbb", "ts": "t1", "stage": "end"}
res = worktrees.diff_tracked_mutation(before, after, expected_candidate_sha="new_sha_bbb")
assert res["mutated"] is False, f"FAIL: controlled refresh misclassified: {res}"
assert res["kind"] == "controlled_refresh"
print("  PASS: controlled refresh is NOT a mutation (F1)")

# External drift: before.head is some unrelated sha, after.head is NEW.
before2 = {"head": "garbage_sha"}
after2 = {"head": "another_sha"}
res2 = worktrees.diff_tracked_mutation(before2, after2, expected_candidate_sha="expected_sha")
assert res2["mutated"] is True and res2["kind"] == "external_drift", f"FAIL: external drift misclassified: {res2}"
print("  PASS: external drift IS a mutation (F2)")

# No drift: same SHA on both sides.
same_before = {"head": "x"}
same_after = {"head": "x"}
res3 = worktrees.diff_tracked_mutation(same_before, same_after)
assert res3["mutated"] is False and res3["kind"] == "no_change"
print("  PASS: identical SHAs are no-change (F3)")

# Unexpected initial drift: before had no head, after has one.
none_before = {"head": None}
some_after = {"head": "abc"}
res4 = worktrees.diff_tracked_mutation(none_before, some_after)
assert res4["mutated"] is True and res4["kind"] == "unexpected_initial_drift", f"FAIL: {res4}"
print("  PASS: null-before is unexpected_initial_drift (F4)")

# ----- Case G: classify_mutation verdicts -----
# controlled_refresh -> controlled_refresh action
action = worktrees.diff_tracked_mutation(before, after, expected_candidate_sha="new_sha_bbb")
from ownframework_loop import verdicts
v = verdicts.classify_mutation(action)
assert v["action"] == "controlled_refresh", v
print("  PASS: classify_mutation maps controlled_refresh correctly (G1)")

action_ext = worktrees.diff_tracked_mutation(before2, after2, expected_candidate_sha="expected_sha")
v2 = verdicts.classify_mutation(action_ext)
assert v2["action"] == "external_drift_block", v2
print("  PASS: classify_mutation maps external_drift to BLOCK (G2)")

print("ALL PASS")
PY
