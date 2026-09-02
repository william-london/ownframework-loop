#!/usr/bin/env bash
# Runtime/concurrency/recovery lane regressions.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib"

python3 -B - "$ROOT_DIR" <<'PY'
import json
import os
import signal
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from ownframework_loop import state
from ownframework_loop import supervisor

root = Path(sys.argv[1])
# Crash-state seeding is a TEST-ONLY seam: production save() is creation-only.
sys.path.insert(0, str(root / "tests" / "helpers"))
from state_seed import seed_state

tmp = Path(tempfile.mkdtemp(prefix="ofloop-runtime-recovery-"))

def new_repo(name: str) -> Path:
    p = tmp / name
    p.mkdir(parents=True, exist_ok=True)
    return p

# ------------------------------------------------------------------
# A-01: real child is born behind the release gate.  Kill the parent
# while on_start is blocked BEFORE durable publication can return.
# The provider sentinel must remain untouched.
# ------------------------------------------------------------------
repo = new_repo("gate")
worktree = repo / "wt"
worktree.mkdir()
run_id = "run-gate"
sem = repo / ".ownframework-loop" / run_id / "scratch" / "builder" / "pass-0001" / "BUILD_AGENT_RESULT.json"
sem.parent.mkdir(parents=True)
fake = tmp / "fake-claude"
sentinel = tmp / "model-sentinel"
fake.write_text(
    "#!/bin/sh\n"
    "if [ \"${1:-}\" = \"--version\" ]; then printf '%s\\n' '2.1.252 (Claude Code)'; exit 0; fi\n"
    "printf x >> \"$MODEL_SENTINEL\"\n"
    "printf '%s\\n' '{\"is_error\":false,\"total_cost_usd\":0,\"result\":\"ok\",\"usage\":{\"input_tokens\":0,\"output_tokens\":0}}'\n",
    encoding="utf-8",
)
fake.chmod(0o755)
pid_fifo = tmp / "spawned.fifo"
hold_fifo = tmp / "hold.fifo"
os.mkfifo(pid_fifo)
os.mkfifo(hold_fifo)

work_order = {
    "decision": "BUILD",
    "role": "builder",
    "run_id": run_id,
    "canonical_repo": str(repo),
    "worktree": str(worktree),
    "semantic_path": str(sem),
    "network_read_allowlist": [],
    "attempt_id": "attempt-gate-recovery",
}
child_code = r'''
import json, os, sys
from pathlib import Path
from ownframework_loop import supervisor
wo=json.loads(sys.argv[1])
pid_fifo=sys.argv[2]
hold_fifo=sys.argv[3]
def on_start(pid, role):
    with open(pid_fifo, "w", encoding="utf-8") as f:
        f.write(str(pid))
        f.flush()
    with open(hold_fifo, "r", encoding="utf-8") as f:
        f.read(1)
supervisor.ClaudeCodeRunner().run(
    wo,
    timeout_seconds=30,
    on_start=on_start,
)
'''
env = os.environ.copy()
env["OFLOOP_CLAUDE_BIN"] = str(fake)
env["MODEL_SENTINEL"] = str(sentinel)
parent = subprocess.Popen(
    [sys.executable, "-B", "-c", child_code, json.dumps(work_order), str(pid_fifo), str(hold_fifo)],
    env=env,
)
with open(pid_fifo, "r", encoding="utf-8") as f:
    gated_pid = int(f.read())
os.kill(parent.pid, signal.SIGKILL)
parent.wait(timeout=10)

deadline = time.monotonic() + 5
while time.monotonic() < deadline:
    try:
        os.kill(gated_pid, 0)
    except ProcessLookupError:
        break
    time.sleep(0.02)
else:
    raise AssertionError(f"unreleased gate child remained alive pid={gated_pid}")
assert not sentinel.exists(), "post-spawn/pre-publication child reached provider sentinel"

# A replacement execution releases exactly one provider process.
os.environ["OFLOOP_CLAUDE_BIN"] = str(fake)
os.environ["MODEL_SENTINEL"] = str(sentinel)
result = supervisor.ClaudeCodeRunner().run(
    work_order,
    timeout_seconds=30,
    on_start=lambda pid, role: None,
)
assert sentinel.read_text(encoding="utf-8") == "x", sentinel.read_text()
print("A01_FIRST_CHILD_REACHED_MODEL_SENTINEL=no")
print("A01_REPLACEMENT_WORKER_COUNT=1")
print("A01_DUPLICATE_SEMANTIC_EXECUTION=0")

# The same gate provenance is durable in SQLite. An unpublished gate-v1
# reservation is known zero-execution; a legacy pre-gate reservation is NOT.
db_gate = tmp / "gate-ledger.sqlite3"
repo_gate = new_repo("gate-ledger")
supervisor.enqueue(canonical_repo=repo_gate, run_id="run-gate-ledger", db_path=db_gate)
with supervisor._connect(db_gate) as conn:
    conn.execute(
        "UPDATE jobs SET status='RUNNING', worker_pid=99999999, worker_started_at=1 "
        "WHERE run_id='run-gate-ledger'"
    )
    conn.commit()
    job_gate = conn.execute(
        "SELECT * FROM jobs WHERE run_id='run-gate-ledger'"
    ).fetchone()
    gate_attempt, _ = supervisor._reserve_semantic_attempt(
        conn, job=job_gate, role="builder"
    )
    supervisor._recover_stale_running(conn)
with supervisor._connect_readonly(db_gate) as conn:
    gated_row = conn.execute(
        "SELECT * FROM semantic_attempts WHERE attempt_id=?", (gate_attempt,)
    ).fetchone()
assert int(gated_row["launch_gate_version"]) == 1, dict(gated_row)
assert gated_row["status"] == "FAILED", dict(gated_row)
assert gated_row["failure_reason"] == "worker_ownership_not_published", dict(gated_row)
assert int(gated_row["cost_known"]) == 1 and float(gated_row["cost_usd"]) == 0.0

db_legacy = tmp / "legacy-reservation.sqlite3"
repo_legacy = new_repo("legacy-reservation")
supervisor.enqueue(canonical_repo=repo_legacy, run_id="run-legacy-reserved", db_path=db_legacy)
with supervisor._connect(db_legacy) as conn:
    conn.execute(
        "UPDATE jobs SET status='RUNNING', worker_pid=99999998, worker_started_at=1 "
        "WHERE run_id='run-legacy-reserved'"
    )
    conn.commit()
    legacy_job = conn.execute(
        "SELECT * FROM jobs WHERE run_id='run-legacy-reserved'"
    ).fetchone()
    legacy_attempt, _ = supervisor._reserve_semantic_attempt(
        conn, job=legacy_job, role="builder"
    )
    conn.execute(
        "UPDATE semantic_attempts SET launch_gate_version=0 WHERE attempt_id=?",
        (legacy_attempt,),
    )
    conn.commit()
    supervisor._recover_stale_running(conn)
with supervisor._connect_readonly(db_legacy) as conn:
    legacy_row = conn.execute(
        "SELECT * FROM semantic_attempts WHERE attempt_id=?", (legacy_attempt,)
    ).fetchone()
assert int(legacy_row["launch_gate_version"]) == 0, dict(legacy_row)
assert legacy_row["status"] == "COST_UNKNOWN", dict(legacy_row)
assert int(legacy_row["cost_known"]) == 0, dict(legacy_row)
print("A01_GATED_RESERVATION_RECOVERY_KNOWN_ZERO=yes")
print("A01_LEGACY_RESERVATION_REMAINS_AMBIGUOUS=yes")

# ------------------------------------------------------------------
# A-02 + A-06: replacement recovery enforces the ORIGINAL persisted
# deadline on a real orphan, then preserves unknown cost as unknown.
# ------------------------------------------------------------------
db = tmp / "orphan.sqlite3"
repo2 = new_repo("orphan")
supervisor.enqueue(canonical_repo=repo2, run_id="run-orphan", db_path=db)
with supervisor._connect(db) as conn:
    conn.execute("UPDATE jobs SET status='RUNNING' WHERE run_id='run-orphan'")
    conn.commit()
    job = conn.execute("SELECT * FROM jobs WHERE run_id='run-orphan'").fetchone()
    attempt_id, logs = supervisor._reserve_semantic_attempt(conn, job=job, role="builder")

# Spawn through a short-lived parent so the long-running worker is truly orphaned.
orphan_pid = int(subprocess.check_output(
    [
        sys.executable, "-B", "-c",
        "import subprocess; p=subprocess.Popen(['/bin/sleep','30'], start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); print(p.pid, flush=True)",
    ],
    text=True,
).strip())
with supervisor._connect(db) as conn:
    supervisor._set_worker_pid(
        conn,
        int(job["id"]),
        orphan_pid,
        "builder",
        out_path=logs[0],
        err_path=logs[1],
        attempt_id=attempt_id,
        deadline_at=time.time() - 1,
    )
    recovered = supervisor._recover_stale_running(conn)
assert recovered == 1, recovered
with supervisor._connect_readonly(db) as conn:
    j = conn.execute("SELECT * FROM jobs WHERE run_id='run-orphan'").fetchone()
    a = conn.execute("SELECT * FROM semantic_attempts WHERE attempt_id=?", (attempt_id,)).fetchone()
assert j["status"] == "QUEUED", dict(j)
assert j["worker_pid"] is None and j["worker_deadline_at"] is None, dict(j)
assert a["status"] == "COST_UNKNOWN", dict(a)
assert int(a["cost_known"]) == 0, dict(a)
assert not supervisor._pid_alive(orphan_pid, None), "expired orphan still alive"
print("A02_TIMEOUT_SURVIVES_RESTART=yes")
print("A06_UNKNOWN_COST_REMAINS_UNKNOWN=yes")

# PID reuse safety: a matching PID/PGID with the wrong durable start identity
# must never be signalled by replacement recovery.
identity_probe = subprocess.Popen(["/bin/sleep", "30"], start_new_session=True)
try:
    actual_identity = supervisor._read_pid_start_identity(identity_probe.pid)
    assert actual_identity, "supported platform failed to expose process start identity"
    refused = supervisor._terminate_owned_process_group(
        identity_probe.pid,
        identity_probe.pid,
        str(actual_identity) + "-wrong",
        time.time(),
    )
    assert refused is False
    assert supervisor._pid_alive(identity_probe.pid, None), "identity mismatch killed unrelated process"
finally:
    try:
        os.killpg(identity_probe.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    identity_probe.wait(timeout=10)
print("A02_PID_REUSE_SAFE_KILL_PROOF=yes")

# A later finite ceiling must fail closed on the historical uncertainty.
with supervisor._connect(db) as conn:
    conn.execute(
        "UPDATE jobs SET runner='lane-ready', max_total_cost_usd=5, status='QUEUED', next_attempt_at=0 WHERE run_id='run-orphan'"
    )
    conn.commit()

@supervisor.register_runner
class LaneReady:
    runner_id = "lane-ready"
    def preflight(self):
        return supervisor.RunnerReadiness(True)
    def run(self, *args, **kwargs):
        raise AssertionError("runner must not execute with historical unknown cost")

real_claim = supervisor.dispatch_mod.claim_next
real_ready = supervisor.dispatch_mod.semantic_result_ready
supervisor.dispatch_mod.claim_next = lambda **kwargs: {
    "decision": "BUILD", "role": "builder", "canonical_repo": str(repo2),
    "run_id": "run-orphan", "worktree": str(repo2), "semantic_path": str(repo2 / "x"),
}
supervisor.dispatch_mod.semantic_result_ready = lambda wo: (False, "missing")
try:
    unknown_out = supervisor.run_one(db_path=db)
finally:
    supervisor.dispatch_mod.claim_next = real_claim
    supervisor.dispatch_mod.semantic_result_ready = real_ready
assert unknown_out["action"] == "QUARANTINED", unknown_out
assert unknown_out["reason"] == "historical_cost_unknown", unknown_out
print("A06_LATER_FINITE_CEILING_REFUSES_KNOWN_ZERO_LIE=yes")

# Active finite-ceiling crash recovery must persist cost uncertainty too.
db6c = tmp / "unknown-active-cap.sqlite3"
repo6c = new_repo("unknown-active-cap")
supervisor.enqueue(
    canonical_repo=repo6c, run_id="run-unknown-cap", db_path=db6c,
    max_total_cost_usd=5,
)
with supervisor._connect(db6c) as conn:
    conn.execute(
        "UPDATE jobs SET status='RUNNING', worker_pid=99999999, "
        "worker_started_at=1, worker_pgid=99999999, worker_deadline_at=1 "
        "WHERE run_id='run-unknown-cap'"
    )
    conn.commit()
    job6c = conn.execute(
        "SELECT * FROM jobs WHERE run_id='run-unknown-cap'"
    ).fetchone()
    attempt6c, _ = supervisor._reserve_semantic_attempt(
        conn, job=job6c, role="builder"
    )
    conn.execute(
        "UPDATE semantic_attempts SET status='RUNNING', worker_pid=99999999, "
        "worker_pgid=99999999, deadline_at=1 WHERE attempt_id=?",
        (attempt6c,),
    )
    conn.commit()
    assert supervisor._recover_stale_running(conn) == 0
with supervisor._connect_readonly(db6c) as conn:
    j6c = conn.execute(
        "SELECT * FROM jobs WHERE run_id='run-unknown-cap'"
    ).fetchone()
    a6c = conn.execute(
        "SELECT * FROM semantic_attempts WHERE attempt_id=?", (attempt6c,)
    ).fetchone()
    unknown6c = supervisor._unknown_cost_attempt_count(conn, int(j6c["id"]))
assert j6c["status"] == "QUARANTINED", dict(j6c)
assert a6c["status"] == "COST_UNKNOWN", dict(a6c)
assert int(a6c["cost_known"]) == 0 and int(a6c["cost_accounted"]) == 1, dict(a6c)
assert unknown6c == 1
print("A06_ACTIVE_CAP_CRASH_RECOVERY_PRESERVES_UNKNOWN=yes")

# ------------------------------------------------------------------
# A-08: a real Popen failure after durable reservation is terminalized.
# ------------------------------------------------------------------
db8 = tmp / "launch.sqlite3"
repo8 = new_repo("launch")

@supervisor.register_runner
class LaneLaunchFail:
    runner_id = "lane-launch-fail"
    def preflight(self):
        return supervisor.RunnerReadiness(True)
    def run(self, *args, **kwargs):
        try:
            subprocess.Popen([str(tmp / "definitely-missing-executable")])
        except OSError as exc:
            raise supervisor.WorkerLaunchError("synthetic real Popen failure") from exc
        raise AssertionError("missing executable unexpectedly launched")

enrolled8 = supervisor.enqueue(
    canonical_repo=repo8, run_id="run-launch", db_path=db8, runner="lane-launch-fail"
)
assert enrolled8["ok"] is True and enrolled8["runner"] == "lane-launch-fail", enrolled8

real_claim = supervisor.dispatch_mod.claim_next
real_ready = supervisor.dispatch_mod.semantic_result_ready
real_parse = supervisor.packet_mod.parse_packet_file
supervisor.dispatch_mod.claim_next = lambda **kwargs: {
    "decision": "BUILD", "role": "builder", "canonical_repo": str(repo8),
    "run_id": "run-launch", "worktree": str(repo8), "semantic_path": str(repo8 / "result.json"),
}
supervisor.dispatch_mod.semantic_result_ready = lambda wo: (False, "missing")
supervisor.packet_mod.parse_packet_file = lambda path: ({}, "")
try:
    launch_out = supervisor.run_one(db_path=db8)
finally:
    supervisor.dispatch_mod.claim_next = real_claim
    supervisor.dispatch_mod.semantic_result_ready = real_ready
    supervisor.packet_mod.parse_packet_file = real_parse
assert launch_out["action"] == "QUARANTINED", launch_out
with supervisor._connect_readonly(db8) as conn:
    attempts = conn.execute("SELECT * FROM semantic_attempts ORDER BY started_at").fetchall()
assert len(attempts) == 1
assert attempts[0]["status"] == "FAILED", dict(attempts[0])
assert attempts[0]["failure_reason"] == "worker_launch_failed", dict(attempts[0])
assert int(attempts[0]["cost_accounted"]) == 1
print("A08_RESERVED_ATTEMPT_TERMINAL=yes")

# PID publication may succeed while the release write itself fails. The gated
# child still cannot have executed the provider, so the RUNNING attempt must
# terminalize as a known-zero launch failure.
db8b = tmp / "release-fail.sqlite3"
repo8b = new_repo("release-fail")
supervisor.enqueue(
    canonical_repo=repo8b, run_id="run-release-fail", db_path=db8b,
)
with supervisor._connect(db8b) as conn:
    conn.execute("UPDATE jobs SET status='RUNNING' WHERE run_id='run-release-fail'")
    conn.commit()
    j8b = conn.execute(
        "SELECT * FROM jobs WHERE run_id='run-release-fail'"
    ).fetchone()
    a8b, _ = supervisor._reserve_semantic_attempt(conn, job=j8b, role="builder")
    conn.execute(
        "UPDATE semantic_attempts SET status='RUNNING', worker_pid=12345 "
        "WHERE attempt_id=?", (a8b,)
    )
    conn.commit()
    supervisor._mark_attempt_launch_failed(
        conn, job_id=int(j8b["id"]), attempt_id=a8b,
        detail="synthetic gate release failure",
    )
with supervisor._connect_readonly(db8b) as conn:
    a8b_after = conn.execute(
        "SELECT * FROM semantic_attempts WHERE attempt_id=?", (a8b,)
    ).fetchone()
assert a8b_after["status"] == "FAILED", dict(a8b_after)
assert a8b_after["worker_pid"] is None, dict(a8b_after)
assert int(a8b_after["cost_known"]) == 1 and int(a8b_after["cost_accounted"]) == 1
print("A08_POST_PUBLICATION_PRE_RELEASE_TERMINAL=yes")

# ------------------------------------------------------------------
# A-04: stale resume snapshot loses to retire and cannot resurrect.
# ------------------------------------------------------------------
db4 = tmp / "resume-retire.sqlite3"
repo4 = new_repo("resume-retire")
supervisor.enqueue(
    canonical_repo=repo4, run_id="run-race", db_path=db4,
    runtime_generation="ofloop-old@test",
)
with supervisor._connect(db4) as conn:
    conn.execute(
        "UPDATE jobs SET status='QUARANTINED', worker_pid=99999999, worker_started_at=1 WHERE run_id='run-race'"
    )
    conn.commit()

entered = threading.Event()
release = threading.Event()
resume_result = {}
real_pid_alive = supervisor._pid_alive
def gated_pid_alive(pid, started):
    if threading.current_thread().name == "resume-thread":
        entered.set()
        assert release.wait(10)
        return False
    return False
supervisor._pid_alive = gated_pid_alive
def do_resume():
    resume_result.update(
        supervisor.resume(canonical_repo=repo4, run_id="run-race", db_path=db4)
    )
t = threading.Thread(target=do_resume, name="resume-thread")
t.start()
assert entered.wait(10)
retire_out = supervisor.retire(canonical_repo=repo4, run_id="run-race", db_path=db4)
assert retire_out["retired"] is True, retire_out
release.set()
t.join(10)
supervisor._pid_alive = real_pid_alive
assert not t.is_alive()
assert resume_result["resumed"] is False, resume_result
assert resume_result["reason"] == "resume_lost_quarantine_race", resume_result
with supervisor._connect_readonly(db4) as conn:
    final4 = conn.execute("SELECT * FROM jobs WHERE run_id='run-race'").fetchone()
assert final4["status"] == "RETIRED", dict(final4)
assert final4["runtime_generation"] == "ofloop-old@test", dict(final4)
print("A04_RETIRED_RESURRECTION_CLOSED=yes")

# ------------------------------------------------------------------
# A-05: enqueue authorization is serialized with claim mutation.
# ------------------------------------------------------------------
db5 = tmp / "enqueue-claim.sqlite3"
repo5 = new_repo("enqueue-claim")
supervisor.enqueue(
    canonical_repo=repo5, run_id="run-gen-race", db_path=db5,
    runtime_generation="ofloop-g1@test",
)
claim_conn = supervisor._connect(db5)
claim_conn.execute("BEGIN IMMEDIATE")
claim_conn.execute(
    "UPDATE jobs SET status='RUNNING' WHERE run_id='run-gen-race'"
)
started = threading.Event()
enqueue_result = {}
def do_enqueue():
    started.set()
    enqueue_result.update(supervisor.enqueue(
        canonical_repo=repo5,
        run_id="run-gen-race",
        db_path=db5,
        runtime_generation="ofloop-g2@test",
    ))
et = threading.Thread(target=do_enqueue)
et.start()
assert started.wait(5)
# Releasing the SQLite writer commits the live G1 claim. Enqueue's own
# BEGIN IMMEDIATE can only continue afterward and must observe RUNNING/G1.
claim_conn.commit()
claim_conn.close()
et.join(10)
assert not et.is_alive()
assert enqueue_result["ok"] is False, enqueue_result
assert enqueue_result["reason"] == "cannot_change_runtime_generation_while_running", enqueue_result
with supervisor._connect_readonly(db5) as conn:
    final5 = conn.execute("SELECT status,runtime_generation FROM jobs WHERE run_id='run-gen-race'").fetchone()
assert tuple(final5) == ("RUNNING", "ofloop-g1@test"), tuple(final5)
print("A05_GENERATION_CLAIM_RACE_CLOSED=yes")

# ------------------------------------------------------------------
# A-03: rejected review + repair entitlement survive a state/event crash
# as ONE recovered mutation; cap exhaustion exposes BLOCKED, never repair.
# ------------------------------------------------------------------
def reviewing_run(base: Path, rid: str):
    rd = base / ".ownframework-loop" / rid
    rd.mkdir(parents=True)
    state.save(base, rid, state.initial_state(rid))
    for target in ("READY_TO_BUILD", "BUILDING", "READY_FOR_REVIEW", "REVIEWING"):
        state.transition(base, rid, to_state=target, actor="test")
    return rd

repo3 = new_repo("repair-atomic")
reviewing_run(repo3, "run-repair-atomic")
packet = {"risk_budget": {"max_repair_rounds": 1}}
real_append = state._append_event_locked
def crash_after_state(*args, **kwargs):
    raise RuntimeError("synthetic crash after atomic repair state write")
state._append_event_locked = crash_after_state
try:
    try:
        state.transition_review_rejection_with_repair(
            repo3, "run-repair-atomic",
            packet=packet, actor="review-finalize",
            commit_sha="a" * 40,
        )
    except RuntimeError as exc:
        assert "synthetic crash" in str(exc)
    else:
        raise AssertionError("A03 crash injection did not fire")
finally:
    state._append_event_locked = real_append
healed3 = state.load_verified(repo3, "run-repair-atomic")
assert healed3["state"] == "CHANGES_REQUESTED", healed3
assert healed3["repair_round"] == 1, healed3

repo3b = new_repo("repair-cap")
reviewing_run(repo3b, "run-repair-cap")
cur = state.load_verified(repo3b, "run-repair-cap")
cur["repair_round"] = 1
seed_state(repo3b, "run-repair-cap", cur, reason="fixture repair-cap pre-fund")
cap_out = state.transition_review_rejection_with_repair(
    repo3b, "run-repair-cap",
    packet=packet, actor="review-finalize",
    commit_sha="b" * 40,
)
assert cap_out["state"] == "BLOCKED", cap_out
blocked3 = state.load_verified(repo3b, "run-repair-cap")
assert blocked3["state"] == "BLOCKED" and blocked3["repair_round"] == 1, blocked3
print("A03_REPAIR_ROUND_CHARGED_EXACTLY_ONCE=yes")
print("A03_AT_REPAIR_CEILING_BLOCKED_WITHOUT_MODEL_CALL=yes")

# ------------------------------------------------------------------
# A-09: finalizer-derived state + transition use the same STATE_TXN. Inject
# the exact post-state/pre-event crash and prove recovery keeps the one-pass
# derived values without a BUILDING replay surface.
# ------------------------------------------------------------------
repo9 = new_repo("build-replay")
rd9 = reviewing_run(repo9, "run-build-replay")
# Walk back via a fresh run to BUILDING for this proof.
repo9b = new_repo("build-replay-b")
rid9 = "run-build-replay"
rd = repo9b / ".ownframework-loop" / rid9
rd.mkdir(parents=True)
state.save(repo9b, rid9, state.initial_state(rid9))
state.transition(repo9b, rid9, to_state="READY_TO_BUILD", actor="test")
state.transition(repo9b, rid9, to_state="BUILDING", actor="test")
real_append = state._append_event_locked
state._append_event_locked = crash_after_state
try:
    try:
        state.transition(
            repo9b, rid9,
            to_state="READY_FOR_REVIEW",
            actor="build-finalize",
            commit_sha="c" * 40,
            no_progress_streak=0,
            build_pass_count=1,
        )
    except RuntimeError as exc:
        assert "synthetic crash" in str(exc)
    else:
        raise AssertionError("A09 crash injection did not fire")
finally:
    state._append_event_locked = real_append
healed9 = state.load_verified(repo9b, rid9)
assert healed9["state"] == "READY_FOR_REVIEW", healed9
assert healed9["no_progress_streak"] == 0, healed9
assert healed9["last_candidate_sha"] == "c" * 40, healed9
assert healed9["build_pass_count"] == 1, healed9
print("A09_BUILD_FINALIZER_REPLAY_IDEMPOTENT=yes")

print("RUNTIME_RECOVERY_LANE_FOCUSED=PASS")
PY

echo "RUNTIME_RECOVERY_LANE=PASS"
