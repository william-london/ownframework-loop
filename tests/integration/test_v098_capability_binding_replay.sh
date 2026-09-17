#!/usr/bin/env bash
# v0.9.8 real supervisor zero-cost replay after explicit capability migration.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PYTHONPATH="$ROOT/lib${PYTHONPATH:+:$PYTHONPATH}"

python3 -B - <<'PY'
import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path

from ownframework_loop import approval, capabilities, capability_binding, runner_profiles, state, supervisor


def git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(repo), *args], check=True, capture_output=True, text=True
    ).stdout.strip()


with tempfile.TemporaryDirectory(prefix="ofloop-v098-replay-") as td:
    root = Path(td)
    os.environ["XDG_STATE_HOME"] = str(root / "state")
    tool_a = root / "tool-a"
    tool_b = root / "tool-b"
    tool_a.write_text("#!/bin/sh\nprintf A\\n\n", encoding="utf-8")
    tool_b.write_text("#!/bin/sh\nprintf B\\n\n", encoding="utf-8")
    tool_a.chmod(0o700)
    tool_b.chmod(0o700)
    manifest_path = root / "state" / "ownframework-loop" / "host-capabilities.json"
    manifest_path.parent.mkdir(parents=True)

    def write_manifest(tool: Path) -> None:
        manifest_path.write_text(json.dumps({
            "schema": capabilities.HOST_MANIFEST_SCHEMA,
            "capabilities": {
                "toolchain.synthetic": {
                    "kind": "tool", "executable": str(tool), "version_args": [],
                }
            },
        }), encoding="utf-8")
        manifest_path.chmod(0o600)

    repo = root / "repo"
    repo.mkdir()
    subprocess.run(["git", "-C", str(repo), "init", "-q", "--initial-branch=main"], check=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.email", "test@ofloop"], check=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.name", "OwnFramework Test"], check=True)
    (repo / "README.md").write_text("fixture\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(repo), "add", "README.md"], check=True)
    subprocess.run(["git", "-C", str(repo), "commit", "-qm", "fixture"], check=True)

    run_id = "run-replay-after-migration"
    run_dir = repo / ".ownframework-loop" / run_id
    run_dir.mkdir(parents=True)
    packet = {
        "schema": "ownframework-work-packet/v3",
        "packet_id": "packet-replay-after-migration",
        "created_at": "2026-09-16T00:00:00Z",
        "work_class": "HARDENING", "risk_class": "low",
        "title": "capability replay fixture",
        "target": {"repo": str(repo.resolve()), "branch": "main", "classification": "local_only"},
        "execution_mode": "single",
        "capabilities": ["toolchain.synthetic"], "runner_profile": "default",
        "acceptance_criteria": [{"id": "AC-1", "text": "fixture"}],
        "non_goals": [], "allowed_paths": ["src/"],
        "protected_paths": [".ownframework-loop/"],
        "work_units": [{"id": "UNIT-1", "title": "fixture", "scope": "src/"}],
        "merge_authority": "human_only", "deploy_authority": "human_only",
        "push_authority": "human_only", "external_action_authority": "none",
    }
    packet_path = run_dir / "WORK_PACKET.md"
    packet_path.write_text("```json\n" + json.dumps(packet, sort_keys=True) + "\n```\n", encoding="utf-8")
    packet_sha = hashlib.sha256(packet_path.read_bytes()).hexdigest()
    approval_path = run_dir / "APPROVAL.json"
    approval_path.write_text(json.dumps({
        "schema": "ownframework-loop-approval/v1", "run_id": run_id,
        "packet_sha256": packet_sha, "approved_at": "2026-09-16T00:00:00Z",
        "approved_actor": "test", "canonical_repo": str(repo.resolve()),
        "baseline_branch": "main", "baseline_sha": git(repo, "rev-parse", "HEAD"),
        "candidate_branch": "factory/candidate/" + run_id,
        "packet_schema": "ownframework-work-packet/v3",
        "approval_method": "tty_confirmation",
        "confirmation_token": approval.derive_confirmation_token(packet_sha),
    }, sort_keys=True), encoding="utf-8")
    approval_path.chmod(0o600)
    state.save(repo, run_id, state.initial_state(run_id))
    state.transition(repo, run_id, to_state="READY_TO_BUILD", actor="test", reason="fixture approved")
    candidate_sha = git(repo, "rev-parse", "HEAD")
    state.transition(
        repo, run_id, to_state="BUILDING", actor="test", reason="fixture build claimed",
        commit_sha=candidate_sha,
    )

    def resolve() -> dict:
        return capabilities.resolve_capabilities(
            ["toolchain.synthetic"], canonical_repo=repo, role="builder",
            repo_cache_root=repo / ".cache", ephemeral_cache_root=repo / ".ephemeral",
        )

    profile = runner_profiles.resolve_profile("default", provider="claude-code")
    write_manifest(tool_a)
    old_resolution = resolve()
    old_binding = capability_binding.ensure_run_binding(
        repo, run_id, old_resolution, profile, allow_create=True
    )
    db = root / "supervisor.sqlite3"

    calls = {"runner": 0}

    @supervisor.register_runner
    class ReplayRunner:
        runner_id = "claude-code"
        requires_capability_receipt = True

        def preflight(self):
            return supervisor.RunnerReadiness(True)

        def run(self, work_order, **kwargs):
            calls["runner"] += 1
            role = str(work_order["role"])
            current_resolution = capabilities.resolve_capabilities(
                ["toolchain.synthetic"], canonical_repo=repo, role=role,
                repo_cache_root=repo / ".cache", ephemeral_cache_root=repo / ".ephemeral",
            )
            binding = capability_binding.verify_run_binding(repo, run_id, current_resolution, profile)
            capabilities.write_resolution_receipt(
                repo, run_id, role, str(work_order["attempt_id"]), current_resolution,
                run_binding=binding, runner_profile=profile,
            )
            Path(work_order["semantic_path"]).write_text("{\"ready\":true}\n", encoding="utf-8")
            return supervisor.RunnerResult(
                ok=True, returncode=0, cost_usd=2.0, stdout="ok", stderr="",
                input_tokens=11, output_tokens=7, cache_read_tokens=3,
                tokens_known=True, cost_known=True, effective_model=profile["model"],
            )

    # The packet was already written by packet_and_approval(repo, run_id)
    # and keyed to an APPROVAL.json whose packet_sha256 is the SHA of that
    # packet. Do NOT call write_minimal_valid_packet here — it would rewrite
    # the packet with a different SHA and break the resume SHA-drift check.
    enrolled = supervisor.enqueue(
        canonical_repo=repo, run_id=run_id, db_path=db,
        runner=ReplayRunner.runner_id, max_infra_failures=1,
        runtime_generation=supervisor._current_runtime_generation(),
    )
    assert enrolled["ok"], enrolled

    phase = {"name": "builder_initial", "ready_calls": 0}
    semantic_paths = {
        "builder": str(run_dir / "BUILD_AGENT_RESULT.json"),
        "reviewer": str(run_dir / "REVIEW_AGENT_RESULT.json"),
    }
    work_orders = {}
    for role in ("builder", "reviewer"):
        work_orders[role] = {
            "decision": "BUILD" if role == "builder" else "REVIEW",
            "role": role, "canonical_repo": str(repo), "run_id": run_id,
            "worktree": str(repo), "semantic_path": semantic_paths[role],
            "capabilities": ["toolchain.synthetic"], "runner_profile": "default",
            "network_read_allowlist": [],
        }

    real_claim = supervisor.dispatch_mod.claim_next
    real_ready = supervisor.dispatch_mod.semantic_result_ready
    real_finalize = supervisor.dispatch_mod.finalize_work_order
    real_runner = supervisor._RUNNER_REGISTRY.get("claude-code")
    try:
        supervisor.dispatch_mod.claim_next = lambda **kwargs: dict(work_orders[
            "builder" if phase["name"] != "review" else "reviewer"
        ])

        def readiness(_work_order):
            phase["ready_calls"] += 1
            if phase["name"] == "builder_initial" and phase["ready_calls"] == 1:
                return False, "synthetic-not-ready-before-provider"
            if phase["name"] == "review" and phase["ready_calls"] == 1:
                return False, "synthetic-review-not-ready-before-provider"
            return True, "ready"

        supervisor.dispatch_mod.semantic_result_ready = readiness
        supervisor.dispatch_mod.finalize_work_order = lambda _wo, **kwargs: (_ for _ in ()).throw(
            RuntimeError("synthetic deterministic finalization interrupted")
        ) if phase["name"] == "builder_initial" else {"finalized": True}

        first = supervisor.run_one(db_path=db)
        assert first["ok"] is False and first["action"] == "QUARANTINED", first
        assert calls["runner"] == 1, calls
        with supervisor._connect_readonly(db) as conn:
            job = conn.execute("SELECT * FROM jobs WHERE run_id=?", (run_id,)).fetchone()
            attempt = conn.execute(
                "SELECT * FROM semantic_attempts WHERE attempt_id=?", (job["latest_attempt_id"],)
            ).fetchone()
        assert int(attempt["semantic_accepted"]) == 1, dict(attempt)
        assert abs(float(job["total_cost_usd"]) - 2.0) < 1e-9, dict(job)

        # Trusted environment B; explicit public rebind + resume only.
        write_manifest(tool_b)
        resumed = supervisor.resume(
            canonical_repo=repo, run_id=run_id, db_path=db, rebind_capabilities=True
        )
        assert resumed["resumed"] is True and resumed["status"] == "QUEUED", resumed
        new_binding = capability_binding._read(capability_binding.binding_path(repo, run_id))
        assert new_binding["binding_sha256"] != old_binding["binding_sha256"]
        try:
            capabilities.read_resolution_receipt(repo, run_id, "builder", attempt["attempt_id"])
        except capabilities.CapabilityResolutionError:
            pass
        else:
            raise AssertionError("old receipt authorized ordinary current-binding work")

        phase["name"] = "replay"
        phase["ready_calls"] = 0
        replay = supervisor.run_one(db_path=db)
        assert replay["ok"] is True and replay["action"] == "BUILD_REPLAY_FINALIZED", replay
        assert replay["semantic_replay"] is True
        assert calls["runner"] == 1, calls
        with supervisor._connect_readonly(db) as conn:
            job_after_replay = conn.execute("SELECT * FROM jobs WHERE run_id=?", (run_id,)).fetchone()
            attempts = conn.execute("SELECT * FROM semantic_attempts WHERE job_id=?", (job_after_replay["id"],)).fetchall()
        assert len(attempts) == 1, attempts
        assert abs(float(job_after_replay["total_cost_usd"]) - 2.0) < 1e-9
        assert int(job_after_replay["total_input_tokens"]) == 11
        assert int(job_after_replay["total_output_tokens"]) == 7
        assert int(job_after_replay["total_cache_read_tokens"]) == 3

        # A fresh REVIEW provider call must write a new receipt under B.
        phase["name"] = "review"
        phase["ready_calls"] = 0
        review = supervisor.run_one(db_path=db)
        assert review["ok"] is True and review["action"] == "REVIEW", review
        assert calls["runner"] == 2, calls
        with supervisor._connect_readonly(db) as conn:
            rows = conn.execute(
                "SELECT attempt_id, role FROM semantic_attempts WHERE job_id=? ORDER BY started_at",
                (job_after_replay["id"],),
            ).fetchall()
        reviewer_attempt = next(row["attempt_id"] for row in rows if row["role"] == "reviewer")
        reviewer_receipt = capabilities.read_resolution_receipt(
            repo, run_id, "reviewer", reviewer_attempt
        )
        assert reviewer_receipt["run_binding_sha256"] == new_binding["binding_sha256"]
        assert reviewer_receipt["run_binding_sha256"] != old_binding["binding_sha256"]
    finally:
        supervisor.dispatch_mod.claim_next = real_claim
        supervisor.dispatch_mod.semantic_result_ready = real_ready
        supervisor.dispatch_mod.finalize_work_order = real_finalize
        if real_runner is not None:
            supervisor._RUNNER_REGISTRY["claude-code"] = real_runner

print("OF_LOOP_V098_CAPABILITY_BINDING_REPLAY=PASS")
PY
