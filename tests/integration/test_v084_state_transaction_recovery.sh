#!/usr/bin/env bash
# v0.8.4 durable STATE/EVENTS transaction + authoritative dispatch regression.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib"

TMP="$(mktemp -d -t ofloop_v084_state_txn.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

python3 -B - "$TMP" <<'PY'
import copy
import pathlib
import sys

from ownframework_loop import dispatch, integrity, state

# Standalone append_event and transaction-owned appends must both use atomic
# temp+replace rather than an in-place JSONL tail append.
state_source = pathlib.Path(state.__file__).read_text(encoding="utf-8")
assert 'open(ep, "a"' not in state_source, "non-atomic EVENTS.log append remains"

root = pathlib.Path(sys.argv[1])
repo = root / "repo"
repo.mkdir()
run_id = "run-txn"
rd = state.run_dir(repo, run_id)
rd.mkdir(parents=True)

# Establish a real state/event chain.
state.save(repo, run_id, state.initial_state(run_id))
assert state.load_verified(repo, run_id)["state"] == "AWAITING_APPROVAL"

# Diagnostic extras are never allowed to replace protocol identity/integrity
# fields or spoof the transaction recovery marker.
event_bytes = state.events_path(repo, run_id).read_bytes()
for reserved in ("run_id", "state_sha256", "event_chain_sha256", "state_txn_id"):
    try:
        state.append_event(
            repo,
            run_id,
            event_type="reserved-extra-probe",
            old_state=None,
            new_state=None,
            actor="test",
            extras={reserved: "spoofed"},
        )
    except ValueError as exc:
        assert "authoritative fields" in str(exc), exc
    else:
        raise AssertionError(f"reserved event extra accepted: {reserved}")
assert state.events_path(repo, run_id).read_bytes() == event_bytes

# 1) Crash after STATE replacement but before event append.
real_append = state._append_event_locked
def crash_before_event(*args, **kwargs):
    raise RuntimeError("synthetic crash after state write")
state._append_event_locked = crash_before_event
try:
    try:
        state.transition(
            repo, run_id,
            to_state="READY_TO_BUILD",
            actor="txn-test",
            reason="crash-window-state-written",
        )
    except RuntimeError as exc:
        assert "synthetic crash" in str(exc)
    else:
        raise AssertionError("synthetic state/event crash did not fire")
finally:
    state._append_event_locked = real_append

assert state.state_txn_path(repo, run_id).is_file()
ok, _ = integrity.verify_state_sha(state.state_path(repo, run_id), state.events_path(repo, run_id))
assert ok is False, "torn state/event pair should be observable before recovery"
healed = state.load_verified(repo, run_id)
assert healed["state"] == "READY_TO_BUILD", healed
assert not state.state_txn_path(repo, run_id).exists()
ok, reason = integrity.verify_state_sha(state.state_path(repo, run_id), state.events_path(repo, run_id))
assert ok, reason

# 2) Crash after write-ahead journal, before STATE replacement. Recovery
# deterministically completes the journaled transition.
real_atomic = state.atomic_write_json
state_target = state.state_path(repo, run_id).resolve()
def crash_before_state(path, payload, *args, **kwargs):
    if pathlib.Path(path).resolve() == state_target and state.state_txn_path(repo, run_id).exists():
        raise RuntimeError("synthetic crash after journal")
    return real_atomic(path, payload, *args, **kwargs)
state.atomic_write_json = crash_before_state
try:
    try:
        state.transition(
            repo, run_id,
            to_state="BUILDING",
            actor="txn-test",
            reason="crash-window-journal-only",
        )
    except RuntimeError as exc:
        assert "synthetic crash after journal" in str(exc)
    else:
        raise AssertionError("journal-only crash did not fire")
finally:
    state.atomic_write_json = real_atomic

assert state.state_txn_path(repo, run_id).is_file()
assert state.load(repo, run_id)["state"] == "READY_TO_BUILD"
healed2 = state.load_verified(repo, run_id)
assert healed2["state"] == "BUILDING", healed2
assert not state.state_txn_path(repo, run_id).exists()

# 3) Crash after both state + event are durable but before journal cleanup.
real_clear = state._clear_state_txn_locked
def crash_before_clear(*args, **kwargs):
    raise RuntimeError("synthetic crash before journal cleanup")
state._clear_state_txn_locked = crash_before_clear
try:
    try:
        state.transition(
            repo, run_id,
            to_state="READY_FOR_REVIEW",
            actor="txn-test",
            reason="crash-window-event-written",
        )
    except RuntimeError as exc:
        assert "synthetic crash before journal cleanup" in str(exc)
    else:
        raise AssertionError("post-event cleanup crash did not fire")
finally:
    state._clear_state_txn_locked = real_clear

assert state.state_txn_path(repo, run_id).is_file()
healed3 = state.load_verified(repo, run_id)
assert healed3["state"] == "READY_FOR_REVIEW", healed3
assert not state.state_txn_path(repo, run_id).exists()
events = integrity.read_event_chain(state.events_path(repo, run_id))
txn_events = [e for e in events if e.get("state_txn_id")]
assert len({e["state_txn_id"] for e in txn_events}) == len(txn_events), txn_events

# 4) Arbitrary state tampering with NO journal is still refused.
clean = copy.deepcopy(healed3)
tampered = copy.deepcopy(clean)
tampered["state"] = "APPROVED"
real_atomic(state.state_path(repo, run_id), tampered, mode=0o600)
try:
    state.load_verified(repo, run_id)
except integrity.TamperingDetected:
    pass
else:
    raise AssertionError("un-journaled STATE tampering was accepted")

# Restore exact clean state only for the independent dispatch probe.
real_atomic(state.state_path(repo, run_id), clean, mode=0o600)
assert state.load_verified(repo, run_id)["state"] == "READY_FOR_REVIEW"

# 5) Dispatch's claim-error terminal fallback must never trust raw STATE bytes.
run2 = "run-dispatch-integrity"
(state.run_dir(repo, run2)).mkdir(parents=True)
state.save(repo, run2, state.initial_state(run2))
raw = state.load(repo, run2)
raw["state"] = "APPROVED"
real_atomic(state.state_path(repo, run2), raw, mode=0o600)

real_run_cli = dispatch._run_cli
dispatch._run_cli = lambda *a, **k: (_ for _ in ()).throw(dispatch.DispatchError("synthetic claim failure"))
try:
    try:
        dispatch._claim_or_terminal(["noop"], repo=repo, run_id=run2)
    except integrity.TamperingDetected:
        pass
    else:
        raise AssertionError("dispatch terminalized from unverified tampered STATE")
finally:
    dispatch._run_cli = real_run_cli

print("V084_STATE_TRANSACTION_RECOVERY=PASS")
PY

pass "write-ahead state/event recovery and verified dispatch authority"
echo "V084_STATE_TRANSACTION_RECOVERY=PASS"
