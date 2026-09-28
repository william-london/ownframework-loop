#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib:$ROOT_DIR/tests/helpers${PYTHONPATH:+:$PYTHONPATH}"
export OFLOOP_LIB="$ROOT_DIR/lib"

TMP="$(mktemp -d -t ofloop-v123-review-recovery.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

python3 -B - "$TMP" <<'PY'
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

from ownframework_loop import (
    approval, assessment, capability_binding, dispatch, program, receipts,
    state, supervisor, supervisor_validation_recovery as recovery, util, verdicts,
    validation_evidence, transitions,
)
from state_seed import seed_state

root = Path(sys.argv[1])
repo = root / "repo"
repo.mkdir()
subprocess.run(["git", "init", "-q", "-b", "master", str(repo)], check=True)
subprocess.run(["git", "-C", str(repo), "config", "user.name", "Loop test"], check=True)
subprocess.run(["git", "-C", str(repo), "config", "user.email", "loop-test@example.invalid"], check=True)
(repo / "README.md").write_text("seed\n", encoding="utf-8")
subprocess.run(["git", "-C", str(repo), "add", "README.md"], check=True)
subprocess.run(["git", "-C", str(repo), "commit", "-qm", "seed"], check=True)
baseline = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
run_id = "run-20260927T000000Z-v123-recovery"
run_dir = repo / ".ownframework-loop" / run_id
run_dir.mkdir(parents=True)
packet = {
    "schema": "ownframework-work-packet/v3",
    "packet_id": "v123-recovery",
    "created_at": "2026-09-27T00:00:00Z",
    "work_class": "HARDENING",
    "risk_class": "low",
    "title": "validation infrastructure retry fixture",
    "target": {
        "repo": str(repo), "branch": "master", "classification": "local_only",
        "candidate_branch_prefix": f"factory/candidate/{run_id}",
    },
    "execution_mode": "program",
    "checkpoint_graph": {
        "execution_order": ["CP-01"],
        "checkpoints": [{
            "id": "CP-01", "title": "fixture", "scope": "test",
            "depends_on": [], "acceptance_criterion_ids": ["AC-01"],
            "risk_budget": {
                "max_build_passes": 2,
                "max_review_passes": 3,
                "max_repair_rounds": 1,
            },
        }],
    },
    "promotion_policy": "human_gate",
    "acceptance_criteria": [{"id": "AC-01", "text": "fixture"}],
    "non_goals": [],
    "allowed_paths": ["src/"],
    "protected_paths": [".ownframework-loop/"],
    "work_units": [{"id": "UNIT-01", "title": "fixture", "scope": "test"}],
    "merge_authority": "human_only",
    "deploy_authority": "human_only",
    "push_authority": "human_only",
    "external_action_authority": "none",
    "risk_budget": {
        "max_build_passes": 2,
        "max_review_passes": 3,
        "max_repair_rounds": 1,
        "max_files_changed": 5,
        "max_diff_lines": 100,
    },
}
import json
packet_path = run_dir / "WORK_PACKET.md"
packet_path.write_text("```json\n" + json.dumps(packet, sort_keys=True) + "\n```\n", encoding="utf-8")
candidate_branch = f"factory/candidate/{run_id}"
subprocess.run(["git", "-C", str(repo), "branch", candidate_branch], check=True)
packet_sha = util.sha256_file(packet_path)
approval_doc = {
    "schema": approval.SCHEMA_VERSION,
    "run_id": run_id,
    "packet_sha256": packet_sha,
    "approved_at": "2026-09-27T00:00:00Z",
    "approved_actor": "fixture",
    "canonical_repo": str(repo.resolve()),
    "baseline_branch": "master",
    "baseline_sha": baseline,
    "candidate_branch": candidate_branch,
    "packet_schema": packet["schema"],
    "approval_method": "build_start",
    "confirmation_token": approval.derive_confirmation_token(packet_sha),
}
approval_path = approval.approval_path(repo, run_id)
approval_path.write_text(json.dumps(approval_doc, indent=2, sort_keys=True), encoding="utf-8")
os.chmod(approval_path, 0o600)
approval_sha = approval.approval_artifact_sha256(approval_doc)
receipt_path = receipts.receipt_path(repo, run_id)
receipt_path.write_bytes(b"fixture build receipt\n")
receipt_sha = util.sha256_file(receipt_path)
state.save(repo, run_id, state.initial_state(run_id))
state.transition(repo, run_id, to_state="READY_TO_BUILD", actor="fixture", reason="fixture approval")
current = state.load(repo, run_id)
current["schema"] = state.PROGRAM_STATE_SCHEMA_VERSION
current["program"] = program.materialise_initial_program_state(
    packet, baseline_sha=baseline, candidate_branch=candidate_branch
)
current["program"]["cumulative_counters"].update({
    "build_pass_count": 2,
    "review_pass_count": 1,
    "repair_round_count": 1,
})
cp = current["program"]["checkpoints"][0]
cp.update({
    "build_pass_count": 2,
    "review_pass_count": 1,
    "repair_round_count": 1,
    "candidate_sha": baseline,
})
current.update({
    "state": "BLOCKED",
    "last_candidate_sha": baseline,
    "build_pass_count": 2,
    "review_pass_count": 1,
    "repair_round": 1,
})
seed_state(repo, run_id, current, actor="fixture", reason="seed exact blocked validation review")

attempt_id = "a" * 32
semantic_path = assessment.assessment_path(repo, run_id)
semantic_path.parent.mkdir(parents=True, exist_ok=True)
semantic_path.write_bytes(b"fixture accepted reviewer result\n")
semantic_sha = util.sha256_file(semantic_path)
verdict_path = verdicts.verdict_path(repo, run_id)
evidence_identity = validation_evidence.validation_identity(
    canonical_repo=repo,
    run_id=run_id,
    checkpoint_id="CP-01",
    role="reviewer",
    pass_number=1,
    validation_index=0,
    candidate_sha=baseline,
    cwd=util.reviewer_worktree(repo, run_id),
    validation={"name": "fixture-validation", "command": "true", "kind": "fast"},
)
evidence_reference = validation_evidence.publish_package_network_events(
    identity=evidence_identity,
    events=[{
        "kind": "dns_resolution_failed", "host": "pypi.org",
        "port": 443, "broker": "connect_proxy",
    }],
)
validation_row = {
    "name": "fixture-validation", "command": "true", "kind": "fast",
    "expected_exit_code": 0, "passed": False, "infra_failure": True,
    "candidate_invalid": False, "checkpoint_id": "CP-01", "pass_number": 1,
    "validation_index": 0, "infrastructure_evidence": evidence_reference,
}
prior_verdict_bytes = (json.dumps({"validation_results": [validation_row]}, sort_keys=True) + "\n").encode()
verdict_path.write_bytes(prior_verdict_bytes)
prior_verdict_sha = util.sha256_bytes(prior_verdict_bytes)
state.append_event(
    repo, run_id, event_type="review_finalized", old_state="REVIEWING",
    new_state="BLOCKED", actor="fixture-review-finalizer", commit_sha=baseline,
    reason="fixture trusted validation infrastructure block",
    extras={
        "verdict": "BLOCKED", "failure_reason": "infra_failure",
        "validation_pass": False, "infra_failure_count": 1,
        "validation_evidence_refs": validation_evidence.event_references([validation_row]),
    },
)
old_binding_sha, new_binding_sha = "7" * 64, "8" * 64
old_runtime, new_runtime = "old-runtime", "new-runtime"
accounting = {"cost": 0.0, "input": 0, "output": 0, "cache": 0}
accounting_sha = recovery._canonical_sha(accounting)
db_path = root / "supervisor.sqlite3"
with supervisor._managed_connect(db_path) as conn:
    cur = conn.execute(
        "INSERT INTO jobs (repo,run_id,runner,status,runtime_generation,execution_mode,"
        "candidate_branch,latest_attempt_id,total_cost_usd,total_input_tokens,"
        "total_output_tokens,total_cache_read_tokens,created_at,updated_at) "
        "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (str(repo.resolve()), run_id, "claude-code", "DONE", old_runtime, "PROGRAM",
         candidate_branch, attempt_id, 0.0, 0, 0, 0, 1.0, 1.0),
    )
    job_id = int(cur.lastrowid)
    conn.execute(
        "INSERT INTO semantic_attempts (attempt_id,job_id,role,status,started_at,"
        "completed_at,stdout_path,stderr_path,returncode,cost_usd,cost_accounted,"
        "semantic_accepted,cost_known,input_tokens,output_tokens,cache_read_tokens,"
        "tokens_known,failure_class,failure_reason,accepted_candidate_sha,"
        "accepted_semantic_sha256) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (attempt_id, job_id, "reviewer", "COMPLETED", 1.0, 2.0, "", "", 0,
         0.0, 1, 1, 1, 0, 0, 0, 1, None, None, baseline, semantic_sha),
    )

preflight_rows = [{
    "name": "fixture-validation", "command": "true", "passed": True,
    "exit_code": 0, "stdout_sha256": "a" * 64, "stderr_sha256": "b" * 64,
}]
preflight_sha = recovery._preflight_result_sha(preflight_rows)
identity = {
    "schema": recovery.SCHEMA,
    "repo": str(repo.resolve()),
    "run_id": run_id,
    "job_id": job_id,
    "checkpoint_id": "CP-01",
    "candidate_sha": baseline,
    "review_attempt_id": attempt_id,
    "semantic_sha256": semantic_sha,
    "prior_verdict_sha256": prior_verdict_sha,
    "validation_evidence_sha256": evidence_reference["sha256"],
    "validation_evidence_reference": evidence_reference,
    "validation_evidence_identity": evidence_identity,
    "packet_sha256": packet_sha,
    "approval_sha256": approval_sha,
    "build_receipt_sha256": receipt_sha,
    "prior_runtime_generation": old_runtime,
    "runtime_generation": new_runtime,
    "prior_capability_binding_sha256": old_binding_sha,
    "capability_binding_sha256": new_binding_sha,
    "counters": {"build": 2, "review": 1, "repair": 1},
    "accounting": accounting,
    "accounting_sha256": accounting_sha,
}
recovery_id = recovery._canonical_sha(identity)
intent = dict(identity, recovery_id=recovery_id)
recovery_dir = run_dir / "recovery" / "validation-infrastructure" / recovery_id
recovery._write_exact_private_json(recovery_dir / "INTENT.json", intent)
recovery._write_exact_private(recovery_dir / "REVIEW_VERDICT.before.json", prior_verdict_bytes)
recovery._write_exact_private_json(recovery_dir / "PREFLIGHT.json", dict(
    intent, preflight_sha256=preflight_sha, preflight_results=preflight_rows,
))

kwargs = {
    "packet": packet,
    "checkpoint_id": "CP-01",
    "candidate_sha": baseline,
    "review_attempt_id": attempt_id,
    "semantic_sha256": semantic_sha,
    "prior_verdict_sha256": prior_verdict_sha,
    "validation_evidence_sha256": evidence_reference["sha256"],
    "recovery_id": recovery_id,
    "prior_runtime_generation": old_runtime,
    "runtime_generation": new_runtime,
    "packet_sha256": packet_sha,
    "approval_sha256": approval_sha,
    "build_receipt_sha256": receipt_sha,
    "prior_capability_binding_sha256": old_binding_sha,
    "capability_binding_sha256": new_binding_sha,
    "checkpoint_build_pass_count": 2,
    "checkpoint_review_pass_count": 1,
    "checkpoint_repair_round_count": 1,
    "preflight_sha256": preflight_sha,
    "accounting_sha256": accounting_sha,
}
first = state.retry_blocked_program_review_after_validation_infrastructure(repo, run_id, **kwargs)
assert first["ok"] and first["idempotent"] is False, first
after_first = state.load_verified(repo, run_id)
assert after_first["state"] == "REVIEWING", after_first["state"]
assert after_first["build_pass_count"] == 2
assert after_first["review_pass_count"] == 1
assert after_first["repair_round"] == 1
assert after_first["program"]["cumulative_counters"] == current["program"]["cumulative_counters"]

second = state.retry_blocked_program_review_after_validation_infrastructure(repo, run_id, **kwargs)
assert second["ok"] and second["idempotent"] is True, second
after_second = state.load_verified(repo, run_id)
assert after_second["transitions_count"] == after_first["transitions_count"]
assert after_second["build_pass_count"] == 2
assert after_second["review_pass_count"] == 1
assert after_second["repair_round"] == 1
events = state.integrity.read_event_chain(state.events_path(repo, run_id)) if hasattr(state, "integrity") else None
assert events is not None
retries = [e for e in events if e.get("event_type") == "program_review_infrastructure_retry"]
assert len(retries) == 1, retries
assert retries[0]["accounting_sha256"] == kwargs["accounting_sha256"]
print("STATE_RETRY_NO_BUILD_REVIEW_REPAIR_COUNTER_DELTA=PASS")
print("STATE_RETRY_EVENT_IDEMPOTENCY=PASS")
print("STATE_RETRY_ACCOUNTING_IDENTITY_BOUND=PASS")

original_binding_read = capability_binding._read
original_runtime = supervisor._current_runtime_generation
original_ready = dispatch.semantic_result_ready
original_provenance = supervisor._attempt_provenance_gate
original_worktrees = recovery._assert_clean_candidate_worktrees
capability_binding._read = lambda _path: {
    "binding_sha256": new_binding_sha,
    "projection": {"capabilities": [{"name": "package.uv", "network_domains": ["pypi.org"]}]},
}
supervisor._current_runtime_generation = lambda: new_runtime
dispatch.semantic_result_ready = lambda _order: (True, "accepted fixture")
supervisor._attempt_provenance_gate = lambda *_a, **_k: (True, "accepted fixture", {})
recovery._assert_clean_candidate_worktrees = lambda *_a, **_k: None
try:
    result = recovery._complete_interrupted_requeue(
        repo=repo.resolve(), run_id=run_id, candidate=baseline, attempt_id=attempt_id,
        db_path=db_path, current=after_first, event=retries[0],
        recovery_dir=recovery_dir, supervisor_mod=supervisor,
    )
finally:
    capability_binding._read = original_binding_read
    supervisor._current_runtime_generation = original_runtime
    dispatch.semantic_result_ready = original_ready
    supervisor._attempt_provenance_gate = original_provenance
    recovery._assert_clean_candidate_worktrees = original_worktrees
assert result["ok"] and result["status"] == "QUEUED" and result["idempotent"] is True, result
with supervisor._managed_connect_readonly(db_path) as conn:
    job, _ = supervisor._logical_job_row(conn, repo, run_id)
    assert job["status"] == "QUEUED"
    assert job["runtime_generation"] == new_runtime
    assert job["latest_attempt_id"] == attempt_id
    assert job["total_cost_usd"] == 0
assert state.load_verified(repo, run_id)["build_pass_count"] == 2
assert state.load_verified(repo, run_id)["review_pass_count"] == 1
assert state.load_verified(repo, run_id)["repair_round"] == 1
print("DONE_TO_QUEUED_CRASH_REPLAY_NO_PROVIDER_OR_COUNTER_DELTA=PASS")

stopped_state = state.load_verified(repo, run_id)
stopped_state["state"] = "STOPPED"
seed_state(repo, run_id, stopped_state, actor="fixture", reason="prove STOPPED remains absorbing")
try:
    state.retry_blocked_program_review_after_validation_infrastructure(
        repo, run_id, **kwargs
    )
except transitions.InvalidTransitionError as exc:
    assert "STOPPED is absorbing" in str(exc), exc
else:
    raise AssertionError("validation-infrastructure recovery reopened STOPPED")
print("STOPPED_REMAINS_ABSORBING=PASS")
PY

echo "VALIDATION_INFRASTRUCTURE_REVIEW_RECOVERY=PASS"
