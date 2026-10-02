#!/usr/bin/env bash
# v1.1.1 — verified reads must not materialize the state they read.
#
# Incident: four retired certification fixture directories under the operator's
# canonical ~/projects root kept REAPPEARING after deletion. Root cause was
# READ_PATH_USES_CREATING_LOCK: state.load_verified() is an authoritative READ
# but acquired locking.flock_exclusive(), which does
# `path.parent.mkdir(parents=True, exist_ok=True)` and `os.open(O_CREAT)`.
# supervisor.run_one() -> program_mission.reconcile_pending_boundaries() replays
# EVERY job with status IN ('QUEUED','DONE') fleet-wide, so merely OBSERVING a
# retired historical enrollment recreated that run's whole
# `.ownframework-loop/<run_id>/` skeleton (repo + run dir + 0600 LOCK) on every
# dispatch tick. The read manufactured the state it was reading.
#
# Native fix: locking.flock_exclusive_existing() (a non-materializing read
# lock) is used by load_verified(), which now fails closed on an absent
# run/repository without creating anything. Mutation owners keep the creating
# flock, because they legitimately establish new run state.
#
# Required invariants proven here:
#   READ_OF_MISSING_REPO => NO FILESYSTEM CREATION
#   READ_OF_MISSING_RUN  => NO FILESYSTEM CREATION
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib:$ROOT_DIR/tests/helpers${PYTHONPATH:+:$PYTHONPATH}"
export OFLOOP_LIB="$ROOT_DIR/lib"
export PYTHONDONTWRITEBYTECODE=1
TMP="$(mktemp -d -t ofloop-v128-verified-read.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

python3 -B - "$TMP" "$ROOT_DIR" <<'PY'
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

root = Path(sys.argv[1])
source_root = Path(sys.argv[2])
os.environ["XDG_STATE_HOME"] = str(root / "state")

from ownframework_loop import (
    integrity, program_mission, state, supervisor, supervisor_db, util,
)


class ReadFixtureRunner:
    runner_id = "v128-read-fixture"

    def run(self, *args, **kwargs):
        raise AssertionError("fixture runner must not launch provider work")


supervisor.register_runner(ReadFixtureRunner)
db_path = root / "state" / "ownframework-loop" / "supervisor.sqlite3"
with supervisor_db._managed_connect(db_path):
    pass

# The exact retired fixture identities from the incident, replayed under a
# disposable projects root. These are the paths that kept reappearing.
RETIRED = [
    ("ofloop-cert-final-20260924", "run-20260923T104950Z-d20cb908"),
    ("ofloop-cert-greenfield-20260917", "run-20260917T131150Z-64f56e4c"),
    ("ofloop-cert-portability-20260923", "run-20260923T152654Z-d1ede72d"),
    ("ofloop-cert-post-v1-20260922/factcard", "run-20260922T051016Z-ccb5c77d"),
    ("ofloop-cert-post-v1-20260922/sourcecard", "run-20260922T123031Z-56e0cdcc"),
]
projects_root = root / "projects"
projects_root.mkdir(parents=True)

# ---------------------------------------------------------------------------
# Part A — the incident, through the exact historical reconciliation path.
# A DONE enrollment naming a repository that no longer exists is replayed by
# the supervisor's program-boundary reconciliation. Observing it must not
# resurrect it.
# ---------------------------------------------------------------------------
for name, run_id in RETIRED:
    assert not (projects_root / name).exists(), f"{name} must start absent"

now = time.time()
with supervisor_db._managed_connect(db_path) as conn:
    for name, run_id in RETIRED:
        conn.execute(
            """INSERT INTO jobs (repo, run_id, status, next_attempt_at,
                                created_at, updated_at)
               VALUES (?, ?, 'DONE', 0, ?, ?)""",
            (str((projects_root / name).resolve()), run_id, now, now),
        )
    conn.commit()

# Exercise the real supervisor entry point that owns the defect.
recon = program_mission.reconcile_pending_boundaries(db_path=db_path)
assert recon.get("ok") is True, recon
assert recon.get("processed") == [], recon
print("HISTORICAL_RECONCILIATION_OVER_ABSENT_REPOS_RUNS=PASS")

for name, run_id in RETIRED:
    fixture = projects_root / name
    assert not fixture.exists(), f"REGRESSION: reconciliation recreated {name}"
    assert not (fixture / ".ownframework-loop").exists()
    assert not (fixture / ".ownframework-loop" / run_id / "LOCK").exists()
print("HISTORICAL_RECONCILIATION_CREATED_NO_FIXTURE=PASS")

# The real supervisor dispatch tick must also stay clean.
tick = supervisor.run_one(db_path=db_path)
for name, run_id in RETIRED:
    assert not (projects_root / name).exists(), f"REGRESSION: run_one recreated {name}"
print("SUPERVISOR_RUN_ONE_CREATED_NO_FIXTURE=PASS")

# ---------------------------------------------------------------------------
# Part B — the read-side invariants, directly.
# ---------------------------------------------------------------------------
absent_repo = projects_root / "ofloop-cert-never-existed"
assert not absent_repo.exists()
# A run with no durable state yields the same empty result the integrity check
# already produces for "no state or event chain yet" — and creates nothing.
assert state.load_verified(absent_repo, "run-20260101T000000Z-v128absent") == {}
assert not absent_repo.exists(), "READ_OF_MISSING_REPO created the repository"
assert not (absent_repo / ".ownframework-loop").exists()
print("READ_OF_MISSING_REPO_NO_CREATION=PASS")

# A repository that exists but has no such run must not gain a run directory.
live_repo = projects_root / "ofloop-cert-post-v1-20260922"
live_repo.mkdir(parents=True)
assert not (live_repo / ".ownframework-loop").exists()
assert state.load_verified(live_repo, "run-20260101T000000Z-v128absent") == {}
assert not (live_repo / ".ownframework-loop").exists(), \
    "READ_OF_MISSING_RUN created the run directory"
assert not (live_repo / ".ownframework-loop" / "run-20260101T000000Z-v128absent" / "LOCK").exists()
print("READ_OF_MISSING_RUN_NO_CREATION=PASS")

# A run directory that EXISTS but was established without a per-run lock is a
# legitimate run and must remain readable: the creating lock is retained
# inside the existing run directory, which establishes nothing new.
legacy_repo = projects_root / "ofloop-cert-legacy-run"
legacy_run = "run-20260101T000000Z-v128legacy"
legacy_root = state.run_dir(legacy_repo, legacy_run)
legacy_root.mkdir(parents=True)
legacy_root.joinpath("STATE.json").write_text(
    json.dumps({"state": "BUILDING", "label": "legacy"}), encoding="utf-8",
)
assert not (legacy_root / "LOCK").exists()
assert state.load_verified(legacy_repo, legacy_run) == {"state": "BUILDING", "label": "legacy"}
assert (legacy_root / "LOCK").is_file(), \
    "an existing run must keep its establishing lock behavior"
print("EXISTING_RUN_WITHOUT_LOCK_STILL_READABLE=PASS")

# ---------------------------------------------------------------------------
# Part C — positive control: legitimate existing runs are unchanged.
# Verified locking and integrity enforcement must still work exactly as before.
# ---------------------------------------------------------------------------
repo = projects_root / "live-repo"
repo.mkdir()
subprocess.run(["git", "-C", str(repo), "init", "-q", "-b", "master"], check=True)
subprocess.run(["git", "-C", str(repo), "config", "user.name", "Loop v128 fixture"], check=True)
subprocess.run(
    ["git", "-C", str(repo), "config", "user.email", "loop-v128@example.invalid"], check=True,
)
(repo / ".git" / "info" / "exclude").write_text(
    "/.ownframework-loop/\n/.worktrees/ownframework-loop/\n", encoding="utf-8",
)
(repo / "README.md").write_text("v128 positive control fixture\n", encoding="utf-8")
subprocess.run(["git", "-C", str(repo), "add", "README.md"], check=True)
subprocess.run(["git", "-C", str(repo), "commit", "-qm", "fixture baseline"], check=True)
baseline = subprocess.run(
    ["git", "-C", str(repo), "rev-parse", "HEAD"],
    capture_output=True, text=True, check=True,
).stdout.strip()

live_run = "run-20260101T000000Z-v128live"
initial = state.initial_state(live_run)
initial.update({
    "spec_baseline_branch": "master",
    "spec_baseline_sha": baseline,
    "spec_snapshot_at": util.utc_now_iso(),
})
# Mutation owners legitimately CREATE run state; that must keep working.
state.save(repo, live_run, initial)
assert (repo / ".ownframework-loop" / live_run / "LOCK").is_file(), \
    "mutation owner lost its creating lock"
loaded = state.load_verified(repo, live_run)
assert loaded["state"] == "AWAITING_APPROVAL", loaded["state"]
assert loaded["run_id"] == live_run
print("EXISTING_RUN_VERIFIED_READ_UNCHANGED=PASS")

# Integrity enforcement on a real run is unchanged: a SHA-mismatched
# STATE.json is still refused rather than trusted.
sp = state.state_path(repo, live_run)
tampered = json.loads(sp.read_text(encoding="utf-8"))
tampered["state"] = "APPROVED"
sp.write_text(json.dumps(tampered), encoding="utf-8")
try:
    state.load_verified(repo, live_run)
except integrity.TamperingDetected:
    pass
else:
    raise AssertionError("verified read must still reject a tampered STATE.json")
print("EXISTING_RUN_INTEGRITY_ENFORCEMENT_UNCHANGED=PASS")

# A verified read of an existing run must not add any new run entries.
state_root_before = sorted(p.name for p in (repo / ".ownframework-loop").iterdir())
try:
    state.load_verified(repo, live_run)
except integrity.TamperingDetected:
    pass  # still tampered from the integrity check above
assert sorted(p.name for p in (repo / ".ownframework-loop").iterdir()) == state_root_before
print("VERIFIED_READ_CREATES_NO_NEW_RUN_ENTRIES=PASS")

print("VERIFIED_READ_NON_MATERIALIZATION=PASS")
PY

echo "test_v128_verified_read_non_materialization:PASS"
