#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib:$ROOT_DIR/tests/helpers:$ROOT_DIR/tests${PYTHONPATH:+:$PYTHONPATH}"
export OFLOOP_LIB="$ROOT_DIR/lib"
export PYTHONDONTWRITEBYTECODE=1
TMP="$(mktemp -d -t ofloop-v13ab-budget-continuation.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

python3 -B - "$TMP" "$ROOT_DIR" <<'PY'
from __future__ import annotations

import contextlib
import io
import json
import os
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
source_root = Path(sys.argv[2])
repo = root / "unrelated-v4-mission"
repo.mkdir()
os.environ["XDG_STATE_HOME"] = str(root / "state")

from ownframework_loop import (
    approval, assessment, build_agent, build_finalize, build_prepare,
    capabilities, capability_binding, cli, execution_start, integrity,
    packet, program, program_mission, review_finalize, review_prepare,
    runner_profiles, runtime_env, state, supervisor, supervisor_claims,
    supervisor_db, supervisor_runtime, util,
)


def git(*args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args], capture_output=True, text=True,
    )
    if result.returncode:
        raise AssertionError(f"git {args!r} failed: {result.stderr}")
    return result.stdout.strip()


git("init", "-q", "-b", "master")
git("config", "user.name", "Loop continuation fixture")
git("config", "user.email", "loop-continuation@example.invalid")
(repo / ".git" / "info" / "exclude").write_text(
    "/.ownframework-loop/\n/.worktrees/ownframework-loop/\n", encoding="utf-8",
)
(repo / "README.md").write_text("disposable mission continuation fixture\n", encoding="utf-8")
git("add", "README.md")
git("commit", "-qm", "fixture baseline")
baseline = git("rev-parse", "HEAD")


class ContinuationFixtureRunner:
    runner_id = "v13ab-continuation-fixture"

    def run(self, *args, **kwargs):
        raise AssertionError("fixture must not launch an external provider")


supervisor.register_runner(ContinuationFixtureRunner)
db_path = root / "state" / "ownframework-loop" / "supervisor.sqlite3"
with supervisor_db._managed_connect(db_path):
    pass

cp_budgets = [
    {"max_build_passes": 2, "max_review_passes": 2, "max_repair_rounds": 1},
    {"max_build_passes": 3, "max_review_passes": 2, "max_repair_rounds": 1},
]
checkpoints = [
    {
        "id": f"CP-{index:02d}", "title": f"fixture checkpoint {index}",
        "scope": "src/", "depends_on": [] if index == 0 else ["CP-00"],
        "acceptance_criterion_ids": [f"AC-{index:02d}"],
        "work_units": [f"UNIT-{index:02d}"], "risk_budget": cp_budgets[index],
    }
    for index in range(2)
]
meta = {
    "schema": "ownframework-work-packet/v4",
    "packet_id": "v13ab-blocked-continuation", "created_at": "2026-09-30T00:00:00Z",
    "work_class": "FEATURE", "risk_class": "low",
    "title": "typed blocked semantic-budget continuation fixture",
    "runner_profile": "default",
    "target": {"repo": str(repo.resolve()), "branch": "master",
               "classification": "local_only", "expected_baseline_sha": baseline},
    "execution_mode": "program",
    "checkpoint_graph": {
        "execution_order": ["CP-00", "CP-01"], "checkpoints": checkpoints,
        "global_source_ceilings": {
            "max_unique_changed_files": 10,
            "max_baseline_to_final_diff_lines": 5,
        },
    },
    "mission_budget": {
        "schema": "ownframework-loop-mission-budget/v1", "auto_segment": True,
        "segment_max_diff_lines": 5, "mission_max_diff_lines": 100,
        "max_segments": 3, "segment_boundary_policy": "last_approved_checkpoint",
    },
    "promotion_policy": "human_gate",
    "acceptance_criteria": [
        {"id": "AC-00", "text": "first checkpoint is implemented"},
        {"id": "AC-01", "text": "second checkpoint is implemented"},
    ],
    "non_goals": [],
    "required_validation": [{"name": "fixture", "command": "true", "kind": "fast"}],
    "allowed_paths": ["src/"], "protected_paths": [".ownframework-loop/", ".worktrees/"],
    "work_units": [
        {"id": "UNIT-00", "title": "first", "scope": "src/"},
        {"id": "UNIT-01", "title": "second", "scope": "src/"},
    ],
    "merge_authority": "human_only", "deploy_authority": "human_only",
    "push_authority": "human_only", "external_action_authority": "none",
    "risk_budget": {
        "max_build_passes": 8, "max_review_passes": 6, "max_repair_rounds": 3,
        "max_files_changed": 10, "max_diff_lines": 5,
        "max_consecutive_no_progress_passes": 8,
        "max_identical_finding_repeats": 8,
    },
}
packet_errors = packet.validate_packet_for_approval(meta)
assert packet_errors == [], packet_errors
source_run = "run-2026-09-30-v13ab-parent"
source_run_root = state.run_dir(repo, source_run)
source_run_root.mkdir(parents=True)
(source_run_root / "WORK_PACKET.md").write_text(
    "```json\n" + json.dumps(meta, sort_keys=True, indent=2) + "\n```\nfixture\n",
    encoding="utf-8",
)
initial = state.initial_state(source_run)
initial.update({
    "spec_baseline_branch": "master", "spec_baseline_sha": baseline,
    "spec_snapshot_at": util.utc_now_iso(),
})
state.save(repo, source_run, initial)
state.append_event(
    repo, source_run, event_type="run_created", old_state=None,
    new_state="AWAITING_APPROVAL", actor="v13ab-fixture", reason="sealed v4 fixture",
)
execution_start.ensure_executable(canonical_repo=repo, run_id=source_run, actor="v13ab-fixture")
runtime_generation = supervisor_runtime.runtime_generation()
enrolled = supervisor.enqueue(
    canonical_repo=repo, run_id=source_run, runner=ContinuationFixtureRunner.runner_id,
    db_path=db_path, max_total_cost_usd=10.0, max_total_tokens=100000,
    max_wall_seconds=0, runtime_generation=runtime_generation,
)
assert enrolled.get("ok") is True, enrolled

# Let the ordinary scheduler initialize the immutable mission, but prevent it
# from claiming the first semantic action during fixture setup.
real_take_next = supervisor_claims._take_next_job
supervisor_claims._take_next_job = lambda conn: None
try:
    initialized = supervisor.run_one(db_path=db_path)
finally:
    supervisor_claims._take_next_job = real_take_next
assert initialized.get("action") == "IDLE", initialized
profile = runner_profiles.resolve_profile("default", provider=ContinuationFixtureRunner.runner_id)
resolution = capabilities.resolve_capabilities(
    [], canonical_repo=repo, role="builder",
    repo_cache_root=runtime_env.repo_tool_cache_dir(repo),
    ephemeral_cache_root=runtime_env.runtime_cache_dir(repo, source_run, "builder") / "capability-cache",
    evidence_run_key=source_run,
)
binding = capability_binding.ensure_run_binding(repo, source_run, resolution, profile, allow_create=True)
mission_binding = program_mission.bind_runtime_identity(
    repo, source_run, run_binding=binding, runner_profile=profile,
    runtime_generation=runtime_generation,
)
assert mission_binding
segment, _, _, _ = program_mission.load_segment(repo, source_run)
mission_id = str(segment["mission_id"])
mission_sha = str(segment["mission_authority_sha256"])


def packet_for(run_id: str) -> dict:
    return packet.parse_packet_file(state.run_dir(repo, run_id) / "WORK_PACKET.md")[0]


def bind_run(run_id: str) -> None:
    run_profile = runner_profiles.resolve_profile("default", provider=ContinuationFixtureRunner.runner_id)
    resolution = capabilities.resolve_capabilities(
        [], canonical_repo=repo, role="builder",
        repo_cache_root=runtime_env.repo_tool_cache_dir(repo),
        ephemeral_cache_root=runtime_env.runtime_cache_dir(repo, run_id, "builder") / "capability-cache",
        evidence_run_key=run_id,
    )
    run_binding = capability_binding.ensure_run_binding(
        repo, run_id, resolution, run_profile, allow_create=True,
    )
    identity = program_mission.verify_runtime_identity(
        repo, mission_id, run_binding=run_binding, runner_profile=run_profile,
        runtime_generation=runtime_generation,
    )
    assert identity["capability_binding_sha256"] == run_binding["binding_sha256"]


def build(run_id: str, *, path: str, text: str,
          expected_state: str = "READY_FOR_REVIEW") -> tuple[str, dict]:
    run_meta = packet_for(run_id)
    current = state.load_verified(repo, run_id)
    cp_id = current["program"]["current_checkpoints"][0]
    cp = next(item for item in run_meta["checkpoint_graph"]["checkpoints"] if item["id"] == cp_id)
    claim = program.claim_build_pass(canonical_repo=repo, run_id=run_id, packet=run_meta)
    prepared = build_prepare.prepare(canonical_repo=repo, run_id=run_id)
    builder = Path(prepared["builder_worktree"])
    target = builder / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")
    git_result = subprocess.run(
        ["git", "-C", str(builder), "add", "--", path], capture_output=True, text=True,
    )
    assert git_result.returncode == 0, git_result.stderr
    commit = subprocess.run(
        ["git", "-C", str(builder), "commit", "-qm", f"v13ab {run_id} {cp_id} build {claim['cp_pass_number']}"],
        capture_output=True, text=True,
    )
    assert commit.returncode == 0, commit.stderr
    candidate = subprocess.check_output(
        ["git", "-C", str(builder), "rev-parse", "HEAD"], text=True,
    ).strip()
    result_path = build_agent.write_skeleton(repo, run_id, source_root=source_root, overwrite=True)
    result = json.loads(result_path.read_text(encoding="utf-8"))
    result.update({
        "summary": f"fixture implementation for {cp_id}",
        "outcome_requested": "candidate_ready", "work_unit_id": cp["work_units"][0],
        "unit_ids_completed": [cp["work_units"][0]],
        "acceptance_addressed": cp["acceptance_criterion_ids"],
        "notes": "Deterministic fake semantic output; production finalizer is used.",
        "timestamp": util.utc_now_iso(),
    })
    result["evidence"]["files_changed"] = [path]
    result["evidence"]["diff_lines_total"] = len(text.splitlines())
    result_path.write_text(json.dumps(result, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    receipt = build_finalize.finalize_build(
        canonical_repo=repo, run_id=run_id,
        agent_result_path=result_path, actor="v13ab-fixture-builder",
    )
    assert receipt["candidate_sha"] == candidate, receipt
    assert receipt["next_state"] == expected_state, receipt
    return candidate, receipt


def review(
    run_id: str,
    *,
    must_fix: bool = False,
    finding_path: str = "src/first.py",
) -> dict:
    run_meta = packet_for(run_id)
    current = state.load_verified(repo, run_id)
    program_state = current["program"]
    review_scope = program_state.get("review_scope") or "checkpoint"
    current_checkpoints = list(program_state.get("current_checkpoints") or [])
    cp_id = current_checkpoints[0] if current_checkpoints else ""
    cp = (
        next(item for item in run_meta["checkpoint_graph"]["checkpoints"] if item["id"] == cp_id)
        if review_scope != "program_final" else None
    )
    program.claim_review_pass(canonical_repo=repo, run_id=run_id, packet=run_meta)
    review_prepare.prepare(canonical_repo=repo, run_id=run_id)
    assess_path = assessment.write_skeleton(repo, run_id, source_root=source_root, overwrite=True)
    doc = json.loads(assess_path.read_text(encoding="utf-8"))
    acceptance_ids = (
        program.packet_acceptance_criterion_ids(run_meta)
        if review_scope == "program_final" else cp["acceptance_criterion_ids"]
    )
    doc["acceptance_results"] = [
        {"id": ac_id, "result": "pass", "evidence": "Fixture source exists."}
        for ac_id in acceptance_ids
    ]
    doc["non_goal_results"] = []
    doc["validation_results"] = []
    doc["findings"] = ([{
        "finding_id": "F-V13AB-MUST-FIX", "severity": "high",
        "classification": "must_fix", "title": "bounded fixture repair",
        "description": "The deterministic fixture requires one repair before continuation.",
        "file": finding_path, "line": 1,
    }] if must_fix else [])
    doc["recommended_verdict"] = "CHANGES_REQUESTED" if must_fix else "APPROVED"
    doc["review_scope"] = review_scope
    doc["timestamp"] = util.utc_now_iso()
    assess_path.write_text(json.dumps(doc, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    return review_finalize.finalize_review(
        canonical_repo=repo, run_id=run_id,
        assessment_path=assess_path, actor="v13ab-fixture-reviewer",
    )


def program_final_repair_build(run_id: str, *, path: str) -> tuple[str, dict]:
    """Run a real final-scope BUILD claim, prepare, and deterministic finalize."""
    run_meta = packet_for(run_id)
    claim = program.claim_build_pass(canonical_repo=repo, run_id=run_id, packet=run_meta)
    assert claim["cp_id"] == "", claim
    prepared = build_prepare.prepare(canonical_repo=repo, run_id=run_id)
    builder = Path(prepared["builder_worktree"])
    target = builder / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("CONTINUED = True\nFINAL_ACCEPTANCE_REPAIR = True\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(builder), "add", "--", path], check=True, capture_output=True)
    subprocess.run(
        ["git", "-C", str(builder), "commit", "-qm", "v13ab program-final repair"],
        check=True, capture_output=True,
    )
    candidate = subprocess.check_output(
        ["git", "-C", str(builder), "rev-parse", "HEAD"], text=True,
    ).strip()
    result_path = build_agent.write_skeleton(
        repo, run_id, source_root=source_root, overwrite=True,
    )
    result = json.loads(result_path.read_text(encoding="utf-8"))
    result.update({
        "summary": "one bounded whole-product final-review repair",
        "outcome_requested": "candidate_ready",
        "unit_ids_completed": [],
        "acceptance_addressed": program.packet_acceptance_criterion_ids(run_meta),
        "work_unit_id": program.PROGRAM_FINAL_REPAIR_WORK_UNIT_ID,
        "notes": "Deterministic fake semantic output; production finalizer is used.",
        "timestamp": util.utc_now_iso(),
    })
    result["evidence"]["files_changed"] = [path]
    result["evidence"]["diff_lines_total"] = 2
    result_path.write_text(json.dumps(result, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    receipt = build_finalize.finalize_build(
        canonical_repo=repo, run_id=run_id,
        agent_result_path=result_path, actor="v13ab-fixture-builder",
    )
    assert receipt["candidate_sha"] == candidate, receipt
    assert receipt["validation_status"] == "PASS", receipt
    assert receipt["next_state"] == "READY_FOR_REVIEW", receipt
    return candidate, receipt


# Complete CP-00 and cross the source ceiling while CP-01 still has local BUILD
# authority. Ordinary segmentation creates s02 from the approved prefix; the
# s02 successor then genuinely exhausts CP-01 BUILD authority after a repair.
approved_candidate, _ = build(source_run, path="src/base.py", text="BASE = 1\n")
approved_verdict = review(source_run)
assert approved_verdict["verdict"] == "APPROVED"
_, first_boundary = build(
    source_run, path="src/first-crossing.py",
    text="".join(f"FIRST_CROSSING_{n} = {n}\n" for n in range(8)),
    expected_state="SEGMENT_BOUNDARY",
)
assert first_boundary["segment_boundary"]["result"] == "authorized"
first_segment_done = supervisor.run_one(db_path=db_path)
assert first_segment_done["action"] == "TERMINAL", first_segment_done
source_run = program_mission._segment_run_id(mission_id, 2)
bind_run(source_run)
source_meta = packet_for(source_run)
source_run_root = state.run_dir(repo, source_run)
packet_path = source_run_root / "WORK_PACKET.md"
packet_sha = util.sha256_file(packet_path)
_, _ = build(source_run, path="src/first.py", text="FIRST = 1\n")
mustfix_verdict = review(source_run, must_fix=True)
assert mustfix_verdict["verdict"] == "CHANGES_REQUESTED"
crossing_text = "".join(f"CROSSING_{n} = {n}\n" for n in range(8))
crossing_candidate, crossing_receipt = build(
    source_run, path="src/crossing.py", text=crossing_text, expected_state="BLOCKED",
)
source_state_before = state.load_verified(repo, source_run)
assert source_state_before["state"] == "BLOCKED"
assert "checkpoint_build_authority_exhausted" in source_state_before["terminal_reason"]
assert source_state_before["program"]["current_checkpoints"] == ["CP-01"]
assert source_state_before["program"]["checkpoints"][1]["build_pass_count"] == 3
assert crossing_receipt["segment_boundary"]["result"] == "refused"
assert crossing_receipt["segment_boundary"]["reasons"] == ["checkpoint_build_authority_exhausted"]
assert state.load_verified(repo, source_run)["last_candidate_sha"] == crossing_candidate
packet_path = source_run_root / "WORK_PACKET.md"
packet_sha = util.sha256_file(packet_path)

# The scheduler owns normal terminalization to DONE, with no worker or semantic
# attempt. This proves the continuation front door requires a true safe source.
source_done = supervisor.run_one(db_path=db_path)
assert source_done["action"] == "TERMINAL", source_done
source_job = supervisor.status(canonical_repo=repo, run_id=source_run, db_path=db_path)
assert source_job["status"] == "DONE", source_job
assert all(source_job.get(key) is None for key in (
    "worker_pid", "worker_pgid", "worker_attempt_id", "worker_role",
))

source_hashes = {
    "packet": util.sha256_file(packet_path),
    "state": util.sha256_file(state.state_path(repo, source_run)),
    "events": integrity.compute_event_chain_hash(state.events_path(repo, source_run)),
}
# Model the existing typed successor being created after an ordinary exact
# runtime commission. Its migration is sequence 1; the recovery under test
# below must append a distinct sequence 2 for the same sealed child.
successor_generation = "ofloop-v13ab-successor-generation"
runtime_generation = successor_generation
supervisor_runtime.runtime_generation = lambda: successor_generation
supervisor._current_runtime_generation = lambda: successor_generation
supervisor_claims._current_runtime_generation = lambda: successor_generation
args = [
    "program", "continue-blocked-semantic-budget", str(repo), source_run,
    "--expected-mission-id", mission_id,
    "--expected-mission-authority-sha256", mission_sha,
    "--expected-packet-sha256", packet_sha,
    "--expected-original-baseline-sha", baseline,
    "--expected-crossing-candidate-sha", crossing_candidate,
    "--expected-checkpoint-id", "CP-01",
    "--expected-approved-checkpoint-id", "CP-00",
    "--expected-approved-candidate-sha", approved_candidate,
    "--remaining-checkpoints", "CP-01",
    "--confirm", f"CONTINUE-BLOCKED-SEMANTIC-BUDGET:{mission_id}",
    "--db", str(db_path),
]
output = io.StringIO()
with contextlib.redirect_stdout(output):
    try:
        assert cli.main(args) == 0
    except SystemExit as exc:
        raise AssertionError(f"supported continuation CLI exited {exc.code}: {output.getvalue()}") from exc
continuation = json.loads(output.getvalue())
assert continuation["ok"] is True, continuation
assert continuation["source_run_unchanged"] is True
assert continuation["crossing_candidate_not_adopted"] is True
assert continuation["crossing_candidate_sha"] == crossing_candidate
child_run = continuation["run_id"]
assert child_run == program_mission._segment_run_id(mission_id, 3)
assert continuation["baseline_sha"] == approved_candidate, (continuation["baseline_sha"], approved_candidate)
assert state.load_verified(repo, source_run)["last_candidate_sha"] == crossing_candidate
assert source_hashes == {
    "packet": util.sha256_file(packet_path),
    "state": util.sha256_file(state.state_path(repo, source_run)),
    "events": integrity.compute_event_chain_hash(state.events_path(repo, source_run)),
}
assert util.sha256_file(packet_path) == packet_sha

child_packet_path = state.run_dir(repo, child_run) / "WORK_PACKET.md"
child_meta, _ = packet.parse_packet_file(child_packet_path)
child_packet_sha = util.sha256_file(child_packet_path)
assert child_packet_sha == continuation["packet_sha256"]
assert packet.validate_packet_for_approval(child_meta) == []
assert child_meta["mission_budget"]["semantic_budget_policy"] == {
    "schema": "ownframework-loop-semantic-budget-policy/v1",
    "reclaim_approved_checkpoint_capacity": True,
    "use_cumulative_slack": True,
}
child_state = state.load_verified(repo, child_run)
assert child_state["state"] == "READY_TO_BUILD"
assert child_state["last_candidate_sha"] == approved_candidate
child_segment, _, _, _ = program_mission.load_segment(repo, child_run)
assert child_segment["mission_id"] == mission_id
assert child_segment["source_admission"]["crossing_candidate_not_adopted"] is True
assert child_segment["source_admission"]["crossing_candidate_sha"] == crossing_candidate
assert child_segment["predecessor_run_id"] == source_run
assert child_segment["baseline_sha"] == approved_candidate
assert approval.load_approval(repo, child_run)["binding_kind"] == "mission_derived_seal"
child_approval = approval.load_approval(repo, child_run)
approval_valid, approval_reason = approval.validate_approval_binding(
    canonical_repo=repo, run_id=child_run, approval=child_approval,
    packet=child_meta, packet_path=child_packet_path,
)
assert approval_valid, approval_reason
child_job = supervisor.status(canonical_repo=repo, run_id=child_run, db_path=db_path)
assert child_job["status"] == "QUEUED", child_job
assert child_job["runtime_generation"] == runtime_generation

# Exercise the real counter claim, including durable allocation/event binding,
# then deterministic BUILD finalization and a normal REVIEW claim. No provider
# call is made; only the semantic body is a deterministic fixture.
child_resolution = capabilities.resolve_capabilities(
    [], canonical_repo=repo, role="builder",
    repo_cache_root=runtime_env.repo_tool_cache_dir(repo),
    ephemeral_cache_root=runtime_env.runtime_cache_dir(repo, child_run, "builder") / "capability-cache",
    evidence_run_key=child_run,
)
child_binding = capability_binding.ensure_run_binding(
    repo, child_run, child_resolution, profile, allow_create=True,
)
program_mission.bind_runtime_identity(
    repo, child_run, run_binding=child_binding, runner_profile=profile,
    runtime_generation=runtime_generation,
)
identity = program_mission.verify_runtime_identity(
    repo, mission_id, run_binding=child_binding, runner_profile=profile,
    runtime_generation=runtime_generation,
    segment_number=int(child_segment["segment_number"]),
)
assert identity["capability_binding_sha256"] == child_binding["binding_sha256"]
before_builds = child_state["program"]["cumulative_counters"]["build_pass_count"]
before_repairs = child_state["program"]["cumulative_counters"]["repair_round_count"]
sealed_cumulative_ceilings = dict(child_state["program"]["cumulative_ceilings"])
build_claim = program.claim_build_pass(canonical_repo=repo, run_id=child_run, packet=child_meta)
claimed_state = state.load_verified(repo, child_run)
allocations = claimed_state["program"]["semantic_budget_allocations"]
assert claimed_state["program"]["cumulative_ceilings"] == sealed_cumulative_ceilings
assert build_claim["cp_id"] == "CP-01", build_claim
assert build_claim["cp_pass_number"] == 4, build_claim
assert claimed_state["program"]["cumulative_counters"]["build_pass_count"] == before_builds + 1
assert claimed_state["program"]["cumulative_counters"]["repair_round_count"] == before_repairs
build_allocations = [
    item for item in allocations if item["counter_kind"] == "build_pass_count"
]
assert len(build_allocations) == 1, allocations
allocation = build_allocations[0]
assert allocation["counter_kind"] == "build_pass_count"
assert allocation["amount_borrowed"] == 1
assert allocation["source_kind"] == "approved_checkpoint_capacity"
assert allocation["source_checkpoint_id"] == "CP-00"
claim_event = integrity.read_event_chain(state.events_path(repo, child_run))[-1]
assert claim_event.get("semantic_budget_allocation_id") == allocation["allocation_id"]
assert claim_event.get("semantic_budget_counter_kind") == "build_pass_count"
assert program.verify_frozen_graph(child_meta, claimed_state["program"]) == (True, "ok")

prepared = build_prepare.prepare(canonical_repo=repo, run_id=child_run)
builder = Path(prepared["builder_worktree"])
(builder / "src" / "continued.py").parent.mkdir(parents=True, exist_ok=True)
(builder / "src" / "continued.py").write_text("CONTINUED = True\n", encoding="utf-8")
subprocess.run(["git", "-C", str(builder), "add", "--", "src/continued.py"], check=True, capture_output=True)
subprocess.run(["git", "-C", str(builder), "commit", "-qm", "v13ab funded successor build"], check=True, capture_output=True)
candidate = subprocess.check_output(["git", "-C", str(builder), "rev-parse", "HEAD"], text=True).strip()
result_path = build_agent.write_skeleton(repo, child_run, source_root=source_root, overwrite=True)
result_doc = json.loads(result_path.read_text(encoding="utf-8"))
result_doc.update({
    "summary": "funded adaptive successor build",
    "outcome_requested": "candidate_ready", "work_unit_id": "UNIT-01",
    "unit_ids_completed": ["UNIT-01"], "acceptance_addressed": ["AC-01"],
    "notes": "Deterministic fake semantic output.", "timestamp": util.utc_now_iso(),
})
result_doc["evidence"]["files_changed"] = ["src/continued.py"]
result_doc["evidence"]["diff_lines_total"] = 1
result_path.write_text(json.dumps(result_doc, sort_keys=True, indent=2) + "\n", encoding="utf-8")
build_receipt = build_finalize.finalize_build(
    canonical_repo=repo, run_id=child_run, agent_result_path=result_path,
    actor="v13ab-fixture-builder",
)
assert build_receipt["candidate_sha"] == candidate
assert build_receipt["validation_status"] == "PASS"
assert build_receipt["next_state"] == "READY_FOR_REVIEW"

# Simulate a later runtime installation. The ordinary scheduler quarantines
# the old-generation job before any new semantic claim. The supported resume
# must append a same-segment migration, preserving the sealed candidate and
# engineering counters. Replaying preparation after a crash must reuse the
# exact same record.
resumed_generation = "ofloop-v13ab-resumed-generation"
supervisor_runtime.runtime_generation = lambda: resumed_generation
supervisor._current_runtime_generation = lambda: resumed_generation
supervisor_claims._current_runtime_generation = lambda: resumed_generation
pre_resume_state = state.load_verified(repo, child_run)
pre_resume_state_sha = util.sha256_file(state.state_path(repo, child_run))
pre_resume_event_sha = integrity.compute_event_chain_hash(state.events_path(repo, child_run))
pre_resume_counts = (
    pre_resume_state["build_pass_count"], pre_resume_state["review_pass_count"],
    pre_resume_state["repair_round"],
)
quarantined = supervisor.run_one(db_path=db_path)
assert quarantined["action"] == "QUARANTINED", quarantined
quarantined_job = supervisor.status(canonical_repo=repo, run_id=child_run, db_path=db_path)
assert quarantined_job["status"] == "QUARANTINED", quarantined_job
with supervisor_db._managed_connect_readonly(db_path) as conn:
    resume_row = conn.execute(
        "SELECT * FROM jobs WHERE run_id=?", (child_run,),
    ).fetchone()
assert resume_row is not None
resume_snapshot = dict(resume_row)
worker_owned_snapshot = dict(resume_snapshot)
worker_owned_snapshot["worker_pid"] = 987654321
try:
    program_mission.prepare_runtime_generation_resume(
        repo, child_run, job_snapshot=worker_owned_snapshot,
        target_runtime_generation=resumed_generation, db_path=db_path,
    )
except program_mission.MissionAuthorityError:
    pass
else:
    raise AssertionError("same-segment runtime migration accepted an owned worker")
assert not program_mission._mission_runtime_migration_path(repo, mission_id, 2).exists()
migration_first = program_mission.prepare_runtime_generation_resume(
    repo, child_run, job_snapshot=resume_snapshot,
    target_runtime_generation=resumed_generation, db_path=db_path,
)
migration_replay = program_mission.prepare_runtime_generation_resume(
    repo, child_run, job_snapshot=resume_snapshot,
    target_runtime_generation=resumed_generation, db_path=db_path,
)
assert migration_first == migration_replay, (migration_first, migration_replay)
assert migration_first["sequence"] == 2, migration_first
resume_output = io.StringIO()
with contextlib.redirect_stdout(resume_output):
    try:
        assert cli.main(["supervisor", "resume", str(repo), child_run, "--db", str(db_path)]) == 0
    except SystemExit as exc:
        raise AssertionError(f"supported resume exited {exc.code}: {resume_output.getvalue()}") from exc
resumed = json.loads(resume_output.getvalue())
assert resumed["ok"] is True and resumed["resumed"] is True, resumed
assert resumed["runtime_generation_previous"] == successor_generation, resumed
assert resumed["runtime_generation"] == resumed_generation, resumed
assert resumed["runtime_migration"] == migration_first, resumed
assert util.sha256_file(child_packet_path) == child_packet_sha
assert util.sha256_file(state.state_path(repo, child_run)) == pre_resume_state_sha
assert integrity.compute_event_chain_hash(state.events_path(repo, child_run)) == pre_resume_event_sha
assert state.load_verified(repo, child_run)["last_candidate_sha"] == candidate
assert (
    state.load_verified(repo, child_run)["build_pass_count"],
    state.load_verified(repo, child_run)["review_pass_count"],
    state.load_verified(repo, child_run)["repair_round"],
) == pre_resume_counts
resumed_job = supervisor.status(canonical_repo=repo, run_id=child_run, db_path=db_path)
assert resumed_job["status"] == "QUEUED", resumed_job
assert resumed_job["runtime_generation"] == resumed_generation, resumed_job
runtime_binding = program_mission.bind_runtime_identity(
    repo, child_run, run_binding=child_binding, runner_profile=profile,
    runtime_generation=resumed_generation,
)
assert runtime_binding["runtime_migration_sequence"] == 2, runtime_binding
resumed_identity = program_mission.verify_runtime_identity(
    repo, mission_id, run_binding=child_binding, runner_profile=profile,
    runtime_generation=resumed_generation,
    segment_number=int(child_segment["segment_number"]),
)
assert resumed_identity["runtime_generation"] == resumed_generation, resumed_identity
assert resumed_identity["capability_binding_sha256"] == child_binding["binding_sha256"]
# Consume the segment's declared CP-01 REVIEW with one genuine must-fix,
# complete its funded BUILD repair, then require one adaptive REVIEW claim to
# approve CP-01 while leaving exactly the two whole-product final-review
# claims protected by the allocator.
child_review_one = review(
    child_run, must_fix=True, finding_path="src/continued.py",
)
assert child_review_one["verdict"] == "CHANGES_REQUESTED", child_review_one
assert state.load_verified(repo, child_run)["state"] == "CHANGES_REQUESTED"
repair_candidate, repair_receipt = build(
    child_run, path="src/continued.py", text="CONTINUED = False\n",
)
assert repair_receipt["validation_status"] == "PASS", repair_receipt
assert repair_receipt["next_state"] == "READY_FOR_REVIEW", repair_receipt
child_review_two = review(child_run)
assert child_review_two["verdict"] == "APPROVED", child_review_two
after_adaptive_review = state.load_verified(repo, child_run)
adaptive_review_allocations = [
    item for item in after_adaptive_review["program"]["semantic_budget_allocations"]
    if item["counter_kind"] == "review_pass_count"
]
assert len(adaptive_review_allocations) == 1, adaptive_review_allocations
adaptive_review_allocation = adaptive_review_allocations[0]
review_used = after_adaptive_review["program"]["cumulative_counters"]["review_pass_count"]
review_cap = after_adaptive_review["program"]["cumulative_ceilings"]["max_review_passes"]
assert adaptive_review_allocation["final_acceptance_reserve"] == 2
assert review_cap - review_used == 2, (review_cap, review_used)
assert after_adaptive_review["program"]["review_scope"] == "program_final"

# The first whole-product final review requests one legitimate repair. The
# reserved lane must permit one PROGRAM-FINAL BUILD and a second final review,
# which approves the exact post-repair candidate without changing any ceiling.
final_review_one = review(
    child_run, must_fix=True, finding_path="src/continued.py",
)
assert final_review_one["verdict"] == "CHANGES_REQUESTED", final_review_one
after_final_mustfix = state.load_verified(repo, child_run)
assert after_final_mustfix["state"] == "CHANGES_REQUESTED"
assert after_final_mustfix["program"]["review_scope"] == "program_final"
before_final_repair_ceilings = dict(after_final_mustfix["program"]["cumulative_ceilings"])
final_candidate, final_build_receipt = program_final_repair_build(
    child_run, path="src/continued.py",
)
assert final_build_receipt["work_unit_id"] == program.PROGRAM_FINAL_REPAIR_WORK_UNIT_ID
final_review_two = review(child_run)
assert final_review_two["verdict"] == "APPROVED", final_review_two
terminal = state.load_verified(repo, child_run)
assert terminal["state"] == "APPROVED", terminal
assert terminal["last_candidate_sha"] == final_candidate
assert terminal["program"]["cumulative_ceilings"] == before_final_repair_ceilings
assert terminal["program"]["cumulative_ceilings"] == sealed_cumulative_ceilings
assert terminal["program"]["cumulative_counters"]["review_pass_count"] == review_cap
assert terminal["program"]["cumulative_counters"]["repair_round_count"] == 3
assert terminal["program"]["cumulative_counters"]["build_pass_count"] <= 8
assert program.verify_frozen_graph(child_meta, terminal["program"]) == (True, "ok")
# The migration remains verifiable after ordinary engineering events advance
# the child state beyond the exact source snapshot it was created from.
program_mission.verify_runtime_identity(
    repo, mission_id, run_binding=child_binding, runner_profile=profile,
    runtime_generation=resumed_generation,
    segment_number=int(child_segment["segment_number"]),
)
assert supervisor.status(canonical_repo=repo, run_id=source_run, db_path=db_path)["status"] == "DONE"
assert supervisor.status(canonical_repo=repo, run_id=child_run, db_path=db_path)["status"] == "QUEUED"
print("BLOCKED_SOURCE_TERMINAL_WORKERLESS=PASS")
print("SUPPORTED_CLI_CONTINUATION_AND_IMMUTABLE_SUCCESSOR=PASS")
print("APPEND_ONLY_POLICY_OVERLAY_SEAL_AND_ENROLLMENT=PASS")
print("CROSSING_CANDIDATE_NOT_ADOPTED_LAST_APPROVED_BASELINE=PASS")
print("ADAPTIVE_BUILD_ALLOCATION_DURABLE_AND_CEILINGS_UNCHANGED=PASS")
print("SUCCESSOR_BUILD_FINALIZED_AND_REVIEW_CLAIMED=PASS")
print("ADAPTIVE_REVIEW_CANNOT_STARVE_REREVIEW=PASS")
print("FINAL_REVIEW_REPAIR_CYCLE_REGRESSION=PASS")
print("SAME_SEGMENT_RUNTIME_MIGRATION_CRASH_REPLAY_AND_SUPPORTED_RESUME=PASS")
PY
