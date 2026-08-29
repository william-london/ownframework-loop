#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$TMP" <<'PY'
import json
import sys
from pathlib import Path
from ownframework_loop import supervisor

root = Path(sys.argv[1])
repo = root / "repo"
repo.mkdir()
rd = repo / ".ownframework-loop" / "run-policy"
rd.mkdir(parents=True)
(rd / "STATE.json").write_text(json.dumps({"state": "BUILDING"}), encoding="utf-8")
db = root / "supervisor.sqlite3"

s = supervisor.enqueue(
    canonical_repo=repo,
    run_id="run-policy",
    db_path=db,
    max_infra_failures=2,
    max_transient_failures=3,
    max_total_cost_usd=50,
    max_total_tokens=10000,
)
assert s["max_transient_failures"] == 3, s
assert s["max_total_tokens"] == 10000, s

# Classification changes retry policy only; it does not interpret engineering state.
transient = supervisor.RunnerResult(
    ok=False, returncode=1, cost_usd=0.1,
    stdout="", stderr="HTTP 429 rate limit; temporarily unavailable",
)
configuration = supervisor.RunnerResult(
    ok=False, returncode=127, cost_usd=0.0,
    stdout="", stderr="command not found",
)
ordinary = supervisor.RunnerResult(
    ok=False, returncode=1, cost_usd=0.2,
    stdout="", stderr="runner exited without a valid result envelope",
)
assert supervisor._classify_runner_failure(transient)[0] == "transient"
assert supervisor._classify_runner_failure(configuration)[0] == "configuration"
assert supervisor._classify_runner_failure(ordinary)[0] == "runner"

# Token + cost usage are exactly-once under attempt identity.
with supervisor._connect(db) as conn:
    conn.execute(
        "UPDATE jobs SET status='RUNNING', worker_role='dispatching' WHERE run_id='run-policy'"
    )
    conn.commit()
    job = conn.execute("SELECT * FROM jobs WHERE run_id='run-policy'").fetchone()
    attempt_id, _ = supervisor._reserve_semantic_attempt(conn, job=job, role="builder")
    total = supervisor._account_attempt_cost(
        conn,
        job_id=job["id"],
        attempt_id=attempt_id,
        cost_usd=1.25,
        returncode=0,
        input_tokens=100,
        output_tokens=50,
        cache_read_tokens=25,
        cache_creation_tokens=10,
        tokens_known=True,
    )
assert total == 1.25
with supervisor._connect(db) as conn:
    total2 = supervisor._account_attempt_cost(
        conn,
        job_id=job["id"],
        attempt_id=attempt_id,
        cost_usd=1.25,
        returncode=0,
        input_tokens=100,
        output_tokens=50,
        cache_read_tokens=25,
        cache_creation_tokens=10,
        tokens_known=True,
    )
assert total2 == 1.25
s = supervisor.status(canonical_repo=repo, run_id="run-policy", db_path=db)
assert s["observed_total_tokens"] == 185, s
assert s["total_input_tokens"] == 100 and s["total_output_tokens"] == 50, s
assert len(s["attempt_history"]) == 1, s
assert s["attempt_history"][0]["tokens_known"] == 1, s

# Transient failures get their own more generous streak.
for expected_status, expected_count in (("BACKOFF", 1), ("BACKOFF", 2), ("QUARANTINED", 3)):
    with supervisor._connect(db) as conn:
        conn.execute(
            "UPDATE jobs SET status='RUNNING', worker_pid=NULL, worker_started_at=NULL WHERE run_id='run-policy'"
        )
        conn.commit()
        job = conn.execute("SELECT * FROM jobs WHERE run_id='run-policy'").fetchone()
        policy = supervisor._apply_failure_policy(
            conn,
            job_id=job["id"],
            failure_class="transient",
            failure_reason="runner_transient_failure",
            detail="provider rate limited request",
        )
    assert policy["status"] == expected_status, policy
    assert policy["transient_failures"] == expected_count, policy
    assert policy["infra_failures"] == 0, policy

s = supervisor.status(canonical_repo=repo, run_id="run-policy", db_path=db)
assert s["status"] == "QUARANTINED", s
assert s["quarantine_reason"] == "runner_transient_failure", s

# Resume resets operational streaks only and can tune new ceilings.
res = supervisor.resume(
    canonical_repo=repo,
    run_id="run-policy",
    db_path=db,
    max_transient_failures=9,
    max_total_tokens=50000,
)
assert res["resumed"] is True and res["status"] == "QUEUED", res
assert res["infra_failures"] == 0 and res["transient_failures"] == 0, res
assert res["max_transient_failures"] == 9, res
assert res["max_total_tokens"] == 50000, res

# Configuration failures quarantine immediately and do not masquerade as a streak.
with supervisor._connect(db) as conn:
    conn.execute("UPDATE jobs SET status='RUNNING' WHERE run_id='run-policy'")
    conn.commit()
    job = conn.execute("SELECT * FROM jobs WHERE run_id='run-policy'").fetchone()
    policy = supervisor._apply_failure_policy(
        conn,
        job_id=job["id"],
        failure_class="configuration",
        failure_reason="runner_configuration_failure",
        detail="missing runner executable",
    )
assert policy["status"] == "QUARANTINED", policy
assert policy["infra_failures"] == 0 and policy["transient_failures"] == 0, policy
s = supervisor.status(canonical_repo=repo, run_id="run-policy", db_path=db)
assert s["last_failure_class"] == "configuration", s
assert s["quarantine_reason"] == "runner_configuration_failure", s

# Operator visibility must show the isolated candidate instead of implying the
# canonical checkout should contain its diff.
import subprocess

vrepo = root / "visibility-repo"
vrepo.mkdir()
subprocess.run(["git", "-C", str(vrepo), "init", "-b", "master"], check=True, capture_output=True)
subprocess.run(["git", "-C", str(vrepo), "config", "user.email", "test@example.com"], check=True)
subprocess.run(["git", "-C", str(vrepo), "config", "user.name", "Loop Test"], check=True)
(vrepo / "baseline.txt").write_text("baseline\n", encoding="utf-8")
subprocess.run(["git", "-C", str(vrepo), "add", "baseline.txt"], check=True)
subprocess.run(["git", "-C", str(vrepo), "commit", "-m", "baseline"], check=True, capture_output=True)
baseline = subprocess.run(
    ["git", "-C", str(vrepo), "rev-parse", "HEAD"],
    check=True, capture_output=True, text=True,
).stdout.strip()

vrun = "run-visibility"
vbranch = f"factory/candidate/{vrun}"
vrd = vrepo / ".ownframework-loop" / vrun
vrd.mkdir(parents=True)
builder = vrepo / ".worktrees" / "ownframework-loop" / vrun / "builder"
builder.parent.mkdir(parents=True)
subprocess.run(
    ["git", "-C", str(vrepo), "worktree", "add", "-b", vbranch, str(builder), baseline],
    check=True, capture_output=True,
)
(builder / "feature.txt").write_text("candidate\n", encoding="utf-8")
subprocess.run(["git", "-C", str(builder), "add", "feature.txt"], check=True)
subprocess.run(["git", "-C", str(builder), "commit", "-m", "candidate"], check=True, capture_output=True)
candidate = subprocess.run(
    ["git", "-C", str(builder), "rev-parse", "HEAD"],
    check=True, capture_output=True, text=True,
).stdout.strip()
(vrd / "STATE.json").write_text(
    json.dumps({
        "state": "READY_FOR_REVIEW",
        "last_candidate_sha": candidate,
        "build_pass_count": 1,
        "review_pass_count": 0,
        "repair_round": 0,
        "spec_baseline_sha": baseline,
    }),
    encoding="utf-8",
)
(vrd / "BUILD_RECEIPT.json").write_text(
    json.dumps({
        "candidate_sha": candidate,
        "baseline_sha": baseline,
        "candidate_branch": vbranch,
    }),
    encoding="utf-8",
)
(vrd / "APPROVAL.json").write_text(
    json.dumps({
        "baseline_sha": baseline,
        "candidate_branch": vbranch,
    }),
    encoding="utf-8",
)
vdb = root / "visibility.sqlite3"
supervisor.enqueue(canonical_repo=vrepo, run_id=vrun, db_path=vdb)
visible = supervisor.status(canonical_repo=vrepo, run_id=vrun, db_path=vdb)
assert visible["canonical_checkout"]["head"] == baseline, visible
assert visible["candidate_is_canonical_head"] is False, visible
assert visible["candidate_branch"] == vbranch, visible
assert visible["builder_worktree"]["exists"] is True, visible
assert visible["builder_worktree"]["registered"] is True, visible
assert visible["builder_worktree"]["head"] == candidate, visible
assert visible["builder_worktree"]["branch"] == vbranch, visible
assert visible["builder_worktree"]["cleanliness"] == "clean", visible
assert visible["reviewer_worktree"]["exists"] is False, visible
assert visible["candidate_diff"]["available"] is True, visible
assert visible["candidate_diff"]["files_changed"] == 1, visible
assert visible["candidate_diff"]["changed_paths"] == ["feature.txt"], visible
assert visible["candidate_diff"]["added_lines"] == 1, visible
assert visible["visibility_errors"] == [], visible

print("V061_SUPERVISOR_RETRY_USAGE_POLICY=PASS")
PY
