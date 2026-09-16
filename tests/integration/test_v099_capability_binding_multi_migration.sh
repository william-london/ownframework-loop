#!/usr/bin/env bash
# v0.9.9 multi-migration post-switch recovery and frontier validation.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PYTHONPATH="$ROOT/lib${PYTHONPATH:+:$PYTHONPATH}"

python3 -B - <<'PY'
import hashlib
import json
import shutil
import tempfile
from pathlib import Path

from ownframework_loop import capability_binding


def resolution(version: str) -> dict:
    return {
        "capability_contract_revision": "host-capability-contract/v2",
        "requested": ["toolchain.synthetic"],
        "host_manifest_sha256": "manifest-" + version,
        "semantic_runtime_fingerprint": "runtime-" + version,
        "platform_identity": {"platform": "test", "release": version},
        "resolved": [{
            "name": "toolchain.synthetic",
            "kind": "tool",
            "provider": "builtin",
            "version": version,
            "network_domains": [],
        }],
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


def digest_record(record: dict) -> dict:
    body = dict(record)
    body.pop("migration_record_sha256", None)
    body["migration_record_sha256"] = hashlib.sha256(
        capability_binding._canonical(body)
    ).hexdigest()
    return body


def write_json_private(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    path.chmod(0o600)


def prepare_second_migration(root: Path, label: str):
    repo = root / label
    run_id = "run-multi-migration"
    (repo / ".ownframework-loop" / run_id).mkdir(parents=True)
    old = capability_binding.ensure_run_binding(
        repo, run_id, resolution("A"), PROFILE, allow_create=True
    )
    first = capability_binding.migrate_run_binding(
        repo, run_id, resolution("B"), PROFILE, reason="first", actor="test"
    )
    real_replace = capability_binding._atomic_replace_json

    def crash_after_second_switch(path: Path, payload: dict) -> None:
        if path.name == "RECORD.json" and payload.get("status") == "COMPLETE" and payload.get("migration_sequence") == 2:
            raise RuntimeError("synthetic crash after second active switch")
        real_replace(path, payload)

    capability_binding._atomic_replace_json = crash_after_second_switch
    try:
        try:
            capability_binding.migrate_run_binding(
                repo, run_id, resolution("C"), PROFILE, reason="second", actor="test"
            )
        except RuntimeError as exc:
            assert str(exc) == "synthetic crash after second active switch"
        else:
            raise AssertionError("second post-switch crash was not injected")
    finally:
        capability_binding._atomic_replace_json = real_replace

    history = capability_binding.migration_root(repo, run_id)
    records, incomplete = capability_binding._migration_inventory(repo, run_id)
    assert not incomplete, incomplete
    assert [r["status"] for r in records] == ["COMPLETE", "PREPARED"], records
    active = capability_binding._read(capability_binding.binding_path(repo, run_id))
    assert active["binding_sha256"] == records[1]["new_binding_sha256"], active
    assert records[1]["previous_binding_sha256"] == first["new_binding_sha256"], records[1]
    return repo, run_id, old, first, records, history


def expect_refusal(fn, label: str) -> None:
    try:
        fn()
    except capability_binding.CapabilityBindingError:
        return
    raise AssertionError(label)


with tempfile.TemporaryDirectory(prefix="ofloop-v099-migration-") as td:
    root = Path(td)

    # Real multi-step recovery: A -> B complete, B -> C crashes after the
    # switch, exact retry completes it, and C -> D becomes sequence three.
    repo, run_id, old, first, pending, history = prepare_second_migration(root, "chain")
    recovered = capability_binding.migrate_run_binding(
        repo, run_id, resolution("C"), PROFILE, reason="second-retry", actor="test"
    )
    assert recovered["status"] == "COMPLETE", recovered
    assert recovered["idempotent"] is True, recovered
    assert recovered["migration_sequence"] == 2, recovered
    active = capability_binding._read(capability_binding.binding_path(repo, run_id))
    assert active["binding_sha256"] == recovered["new_binding_sha256"], active
    records = capability_binding._migration_records(repo, run_id)
    assert len(list(history.glob("*/RECORD.json"))) == 2
    assert len(records) == 2
    assert records[1]["previous_binding_sha256"] == first["new_binding_sha256"]
    assert records[1]["new_binding_sha256"] == recovered["new_binding_sha256"]
    assert records[1]["prior_migration_record_sha256"] == first["migration_record_sha256"]
    third = capability_binding.migrate_run_binding(
        repo, run_id, resolution("D"), PROFILE, reason="third", actor="test"
    )
    assert third["status"] == "COMPLETE" and third["migration_sequence"] == 3, third
    assert capability_binding._read(capability_binding.binding_path(repo, run_id))["binding_sha256"] == third["new_binding_sha256"]
    records = capability_binding._migration_records(repo, run_id)
    assert len(records) == 3
    assert [r["migration_sequence"] for r in records] == [1, 2, 3]
    assert [r["previous_binding_sha256"] for r in records] == [old["binding_sha256"], first["new_binding_sha256"], recovered["new_binding_sha256"]]
    assert [r["prior_migration_record_sha256"] for r in records] == [None, first["migration_record_sha256"], recovered["migration_record_sha256"]]
    print("A_TO_B_TO_C_TO_D_CHAIN=PASS")

    # An active binding outside the pending frontier is never repaired.
    repo, run_id, _old, _first, pending, _history = prepare_second_migration(root, "wrong-active")
    wrong_active = capability_binding._binding_document(run_id, capability_binding.stable_projection(resolution("D"), PROFILE))
    capability_binding._atomic_replace_json(capability_binding.binding_path(repo, run_id), wrong_active)
    expect_refusal(
        lambda: capability_binding.migrate_run_binding(repo, run_id, resolution("C"), PROFILE, reason="retry", actor="test"),
        "contradictory active binding accepted",
    )
    print("CONTRADICTORY_ACTIVE_BINDING=PASS")

    # Each malformed pending frontier is tested against a fresh, valid crash
    # state. Recompute the record digest so refusal exercises chain rules,
    # rather than only the outer record-integrity check.
    repo, run_id, old, _first, pending, history = prepare_second_migration(root, "wrong-previous")
    migration_dir = history / ("000002-" + pending[1]["new_binding_sha256"][:16])
    record_path = migration_dir / "RECORD.json"
    record = json.loads(record_path.read_text(encoding="utf-8"))
    record["previous_binding"] = old
    record["previous_binding_sha256"] = old["binding_sha256"]
    write_json_private(migration_dir / "PREVIOUS_BINDING.json", old)
    write_json_private(record_path, digest_record(record))
    expect_refusal(
        lambda: capability_binding.migrate_run_binding(repo, run_id, resolution("C"), PROFILE, reason="retry", actor="test"),
        "wrong pending previous binding accepted",
    )
    print("WRONG_PREVIOUS_BINDING=PASS")

    repo, run_id, _old, _first, pending, history = prepare_second_migration(root, "wrong-new")
    record_path = history / ("000002-" + pending[1]["new_binding_sha256"][:16]) / "RECORD.json"
    record = json.loads(record_path.read_text(encoding="utf-8"))
    record["new_binding_sha256"] = "f" * 64
    write_json_private(record_path, digest_record(record))
    expect_refusal(
        lambda: capability_binding.migrate_run_binding(repo, run_id, resolution("C"), PROFILE, reason="retry", actor="test"),
        "wrong pending new binding digest accepted",
    )
    print("WRONG_NEW_BINDING=PASS")

    repo, run_id, _old, _first, pending, history = prepare_second_migration(root, "wrong-sequence")
    record_path = history / ("000002-" + pending[1]["new_binding_sha256"][:16]) / "RECORD.json"
    record = json.loads(record_path.read_text(encoding="utf-8"))
    record["migration_sequence"] = 3
    write_json_private(record_path, digest_record(record))
    expect_refusal(
        lambda: capability_binding.migrate_run_binding(repo, run_id, resolution("C"), PROFILE, reason="retry", actor="test"),
        "wrong pending sequence accepted",
    )
    print("WRONG_SEQUENCE=PASS")

    repo, run_id, _old, _first, pending, history = prepare_second_migration(root, "wrong-prior-record")
    record_path = history / ("000002-" + pending[1]["new_binding_sha256"][:16]) / "RECORD.json"
    record = json.loads(record_path.read_text(encoding="utf-8"))
    record["prior_migration_record_sha256"] = "0" * 64
    write_json_private(record_path, digest_record(record))
    expect_refusal(
        lambda: capability_binding.migrate_run_binding(repo, run_id, resolution("C"), PROFILE, reason="retry", actor="test"),
        "wrong pending prior record accepted",
    )
    print("WRONG_PRIOR_RECORD=PASS")

    repo, run_id, _old, _first, pending, history = prepare_second_migration(root, "multiple-prepared")
    source_dir = history / ("000002-" + pending[1]["new_binding_sha256"][:16])
    extra_dir = history / "000003-extra-prepared"
    shutil.copytree(source_dir, extra_dir)
    extra_record_path = extra_dir / "RECORD.json"
    extra_record = json.loads(extra_record_path.read_text(encoding="utf-8"))
    extra_record["migration_directory"] = extra_dir.name
    extra_record["migration_sequence"] = 3
    write_json_private(extra_record_path, digest_record(extra_record))
    expect_refusal(
        lambda: capability_binding.migrate_run_binding(repo, run_id, resolution("C"), PROFILE, reason="retry", actor="test"),
        "multiple prepared frontiers accepted",
    )
    print("MULTIPLE_PREPARED=PASS")

print("OF_LOOP_V099_CAPABILITY_BINDING_MULTI_MIGRATION=PASS")
PY
