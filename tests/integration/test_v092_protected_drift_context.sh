#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"

PYTHONPATH="$OFLOOP_LIB" PYTHONDONTWRITEBYTECODE=1 python3 -B <<'PY'
import json
import os
import stat
import subprocess
import tempfile
import sys
from pathlib import Path

from ownframework_loop import approval, program, protected_recovery, supervisor, util


def run(repo: Path, *args: str, env=None):
    return subprocess.run(["git", "-C", str(repo), *args], text=True,
                          capture_output=True, check=True, env=env)


def out(repo: Path, *args: str) -> str:
    return run(repo, *args).stdout.strip()


with tempfile.TemporaryDirectory() as td:
    repo = Path(td)
    run(repo, "init", "-q")
    out(repo, "config", "user.name", "test")
    out(repo, "config", "user.email", "test@example.invalid")
    (repo / "src").mkdir()
    (repo / "docs").mkdir()
    (repo / "src" / "feature.py").write_text("base\n")
    (repo / "docs" / "protected.md").write_text("approved\n")
    out(repo, "add", ".")
    out(repo, "commit", "-qm", "baseline")
    baseline = out(repo, "rev-parse", "HEAD")
    out(repo, "checkout", "-qb", "candidate")
    (repo / "src" / "feature.py").write_text("candidate\n")
    (repo / "docs" / "protected.md").write_text("model drift\n")
    out(repo, "add", ".")
    out(repo, "commit", "-qm", "candidate")
    candidate = out(repo, "rev-parse", "HEAD")
    out(repo, "checkout", "--detach", "-q")

    run_dir = repo / ".ownframework-loop" / "run-test"
    run_dir.mkdir(parents=True)
    packet = {
        "protected_paths": ["docs/protected.md"],
        "allowed_paths": ["src/"],
        "checkpoint_graph": {
            "execution_order": ["CP-1"],
            "checkpoints": [{"id": "CP-1", "acceptance_criterion_ids": ["AC-1"]}],
        },
    }
    packet_path = run_dir / "WORK_PACKET.md"
    packet_path.write_text("```json\n" + json.dumps(packet) + "\n```\n")
    packet_sha = util.sha256_file(packet_path)
    approval_doc = {
        "schema": "ownframework-loop-approval/v1",
        "run_id": "run-test",
        "packet_sha256": packet_sha,
        "approved_at": "2026-01-01T00:00:00Z",
        "approved_actor": "test",
        "canonical_repo": str(repo),
        "baseline_branch": "master",
        "baseline_sha": baseline,
        "packet_schema": "ownframework-work-packet/v3",
        "approval_method": "build_start",
        "confirmation_token": approval.derive_confirmation_token(packet_sha),
        "candidate_branch": "candidate",
    }
    approval_path = run_dir / "APPROVAL.json"
    approval_path.write_text(json.dumps(approval_doc))
    os.chmod(approval_path, 0o600)
    (run_dir / "EVENTS.log").write_text("")

    wt = repo / "builder"
    out(repo, "worktree", "add", "-q", str(wt), "candidate")
    current = {"program": {"checkpoints": [{
        "id": "CP-1",
        "checkpoint_entry_candidate_sha": baseline,
    }]}}
    recovered = protected_recovery.recover_candidate_only_protected_drift(
        canonical_repo=repo,
        run_id="run-test",
        packet=packet,
        current_state=current,
        checkpoint_id="CP-1",
        builder_worktree=wt,
        candidate_branch="candidate",
        candidate_sha=candidate,
        offending_paths=["docs/protected.md"],
    )
    assert recovered["result"] == "recovered"
    rollback = recovered["candidate_sha"]
    assert rollback != candidate
    assert out(wt, "show", "HEAD:docs/protected.md") == "approved"
    assert out(wt, "show", "HEAD:src/feature.py") == "candidate"
    receipt = Path(recovered["receipt_path"])
    assert stat.S_IMODE(receipt.stat().st_mode) == 0o600
    assert json.loads(receipt.read_text())["status"] == "complete"

    again = protected_recovery.recover_candidate_only_protected_drift(
        canonical_repo=repo,
        run_id="run-test",
        packet=packet,
        current_state=current,
        checkpoint_id="CP-1",
        builder_worktree=wt,
        candidate_branch="candidate",
        candidate_sha=candidate,
        offending_paths=["docs/protected.md"],
    )
    assert again["already_recovered"] is True

    # Simulate process death after the ref/worktree restore but before the
    # receipt is marked complete.  Restart must finish the same receipt and
    # never create a second rollback commit.
    prepared = json.loads(receipt.read_text())
    prepared["status"] = "prepared"
    prepared.pop("completed_at", None)
    util.atomic_write_json(receipt, prepared, mode=0o600)
    out(wt, "checkout", "--detach", "-q", candidate)
    resumed = protected_recovery.recover_candidate_only_protected_drift(
        canonical_repo=repo,
        run_id="run-test",
        packet=packet,
        current_state=current,
        checkpoint_id="CP-1",
        builder_worktree=wt,
        candidate_branch="candidate",
        candidate_sha=candidate,
        offending_paths=["docs/protected.md"],
    )
    assert resumed["already_recovered"] is True
    assert json.loads(receipt.read_text())["status"] == "complete"
    assert out(wt, "rev-parse", "HEAD") == rollback

    # If the process dies after the complete recovery receipt but before the
    # FSM transition, finalization must replay the same repair rather than
    # silently treating the safe tree as an approval.
    pending = protected_recovery.pending_completed_recovery(
        canonical_repo=repo,
        run_id="run-test",
        current_state={"state": "BUILDING"},
        checkpoint_id="CP-1",
        builder_worktree=wt,
        candidate_branch="candidate",
    )
    assert pending is not None
    assert pending["candidate_sha"] == rollback

    # A different protected payload under the same candidate identity cannot
    # be silently replaced after the completed operation.
    try:
        protected_recovery.recover_candidate_only_protected_drift(
            canonical_repo=repo,
            run_id="run-test",
            packet=packet,
            current_state=current,
            checkpoint_id="CP-1",
            builder_worktree=wt,
            candidate_branch="candidate",
            candidate_sha=candidate,
            offending_paths=["docs/other-protected.md"],
        )
    except protected_recovery.ProtectedDriftRecoveryError:
        pass
    else:
        raise AssertionError("unexpected protected path was accepted")

    # PROGRAM packets with packet-level UNIT-N entries bind the current CP to
    # its acceptance overlap rather than silently falling back to UNIT-1.
    packet["work_units"] = [
        {"id": "UNIT-1", "acceptance": ["AC-0"]},
        {"id": "UNIT-7", "acceptance": ["AC-1"]},
    ]
    assert program.current_checkpoint_work_unit_id(
        packet, {"current_checkpoints": ["CP-1"]}
    ) == "UNIT-7"

    # Exact prompt/work-order provenance is private and contains no provider
    # environment or credential fields.
    provenance_repo = repo / "provenance-repo"
    provenance_repo.mkdir()
    prov_run = provenance_repo / ".ownframework-loop" / "run-prov"
    prov_run.mkdir(parents=True)
    order = {
        "canonical_repo": str(provenance_repo),
        "run_id": "run-prov",
        "attempt_id": "attempt-1",
        "role": "builder",
        "decision": "BUILD",
        "checkpoint_id": "CP-1",
        "work_unit_id": "UNIT-7",
        "packet_sha256": "a" * 64,
        "approval_sha256": "b" * 64,
        "protected_paths": ["docs/protected.md"],
    }
    prompt = "sealed prompt with checkpoint authority"
    path = supervisor._write_semantic_prompt_provenance(
        work_order=order,
        effective_work_order=order,
        prompt=prompt,
        role_contract="role contract",
    )
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    saved = json.loads(path.read_text())
    assert saved["prompt"] == prompt
    assert saved["work_order"]["protected_paths"] == ["docs/protected.md"]
    assert "token" not in json.dumps(saved).lower()
    assert "credential" not in json.dumps(saved).lower()

    # Exercise the authoritative BUILD finalizer, not only the Git recovery
    # primitive: a protected-only candidate is restored, receives one funded
    # repair, and remains out of REVIEW for this pass.
    finalizer_repo = repo / "finalizer-repo"
    finalizer_repo.mkdir()
    run(finalizer_repo, "init", "-q")
    out(finalizer_repo, "config", "user.name", "test")
    out(finalizer_repo, "config", "user.email", "test@example.invalid")
    (finalizer_repo / "README.md").write_text("baseline\n")
    out(finalizer_repo, "add", ".")
    out(finalizer_repo, "commit", "-qm", "baseline")
    ofloop = str(Path(os.environ["OFLOOP_ROOT"]) / "bin" / "ofloop")
    subprocess.run([ofloop, "spec", "new", str(finalizer_repo), "protected-drift-finalizer"],
                   check=True, capture_output=True, text=True)
    run_id = sorted((finalizer_repo / ".ownframework-loop").iterdir())[-1].name
    packet2 = {
        "schema": "ownframework-work-packet/v3",
        "packet_id": "protected-drift-finalizer",
        "created_at": "2026-01-01T00:00:00Z",
        "work_class": "HARDENING",
        "risk_class": "low",
        "title": "protected drift finalizer",
        "target": {"repo": str(finalizer_repo), "branch": "master", "classification": "local_only"},
        "execution_mode": "program",
        "checkpoint_graph": {"execution_order": ["CP-1"], "checkpoints": [{
            "id": "CP-1", "title": "protected drift", "scope": "recovery",
            "depends_on": [], "acceptance_criterion_ids": ["AC-1"],
            "risk_budget": {"max_build_passes": 3, "max_review_passes": 3, "max_repair_rounds": 2},
        }]},
        "promotion_policy": "human_gate",
        "acceptance_criteria": [{"id": "AC-1", "text": "repair protected drift"}],
        "non_goals": [], "network_read_allowlist": [],
        "allowed_paths": ["src/"], "protected_paths": [".ownframework-loop/"],
        "work_units": [{"id": "UNIT-1", "title": "unit", "scope": "src/"}],
        "merge_authority": "human_only", "deploy_authority": "human_only",
        "push_authority": "human_only", "external_action_authority": "none",
        "risk_budget": {"max_build_passes": 3, "max_review_passes": 3,
                         "max_repair_rounds": 2, "max_files_changed": 10,
                         "max_diff_lines": 500},
    }
    packet2_path = finalizer_repo / ".ownframework-loop" / run_id / "WORK_PACKET.md"
    packet2_path.write_text("```json\n" + json.dumps(packet2, sort_keys=True) + "\n```\n")
    claim_result = subprocess.run(
        [ofloop, "dispatch", "claim", str(finalizer_repo), run_id],
        check=False, capture_output=True, text=True,
    )
    if claim_result.returncode != 0:
        raise AssertionError(claim_result.stdout + claim_result.stderr)
    claim = json.loads(claim_result.stdout)
    builder = Path(claim["worktree"])
    (builder / ".ownframework-loop" / "candidate-only.md").parent.mkdir(parents=True, exist_ok=True)
    (builder / ".ownframework-loop" / "candidate-only.md").write_text("discard me\n")
    out(builder, "add", "-f", ".ownframework-loop/candidate-only.md")
    out(builder, "commit", "-qm", "synthetic protected drift")
    semantic = Path(claim["semantic_path"])
    result = json.loads(semantic.read_text())
    result.update({
        "summary": "synthetic protected drift",
        "outcome_requested": "candidate_ready",
        "unit_ids_completed": ["UNIT-1"],
        "acceptance_addressed": ["AC-1"],
    })
    semantic.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    subprocess.run([
        ofloop, "dispatch", "finalize", str(finalizer_repo), run_id, "BUILD", str(semantic),
    ], check=True, capture_output=True, text=True)
    final_state = json.loads((finalizer_repo / ".ownframework-loop" / run_id / "STATE.json").read_text())
    assert final_state["state"] == "CHANGES_REQUESTED"
    assert final_state["build_pass_count"] == 1
    assert final_state["repair_round"] == 1
    assert out(builder, "status", "--porcelain") == ""
    assert not (builder / ".ownframework-loop" / "candidate-only.md").exists()
    receipt = json.loads((finalizer_repo / ".ownframework-loop" / run_id / "BUILD_RECEIPT.json").read_text())
    assert receipt["protected_drift_recovery"]["result"] == "recovered"
    assert receipt["next_state"] == "CHANGES_REQUESTED"

print("PROTECTED_DRIFT_RECOVERY=PASS")
print("PROTECTED_DRIFT_RESTART_IDEMPOTENCE=PASS")
print("PROTECTED_DRIFT_CRASH_BOUNDARIES=PASS")
print("PROTECTED_DRIFT_COLLISION_FAILS_CLOSED=PASS")
print("PROGRAM_WORK_UNIT_BINDING=PASS")
print("SEMANTIC_PROMPT_PROVENANCE=PASS")
print("BUILD_FINALIZER_PROTECTED_DRIFT_REPAIR=PASS")
PY
