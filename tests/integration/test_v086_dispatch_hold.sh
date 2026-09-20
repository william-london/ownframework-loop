#!/usr/bin/env bash
# v0.8.6 — typed per-run dispatch hold and durable scheduler hand-off.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"
TMP="$(mktemp -d -t ofloop_dispatch_hold.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

TMP_ROOT="$TMP" ROOT_DIR="$ROOT_DIR" OFLOOP_BIN="$OFLOOP_BIN" \
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$(cd "$HERE/.." && pwd):$LIB_DIR" \
python3 -B - <<'PY'
import json, os, sqlite3, subprocess, sys, time
from pathlib import Path
from ownframework_loop import state as state_mod, supervisor
import sys as _sys_h
_sys_h.path.insert(0, str(Path(__file__).resolve().parents[2]))
from _test_support import write_minimal_valid_packet  # noqa: E402

tmp = Path(os.environ["TMP_ROOT"])
root = Path(os.environ["ROOT_DIR"])
setup = root / "tests/helpers/setup_program_run.py"
ofloop = Path(os.environ["OFLOOP_BIN"])
# Crash-state seeding is a TEST-ONLY seam: production save() can never change
# transition identity; the CP-1 -> CP-2 boundary is seeded as the durable
# state a real advancement crash would leave behind.
sys.path.insert(0, str(root / "tests" / "helpers"))
from state_seed import seed_state

def git(repo, *args):
    subprocess.run(["git", "-C", str(repo), *args], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def make_repo(name):
    p = tmp / name; p.mkdir()
    git(p, "init", "-q", "-b", "master")
    git(p, "config", "user.email", "test@localhost")
    git(p, "config", "user.name", "test")
    (p / "README.md").write_text("seed\n")
    git(p, "add", "README.md"); git(p, "commit", "-qm", "seed")
    return p

def make_program(repo, rid):
    # v0.9.1+: packet-global caps must fund n_cps + gp + 1 review
    # passes (CP reviews + repair reviews + mandatory final whole-
    # product review).  Use generous caps so the test exercises the
    # dispatch hold seam, not the budget-admission seam.
    subprocess.run(["python3", str(setup), str(repo), rid, "2", "30", "30", "20", "3", "3", "1"], check=True)

def make_boundary(repo, rid):
    doc = state_mod.load(repo, rid)
    doc["state"] = "READY_TO_BUILD"
    prog = doc["program"]
    prog["current_checkpoints"] = ["CP-2"]
    prog["finalized_checkpoints"] = [{"id": "CP-1", "terminal_state": "APPROVED"}]
    previous_cp = {x["id"]: x for x in prog["checkpoints"]}["CP-1"]
    previous_cp["terminal"] = "APPROVED"
    next_cp = {x["id"]: x for x in prog["checkpoints"]}["CP-2"]
    next_cp.update(build_pass_count=0, review_pass_count=0, repair_round_count=0)
    seed_state(repo, rid, doc)

def held_fixture(name, rid):
    repo = make_repo(name); make_program(repo, rid); make_boundary(repo, rid)
    db = tmp / f"{name}.sqlite3"
    job = supervisor.enqueue(
        canonical_repo=repo, run_id=rid, db_path=db, runtime_generation="test-generation",
        dispatch_hold_kind=supervisor.DISPATCH_HOLD_KIND,
        dispatch_hold_previous_checkpoint_id="CP-1",
        dispatch_hold_next_checkpoint_id="CP-2",
    )
    return repo, db, job, job["dispatch_hold"]

# H-02: injected failure after the operational job write rolls back the whole
# enrollment, so no eligible job can exist without its required hold.
rollback_repo = make_repo("rollback")
rollback_db = tmp / "rollback.sqlite3"
original_uuid4 = supervisor.uuid.uuid4
supervisor.uuid.uuid4 = lambda: (_ for _ in ()).throw(RuntimeError("injected hold failure"))
try:
    try:
        write_minimal_valid_packet(rollback_repo, 'run-rollback')
        supervisor.enqueue(canonical_repo=rollback_repo, run_id="run-rollback", db_path=rollback_db,
                           runtime_generation="test-generation",
                           dispatch_hold_kind=supervisor.DISPATCH_HOLD_KIND,
                           dispatch_hold_previous_checkpoint_id="CP-1",
                           dispatch_hold_next_checkpoint_id="CP-2")
    except RuntimeError as exc:
        assert "injected hold failure" in str(exc)
    else:
        raise AssertionError("hold injection unexpectedly succeeded")
finally:
    supervisor.uuid.uuid4 = original_uuid4
with supervisor._connect_readonly(rollback_db) as conn:
    assert conn.execute("select count(*) from jobs").fetchone()[0] == 0
    assert conn.execute("select count(*) from dispatch_holds").fetchone()[0] == 0
print("ATOMIC_JOB_AND_HOLD_ENROLLMENT=PASS")

# H-03/H-04/H-05/H-06/H-08/H-16/H-27/H-28.
repo, db, job, hold = held_fixture("held", "run-held")
# An ARMED hold at its exact engineering boundary is already a real claim
# barrier even before the scheduler atomically transitions it to HELD. Read-only
# status/fleet projections must report that truth rather than advertising the
# queued job as effectively schedulable and making a correct hold look hung.
armed_fleet = supervisor.fleet_status(db_path=db)
armed_item = next(x for x in armed_fleet["jobs"] if x["id"] == job["id"])
assert armed_item["dispatch_hold_claim_decision"] == "MATCH", armed_item
assert armed_item["dispatch_hold_blocked"] is True, armed_item
assert armed_item["effective_schedulability"] is False, armed_item
armed_status = supervisor.status(canonical_repo=repo, run_id="run-held", db_path=db)
assert armed_status["dispatch_hold_claim_decision"] == "MATCH", armed_status
assert armed_status["dispatch_hold_blocked"] is True, armed_status
print("ARMED_MATCH_PROJECTED_AS_BLOCKED=PASS")

with supervisor._connect(db) as conn:
    got = supervisor._take_next_job(conn)
    assert got is None
    jstate = conn.execute("select status from jobs where id=?", (job["id"],)).fetchone()[0]
    hstate = conn.execute("select state from dispatch_holds where hold_id=?", (hold["hold_id"],)).fetchone()[0]
    assert jstate == "QUEUED"
    assert hstate == "HELD"
    assert conn.execute("select count(*) from semantic_attempts where job_id=?", (job["id"],)).fetchone()[0] == 0
    assert "HELD" not in {row[1] for row in conn.execute("pragma table_info(jobs)")}
held_status = supervisor.status(canonical_repo=repo, run_id="run-held", db_path=db)
assert held_status["dispatch_hold_claim_decision"] == "HELD", held_status
assert held_status["dispatch_hold_blocked"] is True, held_status
released = supervisor.release_dispatch_hold(canonical_repo=repo, run_id="run-held", hold_id=hold["hold_id"], db_path=db)
assert released["state"] == "RELEASED"
assert supervisor.release_dispatch_hold(canonical_repo=repo, run_id="run-held", hold_id=hold["hold_id"], db_path=db)["idempotent"]
with supervisor._connect(db) as conn:
    claimed = supervisor._take_next_job(conn)
    assert claimed is not None and claimed["id"] == job["id"]
print("HELD_BEFORE_ATTEMPT_RESERVATION=PASS")
print("RELEASE_IDEMPOTENCE=PASS")
print("HOLD_HISTORY_PRESERVED=PASS")

# Malformed active hold metadata is a canonical fail-closed claim barrier. The
# read model and the actual claim path must agree without inventing new hold
# semantics.
malformed_repo, malformed_db, malformed_job, malformed_hold = held_fixture(
    "malformed", "run-malformed"
)
with supervisor._connect(malformed_db) as conn:
    conn.execute(
        "update dispatch_holds set kind='UNSUPPORTED_TEST_KIND' where hold_id=?",
        (malformed_hold["hold_id"],),
    )
    conn.commit()
malformed_fleet = supervisor.fleet_status(db_path=malformed_db)
malformed_item = next(x for x in malformed_fleet["jobs"] if x["id"] == malformed_job["id"])
assert malformed_item["dispatch_hold_claim_decision"] == "unsupported_hold_kind", malformed_item
assert malformed_item["dispatch_hold_blocked"] is True, malformed_item
assert malformed_item["effective_schedulability"] is False, malformed_item
with supervisor._connect(malformed_db) as conn:
    assert supervisor._take_next_job(conn) is None
    assert conn.execute(
        "select status from jobs where id=?", (malformed_job["id"],)
    ).fetchone()[0] == "QUEUED"
print("MALFORMED_ACTIVE_HOLD_FAILS_CLOSED=PASS")

# If live engineering-state identity cannot be read, the hold remains a claim
# barrier rather than degrading UNKNOWN into released/not-blocked.
unavailable_repo, unavailable_db, unavailable_job, unavailable_hold = held_fixture(
    "unavailable", "run-unavailable"
)
unavailable_state = state_mod.state_path(unavailable_repo, "run-unavailable")
unavailable_original = unavailable_state.read_bytes()
unavailable_state.write_text("{not-json", encoding="utf-8")
try:
    unavailable_fleet = supervisor.fleet_status(db_path=unavailable_db)
    unavailable_item = next(
        x for x in unavailable_fleet["jobs"] if x["id"] == unavailable_job["id"]
    )
    assert unavailable_item["dispatch_hold_claim_decision"].startswith(
        "engineering_state_unavailable"
    ), unavailable_item
    assert unavailable_item["dispatch_hold_blocked"] is True, unavailable_item
    assert unavailable_item["effective_schedulability"] is False, unavailable_item
    with supervisor._connect(unavailable_db) as conn:
        assert supervisor._take_next_job(conn) is None
        assert conn.execute(
            "select status from jobs where id=?", (unavailable_job["id"],)
        ).fetchone()[0] == "QUEUED"
finally:
    unavailable_state.write_bytes(unavailable_original)
print("ENGINEERING_STATE_UNAVAILABLE_FAILS_CLOSED=PASS")

# H-10/H-11/H-12/H-15: mismatch does not hold, and a held run is skipped so
# another queued run may use the operational slot.
mismatch = make_repo("mismatch"); make_program(mismatch, "run-mismatch")
mdb = tmp / "mismatch.sqlite3"
write_minimal_valid_packet(mismatch, 'run-mismatch')
mjob = supervisor.enqueue(canonical_repo=mismatch, run_id="run-mismatch", db_path=mdb, runtime_generation="test-generation",
                          dispatch_hold_kind=supervisor.DISPATCH_HOLD_KIND,
                          dispatch_hold_previous_checkpoint_id="CP-X", dispatch_hold_next_checkpoint_id="CP-Y")
mismatch_fleet = supervisor.fleet_status(db_path=mdb)
mismatch_item = next(x for x in mismatch_fleet["jobs"] if x["id"] == mjob["id"])
assert mismatch_item["dispatch_hold_claim_decision"] == "checkpoint_identity_not_found", mismatch_item
assert mismatch_item["dispatch_hold_blocked"] is False, mismatch_item
assert mismatch_item["effective_schedulability"] is True, mismatch_item
with supervisor._connect(mdb) as conn:
    got = supervisor._take_next_job(conn)
    assert got is not None and got["id"] == mjob["id"]
print("WRONG_CHECKPOINT_DOES_NOT_HOLD=PASS")
print("ARMED_MISMATCH_REMAINS_SCHEDULABLE=PASS")

# Legacy serial projection cannot know hold-specific blocking because the
# pre-v0.9 ledger has no dispatch_holds authority. Preserve UNKNOWN as null,
# while keeping effective schedulability conservatively false.
legacy_db = tmp / "legacy.sqlite3"
with sqlite3.connect(legacy_db) as legacy:
    legacy.execute(
        "create table jobs(id integer primary key, repo text, run_id text, status text)"
    )
    legacy.execute(
        "insert into jobs(repo,run_id,status) values(?,?,?)",
        (str(tmp / "legacy-repo"), "run-legacy", "QUEUED"),
    )
legacy_fleet = supervisor.fleet_status(db_path=legacy_db)
assert legacy_fleet["legacy_serial_projection"] is True, legacy_fleet
legacy_item = legacy_fleet["jobs"][0]
assert legacy_item["dispatch_hold_claim_decision"] == "legacy_projection_unavailable", legacy_item
assert legacy_item["dispatch_hold_blocked"] is None, legacy_item
assert legacy_item["effective_schedulability"] is False, legacy_item
print("LEGACY_HOLD_BLOCKED_REMAINS_UNKNOWN=PASS")

held2, db2, job2, hold2 = held_fixture("held2", "run-held2")
plain = make_repo("plain")
write_minimal_valid_packet(plain, 'run-plain')
plain_job = supervisor.enqueue(canonical_repo=plain, run_id="run-plain", db_path=db2, runtime_generation="test-generation")
with supervisor._connect(db2) as conn:
    assert supervisor._take_next_job(conn)["id"] == plain_job["id"]
print("RUN_ISOLATION=PASS")

# H-08/H-21: a replacement scheduler still honors HELD; cancelling is an
# explicit operation, never an implicit recovery from watcher loss.
repo3, db3, job3, hold3 = held_fixture("crash", "run-crash")
with supervisor._connect(db3) as conn:
    assert supervisor._take_next_job(conn) is None
with supervisor._connect(db3) as conn:
    assert supervisor._take_next_job(conn) is None
assert supervisor.cancel_dispatch_hold(canonical_repo=repo3, run_id="run-crash", hold_id=hold3["hold_id"], db_path=db3)["state"] == "CANCELLED"
print("REPLACEMENT_HONORS_HELD=PASS")
print("WATCHER_LOSS_DOES_NOT_AUTO_RELEASE=PASS")

# H-17/H-20/H-22/H-24: the watcher consumes the durable HELD state rather
# than racing the scheduler. The test manager is a safe fake service target;
# the public arm command's launcher exits before the hold is triggered.
watch_root = tmp / "watcher"
watch_repo = make_repo("watch-repo")
watch_id = "run-watch"
make_program(watch_repo, watch_id)
watch_db = tmp / "watch.sqlite3"
active = tmp / "service.active"; active.touch()
count = tmp / "restart.count"
restart = tmp / "restart.sh"
restart.write_text("#!/bin/sh\nn=0; test -f '" + str(count) + "' && n=$(cat '" + str(count) + "'); printf '%s\\n' $((n+1)) > '" + str(count) + "'\n")
restart.chmod(0o700)
provenance = tmp / "watch-provenance.json"
provenance.write_text(json.dumps({"runtime_generation": "test-generation"}) + "\n")
watch_root.mkdir()
control = {
    "schema": "ownframework-loop-commissioned-canary-control/v1",
    "status": "PREPARED", "canary_root": str(watch_root), "repo": str(watch_repo),
    "run_id": watch_id, "db": str(watch_db), "provenance": str(provenance),
    "ofloop_bin": str(ofloop), "service_manager": "test", "service_label": "fake-service",
    "runtime_generation_prepared": "test-generation", "test_restart_command": str(restart),
    "test_service_active_file": str(active),
}
(watch_root / "control.json").write_text(json.dumps(control, indent=2) + "\n")
env = os.environ.copy()
env.update({"OFLOOP_CANARY_TEST_MANAGER": "1", "OFLOOP_CANARY_TEST_SERVICE_ACTIVE_FILE": str(active),
           "OFLOOP_CANARY_RESTART_POLL_SECONDS": "0.01", "OFLOOP_CANARY_RESTART_WAIT_SECONDS": "30"})
harness = root / "tests/canary/commissioned_program_canary.sh"
armed = subprocess.run(["bash", str(harness), "arm-restart", str(watch_root)], env=env,
                       capture_output=True, text=True, check=True)
assert "WATCHER_DURABLE=yes" in armed.stdout, armed.stdout
watch_job = supervisor.enqueue(
    canonical_repo=watch_repo, run_id=watch_id, db_path=watch_db, runtime_generation="test-generation",
    dispatch_hold_kind=supervisor.DISPATCH_HOLD_KIND,
    dispatch_hold_previous_checkpoint_id="CP-1", dispatch_hold_next_checkpoint_id="CP-2",
)
control = json.loads((watch_root / "control.json").read_text())
control.update({"status": "STARTED", "dispatch_hold_id": watch_job["dispatch_hold"]["hold_id"],
                "dispatch_hold_kind": supervisor.DISPATCH_HOLD_KIND, "dispatch_hold_state": "ARMED"})
(watch_root / "control.json").write_text(json.dumps(control, indent=2) + "\n")
make_boundary(watch_repo, watch_id)
with supervisor._connect(watch_db) as conn:
    got = supervisor._take_next_job(conn)
    assert got is None
    hstate = conn.execute("select state from dispatch_holds where hold_id=?", (watch_job["dispatch_hold"]["hold_id"],)).fetchone()[0]
    assert hstate in {"HELD", "RELEASED"}
deadline = time.time() + 60
while time.time() < deadline:
    if (watch_root / "restart-proof.json").is_file():
        with supervisor._connect_readonly(watch_db) as conn:
            if conn.execute("select state from dispatch_holds where hold_id=?", (watch_job["dispatch_hold"]["hold_id"],)).fetchone()[0] == "RELEASED":
                break
    time.sleep(0.05)
assert (watch_root / "restart-proof.json").is_file(), (watch_root / "control.json").read_text()
proof = json.loads((watch_root / "restart-proof.json").read_text())
assert proof["dispatch_hold_state"] == "HELD" and proof["cp2_attempts_at_hold"] == 0
assert int(count.read_text().strip()) == 1
with supervisor._connect_readonly(watch_db) as conn:
    final_hold_state = conn.execute("select state from dispatch_holds where hold_id=?", (watch_job["dispatch_hold"]["hold_id"],)).fetchone()[0]
assert final_hold_state == "RELEASED", (final_hold_state, (watch_root / "control.json").read_text(), (watch_root / "restart-watcher.log").read_text())
for _ in range(100):
    if not (watch_root / "watcher" / "test-ownframework-loop-canary-restart-watcher.unit").exists():
        break
    time.sleep(0.05)
assert not (watch_root / "watcher" / "test-ownframework-loop-canary-restart-watcher.unit").exists()
print("WATCHER_CONSUMES_HELD=PASS")
print("RESTART_PROOF_BEFORE_RELEASE=PASS")
print("WATCHER_HOLD_CLEANUP=PASS")
PY

pass "typed per-run dispatch hold and atomic scheduler claim contract"