#!/usr/bin/env bash
# v0.9.1 final-frontier seam regression: TOKENS_UNKNOWN terminalization.
#
# A semantic attempt that completes (live or via crash recovery) with a
# token ceiling enabled but no provable token usage is terminalized as
# TOKENS_UNKNOWN. That terminalization must still account the attempt
# exactly once:
#   * a PROVEN provider cost must land in jobs.total_cost_usd (a funded
#     cost ceiling would otherwise under-count spend across the
#     quarantine/resume cycle);
#   * an UNPROVEN provider cost must record honest cost_known=0 and be
#     counted by the historical-cost gate, so a later funded cost ceiling
#     fails closed instead of resuming from an unknown baseline.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib"

python3 -B - "$ROOT_DIR" <<'PY'
import json
import sys
import tempfile
from pathlib import Path

from ownframework_loop import supervisor

root = Path(sys.argv[1])
tmp = Path(tempfile.mkdtemp(prefix="ofloop-tokens-unknown-"))


def new_repo(name: str) -> Path:
    p = tmp / name
    p.mkdir(parents=True, exist_ok=True)
    return p


def wire_dispatch(repo: Path, run_id: str) -> None:
    supervisor.dispatch_mod.claim_next = lambda **kwargs: {
        "decision": "BUILD",
        "role": "builder",
        "canonical_repo": str(repo),
        "run_id": run_id,
        "worktree": str(repo),
        "semantic_path": str(repo / "result.json"),
    }
    supervisor.dispatch_mod.semantic_result_ready = lambda wo: (False, "missing")


real_claim = supervisor.dispatch_mod.claim_next
real_ready = supervisor.dispatch_mod.semantic_result_ready
real_parse = supervisor.packet_mod.parse_packet_file

# ------------------------------------------------------------------
# T-01: live TOKENS_UNKNOWN with a PROVEN cost. The completed attempt
# must be accounted exactly once before quarantine: the proven cost
# lands in the durable ledger and cost_known stays honestly true.
# ------------------------------------------------------------------
@supervisor.register_runner
class TokensKnownCost:
    runner_id = "tokens-known-cost"

    def preflight(self):
        return supervisor.RunnerReadiness(True)

    def run(self, work_order, *, timeout_seconds=30, on_start=None, durable_files=None):
        return supervisor.RunnerResult(
            ok=True, returncode=0, cost_usd=0.42,
            stdout="", stderr="", cost_known=True, tokens_known=False,
        )


db1 = tmp / "tokens-known-cost.sqlite3"
repo1 = new_repo("tokens-known-cost")
run1 = "run-tokens-known-cost"
supervisor.enqueue(
    canonical_repo=repo1, run_id=run1, db_path=db1,
    runner="tokens-known-cost", max_total_tokens=1000,
)
wire_dispatch(repo1, run1)
supervisor.packet_mod.parse_packet_file = lambda path: ({}, "")
try:
    out1 = supervisor.run_one(db_path=db1)
finally:
    supervisor.dispatch_mod.claim_next = real_claim
    supervisor.dispatch_mod.semantic_result_ready = real_ready
    supervisor.packet_mod.parse_packet_file = real_parse
assert out1["action"] == "QUARANTINED", out1
assert out1["reason"] == "token_usage_unknown", out1
with supervisor._connect_readonly(db1) as conn:
    j1 = conn.execute("SELECT * FROM jobs WHERE run_id=?", (run1,)).fetchone()
    a1 = conn.execute(
        "SELECT * FROM semantic_attempts WHERE job_id=?", (int(j1["id"]),)
    ).fetchone()
assert j1["status"] == "QUARANTINED", dict(j1)
assert abs(float(j1["total_cost_usd"]) - 0.42) < 1e-9, dict(j1)
assert a1["status"] == "TOKENS_UNKNOWN", dict(a1)
assert int(a1["cost_accounted"]) == 1, dict(a1)
assert abs(float(a1["cost_usd"]) - 0.42) < 1e-9, dict(a1)
assert int(a1["cost_known"]) == 1, dict(a1)
assert int(a1["tokens_known"]) == 0, dict(a1)
assert a1["failure_class"] == "usage_unknown", dict(a1)
assert a1["failure_reason"] == "token_usage_unknown", dict(a1)
print("T01_TOKENS_UNKNOWN_ACCOUNTS_PROVEN_COST=yes")

# ------------------------------------------------------------------
# T-02: live TOKENS_UNKNOWN with an UNPROVEN cost. The attempt must
# record cost_known=0, and a later funded cost ceiling (set on resume)
# must fail closed on the historical uncertainty instead of resuming
# from an unknown baseline.
# ------------------------------------------------------------------
@supervisor.register_runner
class TokensUnknownCost:
    runner_id = "tokens-unknown-cost"
    invoked = 0

    def preflight(self):
        return supervisor.RunnerReadiness(True)

    def run(self, work_order, *, timeout_seconds=30, on_start=None, durable_files=None):
        TokensUnknownCost.invoked += 1
        return supervisor.RunnerResult(
            ok=True, returncode=0, cost_usd=0.0,
            stdout="", stderr="", cost_known=False, tokens_known=False,
        )


db2 = tmp / "tokens-unknown-cost.sqlite3"
repo2 = new_repo("tokens-unknown-cost")
run2 = "run-tokens-unknown-cost"
supervisor.enqueue(
    canonical_repo=repo2, run_id=run2, db_path=db2,
    runner="tokens-unknown-cost", max_total_tokens=1000,
)
wire_dispatch(repo2, run2)
supervisor.packet_mod.parse_packet_file = lambda path: ({}, "")
try:
    out2 = supervisor.run_one(db_path=db2)
finally:
    supervisor.dispatch_mod.claim_next = real_claim
    supervisor.dispatch_mod.semantic_result_ready = real_ready
    supervisor.packet_mod.parse_packet_file = real_parse
assert out2["action"] == "QUARANTINED", out2
assert out2["reason"] == "token_usage_unknown", out2
with supervisor._connect_readonly(db2) as conn:
    j2 = conn.execute("SELECT * FROM jobs WHERE run_id=?", (run2,)).fetchone()
    a2 = conn.execute(
        "SELECT * FROM semantic_attempts WHERE job_id=?", (int(j2["id"]),)
    ).fetchone()
    unknown2 = supervisor._unknown_cost_attempt_count(conn, int(j2["id"]))
assert a2["status"] == "TOKENS_UNKNOWN", dict(a2)
assert int(a2["cost_accounted"]) == 1, dict(a2)
assert int(a2["cost_known"]) == 0, dict(a2)
assert unknown2 == 1, unknown2
print("T02_TOKENS_UNKNOWN_RECORDS_HONEST_UNKNOWN_COST=yes")

resumed2 = supervisor.resume(
    canonical_repo=repo2, run_id=run2, db_path=db2, max_total_cost_usd=5.0,
)
assert resumed2.get("resumed") is True, resumed2
invocations_before = TokensUnknownCost.invoked
wire_dispatch(repo2, run2)
supervisor.packet_mod.parse_packet_file = lambda path: ({}, "")
try:
    out2b = supervisor.run_one(db_path=db2)
finally:
    supervisor.dispatch_mod.claim_next = real_claim
    supervisor.dispatch_mod.semantic_result_ready = real_ready
    supervisor.packet_mod.parse_packet_file = real_parse
assert out2b["action"] == "QUARANTINED", out2b
assert out2b["reason"] == "historical_cost_unknown", out2b
assert TokensUnknownCost.invoked == invocations_before, (
    "runner executed despite historical unknown cost under a funded ceiling"
)
print("T02_LATER_COST_CEILING_FAILS_CLOSED_ON_TOKENS_UNKNOWN=yes")

# ------------------------------------------------------------------
# T-03: crash-recovery TOKENS_UNKNOWN. A dead worker whose durable
# envelope proves cost but not usage, under a token ceiling, must be
# recovered with the proven cost accounted exactly once.
# ------------------------------------------------------------------
db3 = tmp / "tokens-recovery.sqlite3"
repo3 = new_repo("tokens-recovery")
run3 = "run-tokens-recovery"
supervisor.enqueue(
    canonical_repo=repo3, run_id=run3, db_path=db3, max_total_tokens=1000,
)
with supervisor._connect(db3) as conn:
    conn.execute(
        "UPDATE jobs SET status='RUNNING', worker_pid=99999999, "
        "worker_started_at=1, worker_pgid=99999999, worker_deadline_at=1 "
        "WHERE run_id=?",
        (run3,),
    )
    conn.commit()
    job3 = conn.execute("SELECT * FROM jobs WHERE run_id=?", (run3,)).fetchone()
    attempt3, logs3 = supervisor._reserve_semantic_attempt(
        conn, job=job3, role="builder"
    )
    conn.execute(
        "UPDATE semantic_attempts SET status='RUNNING', worker_pid=99999999, "
        "worker_pgid=99999999, deadline_at=1 WHERE attempt_id=?",
        (attempt3,),
    )
    conn.commit()
# Durable provider envelope: proven cost, no usage record.
Path(logs3[0]).write_text(
    json.dumps({"is_error": False, "total_cost_usd": 0.77, "result": "ok"}),
    encoding="utf-8",
)
with supervisor._connect(db3) as conn:
    recovered3 = supervisor._recover_stale_running(conn)
assert recovered3 == 0, recovered3
with supervisor._connect_readonly(db3) as conn:
    j3 = conn.execute("SELECT * FROM jobs WHERE run_id=?", (run3,)).fetchone()
    a3 = conn.execute(
        "SELECT * FROM semantic_attempts WHERE attempt_id=?", (attempt3,)
    ).fetchone()
assert j3["status"] == "QUARANTINED", dict(j3)
assert j3["last_failure_reason"] == "token_usage_unknown_during_crash_recovery", dict(j3)
assert abs(float(j3["total_cost_usd"]) - 0.77) < 1e-9, dict(j3)
assert a3["status"] == "TOKENS_UNKNOWN", dict(a3)
assert int(a3["cost_accounted"]) == 1, dict(a3)
assert abs(float(a3["cost_usd"]) - 0.77) < 1e-9, dict(a3)
assert int(a3["cost_known"]) == 1, dict(a3)
assert int(a3["tokens_known"]) == 0, dict(a3)
print("T03_CRASH_RECOVERY_TOKENS_UNKNOWN_ACCOUNTS_PROVEN_COST=yes")
PY

echo "OK: test_v091_tokens_unknown_accounting.sh"
