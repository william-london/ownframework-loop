#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
python3 - "$TMP" <<'PY'
import json, sys
from pathlib import Path
from ownframework_loop import supervisor

root=Path(sys.argv[1]); repo=root/"repo"; repo.mkdir()
rd=repo/".ownframework-loop"/"run-cost"; rd.mkdir(parents=True)
(rd/"STATE.json").write_text(json.dumps({"state":"BUILDING"}),encoding="utf-8")
# v0.9.9 admission invariant: enqueue requires a current pre-seal packet.
# Write a minimal valid v3 packet so the attempt-ledger assertion below
# exercises ledger accounting, not admission.
minimal_packet = {
    "schema": "ownframework-work-packet/v3",
    "packet_id": "v061-attempt-ledger-fixture",
    "created_at": "2026-09-17T00:00:00Z",
    "work_class": "FEATURE",
    "risk_class": "low",
    "title": "v061 attempt ledger fixture",
    "target": {"repo": str(repo), "branch": "master", "classification": "local_only"},
    "execution_mode": "single",
    "acceptance_criteria": [{"id": "AC-1", "text": "ok"}],
    "non_goals": [],
    "allowed_paths": ["a.txt"],
    "protected_paths": [".ownframework-loop/"],
    "work_units": [{"id": "UNIT-1", "title": "u", "scope": "do"}],
    "merge_authority": "human_only",
    "deploy_authority": "human_only",
    "push_authority": "human_only",
    "external_action_authority": "none",
    "risk_budget": {"max_build_passes": 5, "max_review_passes": 5, "max_repair_rounds": 1,
                    "max_files_changed": 5, "max_diff_lines": 100},
}
fence = chr(96) * 3
(rd / "WORK_PACKET.md").write_text(
    fence + "json\n" + json.dumps(minimal_packet) + "\n" + fence + "\n", encoding="utf-8"
)
db=root/"s.sqlite3"
supervisor.enqueue(canonical_repo=repo,run_id="run-cost",db_path=db,max_total_cost_usd=20)

def make_running():
    with supervisor._connect(db) as c:
        c.execute("""UPDATE jobs SET status='RUNNING', worker_pid=NULL,
                     worker_started_at=NULL, worker_role='dispatching'
                     WHERE run_id='run-cost'""")
        c.commit()
        return c.execute("SELECT * FROM jobs WHERE run_id='run-cost'").fetchone()

# Two distinct attempts with identical hypothetical output are both charged.
with supervisor._connect(db) as c:
    job=make_running()
    a1,logs1=supervisor._reserve_semantic_attempt(c,job=job,role="builder")
    total=supervisor._account_attempt_cost(c,job_id=job["id"],attempt_id=a1,cost_usd=1.25,returncode=0)
assert total==1.25
with supervisor._connect(db) as c:
    job=make_running()
    a2,logs2=supervisor._reserve_semantic_attempt(c,job=job,role="builder")
    total=supervisor._account_attempt_cost(c,job_id=job["id"],attempt_id=a2,cost_usd=1.25,returncode=0)
assert a1!=a2 and logs1!=logs2
assert total==2.5

# Re-accounting the SAME attempt is idempotent.
with supervisor._connect(db) as c:
    total2=supervisor._account_attempt_cost(c,job_id=job["id"],attempt_id=a2,cost_usd=1.25,returncode=0)
assert total2==2.5

# Crash after durable provider output but before parent accounting recovers cost.
with supervisor._connect(db) as c:
    job=make_running()
    a3,logs3=supervisor._reserve_semantic_attempt(c,job=job,role="reviewer")
    logs3[0].parent.mkdir(parents=True,exist_ok=True)
    logs3[0].write_text(json.dumps({"total_cost_usd":2.0,"is_error":False}),encoding="utf-8")
    # Provider output is only possible after gated release, which requires
    # durable worker ownership. Publish the attempt through the real ownership
    # helper, then use a non-live PID to model worker death before accounting.
    supervisor._set_worker_pid(
        c, int(job["id"]), 99999999, "reviewer",
        out_path=logs3[0], err_path=logs3[1], attempt_id=a3,
    )
    recovered=supervisor._recover_stale_running(c)
assert recovered==1
s=supervisor.status(canonical_repo=repo,run_id="run-cost",db_path=db)
assert s["status"]=="QUEUED",s
assert abs(s["total_cost_usd"]-4.5)<1e-9,s
assert s["latest_attempt_id"]==a3
assert s["latest_attempt"]["cost_accounted"]==1,s

# A dead attempt whose provider cost cannot be reconstructed quarantines.
with supervisor._connect(db) as c:
    job=make_running()
    a4,logs4=supervisor._reserve_semantic_attempt(c,job=job,role="builder")
    logs4[0].parent.mkdir(parents=True,exist_ok=True)
    logs4[0].write_text("not-json",encoding="utf-8")
    supervisor._set_worker_pid(
        c, int(job["id"]), 99999998, "builder",
        out_path=logs4[0], err_path=logs4[1], attempt_id=a4,
    )
    recovered=supervisor._recover_stale_running(c)
assert recovered==0
s=supervisor.status(canonical_repo=repo,run_id="run-cost",db_path=db)
assert s["status"]=="QUARANTINED",s
assert "cost could not be recovered" in (s["last_error"] or ""),s
PY
echo "V061_SUPERVISOR_ATTEMPT_LEDGER=PASS"
