#!/usr/bin/env bash
# Model-free durable commissioned-canary restart-watcher lifecycle proof.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"

HARNESS="$ROOT_DIR/tests/canary/commissioned_program_canary.sh"
HELPER="$ROOT_DIR/tests/canary/commissioned_program_restart_watcher.py"
TMP="$(mktemp -d -t ofloop_canary_watcher.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

TMP_ROOT="$TMP" HARNESS="$HARNESS" HELPER="$HELPER" OFLOOP_BIN="$OFLOOP_BIN" \
PYTHONDONTWRITEBYTECODE=1 python3 -B - <<'PY'
import json
import os
import signal
import sqlite3
import subprocess
import time
from pathlib import Path

tmp = Path(os.environ["TMP_ROOT"])
harness = Path(os.environ["HARNESS"])
helper = Path(os.environ["HELPER"])
ofloop = os.environ["OFLOOP_BIN"]


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def fixture(name, missed=False):
    root = tmp / name
    repo = root / "repo"
    run = "run-watcher-" + name
    run_dir = repo / ".ownframework-loop" / run
    install = root / "install"
    state_root = root / "state"
    db = root / "supervisor.sqlite3"
    provenance = root / "runtime-provenance.json"
    active = root / "service.active"
    count = root / "restart.count"
    fake_restart = root / "fake-restart.sh"
    repo.mkdir(parents=True)
    run_dir.mkdir(parents=True)
    install.mkdir()
    state_root.mkdir()
    active.touch()
    provenance.write_text(json.dumps({"runtime_generation": "test-generation"}) + "\n")
    fake_restart.write_text(
        "#!/bin/sh\n"
        "n=0; [ -f \"$OFLOOP_CANARY_TEST_RESTART_COUNT_FILE\" ] && n=$(cat \"$OFLOOP_CANARY_TEST_RESTART_COUNT_FILE\")\n"
        "printf '%s\\n' $((n + 1)) > \"$OFLOOP_CANARY_TEST_RESTART_COUNT_FILE\"\n",
        encoding="utf-8",
    )
    fake_restart.chmod(0o700)
    attempts = [
        ("builder-1", "builder", "DONE"),
        ("reviewer-1", "reviewer", "DONE"),
        ("builder-2", "builder", "DONE"),
        ("reviewer-2", "reviewer", "DONE"),
    ]
    if missed:
        attempts.append(("builder-3", "builder", "RUNNING"))
    conn = sqlite3.connect(db)
    conn.executescript(
        """
        CREATE TABLE jobs (
          id INTEGER PRIMARY KEY, repo TEXT, run_id TEXT,
          worker_pid INTEGER, worker_role TEXT, worker_attempt_id TEXT
        );
        CREATE TABLE semantic_attempts (
          attempt_id TEXT PRIMARY KEY, job_id INTEGER, role TEXT,
          status TEXT, started_at REAL
        );
        """
    )
    conn.execute(
        "INSERT INTO jobs(id, repo, run_id, worker_pid, worker_role, worker_attempt_id) VALUES(1, ?, ?, ?, ?, ?)",
        (str(repo.resolve()), run, 101 if missed else None, "builder" if missed else None, "builder-3" if missed else None),
    )
    for index, (attempt_id, role, status) in enumerate(attempts):
        conn.execute(
            "INSERT INTO semantic_attempts VALUES(?, 1, ?, ?, ?)",
            (attempt_id, role, status, index),
        )
    conn.commit()
    conn.close()
    boundary_state = {
        "state": "READY_TO_BUILD",
        "program": {
            "current_checkpoints": ["CP-2"],
            "finalized_checkpoints": [{"id": "CP-1", "terminal_state": "APPROVED"}],
            "checkpoints": [
                {"id": "CP-1", "terminal": "APPROVED", "build_pass_count": 2, "review_pass_count": 2, "repair_round_count": 1},
                {"id": "CP-2", "terminal": None, "build_pass_count": 1 if missed else 0, "review_pass_count": 0, "repair_round_count": 0},
            ],
        },
    }
    initial_state = boundary_state if missed else {
        "state": "READY_TO_BUILD",
        "program": {
            "current_checkpoints": ["CP-1"],
            "finalized_checkpoints": [],
            "checkpoints": [
                {"id": "CP-1", "terminal": None, "build_pass_count": 1, "review_pass_count": 0, "repair_round_count": 0},
                {"id": "CP-2", "terminal": None, "build_pass_count": 0, "review_pass_count": 0, "repair_round_count": 0},
            ],
        },
    }
    write(run_dir / "STATE.json", initial_state)
    control = {
        "schema": "ownframework-loop-commissioned-canary-control/v1",
        "status": "PREPARED",
        "canary_root": str(root), "repo": str(repo), "run_id": run,
        "ofloop_bin": ofloop, "install_root": str(install),
        "state_root": str(state_root), "db": str(db), "provenance": str(provenance),
        "service_manager": "test", "service_label": "fake-supervisor",
        "runtime_generation_prepared": "test-generation",
        "test_service_active_file": str(active),
        "test_restart_command": str(fake_restart),
        "semantic_intervention_count": 0,
    }
    write(root / "control.json", control)
    (root / "control.json").chmod(0o600)
    return root, run, boundary_state, count, active


def env(count, active):
    value = os.environ.copy()
    value.update({
        "OFLOOP_CANARY_TEST_MANAGER": "1",
        "OFLOOP_CANARY_TEST_SERVICE_ACTIVE_FILE": str(active),
        "OFLOOP_CANARY_TEST_RESTART_COUNT_FILE": str(count),
        "OFLOOP_CANARY_RESTART_POLL_SECONDS": "0.02",
        "OFLOOP_CANARY_RESTART_WAIT_SECONDS": "30",
    })
    return value


def control(root):
    return json.loads((root / "control.json").read_text())


def wait_for(predicate, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.03)
    raise AssertionError("timed out waiting for watcher fixture")


def dead(pid):
    try:
        os.kill(pid, 0)
    except (ProcessLookupError, PermissionError):
        return True
    return False


root, run, state, count, active = fixture("survives-launcher-exit")
e = env(count, active)
launcher = subprocess.Popen(
    ["bash", str(harness), "arm-restart", str(root)],
    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=e,
)
try:
    wait_for(lambda: control(root).get("watcher_pid"), timeout=5)
except AssertionError:
    if launcher.poll() is not None:
        raise AssertionError(f"arm failed rc={launcher.returncode}: {launcher.communicate()[0]}")
    raise AssertionError(f"arm still running control={control(root)}")
watcher_pid = int(control(root)["watcher_pid"])
if launcher.poll() is None:
    launcher.terminate()
launcher.communicate(timeout=5)
os.kill(watcher_pid, 0)
assert control(root)["watcher_durable"] is True
assert (root / "watcher" / (control(root)["watcher_id"] + ".unit")).is_file()
print("CANARY_RESTART_WATCHER_SURVIVES_LAUNCHER_EXIT=PASS")

# A second arm is idempotent and cannot create a second watcher.
again = subprocess.run(["bash", str(harness), "arm-restart", str(root)], capture_output=True, text=True, env=e, check=True)
assert "WATCHER_DURABLE=yes" in again.stdout
assert int(control(root)["watcher_pid"]) == watcher_pid

# The safe boundary is observed only after CP-1 approval, CP-2 current, the
# top-level READY_TO_BUILD state, and no CP-2 ledger activity.
subprocess.run(["bash", str(harness), "arm-restart", str(root)], env=e, check=True, stdout=subprocess.DEVNULL)
run_state = root / "repo" / ".ownframework-loop" / run / "STATE.json"
write(run_state, state)
wait_for(lambda: (root / "restart-proof.json").is_file(), timeout=5)
proof = json.loads((root / "restart-proof.json").read_text())
assert proof["observed_cp1_terminal"] == "APPROVED"
assert proof["observed_current_checkpoints"] == ["CP-2"]
assert proof["observed_top_state"] == "READY_TO_BUILD"
assert proof["no_active_cp2_worker"] is True
assert proof["service_restarted"] is True
assert proof["service_active_after_restart"] is True
assert proof["runtime_generation_stable"] is True
assert count.read_text().strip() == "1"
try:
    wait_for(lambda: dead(watcher_pid), timeout=5)
except AssertionError:
    ps = subprocess.run(["ps", "-o", "pid=,ppid=,stat=,command=", "-p", str(watcher_pid)], capture_output=True, text=True).stdout.strip()
    raise AssertionError(f"watcher remained alive control={control(root)} ps={ps}")
assert control(root)["watcher_status"] == "PROOF_WRITTEN"
assert not (root / "watcher" / (control(root)["watcher_id"] + ".unit")).exists()
duplicate = subprocess.run(["bash", str(harness), "arm-restart", str(root)], capture_output=True, text=True, env=e, check=True)
assert "CANARY_RESTART_WATCH=ALREADY_COMPLETE" in duplicate.stdout
assert count.read_text().strip() == "1"
subprocess.run(["bash", str(harness), "destroy", str(root)], env=e, check=True, stdout=subprocess.DEVNULL)
print("CANARY_RESTART_WATCHER_EXACTLY_ONCE=PASS")

# If CP-2 is already claimed, the watcher fails closed and never restarts.
root, run, state, count, active = fixture("missed-boundary", missed=True)
e = env(count, active)
missed_arm = subprocess.run(["bash", str(harness), "arm-restart", str(root)], capture_output=True, text=True, env=e)
assert missed_arm.returncode in (0, 1)
wait_for(lambda: control(root).get("watcher_result") == "RESTART_BOUNDARY_MISSED", timeout=5)
assert not (root / "restart-proof.json").exists()
assert not count.exists()
assert control(root)["watcher_status"] == "FAILED"
subprocess.run(["bash", str(harness), "destroy", str(root)], env=e, check=True, stdout=subprocess.DEVNULL)
print("CANARY_RESTART_WATCHER_MISSED_BOUNDARY_FAIL_CLOSED=PASS")

# Paid start is fail-closed unless a durable watcher is alive.
root, run, state, count, active = fixture("start-safety")
e = env(count, active)
blocked = subprocess.run(["bash", str(harness), "start", str(root)], capture_output=True, text=True, env=e)
assert blocked.returncode != 0
assert "restart_watcher_not_armed" in blocked.stdout + blocked.stderr
assert not count.exists()
subprocess.run(["bash", str(harness), "destroy", str(root)], env=e, check=True, stdout=subprocess.DEVNULL)
print("CANARY_RESTART_WATCHER_START_SAFETY=PASS")
PY

echo "V085_COMMISSIONED_CANARY_RESTART_WATCHER=PASS"
