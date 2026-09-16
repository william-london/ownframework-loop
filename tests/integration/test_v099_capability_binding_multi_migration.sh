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

    # Historical migration records must not be mistaken for the current
    # idempotent migration frontier merely because the same previous->new
    # binding identities occur again later in the chain. The fix lives in
    # CURRENT-frontier selection/recovery logic, not in the chain validator.
    # Required regression: A -> B (seq 1), B -> A (seq 2), A -> B (seq 3).
    # Sequence 3 must NOT reuse sequence 1's evidence, and must report
    # idempotent=False.
    cycle_repo = root / "cycle"
    cycle_run_id = "run-cycle-regression"
    (cycle_repo / ".ownframework-loop" / cycle_run_id).mkdir(parents=True)
    cycle_a = capability_binding.ensure_run_binding(
        cycle_repo, cycle_run_id, resolution("A"), PROFILE, allow_create=True
    )
    cycle_b = capability_binding.migrate_run_binding(
        cycle_repo, cycle_run_id, resolution("B"), PROFILE,
        reason="cycle-first", actor="test",
    )
    assert cycle_b["migration_sequence"] == 1 and cycle_b["idempotent"] is False, cycle_b
    cycle_a2 = capability_binding.migrate_run_binding(
        cycle_repo, cycle_run_id, resolution("A"), PROFILE,
        reason="cycle-second", actor="test",
    )
    assert cycle_a2["migration_sequence"] == 2 and cycle_a2["idempotent"] is False, cycle_a2
    cycle_b2 = capability_binding.migrate_run_binding(
        cycle_repo, cycle_run_id, resolution("B"), PROFILE,
        reason="cycle-third", actor="test",
    )
    assert cycle_b2["migration_sequence"] == 3, cycle_b2
    assert cycle_b2["status"] == "COMPLETE", cycle_b2
    assert cycle_b2["idempotent"] is False, cycle_b2
    cycle_history = capability_binding.migration_root(cycle_repo, cycle_run_id)
    cycle_dirs = sorted(cycle_history.glob("*/RECORD.json"))
    assert len(cycle_dirs) == 3, [d.parent.name for d in cycle_dirs]
    cycle_records = capability_binding._migration_records(cycle_repo, cycle_run_id)
    assert [r["migration_sequence"] for r in cycle_records] == [1, 2, 3], [r["migration_sequence"] for r in cycle_records]
    assert [r["previous_binding_sha256"] for r in cycle_records] == [
        cycle_a["binding_sha256"],
        cycle_b["new_binding_sha256"],
        cycle_a2["new_binding_sha256"],
    ]
    assert [r["new_binding_sha256"] for r in cycle_records] == [
        cycle_b["new_binding_sha256"],
        cycle_a2["new_binding_sha256"],
        cycle_b2["new_binding_sha256"],
    ]
    assert [r["prior_migration_record_sha256"] for r in cycle_records] == [
        None,
        cycle_b["migration_record_sha256"],
        cycle_a2["migration_record_sha256"],
    ]
    assert (
        capability_binding._read(capability_binding.binding_path(cycle_repo, cycle_run_id))["binding_sha256"]
        == cycle_b2["new_binding_sha256"]
    )
    print("CYCLE_TEST=PASS")

    # After migration 3 (A -> B COMPLETE), an idempotent re-request of the
    # same migration must NOT create sequence 4, must NOT create a new
    # directory, and must identify the CURRENT latest completed frontier
    # (sequence 3), not historical sequence 1.
    cycle_retry = capability_binding.migrate_run_binding(
        cycle_repo, cycle_run_id, resolution("B"), PROFILE,
        reason="cycle-third-retry", actor="test",
    )
    assert cycle_retry["idempotent"] is True, cycle_retry
    assert cycle_retry["migration_sequence"] == 3, cycle_retry
    cycle_records = capability_binding._migration_records(cycle_repo, cycle_run_id)
    assert len(cycle_records) == 3, len(cycle_records)
    print("LATEST_IDEMPOTENCE_TEST=PASS")

    # Continue cycling so the regression proves a one-off patch that only
    # permits a single repeated edge would have failed.
    cycle_a3 = capability_binding.migrate_run_binding(
        cycle_repo, cycle_run_id, resolution("A"), PROFILE,
        reason="cycle-fourth", actor="test",
    )
    assert cycle_a3["migration_sequence"] == 4 and cycle_a3["idempotent"] is False, cycle_a3
    cycle_b3 = capability_binding.migrate_run_binding(
        cycle_repo, cycle_run_id, resolution("B"), PROFILE,
        reason="cycle-fifth", actor="test",
    )
    assert cycle_b3["migration_sequence"] == 5 and cycle_b3["idempotent"] is False, cycle_b3
    cycle_records = capability_binding._migration_records(cycle_repo, cycle_run_id)
    assert len(cycle_records) == 5
    assert [r["migration_sequence"] for r in cycle_records] == [1, 2, 3, 4, 5]
    print("REPEATED_CYCLE_TEST=PASS")

    # PREPARED recovery still wins when a historical edge repeats: build
    # A -> B (seq 1 COMPLETE), B -> A (seq 2 COMPLETE), then arrange a
    # PREPARED A -> B that crashes after the active switch. Retry recovers
    # the pending frontier as sequence 3, never historical sequence 1.
    pre_repo = root / "prepared-pre"
    pre_run_id = "run-prepared-pre"
    (pre_repo / ".ownframework-loop" / pre_run_id).mkdir(parents=True)
    pre_a = capability_binding.ensure_run_binding(
        pre_repo, pre_run_id, resolution("A"), PROFILE, allow_create=True
    )
    pre_b = capability_binding.migrate_run_binding(
        pre_repo, pre_run_id, resolution("B"), PROFILE, reason="pre-first", actor="test"
    )
    pre_a_back = capability_binding.migrate_run_binding(
        pre_repo, pre_run_id, resolution("A"), PROFILE, reason="pre-second", actor="test"
    )
    assert pre_a_back["migration_sequence"] == 2 and pre_a_back["idempotent"] is False, pre_a_back
    real_replace = capability_binding._atomic_replace_json

    def crash_after_pre_switch(path: Path, payload: dict) -> None:
        if (
            path.name == "RECORD.json"
            and payload.get("status") == "COMPLETE"
            and int(payload.get("migration_sequence") or 0) == 3
        ):
            raise RuntimeError("synthetic crash after third migration switch")
        real_replace(path, payload)

    capability_binding._atomic_replace_json = crash_after_pre_switch
    try:
        try:
            capability_binding.migrate_run_binding(
                pre_repo, pre_run_id, resolution("B"), PROFILE,
                reason="pre-third", actor="test",
            )
        except RuntimeError as exc:
            assert str(exc) == "synthetic crash after third migration switch"
        else:
            raise AssertionError("third post-switch crash was not injected")
    finally:
        capability_binding._atomic_replace_json = real_replace

    pre_records = capability_binding._migration_records(pre_repo, pre_run_id)
    assert [r["status"] for r in pre_records] == ["COMPLETE", "COMPLETE", "PREPARED"], pre_records
    pre_recovered = capability_binding.migrate_run_binding(
        pre_repo, pre_run_id, resolution("B"), PROFILE,
        reason="pre-third-retry", actor="test",
    )
    assert pre_recovered["status"] == "COMPLETE", pre_recovered
    assert pre_recovered["migration_sequence"] == 3, pre_recovered
    assert pre_recovered["idempotent"] is True, pre_recovered
    pre_records = capability_binding._migration_records(pre_repo, pre_run_id)
    assert len(pre_records) == 3, len(pre_records)
    assert all(r["status"] == "COMPLETE" for r in pre_records), pre_records
    print("PREPARED_REPEATED_EDGE_PRE_SWITCH=PASS")

    # Same fixture but the crash occurs after the active switch has already
    # moved to B; retry recovers the pending frontier as sequence 3.
    post_repo = root / "prepared-post"
    post_run_id = "run-prepared-post"
    (post_repo / ".ownframework-loop" / post_run_id).mkdir(parents=True)
    post_a = capability_binding.ensure_run_binding(
        post_repo, post_run_id, resolution("A"), PROFILE, allow_create=True
    )
    post_b = capability_binding.migrate_run_binding(
        post_repo, post_run_id, resolution("B"), PROFILE, reason="post-first", actor="test"
    )
    post_a_back = capability_binding.migrate_run_binding(
        post_repo, post_run_id, resolution("A"), PROFILE, reason="post-second", actor="test"
    )
    assert post_a_back["migration_sequence"] == 2 and post_a_back["idempotent"] is False, post_a_back
    real_replace = capability_binding._atomic_replace_json

    def crash_after_post_switch(path: Path, payload: dict) -> None:
        if (
            path.name == "RECORD.json"
            and payload.get("status") == "COMPLETE"
            and int(payload.get("migration_sequence") or 0) == 3
        ):
            raise RuntimeError("synthetic crash after third post migration switch")
        real_replace(path, payload)

    capability_binding._atomic_replace_json = crash_after_post_switch
    try:
        try:
            capability_binding.migrate_run_binding(
                post_repo, post_run_id, resolution("B"), PROFILE,
                reason="post-third", actor="test",
            )
        except RuntimeError as exc:
            assert str(exc) == "synthetic crash after third post migration switch"
        else:
            raise AssertionError("third post-switch crash was not injected")
    finally:
        capability_binding._atomic_replace_json = real_replace

    post_active = capability_binding._read(capability_binding.binding_path(post_repo, post_run_id))
    # Crash-after-switch: active is already the new binding B even though
    # the RECORD.json COMPLETE marker was never written.
    post_expected_binding = capability_binding._binding_document(
        post_run_id,
        capability_binding.stable_projection(resolution("B"), PROFILE),
    )
    assert post_active["binding_sha256"] == post_expected_binding["binding_sha256"]
    post_recovered = capability_binding.migrate_run_binding(
        post_repo, post_run_id, resolution("B"), PROFILE,
        reason="post-third-retry", actor="test",
    )
    assert post_recovered["status"] == "COMPLETE", post_recovered
    assert post_recovered["migration_sequence"] == 3, post_recovered
    assert post_recovered["idempotent"] is True, post_recovered
    post_records = capability_binding._migration_records(post_repo, post_run_id)
    assert len(post_records) == 3, len(post_records)
    assert all(r["status"] == "COMPLETE" for r in post_records), post_records
    print("PREPARED_REPEATED_EDGE_POST_SWITCH=PASS")

print("OF_LOOP_V099_CAPABILITY_BINDING_MULTI_MIGRATION=PASS")
PY
