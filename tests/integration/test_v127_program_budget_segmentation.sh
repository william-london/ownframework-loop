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
import hashlib
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
    capabilities, capability_binding, execution_start, integrity, packet,
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
              max_segments: int = 2, checkpoint_count: int = 3) -> dict:
    order = [f"CP-{index:02d}" for index in range(checkpoint_count)]
    checkpoints = []
    acceptance = []
    units = []
    for index, cp_id in enumerate(order):
        ac_id = f"AC-{index:02d}"
        unit_id = f"UNIT-{index:02d}"
        acceptance.append({"id": ac_id, "text": f"fixture acceptance {index}"})
        units.append({"id": unit_id, "title": f"fixture unit {index}", "scope": "src/"})
        checkpoints.append({
            "id": cp_id,
            "title": f"fixture checkpoint {index}",
            "scope": "src/",
            "depends_on": [] if index == 0 else [order[index - 1]],
            "acceptance_criterion_ids": [ac_id],
            "work_units": [unit_id],
            "risk_budget": {
                "max_build_passes": 3,
                "max_review_passes": 3,
                "max_repair_rounds": 1,
            },
        })
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
                "max_baseline_to_final_diff_lines": segment_lines,
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
        "risk_budget": {
            "max_build_passes": checkpoint_count * 3,
            "max_review_passes": checkpoint_count * 4 + 1,
            "max_repair_rounds": checkpoint_count,
            "max_files_changed": 10,
            "max_diff_lines": segment_lines,
        },
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
                 pre_finalize_state_out: list[dict] | None = None) -> tuple[str, dict]:
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
    receipt = build_finalize.finalize_build(
        canonical_repo=repo, run_id=run_id, agent_result_path=result_path,
        actor="v127-fixture-builder",
    )
    assert receipt["candidate_sha"] == candidate, receipt
    assert receipt["validation_status"] == "PASS", receipt
    assert receipt["next_state"] == expected_state, receipt
    assert state.load_verified(repo, run_id)["last_candidate_sha"] == candidate
    return candidate, receipt


def finish_review(fixture: dict, *, final: bool = False) -> dict:
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
    assess["findings"] = []
    assess["validation_results"] = []
    assess["recommended_verdict"] = "APPROVED"
    assess["timestamp"] = util.utc_now_iso()
    assess_path.write_text(json.dumps(assess, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    verdict = review_finalize.finalize_review(
        canonical_repo=repo, run_id=run_id, assessment_path=assess_path,
        actor="v127-fixture-reviewer",
    )
    assert verdict["candidate_sha_reviewed"] == candidate, verdict
    assert verdict["review_pass_number"] == claim["claimed_pass_number"], verdict
    assert verdict["verdict"] == "APPROVED", verdict
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
assert packet.validate_packet_for_approval(covered) == []
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
ok, proof = program_mission.segment_boundary_eligibility(repo, parent, **base_args)
assert ok, proof
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

# Typed legacy admission is exercised with a synthetic v3 source authority. The
# legacy verifier is replaced only in this disposable unit fixture; source
# artifacts, source packet bytes, and source ledger row remain outside the
# successor mutation and are hash-checked before/after.
legacy_repo, legacy_baseline = make_repo("v127-legacy-admission")
legacy_id = "run-20260929T000000Z-v127legacy"
legacy_branch = "factory/candidate/v127-legacy-source"
git(legacy_repo, "switch", "-qc", legacy_branch)
(legacy_repo / "src").mkdir()
(legacy_repo / "src" / "base.py").write_text("BASE = 1\n", encoding="utf-8")
git(legacy_repo, "add", "src/base.py"); git(legacy_repo, "commit", "-qm", "legacy approved candidate")
approved_legacy = git(legacy_repo, "rev-parse", "HEAD")
(legacy_repo / "src" / "base.py").write_text("BASE = 2\n", encoding="utf-8")
(legacy_repo / "docs" / "governance").mkdir(parents=True)
(legacy_repo / "docs" / "governance" / "RESEARCH_PROVENANCE.md").write_text("authorized path\n", encoding="utf-8")
git(legacy_repo, "add", "src/base.py", "docs/governance/RESEARCH_PROVENANCE.md")
git(legacy_repo, "commit", "-qm", "legacy crossing candidate")
crossing_legacy = git(legacy_repo, "rev-parse", "HEAD")
git(legacy_repo, "switch", "-q", "master")

legacy_order = ["CP-00", "CP-01"]
legacy_checkpoints = [
    {"id": "CP-00", "title": "approved", "scope": "src/", "depends_on": [],
     "acceptance_criterion_ids": ["AC-00"], "risk_budget": {"max_build_passes": 2, "max_review_passes": 2, "max_repair_rounds": 1}},
    {"id": "CP-01", "title": "remaining", "scope": "src/", "depends_on": ["CP-00"],
     "acceptance_criterion_ids": ["AC-01"], "risk_budget": {"max_build_passes": 3, "max_review_passes": 3, "max_repair_rounds": 1}},
]
legacy_meta = {
    "schema": "ownframework-work-packet/v3", "packet_id": "v127-legacy", "created_at": "2026-09-29T00:00:00Z",
    "work_class": "FEATURE", "risk_class": "medium", "title": "typed legacy admission fixture",
    "runner_profile": "default", "target": {"repo": str(legacy_repo.resolve()), "branch": "master", "classification": "local_only", "candidate_branch_prefix": legacy_branch},
    "execution_mode": "program", "checkpoint_graph": {"execution_order": legacy_order, "checkpoints": legacy_checkpoints,
        "global_source_ceilings": {"max_unique_changed_files": 20, "max_baseline_to_final_diff_lines": 30000}},
    "promotion_policy": "human_gate", "acceptance_criteria": [{"id": "AC-00", "text": "approved"}, {"id": "AC-01", "text": "remaining"}],
    "non_goals": [], "required_validation": [{"name": "fixture", "command": "true", "kind": "fast"}],
    "allowed_paths": ["src/"], "protected_paths": [".ownframework-loop/"],
    "work_units": [{"id": "UNIT-00", "title": "approved unit", "scope": "src/"}],
    "merge_authority": "human_only", "deploy_authority": "human_only", "push_authority": "human_only", "external_action_authority": "none",
    "risk_budget": {"max_build_passes": 5, "max_review_passes": 6, "max_repair_rounds": 2, "max_files_changed": 20, "max_diff_lines": 30000},
}
assert packet.validate_packet_for_approval(legacy_meta) == []
legacy_root = state.run_dir(legacy_repo, legacy_id); legacy_root.mkdir(parents=True)
legacy_packet_bytes = ("```json\n" + json.dumps(legacy_meta, sort_keys=True, indent=2) + "\n```\nlegacy fixture\n").encode()
(legacy_root / "WORK_PACKET.md").write_bytes(legacy_packet_bytes)
state.save(legacy_repo, legacy_id, state.initial_state(legacy_id))
state.append_event(legacy_repo, legacy_id, event_type="run_created", old_state=None, new_state="AWAITING_APPROVAL", actor="test", reason="legacy source")
legacy_enqueue = supervisor.enqueue(
    canonical_repo=legacy_repo, run_id=legacy_id, runner=MissionFixtureRunner.runner_id,
    db_path=db_path, max_total_cost_usd=50.0, max_total_tokens=100000, max_wall_seconds=0,
    runtime_generation=supervisor_runtime.runtime_generation(),
)
assert legacy_enqueue.get("ok") is True, legacy_enqueue
with supervisor_db._managed_connect(db_path) as conn:
    conn.execute("UPDATE jobs SET status='DONE' WHERE repo=? AND run_id=?", (str(legacy_repo.resolve()), legacy_id))

source_program = program.materialise_initial_program_state(
    legacy_meta, baseline_sha=legacy_baseline, candidate_branch=legacy_branch,
)
cp0 = next(item for item in source_program["checkpoints"] if item["id"] == "CP-00")
cp0.update({"build_pass_count": 1, "review_pass_count": 1, "candidate_sha": approved_legacy})
source_program["cumulative_counters"]["build_pass_count"] = 1
source_program["cumulative_counters"]["review_pass_count"] = 1
source_program = program.finalize_checkpoint(
    program_state=source_program, cp_id="CP-00", terminal_state="APPROVED",
    evidence_manifest={"_packet": legacy_meta, "candidate_sha": approved_legacy, "verdict_sha256": "a" * 64},
)
source_program = program.advance_to_next(source_program, legacy_meta)
next_cp = next(item for item in source_program["checkpoints"] if item["id"] == "CP-01")
next_cp["checkpoint_entry_candidate_sha"] = approved_legacy
synthetic_prefix = [{
    "checkpoint_id": "CP-00", "terminal_state": "APPROVED", "candidate_sha": approved_legacy,
    "verdict_sha256": "a" * 64, "next_checkpoints": ["CP-01"], "source_event_sha256": "b" * 64,
}]
legacy_source_state = {
    "run_id": legacy_id, "state": "BLOCKED", "last_candidate_sha": crossing_legacy,
    "build_pass_count": 4, "review_pass_count": 2, "repair_round": 1,
    "no_progress_streak": 0, "program": source_program,
}
source_program["cumulative_counters"].update({"build_pass_count": 4, "review_pass_count": 2, "repair_round_count": 1})
legacy_source_state["program"] = source_program
legacy_source_state_sha = util.sha256_file(legacy_root / "STATE.json")
legacy_events_sha = integrity.compute_event_chain_hash(legacy_root / "EVENTS.log")
legacy_packet_sha = hashlib.sha256(legacy_packet_bytes).hexdigest()
with supervisor_db._managed_connect_readonly(db_path) as conn:
    legacy_job = dict(conn.execute("SELECT * FROM jobs WHERE repo=? AND run_id=?", (str(legacy_repo.resolve()), legacy_id)).fetchone())
validated_source = {
    "state": legacy_source_state, "packet_meta": legacy_meta, "packet_sha256": legacy_packet_sha,
    "approval": {}, "approval_file_sha256": "c" * 64, "approval_sha256": "d" * 64,
    "baseline_sha": legacy_baseline, "baseline_branch": "master", "candidate_branch": legacy_branch,
    "program": source_program, "events": [], "approved_prefix": synthetic_prefix,
    "event_chain_sha256": legacy_events_sha, "state_sha256": legacy_source_state_sha,
    "review_verdict_sha256": "e" * 64, "build_receipt_sha256": "f" * 64,
    "approved_verdict_sha256": "a" * 64, "approved_source_lines": program_mission._line_count(legacy_repo, legacy_baseline, approved_legacy),
    "changed_paths": ["src/base.py", "docs/governance/RESEARCH_PROVENANCE.md"],
    "scope_paths": ["docs/governance/RESEARCH_PROVENANCE.md"], "job": legacy_job,
    "attempts": [], "accounting": {},
}
real_validator = program_mission._validate_legacy_source
program_mission._validate_legacy_source = lambda *args, **kwargs: copy.deepcopy(validated_source)
legacy_args = dict(
    expected_packet_sha256=legacy_packet_sha, expected_baseline_sha=legacy_baseline,
    approved_checkpoint_id="CP-00", approved_candidate_sha=approved_legacy,
    crossing_candidate_sha=crossing_legacy, expected_remaining_checkpoints=["CP-01"],
    authorized_scope_paths=["docs/governance/RESEARCH_PROVENANCE.md"],
    segment_max_diff_lines=18000, mission_max_diff_lines=48000, max_segments=2,
    expected_approved_source_lines=None, confirmation=f"LEGACY-CONTINUE:{legacy_id}", db_path=db_path,
)
try:
    legacy_admission = program_mission.admit_legacy_continuation(legacy_repo, legacy_id, **legacy_args)
    replayed_admission = program_mission.admit_legacy_continuation(legacy_repo, legacy_id, **legacy_args)
    try:
        program_mission.admit_legacy_continuation(
            legacy_repo, legacy_id, **{**legacy_args, "mission_max_diff_lines": 48001},
        )
    except program_mission.MissionAuthorityError:
        pass
    else:
        raise AssertionError("contradictory replayed legacy authority was accepted")
finally:
    program_mission._validate_legacy_source = real_validator
assert legacy_admission["run_id"] == replayed_admission["run_id"]
assert legacy_admission["baseline_sha"] == approved_legacy
assert legacy_admission["current_checkpoints"] == ["CP-01"]
assert legacy_admission["source_crossing_candidate_preserved"] == crossing_legacy
assert legacy_admission["source_run_unchanged"] is True
assert legacy_admission["source_build_pass_count"] == 4
legacy_child_packet, _ = packet.parse_packet_file(state.run_dir(legacy_repo, legacy_admission["run_id"]) / "WORK_PACKET.md")
assert legacy_child_packet["schema"] == packet.MISSION_PROGRAM_SCHEMA_VERSION
assert legacy_child_packet["mission_budget"]["segment_max_diff_lines"] == 18000
assert legacy_child_packet["mission_budget"]["mission_max_diff_lines"] == 48000
assert "docs/governance/RESEARCH_PROVENANCE.md" in legacy_child_packet["allowed_paths"]
assert legacy_child_packet["checkpoint_graph"]["checkpoints"][1]["required_paths"] == ["docs/governance/RESEARCH_PROVENANCE.md"]
assert state.load_verified(legacy_repo, legacy_admission["run_id"])["state"] == "READY_TO_BUILD"
assert supervisor.status(canonical_repo=legacy_repo, run_id=legacy_admission["run_id"], db_path=db_path)["status"] == "QUEUED"
assert util.sha256_file(legacy_root / "WORK_PACKET.md") == legacy_packet_sha
assert util.sha256_file(legacy_root / "STATE.json") == legacy_source_state_sha
assert integrity.compute_event_chain_hash(legacy_root / "EVENTS.log") == legacy_events_sha
with supervisor_db._managed_connect_readonly(db_path) as conn:
    assert conn.execute("SELECT COUNT(*) FROM jobs WHERE repo=? AND run_id=?", (str(legacy_repo.resolve()), legacy_admission["run_id"])).fetchone()[0] == 1
print("TYPED_LEGACY_ADMISSION_SCOPE_BASELINE_REPLAY_AND_IMMUTABILITY=PASS")

print("PROGRAM_BUDGET_SEGMENTATION=PASS")
PY

echo "PROGRAM_BUDGET_SEGMENTATION=PASS"
