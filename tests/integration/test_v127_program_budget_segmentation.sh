#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib:$ROOT_DIR/tests/helpers:$ROOT_DIR/tests${PYTHONPATH:+:$PYTHONPATH}"
export OFLOOP_LIB="$ROOT_DIR/lib"
export PYTHONDONTWRITEBYTECODE=1
TMP="$(mktemp -d -t ofloop-v127-mission-segments.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

python3 -B - "$TMP" "$ROOT_DIR" <<'PY'
from __future__ import annotations

import copy
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
source_root = Path(sys.argv[2])
os.environ["XDG_STATE_HOME"] = str(root / "state")

from ownframework_loop import (
    approval, assessment, build_agent, build_finalize, build_prepare,
    capabilities, capability_binding, execution_start, git_checks, integrity, packet,
    program, program_mission, review_finalize, review_prepare,
    runner_profiles, runtime_env, state, supervisor, supervisor_db,
    supervisor_claims, supervisor_runtime, util, verdicts, worktrees,
)

# Legacy v3 stores finalized evidence on the finalized-checkpoint projection,
# not on the mutable per-checkpoint progress row.
legacy_evidence_state = {
    "checkpoints": [{"id": "CP-09", "terminal": "APPROVED"}],
    "finalized_checkpoints": [{
        "id": "CP-09", "terminal_state": "APPROVED",
        "evidence_sha256": "a" * 64,
    }],
}
assert program_mission._finalized_checkpoint_evidence_sha256(
    legacy_evidence_state, "CP-09",
) == "a" * 64
assert program_mission._finalized_checkpoint_evidence_sha256(
    {**legacy_evidence_state, "finalized_checkpoints": [{
        "id": "CP-09", "terminal_state": "APPROVED", "evidence_sha256": "z" * 64,
    }]},
    "CP-09",
) is None
assert program_mission._finalized_checkpoint_evidence_sha256(
    {**legacy_evidence_state, "finalized_checkpoints": legacy_evidence_state["finalized_checkpoints"] * 2},
    "CP-09",
) is None
print("LEGACY_FINALIZED_EVIDENCE_BINDING_LOCATION_AND_SHAPE=PASS")


class MissionFixtureRunner:
    runner_id = "v127-mission-fixture"

    def run(self, *args, **kwargs):
        raise AssertionError("v127 deterministic fixture must not launch a provider")


supervisor.register_runner(MissionFixtureRunner)
db_path = root / "state" / "ownframework-loop" / "supervisor.sqlite3"
with supervisor_db._managed_connect(db_path):
    pass


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args], capture_output=True, text=True,
    )
    if result.returncode:
        raise AssertionError(f"git {args!r} failed: {result.stderr}")
    return result.stdout.strip()


def make_repo(name: str) -> tuple[Path, str]:
    repo = root / name
    repo.mkdir()
    git(repo, "init", "-q", "-b", "master")
    git(repo, "config", "user.name", "Loop v127 fixture")
    git(repo, "config", "user.email", "loop-v127@example.invalid")
    (repo / ".git" / "info" / "exclude").write_text(
        "/.ownframework-loop/\n/.worktrees/ownframework-loop/\n",
        encoding="utf-8",
    )
    (repo / "README.md").write_text("disposable v127 mission fixture\n", encoding="utf-8")
    git(repo, "add", "README.md")
    git(repo, "commit", "-qm", "fixture baseline")
    return repo, git(repo, "rev-parse", "HEAD")


def v4_packet(repo: Path, baseline: str, *, auto_segment: bool = True,
              segment_lines: int = 10, mission_lines: int = 100,
              max_segments: int = 2, checkpoint_count: int = 3,
              checkpoint_risk_budgets: list[dict] | None = None,
              global_risk_budget: dict | None = None) -> dict:
    order = [f"CP-{index:02d}" for index in range(checkpoint_count)]
    checkpoints = []
    acceptance = []
    units = []
    for index, cp_id in enumerate(order):
        ac_id = f"AC-{index:02d}"
        unit_id = f"UNIT-{index:02d}"
        acceptance.append({"id": ac_id, "text": f"fixture acceptance {index}"})
        units.append({"id": unit_id, "title": f"fixture unit {index}", "scope": "src/"})
        checkpoint_budget = (
            dict(checkpoint_risk_budgets[index])
            if checkpoint_risk_budgets is not None
            else {
                "max_build_passes": 3,
                "max_review_passes": 3,
                "max_repair_rounds": 1,
            }
        )
        checkpoints.append({
            "id": cp_id,
            "title": f"fixture checkpoint {index}",
            "scope": "src/",
            "depends_on": [] if index == 0 else [order[index - 1]],
            "acceptance_criterion_ids": [ac_id],
            "work_units": [unit_id],
            "risk_budget": checkpoint_budget,
        })
    global_budget = {
        "max_build_passes": checkpoint_count * 3,
        "max_review_passes": checkpoint_count * 4 + 1,
        "max_repair_rounds": checkpoint_count,
        "max_files_changed": 10,
        "max_diff_lines": segment_lines,
    }
    if global_risk_budget is not None:
        global_budget.update(global_risk_budget)
    return {
        "schema": "ownframework-work-packet/v4",
        "packet_id": "v127-segmented-mission",
        "created_at": "2026-09-29T00:00:00Z",
        "work_class": "FEATURE",
        "risk_class": "low",
        "title": "v127 bounded source segment lifecycle",
        "runner_profile": "default",
        "target": {
            "repo": str(repo.resolve()),
            "branch": "master",
            "classification": "local_only",
            "expected_baseline_sha": baseline,
        },
        "execution_mode": "program",
        "checkpoint_graph": {
            "execution_order": order,
            "checkpoints": checkpoints,
            "global_source_ceilings": {
            "max_unique_changed_files": 10,
            "max_baseline_to_final_diff_lines": mission_lines,
            },
        },
        "mission_budget": {
            "schema": "ownframework-loop-mission-budget/v1",
            "auto_segment": auto_segment,
            "segment_max_diff_lines": segment_lines,
            "mission_max_diff_lines": mission_lines,
            "max_segments": max_segments,
            "segment_boundary_policy": "last_approved_checkpoint",
        },
        "promotion_policy": "human_gate",
        "acceptance_criteria": acceptance,
        "non_goals": [],
        "required_validation": [{"name": "fixture-validation", "command": "true", "kind": "fast"}],
        "allowed_paths": ["src/"],
        "protected_paths": [".ownframework-loop/", ".worktrees/"],
        "work_units": units,
        "merge_authority": "human_only",
        "deploy_authority": "human_only",
        "push_authority": "human_only",
        "external_action_authority": "none",
        "risk_budget": global_budget,
    }


def start_v4(repo: Path, baseline: str, run_id: str, *, meta: dict | None = None) -> dict:
    meta = meta or v4_packet(repo, baseline)
    errors = packet.validate_packet_for_approval(meta)
    assert not errors, errors
    run_root = state.run_dir(repo, run_id)
    run_root.mkdir(parents=True)
    (run_root / "WORK_PACKET.md").write_text(
        "```json\n" + json.dumps(meta, sort_keys=True, indent=2) + "\n```\nfixture\n",
        encoding="utf-8",
    )
    initial = state.initial_state(run_id)
    initial.update({
        "spec_baseline_branch": "master",
        "spec_baseline_sha": baseline,
        "spec_snapshot_at": util.utc_now_iso(),
    })
    state.save(repo, run_id, initial)
    state.append_event(
        repo, run_id, event_type="run_created", old_state=None,
        new_state="AWAITING_APPROVAL", actor="v127-spec", reason="v4 fixture packet",
    )
    seal = execution_start.ensure_executable(
        canonical_repo=repo, run_id=run_id, actor="v127-seal",
    )
    runtime_generation = supervisor_runtime.runtime_generation()
    enqueue = supervisor.enqueue(
        canonical_repo=repo,
        run_id=run_id,
        runner=MissionFixtureRunner.runner_id,
        db_path=db_path,
        max_total_cost_usd=50.0,
        max_total_tokens=100000,
        max_wall_seconds=0,
        runtime_generation=runtime_generation,
    )
    assert enqueue.get("ok") is True, enqueue
    # The normal scheduler, not fixture setup, must materialize the first
    # mission segment after the queued row supplies its operational envelope
    # and before any semantic pass can be claimed.
    real_take_next_job = supervisor_claims._take_next_job
    def assert_segment_bound_before_claim(conn):
        assert program_mission.load_segment(repo, run_id) is not None
        return None
    supervisor_claims._take_next_job = assert_segment_bound_before_claim
    try:
        setup_result = supervisor.run_one(db_path=db_path)
    finally:
        supervisor_claims._take_next_job = real_take_next_job
    assert setup_result.get("action") == "IDLE", setup_result
    assert program_mission.load_segment(repo, run_id) is not None
    profile = runner_profiles.resolve_profile("default", provider=MissionFixtureRunner.runner_id)
    resolution = capabilities.resolve_capabilities(
        [], canonical_repo=repo, role="builder",
        repo_cache_root=runtime_env.repo_tool_cache_dir(repo),
        ephemeral_cache_root=runtime_env.runtime_cache_dir(repo, run_id, "builder") / "capability-cache",
        evidence_run_key=run_id,
    )
    binding = capability_binding.ensure_run_binding(
        repo, run_id, resolution, profile, allow_create=True,
    )
    mission_binding = program_mission.bind_runtime_identity(
        repo, run_id, run_binding=binding, runner_profile=profile,
        runtime_generation=runtime_generation,
    )
    assert mission_binding, "initial v4 segment must freeze runtime identity"
    return {
        "repo": repo, "baseline": baseline, "run_id": run_id, "meta": meta,
        "seal": seal, "runtime_generation": runtime_generation,
        "profile": profile, "binding": binding,
    }


def set_binding_for_child(fixture: dict, child_run_id: str) -> None:
    repo = fixture["repo"]
    profile = runner_profiles.resolve_profile("default", provider=MissionFixtureRunner.runner_id)
    resolution = capabilities.resolve_capabilities(
        [], canonical_repo=repo, role="builder",
        repo_cache_root=runtime_env.repo_tool_cache_dir(repo),
        ephemeral_cache_root=runtime_env.runtime_cache_dir(repo, child_run_id, "builder") / "capability-cache",
        evidence_run_key=child_run_id,
    )
    binding = capability_binding.ensure_run_binding(
        repo, child_run_id, resolution, profile, allow_create=True,
    )
    segment, _, mission_doc, _ = program_mission.load_segment(repo, child_run_id)
    identity = program_mission.verify_runtime_identity(
        repo, str(segment["mission_id"]), run_binding=binding,
        runner_profile=profile, runtime_generation=fixture["runtime_generation"],
    )
    assert identity["capability_binding_sha256"] == binding["binding_sha256"]
    assert mission_doc["operational_budget"]["runtime_generation"] == fixture["runtime_generation"]


def finish_build(fixture: dict, *, content: list[str], path: str = "src/app.py",
                 expected_state: str = "READY_FOR_REVIEW",
                 pre_finalize_state_out: list[dict] | None = None,
                 pre_finalize_job_out: list[dict] | None = None) -> tuple[str, dict]:
    repo = fixture["repo"]
    run_id = fixture["run_id"]
    meta = fixture["meta"]
    current = state.load_verified(repo, run_id)
    cp_id = (current.get("program") or {}).get("current_checkpoints", [None])[0]
    cp = next(item for item in meta["checkpoint_graph"]["checkpoints"] if item["id"] == cp_id)
    unit_id = cp["work_units"][0]
    claim = program.claim_build_pass(canonical_repo=repo, run_id=run_id, packet=meta)
    prepared = build_prepare.prepare(canonical_repo=repo, run_id=run_id)
    builder = Path(prepared["builder_worktree"])
    target = builder / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("".join(content), encoding="utf-8")
    git(builder, "add", "--", path)
    git(builder, "commit", "-qm", f"v127 {run_id} {cp_id} build {claim['cp_pass_number']}")
    candidate = git(builder, "rev-parse", "HEAD")
    result_path = build_agent.write_skeleton(repo, run_id, source_root=source_root, overwrite=True)
    result = json.loads(result_path.read_text(encoding="utf-8"))
    result.update({
        "summary": f"Deterministic v127 builder result for {cp_id}.",
        "outcome_requested": "candidate_ready",
        "work_unit_id": unit_id,
        "unit_ids_completed": [unit_id],
        "acceptance_addressed": list(cp["acceptance_criterion_ids"]),
        "notes": "Test fixture; finalization is the production deterministic implementation.",
        "timestamp": util.utc_now_iso(),
    })
    result["evidence"]["files_changed"] = [path]
    result["evidence"]["diff_lines_total"] = len(content)
    result_path.write_text(json.dumps(result, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    if pre_finalize_state_out is not None:
        pre_finalize_state_out.append(state.load_verified(repo, run_id))
    if pre_finalize_job_out is not None:
        with supervisor_db._managed_connect_readonly(db_path) as conn:
            job_row = conn.execute(
                """SELECT total_cost_usd, total_input_tokens, total_output_tokens,
                          total_cache_read_tokens, total_cache_creation_tokens
                   FROM jobs WHERE repo=? AND run_id=?""",
                (str(repo.resolve()), run_id),
            ).fetchone()
        assert job_row is not None, f"missing supervisor job for {run_id}"
        pre_finalize_job_out.append(dict(job_row))
    receipt = build_finalize.finalize_build(
        canonical_repo=repo, run_id=run_id, agent_result_path=result_path,
        actor="v127-fixture-builder",
    )
    assert receipt["candidate_sha"] == candidate, receipt
    assert receipt["validation_status"] == "PASS", receipt
    assert receipt["next_state"] == expected_state, receipt
    assert state.load_verified(repo, run_id)["last_candidate_sha"] == candidate
    return candidate, receipt


def finish_review(
    fixture: dict, *, final: bool = False, must_fix: list[dict] | None = None,
) -> dict:
    repo = fixture["repo"]
    run_id = fixture["run_id"]
    meta = fixture["meta"]
    current = state.load_verified(repo, run_id)
    candidate = str(current["last_candidate_sha"])
    claim = program.claim_review_pass(canonical_repo=repo, run_id=run_id, packet=meta)
    review_prepare.prepare(canonical_repo=repo, run_id=run_id)
    assess_path = assessment.write_skeleton(repo, run_id, source_root=source_root, overwrite=True)
    assess = json.loads(assess_path.read_text(encoding="utf-8"))
    expected = (
        [item["id"] for item in meta["acceptance_criteria"]]
        if final else program.current_checkpoint_acceptance_criterion_ids(meta, current["program"])
    )
    assess["acceptance_results"] = [
        {"id": ac_id, "result": "pass", "evidence": "Fixture implementation is present and integrated."}
        for ac_id in expected
    ]
    assess["non_goal_results"] = []
    assess["findings"] = must_fix or []
    assess["validation_results"] = []
    assess["recommended_verdict"] = "CHANGES_REQUESTED" if must_fix else "APPROVED"
    assess["timestamp"] = util.utc_now_iso()
    assess_path.write_text(json.dumps(assess, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    verdict = review_finalize.finalize_review(
        canonical_repo=repo, run_id=run_id, assessment_path=assess_path,
        actor="v127-fixture-reviewer",
    )
    assert verdict["candidate_sha_reviewed"] == candidate, verdict
    assert verdict["review_pass_number"] == claim["claimed_pass_number"], verdict
    assert verdict["verdict"] == ("CHANGES_REQUESTED" if must_fix else "APPROVED"), verdict
    if final:
        assert verdict["review_scope"] == program.REVIEW_SCOPE_PROGRAM_FINAL, verdict
        assert verdict["expected_acceptance_criterion_ids"] == expected, verdict
    return verdict


# v1-v3 remain on their existing contract; only explicit v4 carries the new budget.
repo_probe, baseline_probe = make_repo("v127-v3-compat")
v3 = {
    "schema": "ownframework-work-packet/v3", "packet_id": "v127-v3",
    "created_at": "2026-09-29T00:00:00Z", "work_class": "FEATURE", "risk_class": "low",
    "title": "v3 compatibility", "target": {"repo": str(repo_probe), "branch": "master", "classification": "local_only"},
    "execution_mode": "single", "acceptance_criteria": [{"id": "AC-1", "text": "works"}],
    "non_goals": [], "allowed_paths": ["src/"], "protected_paths": [".ownframework-loop/"],
    "work_units": [{"id": "UNIT-1", "title": "unit", "scope": "src/"}],
    "merge_authority": "human_only", "deploy_authority": "human_only", "push_authority": "human_only",
    "external_action_authority": "none", "risk_budget": {"max_build_passes": 2,
    "max_review_passes": 2, "max_repair_rounds": 1, "max_files_changed": 5, "max_diff_lines": 100},
}
assert packet.validate_packet_for_approval(v3) == []
v3_with_v4_field_errors = packet.validate_packet_for_approval({**v3, "mission_budget": {}})
assert v3_with_v4_field_errors and any("mission_budget" in error for error in v3_with_v4_field_errors), v3_with_v4_field_errors
print("V1_V3_SEMANTICS_UNCHANGED=PASS")

# Required output paths must be covered by the sealed allowed path envelope.
covered = v4_packet(repo_probe, baseline_probe)
covered["checkpoint_graph"]["checkpoints"][0]["required_paths"] = ["src/needed.py"]
assert packet.validate_packet_for_approval(covered) == [], packet.validate_packet_for_approval(covered)
uncovered = copy.deepcopy(covered)
uncovered["checkpoint_graph"]["checkpoints"][0]["required_paths"] = ["docs/needed.md"]
assert any("not covered by packet allowed_paths" in error for error in packet.validate_packet_for_approval(uncovered))
print("SPEC_REQUIRED_PATH_COVERAGE=PASS")

# Full v4 lifecycle: an eligible source-only boundary creates one successor,
# replays after a simulated crash, re-executes the crossing checkpoint, and
# preserves the whole-product final review over the inherited approved prefix.
repo, baseline = make_repo("v127-full-mission")
parent = "run-20260929T000000Z-v127parent"
fixture = start_v4(repo, baseline, parent)
assert state.load_verified(repo, parent)["state"] == "READY_TO_BUILD"
approved_cp0, cp0_receipt = finish_build(
    fixture, content=["A = 1\n", "B = 2\n"],
)
cp0_review = finish_review(fixture)
assert state.load_verified(repo, parent)["program"]["finalized_checkpoints"][-1]["id"] == "CP-00"
parent_root = state.run_dir(repo, parent)
prior_verdict_sha = util.sha256_file(parent_root / "REVIEW_VERDICT.json")

crossing_pre_finalize_state: list[dict] = []
crossing, crossing_receipt = finish_build(
    fixture, content=[f"VALUE_{i} = {i}\n" for i in range(15)],
    expected_state="SEGMENT_BOUNDARY",
    pre_finalize_state_out=crossing_pre_finalize_state,
)
parent_state = state.load_verified(repo, parent)
assert parent_state["last_candidate_sha"] == crossing
assert crossing_receipt["segment_boundary"]["result"] == "authorized"
assert crossing_receipt["segment_boundary"]["last_approved_candidate_sha"] == approved_cp0
assert util.sha256_file(parent_root / "REVIEW_VERDICT.json") == prior_verdict_sha
assert json.loads((parent_root / "REVIEW_VERDICT.json").read_text())["candidate_sha_reviewed"] == approved_cp0
assert not (parent_root / "scratch" / "REVIEW_AGENT_ASSESSMENT.json").exists()
print("BOUNDARY_SOURCE_ONLY_AND_CROSSING_CANDIDATE_UNREVIEWED=PASS")

segment1, _, mission_doc, _ = program_mission.load_segment(repo, parent)
mission_id = segment1["mission_id"]
assert program_mission.source_budget_for_candidate(repo, parent, crossing)["mission_source_lines_total"] < mission_doc["mission_max_diff_lines"]

# Simulate a crash after the complete successor approval is published but
# before its normal job enrollment. The existing mission scheduler replay
# must recover that exact segment and create exactly one QUEUED job.
real_write_seal = program_mission._write_derived_approval_once
def fail_after_seal(*args, **kwargs):
    real_write_seal(*args, **kwargs)
    raise RuntimeError("v127 injected crash after derived seal publication")
program_mission._write_derived_approval_once = fail_after_seal
try:
    try:
        program_mission.reconcile_pending_boundaries(db_path=db_path)
    except RuntimeError as exc:
        assert "injected crash" in str(exc)
    else:
        raise AssertionError("injected successor-publication crash was not observed")
finally:
    program_mission._write_derived_approval_once = real_write_seal

restart_script = '''
import json, sys
from pathlib import Path
from ownframework_loop import program_mission, supervisor
class MissionFixtureRunner:
    runner_id = "v127-mission-fixture"
    def run(self, *args, **kwargs):
        raise AssertionError("restart replay fixture must not launch a provider")
supervisor.register_runner(MissionFixtureRunner)
result = program_mission.reconcile_pending_boundaries(db_path=Path(sys.argv[1]))
print(json.dumps(result, sort_keys=True))
'''
restart_env = dict(os.environ)
restart_env["PYTHONPATH"] = f"{source_root / 'lib'}:{source_root / 'tests/helpers'}:{source_root / 'tests'}"
restart = subprocess.run(
    [sys.executable, "-B", "-c", restart_script, str(db_path)],
    capture_output=True, text=True, env=restart_env,
)
assert restart.returncode == 0, restart.stderr
replayed = json.loads(restart.stdout.splitlines()[-1])
assert replayed["ok"] is True, replayed
segments = [
    program_mission._read_record(
        program_mission._segment_path(repo.resolve(), mission_id, number),
        expected_schema=program_mission.SEGMENT_SCHEMA,
    )[0]
    for number in (1, 2)
]
child = segments[1]["run_id"]
assert segments[1]["predecessor_run_id"] == parent
assert segments[1]["baseline_sha"] == approved_cp0
assert segments[1]["source_admission"]["crossing_candidate_sha"] == crossing
assert segments[1]["source_admission"]["crossing_candidate_not_adopted"] is True
assert state.load_verified(repo, child)["state"] == "READY_TO_BUILD"
assert state.load_verified(repo, child)["program"]["current_checkpoints"] == ["CP-01"]
assert state.load_verified(repo, child)["last_candidate_sha"] == approved_cp0
assert supervisor.status(canonical_repo=repo, run_id=child, db_path=db_path)["status"] == "QUEUED"
set_binding_for_child(fixture, child)

replay_again = program_mission.reconcile_pending_boundaries(db_path=db_path)
assert replay_again["ok"] is True, replay_again
with supervisor_db._managed_connect_readonly(db_path) as conn:
    child_rows = conn.execute(
        "SELECT * FROM jobs WHERE repo=? AND run_id=?", (str(repo.resolve()), child),
    ).fetchall()
assert len(child_rows) == 1
status_projection = program_mission.mission_status(repo, mission_id, db_path=db_path)
assert status_projection["current_run_id"] == child
assert status_projection["current_segment_number"] == 2
assert status_projection["current_candidate_sha"] == approved_cp0
assert status_projection["completed_checkpoints"] == ["CP-00"]
assert status_projection["mission_source_lines_used"] == program.source_tree_accounting(
    canonical_repo=repo, baseline_sha=baseline, candidate_sha=approved_cp0,
)["diff_lines"]
assert status_projection["mission_source_lines_remaining"] == (
    100 - status_projection["mission_source_lines_used"]
)
assert status_projection["current_segment_source_lines"] == 0
assert set(status_projection["aggregate_observed_spend"]) == {
    "cost_usd", "input_tokens", "output_tokens", "cache_read_tokens",
    "cache_creation_tokens", "total_tokens",
}
assert status_projection["operational_source_run_ids"] == []
print("SUCCESSOR_LAST_APPROVED_BASELINE_AND_REEXECUTION=PASS")
print("SUCCESSOR_CRASH_REPLAY_AND_SINGLE_ENROLLMENT=PASS")
print("SUPERVISOR_RESTART_AND_MISSION_ID_OBSERVER_RESOLUTION=PASS")
print("MISSION_STATUS_SOURCE_CHECKPOINT_AND_SPEND_PROJECTION=PASS")

# The crossing checkpoint is rebuilt from the approved baseline; its valid
# segment-local source use remains below 10 lines, then CP-02 completes inside
# the same segment. The final review must see all ACs across the full product.
child_fixture = {**fixture, "run_id": child, "meta": json.loads(
    (state.run_dir(repo, child) / "WORK_PACKET.md").read_text().split("```json\n", 1)[1].split("\n```", 1)[0]
)}
child_cp1, child_cp1_receipt = finish_build(
    child_fixture, content=["A = 1\n", "B = 2\n"] + [f"C{i} = {i}\n" for i in range(4)],
)
assert child_cp1_receipt["program_source_ceiling_check"]["result"] == "pass"
finish_review(child_fixture)
assert state.load_verified(repo, child)["program"]["current_checkpoints"] == ["CP-02"]
cp2_candidate, cp2_receipt = finish_build(
    child_fixture, content=[f"EXTRA_{i} = {i}\n" for i in range(5)], path="src/extra.py",
)
assert cp2_receipt["program_source_ceiling_check"]["result"] == "pass"
finish_review(child_fixture)
pre_final = state.load_verified(repo, child)
assert pre_final["state"] == "READY_FOR_REVIEW"
assert pre_final["program"]["review_scope"] == program.REVIEW_SCOPE_PROGRAM_FINAL
final_verdict = finish_review(child_fixture, final=True)
terminal = state.load_verified(repo, child)
assert terminal["state"] == "APPROVED"
assert program.is_program_terminal(terminal["program"])[0] is True
assert terminal["program"]["review_scope"] == program.REVIEW_SCOPE_PROGRAM_FINAL
assert final_verdict["candidate_sha_reviewed"] == cp2_candidate
assert set(final_verdict["expected_acceptance_criterion_ids"]) == {"AC-00", "AC-01", "AC-02"}
assert subprocess.run(
    ["git", "-C", str(repo.resolve()), "merge-base", "--is-ancestor", crossing, segments[1]["candidate_branch"]],
    capture_output=True,
).returncode != 0, "crossing candidate must not be an ancestor of the successor branch"
assert git(repo, "rev-parse", segments[1]["candidate_branch"]) == cp2_candidate
assert subprocess.run(
    ["git", "-C", str(repo.resolve()), "merge-base", "--is-ancestor", approved_cp0, segments[1]["candidate_branch"]],
    capture_output=True,
).returncode == 0, "successor branch must descend from the last approved candidate"
assert program_mission.source_budget_for_candidate(repo, child, cp2_candidate)["mission_source_lines_total"] <= 100
print("WHOLE_PRODUCT_FINAL_ACCEPTANCE_PRESERVED=PASS")
print("SEGMENT_AND_MISSION_SOURCE_BUDGETS_ENFORCED=PASS")

# Negative boundary decisions: mission exhaustion, max-segment exhaustion,
# auto_segment=false, explicit STOP, and independent scope/identity failures
# are never turned into successor authority.
boundary_state = crossing_pre_finalize_state[0]
loaded_parent = program_mission.load_segment(repo, parent)
segment_doc, _, mission_doc, _ = loaded_parent
source_check = crossing_receipt["program_source_ceiling_check"]
base_args = dict(
    meta=fixture["meta"], current_state=boundary_state, candidate_sha=crossing,
    source_check=source_check, validation_pass=True, infra_failure_count=0,
    identity_reproof={"result": "pass"}, scope_findings=[], protected_findings=[],
    hard_secret_blocks=[], outcome_requested="candidate_ready", candidate_invalid_count=0,
    segment_context=loaded_parent,
)
budget_packet_cp = {"risk_budget": {"max_build_passes": 3}}
def build_entitlement(local_used: int, cumulative_used: int) -> dict:
    return program.build_pass_entitlement(
        {
            "checkpoints": [{"id": "CP-BUDGET", "build_pass_count": local_used}],
            "cumulative_counters": {"build_pass_count": cumulative_used},
            "cumulative_ceilings": {"max_build_passes": 4},
        },
        cp_id="CP-BUDGET", packet_cp=budget_packet_cp,
    )

assert build_entitlement(1, 2)["eligible"] is True
local_exhaustion = build_entitlement(3, 3)
assert local_exhaustion["eligible"] is False
assert local_exhaustion["reason_codes"] == ["checkpoint_build_authority_exhausted"]
global_exhaustion = build_entitlement(1, 4)
assert global_exhaustion["eligible"] is False
assert global_exhaustion["reason_codes"] == ["mission_cumulative_build_authority_exhausted"]
both_exhausted = build_entitlement(3, 4)
assert both_exhausted["eligible"] is False
assert set(both_exhausted["reason_codes"]) == {
    "checkpoint_build_authority_exhausted",
    "mission_cumulative_build_authority_exhausted",
}
print("LOCAL_GLOBAL_AND_COMBINED_BUILD_ENTITLEMENT=PASS")
ok, proof = program_mission.segment_boundary_eligibility(repo, parent, **base_args)
assert ok, proof
# Exercise an independently exhausted checkpoint BUILD entitlement while the
# mission still has budget and a segment slot. A successor must be refused.
local_build_exhausted = copy.deepcopy(boundary_state)
local_program = local_build_exhausted["program"]
local_cp_id = local_program["current_checkpoints"][0]
local_cp = next(cp for cp in local_program["checkpoints"] if cp["id"] == local_cp_id)
local_cap = next(
    cp["risk_budget"]["max_build_passes"]
    for cp in fixture["meta"]["checkpoint_graph"]["checkpoints"]
    if cp["id"] == local_cp_id
)
local_cp["build_pass_count"] = local_cap
local_total = sum(int(cp.get("build_pass_count") or 0) for cp in local_program["checkpoints"])
local_program["cumulative_counters"]["build_pass_count"] = local_total
local_build_exhausted["build_pass_count"] = local_total
ok, proof = program_mission.segment_boundary_eligibility(
    repo, parent, **{**base_args, "current_state": local_build_exhausted},
)
assert not ok, f"BUG REPRODUCED: segment boundary authorized without a successor BUILD claim: {proof}"
assert "checkpoint_build_authority_exhausted" in proof["reasons"]
global_build_exhausted = copy.deepcopy(boundary_state)
global_program = global_build_exhausted["program"]
global_cap = int(global_program["cumulative_ceilings"]["max_build_passes"])
global_program["cumulative_counters"]["build_pass_count"] = global_cap
global_build_exhausted["build_pass_count"] = global_cap
ok, proof = program_mission.segment_boundary_eligibility(
    repo, parent, **{**base_args, "current_state": global_build_exhausted},
)
assert not ok, f"BUG REPRODUCED: segment boundary ignored cumulative BUILD exhaustion: {proof}"
assert "mission_cumulative_build_authority_exhausted" in proof["reasons"]
assert proof["required_build_entitlement"]["reason_codes"] == [
    "mission_cumulative_build_authority_exhausted",
]
assert boundary_state["program"]["cumulative_counters"]["build_pass_count"] != global_cap
print("SEGMENT_BOUNDARY_REQUIRES_REEXECUTABLE_BUILD=PASS")
mission_exhausted = dict(source_check, mission_budget_result="fail")
ok, proof = program_mission.segment_boundary_eligibility(
    repo, parent, **{**base_args, "source_check": mission_exhausted},
)
assert not ok
maxed_segment = dict(segment_doc, segment_number=int(mission_doc["max_segments"]))
maxed_context = (maxed_segment, loaded_parent[1], mission_doc, loaded_parent[3])
ok, proof = program_mission.segment_boundary_eligibility(
    repo, parent, **{**base_args, "segment_context": maxed_context},
)
assert not ok and "maximum_segments_exhausted" in proof["reasons"]
no_auto = copy.deepcopy(fixture["meta"])
no_auto["mission_budget"]["auto_segment"] = False
ok, proof = program_mission.segment_boundary_eligibility(
    repo, parent, **{**base_args, "meta": no_auto},
)
assert not ok and "automatic_segmentation_not_authorized" in proof["reasons"]
ok, proof = program_mission.segment_boundary_eligibility(
    repo, parent, **{**base_args, "scope_findings": [{"path": "elsewhere"}]},
)
assert not ok and "scope_violation_present" in proof["reasons"]
ok, proof = program_mission.segment_boundary_eligibility(
    repo, parent, **{**base_args, "identity_reproof": {"result": "fail"}},
)
assert not ok and "candidate_identity_reproof_failed" in proof["reasons"]
stop_path = state.stop_path(repo, parent)
util.atomic_write_json(stop_path, {"schema": "ownframework-loop-stop/v1", "reason": "fixture"}, mode=0o600)
try:
    ok, proof = program_mission.segment_boundary_eligibility(repo, parent, **base_args)
    assert not ok and "stop_requested" in proof["reasons"]
finally:
    stop_path.unlink()
print("MISSION_EXHAUSTION_MAX_SEGMENTS_STOP_AND_NONBUDGET_FAILURES_FAIL_CLOSED=PASS")

# End-to-end finalization: CP-01's second and final BUILD produces an otherwise
# valid source-only segment overrun. The next segment could not re-execute the
# checkpoint, so deterministic finalization must BLOCK the parent and create
# no successor-side authority or ledger row.
local_repo, local_baseline = make_repo("v127-local-build-exhaustion")
local_run = "run-20260929T000000Z-v127localcap"
local_budgets = [
    {"max_build_passes": 2, "max_review_passes": 2, "max_repair_rounds": 1},
    {"max_build_passes": 2, "max_review_passes": 2, "max_repair_rounds": 1},
]
local_meta = v4_packet(
    local_repo, local_baseline, segment_lines=10, mission_lines=100,
    max_segments=2, checkpoint_count=2,
    checkpoint_risk_budgets=local_budgets,
    global_risk_budget={
        "max_build_passes": 6, "max_review_passes": 5,
        "max_repair_rounds": 2,
    },
)
local_fixture = start_v4(local_repo, local_baseline, local_run, meta=local_meta)
finish_build(local_fixture, content=["BASE = 1\n", "BASE_TWO = 2\n"])
finish_review(local_fixture)
finish_build(
    local_fixture, content=["CP1 = 1\n", "CP1_TWO = 2\n"],
    path="src/checkpoint1.py",
)
requested_repair = finish_review(local_fixture, must_fix=[{
    "finding_id": "F-V127_LOCAL-CAP-1",
    "severity": "high",
    "classification": "must_fix",
    "title": "Fixture repair before source boundary",
    "description": "The fixture requires one bounded repair before the crossing build.",
    "file": "src/checkpoint1.py",
    "line": 1,
}])
assert requested_repair["verdict"] == "CHANGES_REQUESTED"
pre_finalize_local: list[dict] = []
pre_finalize_local_job: list[dict] = []
local_crossing, local_receipt = finish_build(
    local_fixture,
    content=[f"CROSSING_{index} = {index}\n" for index in range(15)],
    path="src/crossing.py",
    expected_state="BLOCKED",
    pre_finalize_state_out=pre_finalize_local,
    pre_finalize_job_out=pre_finalize_local_job,
)
local_terminal = state.load_verified(local_repo, local_run)
local_proof = local_receipt["segment_boundary"]
assert local_proof["result"] == "refused", local_proof
assert local_proof["reasons"] == ["checkpoint_build_authority_exhausted"], local_proof
assert local_proof["required_build_entitlement"]["eligible"] is False
assert local_terminal["state"] == "BLOCKED"
assert local_terminal["terminal_reason"] == (
    "segment_boundary_refused:checkpoint_build_authority_exhausted"
)
assert local_terminal["last_candidate_sha"] == local_crossing
pre_program = pre_finalize_local[0]["program"]
post_program = local_terminal["program"]
assert local_terminal["build_pass_count"] == pre_finalize_local[0]["build_pass_count"]
assert post_program["cumulative_counters"]["build_pass_count"] == (
    pre_program["cumulative_counters"]["build_pass_count"]
)
assert local_terminal["repair_round"] == pre_finalize_local[0]["repair_round"]
assert post_program["cumulative_counters"]["repair_round_count"] == (
    pre_program["cumulative_counters"]["repair_round_count"]
)
for counter in ("build_pass_count", "review_pass_count", "repair_round_count"):
    assert post_program["cumulative_counters"][counter] == pre_program["cumulative_counters"][counter]
assert post_program["cumulative_ceilings"] == pre_program["cumulative_ceilings"]
assert post_program["cumulative_counters"]["diff_lines_total"] == (
    local_receipt["program_source_ceiling_check"]["mission_source_lines_total"]
)
assert local_terminal["review_pass_count"] == pre_finalize_local[0]["review_pass_count"]
with supervisor_db._managed_connect_readonly(db_path) as conn:
    local_job_after = conn.execute(
        """SELECT total_cost_usd, total_input_tokens, total_output_tokens,
                  total_cache_read_tokens, total_cache_creation_tokens
           FROM jobs WHERE repo=? AND run_id=?""",
        (str(local_repo.resolve()), local_run),
    ).fetchone()
assert local_job_after is not None
assert dict(local_job_after) == pre_finalize_local_job[0]
local_segment, _, local_mission, _ = program_mission.load_segment(local_repo, local_run)
local_child = program_mission._segment_run_id(local_segment["mission_id"], 2)
assert not program_mission._segment_path(local_repo.resolve(), local_segment["mission_id"], 2).exists()
assert not state.run_dir(local_repo, local_child).exists()
assert git_checks.branch_head(local_repo, f"factory/candidate/{local_child}") is None
assert git_checks.branch_head(local_repo, local_segment["candidate_branch"]) == local_crossing
with supervisor_db._managed_connect_readonly(db_path) as conn:
    assert conn.execute(
        "SELECT 1 FROM jobs WHERE repo=? AND run_id=?",
        (str(local_repo.resolve()), local_child),
    ).fetchone() is None
assert local_mission["max_segments"] == 2
print("LOCAL_CAP_FINALIZATION_BLOCKS_WITHOUT_SUCCESSOR_SIDE_EFFECTS=PASS")

# A single-segment v4 packet remains valid and does not authorize successors.
single = v4_packet(repo_probe, baseline_probe, auto_segment=False, max_segments=1)
assert packet.validate_packet_for_approval(single) == []
single["mission_budget"]["max_segments"] = 2
assert any("auto_segment=false" in error for error in packet.validate_packet_for_approval(single))
single_repo, single_baseline = make_repo("v127-single-segment")
single_run = "run-20260929T000000Z-v127single"
single_fixture = start_v4(
    single_repo, single_baseline, single_run,
    meta=v4_packet(single_repo, single_baseline, auto_segment=False,
                   segment_lines=10, mission_lines=10, max_segments=1,
                   checkpoint_count=2),
)
finish_build(single_fixture, content=["ONLY = 1\n", "ONE = 1\n"])
finish_review(single_fixture)
finish_build(single_fixture, content=["SECOND = 2\n", "DONE = 2\n"], path="src/second.py")
finish_review(single_fixture)
finish_review(single_fixture, final=True)
single_segment, _, single_mission, _ = program_mission.load_segment(single_repo, single_run)
assert state.load_verified(single_repo, single_run)["state"] == "APPROVED"
assert not program_mission._segment_path(
    single_repo.resolve(), single_segment["mission_id"], 2,
).exists()
assert single_mission["max_segments"] == 1
assert program_mission.reconcile_pending_boundaries(db_path=db_path)["ok"] is True
print("SINGLE_SEGMENT_COMPLETES_WITHOUT_SUCCESSOR_AND_AUTO_FALSE_IS_ENFORCED=PASS")

# A candidate that crosses both the segment and original-baseline mission
# budgets is a hard authority stop, not a successor opportunity.
exhaust_repo, exhaust_baseline = make_repo("v127-mission-exhaustion")
exhaust_run = "run-20260929T000000Z-v127exhaust"
exhaust_fixture = start_v4(
    exhaust_repo, exhaust_baseline, exhaust_run,
    meta=v4_packet(exhaust_repo, exhaust_baseline, segment_lines=10,
                   mission_lines=12, max_segments=2, checkpoint_count=2),
)
finish_build(exhaust_fixture, content=["BASE_A = 1\n", "BASE_B = 2\n"])
finish_review(exhaust_fixture)
exhaust_candidate, exhaust_receipt = finish_build(
    exhaust_fixture,
    content=[f"EXHAUST_{index} = {index}\n" for index in range(15)],
    expected_state="BLOCKED",
)
assert exhaust_receipt["program_source_ceiling_check"]["mission_budget_result"] == "fail"
assert exhaust_receipt.get("segment_boundary", {}).get("result") != "authorized"
exhaust_segment, _, exhaust_mission, _ = program_mission.load_segment(exhaust_repo, exhaust_run)
assert not program_mission._segment_path(
    exhaust_repo.resolve(), exhaust_segment["mission_id"], 2,
).exists()
assert state.load_verified(exhaust_repo, exhaust_run)["state"] == "BLOCKED"
assert supervisor.status(canonical_repo=exhaust_repo, run_id=exhaust_run, db_path=db_path)["status"] == "QUEUED"
assert exhaust_mission["mission_max_diff_lines"] == 12
print("MISSION_SOURCE_EXHAUSTION_BLOCKS_WITHOUT_SUCCESSOR=PASS")

assert not hasattr(program_mission, "admit_legacy_continuation")
assert not hasattr(program_mission, "continue_blocked_semantic_budget")
assert not hasattr(program_mission, "continue_blocked_source_budget")
print("NORMAL_V4_HAS_NO_INCIDENT_CONTINUATION_CREATION_SURFACES=PASS")

# New v4 has one source-authority model: a packet-selected segment cap bounded
# by one platform maximum and a separate finite mission total. Historical v3
# keeps its original source ceiling.
authority_repo, authority_baseline = make_repo("v127-authority-model")
authority_packet = v4_packet(
    authority_repo, authority_baseline, segment_lines=100000,
    mission_lines=480000, max_segments=16, checkpoint_count=1,
)
authority_packet["risk_budget"]["max_diff_lines"] = 100000
authority_packet["checkpoint_graph"]["global_source_ceilings"][
    "max_baseline_to_final_diff_lines"
] = 480000
assert packet.validate_packet_for_approval(authority_packet) == []
too_large_segment = copy.deepcopy(authority_packet)
too_large_segment["mission_budget"]["segment_max_diff_lines"] = 100001
too_large_segment["risk_budget"]["max_diff_lines"] = 100001
assert packet.validate_packet_for_approval(too_large_segment)
too_large_mission = copy.deepcopy(authority_packet)
too_large_mission["mission_budget"]["mission_max_diff_lines"] = 480001
too_large_mission["checkpoint_graph"]["global_source_ceilings"][
    "max_baseline_to_final_diff_lines"
] = 480001
assert packet.validate_packet_for_approval(too_large_mission)
# Previously sealed v4 packets bound the graph ceiling to their segment cap.
# They remain valid with exactly that original cumulative limit; the new
# normal authoring form may instead bind it to the mission-total envelope.
legacy_v4_packet = v4_packet(
    authority_repo, authority_baseline, segment_lines=30000,
    mission_lines=100000, max_segments=2, checkpoint_count=1,
)
legacy_v4_packet["checkpoint_graph"]["global_source_ceilings"][
    "max_baseline_to_final_diff_lines"
] = 30000
assert packet.validate_packet_for_approval(legacy_v4_packet) == []
assert program.validate_checkpoint_graph(legacy_v4_packet) == []
legacy_v4_state = program.materialise_initial_program_state(
    legacy_v4_packet, baseline_sha=authority_baseline,
    candidate_branch="factory/candidate/v127-legacy-v4",
)
assert legacy_v4_state["cumulative_ceilings"][
    "max_baseline_to_final_diff_lines"
] == 30000
print("SEALED_V4_SEGMENT_CEILING_PRESERVED=PASS")
assert packet._validate_risk_budget_envelope({
    "schema": "ownframework-work-packet/v3", "risk_budget": {"max_diff_lines": 30000},
}) == []
assert packet._validate_risk_budget_envelope({
    "schema": "ownframework-work-packet/v3", "risk_budget": {"max_diff_lines": 30001},
})
obsolete_authority = copy.deepcopy(authority_packet)
obsolete_authority["mission_budget"]["source_budget_continuation"] = {}
assert packet.validate_packet_for_approval(obsolete_authority)
receipt_schema = json.loads(
    (source_root / "schemas" / "build-receipt.schema.json").read_text()
)
receipt_properties = receipt_schema["properties"]
source_check = receipt_properties["program_source_ceiling_check"]["properties"]
boundary_properties = receipt_properties["segment_boundary"]["properties"]
assert source_check["program_max_baseline_to_final_diff_lines"]["maximum"] == 480000
assert source_check["effective_max_diff_lines"]["maximum"] == 100000
assert source_check["segment_source_ceiling"]["maximum"] == 100000
assert source_check["mission_source_ceiling"]["maximum"] == 480000
assert boundary_properties["mission_source_ceiling"]["maximum"] == 480000
print("V4_SOURCE_BUDGET_SCHEMA_MAXIMA_MATCH_RUNTIME=PASS")
print("V4_SEGMENT_AND_MISSION_SOURCE_AUTHORITY_LIMITS=PASS")
print("V1_V3_SOURCE_LIMIT_REMAINS_30000=PASS")

from ownframework_loop import cli

root_parser = cli._build_parser()
root_subparsers = next(
    action for action in root_parser._actions
    if isinstance(action, argparse._SubParsersAction)
)
root_commands = root_subparsers.choices
program_parser = root_commands["program"]
program_subparsers = next(
    action for action in program_parser._actions
    if isinstance(action, argparse._SubParsersAction)
)
program_commands = program_subparsers.choices
assert not {
    "continue-blocked-source-budget", "continue-blocked-semantic-budget",
    "admit-legacy-continuation",
}.intersection(program_commands)
assert hasattr(program_mission, "load_segment")
assert hasattr(program_mission, "verify_segment_approval")
print("INCIDENT_CONTINUATION_CREATION_ABSENT_FROM_PUBLIC_CLI=PASS")

# Runtime-generation maintenance is independent of a continuation type. A
# normal sealed v4 segment quarantined on an installed-generation mismatch can
# publish one exact workerless migration, replay it idempotently, and resume
# without changing product authority or semantic accounting.
from ownframework_loop import program_mission_runtime

runtime_repo, runtime_baseline = make_repo("v127-runtime-migration")
runtime_run = "run-20260930T000000Z-v127runtime"
runtime_meta = v4_packet(
    runtime_repo, runtime_baseline, segment_lines=100,
    mission_lines=200, max_segments=2, checkpoint_count=2,
)
# Isolate scheduler selection from the other PROGRAM fixtures in this test.
previous_db_path = db_path
previous_xdg_state_home = os.environ["XDG_STATE_HOME"]
os.environ["XDG_STATE_HOME"] = str(root / "state-runtime")
runtime_db_path = supervisor_db.default_db_path()
with supervisor_db._managed_connect(runtime_db_path):
    pass
db_path = runtime_db_path
runtime_fixture = start_v4(
    runtime_repo, runtime_baseline, runtime_run, meta=runtime_meta,
)
runtime_segment, _, runtime_mission, _ = program_mission.load_segment(
    runtime_repo, runtime_run,
)
runtime_mission_id = str(runtime_segment["mission_id"])
runtime_packet_path = state.run_dir(runtime_repo, runtime_run) / "WORK_PACKET.md"
runtime_approval_path = approval.approval_path(runtime_repo, runtime_run)
runtime_state_path = state.state_path(runtime_repo, runtime_run)
runtime_events_path = state.events_path(runtime_repo, runtime_run)
runtime_manifest_path = program_mission._manifest_path(runtime_repo, runtime_mission_id)
runtime_identity_path = program_mission._mission_runtime_path(runtime_repo, runtime_mission_id)
authority_before = {
    "packet": util.sha256_file(runtime_packet_path),
    "approval": util.sha256_file(runtime_approval_path),
    "state": util.sha256_file(runtime_state_path),
    "events": integrity.compute_event_chain_hash(runtime_events_path),
    "mission": util.sha256_file(runtime_manifest_path),
    "runtime": util.sha256_file(runtime_identity_path),
    "binding": runtime_fixture["binding"]["binding_sha256"],
}
generation_before = runtime_fixture["runtime_generation"]
generation_after = generation_before + ".maintenance-test"
real_generation = supervisor_runtime.runtime_generation
real_supervisor_generation = supervisor._current_runtime_generation
supervisor_runtime.runtime_generation = lambda: generation_after
supervisor._current_runtime_generation = lambda: generation_after
try:
    quarantined = supervisor.run_one(db_path=runtime_db_path)
    assert quarantined.get("action") == "QUARANTINED", quarantined
    job_snapshot = supervisor.status(
        canonical_repo=runtime_repo, run_id=runtime_run, db_path=runtime_db_path,
    )
    assert job_snapshot["status"] == "QUARANTINED", job_snapshot
    assert all(job_snapshot.get(key) is None for key in (
        "worker_pid", "worker_pgid", "worker_attempt_id", "worker_role",
    ))
    with supervisor_db._managed_connect_readonly(runtime_db_path) as conn:
        runtime_attempt_count = int(conn.execute(
            "SELECT COUNT(*) FROM semantic_attempts WHERE job_id=?",
            (int(job_snapshot["id"]),),
        ).fetchone()[0])
    runtime_candidate = str(
        state.load_verified(runtime_repo, runtime_run).get("last_candidate_sha") or runtime_baseline
    )
    runtime_branch = str(job_snapshot["candidate_branch"])
    assert program_mission_runtime._runtime_migration_candidate_lineage_valid(
        runtime_repo, runtime_candidate, runtime_baseline, runtime_branch,
        semantic_attempt_count=runtime_attempt_count,
    ), {
        "candidate": runtime_candidate, "baseline": runtime_baseline,
        "branch": runtime_branch,
        "branch_head": git_checks.branch_head(runtime_repo, runtime_branch),
        "attempt_count": runtime_attempt_count,
    }
    migration_path = program_mission._mission_runtime_migration_path(
        runtime_repo, runtime_mission_id, 1,
    )
    active_worker_snapshot = dict(job_snapshot)
    active_worker_snapshot.update({
        "worker_pid": 43210, "worker_pgid": 43210,
        "worker_attempt_id": "active-worker-must-block-migration",
        "worker_role": "builder", "worker_started_at": "2026-09-30T00:00:00Z",
    })
    try:
        program_mission_runtime.prepare_runtime_generation_resume(
            runtime_repo, runtime_run, job_snapshot=active_worker_snapshot,
            target_runtime_generation=generation_after, db_path=runtime_db_path,
        )
    except program_mission.MissionAuthorityError:
        pass
    else:
        raise AssertionError("runtime migration proceeded beneath an active worker")
    assert not migration_path.exists()
    print("ACTIVE_WORKER_PREVENTS_RUNTIME_MIGRATION=PASS")

    first_migration = program_mission_runtime.prepare_runtime_generation_resume(
        runtime_repo, runtime_run, job_snapshot=job_snapshot,
        target_runtime_generation=generation_after, db_path=runtime_db_path,
    )
    replayed_migration = program_mission_runtime.prepare_runtime_generation_resume(
        runtime_repo, runtime_run, job_snapshot=job_snapshot,
        target_runtime_generation=generation_after, db_path=runtime_db_path,
    )
    assert first_migration == replayed_migration
    assert first_migration["sequence"] == 1
    resumed = supervisor.resume(
        canonical_repo=runtime_repo, run_id=runtime_run, db_path=runtime_db_path,
    )
    assert resumed.get("resumed") is True, resumed
    assert resumed.get("runtime_migration") == first_migration, resumed
    assert resumed["status"] == "QUEUED"
    new_binding = program_mission_runtime.bind_runtime_identity(
        runtime_repo, runtime_run, run_binding=runtime_fixture["binding"],
        runner_profile=runtime_fixture["profile"],
        runtime_generation=generation_after,
    )
    assert new_binding["runtime_migration_sequence"] == 1
    binding_receipt_path = program_mission._mission_runtime_binding_path(
        runtime_repo, runtime_mission_id, 1,
    )
    binding_receipt_before = binding_receipt_path.read_bytes()
    wrong_generation_refused = False
    try:
        program_mission_runtime.bind_runtime_identity(
            runtime_repo, runtime_run, run_binding=runtime_fixture["binding"],
            runner_profile=runtime_fixture["profile"],
            runtime_generation=generation_before,
        )
    except program_mission.MissionAuthorityError:
        wrong_generation_refused = True
    assert wrong_generation_refused
    drifted_profile = dict(runtime_fixture["profile"], model="unauthorized-model")
    profile_drift_refused = False
    try:
        program_mission_runtime.verify_runtime_identity(
            runtime_repo, runtime_mission_id,
            run_binding=runtime_fixture["binding"], runner_profile=drifted_profile,
            runtime_generation=generation_after, segment_number=1,
        )
    except program_mission.MissionAuthorityError:
        profile_drift_refused = True
    assert profile_drift_refused
    capability_drift = copy.deepcopy(runtime_fixture["binding"])
    capability_drift["projection"]["requested"] = ["toolchain.git", "research.public"]
    capability_drift_refused = False
    try:
        program_mission_runtime.verify_runtime_identity(
            runtime_repo, runtime_mission_id,
            run_binding=capability_drift, runner_profile=runtime_fixture["profile"],
            runtime_generation=generation_after, segment_number=1,
        )
    except program_mission.MissionAuthorityError:
        capability_drift_refused = True
    assert capability_drift_refused
    assert binding_receipt_path.read_bytes() == binding_receipt_before
    print("MIGRATED_RUNTIME_CAPABILITY_AND_PROFILE_DRIFT_REFUSED=PASS")

    replayed_binding = program_mission_runtime.bind_runtime_identity(
        runtime_repo, runtime_run, run_binding=runtime_fixture["binding"],
        runner_profile=runtime_fixture["profile"],
        runtime_generation=generation_after,
    )
    assert replayed_binding == new_binding
    assert binding_receipt_path.read_bytes() == binding_receipt_before
    print("RUNTIME_BINDING_RECEIPT_CREATE_ONCE_REPLAY=PASS")

    verified_identity = program_mission_runtime.verify_runtime_identity(
        runtime_repo, runtime_mission_id, run_binding=runtime_fixture["binding"],
        runner_profile=runtime_fixture["profile"],
        runtime_generation=generation_after, segment_number=1,
    )
    assert verified_identity["runtime_generation"] == generation_after
    assert verified_identity["capability_binding_sha256"] == authority_before["binding"]
    assert util.sha256_file(runtime_packet_path) == authority_before["packet"]
    assert util.sha256_file(runtime_approval_path) == authority_before["approval"]
    assert util.sha256_file(runtime_state_path) == authority_before["state"]
    assert integrity.compute_event_chain_hash(runtime_events_path) == authority_before["events"]
    assert util.sha256_file(runtime_manifest_path) == authority_before["mission"]
    assert util.sha256_file(runtime_identity_path) == authority_before["runtime"]
    current_program = state.load_verified(runtime_repo, runtime_run)["program"]
    assert current_program["cumulative_counters"] == {
        "build_pass_count": 0, "review_pass_count": 0, "repair_round_count": 0,
        "files_changed_unique": 0, "diff_lines_total": 0,
    }
finally:
    supervisor_runtime.runtime_generation = real_generation
    supervisor._current_runtime_generation = real_supervisor_generation
    db_path = previous_db_path
    os.environ["XDG_STATE_HOME"] = previous_xdg_state_home
print("NORMAL_SEGMENT_RUNTIME_MIGRATION_IS_WORKERLESS_AND_CONTINUATION_INDEPENDENT=PASS")

# A normalized semantic runner can change the capability-bound host runtime
# fingerprint while Loop's installed payload generation also changes. Fresh
# commissioning digests and an effort attestation may be rebound, but the
# requested capabilities/profile must remain fixed. The capability rebind and
# mission runtime identity must advance together before the quarantined job is
# made claimable.
capability_previous_db_path = db_path
capability_previous_xdg_state_home = os.environ["XDG_STATE_HOME"]
os.environ["XDG_STATE_HOME"] = str(root / "state-capability-runtime")
capability_runtime_db_path = supervisor_db.default_db_path()
with supervisor_db._managed_connect(capability_runtime_db_path):
    pass
db_path = capability_runtime_db_path
capability_runtime_repo, capability_runtime_baseline = make_repo(
    "v127-capability-runtime-migration",
)
capability_runtime_meta = v4_packet(
    capability_runtime_repo, capability_runtime_baseline,
)
capability_runtime_meta["capabilities"] = []
capability_runtime_run = "run-20260930T000000Z-v127capruntime"
original_profile_resolver_for_capability_fixture = runner_profiles.resolve_profile
initial_semantic_fingerprint = capabilities.semantic_runtime_fingerprint()
def resolve_profile_with_initial_attestation(name: str, *, provider: str | None = None) -> dict:
    profile = original_profile_resolver_for_capability_fixture(name, provider=provider)
    if provider == MissionFixtureRunner.runner_id:
        profile = dict(profile)
        profile["effort_attestation"] = {
            "attestation_sha256": "3" * 64,
            "evidence_kind": "operator_assertion",
            "profile_identity_sha256": profile["identity_sha256"],
            "schema": "ownframework-loop-runner-effort-operator-assertion/v3",
            "semantic_runtime_fingerprint": initial_semantic_fingerprint,
        }
    return profile
runner_profiles.resolve_profile = resolve_profile_with_initial_attestation
try:
    capability_runtime_fixture = start_v4(
        capability_runtime_repo, capability_runtime_baseline, capability_runtime_run,
        meta=capability_runtime_meta,
    )
finally:
    runner_profiles.resolve_profile = original_profile_resolver_for_capability_fixture
# A capability migration may refresh evidence digests, but must reject any
# change to the underlying requested capability, environment, or profile.
old_projection = copy.deepcopy(capability_runtime_fixture["binding"]["projection"])
old_projection["capabilities"] = [{
    "kind": "browser", "name": "browser.playwright.chromium",
    "provider": "builtin", "privileged": False,
    "network_domains": ["cdn.playwright.dev"],
    "commissioning_evidence_sha256": "a" * 64,
    "browser": {
        "browser_asset_merkle_sha256": "b" * 64,
        "browser_proof_sha256": "c" * 64,
        "browser_version": "153.0.8010.12",
    },
}]
old_projection["requested"] = ["browser.playwright.chromium"]
old_projection["requested_runner_profile"]["effort_attestation"] = {
    "attestation_sha256": "d" * 64,
    "profile_identity_sha256": capability_runtime_fixture["profile"]["identity_sha256"],
    "semantic_runtime_fingerprint": old_projection["semantic_runtime_fingerprint"],
}
new_projection = copy.deepcopy(old_projection)
new_projection["semantic_runtime_fingerprint"] = "e" * 64
new_projection["capabilities"][0]["commissioning_evidence_sha256"] = "f" * 64
new_projection["capabilities"][0]["browser"]["browser_proof_sha256"] = "1" * 64
new_projection["requested_runner_profile"]["effort_attestation"] = {
    "attestation_sha256": "2" * 64,
    "profile_identity_sha256": capability_runtime_fixture["profile"]["identity_sha256"],
    "semantic_runtime_fingerprint": "e" * 64,
}
assert program_mission_runtime._runtime_only_capability_transition({
    "previous_binding": {"projection": old_projection},
    "new_binding": {"projection": new_projection},
})

# A builtin, unprivileged package-manager version is semantic runtime identity,
# not new capability authority, provided its exact executable and scope remain
# unchanged. This is the package version emitted by the installed capability
# probe; the complete old/new projections remain bound in migration evidence.
package_old = copy.deepcopy(old_projection)
package_old["semantic_runtime_fingerprint"] = "4" * 64
package_old["capabilities"] = [{
    "kind": "package",
    "name": "package.npm",
    "provider": "builtin",
    "privileged": False,
    "executable": "/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js",
    "executable_sha256": "5" * 64,
    "network_domains": ["registry.npmjs.org"],
    "commissioning_evidence_sha256": "6" * 64,
    "version": "12.0.2",
}]
package_old["requested"] = ["package.npm"]
package_old["requested_runner_profile"]["effort_attestation"] = {
    "attestation_sha256": "7" * 64,
    "profile_identity_sha256": capability_runtime_fixture["profile"]["identity_sha256"],
    "semantic_runtime_fingerprint": "4" * 64,
}
package_new = copy.deepcopy(package_old)
package_new["semantic_runtime_fingerprint"] = "8" * 64
package_new["capabilities"][0]["version"] = "12.2.0"
package_new["capabilities"][0]["commissioning_evidence_sha256"] = "9" * 64
package_new["requested_runner_profile"]["effort_attestation"] = {
    "attestation_sha256": "a" * 64,
    "profile_identity_sha256": capability_runtime_fixture["profile"]["identity_sha256"],
    "semantic_runtime_fingerprint": "8" * 64,
}
assert program_mission_runtime._runtime_only_capability_transition({
    "previous_binding": {"projection": package_old},
    "new_binding": {"projection": package_new},
}), "same executable/scope package version refresh must be runtime-migratable"
for package_drift in ("executable", "executable_sha256", "network_domains", "privileged"):
    invalid_package = copy.deepcopy(package_new)
    if package_drift == "network_domains":
        invalid_package["capabilities"][0][package_drift] = ["unapproved.example"]
    elif package_drift == "privileged":
        invalid_package["capabilities"][0][package_drift] = True
    elif package_drift == "executable_sha256":
        invalid_package["capabilities"][0][package_drift] = "b" * 64
    else:
        invalid_package["capabilities"][0][package_drift] = "/tmp/unapproved-npm"
    assert not program_mission_runtime._runtime_only_capability_transition({
        "previous_binding": {"projection": package_old},
        "new_binding": {"projection": invalid_package},
    }), package_drift

for forbidden_change in ("requested_runner_profile", "capabilities", "network_domains"):
    invalid_projection = copy.deepcopy(new_projection)
    if forbidden_change == "requested_runner_profile":
        invalid_projection[forbidden_change]["model"] = "unauthorized-model"
    elif forbidden_change == "capabilities":
        invalid_projection[forbidden_change][0]["browser"]["browser_asset_merkle_sha256"] = "3" * 64
    else:
        invalid_projection[forbidden_change] = ["unapproved.example"]
    assert not program_mission_runtime._runtime_only_capability_transition({
        "previous_binding": {"projection": old_projection},
        "new_binding": {"projection": invalid_projection},
    }), forbidden_change
print("RUNTIME_MIGRATION_ALLOWS_PROOF_AND_EXACT_PACKAGE_VERSION_REFRESH=PASS")
capability_runtime_segment, _, capability_runtime_mission, _ = program_mission.load_segment(
    capability_runtime_repo, capability_runtime_run,
)
capability_runtime_mission_id = str(capability_runtime_segment["mission_id"])
capability_runtime_packet = state.run_dir(
    capability_runtime_repo, capability_runtime_run,
) / "WORK_PACKET.md"
capability_runtime_approval = approval.approval_path(
    capability_runtime_repo, capability_runtime_run,
)
capability_runtime_state = state.state_path(
    capability_runtime_repo, capability_runtime_run,
)
capability_runtime_events = state.events_path(
    capability_runtime_repo, capability_runtime_run,
)
capability_runtime_before = {
    "packet": util.sha256_file(capability_runtime_packet),
    "approval": util.sha256_file(capability_runtime_approval),
    "state": util.sha256_file(capability_runtime_state),
    "events": integrity.compute_event_chain_hash(capability_runtime_events),
    "binding": capability_runtime_fixture["binding"]["binding_sha256"],
    "runtime": util.sha256_file(program_mission._mission_runtime_path(
        capability_runtime_repo, capability_runtime_mission_id,
    )),
}
original_runtime_generation_fn = supervisor_runtime.runtime_generation
original_current_runtime_generation_fn = supervisor._current_runtime_generation
original_fingerprint_fn = capabilities.semantic_runtime_fingerprint
original_effort_attestation_fn = runner_profiles.verify_effort_attestation
try:
    supervisor_runtime.runtime_generation = lambda: capability_runtime_fixture["runtime_generation"] + ".quarantine-trigger"
    supervisor._current_runtime_generation = lambda: capability_runtime_fixture["runtime_generation"] + ".quarantine-trigger"
    quarantined = supervisor.run_one(db_path=capability_runtime_db_path)
    assert quarantined.get("action") == "QUARANTINED", quarantined
    quarantined_job = supervisor.status(
        canonical_repo=capability_runtime_repo,
        run_id=capability_runtime_run,
        db_path=capability_runtime_db_path,
    )
    assert quarantined_job["status"] == "QUARANTINED", quarantined_job
    quarantined_snapshot = dict(quarantined_job)

    # Model a new commissioned Loop payload and normalized Claude runtime.
    # Only runtime-bound proof identities change; requested authority stays
    # fixed and the fresh attestation is bound to the same named profile.
    target_generation = (
        capability_runtime_fixture["runtime_generation"].split("@payload-", 1)[0]
        + "@payload-" + "9" * 64
    )
    supervisor_runtime.runtime_generation = lambda: target_generation
    supervisor._current_runtime_generation = lambda: target_generation
    old_fingerprint = str(capability_runtime_fixture["binding"]["projection"].get(
        "semantic_runtime_fingerprint") or "")
    new_fingerprint = "f" * 64
    assert old_fingerprint != new_fingerprint
    capabilities.semantic_runtime_fingerprint = lambda: new_fingerprint
    new_attestation = {
        "attestation_sha256": "4" * 64,
        "evidence_kind": "operator_assertion",
        "profile_identity_sha256": capability_runtime_fixture["profile"]["identity_sha256"],
        "schema": "ownframework-loop-runner-effort-operator-assertion/v3",
        "semantic_runtime_fingerprint": new_fingerprint,
    }
    runner_profiles.verify_effort_attestation = lambda _profile: new_attestation
    implicit_resume = supervisor.resume(
        canonical_repo=capability_runtime_repo,
        run_id=capability_runtime_run,
        db_path=capability_runtime_db_path,
    )
    assert implicit_resume.get("resumed") is False, implicit_resume
    assert implicit_resume.get("reason") == "runtime_generation_rebind_refused", implicit_resume
    assert capability_binding._read(
        capability_binding.binding_path(capability_runtime_repo, capability_runtime_run),
    )["binding_sha256"] == capability_runtime_before["binding"]
    assert capability_binding._migration_records(
        capability_runtime_repo, capability_runtime_run,
    ) == []
    resumed = supervisor.resume(
        canonical_repo=capability_runtime_repo,
        run_id=capability_runtime_run,
        db_path=capability_runtime_db_path,
        rebind_capabilities=True,
        capability_migration_reason="v127 exact semantic runtime normalization fixture",
    )
    assert resumed.get("resumed") is True, resumed
    assert resumed.get("capability_migration_completed") is not True or resumed.get(
        "capability_migration", {}
    ).get("status") == "COMPLETE", resumed
    runtime_migration = resumed.get("runtime_migration")
    assert isinstance(runtime_migration, dict), (
        "combined generation/capability rebind must append mission runtime identity evidence",
        resumed,
    )
    assert runtime_migration["runtime_generation"] == target_generation
    assert runtime_migration["sequence"] == 1
    assert resumed["status"] == "QUEUED"
    cap_migration = resumed.get("capability_migration")
    assert isinstance(cap_migration, dict) and cap_migration["status"] == "COMPLETE", resumed
    migration_path = program_mission._mission_runtime_migration_path(
        capability_runtime_repo.resolve(), capability_runtime_mission_id, 1,
    )
    assert migration_path.is_file(), (str(migration_path), list(migration_path.parent.iterdir()), resumed)
    migration_doc, migration_sha = program_mission_runtime._read_runtime_migration_record(
        migration_path,
    )
    assert migration_sha == runtime_migration["sha256"]
    assert migration_doc["capability_migration_ref"] == {
        "sequence": cap_migration["migration_sequence"],
        "record_sha256": cap_migration["migration_record_sha256"],
        "previous_binding_sha256": cap_migration["previous_binding_sha256"],
        "new_binding_sha256": cap_migration["new_binding_sha256"],
    }
    replayed_runtime_migration = program_mission_runtime.prepare_runtime_generation_resume(
        capability_runtime_repo,
        capability_runtime_run,
        job_snapshot=quarantined_snapshot,
        target_runtime_generation=target_generation,
        capability_migration=cap_migration,
        db_path=capability_runtime_db_path,
    )
    assert replayed_runtime_migration == runtime_migration

    migrated_binding = capability_binding._read(
        capability_binding.binding_path(capability_runtime_repo, capability_runtime_run),
    )
    assert migrated_binding["binding_sha256"] != capability_runtime_before["binding"]
    assert migrated_binding["projection"]["semantic_runtime_fingerprint"] == new_fingerprint
    migrated_profile = dict(capability_runtime_fixture["profile"], effort_attestation=new_attestation)
    migrated_identity = program_mission_runtime.bind_runtime_identity(
        capability_runtime_repo,
        capability_runtime_run,
        run_binding=migrated_binding,
        runner_profile=migrated_profile,
        runtime_generation=target_generation,
    )
    assert migrated_identity["runtime_migration_sequence"] == 1
    assert migrated_identity["capability_binding_sha256"] == migrated_binding["binding_sha256"]
    verified = program_mission_runtime.verify_runtime_identity(
        capability_runtime_repo,
        capability_runtime_mission_id,
        run_binding=migrated_binding,
        runner_profile=migrated_profile,
        runtime_generation=target_generation,
        segment_number=1,
    )
    assert verified["semantic_runtime_fingerprint"] == new_fingerprint
    assert verified["capability_binding_sha256"] == migrated_binding["binding_sha256"]
    binding_receipt_path = program_mission._mission_runtime_binding_path(
        capability_runtime_repo.resolve(), capability_runtime_mission_id, 1,
    )
    receipt_doc, _ = program_mission_runtime._read_record(
        binding_receipt_path,
        expected_schema=program_mission_runtime.MISSION_RUNTIME_BINDING_SCHEMA,
    )
    assert receipt_doc["migration_sha256"] == runtime_migration["sha256"]
    assert receipt_doc["runtime_identity"] == migration_doc["runtime_identity"]
    assert util.sha256_file(capability_runtime_packet) == capability_runtime_before["packet"]
    assert util.sha256_file(capability_runtime_approval) == capability_runtime_before["approval"]
    assert util.sha256_file(capability_runtime_state) == capability_runtime_before["state"]
    assert integrity.compute_event_chain_hash(capability_runtime_events) == capability_runtime_before["events"]
    with supervisor_db._managed_connect_readonly(capability_runtime_db_path) as conn:
        attempts = conn.execute(
            "SELECT COUNT(*) FROM semantic_attempts WHERE job_id=?",
            (int(resumed["id"]),),
        ).fetchone()[0]
    assert int(attempts) == 0
    print("COMBINED_RUNTIME_AND_CAPABILITY_REFRESH_MIGRATION=PASS")
finally:
    supervisor_runtime.runtime_generation = original_runtime_generation_fn
    supervisor._current_runtime_generation = original_current_runtime_generation_fn
    capabilities.semantic_runtime_fingerprint = original_fingerprint_fn
    runner_profiles.verify_effort_attestation = original_effort_attestation_fn
    db_path = capability_previous_db_path
    os.environ["XDG_STATE_HOME"] = capability_previous_xdg_state_home

print("PROGRAM_BUDGET_SEGMENTATION=PASS")
PY

echo "PROGRAM_BUDGET_SEGMENTATION=PASS"
