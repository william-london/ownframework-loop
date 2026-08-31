#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"
TMP="$(mktemp -d -t ofloop-v090-concurrency.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
TMP_ROOT="$TMP" PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$LIB_DIR" python3 -B - <<'PY'
import os, subprocess, time
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
from ownframework_loop import supervisor

tmp = Path(os.environ["TMP_ROOT"]); db = tmp / "supervisor.sqlite3"
def git(repo, *args):
    subprocess.run(["git", "-C", str(repo), *args], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
def repo(name):
    p = tmp / name; p.mkdir()
    subprocess.run(["git", "init", "-q", "-b", "master", str(p)], check=True)
    git(p, "config", "user.email", "test@localhost")
    git(p, "config", "user.name", "test")
    (p / "README.md").write_text("seed\n"); git(p, "add", "README.md"); git(p, "commit", "-qm", "seed")
    return p
def enqueue(p, rid, mode="SINGLE"):
    out = supervisor.enqueue(canonical_repo=p, run_id=rid, db_path=db, runtime_generation="test-generation")
    with supervisor._connect(db) as c:
        c.execute("UPDATE jobs SET execution_mode=? WHERE id=?", (mode, out["id"])); c.commit()
    return out
def reset(j, status="DONE"):
    with supervisor._connect(db) as c:
        c.execute("UPDATE jobs SET status=?, worker_pid=NULL, worker_started_at=NULL, worker_role=NULL, worker_attempt_id=NULL WHERE id=?", (status, j["id"])); c.commit()

assert supervisor.supervisor_config_get(db_path=db)["max_concurrency"] == 1
assert supervisor.supervisor_config_set(max_concurrency="4", db_path=db)["max_concurrency"] == 4
for bad in ("0", "-1", "wat", "65", "1.0"):
    try: supervisor.supervisor_config_set(max_concurrency=bad, db_path=db)
    except ValueError: pass
    else: raise AssertionError(f"invalid config accepted: {bad}")
print("CONFIG_PERSISTENCE_AND_VALIDATION=PASS")

repos = [repo(f"r{i}") for i in range(4)]
jobs = [enqueue(p, f"run-{i}") for i, p in enumerate(repos)]
def claim(_):
    with supervisor._connect(db) as c: return supervisor._take_next_job(c)
with ThreadPoolExecutor(max_workers=4) as pool:
    claimed = [x for x in pool.map(claim, range(4)) if x is not None]
assert len(claimed) == 4 and len({int(x["id"]) for x in claimed}) == 4
with supervisor._connect_readonly(db) as c:
    assert c.execute("select count(*) from jobs where status='RUNNING'").fetchone()[0] == 4
print("FOUR_WAY_ATOMIC_CLAIM=PASS")

# A semantic child can finish while its current supervisor lane is still
# accounting/finalizing. Same-process stale recovery must not steal that
# ownership; a replacement supervisor (with no local fence) must still be
# able to recover the row. This is the regression for the Stage C duplicate
# finalization / lost-RUNNING-ownership failure.
handoff = jobs[0]
with supervisor._connect(db) as c:
    c.execute("UPDATE jobs SET status='RUNNING', worker_pid=999999, worker_started_at=?, worker_role='builder', worker_attempt_id=NULL WHERE id=?", (time.time(), handoff["id"]))
    c.commit()
supervisor._register_local_execution(int(handoff["id"]))
with supervisor._connect(db) as c:
    assert supervisor._recover_stale_running(c) == 0
    assert c.execute("select status from jobs where id=?", (handoff["id"],)).fetchone()[0] == "RUNNING"
supervisor._clear_local_executions_for_thread()
with supervisor._connect(db) as c:
    assert supervisor._recover_stale_running(c) == 1
    assert c.execute("select status from jobs where id=?", (handoff["id"],)).fetchone()[0] == "QUEUED"
print("SAME_SUPERVISOR_COMPLETION_HANDOFF_RECOVERY_FENCE=PASS")

for j in jobs: reset(j)
alias_target = repo("alias-target"); alias = tmp / "alias-link"; alias.symlink_to(alias_target, target_is_directory=True)
same_a = enqueue(alias_target, "run-a"); same_b = enqueue(alias, "run-b")
assert same_a["repository_scheduling_key"] == same_b["repository_scheduling_key"]
linked = tmp / "linked"; git(alias_target, "worktree", "add", "-q", str(linked), "-b", "linked-branch")
same_c = enqueue(linked, "run-c"); assert same_a["repository_scheduling_key"] == same_c["repository_scheduling_key"]
clone = tmp / "independent-clone"; subprocess.run(["git", "clone", "-q", str(alias_target), str(clone)], check=True)
same_d = enqueue(clone, "run-d"); assert same_d["repository_scheduling_key"] != same_a["repository_scheduling_key"]
with supervisor._connect(db) as c:
    first = supervisor._take_next_job(c); second = supervisor._take_next_job(c)
assert first is not None and second is not None and first["repository_scheduling_key"] != second["repository_scheduling_key"]
print("GIT_COMMON_DIR_REPOSITORY_EXCLUSION=PASS")

for j in (same_a, same_b, same_c, same_d): reset(j)
four = []
for i in range(4):
    try:
        four.append(enqueue(repo(f"drain{i}"), f"drain-{i}"))
    except Exception as exc:
        raise AssertionError(f"drain enrollment failed: {type(exc).__name__}: {exc!r}") from exc
with supervisor._connect(db) as c:
    for j in four: c.execute("UPDATE jobs SET status='RUNNING', worker_pid=?, worker_role='builder' WHERE id=?", (os.getpid(), j["id"]))
    c.commit()
supervisor.supervisor_config_set(max_concurrency=2, db_path=db)
fleet = supervisor.fleet_status(db_path=db)
assert fleet["active_running"] == 4 and fleet["capacity_draining"] is True and fleet["free_slots"] == 0
with supervisor._connect(db) as c: assert supervisor._take_next_job(c) is None
print("CAPACITY_DRAINING_NO_PREEMPTION=PASS")

for j in four: reset(j)
supervisor.supervisor_config_set(max_concurrency=1, db_path=db)
with supervisor._connect(db) as c:
    c.execute("UPDATE scheduler_meta SET dispatch_sequence=0, single_since_program=0 WHERE id=1")
    c.execute("UPDATE jobs SET last_dispatch_sequence=0 WHERE status='DONE'")
    c.commit()
singles = [enqueue(repo(f"fair-s{i}"), f"fair-s-{i}", "SINGLE") for i in range(2)]
program = enqueue(repo("fair-p"), "fair-p", "PROGRAM")
order = []
for _ in range(3):
    with supervisor._connect(db) as c:
        j = supervisor._take_next_job(c); assert j is not None; order.append(str(j["execution_mode"])); c.execute("UPDATE jobs SET status='QUEUED', worker_pid=NULL, worker_role=NULL WHERE id=?", (j["id"],)); c.commit()
assert order == ["SINGLE", "SINGLE", "PROGRAM"], order
print("PERSISTED_SINGLE_PRIORITY_PROGRAM_ANTI_STARVATION=PASS")

for j in singles + [program]: reset(j)
hold_repo = repo("held"); hold_job = enqueue(hold_repo, "held-run", "PROGRAM")
with supervisor._connect(db) as c:
    c.execute("""INSERT INTO dispatch_holds(hold_id,job_id,repo,run_id,kind,previous_checkpoint_id,next_checkpoint_id,state,armed_at,updated_at)
                 VALUES ('hold-test',?,?,?,?,?,?,'HELD',?,?)""", (hold_job["id"], str(hold_repo.resolve()), "held-run", supervisor.DISPATCH_HOLD_KIND, "CP-1", "CP-2", time.time(), time.time())); c.commit()
before = supervisor.fleet_status(db_path=db); assert before["held_jobs"] == 1 and before["active_running"] == 0
with supervisor._connect(db) as c: assert supervisor._take_next_job(c) is None
with supervisor._connect_readonly(db) as c:
    assert c.execute("select status from jobs where id=?", (hold_job["id"],)).fetchone()[0] == "QUEUED"
    assert "HELD" not in {r[1] for r in c.execute("pragma table_info(jobs)")}
print("HELD_ISOLATION_READ_ONLY_FLEET_NO_JOBS_STATUS_HELD=PASS")
print("MODEL_FREE_CONCURRENCY_FAILURES=0")
PY
pass "bounded concurrency, repository exclusion, fairness, draining, hold isolation, and fleet contract"
