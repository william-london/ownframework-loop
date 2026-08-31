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
from ownframework_loop import dispatch, supervisor, worktrees

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
assert same_a["repository_scheduling_key"] == same_b["repository_scheduling_key"], (same_a["repo"], same_b["repo"], same_a["repository_scheduling_key"], same_b["repository_scheduling_key"], same_a.get("candidate_branch"), same_b.get("candidate_branch"), same_a.get("workspace_scheduling_key"), same_b.get("workspace_scheduling_key"))
assert same_a["workspace_scheduling_key"] != same_b["workspace_scheduling_key"]
linked = tmp / "linked"; git(alias_target, "worktree", "add", "-q", str(linked), "-b", "linked-branch")
same_c = enqueue(linked, "run-c")
assert same_a["repository_scheduling_key"] == same_c["repository_scheduling_key"]
assert len({same_a["workspace_scheduling_key"], same_b["workspace_scheduling_key"], same_c["workspace_scheduling_key"]}) == 3
clone = tmp / "independent-clone"; subprocess.run(["git", "clone", "-q", str(alias_target), str(clone)], check=True)
same_d = enqueue(clone, "run-d")
assert same_d["repository_scheduling_key"] != same_a["repository_scheduling_key"]
with supervisor._connect(db) as c:
    branch_claims = [supervisor._take_next_job(c) for _ in range(4)]
assert all(branch_claims), [dict(x) if x is not None else None for x in branch_claims]
assert len({int(x["id"]) for x in branch_claims}) == 4
assert sum(1 for x in branch_claims if x["repository_scheduling_key"] == same_a["repository_scheduling_key"]) == 3
print("SAME_REPOSITORY_DISTINCT_BRANCH_CONCURRENCY=PASS")

# Same candidate branch/workspace remains exclusive even when run ids differ.
for j in (same_a, same_b, same_c, same_d): reset(j)
collision_repo = repo("branch-collision")
collision_a = enqueue(collision_repo, "collision-a")
collision_b = enqueue(collision_repo, "collision-b")
with supervisor._connect(db) as c:
    a = c.execute("SELECT * FROM jobs WHERE id=?", (collision_a["id"],)).fetchone()
    c.execute(
        """UPDATE jobs
              SET candidate_branch=?, workspace_scheduling_key=?,
                  workspace_identity_proven=1
            WHERE id=?""",
        (a["candidate_branch"], a["workspace_scheduling_key"], collision_b["id"]),
    )
    c.commit()
    first = supervisor._take_next_job(c)
    second = supervisor._take_next_job(c)
assert first is not None and second is None
print("SAME_CANDIDATE_BRANCH_EXCLUSION=PASS")

# Shared Git worktree bookkeeping is serialized briefly, but isolated run
# worktrees must all materialize correctly under concurrent setup.
for j in (collision_a, collision_b): reset(j)
wt_repo = repo("parallel-worktrees")
wt_head = subprocess.run(
    ["git", "-C", str(wt_repo), "rev-parse", "HEAD"],
    check=True, capture_output=True, text=True,
).stdout.strip()
def make_wt(i):
    rid = f"wt-run-{i}"
    branch = f"factory/candidate/{rid}"
    return worktrees.add_builder_worktree(
        wt_repo, rid, branch=branch, base_sha=wt_head
    )
with ThreadPoolExecutor(max_workers=4) as pool:
    wt_results = list(pool.map(make_wt, range(4)))
assert len({x["path"] for x in wt_results}) == 4, wt_results
assert all(x["actual_branch"] == x["branch"] for x in wt_results), wt_results
assert all(worktrees.is_registered_worktree(wt_repo, Path(x["path"])) for x in wt_results)
for i in range(4):
    ok, _ = worktrees.cleanup_builder_worktree(wt_repo, f"wt-run-{i}")
    assert ok
print("SAME_REPOSITORY_PARALLEL_WORKTREE_SETUP=PASS")

# Pre-approval workspace identity honors an explicit packet candidate branch.
custom_repo = repo("custom-preapproval-branch")
custom_run = "custom-preapproval-branch"
custom_dir = custom_repo / ".ownframework-loop" / custom_run
custom_dir.mkdir(parents=True)
fence = chr(96) * 3
(custom_dir / "WORK_PACKET.md").write_text(
    fence + 'json\n{"target":{"candidate_branch_prefix":"factory/candidate/custom-preapproval"}}\n' + fence + '\n'
)
custom_job = supervisor.enqueue(
    canonical_repo=custom_repo, run_id=custom_run, db_path=db,
    runtime_generation="test-generation",
)
assert custom_job.get("candidate_branch") == "factory/candidate/custom-preapproval", custom_job
assert "factory/candidate/custom-preapproval" in custom_job["workspace_scheduling_key"], custom_job
print("PREAPPROVAL_CUSTOM_BRANCH_WORKSPACE_IDENTITY=PASS")
reset(custom_job)

# Recover a vanished disposable worktree by reattaching its surviving frozen branch.
recover_repo = repo("surviving-branch-recovery")
recover_head = subprocess.run(
    ["git", "-C", str(recover_repo), "rev-parse", "HEAD"],
    check=True, capture_output=True, text=True,
).stdout.strip()
recover_run = "surviving-branch-recovery"
recover_branch = "factory/candidate/surviving-branch-recovery"
first_wt = worktrees.add_builder_worktree(
    recover_repo, recover_run, branch=recover_branch, base_sha=recover_head
)
git(recover_repo, "worktree", "remove", "--force", first_wt["path"])
assert not Path(first_wt["path"]).exists()
second_wt = worktrees.add_builder_worktree(
    recover_repo, recover_run, branch=recover_branch, base_sha=recover_head
)
assert second_wt["actual_branch"] == recover_branch, second_wt
assert second_wt["head"] == recover_head, second_wt
assert worktrees.is_registered_worktree(recover_repo, Path(second_wt["path"]))
ok, _ = worktrees.cleanup_builder_worktree(recover_repo, recover_run)
assert ok
print("SURVIVING_CANDIDATE_BRANCH_REATTACH=PASS")

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
    owner = c.execute("SELECT * FROM jobs WHERE id=?", (fallback_owner["id"],)).fetchone()
    c.execute(
        """UPDATE jobs
              SET candidate_branch=?, workspace_scheduling_key=?,
                  workspace_identity_proven=1
            WHERE id=?""",
        (owner["candidate_branch"], owner["workspace_scheduling_key"], fallback_blocked["id"]),
    )
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

# Identity uncertainty is rejected at enrollment rather than left silently
# queued forever in a background service.
orig_identity = supervisor._repository_scheduling_identity
supervisor._repository_scheduling_identity = lambda _p: ("unproven", False)
try:
    refused_identity = supervisor.enqueue(
        canonical_repo=identity_repo,
        run_id="identity-enqueue-refusal",
        db_path=db,
        runtime_generation="test-generation",
    )
finally:
    supervisor._repository_scheduling_identity = orig_identity
assert refused_identity.get("enqueue_refused") is True, refused_identity
assert refused_identity.get("reason") == "repository_identity_unproven", refused_identity
print("UNPROVEN_IDENTITY_ENQUEUE_REFUSED=PASS")

# The same logical run cannot be registered again through another linked
# worktree path of the same Git common directory.
logical_repo = repo("logical-duplicate")
logical_linked = tmp / "logical-linked"
git(logical_repo, "worktree", "add", "-q", str(logical_linked), "-b", "logical-linked-branch")
logical_first = enqueue(logical_repo, "logical-run")
logical_second = supervisor.enqueue(
    canonical_repo=logical_linked,
    run_id="logical-run",
    db_path=db,
    runtime_generation="test-generation",
)
assert logical_second.get("enqueue_refused") is True, logical_second
assert logical_second.get("reason") == "logical_run_already_enrolled_via_other_worktree", logical_second
print("LOGICAL_RUN_ALIAS_DUPLICATE_REFUSED=PASS")
reset(logical_first)

# Two different runs may not reuse one candidate branch. This catches a
# configuration mistake before worktree creation or semantic spend.
branch_repo = repo("branch-enrollment-collision")
orig_branch = supervisor.branch_resolver_mod.resolve_candidate_branch
supervisor.branch_resolver_mod.resolve_candidate_branch = lambda *_a, **_k: "factory/candidate/shared"
try:
    branch_first = supervisor.enqueue(
        canonical_repo=branch_repo, run_id="branch-first", db_path=db,
        runtime_generation="test-generation",
    )
    branch_second = supervisor.enqueue(
        canonical_repo=branch_repo, run_id="branch-second", db_path=db,
        runtime_generation="test-generation",
    )
finally:
    supervisor.branch_resolver_mod.resolve_candidate_branch = orig_branch
assert branch_first.get("ok", True) is True, branch_first
assert branch_second.get("enqueue_refused") is True, branch_second
assert branch_second.get("reason") == "candidate_branch_already_enrolled", branch_second
print("CANDIDATE_BRANCH_DUPLICATE_ENROLLMENT_REFUSED=PASS")
reset(branch_first)

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

# v0.8.4 unfinished PROGRAM rows must get exact v0.9 scheduling identity and
# execution class once. Later connections must not re-run Git backfill.
migration_repo = repo("migration-program")
migration_run = "migration-program"
migration_dir = migration_repo / ".ownframework-loop" / migration_run
migration_dir.mkdir(parents=True)
fence = chr(96) * 3
(migration_dir / "WORK_PACKET.md").write_text(
    fence + 'json\n{"execution_mode":"program"}\n' + fence + '\n'
)
migration_job = supervisor.enqueue(
    canonical_repo=migration_repo,
    run_id=migration_run,
    db_path=db,
    runtime_generation="test-generation",
)
with supervisor._connect(db) as c:
    c.execute(
        """UPDATE jobs
              SET repository_scheduling_key='', repository_identity_proven=0,
                  candidate_branch='', workspace_scheduling_key='',
                  workspace_identity_proven=0,
                  execution_mode='SINGLE', status='QUEUED'
            WHERE id=?""",
        (migration_job["id"],),
    )
    c.execute("PRAGMA user_version = 5")
    c.commit()
with supervisor._connect(db) as c:
    migrated = c.execute(
        "SELECT * FROM jobs WHERE id=?", (migration_job["id"],)
    ).fetchone()
    assert int(c.execute("PRAGMA user_version").fetchone()[0]) == supervisor.SCHEMA_DATA_VERSION
assert int(migrated["repository_identity_proven"]) == 1, dict(migrated)
assert str(migrated["repository_scheduling_key"]) == str((migration_repo / ".git").resolve()), dict(migrated)
assert str(migrated["candidate_branch"]) == "factory/candidate/migration-program", dict(migrated)
assert int(migrated["workspace_identity_proven"]) == 1, dict(migrated)
assert migrated["workspace_scheduling_key"], dict(migrated)
assert str(migrated["execution_mode"]) == "PROGRAM", dict(migrated)
orig_identity = supervisor._repository_scheduling_identity
supervisor._repository_scheduling_identity = lambda _p: (_ for _ in ()).throw(
    AssertionError("identity backfill unexpectedly repeated")
)
try:
    with supervisor._connect(db):
        pass
finally:
    supervisor._repository_scheduling_identity = orig_identity
print("V084_UNFINISHED_PROGRAM_MIGRATION_ONE_TIME=PASS")
reset(migration_job)

# A malformed reviewer scratch file is deterministic non-authoritative state:
# rebuild its same-pass skeleton instead of carrying broken JSON into another
# paid retry.
from ownframework_loop import assessment as assessment_mod
assessment_repo = repo("assessment-repair")
assessment_run = "assessment-repair"
target = tmp / "malformed-review-assessment.json"
target.write_text('{"schema":')
orig_path = assessment_mod.assessment_path
orig_build = assessment_mod.build_skeleton
assessment_mod.assessment_path = lambda *_a, **_k: target
assessment_mod.build_skeleton = lambda *_a, **_k: {
    "schema": assessment_mod.SCHEMA_AGENT_ASSESSMENT,
    "run_id": assessment_run,
    "candidate_sha_claimed": "a" * 40,
    "acceptance_results": [{"id": "AC-2", "result": "", "evidence": ""}],
    "non_goal_results": [],
    "findings": [],
    "recommended_verdict": "HUMAN_REVIEW_REQUIRED",
}
try:
    repaired_path = assessment_mod.write_skeleton(
        assessment_repo, assessment_run, source_root=tmp
    )
finally:
    assessment_mod.assessment_path = orig_path
    assessment_mod.build_skeleton = orig_build
repaired = __import__("json").loads(repaired_path.read_text())
assert repaired["acceptance_results"][0]["id"] == "AC-2", repaired
print("MALFORMED_REVIEW_SCRATCH_REBUILT_SAME_PASS=PASS")

# High configured capacity may not create an idle probe storm. The projection
# limits only executor submissions; SQLite claim transactions remain authority.
idle_db = tmp / "idle-budget.sqlite3"
with supervisor._connect(idle_db):
    pass
assert supervisor._scheduler_submission_budget(
    db_path=idle_db, configured=64, local_inflight=0
) == 0
budget_jobs = [
    supervisor.enqueue(
        canonical_repo=repo(f"budget-{i}"),
        run_id=f"budget-{i}",
        db_path=idle_db,
        runtime_generation="test-generation",
    )
    for i in range(3)
]
assert supervisor._scheduler_submission_budget(
    db_path=idle_db, configured=64, local_inflight=0
) == 3
with supervisor._connect(idle_db) as c:
    c.execute(
        "UPDATE jobs SET status='RUNNING', worker_pid=?, worker_started_at=?, worker_role='builder' WHERE id=?",
        (os.getpid(), time.time(), budget_jobs[0]["id"]),
    )
    c.execute("UPDATE jobs SET status='DONE' WHERE id IN (?, ?)", (budget_jobs[1]["id"], budget_jobs[2]["id"]))
    c.commit()
# No free durable slot at configured=1, but the RUNNING row has no local
# Future after a simulated supervisor restart, so one reconciliation probe
# must still be funded.
assert supervisor._scheduler_submission_budget(
    db_path=idle_db, configured=1, local_inflight=0
) == 1
print("HIGH_CAPACITY_BACKGROUND_PROBE_BUDGET=PASS")

print("MODEL_FREE_CONCURRENCY_FAILURES=0")
PY
pass "bounded concurrency, repository exclusion, fairness, draining, hold isolation, and fleet contract"
