#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"
TMP="$(mktemp -d -t ofloop-v090-concurrency.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
TMP_ROOT="$TMP" PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$LIB_DIR" python3 -B - <<'PY'
import os, subprocess, tempfile, time
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
from ownframework_loop import dispatch, supervisor

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

# Multiple dead workers must reconcile independently.  The first stale
# attempt is durably accounted before the next attempt opens its own SQLite
# transaction; this is the regression for the multi-worker recovery handoff.
stale_root = Path(tempfile.mkdtemp(prefix="ofloop-multi-stale-"))
stale_db = stale_root / "supervisor.sqlite3"
stale_jobs = []
for index in range(2):
    stale_repo = repo(f"multi-stale-{index}")
    stale_jobs.append(
        supervisor.enqueue(
            canonical_repo=stale_repo,
            run_id=f"run-multi-stale-{index}",
            db_path=stale_db,
            runtime_generation="test-generation",
        )
    )
with supervisor._connect(stale_db) as c:
    now = time.time()
    for job in stale_jobs:
        attempt_id = f"stale-attempt-{job['id']}"
        c.execute(
            "UPDATE jobs SET status='RUNNING', worker_pid=999999, "
            "worker_started_at=?, worker_role='builder', worker_attempt_id=?, "
            "latest_attempt_id=? WHERE id=?",
            (now, attempt_id, attempt_id, job["id"]),
        )
        c.execute(
            "INSERT INTO semantic_attempts "
            "(attempt_id,job_id,role,status,started_at,worker_pid,stdout_path,stderr_path) "
            "VALUES (?,?, 'builder','RUNNING', ?,999999, ?, ?)",
            (attempt_id, job["id"], now, str(stale_root / "out"), str(stale_root / "err")),
        )
    c.commit()
with supervisor._connect(stale_db) as c:
    recovered_stale = supervisor._recover_stale_running(c)
    queued_stale = c.execute("SELECT COUNT(*) FROM jobs WHERE status='QUEUED'").fetchone()[0]
    recovered_attempts = c.execute(
        "SELECT COUNT(*) FROM semantic_attempts "
        "WHERE status IN ('RECOVERED','COST_UNKNOWN') AND cost_accounted=1"
    ).fetchone()[0]
    assert recovered_stale == 2, (recovered_stale, queued_stale, recovered_attempts)
    assert queued_stale == 2, (recovered_stale, queued_stale, recovered_attempts)
    assert recovered_attempts == 2, (recovered_stale, queued_stale, recovered_attempts)
print("MULTI_WORKER_STALE_RECOVERY=PASS")

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

# Concurrent fairness claims must serialize against the persisted scheduler
# generation. Three lanes starting from the same observation must still commit
# exactly SINGLE, SINGLE, PROGRAM with consecutive dispatch sequence values.
reset(hold_job)
supervisor.supervisor_config_set(max_concurrency=3, db_path=db)
with supervisor._connect(db) as c:
    c.execute("UPDATE scheduler_meta SET dispatch_sequence=0, single_since_program=0 WHERE id=1")
    c.commit()
fair_concurrent = [
    enqueue(repo("fair-cs-0"), "fair-cs-0", "SINGLE"),
    enqueue(repo("fair-cs-1"), "fair-cs-1", "SINGLE"),
    enqueue(repo("fair-cp-0"), "fair-cp-0", "PROGRAM"),
]
with ThreadPoolExecutor(max_workers=3) as pool:
    fair_claims = [x for x in pool.map(claim, range(3)) if x is not None]
assert len(fair_claims) == 3, [dict(x) for x in fair_claims]
fair_claims = sorted(fair_claims, key=lambda r: int(r["last_dispatch_sequence"]))
assert [str(x["execution_mode"]) for x in fair_claims] == ["SINGLE", "SINGLE", "PROGRAM"], [
    dict(x) for x in fair_claims
]
assert [int(x["last_dispatch_sequence"]) for x in fair_claims] == [1, 2, 3], [
    dict(x) for x in fair_claims
]
print("CONCURRENT_FAIRNESS_CAS_AND_SEQUENCE=PASS")
for j in fair_concurrent:
    reset(j)

# Preferred-class jobs that are all same-repository blocked may not strand a
# free slot while the fallback class has an unrelated eligible repository.
supervisor.supervisor_config_set(max_concurrency=2, db_path=db)
fallback_repo = repo("fallback-same")
fallback_owner = enqueue(fallback_repo, "fallback-owner", "SINGLE")
fallback_blocked = enqueue(fallback_repo, "fallback-blocked", "SINGLE")
fallback_program = enqueue(repo("fallback-program"), "fallback-program", "PROGRAM")
with supervisor._connect(db) as c:
    c.execute(
        "UPDATE jobs SET status='RUNNING', worker_pid=?, worker_started_at=?, worker_role='builder' WHERE id=?",
        (os.getpid(), time.time(), fallback_owner["id"]),
    )
    c.execute("UPDATE scheduler_meta SET single_since_program=0 WHERE id=1")
    c.commit()
with supervisor._connect(db) as c:
    fallback_claim = supervisor._take_next_job(c)
assert fallback_claim is not None and int(fallback_claim["id"]) == int(fallback_program["id"]), (
    dict(fallback_claim) if fallback_claim is not None else None
)
print("BLOCKED_PREFERRED_CLASS_FALLS_BACK_WITHOUT_IDLE_SLOT=PASS")
for j in (fallback_owner, fallback_blocked, fallback_program):
    reset(j)

# Fleet projection must distinguish ARMED from HELD and must respect backoff
# readiness/identity instead of reporting every queued row as schedulable.
supervisor.supervisor_config_set(max_concurrency=1, db_path=db)
fleet_repo = repo("fleet-armed")
fleet_job = enqueue(fleet_repo, "fleet-armed", "PROGRAM")
with supervisor._connect(db) as c:
    c.execute(
        """INSERT INTO dispatch_holds(
               hold_id,job_id,repo,run_id,kind,previous_checkpoint_id,
               next_checkpoint_id,state,armed_at,updated_at
           ) VALUES ('fleet-armed-hold',?,?,?,?,?,?,'ARMED',?,?)""",
        (
            fleet_job["id"],
            str(fleet_repo.resolve()),
            "fleet-armed",
            supervisor.DISPATCH_HOLD_KIND,
            "CP-1",
            "CP-2",
            time.time(),
            time.time(),
        ),
    )
    c.commit()
fleet_now = supervisor.fleet_status(db_path=db)
fleet_item = next(x for x in fleet_now["jobs"] if int(x["id"]) == int(fleet_job["id"]))
assert fleet_item["hold_state"] == "ARMED"
assert fleet_item["held"] is False
assert fleet_item["effective_schedulability"] is True
with supervisor._connect(db) as c:
    c.execute(
        "UPDATE jobs SET status='BACKOFF', next_attempt_at=? WHERE id=?",
        (time.time() + 120, fleet_job["id"]),
    )
    c.commit()
fleet_later = supervisor.fleet_status(db_path=db)
fleet_item = next(x for x in fleet_later["jobs"] if int(x["id"]) == int(fleet_job["id"]))
assert fleet_item["effective_schedulability"] is False
print("FLEET_ARMED_AND_BACKOFF_TRUTH=PASS")
reset(fleet_job)

# Provider/model output that fails the semantic artifact contract is a bounded
# same-pass runner retry, while structural worktree/identity failures remain
# immediate invariants.
retryable = dispatch.SemanticResultIncomplete("review_acceptance_coverage_incomplete")
assert retryable.retryable is True
assert supervisor._classify_exception(retryable) == ("runner", "semantic_result_incomplete")
structural = dispatch.SemanticResultIncomplete("reviewer_worktree_missing")
assert structural.retryable is False
assert supervisor._classify_exception(structural) == ("invariant", "semantic_result_not_finalizable")
retry_job = enqueue(repo("semantic-retry"), "semantic-retry", "PROGRAM")
with supervisor._connect(db) as c:
    c.execute(
        "UPDATE jobs SET status='RUNNING', max_infra_failures=3 WHERE id=?",
        (retry_job["id"],),
    )
    c.commit()
    policy = supervisor._apply_failure_policy(
        c,
        job_id=int(retry_job["id"]),
        failure_class="runner",
        failure_reason="semantic_result_incomplete",
        detail="review acceptance coverage incomplete",
    )
assert policy["status"] == "BACKOFF" and policy["infra_failures"] == 1, policy
print("SEMANTIC_ARTIFACT_INCOMPLETE_BOUNDED_RETRY=PASS")
reset(retry_job)

# If Git common-dir discovery fails for a real repository, scheduling identity
# must be unproven rather than a path-based false positive.
identity_repo = repo("identity-failclosed")
orig_run = supervisor.subprocess.run
def _fail_git_probe(*args, **kwargs):
    raise OSError("synthetic git identity probe failure")
supervisor.subprocess.run = _fail_git_probe
try:
    identity_key, identity_proven = supervisor._repository_scheduling_identity(identity_repo)
finally:
    supervisor.subprocess.run = orig_run
assert identity_proven is False and identity_key.startswith("unproven-git:"), (
    identity_key, identity_proven
)
print("REAL_GIT_IDENTITY_UNCERTAINTY_FAILS_CLOSED=PASS")

# Re-enqueue cannot rewrite repository scheduling identity while a job owns a
# live RUNNING slot.
identity_job = enqueue(repo("identity-running"), "identity-running", "SINGLE")
with supervisor._connect(db) as c:
    c.execute(
        "UPDATE jobs SET status='RUNNING', worker_pid=?, worker_started_at=?, worker_role='builder' WHERE id=?",
        (os.getpid(), time.time(), identity_job["id"]),
    )
    c.commit()
orig_identity = supervisor._repository_scheduling_identity
supervisor._repository_scheduling_identity = lambda _p: ("synthetic-drift-key", True)
try:
    refused = supervisor.enqueue(
        canonical_repo=Path(identity_job["repo"]),
        run_id="identity-running",
        db_path=db,
        runtime_generation="test-generation",
    )
finally:
    supervisor._repository_scheduling_identity = orig_identity
assert refused.get("enqueue_refused") is True, refused
assert refused.get("reason") == "cannot_change_scheduling_identity_while_running", refused
print("RUNNING_SCHEDULING_IDENTITY_IMMUTABLE=PASS")
reset(identity_job)

# Closing a nested managed SQLite connection in one execution lane must not
# clear the ownership fence held by its outer run_one connection.
nested_job = enqueue(repo("nested-connection"), "nested-connection", "SINGLE")
with supervisor._managed_connect(db):
    supervisor._register_local_execution(int(nested_job["id"]))
    with supervisor._managed_connect(db):
        pass
    assert supervisor._local_execution_owned(int(nested_job["id"])) is True
assert supervisor._local_execution_owned(int(nested_job["id"])) is False
print("NESTED_CONNECTION_PRESERVES_EXECUTION_OWNERSHIP_FENCE=PASS")
reset(nested_job)

print("MODEL_FREE_CONCURRENCY_FAILURES=0")
PY
pass "bounded concurrency, repository exclusion, fairness, draining, hold isolation, and fleet contract"
