#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib:$ROOT_DIR/tests/helpers:$ROOT_DIR/tests${PYTHONPATH:+:$PYTHONPATH}"
export OFLOOP_LIB="$ROOT_DIR/lib"
export PYTHONDONTWRITEBYTECODE=1
TMP="$(mktemp -d -t ofloop-v13ac-source-budget.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

python3 -B - "$TMP" "$ROOT_DIR" <<'PY'
from __future__ import annotations

import contextlib
import copy
import hashlib
import io
import json
import os
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
source_root = Path(sys.argv[2])
repo = root / "unrelated-v4-source-budget"
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
git("config", "user.name", "Loop source-budget fixture")
git("config", "user.email", "loop-source-budget@example.invalid")
(repo / ".git" / "info" / "exclude").write_text(
    "/.ownframework-loop/\n/.worktrees/ownframework-loop/\n", encoding="utf-8",
)
(repo / "README.md").write_text("disposable source-budget continuation fixture\n", encoding="utf-8")
git("add", "README.md")
git("commit", "-qm", "fixture baseline")
baseline = git("rev-parse", "HEAD")


class SourceBudgetFixtureRunner:
    runner_id = "v13ac-source-budget-fixture"

    def run(self, *args, **kwargs):
        raise AssertionError("fixture must not launch an external provider")


supervisor.register_runner(SourceBudgetFixtureRunner)
db_path = root / "state" / "ownframework-loop" / "supervisor.sqlite3"
with supervisor_db._managed_connect(db_path):
    pass

checkpoint_ids = ["CP-00", "CP-01", "CP-02"]
checkpoints = [
    {
        "id": cp_id,
        "title": f"fixture checkpoint {index}",
        "scope": "src/",
        "depends_on": [] if index == 0 else [checkpoint_ids[index - 1]],
        "acceptance_criterion_ids": [f"AC-{index:02d}"],
        "work_units": [f"UNIT-{index:02d}"],
        "risk_budget": {
            "max_build_passes": 2,
            "max_review_passes": 2,
            "max_repair_rounds": 1,
        },
    }
    for index, cp_id in enumerate(checkpoint_ids)
]
meta = {
    "schema": packet.MISSION_PROGRAM_SCHEMA_VERSION,
    "packet_id": "v13ac-blocked-source-budget",
    "created_at": "2026-09-30T00:00:00Z",
    "work_class": "FEATURE",
    "risk_class": "low",
    "title": "typed blocked source-budget continuation fixture",
    "runner_profile": "default",
    "target": {
        "repo": str(repo.resolve()), "branch": "master",
        "classification": "local_only", "expected_baseline_sha": baseline,
    },
    "execution_mode": "program",
    "checkpoint_graph": {
        "execution_order": checkpoint_ids,
        "checkpoints": checkpoints,
        "global_source_ceilings": {
            "max_unique_changed_files": 20,
            "max_baseline_to_final_diff_lines": 12,
        },
    },
    "mission_budget": {
        "schema": "ownframework-loop-mission-budget/v1",
        "auto_segment": True,
        "segment_max_diff_lines": 12,
        "mission_max_diff_lines": 18,
        "max_segments": 2,
        "segment_boundary_policy": "last_approved_checkpoint",
        "semantic_budget_policy": {
            "schema": "ownframework-loop-semantic-budget-policy/v1",
            "reclaim_approved_checkpoint_capacity": True,
            "use_cumulative_slack": True,
        },
    },
    "promotion_policy": "human_gate",
    "acceptance_criteria": [
        {"id": f"AC-{index:02d}", "text": f"fixture checkpoint {index} is implemented"}
        for index in range(3)
    ],
    "non_goals": [],
    "required_validation": [{"name": "fixture", "command": "true", "kind": "fast"}],
    "allowed_paths": ["src/"],
    "protected_paths": [".ownframework-loop/", ".worktrees/"],
    "work_units": [
        {"id": f"UNIT-{index:02d}", "title": f"unit {index}", "scope": "src/"}
        for index in range(3)
    ],
    "merge_authority": "human_only",
    "deploy_authority": "human_only",
    "push_authority": "human_only",
    "external_action_authority": "none",
    "risk_budget": {
        "max_build_passes": 8,
        "max_review_passes": 9,
        "max_repair_rounds": 5,
        "max_files_changed": 20,
        "max_diff_lines": 12,
        "max_consecutive_no_progress_passes": 8,
        "max_identical_finding_repeats": 8,
    },
}
packet_errors = packet.validate_packet_for_approval(meta)
assert packet_errors == [], packet_errors

source_run = "run-2026-09-30-v13ac-parent"
source_root_run = state.run_dir(repo, source_run)
source_root_run.mkdir(parents=True)
(source_root_run / "WORK_PACKET.md").write_text(
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
    new_state="AWAITING_APPROVAL", actor="v13ac-fixture", reason="sealed source-budget fixture",
)
execution_start.ensure_executable(canonical_repo=repo, run_id=source_run, actor="v13ac-fixture")
runtime_generation = supervisor_runtime.runtime_generation()
enrolled = supervisor.enqueue(
    canonical_repo=repo, run_id=source_run,
    runner=SourceBudgetFixtureRunner.runner_id, db_path=db_path,
    max_total_cost_usd=10.0, max_total_tokens=100000, max_wall_seconds=0,
    runtime_generation=runtime_generation,
)
assert enrolled.get("ok") is True, enrolled

real_take_next = supervisor_claims._take_next_job
supervisor_claims._take_next_job = lambda conn: None
try:
    initialized = supervisor.run_one(db_path=db_path)
finally:
    supervisor_claims._take_next_job = real_take_next
assert initialized.get("action") == "IDLE", initialized

profile = runner_profiles.resolve_profile("default", provider=SourceBudgetFixtureRunner.runner_id)
resolution = capabilities.resolve_capabilities(
    [], canonical_repo=repo, role="builder",
    repo_cache_root=runtime_env.repo_tool_cache_dir(repo),
    ephemeral_cache_root=runtime_env.runtime_cache_dir(repo, source_run, "builder") / "capability-cache",
    evidence_run_key=source_run,
)
binding = capability_binding.ensure_run_binding(repo, source_run, resolution, profile, allow_create=True)
assert program_mission.bind_runtime_identity(
    repo, source_run, run_binding=binding, runner_profile=profile,
    runtime_generation=runtime_generation,
)
source_mission_id = program_mission.load_segment(repo, source_run)[2]["mission_id"]


def packet_for(run_id: str) -> dict:
    return packet.parse_packet_file(state.run_dir(repo, run_id) / "WORK_PACKET.md")[0]


def bind_run(run_id: str) -> None:
    run_profile = runner_profiles.resolve_profile("default", provider=SourceBudgetFixtureRunner.runner_id)
    resolution = capabilities.resolve_capabilities(
        [], canonical_repo=repo, role="builder",
        repo_cache_root=runtime_env.repo_tool_cache_dir(repo),
        ephemeral_cache_root=runtime_env.runtime_cache_dir(repo, run_id, "builder") / "capability-cache",
        evidence_run_key=run_id,
    )
    run_binding = capability_binding.ensure_run_binding(
        repo, run_id, resolution, run_profile, allow_create=True,
    )
    child_segment, _, child_mission, _ = program_mission.load_segment(repo, run_id)
    assert program_mission.verify_runtime_identity(
        repo, child_mission["mission_id"], run_binding=run_binding,
        runner_profile=run_profile, runtime_generation=runtime_generation,
        segment_number=int(child_segment["segment_number"]),
    )


def build(run_id: str, *, path: str, text: str, expected_state: str) -> tuple[str, dict]:
    run_meta = packet_for(run_id)
    current = state.load_verified(repo, run_id)
    cp_id = current["program"]["current_checkpoints"][0]
    cp = next(row for row in run_meta["checkpoint_graph"]["checkpoints"] if row["id"] == cp_id)
    claim = program.claim_build_pass(canonical_repo=repo, run_id=run_id, packet=run_meta)
    prepared = build_prepare.prepare(canonical_repo=repo, run_id=run_id)
    builder = Path(prepared["builder_worktree"])
    target = builder / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")
    subprocess.run(["git", "-C", str(builder), "add", "--", path], check=True, capture_output=True)
    subprocess.run(
        ["git", "-C", str(builder), "commit", "-qm", f"v13ac {cp_id} build {claim['cp_pass_number']}"],
        check=True, capture_output=True,
    )
    candidate = subprocess.check_output(["git", "-C", str(builder), "rev-parse", "HEAD"], text=True).strip()
    result_path = build_agent.write_skeleton(repo, run_id, source_root=source_root, overwrite=True)
    result = json.loads(result_path.read_text(encoding="utf-8"))
    result.update({
        "summary": f"fixture implementation for {cp_id}",
        "outcome_requested": "candidate_ready",
        "work_unit_id": cp["work_units"][0],
        "unit_ids_completed": [cp["work_units"][0]],
        "acceptance_addressed": cp["acceptance_criterion_ids"],
        "notes": "Deterministic fixture output; production finalizer is used.",
        "timestamp": util.utc_now_iso(),
    })
    result["evidence"]["files_changed"] = [path]
    result["evidence"]["diff_lines_total"] = len(text.splitlines())
    result_path.write_text(json.dumps(result, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    receipt = build_finalize.finalize_build(
        canonical_repo=repo, run_id=run_id,
        agent_result_path=result_path, actor="v13ac-fixture-builder",
    )
    assert receipt["candidate_sha"] == candidate, receipt
    assert receipt["next_state"] == expected_state, receipt
    return candidate, receipt


def review(run_id: str, *, changes_requested: bool) -> dict:
    run_meta = packet_for(run_id)
    current = state.load_verified(repo, run_id)
    cp_id = current["program"]["current_checkpoints"][0]
    cp = next(row for row in run_meta["checkpoint_graph"]["checkpoints"] if row["id"] == cp_id)
    program.claim_review_pass(canonical_repo=repo, run_id=run_id, packet=run_meta)
    review_prepare.prepare(canonical_repo=repo, run_id=run_id)
    assessment_path = assessment.write_skeleton(repo, run_id, source_root=source_root, overwrite=True)
    doc = json.loads(assessment_path.read_text(encoding="utf-8"))
    doc["acceptance_results"] = [
        {"id": item, "result": "pass", "evidence": "Fixture candidate commit is bound."}
        for item in cp["acceptance_criterion_ids"]
    ]
    doc["non_goal_results"] = []
    doc["validation_results"] = []
    doc["findings"] = ([{
        "finding_id": "F-V13AC-REPAIR", "severity": "high",
        "classification": "must_fix", "title": "bounded fixture repair",
        "description": "Exercise a legitimate second build within the sealed envelope.",
        "file": "src/base.py", "line": 1,
    }] if changes_requested else [])
    doc["recommended_verdict"] = "CHANGES_REQUESTED" if changes_requested else "APPROVED"
    doc["review_scope"] = "checkpoint"
    doc["timestamp"] = util.utc_now_iso()
    assessment_path.write_text(json.dumps(doc, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    return review_finalize.finalize_review(
        canonical_repo=repo, run_id=run_id,
        assessment_path=assessment_path, actor="v13ac-fixture-reviewer",
    )


# Produce genuine adaptive semantic allocations and approve CP-00. Then create
# an ordinary segment boundary so the blocked CP-01 receipt is measured from a
# segment baseline distinct from the mission's original baseline.
approved_candidate, _ = build(
    source_run, path="src/base.py", text="BASE = 1\n", expected_state="READY_FOR_REVIEW",
)
assert review(source_run, changes_requested=True)["verdict"] == "CHANGES_REQUESTED"
approved_candidate, _ = build(
    source_run, path="src/base.py", text="BASE = 2\n", expected_state="READY_FOR_REVIEW",
)
assert review(source_run, changes_requested=True)["verdict"] == "CHANGES_REQUESTED"
approved_candidate, _ = build(
    source_run, path="src/base.py", text="BASE = 3\n", expected_state="READY_FOR_REVIEW",
)
assert review(source_run, changes_requested=False)["verdict"] == "APPROVED"
before_blocked = state.load_verified(repo, source_run)
source_allocations = before_blocked["program"]["semantic_budget_allocations"]
assert len(source_allocations) == 3, source_allocations
assert {item["counter_kind"] for item in source_allocations} == {
    "build_pass_count", "review_pass_count", "repair_round_count",
}
assert all(item["source_kind"] == "mission_cumulative_slack" for item in source_allocations)

# The first candidate exceeds the segment ceiling while remaining below the
# mission ceiling. Ordinary segmentation must carry only approved CP-00.
_, first_boundary = build(
    source_run, path="src/first-crossing.py",
    text="".join(f"FIRST_{index} = {index}\n" for index in range(13)),
    expected_state="SEGMENT_BOUNDARY",
)
assert first_boundary["segment_boundary"]["result"] == "authorized", first_boundary
assert supervisor.run_one(db_path=db_path)["action"] == "TERMINAL"
source_run = program_mission._segment_run_id(source_mission_id, 2)
bind_run(source_run)
assert program_mission.load_segment(repo, source_run)[0]["baseline_sha"] == approved_candidate

crossing_candidate, crossing_receipt = build(
    source_run,
    path="src/oversized_checkpoint.py",
    text="".join(f"ROW_{index} = {index}\n" for index in range(21)),
    expected_state="BLOCKED",
)
assert crossing_receipt["validation_status"] == "PASS"
assert crossing_receipt["program_source_ceiling_check"]["result"] == "fail"
assert crossing_receipt["program_source_ceiling_check"]["mission_budget_result"] == "fail"
assert crossing_receipt["scope_check"]["result"] == "pass"
assert crossing_receipt["protected_path_check"]["result"] == "pass"
assert crossing_receipt["candidate_identity_reproof"]["result"] == "pass"
assert crossing_receipt["infra_failure"]["count"] == 0
assert crossing_receipt["candidate_environment_invalid"]["count"] == 0
blocked = state.load_verified(repo, source_run)
assert blocked["state"] == "BLOCKED"
assert blocked["last_candidate_sha"] == crossing_candidate
assert blocked["program"]["current_checkpoints"] == ["CP-01"]
assert blocked["program"]["finalized_checkpoints"][-1]["id"] == "CP-00"
assert crossing_receipt["baseline_sha"] == approved_candidate
assert crossing_receipt["program_source_ceiling_check"]["mission_source_lines_total"] > 18

source_job_terminal = supervisor.run_one(db_path=db_path)
assert source_job_terminal["action"] == "TERMINAL", source_job_terminal
source_job = supervisor.status(canonical_repo=repo, run_id=source_run, db_path=db_path)
assert source_job["status"] == "DONE", source_job
assert all(source_job.get(key) is None for key in (
    "worker_pid", "worker_pgid", "worker_attempt_id", "worker_role",
))

source_loaded = program_mission.load_segment(repo, source_run)
source_segment, source_segment_sha, source_mission, source_mission_sha = source_loaded
source_packet_path = state.run_dir(repo, source_run) / "WORK_PACKET.md"
source_hashes = {
    "packet": util.sha256_file(source_packet_path),
    "state": util.sha256_file(state.state_path(repo, source_run)),
    "events": integrity.compute_event_chain_hash(state.events_path(repo, source_run)),
    "approval": util.sha256_file(approval.approval_path(repo, source_run)),
    "receipt": util.sha256_file(state.run_dir(repo, source_run) / "BUILD_RECEIPT.json"),
    "mission": source_mission_sha,
    "segment": source_segment_sha,
}
source_counters = copy.deepcopy(blocked["program"]["cumulative_counters"])
source_semantic_allocations = copy.deepcopy(blocked["program"]["semantic_budget_allocations"])

# Model commissioning the exact source fix before recovery. The blocked
# predecessor stays bound to its original generation; the supported typed
# runtime migration must authorize the new successor generation.
installed_generation = "ofloop-test@payload-" + hashlib.sha256(
    (runtime_generation + ":source-budget-successor").encode("utf-8")
).hexdigest()
supervisor_runtime.runtime_generation = lambda: installed_generation

args = [
    "program", "continue-blocked-source-budget", str(repo), source_run,
    "--expected-mission-id", source_mission["mission_id"],
    "--expected-mission-authority-sha256", source_mission_sha,
    "--expected-packet-sha256", source_hashes["packet"],
    "--expected-original-baseline-sha", baseline,
    "--expected-crossing-candidate-sha", crossing_candidate,
    "--expected-checkpoint-id", "CP-01",
    "--expected-approved-checkpoint-id", "CP-00",
    "--expected-approved-candidate-sha", approved_candidate,
    "--remaining-checkpoints", "CP-01,CP-02",
    "--segment-max-diff-lines", "50",
    "--mission-max-diff-lines", "95",
    "--max-segments", "3",
    "--confirm", f"CONTINUE-BLOCKED-SOURCE-BUDGET:{source_mission['mission_id']}",
    "--db", str(db_path),
]
# An invalid but structurally bounded segment ceiling must be rejected before
# the supported append-only runtime migration is published. This exercises the
# real blocked predecessor under a simulated newly installed generation.
crossing_segment_lines = program_mission._line_count(
    repo, str(source_segment["baseline_sha"]), crossing_candidate,
)
assert crossing_segment_lines > 0
invalid_args = list(args)
invalid_args[invalid_args.index("--segment-max-diff-lines") + 1] = str(crossing_segment_lines)
try:
    cli.main(invalid_args)
except (SystemExit, program_mission.MissionAuthorityError):
    pass
else:
    raise AssertionError("source-budget continuation accepted a segment ceiling at the crossing delta")
assert not program_mission._mission_runtime_migration_path(
    repo, source_mission["mission_id"], 1,
).exists(), "invalid source envelope must not publish a runtime migration"
assert source_hashes == {
    "packet": util.sha256_file(source_packet_path),
    "state": util.sha256_file(state.state_path(repo, source_run)),
    "events": integrity.compute_event_chain_hash(state.events_path(repo, source_run)),
    "approval": util.sha256_file(approval.approval_path(repo, source_run)),
    "receipt": util.sha256_file(state.run_dir(repo, source_run) / "BUILD_RECEIPT.json"),
    "mission": program_mission.load_segment(repo, source_run)[3],
    "segment": program_mission.load_segment(repo, source_run)[1],
}
print("INVALID_SOURCE_ENVELOPE_PUBLISHES_NO_MIGRATION=PASS")
output = io.StringIO()
with contextlib.redirect_stdout(output):
    try:
        assert cli.main(args) == 0
    except SystemExit as exc:
        raise AssertionError(f"source-budget continuation CLI exited {exc.code}: {output.getvalue()}") from exc
continuation = json.loads(output.getvalue())
assert continuation["ok"] is True, continuation
child_run = continuation["run_id"]
assert continuation["baseline_sha"] == approved_candidate
assert continuation["approved_checkpoint_id"] == "CP-00"
assert continuation["crossing_candidate_sha"] == crossing_candidate
assert continuation["crossing_candidate_not_adopted"] is True
assert continuation["predecessor_run_unchanged"] is True
assert continuation["preserved_cumulative_counters"] == source_counters
assert continuation["semantic_allocation_import_count"] == len(source_semantic_allocations)
assert continuation["runtime_generation"] == installed_generation
assert continuation["runtime_migration"]["sequence"] == 1
assert continuation["runtime_migration"]["runtime_generation"] == installed_generation
assert len(continuation["runtime_migration"]["sha256"]) == 64

child_packet_path = state.run_dir(repo, child_run) / "WORK_PACKET.md"
child_meta, _ = packet.parse_packet_file(child_packet_path)
assert packet.validate_packet_for_approval(child_meta) == []
ordinary_wide = copy.deepcopy(meta)
ordinary_wide["mission_budget"]["segment_max_diff_lines"] = 30001
ordinary_wide["mission_budget"]["mission_max_diff_lines"] = 30001
ordinary_wide["risk_budget"]["max_diff_lines"] = 30001
ordinary_wide["checkpoint_graph"]["global_source_ceilings"]["max_baseline_to_final_diff_lines"] = 30001
assert packet.validate_packet_for_approval(ordinary_wide), "ordinary v4 packet must retain the 30000-line ceiling"
typed_wide = copy.deepcopy(child_meta)
typed_wide["mission_budget"]["segment_max_diff_lines"] = 100001
typed_wide["mission_budget"]["mission_max_diff_lines"] = 100001
typed_wide["risk_budget"]["max_diff_lines"] = 100001
typed_wide["checkpoint_graph"]["global_source_ceilings"]["max_baseline_to_final_diff_lines"] = 100001
assert packet.validate_packet_for_approval(typed_wide), "typed continuation must retain its 100000-line ceiling"
assert child_meta["mission_budget"]["segment_max_diff_lines"] == 50
assert child_meta["mission_budget"]["mission_max_diff_lines"] == 95
assert child_meta["mission_budget"]["max_segments"] == 3
assert child_meta["risk_budget"]["max_diff_lines"] == 50
assert child_meta["checkpoint_graph"]["global_source_ceilings"]["max_baseline_to_final_diff_lines"] == 95
print("SEGMENT_AND_MISSION_SOURCE_CEILINGS_DISTINCT=PASS")
assert child_meta["mission_budget"]["semantic_budget_policy"] == meta["mission_budget"]["semantic_budget_policy"]
assert child_meta["risk_budget"]["max_build_passes"] == meta["risk_budget"]["max_build_passes"]
assert child_meta["risk_budget"]["max_review_passes"] == meta["risk_budget"]["max_review_passes"]
assert child_meta["risk_budget"]["max_repair_rounds"] == meta["risk_budget"]["max_repair_rounds"]
assert child_meta["checkpoint_graph"]["execution_order"] == checkpoint_ids
assert program.packet_acceptance_criterion_ids(child_meta) == [f"AC-{n:02d}" for n in range(3)]

child_segment, _, child_mission, _ = program_mission.load_segment(repo, child_run)
child_state = state.load_verified(repo, child_run)
assert child_state["state"] == "READY_TO_BUILD"
assert child_state["last_candidate_sha"] == approved_candidate
assert child_state["program"]["current_checkpoints"] == ["CP-01"]
assert [row["id"] for row in child_state["program"]["finalized_checkpoints"]] == ["CP-00"]
assert child_segment["baseline_sha"] == approved_candidate
approved_source_stats = program.source_tree_accounting(
    canonical_repo=repo, baseline_sha=baseline, candidate_sha=approved_candidate,
)
child_source_budget = program_mission.source_budget_for_candidate(
    repo, child_segment["run_id"], approved_candidate,
)
source_continuation_record, _ = program_mission._read_record(
    program_mission._source_budget_continuation_path(repo, child_mission["mission_id"]),
    expected_schema=program_mission.SOURCE_BUDGET_CONTINUATION_SCHEMA,
)
assert source_continuation_record["predecessor_runtime_generation"] == runtime_generation
assert source_continuation_record["runtime_generation"] == installed_generation
assert source_continuation_record["runtime_migration"] == continuation["runtime_migration"]
runtime_migration_record, runtime_migration_sha = program_mission._read_runtime_migration_record(
    program_mission._mission_runtime_migration_path(
        repo, source_mission["mission_id"], continuation["runtime_migration"]["sequence"],
    ),
)
assert runtime_migration_sha == continuation["runtime_migration"]["sha256"]
assert runtime_migration_record["previous_runtime_generation"] == runtime_generation
assert runtime_migration_record["runtime_generation"] == installed_generation
assert runtime_migration_record["source_authority"]["run_id"] == source_run
assert runtime_migration_record["source_authority"]["approved_candidate_sha"] == approved_candidate
assert runtime_migration_record["source_authority"]["crossing_candidate_sha"] == crossing_candidate
assert child_source_budget["mission_source_lines_total"] == approved_source_stats["diff_lines"]
assert child_source_budget["mission_source_lines_total"] == source_continuation_record["approved_source_lines"]
assert child_segment["predecessor_run_id"] == source_run
assert child_segment["source_admission"]["kind"] == "blocked_source_budget_continuation"
assert child_segment["source_admission"]["crossing_candidate_not_adopted"] is True
assert child_segment["source_admission"]["crossing_candidate_sha"] == crossing_candidate
assert child_segment["candidate_branch"] != source_segment["candidate_branch"]
child_counters = child_state["program"]["cumulative_counters"]
for key in ("build_pass_count", "review_pass_count", "repair_round_count"):
    assert child_counters[key] == source_counters[key], (key, child_counters, source_counters)
# Source deltas in the new execution state are relative to the exact approved
# CP-00 baseline; the immutable continuation authority separately accounts for
# the inherited original-baseline source usage.
assert child_counters["diff_lines_total"] == 0
assert child_counters["files_changed_unique"] == 0
source_ceiling = child_state["program"]["cumulative_ceilings"]
blocked_ceiling = blocked["program"]["cumulative_ceilings"]
for key in ("max_build_passes", "max_review_passes", "max_repair_rounds", "max_unique_changed_files"):
    assert source_ceiling[key] == blocked_ceiling[key], (key, source_ceiling, blocked_ceiling)
assert source_ceiling["max_baseline_to_final_diff_lines"] == 95
assert child_mission["mission_max_diff_lines"] == 95
continuation_status = program_mission.mission_status(
    repo, child_mission["mission_id"], db_path=db_path,
)
assert continuation_status["mission_source_lines_used"] == approved_source_stats["diff_lines"]
assert continuation_status["mission_source_lines_remaining"] == 95 - approved_source_stats["diff_lines"]
assert len(child_state["program"]["semantic_budget_allocations"]) == len(source_semantic_allocations)
imported = child_state["program"]["semantic_budget_allocations"]
assert all(item["mission_id"] == child_mission["mission_id"] for item in imported), imported
assert all(item["source_authority_sha256"] == program.semantic_budget_policy_sha256(child_meta) for item in imported)
materialized_events = [
    event for event in integrity.read_event_chain(state.events_path(repo, child_run))
    if event.get("event_type") == "mission_segment_materialized"
]
assert len(materialized_events) == 1, materialized_events
materialized = materialized_events[0]
expected_import_sha = hashlib.sha256(
    integrity.canonical_json_dumps(imported).encode("utf-8")
).hexdigest()
assert materialized["event_type"] == "mission_segment_materialized", materialized
assert materialized["semantic_budget_import_sha256"] == expected_import_sha
assert materialized["semantic_budget_import_count"] == len(imported)
assert program.verify_frozen_graph(child_meta, child_state["program"]) == (True, "ok")

# A widened packet is not a generic human-sealable first segment: it must
# arrive with the exact immutable source-continuation and segment authority.
try:
    program_mission.ensure_initial_segment(
        repo, child_run, meta=child_meta, seal=approval.load_approval(repo, child_run),
    )
except program_mission.MissionAuthorityError:
    pass
else:
    raise AssertionError("generic initial-segment admission accepted typed source-budget authority")

child_job = supervisor.status(canonical_repo=repo, run_id=child_run, db_path=db_path)
assert child_job["status"] == "QUEUED", child_job
assert child_job["runtime_generation"] == installed_generation

# Deterministic replay must reuse exactly one successor enrollment and leave
# the historical blocked run byte-for-byte unchanged.
replay_output = io.StringIO()
with contextlib.redirect_stdout(replay_output):
    try:
        assert cli.main(args) == 0
    except SystemExit as exc:
        raise AssertionError(f"source-budget replay exited {exc.code}: {replay_output.getvalue()}") from exc
replay = json.loads(replay_output.getvalue())
assert replay["run_id"] == child_run
assert replay["source_budget_continuation_sha256"] == continuation["source_budget_continuation_sha256"]
assert replay["runtime_migration"] == continuation["runtime_migration"]
assert source_hashes == {
    "packet": util.sha256_file(source_packet_path),
    "state": util.sha256_file(state.state_path(repo, source_run)),
    "events": integrity.compute_event_chain_hash(state.events_path(repo, source_run)),
    "approval": util.sha256_file(approval.approval_path(repo, source_run)),
    "receipt": util.sha256_file(state.run_dir(repo, source_run) / "BUILD_RECEIPT.json"),
    "mission": program_mission.load_segment(repo, source_run)[3],
    "segment": program_mission.load_segment(repo, source_run)[1],
}
assert state.load_verified(repo, source_run)["last_candidate_sha"] == crossing_candidate
with supervisor_db._managed_connect_readonly(db_path) as conn:
    rows = conn.execute("SELECT count(*) FROM jobs WHERE repo=? AND run_id=?", (str(repo), child_run)).fetchone()
assert int(rows[0]) == 1

# The typed reference must distinguish the blocked crossing candidate from
# the approved baseline even before the create-once authority is resolved.
altered = copy.deepcopy(child_meta)
altered["mission_budget"]["source_budget_continuation"]["crossing_candidate_sha"] = approved_candidate
assert packet.validate_packet_for_approval(altered), "reference alteration must be rejected structurally"
altered["mission_budget"]["source_budget_continuation"]["crossing_candidate_sha"] = baseline
assert packet.validate_packet_for_approval(altered) == []
try:
    program_mission._verify_source_budget_continuation(
        repo, meta=altered, mission=child_mission, segment=child_segment,
        program_state=child_state["program"],
    )
except program_mission.MissionAuthorityError:
    pass
else:
    raise AssertionError("a syntactically valid ref cannot replace its immutable source authority")

print("SOURCE_CEILING_BLOCK_REPRODUCED=PASS")
print("EXACT_APPROVED_BASELINE_REUSED=PASS")
print("BLOCKED_CROSSING_CANDIDATE_NOT_ADOPTED=PASS")
print("SEMANTIC_COUNTERS_AND_ALLOCATION_PREFIX_PRESERVED=PASS")
print("TYPED_SOURCE_AUTHORITY_AND_BUDGETS_BOUND=PASS")
print("SOURCE_BUDGET_RUNTIME_MIGRATION_BOUND=PASS")
print("CP15_WHOLE_GRAPH_AND_FINAL_ACCEPTANCE_PRESERVED=PASS")
print("GENERIC_WIDENED_PACKET_ADMISSION_REFUSED=PASS")
print("SOURCE_CONTINUATION_REPLAY_IDEMPOTENT=PASS")
print("PREDECESSOR_ENGINEERING_EVIDENCE_IMMUTABLE=PASS")
PY
