#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib:$ROOT_DIR/tests/helpers${PYTHONPATH:+:$PYTHONPATH}"
export OFLOOP_LIB="$ROOT_DIR/lib"
TMP="$(mktemp -d -t ofloop-v125-rollover-wall.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

python3 -B - "$TMP" "$ROOT_DIR" "$OFLOOP_BIN" <<'PY'
import hashlib
import json
import os
import pty
import select
import subprocess
import sys
import time
from pathlib import Path

root = Path(sys.argv[1])
source_root = Path(sys.argv[2])
ofloop_bin = sys.argv[3]
os.environ["XDG_STATE_HOME"] = str(root / "state")
repo = root / "repo"
repo.mkdir()
db_path = root / "state" / "ownframework-loop" / "supervisor.sqlite3"

from ownframework_loop import (
    approval, assessment, build_agent, build_finalize, build_prepare,
    capabilities, capability_binding,
    execution_start, git_checks, integrity, packet, program,
    program_rollover, receipts, review_finalize, review_prepare, state,
    runner_profiles, runtime_env, supervisor, supervisor_db, util, verdicts,
    worktrees,
)


class RolloverFixtureRunner:
    runner_id = "v125-rollover-fixture"

    def run(self, *args, **kwargs):
        raise AssertionError("fixture runner must not launch provider work")


supervisor.register_runner(RolloverFixtureRunner)


def git(*args):
    result = subprocess.run(
        ["git", "-C", str(repo), *args], capture_output=True, text=True,
    )
    if result.returncode:
        raise AssertionError(f"git {args!r} failed: {result.stderr}")
    return result.stdout.strip()


git("init", "-q", "-b", "master")
git("config", "user.name", "Loop v125 fixture")
git("config", "user.email", "loop-v125@example.invalid")
(repo / ".git" / "info" / "exclude").write_text(
    "/.ownframework-loop/\n/.worktrees/ownframework-loop/\n",
    encoding="utf-8",
)
(repo / "README.md").write_text("disposable rollover parent fixture\n", encoding="utf-8")
git("add", "README.md")
git("commit", "-qm", "fixture baseline")
baseline = git("rev-parse", "HEAD")
parent = "run-20260928T000000Z-v125parent"
run_root = state.run_dir(repo, parent)
run_root.mkdir(parents=True)
cp0_validation = {
    "name": "builder-worktree-only",
    "command": 'test "$(basename "$PWD")" = builder',
    "kind": "fast",
    "expected_exit_code": 0,
}
meta = {
    "schema": "ownframework-work-packet/v3",
    "packet_id": "v125-real-rollover-parent",
    "created_at": "2026-09-28T00:00:00Z",
    "work_class": "FEATURE",
    "risk_class": "low",
    "title": "real rollover wall-clock replay fixture",
    "runner_profile": "default",
    "target": {
        "repo": str(repo.resolve()), "branch": "master",
        "classification": "local_only", "expected_baseline_sha": baseline,
    },
    "execution_mode": "program",
    "checkpoint_graph": {
        "execution_order": ["CP-00", "CP-01"],
        "checkpoints": [
            {"id": "CP-00", "title": "current", "scope": "src/",
             "depends_on": [], "acceptance_criterion_ids": ["AC-00"],
             "risk_budget": {"max_build_passes": 2, "max_review_passes": 3,
                             "max_repair_rounds": 1}},
            {"id": "CP-01", "title": "future", "scope": "src/",
             "depends_on": ["CP-00"], "acceptance_criterion_ids": ["AC-01"],
             "risk_budget": {"max_build_passes": 2, "max_review_passes": 2,
                             "max_repair_rounds": 1}},
        ],
    },
    "promotion_policy": "human_gate",
    "acceptance_criteria": [
        {"id": "AC-00", "text": "current checkpoint artifact exists"},
        {"id": "AC-01", "text": "future checkpoint remains in scope"},
    ],
    "non_goals": [],
    "required_validation": [cp0_validation],
    "allowed_paths": ["src/"],
    "protected_paths": [".ownframework-loop/", ".worktrees/"],
    "work_units": [{"id": "UNIT-00", "title": "current fixture", "scope": "src/"}],
    "merge_authority": "human_only",
    "deploy_authority": "human_only",
    "push_authority": "human_only",
    "external_action_authority": "none",
    "risk_budget": {
        "max_build_passes": 4, "max_review_passes": 5,
        "max_repair_rounds": 2, "max_files_changed": 10,
        "max_diff_lines": 500,
    },
}
errors = packet.validate_packet_for_approval(meta)
assert not errors, errors
packet_path = run_root / "WORK_PACKET.md"
packet_bytes = ("```json\n" + json.dumps(meta, sort_keys=True, indent=2) + "\n```\n").encode()
packet_path.write_bytes(packet_bytes)
initial = state.initial_state(parent)
initial.update({
    "spec_baseline_branch": "master", "spec_baseline_sha": baseline,
    "spec_snapshot_at": util.utc_now_iso(),
})
state.save(repo, parent, initial)
state.append_event(repo, parent, event_type="run_created", old_state=None,
                   new_state="AWAITING_APPROVAL", actor="test-spec",
                   reason="real rollover fixture packet authored")
seal = execution_start.ensure_executable(
    canonical_repo=repo, run_id=parent, actor="test-seal", binding_method="build_start",
)
assert state.load_verified(repo, parent)["state"] == "READY_TO_BUILD"
parent_branch = seal["candidate_branch"]
parent_profile = runner_profiles.resolve_profile(
    "default", provider=RolloverFixtureRunner.runner_id,
)
parent_resolution = capabilities.resolve_capabilities(
    [], canonical_repo=repo, role="builder",
    repo_cache_root=runtime_env.repo_tool_cache_dir(repo),
    ephemeral_cache_root=runtime_env.runtime_cache_dir(repo, parent, "builder") / "capability-cache",
    evidence_run_key=parent,
)
capability_binding.ensure_run_binding(
    repo, parent, parent_resolution, parent_profile, allow_create=True,
)

# Enroll through the normal supervisor API. The fixture later supplies
# synthetic, fully-accounted attempts corresponding to the real finalizers.
parent_enqueue = supervisor.enqueue(
    canonical_repo=repo, run_id=parent, runner=RolloverFixtureRunner.runner_id,
    db_path=db_path, max_total_cost_usd=10.0, max_total_tokens=10000,
    max_wall_seconds=3600, runtime_generation="v125-parent-generation",
)
assert parent_enqueue.get("ok") is True, parent_enqueue


def finish_build(pass_number: int, content: str) -> str:
    current = state.load_verified(repo, parent)
    claim = program.claim_build_pass(canonical_repo=repo, run_id=parent, packet=meta)
    assert claim["cp_pass_number"] == pass_number, claim
    prepared = build_prepare.prepare(canonical_repo=repo, run_id=parent)
    builder = Path(prepared["builder_worktree"])
    source = builder / "src" / "thermostat.py"
    source.parent.mkdir(parents=True, exist_ok=True)
    source.write_text(f'VALUE = "{content}"\n', encoding="utf-8")
    subprocess.run(["git", "-C", str(builder), "add", "src/thermostat.py"], check=True)
    subprocess.run(
        ["git", "-C", str(builder), "commit", "-qm", f"fixture build {pass_number}"],
        check=True,
    )
    candidate = git("rev-parse", "refs/heads/" + parent_branch)
    result_path = build_agent.write_skeleton(
        repo, parent, source_root=source_root, overwrite=True,
    )
    result = json.loads(result_path.read_text(encoding="utf-8"))
    result.update({
        "summary": f"Fixture builder pass {pass_number} committed the candidate.",
        "outcome_requested": "candidate_ready",
        "unit_ids_completed": ["UNIT-00"],
        "acceptance_addressed": ["AC-00"],
        "notes": "Semantic output fixture; finalization is real.",
        "timestamp": util.utc_now_iso(),
    })
    result["evidence"]["files_changed"] = ["src/thermostat.py"]
    result["evidence"]["diff_lines_total"] = 1
    result_path.write_text(json.dumps(result, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    receipt = build_finalize.finalize_build(
        canonical_repo=repo, run_id=parent, agent_result_path=result_path,
        actor="v125-fixture-builder",
    )
    assert receipt["candidate_sha"] == candidate, receipt
    assert receipt["validation_status"] == "PASS", receipt
    assert receipt["next_state"] == "READY_FOR_REVIEW", receipt
    assert state.load_verified(repo, parent)["build_pass_count"] == pass_number
    return candidate


def finish_review(pass_number: int, candidate: str) -> dict:
    claim = program.claim_review_pass(canonical_repo=repo, run_id=parent, packet=meta)
    assert claim["cp_pass_number"] == pass_number, claim
    prepared = review_prepare.prepare(canonical_repo=repo, run_id=parent)
    assess_path = assessment.write_skeleton(
        repo, parent, source_root=source_root, overwrite=True,
    )
    assess = json.loads(assess_path.read_text(encoding="utf-8"))
    assess["acceptance_results"] = [{
        "id": "AC-00", "result": "pass", "evidence": "Fixture source file is present.",
    }]
    assess["non_goal_results"] = []
    assess["findings"] = []
    assess["validation_results"] = []
    assess["recommended_verdict"] = "APPROVED"
    assess["timestamp"] = util.utc_now_iso()
    assess_path.write_text(json.dumps(assess, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    verdict = review_finalize.finalize_review(
        canonical_repo=repo, run_id=parent, assessment_path=assess_path,
        actor="v125-fixture-reviewer",
    )
    assert verdict["candidate_sha_reviewed"] == candidate, verdict
    assert verdict["failure_reason"] == "validation_failed", verdict
    assert verdict["recommended_next_state"] == "CHANGES_REQUESTED", verdict
    assert len(verdict["validation_results"]) == 1, verdict
    assert verdict["validation_results"][0]["passed"] is False, verdict
    assert verdict["validation_results"][0]["infra_failure"] is False, verdict
    return verdict


first_candidate = finish_build(1, "initial")
first_verdict = finish_review(1, first_candidate)
first_after = state.load_verified(repo, parent)
assert first_after["state"] == "CHANGES_REQUESTED", first_after
assert first_after["repair_round"] == 1, first_after
second_candidate = finish_build(2, "repaired")
assert second_candidate != first_candidate
second_verdict = finish_review(2, second_candidate)
parent_state = state.load_verified(repo, parent)
assert parent_state["state"] == "BLOCKED", parent_state
assert parent_state["build_pass_count"] == 2
assert parent_state["review_pass_count"] == 2
assert parent_state["repair_round"] == 1
assert parent_state["last_candidate_sha"] == second_candidate
assert second_verdict["verdict"] == "CHANGES_REQUESTED"
assert second_verdict["failure_reason"] == "validation_failed"
assert second_verdict["recommended_next_state"] == "CHANGES_REQUESTED"
assert (repo / ".worktrees/ownframework-loop" / parent / "builder").is_dir()
assert (repo / ".worktrees/ownframework-loop" / parent / "reviewer").is_dir()
assert git_checks.current_head(worktrees.builder_worktree(repo, parent)) == second_candidate
assert git_checks.current_head(worktrees.reviewer_worktree(repo, parent)) == second_candidate
assert git_checks.dirty_status(worktrees.builder_worktree(repo, parent)) == "clean"
assert git_checks.dirty_status(worktrees.reviewer_worktree(repo, parent)) == "clean"
print("REAL_PARENT_BLOCKED_AT_EXHAUSTED_BUILD_CAP=PASS")
print("REAL_BUILD_AND_REVIEW_FINALIZERS=PASS")
print("VALIDATION_ONLY_REVIEW_REJECTION=PASS")

# Create durable, exact accounting for the four deterministic semantic fixture
# results. No provider is launched; this is the test-owned ledger evidence used
# by the production rollover verifier.
assessment_path = assessment.assessment_path(repo, parent)
assessment_sha = util.sha256_file(assessment_path)
job_id = int(parent_enqueue["id"])
attempt_ids = ["a" * 32, "b" * 32, "c" * 32, "d" * 32]
roles = ["builder", "reviewer", "builder", "reviewer"]
cost_each = 0.25
in_each, out_each, cache_each, creation_each = 11, 7, 19, 3
with supervisor_db._managed_connect(db_path) as conn:
    for index, (attempt_id, role) in enumerate(zip(attempt_ids, roles), start=1):
        accepted_candidate = first_candidate if index < 4 else second_candidate
        accepted_semantic = assessment_sha if role == "reviewer" and index == 4 else hashlib.sha256(
            f"synthetic accepted {index}".encode()
        ).hexdigest()
        conn.execute(
            """INSERT INTO semantic_attempts
               (attempt_id,job_id,role,status,started_at,completed_at,stdout_path,
                stderr_path,returncode,cost_usd,cost_accounted,semantic_accepted,
                cost_known,input_tokens,output_tokens,cache_read_tokens,
                cache_creation_tokens,tokens_known,failure_class,failure_reason,
                effective_model,accepted_candidate_sha,accepted_semantic_sha256)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (attempt_id, job_id, role, "COMPLETED", float(index), float(index) + 0.5,
             "", "", 0, cost_each, 1, 1, 1, in_each, out_each, cache_each,
             creation_each, 1, None, None, "fixture-model", accepted_candidate,
             accepted_semantic),
        )
    parent_clock_start = time.time() - 100.0
    conn.execute(
        """UPDATE jobs SET status='DONE', execution_started_at=?,
           total_cost_usd=?,total_input_tokens=?,total_output_tokens=?,
           total_cache_read_tokens=?,total_cache_creation_tokens=?,
           latest_attempt_id=?,worker_pid=NULL,
           worker_pgid=NULL,worker_attempt_id=NULL,worker_role=NULL
           WHERE id=?""",
        (parent_clock_start, cost_each * 4, in_each * 4, out_each * 4,
         cache_each * 4, creation_each * 4,
         attempt_ids[-1], job_id),
    )

parent_root = state.run_dir(repo, parent)
parent_before = {
    "packet": util.sha256_file(parent_root / "WORK_PACKET.md"),
    "approval": util.sha256_file(parent_root / "APPROVAL.json"),
    "state": util.sha256_file(parent_root / "STATE.json"),
    "events": integrity.compute_event_chain_hash(parent_root / "EVENTS.log"),
    "build": util.sha256_file(parent_root / "BUILD_RECEIPT.json"),
    "verdict": util.sha256_file(parent_root / "REVIEW_VERDICT.json"),
    "assessment": util.sha256_file(assessment_path),
    "candidate": git("rev-parse", "refs/heads/" + parent_branch),
}
with supervisor_db._managed_connect_readonly(db_path) as conn:
    parent_job_before = dict(conn.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone())
    parent_attempts_before = [dict(row) for row in conn.execute(
        "SELECT * FROM semantic_attempts WHERE job_id=? ORDER BY started_at,attempt_id",
        (job_id,),
    )]
parent_before["job_snapshot"] = hashlib.sha256(
    json.dumps(parent_job_before, sort_keys=True, default=str).encode()
).hexdigest()
parent_before["attempts_snapshot"] = hashlib.sha256(
    json.dumps(parent_attempts_before, sort_keys=True, default=str).encode()
).hexdigest()

expected_packet_sha = util.sha256_file(parent_root / "WORK_PACKET.md")
first_now = parent_clock_start + 100.0
real_clock = program_rollover._wall_clock_now
try:
    program_rollover._wall_clock_now = lambda: first_now
    first = program_rollover.create_linked_program_rollover(
        canonical_repo=repo, parent_run_id=parent,
        expected_packet_sha256=expected_packet_sha,
        expected_baseline_sha=baseline, expected_candidate_sha=second_candidate,
        db_path=db_path,
    )
    child_root = state.run_dir(repo, first["run_id"])
    authority_path = child_root / "ROLLOVER_AUTHORITY.json"
    authority_bytes = authority_path.read_bytes()
    authority = json.loads(authority_bytes)
    first_wall = int(authority["operational_envelope_remaining"]["max_wall_seconds"])
    parent_deadline = float(authority["wall_clock_authority"]["parent_deadline_unix"])
    child_clock_origin = float(authority["wall_clock_authority"]["child_execution_started_at"])
    assert first_wall == int(parent_deadline - first_now), (first_wall, parent_deadline, first_now)
    assert child_clock_origin == first_now
    assert child_clock_origin + first_wall <= parent_deadline

    # Seven seconds of ordinary time must replay the same immutable authority,
    # accepting only the lower recomputed remaining duration.
    program_rollover._wall_clock_now = lambda: first_now + 7.0
    second = program_rollover.create_linked_program_rollover(
        canonical_repo=repo, parent_run_id=parent,
        expected_packet_sha256=expected_packet_sha,
        expected_baseline_sha=baseline, expected_candidate_sha=second_candidate,
        db_path=db_path,
    )
finally:
    program_rollover._wall_clock_now = real_clock

assert first["run_id"] == second["run_id"]
assert first["rollover_authority_sha256"] == second["rollover_authority_sha256"]
assert authority_path.read_bytes() == authority_bytes
assert second["candidate_sha"] == second_candidate
assert (child_root / "WORK_PACKET.md").read_bytes() == packet_bytes
assert state.load_verified(repo, first["run_id"])["spec_baseline_sha"] == baseline
child_state = state.load_verified(repo, first["run_id"])
assert child_state["last_candidate_sha"] == second_candidate
assert (child_state["build_pass_count"], child_state["review_pass_count"],
        child_state["repair_round"]) == (
            parent_state["build_pass_count"], parent_state["review_pass_count"],
            parent_state["repair_round"],
        )
assert authority["source"]["parent_candidate_sha"] == second_candidate
assert authority["source"]["parent_baseline_sha"] == baseline
assert authority["operational_envelope_remaining"]["max_wall_seconds"] == first_wall
assert int(first_wall) > int(parent_deadline - (first_now + 7.0))

parent_after = {
    "packet": util.sha256_file(parent_root / "WORK_PACKET.md"),
    "approval": util.sha256_file(parent_root / "APPROVAL.json"),
    "state": util.sha256_file(parent_root / "STATE.json"),
    "events": integrity.compute_event_chain_hash(parent_root / "EVENTS.log"),
    "build": util.sha256_file(parent_root / "BUILD_RECEIPT.json"),
    "verdict": util.sha256_file(parent_root / "REVIEW_VERDICT.json"),
    "assessment": util.sha256_file(assessment_path),
    "candidate": git("rev-parse", "refs/heads/" + parent_branch),
}
with supervisor_db._managed_connect_readonly(db_path) as conn:
    parent_job_after = dict(conn.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone())
    parent_attempts_after = [dict(row) for row in conn.execute(
        "SELECT * FROM semantic_attempts WHERE job_id=? ORDER BY started_at,attempt_id",
        (job_id,),
    )]
assert parent_after == {k: v for k, v in parent_before.items() if k in parent_after}
assert parent_job_after == parent_job_before
assert parent_attempts_after == parent_attempts_before
print("WALL_REPLAY_ACCEPTS_NORMAL_TIME_PASSAGE=PASS")
print("WALL_REPLAY_DOES_NOT_WIDEN_PARENT_DEADLINE=PASS")
print("ROLLOVER_CREATION_IS_DETERMINISTIC_AND_IDEMPOTENT=PASS")
print("PARENT_PACKET_APPROVAL_STATE_EVENTS_RECEIPTS_LEDGER_IMMUTABLE=PASS")
print("PACKET_BYTES_BASELINE_CANDIDATE_AND_COUNTERS_IMPORTED_EXACTLY=PASS")

# A real public TTY approval is required for the child packet; no APPROVAL is
# written by the fixture itself.
token = approval.derive_confirmation_token(expected_packet_sha)
master_fd, slave_fd = pty.openpty()
proc = subprocess.Popen(
    [ofloop_bin, "spec", "approve", str(repo), first["run_id"], "--actor", "v125-tty-fixture"],
    stdin=slave_fd, stdout=slave_fd, stderr=slave_fd,
    close_fds=True, env=dict(os.environ),
)
os.close(slave_fd)
output = ""
sent = False
deadline = time.time() + 15
while time.time() < deadline:
    ready, _, _ = select.select([master_fd], [], [], 0.2)
    if ready:
        try:
            output += os.read(master_fd, 4096).decode("utf-8", errors="replace")
        except OSError:
            break
        if "token>" in output and not sent:
            os.write(master_fd, (token + "\n").encode())
            sent = True
        if "READY_TO_BUILD" in output:
            break
    if proc.poll() is not None:
        break
try:
    returncode = proc.wait(timeout=10)
except subprocess.TimeoutExpired:
    proc.kill(); proc.wait(timeout=3)
    raise AssertionError("supported TTY approval timed out")
os.close(master_fd)
assert sent and returncode == 0, (sent, returncode, output)
child_approval = approval.load_approval(repo, first["run_id"])
assert child_approval["approval_method"] == "tty_confirmation", child_approval
assert child_approval["packet_sha256"] == expected_packet_sha
assert child_approval["baseline_sha"] == baseline
assert child_approval["candidate_branch"] == first["candidate_branch"]
assert state.load_verified(repo, first["run_id"])["state"] == "READY_TO_BUILD"

# Fresh deterministic candidate validation is run by the real rollover path;
# it does not claim another BUILD or repair entitlement.
pre_prepare = state.load_verified(repo, first["run_id"])
admitted = program_rollover.prepare_rollover_review(
    canonical_repo=repo, run_id=first["run_id"], db_path=db_path,
)
assert admitted["state"] == "READY_FOR_REVIEW", admitted
after_prepare = state.load_verified(repo, first["run_id"])
assert (after_prepare["build_pass_count"], after_prepare["review_pass_count"],
        after_prepare["repair_round"]) == (
            pre_prepare["build_pass_count"], pre_prepare["review_pass_count"],
            pre_prepare["repair_round"],
        )
rollover_receipt = receipts.load_receipt(repo, first["run_id"])
assert rollover_receipt["validation_status"] == "PASS", rollover_receipt
assert rollover_receipt["candidate_sha"] == second_candidate
assert rollover_receipt["candidate_origin"]["candidate_sha"] == second_candidate
assert rollover_receipt["candidate_origin"]["parent_run_id"] == parent
assert rollover_receipt["builder_pass_number"] == parent_state["build_pass_count"]
assert git_checks.current_head(worktrees.builder_worktree(repo, first["run_id"])) == second_candidate
print("SUPPORTED_TTY_APPROVAL=PASS")
print("ROLLOVER_FRESH_VALIDATION_AND_CANDIDATE_ORIGIN=PASS")
print("ROLLOVER_DOES_NOT_RESET_BUILD_OR_REPAIR_COUNTERS=PASS")

# An attempted wall-limit increase is refused before any ledger row is added.
child_enqueue_widen = supervisor.enqueue(
    canonical_repo=repo, run_id=first["run_id"],
    runner=RolloverFixtureRunner.runner_id, db_path=db_path,
    max_wall_seconds=first_wall + 1,
    runtime_generation="v125-child-generation",
)
assert child_enqueue_widen.get("enqueue_refused") is True, child_enqueue_widen
assert child_enqueue_widen.get("reason") == "linked_program_rollover_envelope_refused", child_enqueue_widen
with supervisor_db._managed_connect_readonly(db_path) as conn:
    assert conn.execute("SELECT COUNT(*) FROM jobs WHERE repo=? AND run_id=?",
                        (str(repo.resolve()), first["run_id"])).fetchone()[0] == 0

# The ordinary supervisor enrollment path persists the immutable creation
# origin. The child deadline therefore remains no later than the parent's.
child_enqueue = supervisor.enqueue(
    canonical_repo=repo, run_id=first["run_id"],
    runner=RolloverFixtureRunner.runner_id, db_path=db_path,
    runtime_generation="v125-child-generation",
)
assert child_enqueue.get("ok") is True, child_enqueue
assert child_enqueue["status"] == "QUEUED", child_enqueue
assert int(child_enqueue["max_wall_seconds"]) == first_wall
assert abs(float(child_enqueue["execution_started_at"]) - child_clock_origin) < 1e-6
assert float(child_enqueue["execution_started_at"]) + int(child_enqueue["max_wall_seconds"]) <= parent_deadline
child_enqueue_replay = supervisor.enqueue(
    canonical_repo=repo, run_id=first["run_id"],
    runner=RolloverFixtureRunner.runner_id, db_path=db_path,
    runtime_generation="v125-child-generation",
)
assert child_enqueue_replay.get("ok") is True, child_enqueue_replay
assert child_enqueue_replay["execution_started_at"] == child_enqueue["execution_started_at"]
assert child_enqueue_replay["max_wall_seconds"] == child_enqueue["max_wall_seconds"]
print("SUPERVISOR_ENQUEUE_PRESERVES_ORIGIN_AND_DEADLINE=PASS")
print("ROLLOVER_ENQUEUE_CANNOT_WIDEN_WALL_CEILING=PASS")

# A separately STOPPED run is refused before any rollover child is created.
stopped = "run-20260928T000000Z-v125stopped"
stopped_root = state.run_dir(repo, stopped)
stopped_root.mkdir(parents=True)
stopped_state = state.initial_state(stopped)
stopped_state.update({"spec_baseline_branch": "master", "spec_baseline_sha": baseline,
                      "spec_snapshot_at": util.utc_now_iso()})
state.save(repo, stopped, stopped_state)
state.append_event(repo, stopped, event_type="run_created", old_state=None,
                   new_state="AWAITING_APPROVAL", actor="test", reason="stopped refusal fixture")
state.transition(repo, stopped, to_state="STOPPED", actor="test", reason="test terminal stop")
run_dirs_before_stopped_refusal = {
    path.name for path in (repo / ".ownframework-loop").iterdir()
}
try:
    program_rollover.create_linked_program_rollover(
        canonical_repo=repo, parent_run_id=stopped,
        expected_packet_sha256="a" * 64,
        expected_baseline_sha=baseline, expected_candidate_sha=baseline,
        db_path=db_path,
    )
except program_rollover.ProgramRolloverRefused:
    pass
else:
    raise AssertionError("STOPPED parent was accepted for rollover")
assert {
    path.name for path in (repo / ".ownframework-loop").iterdir()
} == run_dirs_before_stopped_refusal
print("STOPPED_PARENT_REFUSED=PASS")

# Contradictory parent evidence is independently refused. This deliberate
# mutation is confined to the disposable test fixture and occurs only after
# the successful rollover immutability proof above.
(parent_root / "BUILD_RECEIPT.json").write_text("{}\n", encoding="utf-8")
try:
    program_rollover.create_linked_program_rollover(
        canonical_repo=repo, parent_run_id=parent,
        expected_packet_sha256=expected_packet_sha,
        expected_baseline_sha=baseline, expected_candidate_sha=second_candidate,
        db_path=db_path,
    )
except program_rollover.ProgramRolloverRefused:
    pass
else:
    raise AssertionError("contradictory parent evidence was accepted")
print("CONTRADICTORY_PARENT_EVIDENCE_REFUSED=PASS")
print("BLOCKED_PROGRAM_CANDIDATE_ROLLOVER_WALL_CLOCK=PASS")
PY
