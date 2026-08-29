#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$TMP" <<'PY'
import json
import os
import sys
from pathlib import Path

from ownframework_loop import supervisor

root = Path(sys.argv[1])
repo = root / "repo"
repo.mkdir()
rd = repo / ".ownframework-loop" / "run-auto"
rd.mkdir(parents=True)
(rd / "STATE.json").write_text(json.dumps({"state": "BUILDING"}), encoding="utf-8")
# run_one resolves the per-pass timeout from the packet; a real run always
# carries WORK_PACKET.md, so the fixture provides a minimal parseable one.
(rd / "WORK_PACKET.md").write_text(
    "```json\n"
    + json.dumps({"schema": "ownframework-work-packet/v2",
                  "execution_mode": "single", "risk_budget": {}})
    + "\n```\n",
    encoding="utf-8",
)
semantic = rd / "BUILD_AGENT_RESULT.json"
semantic.write_text("{}", encoding="utf-8")
db = root / "supervisor.sqlite3"

# T1: no pinned runner + no PATH Claude is a retryable environment wait.
old_path = os.environ.get("PATH", "")
old_pinned = os.environ.pop("OFLOOP_CLAUDE_BIN", None)
os.environ["PATH"] = str(root / "empty-path")
readiness = supervisor.ClaudeCodeRunner().preflight()
assert readiness.ready is False, readiness
assert readiness.classification == "environment_wait", readiness
assert readiness.reason == "runner_not_discoverable", readiness
os.environ["PATH"] = old_path
if old_pinned is not None:
    os.environ["OFLOOP_CLAUDE_BIN"] = old_pinned

# T2/T3: unavailable runner waits without attempt/counter/clock, then
# progresses automatically after readiness changes, without resume.
class WaitThenReadyRunner:
    runner_id = "wait-then-ready"
    ready = False
    calls = 0

    def preflight(self):
        if not self.ready:
            return supervisor.RunnerReadiness(
                False,
                classification="environment_wait",
                reason="synthetic_runner_missing",
                detail="synthetic runner temporarily unavailable",
                retry_after_seconds=5,
            )
        return supervisor.RunnerReadiness(True)

    def run(self, work_order, **kwargs):
        type(self).calls += 1
        return supervisor.RunnerResult(
            ok=True,
            returncode=0,
            cost_usd=0.25,
            cost_known=True,
            tokens_known=True,
            input_tokens=10,
            output_tokens=5,
            stdout='{"is_error":false,"total_cost_usd":0.25}',
            stderr="",
        )

supervisor.register_runner(WaitThenReadyRunner)
runner = supervisor._runner("wait-then-ready")

order = {
    "schema": supervisor.dispatch_mod.SCHEMA,
    "decision": "BUILD",
    "role": "builder",
    "run_id": "run-auto",
    "state": "BUILDING",
    "replayed": False,
    "canonical_repo": str(repo),
    "worktree": str(repo),
    "semantic_path": str(semantic),
}

supervisor.dispatch_mod.claim_next = lambda **kwargs: dict(order)
supervisor.dispatch_mod.semantic_result_ready = lambda work_order: (False, "builder_summary_empty")
supervisor.dispatch_mod.finalize_work_order = lambda work_order: {"ok": True, "finalized": True}

supervisor.enqueue(
    canonical_repo=repo,
    run_id="run-auto",
    runner="wait-then-ready",
    db_path=db,
    max_wall_seconds=60,
)

first = supervisor.run_one(db_path=db)
assert first["action"] == "RUNNER_WAIT", first
assert first["semantic_attempt_created"] is False, first
assert first["execution_clock_started"] is False, first
status = supervisor.status(canonical_repo=repo, run_id="run-auto", db_path=db)
assert status["status"] == "BACKOFF", status
assert status["infra_failures"] == 0, status
assert status["transient_failures"] == 0, status
assert status["execution_started_at"] is None, status
assert status["attempt_history"] == [], status
assert WaitThenReadyRunner.calls == 0

# Make the same runner available and expire only its operational backoff.
runner.ready = True
with supervisor._connect(db) as conn:
    conn.execute("UPDATE jobs SET next_attempt_at=0 WHERE run_id='run-auto'")
    conn.commit()

second = supervisor.run_one(db_path=db)
assert second["action"] == "BUILD", second
assert WaitThenReadyRunner.calls == 1
status2 = supervisor.status(canonical_repo=repo, run_id="run-auto", db_path=db)
assert status2["execution_started_at"] is not None, status2
assert len(status2["attempt_history"]) == 1, status2
assert status2["infra_failures"] == 0, status2
assert status2["transient_failures"] == 0, status2

# T4: pinned runner authority never silently falls back.
missing = root / "missing-commissioned-claude"
os.environ["OFLOOP_CLAUDE_BIN"] = str(missing)
pinned = supervisor.ClaudeCodeRunner().preflight()
assert pinned.ready is False, pinned
assert pinned.classification == "configuration", pinned
assert pinned.reason == "pinned_runner_unavailable", pinned
os.environ.pop("OFLOOP_CLAUDE_BIN", None)

print("V061_SUPERVISOR_AUTONOMY_FRICTION=PASS")
PY
