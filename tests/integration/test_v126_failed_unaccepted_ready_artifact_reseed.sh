#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"
TMP="$(mktemp -d -t ofloop-v126-ready-reseed.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP
export XDG_STATE_HOME="$TMP/state"
export PYTHONDONTWRITEBYTECODE=1

python3 -B - "$TMP" "$ROOT_DIR" <<'PY'
import hashlib
import json
import subprocess
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[2]) / "tests"))
from _test_support import minimal_valid_packet, write_minimal_valid_packet

from ownframework_loop import build_agent, dispatch, state, supervisor

root = Path(sys.argv[1])
source_root = Path(sys.argv[2])
db_path = root / "supervisor.sqlite3"
scenarios = {}
orders = {}


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args], capture_output=True, text=True,
    )
    if result.returncode:
        raise AssertionError(f"git {args!r} failed: {result.stderr}")
    return result.stdout.strip()


def commit_progress(order: dict, leaf: str) -> str:
    worktree = Path(order["worktree"])
    source = worktree / "src" / leaf
    source.parent.mkdir(parents=True, exist_ok=True)
    source.write_text("VALUE = 'preserved candidate progress'\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(worktree), "add", "src"], check=True)
    subprocess.run(
        ["git", "-C", str(worktree), "-c", "user.name=Loop v126",
         "-c", "user.email=v126@example.invalid", "commit", "-qm", leaf],
        check=True,
    )
    return git(worktree, "rev-parse", "HEAD")


def complete_semantic_result(order: dict) -> dict:
    result = build_agent.build_skeleton(
        Path(order["canonical_repo"]), str(order["run_id"]),
        source_root=source_root,
    )
    result.update({
        "outcome_requested": "candidate_ready",
        "summary": "Fixture builder produced a complete semantic result.",
        "unit_ids_completed": ["UNIT-1"],
        "acceptance_addressed": ["AC-1"],
        "notes": "Deterministic v126 recovery regression fixture.",
    })
    result["evidence"]["files_changed"] = ["src/progress.py"]
    result["evidence"]["diff_lines_total"] = 1
    return result


def write_semantic(order: dict, result: dict) -> bytes:
    path = Path(order["semantic_path"])
    encoded = (json.dumps(result, sort_keys=True, indent=2) + "\n").encode()
    path.write_bytes(encoded)
    return encoded


@supervisor.register_runner
class FailedReadyReseedRunner:
    runner_id = "v126-failed-ready-reseed"
    requires_capability_receipt = False

    def preflight(self):
        return supervisor.RunnerReadiness(True)

    def run(self, work_order, **kwargs):
        run_id = str(work_order["run_id"])
        scenario = scenarios[run_id]
        attempt_id = str(work_order["attempt_id"])
        scenario["calls"].append(attempt_id)

        if scenario["kind"] == "retryable_incomplete":
            if len(scenario["calls"]) == 1:
                scenario["candidate_sha"] = commit_progress(
                    work_order, "progress.py"
                )
                # The semantic result is intentionally incomplete. The normal
                # readiness check will terminalize this paid attempt with the
                # retryable semantic_result_incomplete failure marker.
                incomplete = json.loads(
                    Path(work_order["semantic_path"]).read_text(encoding="utf-8")
                )
                incomplete.update({
                    "outcome_requested": "candidate_ready",
                    "summary": "",
                    "unit_ids_completed": [],
                    "acceptance_addressed": [],
                })
                write_semantic(work_order, incomplete)
                return supervisor.RunnerResult(
                    ok=True, returncode=0, cost_usd=1.25,
                    stdout="incomplete semantic fixture", stderr="",
                    input_tokens=10, output_tokens=5, cache_read_tokens=2,
                    tokens_known=True, cost_known=True,
                    effective_model="fixture-model",
                )

            if len(scenario["calls"]) == 2:
                scenario["fresh_attempt_id"] = attempt_id
                assert attempt_id != scenario["old_attempt_id"]
                assert git(Path(work_order["worktree"]), "rev-parse", "HEAD") == scenario["candidate_sha"]
                assert git(Path(work_order["worktree"]), "status", "--porcelain") == ""

                semantic = Path(work_order["semantic_path"])
                archive = semantic.parent / "rejected-attempts" / f"{scenario['old_attempt_id']}.json"
                receipt_path = semantic.parent / "reseed-receipts" / f"{scenario['old_attempt_id']}.json"
                assert archive.read_bytes() == scenario["ready_bytes"]
                receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
                assert receipt["previous_attempt_id"] == scenario["old_attempt_id"]
                assert receipt["archived_artifact_sha256"] == hashlib.sha256(scenario["ready_bytes"]).hexdigest()
                assert receipt["fresh_skeleton_sha256"] == hashlib.sha256(semantic.read_bytes()).hexdigest()
                ready, reason = dispatch.semantic_result_ready(work_order)
                assert not ready and reason in dispatch._RETRYABLE_SEMANTIC_RESULT_REASONS, (ready, reason)

                current = state.load_verified(Path(work_order["canonical_repo"]), run_id)
                assert (
                    current["build_pass_count"], current["review_pass_count"],
                    current["repair_round"],
                ) == scenario["counts_before"]
                with supervisor._connect_readonly(db_path) as conn:
                    old = conn.execute(
                        "SELECT * FROM semantic_attempts WHERE attempt_id=?",
                        (scenario["old_attempt_id"],),
                    ).fetchone()
                    job = conn.execute("SELECT * FROM jobs WHERE run_id=?", (run_id,)).fetchone()
                    assert old["status"] == "FAILED"
                    assert old["failure_reason"] == "semantic_result_incomplete"
                    assert old["semantic_accepted"] == 0
                    assert old["cost_accounted"] == 1
                    assert old["cost_usd"] == 1.25
                    assert job["total_cost_usd"] == 1.25

                write_semantic(work_order, complete_semantic_result(work_order))
                return supervisor.RunnerResult(
                    ok=True, returncode=0, cost_usd=0.5,
                    stdout="fresh semantic attempt", stderr="",
                    input_tokens=20, output_tokens=7, cache_read_tokens=4,
                    tokens_known=True, cost_known=True,
                    effective_model="fixture-model",
                )

            raise AssertionError(f"unexpected provider call count: {scenario['calls']!r}")

        if scenario["kind"] == "unrelated_failure":
            assert len(scenario["calls"]) == 1
            scenario["candidate_sha"] = commit_progress(work_order, "progress.py")
            write_semantic(work_order, complete_semantic_result(work_order))
            return supervisor.RunnerResult(
                ok=False, returncode=1, cost_usd=0.3,
                stdout="provider failed", stderr="synthetic provider failure",
                input_tokens=3, output_tokens=1, cache_read_tokens=0,
                tokens_known=True, cost_known=True,
                effective_model="fixture-model",
            )

        raise AssertionError(f"unknown fixture scenario: {scenario!r}")


def create_run(name: str, db: Path = db_path) -> tuple[Path, str, dict]:
    repo = root / name
    repo.mkdir()
    subprocess.run(["git", "-C", str(repo), "init", "-q", "-b", "master"], check=True)
    git(repo, "config", "user.name", "Loop v126")
    git(repo, "config", "user.email", "v126@example.invalid")
    (repo / "README.md").write_text("disposable v126 recovery fixture\n", encoding="utf-8")
    git(repo, "add", "README.md")
    git(repo, "commit", "-qm", "fixture baseline")

    created = subprocess.check_output(
        [str(source_root / "bin" / "ofloop"), "spec", "new", str(repo),
         f"v126 {name} recovery fixture"],
        text=True,
    )
    run_id = str(json.loads(created)["run_id"])
    packet = minimal_valid_packet(
        run_id=run_id, canonical_repo=repo, branch="master",
    )
    packet["allowed_paths"] = ["src/"]
    packet["work_units"][0]["scope"] = "src/"
    write_minimal_valid_packet(repo, run_id, branch="master", packet=packet)
    from ownframework_loop import execution_start
    execution_start.ensure_executable(
        canonical_repo=repo, run_id=run_id, actor="v126-test",
        binding_method="build_start",
    )
    enrolled = supervisor.enqueue(
        canonical_repo=repo, run_id=run_id,
        runner=FailedReadyReseedRunner.runner_id, db_path=db,
        max_infra_failures=1,
        runtime_generation=supervisor._current_runtime_generation(),
    )
    assert enrolled.get("ok") is True, enrolled
    order = dispatch.claim_next(canonical_repo=repo, run_id=run_id)
    assert order["decision"] == "BUILD", order
    assert order["role"] == "builder", order
    orders[run_id] = order
    return repo, run_id, order


real_claim = supervisor.dispatch_mod.claim_next
try:
    repo, run_id, order = create_run("retryable-incomplete")
    scenario = {
        "kind": "retryable_incomplete", "calls": [], "candidate_sha": "",
        "old_attempt_id": "", "fresh_attempt_id": "", "ready_bytes": b"",
        "counts_before": (),
    }
    scenarios[run_id] = scenario
    supervisor.dispatch_mod.claim_next = lambda **kwargs: (
        dict(orders[kwargs["run_id"]])
        if kwargs["run_id"] in orders
        else real_claim(**kwargs)
    )

    first = supervisor.run_one(db_path=db_path)
    assert first["status"] == "QUARANTINED", first
    with supervisor._connect_readonly(db_path) as conn:
        job = conn.execute("SELECT * FROM jobs WHERE run_id=?", (run_id,)).fetchone()
        old = conn.execute(
            "SELECT * FROM semantic_attempts WHERE job_id=?", (int(job["id"]),)
        ).fetchone()
        assert old["status"] == "FAILED", dict(old)
        assert old["failure_class"] == "runner", dict(old)
        assert old["failure_reason"] == "semantic_result_incomplete", dict(old)
        assert old["semantic_accepted"] == 0, dict(old)
        assert old["cost_accounted"] == 1 and old["tokens_known"] == 1, dict(old)
        assert old["returncode"] == 0, dict(old)
        scenario["old_attempt_id"] = str(old["attempt_id"])
        assert job["total_cost_usd"] == 1.25, dict(job)

    # Supported operational recovery moves only the quarantined enrollment
    # back to QUEUED; it does not alter engineering pass/repair counters.
    resumed = supervisor.resume(
        canonical_repo=repo, run_id=run_id, db_path=db_path,
    )
    assert resumed.get("resumed") is True, resumed
    current = state.load_verified(repo, run_id)
    scenario["counts_before"] = (
        current["build_pass_count"], current["review_pass_count"],
        current["repair_round"],
    )
    assert scenario["counts_before"] == (1, 0, 0), scenario["counts_before"]

    # Model the live condition: the failed worker's canonical artifact is now
    # structurally ready, but the failed attempt remains unaccepted.
    ready_bytes = write_semantic(order, complete_semantic_result(order))
    scenario["ready_bytes"] = ready_bytes
    ready, ready_reason = dispatch.semantic_result_ready(order)
    assert ready and ready_reason == "ready", (ready, ready_reason)

    second = supervisor.run_one(db_path=db_path)
    assert second["ok"] is True and second["action"] == "BUILD", second
    assert len(scenario["calls"]) == 2, scenario
    assert scenario["fresh_attempt_id"] != scenario["old_attempt_id"]
    assert git(Path(order["worktree"]), "rev-parse", "HEAD") == scenario["candidate_sha"]
    assert git(Path(order["worktree"]), "status", "--porcelain") == ""

    final_state = state.load_verified(repo, run_id)
    assert final_state["state"] == "READY_FOR_REVIEW", final_state
    assert (
        final_state["build_pass_count"], final_state["review_pass_count"],
        final_state["repair_round"],
    ) == scenario["counts_before"], final_state
    receipt = json.loads((repo / ".ownframework-loop" / run_id / "BUILD_RECEIPT.json").read_text())
    assert receipt["validation_status"] == "PASS", receipt
    assert receipt["candidate_sha"] == scenario["candidate_sha"], receipt
    with supervisor._connect_readonly(db_path) as conn:
        job = conn.execute("SELECT * FROM jobs WHERE run_id=?", (run_id,)).fetchone()
        attempts = conn.execute(
            "SELECT * FROM semantic_attempts WHERE job_id=? ORDER BY started_at",
            (int(job["id"]),),
        ).fetchall()
        assert len(attempts) == 2, [dict(row) for row in attempts]
        failed, fresh = attempts
        assert failed["attempt_id"] == scenario["old_attempt_id"]
        assert failed["status"] == "FAILED" and failed["semantic_accepted"] == 0
        assert failed["cost_usd"] == 1.25 and failed["cost_accounted"] == 1
        assert fresh["attempt_id"] == scenario["fresh_attempt_id"]
        assert fresh["status"] == "COMPLETED" and fresh["semantic_accepted"] == 1
        assert fresh["cost_usd"] == 0.5 and fresh["cost_accounted"] == 1
        assert job["total_cost_usd"] == 1.75
        assert job["total_input_tokens"] == 30
        assert job["total_output_tokens"] == 12
        assert job["total_cache_read_tokens"] == 6
    print("FAILED_UNACCEPTED_READY_ARTIFACT_RESEEDED_SAME_PASS=PASS")
    print("FAILED_ATTEMPT_REMAINS_IMMUTABLE_AND_UNACCEPTED=PASS")
    print("RESEED_PRESERVES_CANDIDATE_AND_ENGINEERING_COUNTERS=PASS")
    print("FRESH_ATTEMPT_FINALIZES_WITH_EXACT_ONCE_ACCOUNTING=PASS")

    # Negative control: a ready artifact paired with an unrelated provider
    # failure has no semantic-result retry provenance and must still quarantine.
    negative_db = root / "negative.sqlite3"
    repo2, run_id2, order2 = create_run("unrelated-failure", negative_db)
    scenarios[run_id2] = {
        "kind": "unrelated_failure", "calls": [], "candidate_sha": "",
    }
    failure = supervisor.run_one(db_path=negative_db)
    assert failure["status"] == "QUARANTINED", failure
    with supervisor._connect_readonly(negative_db) as conn:
        job2 = conn.execute("SELECT * FROM jobs WHERE run_id=?", (run_id2,)).fetchone()
        failed2 = conn.execute(
            "SELECT * FROM semantic_attempts WHERE job_id=?", (int(job2["id"]),)
        ).fetchone()
        assert failed2["status"] == "COMPLETED", dict(failed2)
        assert failed2["failure_reason"] != "semantic_result_incomplete", dict(failed2)
        assert failed2["semantic_accepted"] == 0, dict(failed2)
    assert supervisor.resume(
        canonical_repo=repo2, run_id=run_id2, db_path=negative_db,
    ).get("resumed") is True
    ready2, reason2 = dispatch.semantic_result_ready(order2)
    assert ready2 and reason2 == "ready", (ready2, reason2)
    unrecognized = supervisor.run_one(db_path=negative_db)
    assert unrecognized["action"] == "QUARANTINED", unrecognized
    assert unrecognized.get("reason") == "semantic_replay_attempt_not_accepted", unrecognized
    assert len(scenarios[run_id2]["calls"]) == 1, scenarios[run_id2]
    semantic2 = Path(order2["semantic_path"])
    rejected2 = semantic2.parent / "rejected-attempts" / f"{failed2['attempt_id']}.json"
    assert not rejected2.exists(), rejected2
    assert not (semantic2.parent / "reseed-receipts" / f"{failed2['attempt_id']}.json").exists()
    with supervisor._connect_readonly(negative_db) as conn:
        final_failed2 = conn.execute(
            "SELECT * FROM semantic_attempts WHERE attempt_id=?",
            (failed2["attempt_id"],),
        ).fetchone()
        assert final_failed2["status"] == "COMPLETED"
        assert final_failed2["semantic_accepted"] == 0
    print("UNRECOGNIZED_FAILED_ATTEMPT_REMAINS_FAIL_CLOSED=PASS")
finally:
    supervisor.dispatch_mod.claim_next = real_claim

print("FAILED_UNACCEPTED_READY_ARTIFACT_RESEED_REGRESSION=PASS")
PY
