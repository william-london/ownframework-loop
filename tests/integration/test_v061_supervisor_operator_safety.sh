#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
python3 - "$TMP" <<'PY'
import json, sqlite3, sys
from pathlib import Path
from ownframework_loop import supervisor

root=Path(sys.argv[1])
repo=root/"repo"; repo.mkdir()
(repo/".ownframework-loop"/"run-safe").mkdir(parents=True)
(repo/".ownframework-loop"/"run-safe"/"STATE.json").write_text(
    json.dumps({"state":"BUILDING","build_pass_count":1}), encoding="utf-8")
# v0.9.9 admission invariant: enqueue requires a current pre-seal packet.
# Write a minimal valid v3 packet so the operator-safety assertion below
# exercises durable enqueue, not admission.
minimal_packet = {
    "schema": "ownframework-work-packet/v3",
    "packet_id": "v061-operator-safety-fixture",
    "created_at": "2026-09-17T00:00:00Z",
    "work_class": "FEATURE",
    "risk_class": "low",
    "title": "v061 operator safety fixture",
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
(repo / ".ownframework-loop" / "run-safe" / "WORK_PACKET.md").write_text(
    fence + "json\n" + json.dumps(minimal_packet) + "\n" + fence + "\n", encoding="utf-8"
)
db=root/"supervisor.sqlite3"

first=supervisor.enqueue(canonical_repo=repo,run_id="run-safe",db_path=db,
                         max_total_cost_usd=25,max_wall_seconds=100)
assert first["status"]=="QUEUED"

# Adapter availability is not durable-runner availability. Refuse an
# unregistered runner before creating or mutating a durable enrollment.
unsupported=supervisor.enqueue(
    canonical_repo=repo,run_id="run-unsupported",runner="codex",db_path=db)
assert unsupported["ok"] is False and unsupported["enqueue_refused"] is True, unsupported
assert unsupported["reason"]=="runner_not_registered", unsupported
assert unsupported["runner"]=="codex", unsupported
assert unsupported["live_runners"]==["claude-code"], unsupported
with supervisor._connect(db) as conn:
    assert conn.execute(
        "SELECT COUNT(*) FROM jobs WHERE run_id='run-unsupported'"
    ).fetchone()[0] == 0
with supervisor._connect(db) as conn:
    conn.execute("""UPDATE jobs SET status='RUNNING', worker_pid=424242,
                    worker_started_at=123, worker_role='builder',
                    next_attempt_at=99 WHERE run_id='run-safe'""")
    conn.commit()
# Re-enqueue must preserve operational ownership/backoff state.
again=supervisor.enqueue(canonical_repo=repo,run_id="run-safe",db_path=db,
                         max_total_cost_usd=40,max_wall_seconds=200)
assert again["status"]=="RUNNING", again
assert again["worker_pid"]==424242, again
assert again["worker_role"]=="builder", again
assert again["next_attempt_at"]==99, again
assert again["max_total_cost_usd"]==40, again

# Resume against RUNNING must not mutate any operational or budget field.
before=dict(again)
res=supervisor.resume(canonical_repo=repo,run_id="run-safe",db_path=db,
                      max_total_cost_usd=999,max_wall_seconds=999)
assert res["ok"] is False and res["resumed"] is False, res
assert res["reason"]=="resume_requires_quarantined", res
after=supervisor.status(canonical_repo=repo,run_id="run-safe",db_path=db)
for key in ("status","worker_pid","worker_role","next_attempt_at",
            "max_total_cost_usd","max_wall_seconds","execution_started_at"):
    assert after.get(key)==before.get(key), (key,before.get(key),after.get(key))

# Quarantine may resume and apply new operational ceilings.
with supervisor._connect(db) as conn:
    conn.execute("""UPDATE jobs SET status='QUARANTINED', worker_pid=NULL,
                    worker_started_at=NULL, worker_role=NULL,
                    infra_failures=3 WHERE run_id='run-safe'""")
    conn.commit()
res=supervisor.resume(canonical_repo=repo,run_id="run-safe",db_path=db,
                      max_total_cost_usd=50,max_wall_seconds=300)
assert res["ok"] is True and res["resumed"] is True, res
assert res["status"]=="QUEUED" and res["infra_failures"]==0, res
assert res["max_total_cost_usd"]==50 and res["max_wall_seconds"]==300, res

# Status must surface malformed core evidence rather than hide it.
(repo/".ownframework-loop"/"run-safe"/"STATE.json").write_text("{bad",encoding="utf-8")
snap=supervisor.status(canonical_repo=repo,run_id="run-safe",db_path=db)
assert snap["core_snapshot_ok"] is False, snap
assert any(x.startswith("STATE.json:") for x in snap["core_snapshot_errors"]), snap
PY
echo "V061_SUPERVISOR_OPERATOR_SAFETY=PASS"
