"""Orthogonal PROGRAM runtime identity and generation-migration authority.

Mission source/semantic authority remains owned by :mod:`program_mission`; this
module owns runtime identity binding, migration-chain verification, and
workerless generation transitions.
"""
from __future__ import annotations

import copy
import hashlib
from pathlib import Path
from typing import Any

from . import (
    approval, build_finalize, git_checks, integrity, packet, runner_profiles,
    supervisor_runtime, state, supervisor_db, transitions, util,
)
from . import program_mission as mission

MISSION_RUNTIME_SCHEMA = mission.MISSION_RUNTIME_SCHEMA
MISSION_RUNTIME_MIGRATION_SCHEMA = mission.MISSION_RUNTIME_MIGRATION_SCHEMA
MISSION_RUNTIME_MIGRATION_V2_SCHEMA = mission.MISSION_RUNTIME_MIGRATION_V2_SCHEMA
MISSION_RUNTIME_BINDING_SCHEMA = mission.MISSION_RUNTIME_BINDING_SCHEMA
SEGMENT_SCHEMA = mission.SEGMENT_SCHEMA
MISSION_SCHEMA = mission.MISSION_SCHEMA
MissionAuthorityError = mission.MissionAuthorityError
_FULL_SHA_RE = mission._FULL_SHA_RE
_SHA256_RE = mission._SHA256_RE

for _helper_name in (
    "_read_record", "_digest", "_write_once", "_mission_runtime_path",
    "_mission_runtime_migration_path", "_mission_runtime_binding_path",
    "_manifest_path", "_segment_path", "load_segment",
    "_verified_mission_spend",
):
    globals()[_helper_name] = getattr(mission, _helper_name)

def _read_runtime_migration_record(path: Path) -> tuple[dict[str, Any], str]:
    """Read one supported append-only runtime migration schema."""
    failure: MissionAuthorityError | None = None
    for schema in (MISSION_RUNTIME_MIGRATION_SCHEMA, MISSION_RUNTIME_MIGRATION_V2_SCHEMA):
        try:
            return _read_record(path, expected_schema=schema)
        except MissionAuthorityError as exc:
            failure = exc
    raise failure or MissionAuthorityError("runtime migration record is invalid")

def _event_chain_hash_for_prefix(events: list[dict[str, Any]]) -> str:
    chain = ""
    for event in events:
        stripped = {key: value for key, value in event.items() if key != "event_chain_sha256"}
        digest = hashlib.sha256()
        digest.update(chain.encode("utf-8"))
        digest.update(integrity.canonical_json_dumps(stripped).encode("utf-8"))
        chain = digest.hexdigest()
    return chain

def _runtime_migration_ref(segment: dict[str, Any]) -> dict[str, Any] | None:
    admission = segment.get("source_admission") or {}
    value = admission.get("runtime_migration")
    if value is None:
        return None
    if (
        not isinstance(value, dict)
        or not isinstance(value.get("sequence"), int)
        or isinstance(value.get("sequence"), bool)
        or not 1 <= int(value.get("sequence") or 0) <= 16
        or not _SHA256_RE.fullmatch(str(value.get("sha256") or ""))
        or not isinstance(value.get("runtime_generation"), str)
        or not value.get("runtime_generation")
    ):
        raise MissionAuthorityError("segment runtime migration reference is malformed")
    return value

def _verify_runtime_migration_source(repo: Path, migration: dict[str, Any]) -> None:
    """Re-prove immutable source evidence for a typed runtime-generation move."""
    source = migration.get("source_authority")
    if not isinstance(source, dict):
        raise MissionAuthorityError("runtime migration source authority is missing")
    run_id = str(source.get("run_id") or "")
    if not run_id:
        raise MissionAuthorityError("runtime migration source run is missing")
    root = state.run_dir(repo, run_id)
    packet_path = root / "WORK_PACKET.md"
    state_file = state.state_path(repo, run_id)
    events_file = state.events_path(repo, run_id)
    if migration.get("schema") == MISSION_RUNTIME_MIGRATION_V2_SCHEMA:
        segment_number = source.get("segment_number")
        if (
            migration.get("migration_kind") != "active_segment_resume"
            or source.get("schema") != "ownframework-loop-active-segment-runtime-source/v1"
            or not isinstance(segment_number, int) or isinstance(segment_number, bool)
            or not 1 <= segment_number <= 16
            or migration.get("runtime_generation") == migration.get("previous_runtime_generation")
        ):
            raise MissionAuthorityError("same-segment runtime migration source is malformed")
        segment, segment_sha = _read_record(
            _segment_path(repo, str(migration.get("mission_id") or ""), segment_number),
            expected_schema=SEGMENT_SCHEMA,
        )
        if (
            segment_sha != source.get("segment_authority_sha256")
            or segment.get("segment_number") != segment_number
            or segment.get("mission_id") != migration.get("mission_id")
            or segment.get("run_id") != run_id
            or not packet_path.is_file()
            or util.sha256_file(packet_path) != source.get("packet_sha256")
            or not state_file.is_file()
            or not events_file.is_file()
        ):
            raise MissionAuthorityError("same-segment runtime migration packet/segment evidence drifted")
        events = integrity.read_event_chain(events_file)
        event_count = source.get("event_count")
        if (
            not isinstance(event_count, int) or isinstance(event_count, bool)
            or event_count < 1 or event_count > len(events)
            or _event_chain_hash_for_prefix(events[:event_count])
            != source.get("event_chain_sha256")
            or integrity.compute_event_chain_hash(events_file)
            != integrity.get_event_chain_hash(events_file)
            or events[event_count - 1].get("state_sha256") != source.get("state_sha256")
        ):
            raise MissionAuthorityError("same-segment runtime migration event prefix is invalid")
        current = state.load_verified(repo, run_id)
        source_job = source.get("source_job")
        candidate_sha = str(source.get("candidate_sha") or "")
        baseline_sha = str(source.get("baseline_sha") or "")
        candidate_branch = str(segment.get("candidate_branch") or "")
        attempt_ledger_sha = str(source.get("semantic_attempt_ledger_sha256") or "")
        # The source ledger digest is captured before the migration is
        # published. An empty projection proves the only safe unmaterialized
        # case: the candidate is still the sealed baseline and no semantic
        # provider attempt existed when this authority was created.
        semantic_attempt_count = 0 if attempt_ledger_sha == _digest([]) else 1
        if (
            not isinstance(current, dict)
            or not isinstance(source_job, dict)
            or source_job.get("status") != "QUARANTINED"
            or any(source_job.get(key) is not None for key in (
                "worker_pid", "worker_pgid", "worker_attempt_id", "worker_role",
                "worker_started_at", "worker_deadline_at", "worker_start_identity",
            ))
            or source_job.get("runtime_generation") != migration.get("previous_runtime_generation")
            or source.get("engineering_state") in {"APPROVED", "BLOCKED", "STOPPED", "SEGMENT_BOUNDARY"}
            or source.get("baseline_sha") != segment.get("baseline_sha")
            or not _runtime_migration_candidate_lineage_valid(
                repo, candidate_sha, baseline_sha, candidate_branch,
                semantic_attempt_count=semantic_attempt_count,
            )
            or not str(source.get("checkpoint_id") or "")
            or not _SHA256_RE.fullmatch(attempt_ledger_sha)
        ):
            raise MissionAuthorityError("same-segment runtime migration state is invalid")
        approval_doc = approval.load_approval(repo, run_id)
        if approval.approval_artifact_sha256(approval_doc or {}) != source.get("approval_sha256"):
            raise MissionAuthorityError("same-segment runtime migration approval evidence drifted")
        return

    if migration.get("schema") != MISSION_RUNTIME_MIGRATION_SCHEMA:
        raise MissionAuthorityError("runtime migration schema is unsupported")
    if (
        not packet_path.is_file() or not state_file.is_file() or not events_file.is_file()
        or util.sha256_file(packet_path) != source.get("packet_sha256")
        or util.sha256_file(state_file) != source.get("state_sha256")
        or integrity.compute_event_chain_hash(events_file) != source.get("event_chain_sha256")
        or integrity.get_event_chain_hash(events_file) != source.get("event_chain_sha256")
    ):
        raise MissionAuthorityError("runtime migration source packet/state/event evidence drifted")
    current = state.load_verified(repo, run_id)
    if (
        not isinstance(current, dict)
        or current.get("state") != "BLOCKED"
        or current.get("last_candidate_sha") != source.get("crossing_candidate_sha")
    ):
        raise MissionAuthorityError("runtime migration source is no longer the sealed blocked boundary")

def _runtime_identity_from_migration(
    repo: Path,
    mission_id: str,
    migration: dict[str, Any],
    migration_sha: str,
    sequence: int,
) -> tuple[dict[str, Any], str]:
    receipt_path = _mission_runtime_binding_path(repo, mission_id, sequence)
    if receipt_path.exists():
        receipt, receipt_sha = _read_record(
            receipt_path, expected_schema=MISSION_RUNTIME_BINDING_SCHEMA,
        )
        identity = receipt.get("runtime_identity")
        if (
            receipt.get("mission_id") != mission_id
            or receipt.get("sequence") != sequence
            or receipt.get("migration_sha256") != migration_sha
            or not isinstance(identity, dict)
            or identity.get("runtime_generation") != migration.get("runtime_generation")
            or identity.get("capabilities") != migration.get("capabilities")
            or identity.get("runner_profile") != migration.get("runner_profile")
        ):
            raise MissionAuthorityError("runtime-generation binding receipt contradicts migration")
        return {**identity, "runtime_migration_sequence": sequence}, receipt_sha
    return {
        "mission_id": mission_id,
        "runtime_generation": str(migration["runtime_generation"]),
        "capabilities": copy.deepcopy(migration["capabilities"]),
        "runner_profile": copy.deepcopy(migration["runner_profile"]),
        "effort_attestation_sha256": None,
        "runtime_migration_sequence": sequence,
    }, migration_sha

def _runtime_identity_for_segment(
    repo: Path,
    mission_id: str,
    segment: dict[str, Any],
) -> tuple[dict[str, Any], str]:
    """Resolve the immutable runtime identity authorized for one segment."""
    migration_ref = _runtime_migration_ref(segment)
    if migration_ref is None:
        base_path = _mission_runtime_path(repo, mission_id)
        if base_path.exists():
            identity, identity_sha = _read_record(
                base_path, expected_schema=MISSION_RUNTIME_SCHEMA,
            )
        else:
            mission, _ = _read_record(
                _manifest_path(repo, mission_id), expected_schema=MISSION_SCHEMA,
            )
            identity = {
                "mission_id": mission_id,
                "runtime_generation": str(
                    (mission.get("operational_budget") or {}).get("runtime_generation") or ""
                ),
                "capabilities": None,
                "runner_profile": None,
                "effort_attestation_sha256": None,
            }
            identity_sha = _digest(identity)
        sequence = 0
    else:
        migration, migration_sha = _read_runtime_migration_record(
            _mission_runtime_migration_path(repo, mission_id, int(migration_ref["sequence"])),
        )
        if (
            migration_sha != migration_ref.get("sha256")
            or migration.get("mission_id") != mission_id
            or migration.get("sequence") != migration_ref.get("sequence")
            or migration.get("runtime_generation") != migration_ref.get("runtime_generation")
        ):
            raise MissionAuthorityError("segment runtime migration does not bind its immutable record")
        _verify_runtime_migration_source(repo, migration)
        source_run = str((migration.get("source_authority") or {}).get("run_id") or "")
        if migration.get("schema") == MISSION_RUNTIME_MIGRATION_V2_SCHEMA and source_run not in {
            str(segment.get("run_id") or ""), str(segment.get("predecessor_run_id") or ""),
        }:
            raise MissionAuthorityError("segment runtime migration is not bound to its typed boundary")
        identity, identity_sha = _runtime_identity_from_migration(
            repo, mission_id, migration, migration_sha, int(migration_ref["sequence"]),
        )
        sequence = int(migration_ref["sequence"])

    # A v2 migration may rebind this existing segment without changing its
    # sealed SEGMENT record. Apply only the contiguous, append-only v2 tail
    # whose source is this exact run. A later successor-boundary migration
    # remains historical for this segment.
    while sequence < 16:
        next_sequence = sequence + 1
        next_path = _mission_runtime_migration_path(repo, mission_id, next_sequence)
        if not next_path.exists():
            break
        next_migration, next_sha = _read_runtime_migration_record(next_path)
        source = next_migration.get("source_authority") or {}
        if (
            next_migration.get("schema") != MISSION_RUNTIME_MIGRATION_V2_SCHEMA
            or next_migration.get("migration_kind") != "active_segment_resume"
            or source.get("run_id") != segment.get("run_id")
        ):
            break
        if (
            next_migration.get("mission_id") != mission_id
            or next_migration.get("sequence") != next_sequence
            or next_migration.get("previous_runtime_identity_sha256") != identity_sha
            or next_migration.get("previous_runtime_generation") != identity.get("runtime_generation")
            or next_migration.get("capabilities") != identity.get("capabilities")
            or next_migration.get("runner_profile") != identity.get("runner_profile")
        ):
            raise MissionAuthorityError("same-segment runtime migration chain is discontinuous")
        _verify_runtime_migration_source(repo, next_migration)
        identity, identity_sha = _runtime_identity_from_migration(
            repo, mission_id, next_migration, next_sha, next_sequence,
        )
        sequence = next_sequence
    return identity, identity_sha

def _active_mission_runtime(
    repo: Path,
    mission_doc: dict[str, Any],
    *,
    through_sequence: int | None = None,
) -> tuple[dict[str, Any], str, int]:
    """Resolve the latest append-only runtime migration, if any."""
    mission_id = str(mission_doc.get("mission_id") or "")
    base_path = _mission_runtime_path(repo, mission_id)
    if base_path.exists():
        identity, identity_sha = _read_record(
            base_path, expected_schema=MISSION_RUNTIME_SCHEMA,
        )
    else:
        identity = {
            "mission_id": mission_id,
            "runtime_generation": str(
                (mission_doc.get("operational_budget") or {}).get("runtime_generation") or ""
            ),
            "capabilities": None,
            "runner_profile": None,
            "effort_attestation_sha256": None,
        }
        identity_sha = _digest(identity)
    sequence = 0
    while sequence < 16 and (through_sequence is None or sequence < through_sequence):
        next_sequence = sequence + 1
        path = _mission_runtime_migration_path(repo, mission_id, next_sequence)
        if not path.exists():
            break
        migration, migration_sha = _read_runtime_migration_record(path)
        if (
            migration.get("mission_id") != mission_id
            or migration.get("sequence") != next_sequence
            or migration.get("previous_runtime_identity_sha256") != identity_sha
            or migration.get("previous_runtime_generation") != identity.get("runtime_generation")
            or migration.get("capabilities") != identity.get("capabilities")
            or migration.get("runner_profile") != identity.get("runner_profile")
        ):
            raise MissionAuthorityError("mission runtime migration chain is discontinuous")
        _verify_runtime_migration_source(repo, migration)
        binding_path = _mission_runtime_binding_path(repo, mission_id, next_sequence)
        if not binding_path.exists():
            return {
                "mission_id": mission_id,
                "runtime_generation": migration["runtime_generation"],
                "capabilities": copy.deepcopy(migration["capabilities"]),
                "runner_profile": copy.deepcopy(migration["runner_profile"]),
                "effort_attestation_sha256": None,
            }, migration_sha, next_sequence
        receipt, identity_sha = _read_record(
            binding_path, expected_schema=MISSION_RUNTIME_BINDING_SCHEMA,
        )
        if (
            receipt.get("mission_id") != mission_id
            or receipt.get("sequence") != next_sequence
            or receipt.get("migration_sha256") != migration_sha
            or not isinstance(receipt.get("runtime_identity"), dict)
        ):
            raise MissionAuthorityError("mission runtime binding chain is invalid")
        identity = receipt["runtime_identity"]
        if (
            identity.get("runtime_generation") != migration.get("runtime_generation")
            or identity.get("capabilities") != migration.get("capabilities")
            or identity.get("runner_profile") != migration.get("runner_profile")
        ):
            raise MissionAuthorityError("mission runtime binding differs from migration authority")
        sequence = next_sequence
    return identity, identity_sha, sequence

def bind_runtime_identity(
    canonical_repo: Path,
    run_id: str,
    *,
    run_binding: dict[str, Any],
    runner_profile: dict[str, Any],
    runtime_generation: str,
) -> dict[str, Any] | None:
    """Freeze the first real v4 provider binding for the complete mission.

    Each run still has its ordinary capability-binding artifact. This
    create-once mission record additionally prevents a derived segment from
    silently changing the commissioned capability projection or the named
    provider/model/effort identity.
    """
    repo = Path(canonical_repo).resolve(strict=False)
    loaded = load_segment(repo, run_id)
    if loaded is None:
        return None
    segment, _, mission_doc, _ = loaded
    try:
        from . import capability_binding

        verified_binding = capability_binding._validate_document(run_binding, run_id=run_id)
    except Exception as exc:
        raise MissionAuthorityError("mission runtime capability binding is invalid") from exc
    projection = verified_binding.get("projection")
    if not isinstance(projection, dict):
        raise MissionAuthorityError("mission runtime capability projection is missing")
    meta, _ = packet.parse_packet_file(state.run_dir(repo, run_id) / "WORK_PACKET.md")
    if sorted(str(value) for value in (projection.get("requested") or [])) != sorted(
        str(value) for value in (meta.get("capabilities") or [])
    ):
        raise MissionAuthorityError("mission runtime capability request differs from frozen packet")
    requested_profile = projection.get("requested_runner_profile")
    expected_profile = {
        key: runner_profile.get(key)
        for key in ("name", "provider", "model", "effort", "identity_sha256")
    }
    if not isinstance(requested_profile, dict) or any(
        requested_profile.get(key) != value for key, value in expected_profile.items()
    ):
        raise MissionAuthorityError("mission runtime profile differs from exact run binding")
    attestation = runner_profile.get("effort_attestation")
    effort_attestation_sha = (
        str(attestation.get("attestation_sha256") or "")
        if isinstance(attestation, dict) else None
    )
    if requested_profile.get("effort_attestation") != attestation:
        raise MissionAuthorityError("mission runtime effort attestation differs from run binding")
    identity = {
        "schema": MISSION_RUNTIME_SCHEMA,
        "mission_id": str(segment["mission_id"]),
        "runtime_generation": runtime_generation,
        "semantic_runtime_fingerprint": projection.get("semantic_runtime_fingerprint"),
        "capability_binding_sha256": str(verified_binding.get("binding_sha256") or ""),
        "capability_projection_sha256": _digest(projection),
        "capabilities": sorted(str(value) for value in (projection.get("requested") or [])),
        "runner_profile": expected_profile,
        "effort_attestation_sha256": effort_attestation_sha,
    }
    expected, _expected_sha = _runtime_identity_for_segment(
        repo, str(segment["mission_id"]), segment,
    )
    sequence_value = expected.get("runtime_migration_sequence")
    if sequence_value is None:
        expected_generation = str(
            (mission_doc.get("operational_budget") or {}).get("runtime_generation") or ""
        )
        if str(runtime_generation or "") != expected_generation:
            raise MissionAuthorityError("semantic worker runtime differs from frozen mission generation")
        path = _mission_runtime_path(repo, str(segment["mission_id"]))
        runtime_sha = _write_once(path, identity)
        return {**identity, "mission_runtime_sha256": runtime_sha}

    sequence = int(sequence_value)
    migration, migration_sha = _read_runtime_migration_record(
        _mission_runtime_migration_path(repo, str(segment["mission_id"]), sequence),
    )
    if (
        migration.get("mission_id") != str(segment["mission_id"])
        or migration.get("sequence") != sequence
        or migration.get("runtime_generation") != expected.get("runtime_generation")
        or str(runtime_generation or "") != str(expected.get("runtime_generation") or "")
        or identity["capabilities"] != expected.get("capabilities")
        or identity["runner_profile"] != expected.get("runner_profile")
    ):
        raise MissionAuthorityError(
            "semantic worker runtime/profile/capability request differs from typed migration"
        )
    receipt = {
        "schema": MISSION_RUNTIME_BINDING_SCHEMA,
        "mission_id": str(segment["mission_id"]),
        "sequence": sequence,
        "migration_sha256": migration_sha,
        "runtime_identity": identity,
    }
    receipt_sha = _write_once(
        _mission_runtime_binding_path(repo, str(segment["mission_id"]), sequence),
        receipt,
    )
    return {
        **identity,
        "mission_runtime_sha256": receipt_sha,
        "runtime_migration_sequence": sequence,
        "runtime_migration_sha256": migration_sha,
    }

def verify_runtime_identity(
    canonical_repo: Path,
    mission_id: str,
    *,
    run_binding: dict[str, Any],
    runner_profile: dict[str, Any],
    runtime_generation: str,
    segment_number: int | None = None,
) -> dict[str, Any]:
    """Require a segment binding to match its create-once mission generation."""
    repo = Path(canonical_repo).resolve(strict=False)
    if segment_number is None:
        expected, expected_sha = _read_record(
            _mission_runtime_path(repo, mission_id),
            expected_schema=MISSION_RUNTIME_SCHEMA,
        )
    else:
        segment, _ = _read_record(
            _segment_path(repo, mission_id, segment_number),
            expected_schema=SEGMENT_SCHEMA,
        )
        expected, expected_sha = _runtime_identity_for_segment(repo, mission_id, segment)
    try:
        from . import capability_binding

        verified_binding = capability_binding._validate_document(run_binding)
    except Exception as exc:
        raise MissionAuthorityError("mission runtime capability binding is invalid") from exc
    projection = verified_binding.get("projection") or {}
    actual_profile = {
        key: runner_profile.get(key)
        for key in ("name", "provider", "model", "effort", "identity_sha256")
    }
    attestation = runner_profile.get("effort_attestation")
    actual = {
        "runtime_generation": runtime_generation,
        "semantic_runtime_fingerprint": projection.get("semantic_runtime_fingerprint"),
        "capability_binding_sha256": str(verified_binding.get("binding_sha256") or ""),
        "capability_projection_sha256": _digest(projection),
        "capabilities": sorted(str(value) for value in (projection.get("requested") or [])),
        "runner_profile": actual_profile,
        "effort_attestation_sha256": (
            str(attestation.get("attestation_sha256") or "")
            if isinstance(attestation, dict) else None
        ),
    }
    if any(expected.get(key) != value for key, value in actual.items()):
        raise MissionAuthorityError("later segment runtime/capability/profile identity drifted")
    return {**expected, "mission_runtime_sha256": expected_sha}

def _runtime_migration_candidate_lineage_valid(
    repo: Path,
    candidate_sha: str,
    baseline_sha: str,
    branch: str,
    *,
    semantic_attempt_count: int,
) -> bool:
    """Validate a materialized candidate or a still-unmaterialized baseline.

    A sealed segment may be quarantined before its first BUILD claim or
    before build preparation creates the candidate branch. In that exact
    no-attempt state, the sealed baseline remains the candidate authority;
    accepting it does not infer or create a branch. Any semantic attempt or
    candidate movement requires the named branch to prove containment.
    """
    if (
        not _FULL_SHA_RE.fullmatch(candidate_sha)
        or not _FULL_SHA_RE.fullmatch(baseline_sha)
        or not git_checks.is_valid_branch_name(branch)
        or not build_finalize._ancestor_of(repo, candidate_sha, baseline_sha)
    ):
        return False
    if build_finalize._candidate_branch_contains(repo, branch, candidate_sha):
        return True
    return (
        candidate_sha == baseline_sha
        and git_checks.branch_head(repo, branch) is None
        and semantic_attempt_count == 0
    )

def prepare_runtime_generation_resume(
    canonical_repo: Path,
    run_id: str,
    *,
    job_snapshot: dict[str, Any],
    target_runtime_generation: str,
    db_path: Path | None = None,
) -> dict[str, Any] | None:
    """Append an exact runtime migration at a workerless resume boundary.

    Runtime identity is orthogonal to how the mission reached this segment.
    The supervisor owns the QUARANTINED -> QUEUED transition; this function
    binds the generation change to the unchanged packet, segment, state/event
    prefix, candidate, job row, and completed attempt ledger. A crash before
    the ledger transition reuses only that exact record.
    """
    repo = Path(canonical_repo).resolve(strict=False)
    loaded = load_segment(repo, run_id)
    if loaded is None:
        return None
    segment, segment_sha, mission_doc, _mission_sha = loaded
    mission_id = str(segment.get("mission_id") or "")
    previous_generation = str(job_snapshot.get("runtime_generation") or "")
    target_generation = str(target_runtime_generation or "")
    if target_generation != str(supervisor_runtime.runtime_generation() or ""):
        raise MissionAuthorityError("resume runtime differs from the commissioned mission runtime")
    if not previous_generation or not target_generation:
        raise MissionAuthorityError("runtime migration requires proven previous and installed generations")
    if previous_generation == target_generation:
        return None
    if (
        job_snapshot.get("repo") != str(repo)
        or job_snapshot.get("run_id") != run_id
        or job_snapshot.get("status") != "QUARANTINED"
        or any(job_snapshot.get(key) is not None for key in (
            "worker_pid", "worker_pgid", "worker_attempt_id", "worker_role",
            "worker_started_at", "worker_deadline_at", "worker_start_identity",
        ))
    ):
        raise MissionAuthorityError("runtime migration requires an unowned quarantined job")

    run_root = state.run_dir(repo, run_id)
    packet_path = run_root / "WORK_PACKET.md"
    meta, _packet_text = packet.parse_packet_file(packet_path)
    packet_errors = packet.validate_packet_for_approval(meta)
    if packet_errors:
        raise MissionAuthorityError("runtime migration packet is invalid: " + "; ".join(packet_errors))
    if meta.get("schema") != packet.MISSION_PROGRAM_SCHEMA_VERSION:
        raise MissionAuthorityError("same-segment runtime migration is only valid for a sealed v4 mission segment")
    approval_doc = approval.load_approval(repo, run_id)
    approval_ok, approval_reason = approval.validate_approval_binding(
        canonical_repo=repo, run_id=run_id, approval=approval_doc,
        packet=meta, packet_path=packet_path,
    )
    if not approval_ok:
        raise MissionAuthorityError("runtime migration approval is invalid: " + approval_reason)
    current = state.load_verified(repo, run_id)
    if not isinstance(current, dict) or transitions.is_terminal(str(current.get("state") or "")):
        raise MissionAuthorityError("runtime migration refuses terminal engineering state")
    program_state = current.get("program") or {}
    checkpoint_ids = list(program_state.get("current_checkpoints") or [])
    checkpoint_id = str(checkpoint_ids[0]) if len(checkpoint_ids) == 1 else ""
    if not checkpoint_id or checkpoint_id in {
        str(item.get("id") or "") for item in program_state.get("finalized_checkpoints") or []
        if isinstance(item, dict)
    }:
        raise MissionAuthorityError("runtime migration requires one unfinished frozen checkpoint")
    baseline_sha = str(segment.get("baseline_sha") or "")
    # A pristine sealed segment has not published a candidate yet. At that
    # exact workerless boundary the only valid candidate identity is its
    # immutable segment baseline; never treat an empty state field as a new
    # or caller-selected revision.
    candidate_sha = str(current.get("last_candidate_sha") or baseline_sha)
    branch = str(segment.get("candidate_branch") or "")
    if (
        not _FULL_SHA_RE.fullmatch(candidate_sha)
        or not _FULL_SHA_RE.fullmatch(baseline_sha)
        or not git_checks.is_valid_branch_name(branch)
        or not build_finalize._ancestor_of(repo, candidate_sha, baseline_sha)
    ):
        raise MissionAuthorityError("runtime migration candidate lineage is invalid")

    events_path = state.events_path(repo, run_id)
    events = integrity.read_event_chain(events_path)
    event_chain_sha = integrity.compute_event_chain_hash(events_path)
    if (
        not events
        or event_chain_sha != integrity.get_event_chain_hash(events_path)
        or events[-1].get("state_sha256") != util.sha256_file(state.state_path(repo, run_id))
    ):
        raise MissionAuthorityError("runtime migration state/event prefix is not authoritative")

    db = db_path or supervisor_db.default_db_path()
    with supervisor_db._managed_connect_readonly(db) as conn:
        rows = conn.execute(
            "SELECT * FROM semantic_attempts WHERE job_id=? ORDER BY started_at, attempt_id",
            (int(job_snapshot["id"]),),
        ).fetchall()
    attempts = [dict(row) for row in rows]
    if any(item.get("status") in {"RESERVED", "RUNNING"} or item.get("completed_at") is None for item in attempts):
        raise MissionAuthorityError("runtime migration refuses nonterminal semantic attempts")
    if not _runtime_migration_candidate_lineage_valid(
        repo, candidate_sha, baseline_sha, branch,
        semantic_attempt_count=len(attempts),
    ):
        raise MissionAuthorityError("runtime migration candidate lineage is invalid")
    attempt_projection = [
        {
            key: item.get(key)
            for key in (
                "attempt_id", "role", "status", "started_at", "completed_at",
                "runtime_generation", "binding_sha256", "cost_usd", "cost_known",
                "cost_accounted", "input_tokens", "output_tokens", "cache_read_tokens",
                "cache_creation_tokens", "tokens_known", "failure_class", "failure_reason",
            )
        }
        for item in attempts
    ]
    attempt_ledger_sha = _digest(attempt_projection)
    job_fields = (
        "id", "repo", "run_id", "runner", "status", "runtime_generation",
        "candidate_branch", "infra_failures", "transient_failures",
        "transient_recovery_cycles", "total_cost_usd", "total_input_tokens",
        "total_output_tokens", "total_cache_read_tokens", "total_cache_creation_tokens",
        "max_infra_failures", "max_transient_failures", "max_transient_recovery_cycles",
        "max_total_cost_usd", "max_total_tokens", "max_wall_seconds",
        "execution_started_at", "worker_pid", "worker_pgid", "worker_attempt_id",
        "worker_role", "worker_started_at", "worker_deadline_at", "worker_start_identity",
        "last_failure_class", "last_failure_reason",
    )
    source_job = {key: job_snapshot.get(key) for key in job_fields}
    source_authority = {
        "schema": "ownframework-loop-active-segment-runtime-source/v1",
        "run_id": run_id,
        "segment_number": int(segment.get("segment_number") or 0),
        "segment_authority_sha256": segment_sha,
        "packet_sha256": util.sha256_file(packet_path),
        "approval_sha256": approval.approval_artifact_sha256(approval_doc or {}),
        "state_sha256": util.sha256_file(state.state_path(repo, run_id)),
        "event_count": len(events),
        "event_chain_sha256": event_chain_sha,
        "engineering_state": str(current.get("state") or ""),
        "checkpoint_id": checkpoint_id,
        "candidate_sha": candidate_sha,
        "baseline_sha": baseline_sha,
        "build_pass_count": int(current.get("build_pass_count") or 0),
        "review_pass_count": int(current.get("review_pass_count") or 0),
        "repair_round_count": int(current.get("repair_round") or 0),
        "source_job": source_job,
        "semantic_attempt_ledger_sha256": attempt_ledger_sha,
    }

    # A crash after authority publication but before the SQLite resume is
    # replayed only when the entire original boundary is still byte-identical.
    active_runtime, active_identity_sha, active_sequence = _active_mission_runtime(repo, mission_doc)
    if str(active_runtime.get("runtime_generation") or "") == target_generation:
        if active_sequence <= 0:
            raise MissionAuthorityError("runtime target lacks an append-only migration record")
        existing, existing_sha = _read_runtime_migration_record(
            _mission_runtime_migration_path(repo, mission_id, active_sequence),
        )
        if (
            existing.get("schema") != MISSION_RUNTIME_MIGRATION_V2_SCHEMA
            or existing.get("migration_kind") != "active_segment_resume"
            or existing.get("runtime_generation") != target_generation
            or existing.get("previous_runtime_generation") != previous_generation
            or existing.get("source_authority") != source_authority
            or existing.get("previous_runtime_identity_sha256")
            != _runtime_identity_before_active_migration(repo, mission_id, active_sequence)
        ):
            raise MissionAuthorityError("existing runtime migration conflicts with this resume boundary")
        _verify_runtime_migration_source(repo, existing)
        return {
            "sequence": active_sequence,
            "sha256": existing_sha,
            "runtime_generation": target_generation,
        }
    if str(active_runtime.get("runtime_generation") or "") != previous_generation:
        raise MissionAuthorityError("active mission runtime differs from the quarantined job generation")

    # Runtime migration may reuse only an existing run capability identity.
    # It never creates or refreshes capability evidence as a side effect.
    from . import capability_binding

    runner = str((mission_doc.get("operational_budget") or {}).get("runner") or "")
    if runner != str(job_snapshot.get("runner") or ""):
        raise MissionAuthorityError("runtime migration runner differs from frozen mission identity")
    profile = runner_profiles.resolve_profile(
        str(meta.get("runner_profile") or "default"), provider=runner,
    )
    runner_profiles.verify_profile_integrity(profile)
    attestation = runner_profiles.verify_effort_attestation(profile)
    if attestation is not None:
        profile = dict(profile)
        profile["effort_attestation"] = attestation
    binding_path = capability_binding.binding_path(repo, run_id)
    if not binding_path.is_file() or binding_path.is_symlink():
        raise MissionAuthorityError("runtime migration requires an existing run capability binding")
    binding = capability_binding._read(binding_path)
    bound_identity = bind_runtime_identity(
        repo, run_id, run_binding=binding, runner_profile=profile,
        runtime_generation=previous_generation,
    )
    if not isinstance(bound_identity, dict) or bound_identity.get("runtime_generation") != previous_generation:
        raise MissionAuthorityError("prior runtime binding could not be proven before migration")
    previous, previous_sha, previous_sequence = _active_mission_runtime(repo, mission_doc)
    if (
        previous.get("runtime_generation") != previous_generation
        or (previous_sequence > 0 and not _mission_runtime_binding_path(
            repo, mission_id, previous_sequence,
        ).is_file())
    ):
        raise MissionAuthorityError("prior mission runtime identity is not durably bound")

    _verified_mission_spend(
        repo, mission_doc, current_run_id=run_id, db_path=db,
        target_runtime_generation=target_generation,
        runtime_migration_from_generation=previous_generation,
        allow_quarantined_current=True,
    )
    sequence = previous_sequence + 1
    migration_payload = {
        "schema": MISSION_RUNTIME_MIGRATION_V2_SCHEMA,
        "mission_id": mission_id,
        "sequence": sequence,
        "migration_kind": "active_segment_resume",
        "previous_runtime_identity_sha256": previous_sha,
        "previous_runtime_generation": previous_generation,
        "runtime_generation": target_generation,
        "runner": runner,
        "capabilities": copy.deepcopy(previous.get("capabilities") or []),
        "runner_profile": copy.deepcopy(previous.get("runner_profile") or {}),
        "source_authority": source_authority,
        "reason": "supported workerless runtime-generation maintenance",
        "created_at": util.utc_now_iso(),
    }
    digest = _write_once(
        _mission_runtime_migration_path(repo, mission_id, sequence), migration_payload,
    )
    return {
        "sequence": sequence,
        "sha256": digest,
        "runtime_generation": target_generation,
    }

def _runtime_identity_before_active_migration(
    repo: Path,
    mission_id: str,
    sequence: int,
) -> str:
    """Return the identity digest named by a prepared active-segment migration."""
    if sequence <= 1:
        identity, identity_sha = _read_record(
            _mission_runtime_path(repo, mission_id),
            expected_schema=MISSION_RUNTIME_SCHEMA,
        )
        if not identity_sha:
            raise MissionAuthorityError("prior mission runtime identity is missing")
        return identity_sha
    mission_doc, _ = _read_record(
        _manifest_path(repo, mission_id), expected_schema=MISSION_SCHEMA,
    )
    _identity, identity_sha, resolved_sequence = _active_mission_runtime(
        repo, mission_doc, through_sequence=sequence - 1,
    )
    if resolved_sequence != sequence - 1:
        raise MissionAuthorityError("prior runtime migration prefix is incomplete")
    return identity_sha
