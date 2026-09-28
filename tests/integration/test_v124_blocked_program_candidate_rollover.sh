#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib:$ROOT_DIR/tests/helpers${PYTHONPATH:+:$PYTHONPATH}"
export OFLOOP_LIB="$ROOT_DIR/lib"
TMP="$(mktemp -d -t ofloop-v124-rollover.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

python3 -B - "$TMP/repo" <<'PY'
import hashlib, json, os, subprocess, sys
from pathlib import Path
from ownframework_loop import (
    approval, capabilities, capability_binding, integrity, packet, program,
    program_rollover, receipts, runner_profiles, runtime_env, state, util,
)

repo = Path(sys.argv[1]); repo.mkdir(parents=True)
os.environ["XDG_STATE_HOME"] = str(repo.parent / "state")
parent, child = "run-2026-09-28-roll-parent", "roll-test-v124-child"
subprocess.run(["git", "init", "-q", "-b", "master", str(repo)], check=True)
subprocess.run(["git", "-C", str(repo), "config", "user.name", "Loop test"], check=True)
subprocess.run(["git", "-C", str(repo), "config", "user.email", "loop-test@example.invalid"], check=True)
(repo / "README.md").write_text("fixture\n", encoding="utf-8")
subprocess.run(["git", "-C", str(repo), "add", "README.md"], check=True)
subprocess.run(["git", "-C", str(repo), "commit", "-qm", "baseline"], check=True)
baseline = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
parent_branch = "factory/candidate/parent-run"
subprocess.run(["git", "-C", str(repo), "switch", "-qc", parent_branch], check=True)
(repo / "src").mkdir()
(repo / "src" / "thermostat.py").write_text('def status():\n    return "ready"\n', encoding="utf-8")
subprocess.run(["git", "-C", str(repo), "add", "src/thermostat.py"], check=True)
subprocess.run(["git", "-C", str(repo), "commit", "-qm", "candidate"], check=True)
candidate = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
subprocess.run(["git", "-C", str(repo), "switch", "-q", "master"], check=True)
child_branch = f"factory/candidate/{child}"
meta = {
    "schema": "ownframework-work-packet/v3", "packet_id": "v124-rollover",
    "created_at": "2026-09-28T00:00:00Z", "work_class": "HARDENING",
    "risk_class": "low", "title": "linked rollover fixture", "runner_profile": "default",
    "target": {"repo": str(repo), "branch": "master", "classification": "local_only",
               "candidate_branch_prefix": "factory/candidate/parent-run",
               "expected_baseline_sha": baseline},
    "execution_mode": "program",
    "checkpoint_graph": {"execution_order": ["CP-00", "CP-01"], "checkpoints": [
        {"id": "CP-00", "title": "first", "scope": "src/", "depends_on": [],
         "acceptance_criterion_ids": ["AC-00"], "risk_budget": {"max_build_passes": 2, "max_review_passes": 2, "max_repair_rounds": 1}},
        {"id": "CP-01", "title": "second", "scope": "src/", "depends_on": ["CP-00"],
         "acceptance_criterion_ids": ["AC-01"], "risk_budget": {"max_build_passes": 2, "max_review_passes": 3, "max_repair_rounds": 1}},
    ]},
    "promotion_policy": "human_gate",
    "acceptance_criteria": [{"id": "AC-00", "text": "first"}, {"id": "AC-01", "text": "second"}],
    "non_goals": [], "required_validation": [{"name": "fixture", "command": "true", "kind": "fast"}],
    "allowed_paths": ["src/"], "protected_paths": [".ownframework-loop/"],
    "work_units": [{"id": "UNIT-00", "title": "fixture", "scope": "src/"}],
    "merge_authority": "human_only", "deploy_authority": "human_only",
    "push_authority": "human_only", "external_action_authority": "none",
    "risk_budget": {"max_build_passes": 5, "max_review_passes": 6,
                     "max_repair_rounds": 2, "max_files_changed": 20, "max_diff_lines": 1000},
}
errors = packet.validate_packet_for_approval(meta); assert not errors, errors
packet_bytes = ("```json\n" + json.dumps(meta, sort_keys=True) + "\n```\n").encode()
root = state.run_dir(repo, child); root.mkdir(parents=True)
(root / "WORK_PACKET.md").write_bytes(packet_bytes)
profile = runner_profiles.resolve_profile("default", provider="claude-code")
resolution = capabilities.resolve_capabilities(
    [], canonical_repo=repo, role="reviewer",
    repo_cache_root=runtime_env.repo_tool_cache_dir(repo),
    ephemeral_cache_root=runtime_env.runtime_cache_dir(repo, child, "validation") / "capability-cache",
    evidence_run_key=child,
)
child_binding = capability_binding.ensure_run_binding(
    repo, child, resolution, profile, allow_create=True,
)

p = program.materialise_initial_program_state(meta, baseline_sha=baseline,
                                               candidate_branch=parent_branch)
cp0, cp1 = p["checkpoints"]
cp0.update({"build_pass_count": 1, "review_pass_count": 1, "candidate_sha": candidate})
cp1.update({"build_pass_count": 2, "review_pass_count": 2, "repair_round_count": 1,
            "candidate_sha": candidate, "checkpoint_entry_candidate_sha": candidate})
stats = receipts.compute_diff_stats(repo, baseline, candidate)
p["cumulative_counters"].update({"build_pass_count": 3, "review_pass_count": 3,
    "repair_round_count": 1, "files_changed_unique": stats["files_changed"],
    "diff_lines_total": stats["added_lines"] + stats["removed_lines"]})
p = program.finalize_checkpoint(program_state=p, cp_id="CP-00", terminal_state="APPROVED",
    evidence_manifest={"_packet": meta, "candidate_sha": candidate, "verdict_sha256": "c" * 64})
p = program.advance_to_next(p, meta)
assert p["current_checkpoints"] == ["CP-01"]
assert program_rollover._verified_current_checkpoint_id(meta, p) == "CP-01"
bad = json.loads(json.dumps(p)); bad["current_checkpoints"] = ["CP-00"]
try: program_rollover._verified_current_checkpoint_id(meta, bad)
except program_rollover.ProgramRolloverRefused: pass
else: raise AssertionError("backward checkpoint authority was accepted")

counters = {"build_pass_count": 3, "review_pass_count": 3, "repair_round_count": 1,
            "files_changed_unique": stats["files_changed"],
            "diff_lines_total": stats["added_lines"] + stats["removed_lines"]}
parent_root = state.run_dir(repo, parent); parent_root.mkdir(parents=True)
(parent_root / "WORK_PACKET.md").write_bytes(packet_bytes)
(parent_root / "APPROVAL.json").write_bytes(b"fixture parent approval\n")
(parent_root / "BUILD_RECEIPT.json").write_bytes(b"fixture parent build receipt\n")
(parent_root / "REVIEW_VERDICT.json").write_bytes(b"fixture parent review verdict\n")
assessment_path = parent_root / "scratch" / "REVIEW_AGENT_ASSESSMENT.json"
assessment_path.parent.mkdir(); assessment_path.write_bytes(b"fixture reviewer assessment\n")
parent_state = state.initial_state(parent)
state.save(repo, parent, parent_state)
state.append_event(repo, parent, event_type="run_created", old_state=None,
    new_state="AWAITING_APPROVAL", actor="test", reason="immutable parent evidence fixture")
hashes = {
    "packet": util.sha256_file(parent_root / "WORK_PACKET.md"),
    "approval": util.sha256_file(parent_root / "APPROVAL.json"),
    "state": util.sha256_file(parent_root / "STATE.json"),
    "events": integrity.compute_event_chain_hash(parent_root / "EVENTS.log"),
    "build": util.sha256_file(parent_root / "BUILD_RECEIPT.json"),
    "verdict": util.sha256_file(parent_root / "REVIEW_VERDICT.json"),
    "assessment": util.sha256_file(assessment_path),
}
authority = {"schema": program_rollover.AUTHORITY_SCHEMA, "parent_run_id": parent,
    "child_run_id": child, "candidate_sha": candidate,
    "child_packet_sha256": util.sha256_file(root / "WORK_PACKET.md"),
    "child_baseline_sha": baseline, "child_baseline_branch": "master",
    "child_candidate_branch": child_branch,
    "source": {"packet_sha256": hashes["packet"], "approval_sha256": hashes["approval"],
        "state_sha256": hashes["state"], "event_chain_sha256": hashes["events"],
        "build_receipt_sha256": hashes["build"], "review_verdict_sha256": hashes["verdict"],
        "review_assessment_sha256": hashes["assessment"], "review_attempt_id": "1" * 32,
        "review_assessment_path": str(assessment_path),
        "parent_candidate_sha": candidate, "parent_candidate_branch": parent_branch},
    "imported_counters": counters,
    "operational_envelope_remaining": {
        "max_infra_failures": 0, "max_transient_failures": 0,
        "max_transient_recovery_cycles": 0, "max_total_cost_usd": 0.0,
        "max_total_tokens": 0, "max_wall_seconds": 0,
        "max_pass_runtime_seconds": 0,
    },
    "wall_clock_authority": {
        "parent_deadline_unix": None, "child_execution_started_at": None,
    },
    "capability_binding_sha256": child_binding["binding_sha256"],
    "runner": "claude-code",
}
authority_path = root / "ROLLOVER_AUTHORITY.json"
authority_path.write_text(json.dumps(authority, sort_keys=True, indent=2), encoding="utf-8")
os.chmod(authority_path, 0o600)
authority_sha = util.sha256_file(authority_path)
assert authority["child_run_id"] == child and authority["parent_run_id"] == parent
assert authority["candidate_sha"] == candidate
assert authority["child_packet_sha256"] == util.sha256_file(root / "WORK_PACKET.md")
assert authority["child_baseline_sha"] == baseline and authority["child_baseline_branch"] == "master"
assert authority["child_candidate_branch"] == child_branch
initial = state.initial_state(child)
initial.update({"spec_baseline_branch": "master", "spec_baseline_sha": baseline,
                "spec_snapshot_at": "2026-09-28T00:00:00Z"})
state.save(repo, child, initial)
state.append_event(repo, child, event_type="run_created", old_state=None,
    new_state="AWAITING_APPROVAL", actor="test", reason="rollover fixture")

p["source_sha_provenance"]["candidate_branch"] = child_branch
p["rollover_provenance"] = {
    "schema": "ownframework-loop-program-rollover/v1", "parent_run_id": parent,
    "candidate_sha": candidate, "rollover_authority_sha256": authority_sha,
    "source_packet_sha256": hashes["packet"], "source_approval_sha256": hashes["approval"],
    "source_state_sha256": hashes["state"], "source_event_chain_sha256": hashes["events"],
    "source_build_receipt_sha256": hashes["build"], "source_review_verdict_sha256": hashes["verdict"],
    "source_review_assessment_sha256": hashes["assessment"], "source_review_attempt_id": "1" * 32,
    "checkpoint_id": "CP-01", "imported_counters": counters,
    "checkpoint_counters": {"build_pass_count": 2, "review_pass_count": 2,
        "repair_round_count": 1, "no_progress_streak": 0}, "initial_review_pass_number": 4}
result = state.initialize_program_rollover(repo, child, program_block=p,
    build_pass_count=3, review_pass_count=3, repair_round=1, no_progress_streak=0,
    candidate_sha=candidate, baseline_sha=baseline, baseline_branch="master",
    candidate_branch=child_branch, parent_run_id=parent, rollover_authority_sha256=authority_sha)
verified = state.load_verified(repo, child)
assert result["state"] == "AWAITING_APPROVAL"
assert verified["program"]["current_checkpoints"] == ["CP-01"]
assert verified["program"]["finalized_checkpoints"][0]["id"] == "CP-00"
assert (verified["build_pass_count"], verified["review_pass_count"], verified["repair_round"]) == (3, 3, 1)
assert (verified["program"]["checkpoints"][1]["build_pass_count"],
        verified["program"]["checkpoints"][1]["repair_round_count"]) == (2, 1)
packet_sha = util.sha256_file(root / "WORK_PACKET.md")
approval_doc = {
    "schema": approval.SCHEMA_VERSION, "run_id": child, "packet_sha256": packet_sha,
    "approved_at": "2026-09-28T00:00:00Z", "approved_actor": "fixture",
    "canonical_repo": str(repo.resolve()), "baseline_branch": "master",
    "baseline_sha": baseline, "candidate_branch": child_branch,
    "packet_schema": meta["schema"], "approval_method": "build_start",
    "confirmation_token": approval.derive_confirmation_token(packet_sha),
}
util.atomic_write_json(approval.approval_path(repo, child), approval_doc, mode=0o600)
state.transition(repo, child, to_state="READY_TO_BUILD", actor="fixture", reason="approved test child")
parent_verifier = program_rollover._verify_parent_source_authority
validation_runner = program_rollover.validation_executor.run_required_validation
program_rollover._verify_parent_source_authority = lambda _repo, _authority: None
program_rollover.validation_executor.run_required_validation = lambda **kw: {
    "name": kw["validation"]["name"], "command": kw["validation"]["command"],
    "kind": kw["validation"]["kind"], "expected_exit_code": 0,
    "expected_marker": None, "passed": True, "infra_failure": False,
    "candidate_invalid": False, "timed_out": False, "exit_code": 0,
    "duration_seconds": 0.0,
    "stdout_sha256": "d" * 64, "stderr_sha256": "e" * 64,
    "checkpoint_id": kw["checkpoint_id"], "pass_number": kw["pass_number"],
    "validation_index": kw["validation_index"],
}
try:
    admitted = program_rollover.prepare_rollover_review(canonical_repo=repo, run_id=child)
finally:
    program_rollover._verify_parent_source_authority = parent_verifier
    program_rollover.validation_executor.run_required_validation = validation_runner
assert admitted["state"] == "READY_FOR_REVIEW", admitted
after = state.load_verified(repo, child)
assert after["last_candidate_sha"] == candidate
assert (after["build_pass_count"], after["review_pass_count"], after["repair_round"]) == (3, 3, 1)
assert after["program"]["checkpoints"][1]["build_pass_count"] == 2
receipt = receipts.load_receipt(repo, child)
assert receipt["validation_status"] == "PASS"
assert receipt["candidate_origin"]["candidate_sha"] == candidate
assert (root / "ROLLOVER_PREFLIGHT.json").is_file()
print("ROLLOVER_FRESH_VALIDATION_ADMITS_ORDINARY_REVIEW=PASS")
print("ROLLOVER_PRESERVES_APPROVED_PREFIX=PASS")
print("ROLLOVER_PRESERVES_EXHAUSTED_CURRENT_COUNTERS=PASS")
print("ROLLOVER_REJECTS_BACKWARD_CURRENT_CHECKPOINT=PASS")
PY

echo "BLOCKED_PROGRAM_CANDIDATE_ROLLOVER=PASS"
