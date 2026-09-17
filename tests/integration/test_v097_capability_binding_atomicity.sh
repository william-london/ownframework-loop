#!/usr/bin/env bash
# v0.9.7 capability migration atomicity, lifecycle serialization, and the
# supported supervisor rebind path.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PYTHONPATH="$ROOT/lib${PYTHONPATH:+:$PYTHONPATH}"

python3 -B - <<'PY'
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from ownframework_loop import approval, capabilities, capability_binding, runner_profiles, state, supervisor


ROOT = Path(os.environ["PYTHONPATH"].split(":", 1)[0]).parent
PROFILE = runner_profiles.resolve_profile("default", provider="claude-code")


def git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(repo), *args], check=True, capture_output=True, text=True
    ).stdout.strip()


def make_repo(root: Path, name: str) -> Path:
    repo = root / name
    repo.mkdir()
    subprocess.run(["git", "-C", str(repo), "init", "-q", "--initial-branch=main"], check=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.email", "test@ofloop"], check=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.name", "OwnFramework Test"], check=True)
    (repo / "README.md").write_text("fixture\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(repo), "add", "README.md"], check=True)
    subprocess.run(["git", "-C", str(repo), "commit", "-qm", "fixture"], check=True)
    return repo


def manifest(state_root: Path, executable: Path) -> None:
    path = state_root / "ownframework-loop" / "host-capabilities.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({
        "schema": capabilities.HOST_MANIFEST_SCHEMA,
        "capabilities": {
            "toolchain.synthetic": {
                "kind": "tool",
                "executable": str(executable),
                "version_args": [],
            }
        },
    }), encoding="utf-8")
    path.chmod(0o600)


def resolve(repo: Path, run_id: str) -> dict:
    return capabilities.resolve_capabilities(
        ["toolchain.synthetic"],
        canonical_repo=repo,
        role="reviewer",
        repo_cache_root=Path(repo) / ".cache",
        ephemeral_cache_root=Path(repo) / ".ephemeral",
    )


def expect_error(fn, text: str) -> None:
    try:
        fn()
    except Exception as exc:
        assert text in str(exc), (text, exc)
        return
    raise AssertionError(f"expected failure: {text}")


def packet_and_approval(repo: Path, run_id: str) -> None:
    run_dir = repo / ".ownframework-loop" / run_id
    run_dir.mkdir(parents=True)
    packet = {
        "schema": "ownframework-work-packet/v3",
        "packet_id": "packet-" + run_id,
        "created_at": "2026-09-16T00:00:00Z",
        "work_class": "HARDENING",
        "risk_class": "low",
        "title": "capability migration fixture",
        "target": {"repo": str(repo.resolve()), "branch": "main", "classification": "local_only"},
        "execution_mode": "single",
        "capabilities": ["toolchain.synthetic"],
        "runner_profile": "default",
        "acceptance_criteria": [{"id": "AC-1", "text": "fixture"}],
        "non_goals": [],
        "allowed_paths": ["src/"],
        "protected_paths": [".ownframework-loop/"],
        "work_units": [{"id": "UNIT-1", "title": "fixture", "scope": "src/"}],
        "merge_authority": "human_only",
        "deploy_authority": "human_only",
        "push_authority": "human_only",
        "external_action_authority": "none",
    }
    packet_path = run_dir / "WORK_PACKET.md"
    packet_path.write_text("```json\n" + json.dumps(packet, sort_keys=True) + "\n```\n", encoding="utf-8")
    packet_sha = hashlib.sha256(packet_path.read_bytes()).hexdigest()
    approval_path = run_dir / "APPROVAL.json"
    approval_path.write_text(json.dumps({
        "schema": "ownframework-loop-approval/v1",
        "run_id": run_id,
        "packet_sha256": packet_sha,
        "approved_at": "2026-09-16T00:00:00Z",
        "approved_actor": "test",
        "canonical_repo": str(repo.resolve()),
        "baseline_branch": "main",
        "baseline_sha": git(repo, "rev-parse", "HEAD"),
        "candidate_branch": "factory/candidate/" + run_id,
        "packet_schema": "ownframework-work-packet/v3",
        "approval_method": "tty_confirmation",
        "confirmation_token": approval.derive_confirmation_token(packet_sha),
    }, sort_keys=True), encoding="utf-8")
    approval_path.chmod(0o600)
    state.save(repo, run_id, state.initial_state(run_id))
    state.transition(repo, run_id, to_state="READY_TO_BUILD", actor="test", reason="fixture approved")


def make_quarantined(root: Path, label: str, old_resolution: dict) -> tuple[Path, str, Path, dict]:
    repo = make_repo(root, "repo-" + label)
    run_id = "run-" + label
    packet_and_approval(repo, run_id)
    old = capability_binding.ensure_run_binding(
        repo, run_id, old_resolution, PROFILE, allow_create=True
    )
    db = root / (label + ".sqlite3")
    supervisor.write_minimal_valid_packet(repo, run_id)
    enrolled = supervisor.enqueue(
        canonical_repo=repo,
        run_id=run_id,
        db_path=db,
        runner="claude-code",
        runtime_generation=supervisor._current_runtime_generation(),
    )
    assert enrolled["ok"], enrolled
    with supervisor._connect(db) as conn:
        conn.execute(
            "UPDATE jobs SET status='QUARANTINED', last_error='synthetic drift' "
            "WHERE repo=? AND run_id=?",
            (str(repo.resolve()), run_id),
        )
    return repo, run_id, db, old


with tempfile.TemporaryDirectory(prefix="ofloop-v097-atomicity-") as td:
    root = Path(td)
    state_root = root / "state"
    os.environ["XDG_STATE_HOME"] = str(state_root)
    tool_a = root / "tool-a"
    tool_b = root / "tool-b"
    tool_a.write_text("#!/bin/sh\nprintf A\\n\n", encoding="utf-8")
    tool_b.write_text("#!/bin/sh\nprintf B\\n\n", encoding="utf-8")
    tool_a.chmod(0o700)
    tool_b.chmod(0o700)

    # Every pre-record crash point leaves no manual cleanup burden.  The
    # retry validates whatever durable prefix exists and completes one chain.
    for stage in (
        "directory_created",
        "previous_snapshot_published",
        "new_snapshot_published",
        "before_record_published",
    ):
        repo = make_repo(root, "partial-" + stage)
        run_id = "run-partial-" + stage.replace("_", "-")
        (repo / ".ownframework-loop" / run_id).mkdir(parents=True)
        manifest(state_root, tool_a)
        old_resolution = resolve(repo, run_id)
        capability_binding.ensure_run_binding(repo, run_id, old_resolution, PROFILE, allow_create=True)
        manifest(state_root, tool_b)
        new_resolution = resolve(repo, run_id)
        original_hook = capability_binding._migration_fault_hook
        capability_binding._migration_fault_hook = lambda current, wanted=stage: (
            (_ for _ in ()).throw(RuntimeError("synthetic migration crash"))
            if current == wanted else None
        )
        try:
            expect_error(
                lambda: capability_binding.migrate_run_binding(
                    repo, run_id, new_resolution, PROFILE, reason="test", actor="test"
                ),
                "synthetic migration crash",
            )
        finally:
            capability_binding._migration_fault_hook = original_hook
        recovered = capability_binding.migrate_run_binding(
            repo, run_id, new_resolution, PROFILE, reason="test", actor="test"
        )
        assert recovered["status"] == "COMPLETE" and recovered["idempotent"] is True, recovered
        history = capability_binding.migration_root(repo, run_id)
        records = list(history.glob("*/RECORD.json"))
        assert len(records) == 1, records
        expected_new = hashlib.sha256(
            capability_binding._canonical(
                capability_binding.stable_projection(new_resolution, PROFILE)
            )
        ).hexdigest()
        assert capability_binding._read(capability_binding.binding_path(repo, run_id))["binding_sha256"] == expected_new
        for snapshot in records[0].parent.glob("*.json"):
            assert snapshot.stat().st_mode & 0o077 == 0, snapshot

    # Contradictory partial evidence fails closed rather than being laundered.
    repo = make_repo(root, "partial-contradiction")
    run_id = "run-contradiction"
    rd = repo / ".ownframework-loop" / run_id
    rd.mkdir(parents=True)
    manifest(state_root, tool_a)
    old_resolution = resolve(repo, run_id)
    old = capability_binding.ensure_run_binding(repo, run_id, old_resolution, PROFILE, allow_create=True)
    manifest(state_root, tool_b)
    new_resolution = resolve(repo, run_id)
    original_hook = capability_binding._migration_fault_hook
    capability_binding._migration_fault_hook = lambda stage: (
        (_ for _ in ()).throw(RuntimeError("stop after previous"))
        if stage == "previous_snapshot_published" else None
    )
    try:
        expect_error(
            lambda: capability_binding.migrate_run_binding(repo, run_id, new_resolution, PROFILE, reason="x", actor="x"),
            "stop after previous",
        )
    finally:
        capability_binding._migration_fault_hook = original_hook
    partial_dir = next(capability_binding.migration_root(repo, run_id).iterdir())
    capability_binding._atomic_replace_json(partial_dir / "PREVIOUS_BINDING.json", old)
    capability_binding._atomic_replace_json(partial_dir / "UNEXPECTED.json", {"x": 1})
    expect_error(
        lambda: capability_binding.migrate_run_binding(repo, run_id, new_resolution, PROFILE, reason="x", actor="x"),
        "unexpected file",
    )

    # Real public supervisor recovery: QUARANTINED -> QUEUED, one migration,
    # unchanged engineering/accounting truth, and no silent ordinary rebind.
    manifest(state_root, tool_a)
    old_resolution = resolve(root, "not-a-run")
    manifest(state_root, tool_b)
    new_resolution = resolve(root, "not-a-run")
    repo, run_id, db, old = make_quarantined(root, "public-resume", old_resolution)
    before_state = state.load_verified(repo, run_id)
    with supervisor._connect_readonly(db) as conn:
        before_job = conn.execute("SELECT * FROM jobs WHERE run_id=?", (run_id,)).fetchone()
    result = supervisor.resume(canonical_repo=repo, run_id=run_id, db_path=db, rebind_capabilities=True)
    assert result["resumed"] is True and result["status"] == "QUEUED", result
    assert result["capability_migration"]["status"] == "COMPLETE", result
    assert capability_binding._read(capability_binding.binding_path(repo, run_id))["binding_sha256"] != old["binding_sha256"]
    after_state = state.load_verified(repo, run_id)
    assert after_state["build_pass_count"] == before_state["build_pass_count"]
    assert after_state["review_pass_count"] == before_state["review_pass_count"]
    assert after_state["repair_round"] == before_state["repair_round"]
    with supervisor._connect_readonly(db) as conn:
        after_job = conn.execute("SELECT * FROM jobs WHERE run_id=?", (run_id,)).fetchone()
    for field in ("total_cost_usd", "total_input_tokens", "total_output_tokens", "total_cache_read_tokens"):
        assert after_job[field] == before_job[field], field
    history_count = len(list(capability_binding.migration_root(repo, run_id).glob("*/RECORD.json")))
    with supervisor._connect(db) as conn:
        conn.execute("UPDATE jobs SET status='QUARANTINED' WHERE run_id=?", (run_id,))
    ordinary = supervisor.resume(canonical_repo=repo, run_id=run_id, db_path=db)
    assert ordinary["resumed"] is True and ordinary["status"] == "QUEUED", ordinary
    assert len(list(capability_binding.migration_root(repo, run_id).glob("*/RECORD.json"))) == history_count

    # Each supported competing lifecycle operation blocks behind the same
    # process-level lock, then re-evaluates the post-resume QUEUED row.
    child_code = r'''
import json, sys
from pathlib import Path
from ownframework_loop import supervisor
repo, run_id, db, op = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3]), sys.argv[4]
if op == "retire":
    out = supervisor.retire(canonical_repo=repo, run_id=run_id, db_path=db)
elif op == "resume":
    out = supervisor.resume(canonical_repo=repo, run_id=run_id, db_path=db)
else:
    out = supervisor.resume(canonical_repo=repo, run_id=run_id, db_path=db, rebind_capabilities=True)
print(json.dumps(out, sort_keys=True))
'''
    real_migrate = supervisor._migrate_quarantined_run_capabilities
    for op, expected_fragment in (("resume", "resume_requires_quarantined"), ("retire", "retire_requires_quarantined"), ("rebind", "resume_requires_quarantined")):
        manifest(state_root, tool_a)
        old_resolution = resolve(root, "not-a-run-" + op)
        manifest(state_root, tool_b)
        new_resolution = resolve(root, "not-a-run-" + op)
        race_repo, race_run, race_db, _ = make_quarantined(root, "race-" + op, old_resolution)
        entered = threading.Event()
        release = threading.Event()
        result_box = []
        def paused(**kwargs):
            entered.set()
            assert release.wait(10)
            return real_migrate(**kwargs)
        supervisor._migrate_quarantined_run_capabilities = paused
        primary = threading.Thread(
            target=lambda: result_box.append(
                supervisor.resume(canonical_repo=race_repo, run_id=race_run, db_path=race_db, rebind_capabilities=True)
            ),
            daemon=True,
        )
        primary.start()
        assert entered.wait(10), op
        child = subprocess.Popen(
            [sys.executable, "-c", child_code, str(race_repo), race_run, str(race_db), op],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env={**os.environ, "PYTHONPATH": str(ROOT / "lib")},
        )
        time.sleep(0.25)
        assert child.poll() is None, (op, child.poll())
        release.set()
        primary.join(15)
        stdout, stderr = child.communicate(timeout=15)
        supervisor._migrate_quarantined_run_capabilities = real_migrate
        assert result_box and result_box[0]["resumed"] is True, result_box
        child_result = json.loads(stdout)
        if op == "retire":
            assert child_result["retired"] is False, child_result
        else:
            assert child_result["resumed"] is False, child_result
        assert expected_fragment in child_result["reason"], (op, child_result, stderr)
        with supervisor._connect_readonly(race_db) as conn:
            row = conn.execute("SELECT status FROM jobs WHERE run_id=?", (race_run,)).fetchone()
        assert row["status"] == "QUEUED", row

print("OF_LOOP_V097_CAPABILITY_BINDING_ATOMICITY=PASS")
PY
