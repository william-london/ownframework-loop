#!/usr/bin/env bash
# v0.9.6 capability-binding migration and preserved semantic provenance.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONDONTWRITEBYTECODE=1

python3 -B - <<'PY'
import json
import os
import tempfile
from pathlib import Path

from ownframework_loop import capabilities, capability_binding, supervisor


def resolution(version: str, *, browser: bool = False, requested=None):
    requested = requested or (["browser.playwright.chromium"] if browser else ["toolchain.synthetic"])
    resolved = []
    for name in requested:
        if name == "browser.playwright.chromium":
            resolved.append({
                "name": name,
                "kind": "browser",
                "provider": "builtin",
                "version": version,
                "network_domains": [],
                "browser": {
                    "runtime_proven": True,
                    "browser_asset_root": "/trusted/chromium",
                    "browser_asset_merkle_sha256": "asset-" + version,
                    "browser_proof_sha256": "proof-" + version,
                    "proof_schema": "ownframework-loop-browser-runtime-proof/v4",
                    "browser_version": "chromium-" + version,
                    "playwright_client_identity": {
                        "distribution_version": version,
                        "package_root": "/trusted/playwright",
                        "package_tree_sha256": "tree-" + version,
                    },
                },
            })
        else:
            resolved.append({
                "name": name,
                "kind": "tool",
                "provider": "builtin",
                "version": version,
                "network_domains": [],
            })
    return {
        "capability_contract_revision": "host-capability-contract/v2",
        "requested": list(requested),
        "host_manifest_sha256": "manifest-" + version,
        "semantic_runtime_fingerprint": "runtime-" + version,
        "platform_identity": {"platform": "test", "release": version},
        "resolved": resolved,
        "network_domains": [],
        "stable_filesystem": {"allowRead": [], "allowWrite": []},
        "sandbox_network": {},
    }


PROFILE = {
    "name": "primary",
    "provider": "test",
    "model": "model",
    "effort": "high",
    "identity_sha256": "profile-a",
}


def expect_refusal(fn, label):
    try:
        fn()
    except Exception:
        return
    raise AssertionError(label)


with tempfile.TemporaryDirectory(prefix="ofloop-v096-migration-") as td:
    root = Path(td)
    repo = root / "repo"
    run_id = "run-migration"
    run_dir = repo / ".ownframework-loop" / run_id
    run_dir.mkdir(parents=True)

    # A normal sealed binding still rejects drift before migration.
    old_resolution = resolution("A")
    new_resolution = resolution("B")
    old = capability_binding.ensure_run_binding(
        repo, run_id, old_resolution, PROFILE, allow_create=True
    )
    expect_refusal(
        lambda: capability_binding.verify_run_binding(repo, run_id, new_resolution, PROFILE),
        "ordinary execution silently accepted capability drift",
    )

    # Migration is explicit, records complete old/new authority, and is
    # idempotent. A second legitimate migration forms a chain.
    first = capability_binding.migrate_run_binding(
        repo, run_id, new_resolution, PROFILE,
        reason="synthetic trusted drift recovery", actor="test-operator",
        context={"engineering_state": "BUILDING", "checkpoint": "CP-7", "supervisor_job_id": 7},
        requested_capabilities=["toolchain.synthetic"],
    )
    assert first["status"] == "COMPLETE" and first["idempotent"] is False, first
    assert first["previous_binding_sha256"] == old["binding_sha256"], first
    assert first["new_binding_sha256"] != old["binding_sha256"], first
    history = capability_binding.migration_root(repo, run_id)
    assert len(list(history.glob("*/RECORD.json"))) == 1
    assert capability_binding.historical_binding(repo, run_id, old["binding_sha256"])["binding_sha256"] == old["binding_sha256"]
    again = capability_binding.migrate_run_binding(
        repo, run_id, new_resolution, PROFILE,
        reason="synthetic trusted drift recovery", actor="test-operator",
    )
    assert again["idempotent"] is True, again
    second = capability_binding.migrate_run_binding(
        repo, run_id, resolution("C"), PROFILE,
        reason="second synthetic trusted drift", actor="test-operator",
    )
    assert second["status"] == "COMPLETE", second
    assert second["prior_migration_record_sha256"] == first["migration_record_sha256"], second
    assert len(list(history.glob("*/RECORD.json"))) == 2

    # A valid accepted receipt remains tied to A, while current execution
    # authority is C. Strict current reads reject it; replay-authorized reads
    # accept it only through the verified migration history.
    receipt = dict(old_resolution)
    receipt.update({
        "run_id": run_id,
        "role": "builder",
        "attempt_id": "attempt-old-binding",
        "requested_runner_profile": PROFILE,
        "run_binding_sha256": old["binding_sha256"],
    })
    receipt_path = capabilities.resolution_receipt_path(
        repo, run_id, "builder", "attempt-old-binding"
    )
    receipt_path.parent.mkdir(parents=True)
    receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
    receipt_path.chmod(0o600)
    expect_refusal(
        lambda: capabilities.read_resolution_receipt(
            repo, run_id, "builder", "attempt-old-binding"
        ),
        "old receipt accepted by ordinary current-binding read",
    )
    accepted = capabilities.read_resolution_receipt(
        repo, run_id, "builder", "attempt-old-binding",
        allow_historical_binding=True,
    )
    assert accepted["run_binding_sha256"] == old["binding_sha256"]
    assert capability_binding.verify_run_binding(
        repo, run_id, resolution("C"), PROFILE
    )["binding_sha256"] == second["new_binding_sha256"]

    # A manually replaced active file with no migration history is not
    # accepted as an implicit migration.
    repo_manual = root / "repo-manual"
    (repo_manual / ".ownframework-loop" / "run-x").mkdir(parents=True)
    capability_binding.ensure_run_binding(repo_manual, "run-x", resolution("A"), PROFILE, allow_create=True)
    manual_doc = {
        "schema": capability_binding.SCHEMA,
        "run_id": "run-x",
        "projection": capability_binding.stable_projection(resolution("B"), PROFILE),
    }
    manual_doc["binding_sha256"] = __import__("hashlib").sha256(
        capability_binding._canonical(manual_doc["projection"])
    ).hexdigest()
    capability_binding._atomic_replace_json(
        capability_binding.binding_path(repo_manual, "run-x"), manual_doc
    )
    expect_refusal(
        lambda: capability_binding.migrate_run_binding(
            repo_manual, "run-x", resolution("B"), PROFILE, reason="manual", actor="test",
        ),
        "manual active binding replacement was accepted",
    )

    # Browser proof is mandatory for a new binding; a stale/unproven result is
    # refused even when its shape is otherwise valid.
    stale = resolution("stale", browser=True)
    stale["resolved"][0]["browser"]["runtime_proven"] = False
    expect_refusal(
        lambda: capability_binding.migrate_run_binding(
            repo, run_id, stale, PROFILE, reason="stale", actor="test",
        ),
        "unproven browser migration accepted",
    )

    # Requested capability authority cannot be widened or reordered.
    expect_refusal(
        lambda: capability_binding.migrate_run_binding(
            repo, run_id, resolution("D", requested=["toolchain.other"]), PROFILE,
            reason="authority drift", actor="test",
            requested_capabilities=["toolchain.synthetic"],
        ),
        "capability-set drift accepted",
    )

    # Crash before active-binding switch: prepared evidence is recovered on
    # retry without a duplicate migration or lost old binding.
    repo2 = root / "repo-before-switch"
    (repo2 / ".ownframework-loop" / "run-x").mkdir(parents=True)
    old2 = capability_binding.ensure_run_binding(repo2, "run-x", resolution("A"), PROFILE, allow_create=True)
    active2 = capability_binding.binding_path(repo2, "run-x")
    real_replace = capability_binding._atomic_replace_json
    def fail_active(path, payload):
        if path == active2:
            raise RuntimeError("synthetic crash before binding switch")
        return real_replace(path, payload)
    capability_binding._atomic_replace_json = fail_active
    expect_refusal(
        lambda: capability_binding.migrate_run_binding(
            repo2, "run-x", resolution("B"), PROFILE, reason="crash", actor="test",
        ),
        "synthetic pre-switch crash did not surface",
    )
    capability_binding._atomic_replace_json = real_replace
    assert capability_binding._read(active2)["binding_sha256"] == old2["binding_sha256"]
    recovered = capability_binding.migrate_run_binding(
        repo2, "run-x", resolution("B"), PROFILE, reason="crash", actor="test",
    )
    assert recovered["status"] == "COMPLETE" and recovered["idempotent"] is True

    # Crash after active switch but before completion marker: retry completes
    # the exact prepared record.
    repo3 = root / "repo-after-switch"
    (repo3 / ".ownframework-loop" / "run-x").mkdir(parents=True)
    capability_binding.ensure_run_binding(repo3, "run-x", resolution("A"), PROFILE, allow_create=True)
    record_crash = {"n": 0}
    real_replace = capability_binding._atomic_replace_json
    def fail_record(path, payload):
        if path.name == "RECORD.json" and payload.get("status") == "COMPLETE" and record_crash["n"] == 0:
            record_crash["n"] += 1
            raise RuntimeError("synthetic crash after binding switch")
        return real_replace(path, payload)
    capability_binding._atomic_replace_json = fail_record
    expect_refusal(
        lambda: capability_binding.migrate_run_binding(
            repo3, "run-x", resolution("B"), PROFILE, reason="crash", actor="test",
        ),
        "synthetic post-switch crash did not surface",
    )
    capability_binding._atomic_replace_json = real_replace
    recovered2 = capability_binding.migrate_run_binding(
        repo3, "run-x", resolution("B"), PROFILE, reason="crash", actor="test",
    )
    assert recovered2["status"] == "COMPLETE" and recovered2["idempotent"] is True

    # Eligibility remains owned by supervisor: only quarantined unfinished
    # rows qualify, and live/ambiguous workers are refused.
    for status in ("QUEUED", "BACKOFF", "RUNNING", "DONE", "RETIRED"):
        row = {"status": status, "worker_pid": None, "worker_started_at": None, "worker_start_identity": None}
        expect_refusal(
            lambda row=row: supervisor._migrate_quarantined_run_capabilities(
                canonical_repo=repo, run_id=run_id, existing=row, reason="x", actor="test"
            ),
            f"migration accepted supervisor status {status}",
        )
    live = {"status": "QUARANTINED", "worker_pid": os.getpid(), "worker_started_at": None, "worker_start_identity": "live"}
    expect_refusal(
        lambda: supervisor._migrate_quarantined_run_capabilities(
            canonical_repo=repo, run_id=run_id, existing=live, reason="x", actor="test"
        ),
        "live worker migration accepted",
    )
    ambiguous = {"status": "QUARANTINED", "worker_pid": 99999999, "worker_started_at": None, "worker_start_identity": None}
    expect_refusal(
        lambda: supervisor._migrate_quarantined_run_capabilities(
            canonical_repo=repo, run_id=run_id, existing=ambiguous, reason="x", actor="test"
        ),
        "ambiguous worker migration accepted",
    )

    # Public operator surface is explicit; ordinary resume remains distinct.
    import inspect
    assert "rebind_capabilities" in inspect.signature(supervisor.resume).parameters

print("OF_LOOP_V096_CAPABILITY_BINDING_MIGRATION=PASS")
PY
