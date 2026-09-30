"""Durable mission authority and bounded PROGRAM segment derivation.

v4 PROGRAMs separate immutable mission authority from one-run execution
segments.  This module is the single owner of the private, create-once mission
records; state transitions, packet validation, and supervisor enrollment remain
owned by their existing typed modules.
"""
from __future__ import annotations

import copy
import hashlib
import json
import math
import os
import re
import tempfile
import time
from pathlib import Path
from typing import Any

from . import (
    approval,
    build_finalize,
    git_checks,
    integrity,
    packet,
    program,
    program_rollover,
    runner_profiles,
    supervisor_runtime,
    state,
    supervisor_db,
    transitions,
    util,
    worktrees,
)
from .locking import flock_exclusive

MISSION_SCHEMA = "ownframework-loop-program-mission/v1"
SEGMENT_SCHEMA = "ownframework-loop-program-segment/v1"
SEGMENT_STATE_SCHEMA = "ownframework-loop-mission-segment-state/v1"
MISSION_RUNTIME_SCHEMA = "ownframework-loop-program-mission-runtime/v1"
MISSION_RUNTIME_MIGRATION_SCHEMA = "ownframework-loop-program-mission-runtime-migration/v1"
MISSION_RUNTIME_MIGRATION_V2_SCHEMA = "ownframework-loop-program-mission-runtime-migration/v2"
MISSION_RUNTIME_BINDING_SCHEMA = "ownframework-loop-program-mission-runtime-binding/v1"
LEGACY_ADMISSION_SCHEMA = "ownframework-loop-legacy-continuation-admission/v1"
_FULL_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


class MissionAuthorityError(RuntimeError):
    """A mission or segment authority could not be proven without widening."""


def _mission_root(repo: Path) -> Path:
    return Path(repo) / ".ownframework-loop" / "missions"


def _mission_dir(repo: Path, mission_id: str) -> Path:
    if not re.fullmatch(r"mission-[a-f0-9]{24}", str(mission_id or "")):
        raise MissionAuthorityError("mission id is not canonical")
    return _mission_root(repo) / mission_id


def _manifest_path(repo: Path, mission_id: str) -> Path:
    return _mission_dir(repo, mission_id) / "MISSION.json"


def _segment_path(repo: Path, mission_id: str, number: int) -> Path:
    if not isinstance(number, int) or isinstance(number, bool) or not 1 <= number <= 16:
        raise MissionAuthorityError("segment number is outside the executable envelope")
    return _mission_dir(repo, mission_id) / f"SEGMENT-{number:02d}.json"


def _mission_runtime_path(repo: Path, mission_id: str) -> Path:
    return _mission_dir(repo, mission_id) / "MISSION-RUNTIME.json"


def _mission_runtime_migration_path(repo: Path, mission_id: str, sequence: int) -> Path:
    if not isinstance(sequence, int) or isinstance(sequence, bool) or not 1 <= sequence <= 16:
        raise MissionAuthorityError("mission runtime migration sequence is outside the envelope")
    return _mission_dir(repo, mission_id) / f"MISSION-RUNTIME-MIGRATION-{sequence:02d}.json"


def _mission_runtime_binding_path(repo: Path, mission_id: str, sequence: int) -> Path:
    if not isinstance(sequence, int) or isinstance(sequence, bool) or not 1 <= sequence <= 16:
        raise MissionAuthorityError("mission runtime binding sequence is outside the envelope")
    return _mission_dir(repo, mission_id) / f"MISSION-RUNTIME-BINDING-{sequence:02d}.json"


def _canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, indent=2, ensure_ascii=True) + "\n").encode("ascii")


def _digest(value: Any) -> str:
    return hashlib.sha256(_canonical_bytes(value)).hexdigest()


def _envelope(payload: dict[str, Any]) -> tuple[dict[str, Any], str]:
    digest = _digest(payload)
    return {"payload": payload, "sha256": digest}, digest


def _atomic_publish_once(path: Path, raw: bytes) -> None:
    """Publish exact bytes atomically without replacing a conflicting artifact."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        parent_resolved = path.parent.resolve(strict=True)
    except OSError as exc:
        raise MissionAuthorityError("mission authority parent is not resolvable") from exc
    if parent_resolved != path.parent or path.parent.is_symlink() or path.is_symlink():
        raise MissionAuthorityError(f"mission authority path is a symlink: {path}")
    if path.exists():
        if not path.is_file() or path.read_bytes() != raw or path.stat().st_mode & 0o077:
            raise MissionAuthorityError(f"create-once authority conflicts: {path.name}")
        return
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    temp = Path(temp_name)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(temp, path)
        except FileExistsError:
            if (
                path.is_symlink() or not path.is_file() or path.read_bytes() != raw
                or path.stat().st_mode & 0o077
            ):
                raise MissionAuthorityError(f"concurrent authority publication conflicts: {path.name}")
        util.fsync_dir(path.parent)
    finally:
        try:
            temp.unlink()
        except OSError:
            pass


def _write_once(path: Path, value: dict[str, Any]) -> str:
    """Atomically publish private create-once JSON; replay accepts identical bytes only."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        parent_resolved = path.parent.resolve(strict=True)
    except OSError as exc:
        raise MissionAuthorityError("mission authority parent is not resolvable") from exc
    if parent_resolved != path.parent or path.parent.is_symlink() or path.is_symlink():
        raise MissionAuthorityError(f"mission authority path is a symlink: {path}")
    envelope, digest = _envelope(value)
    raw = _canonical_bytes(envelope)
    if path.exists():
        if not path.is_file() or path.read_bytes() != raw:
            raise MissionAuthorityError(f"create-once mission authority conflicts: {path.name}")
        if path.stat().st_mode & 0o077:
            raise MissionAuthorityError(f"mission authority permissions are too broad: {path.name}")
        return digest

    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    temp = Path(temp_name)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(temp, path)
        except FileExistsError:
            if not path.is_file() or path.is_symlink() or path.read_bytes() != raw:
                raise MissionAuthorityError(f"create-once mission authority conflicts: {path.name}")
        util.fsync_dir(path.parent)
    finally:
        try:
            temp.unlink()
        except OSError:
            pass
    return digest


def _read_record(path: Path, *, expected_schema: str) -> tuple[dict[str, Any], str]:
    try:
        parent_resolved = path.parent.resolve(strict=True)
    except OSError as exc:
        raise MissionAuthorityError(f"mission authority parent is not resolvable: {path.name}") from exc
    if parent_resolved != path.parent or path.is_symlink() or not path.is_file():
        raise MissionAuthorityError(f"mission authority record missing or unsafe: {path.name}")
    if path.stat().st_mode & 0o077:
        raise MissionAuthorityError(f"mission authority record permissions are too broad: {path.name}")
    try:
        envelope = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise MissionAuthorityError(f"mission authority record is unreadable: {path.name}") from exc
    payload = envelope.get("payload") if isinstance(envelope, dict) else None
    digest = envelope.get("sha256") if isinstance(envelope, dict) else None
    if (
        not isinstance(payload, dict)
        or not isinstance(digest, str)
        or not _SHA256_RE.fullmatch(digest)
        or _digest(payload) != digest
        or payload.get("schema") != expected_schema
    ):
        raise MissionAuthorityError(f"mission authority record digest/schema invalid: {path.name}")
    return payload, digest


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
            or (segment.get("source_admission") or {}).get("kind")
                != "blocked_semantic_budget_continuation"
            or (segment.get("source_admission") or {}).get("crossing_candidate_not_adopted") is not True
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
            or not _FULL_SHA_RE.fullmatch(str(source.get("candidate_sha") or ""))
            or not _FULL_SHA_RE.fullmatch(str(source.get("baseline_sha") or ""))
            or source.get("baseline_sha") != segment.get("baseline_sha")
            or not build_finalize._ancestor_of(repo, str(source.get("candidate_sha") or ""), str(source.get("baseline_sha") or ""))
            or not build_finalize._candidate_branch_contains(
                repo, str(segment.get("candidate_branch") or ""), str(source.get("candidate_sha") or ""),
            )
            or not str(source.get("checkpoint_id") or "")
            or not _SHA256_RE.fullmatch(str(source.get("semantic_attempt_ledger_sha256") or ""))
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


def _authority_projection(meta: dict[str, Any]) -> dict[str, Any]:
    """Remove only run-identity fields that a typed successor must derive."""
    projected = copy.deepcopy(meta)
    for key in ("packet_id", "created_at"):
        projected.pop(key, None)
    target = projected.get("target")
    if isinstance(target, dict):
        for key in ("branch", "expected_baseline_sha", "candidate_branch_prefix"):
            target.pop(key, None)
    return projected


def _segment_authority_projection(
    meta: dict[str, Any], source_admission: dict[str, Any],
) -> dict[str, Any]:
    """Project immutable mission authority with only its typed policy overlay."""
    projected = _authority_projection(meta)
    overlay = source_admission.get("semantic_budget_policy_overlay")
    if overlay is not None:
        if source_admission.get("kind") != "blocked_semantic_budget_continuation":
            raise MissionAuthorityError("unrecognized semantic budget overlay authority")
        mission_budget = projected.get("mission_budget")
        if not isinstance(overlay, dict) or not isinstance(mission_budget, dict):
            raise MissionAuthorityError("semantic budget overlay is malformed")
        if mission_budget.get("semantic_budget_policy") != overlay:
            raise MissionAuthorityError("packet semantic budget policy differs from segment admission")
        mission_budget.pop("semantic_budget_policy", None)
    return projected


def _mission_state_projection(
    *,
    mission_id: str,
    segment_number: int,
    predecessor_run_id: str | None,
    mission_authority_sha256: str,
    segment_authority_sha256: str,
    original_baseline_sha: str,
    segment_baseline_sha: str,
    mission_source_lines_at_start: int,
) -> dict[str, Any]:
    return {
        "schema": SEGMENT_STATE_SCHEMA,
        "mission_id": mission_id,
        "segment_number": segment_number,
        "predecessor_run_id": predecessor_run_id,
        "mission_authority_sha256": mission_authority_sha256,
        "segment_authority_sha256": segment_authority_sha256,
        "mission_original_baseline_sha": original_baseline_sha,
        "segment_baseline_sha": segment_baseline_sha,
        "mission_source_lines_at_start": mission_source_lines_at_start,
    }


def _authority_id(run_id: str, packet_sha256: str, baseline_sha: str, approval_sha256: str) -> str:
    seed = "\0".join((run_id, packet_sha256, baseline_sha, approval_sha256)).encode("utf-8")
    return "mission-" + hashlib.sha256(seed).hexdigest()[:24]


def _mission_unique_file_ceiling(meta: dict[str, Any], program_state: dict[str, Any]) -> int:
    """Freeze the strictest original unique-file authority for the whole mission."""
    program_cap = int(
        (program_state.get("cumulative_ceilings") or {}).get("max_unique_changed_files")
        or program.GLOBAL_MAX_UNIQUE_CHANGED_FILES
    )
    packet_cap = int(
        (((meta.get("checkpoint_graph") or {}).get("global_source_ceilings") or {})
         .get("max_unique_changed_files") or program.GLOBAL_MAX_UNIQUE_CHANGED_FILES)
    )
    risk_cap = int((meta.get("risk_budget") or {}).get("max_files_changed") or 0)
    declared = [
        value for value in (
            program_cap, packet_cap, risk_cap, program.GLOBAL_MAX_UNIQUE_CHANGED_FILES,
        ) if value > 0
    ]
    return min(declared) if declared else program.GLOBAL_MAX_UNIQUE_CHANGED_FILES


def initial_segment_waiting_for_enrollment(
    canonical_repo: Path,
    run_id: str,
    *,
    seal: dict[str, Any] | None = None,
    db_path: Path | None = None,
    allow_queued_enrollment: bool = False,
) -> bool:
    """Recognize only a pristine v4 start whose supervisor row is not created yet.

    The normal lifecycle seals/approves before enqueue. Operational mission
    authority cannot be frozen until enqueue supplies the runner/runtime
    envelope, so execution-start defers segment materialization in this one
    narrow pre-enrollment state. A bound segment, existing job, non-v4 packet,
    or progressed state is never treated as deferred.
    """
    repo = Path(canonical_repo).resolve(strict=False)
    root = state.run_dir(repo, run_id)
    packet_path = root / "WORK_PACKET.md"
    if not packet_path.is_file():
        return False
    try:
        meta, _ = packet.parse_packet_file(packet_path)
        current = state.load_verified(repo, run_id)
    except Exception:
        return False
    job = _job_snapshot_if_present(repo, run_id, db_path=db_path)
    job_is_safe_queue = bool(
        allow_queued_enrollment
        and isinstance(job, dict)
        and str(job.get("status") or "") == "QUEUED"
        and not any(job.get(key) is not None for key in (
            "worker_pid", "worker_pgid", "worker_attempt_id", "worker_role",
        ))
    )
    if (
        meta.get("schema") != packet.MISSION_PROGRAM_SCHEMA_VERSION
        or not packet.packet_is_program(meta)
        or not isinstance(current, dict)
        or current.get("state") not in {"AWAITING_APPROVAL", "READY_TO_START", "READY_TO_BUILD"}
        or isinstance(((current.get("program") or {}).get("mission_segment")), dict)
        or (job is not None and not job_is_safe_queue)
    ):
        return False
    if seal is not None:
        if (
            seal.get("run_id") != run_id
            or seal.get("packet_sha256") != util.sha256_file(packet_path)
            or not _FULL_SHA_RE.fullmatch(str(seal.get("baseline_sha") or ""))
        ):
            return False
        mission_id = _authority_id(
            run_id,
            str(seal["packet_sha256"]),
            str(seal["baseline_sha"]),
            approval.approval_artifact_sha256(seal),
        )
        mission_root = _mission_dir(repo, mission_id)
        if any(path.exists() for path in (
            _manifest_path(repo, mission_id),
            _segment_path(repo, mission_id, 1),
            _mission_runtime_path(repo, mission_id),
        )):
            return False
    return True


def _segment_doc(
    *,
    mission_id: str,
    number: int,
    run_id: str,
    predecessor_run_id: str | None,
    packet_sha256: str,
    baseline_sha: str,
    baseline_branch: str,
    candidate_branch: str,
    mission_authority_sha256: str,
    authority_projection_sha256: str,
    mission_source_lines_at_start: int,
    source_admission: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return {
        "schema": SEGMENT_SCHEMA,
        "mission_id": mission_id,
        "segment_number": number,
        "run_id": run_id,
        "predecessor_run_id": predecessor_run_id,
        "packet_sha256": packet_sha256,
        "baseline_sha": baseline_sha,
        "baseline_branch": baseline_branch,
        "candidate_branch": candidate_branch,
        "mission_authority_sha256": mission_authority_sha256,
        "authority_projection_sha256": authority_projection_sha256,
        "mission_source_lines_at_start": mission_source_lines_at_start,
        "source_admission": copy.deepcopy(source_admission or {"kind": "sealed_v4_initial"}),
    }


def _mission_segment_binding(segment_payload: dict[str, Any], segment_sha: str) -> dict[str, Any]:
    return _mission_state_projection(
        mission_id=str(segment_payload["mission_id"]),
        segment_number=int(segment_payload["segment_number"]),
        predecessor_run_id=segment_payload.get("predecessor_run_id"),
        mission_authority_sha256=str(segment_payload["mission_authority_sha256"]),
        segment_authority_sha256=segment_sha,
        original_baseline_sha=str(segment_payload["source_admission"].get("mission_original_baseline_sha")
                                 or segment_payload["baseline_sha"]),
        segment_baseline_sha=str(segment_payload["baseline_sha"]),
        mission_source_lines_at_start=int(segment_payload["mission_source_lines_at_start"]),
    )


def ensure_initial_segment(
    canonical_repo: Path,
    run_id: str,
    *,
    meta: dict[str, Any],
    seal: dict[str, Any],
) -> dict[str, Any]:
    """Create or verify the first v4 mission/segment after normal sealing."""
    repo = Path(canonical_repo).resolve(strict=False)
    if meta.get("schema") != packet.MISSION_PROGRAM_SCHEMA_VERSION:
        return {"ok": True, "mission": False}
    errors = packet.validate_packet_for_approval(meta)
    if errors:
        raise MissionAuthorityError("v4 packet failed admission validation: " + "; ".join(errors[:10]))
    if seal.get("run_id") != run_id or seal.get("packet_sha256") != util.sha256_file(state.run_dir(repo, run_id) / "WORK_PACKET.md"):
        raise MissionAuthorityError("first-segment seal does not bind current run packet")
    baseline = str(seal.get("baseline_sha") or "")
    if not _FULL_SHA_RE.fullmatch(baseline):
        raise MissionAuthorityError("first-segment sealed baseline is not a full Git SHA")
    packet_sha = str(seal["packet_sha256"])
    approval_sha = approval.approval_artifact_sha256(seal)
    job = _job_snapshot_if_present(repo, run_id)
    if not isinstance(job, dict) or str(job.get("status") or "") not in {"QUEUED", "RUNNING"}:
        raise MissionAuthorityError(
            "v4 mission authority requires one live supervisor enrollment before execution"
        )
    if int(job.get("legacy_budget_ambiguous") or 0) != 0:
        raise MissionAuthorityError("v4 mission cannot bind an ambiguous operational budget")
    if (
        str(job.get("runner") or "") == ""
        or str(job.get("runtime_generation") or "") == ""
        or str(job.get("candidate_branch") or "") != str(seal.get("candidate_branch") or "")
    ):
        raise MissionAuthorityError("initial supervisor identity differs from the execution seal")
    operational_budget = {
        "runner": str(job["runner"]),
        "runtime_generation": str(job["runtime_generation"]),
        "max_infra_failures": int(job.get("max_infra_failures") or 0),
        "max_transient_failures": int(job.get("max_transient_failures") or 0),
        "max_transient_recovery_cycles": int(job.get("max_transient_recovery_cycles") or 0),
        "max_total_cost_usd": float(job.get("max_total_cost_usd") or 0.0),
        "max_total_tokens": int(job.get("max_total_tokens") or 0),
        "max_wall_seconds": int(job.get("max_wall_seconds") or 0),
    }
    mission_id = _authority_id(run_id, packet_sha, baseline, approval_sha)
    root = _mission_dir(repo, mission_id)
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = root / "MISSION.lock"
    with flock_exclusive(lock):
        projection_sha = _digest(_authority_projection(meta))
        budget = copy.deepcopy(meta["mission_budget"])
        authority = {
            "schema": MISSION_SCHEMA,
            "mission_id": mission_id,
            "source_run_id": run_id,
            "source_packet_sha256": packet_sha,
            "source_approval_sha256": approval_sha,
            "mission_original_baseline_sha": baseline,
            "mission_max_diff_lines": int(budget["mission_max_diff_lines"]),
            "mission_max_unique_changed_files": _mission_unique_file_ceiling(
                meta, (state.load_verified(repo, run_id) or {}).get("program") or {},
            ),
            "segment_max_diff_lines": int(budget["segment_max_diff_lines"]),
            "auto_segment": bool(budget["auto_segment"]),
            "max_segments": int(budget["max_segments"]),
            "segment_boundary_policy": budget["segment_boundary_policy"],
            "operational_budget": operational_budget,
            "operational_source_run_ids": [],
            "authority_projection_sha256": projection_sha,
            "template_meta": copy.deepcopy(meta),
            "template_markdown_tail": _markdown_tail(state.run_dir(repo, run_id) / "WORK_PACKET.md"),
        }
        mission_sha = _write_once(_manifest_path(repo, mission_id), authority)
        segment_payload = _segment_doc(
            mission_id=mission_id,
            number=1,
            run_id=run_id,
            predecessor_run_id=None,
            packet_sha256=packet_sha,
            baseline_sha=baseline,
            baseline_branch=str(seal.get("baseline_branch") or ""),
            candidate_branch=str(seal.get("candidate_branch") or ""),
            mission_authority_sha256=mission_sha,
            authority_projection_sha256=projection_sha,
            mission_source_lines_at_start=0,
            source_admission={"kind": "sealed_v4_initial", "mission_original_baseline_sha": baseline},
        )
        segment_sha = _write_once(_segment_path(repo, mission_id, 1), segment_payload)
        binding = _mission_segment_binding(segment_payload, segment_sha)
        state.bind_mission_segment(repo, run_id, mission_segment=binding)
        return {
            "ok": True,
            "mission": True,
            "mission_id": mission_id,
            "segment_number": 1,
            "mission_authority_sha256": mission_sha,
            "segment_authority_sha256": segment_sha,
        }


def initialize_queued_initial_segments(*, db_path: Path | None = None) -> dict[str, Any]:
    """Bind pristine sealed v4 PROGRAMs after durable enqueue, before claim.

    Human approval/sealing normally precedes supervisor enrollment, so the
    first call to ``execution_start.ensure_executable`` may legitimately defer
    mission creation until the operational runner/runtime envelope exists.
    The scheduler calls this replay-safe pre-claim hook once that queue row is
    durable. It must run before dispatch claims a BUILD pass, otherwise a v4
    run could consume engineering authority before its mission identity is
    sealed.
    """
    db = db_path or supervisor_db.default_db_path()
    with supervisor_db._managed_connect_readonly(db) as conn:
        rows = conn.execute(
            """SELECT id, repo, run_id, status, execution_mode,
                      worker_pid, worker_pgid, worker_attempt_id, worker_role
                 FROM jobs WHERE status='QUEUED' ORDER BY next_attempt_at, id"""
        ).fetchall()

    initialized: list[dict[str, Any]] = []
    errors: list[dict[str, Any]] = []
    for row in rows:
        if str(row["execution_mode"] or "").upper() != "PROGRAM":
            continue
        if any(row[key] is not None for key in (
            "worker_pid", "worker_pgid", "worker_attempt_id", "worker_role",
        )):
            continue
        repo = Path(str(row["repo"])).resolve(strict=False)
        run_id = str(row["run_id"])
        packet_path = state.run_dir(repo, run_id) / "WORK_PACKET.md"
        try:
            meta, _ = packet.parse_packet_file(packet_path)
            if meta.get("schema") != packet.MISSION_PROGRAM_SCHEMA_VERSION:
                continue
            current = state.load_verified(repo, run_id)
            if not isinstance(current, dict):
                continue
            binding = ((current.get("program") or {}).get("mission_segment"))
            if isinstance(binding, dict):
                load_segment(repo, run_id, state_snapshot=current)
                continue
            # A v4 packet may be durably queued before a human has completed
            # its ordinary approval/seal. Do not turn that into scheduler
            # authority or attempt a synthetic seal here.
            if current.get("state") not in {"READY_TO_BUILD", "READY_TO_START"}:
                continue
            seal = approval.load_approval(repo, run_id)
            if not isinstance(seal, dict):
                if current.get("state") == "READY_TO_BUILD":
                    raise MissionAuthorityError(
                        "queued v4 PROGRAM is ready to build but has no execution seal"
                    )
                continue
            if not initial_segment_waiting_for_enrollment(
                repo, run_id, seal=seal, db_path=db, allow_queued_enrollment=True,
            ):
                raise MissionAuthorityError(
                    "queued v4 PROGRAM is not a pristine sealed first-segment candidate"
                )
            from . import execution_start

            execution_start.ensure_executable(
                canonical_repo=repo,
                run_id=run_id,
                actor="ofloop-supervisor",
                binding_method="build_start",
            )
            loaded = load_segment(repo, run_id)
            if loaded is None:
                raise MissionAuthorityError("scheduler could not bind the initial v4 mission segment")
            initialized.append({"job_id": int(row["id"]), "run_id": run_id})
        except Exception as exc:
            # Never claim a semantic pass after mission setup could not be
            # proven. The caller terminally quarantines this queued row using
            # the normal supervisor ledger transition, with no pass/cost
            # reservation and a bounded diagnostic.
            errors.append({
                "job_id": int(row["id"]),
                "run_id": run_id,
                "error_class": type(exc).__name__,
            })
    return {"ok": not errors, "initialized": initialized, "errors": errors}


def _markdown_tail(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    match = re.search(r"```json\s*\n.*?\n```", text, re.DOTALL)
    if not match:
        raise MissionAuthorityError("packet metadata block missing while binding mission")
    return text[match.end():]


def load_segment(
    repo: Path,
    run_id: str,
    *,
    state_snapshot: dict[str, Any] | None = None,
) -> tuple[dict[str, Any], str, dict[str, Any], str] | None:
    """Return verified segment and mission records for one run, if v4-bound."""
    repo = Path(repo).resolve(strict=False)
    run_root = state.run_dir(repo, run_id)
    packet_path = run_root / "WORK_PACKET.md"
    if not packet_path.is_file():
        return None
    meta, _ = packet.parse_packet_file(packet_path)
    if meta.get("schema") != packet.MISSION_PROGRAM_SCHEMA_VERSION:
        return None
    current = state_snapshot if state_snapshot is not None else state.load_verified(repo, run_id)
    program_state = (current or {}).get("program") or {}
    binding = program_state.get("mission_segment")
    if not isinstance(binding, dict):
        raise MissionAuthorityError("v4 PROGRAM state has no core-bound mission identity")
    mission_id = str(binding.get("mission_id") or "")
    number = int(binding.get("segment_number") or 0)
    segment, segment_sha = _read_record(_segment_path(repo, mission_id, number), expected_schema=SEGMENT_SCHEMA)
    mission, mission_sha = _read_record(_manifest_path(repo, mission_id), expected_schema=MISSION_SCHEMA)
    expected_binding = _mission_segment_binding(segment, segment_sha)
    source_admission = segment.get("source_admission") or {}
    projected_meta = _segment_authority_projection(meta, source_admission)
    if (
        binding != expected_binding
        or segment.get("run_id") != run_id
        or segment.get("mission_authority_sha256") != mission_sha
        or segment.get("packet_sha256") != util.sha256_file(packet_path)
        or segment.get("authority_projection_sha256") != _digest(projected_meta)
        or mission.get("mission_id") != mission_id
        or mission.get("authority_projection_sha256") != _digest(projected_meta)
        or int(meta.get("mission_budget", {}).get("segment_max_diff_lines") or 0) != int(mission.get("segment_max_diff_lines") or 0)
        or int(meta.get("mission_budget", {}).get("mission_max_diff_lines") or 0) != int(mission.get("mission_max_diff_lines") or 0)
        or int(mission.get("mission_max_unique_changed_files") or 0) <= 0
        or int(meta.get("mission_budget", {}).get("max_segments") or 0) != int(mission.get("max_segments") or 0)
        or bool(meta.get("mission_budget", {}).get("auto_segment")) != bool(mission.get("auto_segment"))
    ):
        raise MissionAuthorityError("v4 packet/state does not match immutable mission segment authority")
    graph_ok, graph_reason = program.verify_frozen_graph(meta, program_state)
    if not graph_ok:
        raise MissionAuthorityError("v4 segment frozen PROGRAM authority is invalid: " + graph_reason)
    migration_ref = _runtime_migration_ref(segment)
    if migration_ref is not None:
        migrated_runtime, _ = _runtime_identity_for_segment(repo, mission_id, segment)
        if (
            sorted(str(value) for value in (meta.get("capabilities") or []))
            != migrated_runtime.get("capabilities")
            or str(meta.get("runner_profile") or "")
            != str((migrated_runtime.get("runner_profile") or {}).get("name") or "")
        ):
            raise MissionAuthorityError(
                "migrated segment packet changes the sealed capability/profile request"
            )
    if source_admission.get("kind") == "blocked_semantic_budget_continuation":
        _verify_semantic_budget_reconciliation(
            repo, segment=segment, program_state=program_state,
        )
    return segment, segment_sha, mission, mission_sha


def verify_segment_approval(
    canonical_repo: Path,
    run_id: str,
    *,
    approval_doc: dict[str, Any],
) -> tuple[bool, str]:
    """Verify a core-derived child seal; ordinary human seals are handled normally."""
    try:
        loaded = load_segment(canonical_repo, run_id)
        if loaded is None:
            return False, "mission segment packet/state is not bound"
        segment, segment_sha, mission_doc, mission_sha = loaded
        expected = {
            "schema": "ownframework-loop-mission-segment-approval/v1",
            "mission_id": segment["mission_id"],
            "segment_number": segment["segment_number"],
            "predecessor_run_id": segment.get("predecessor_run_id"),
            "mission_authority_sha256": mission_sha,
            "segment_authority_sha256": segment_sha,
        }
        if (
            approval_doc.get("approval_method") != "mission_segment"
            or approval_doc.get("mission_segment") != expected
            or approval_doc.get("run_id") != run_id
            or approval_doc.get("packet_sha256") != segment.get("packet_sha256")
            or approval_doc.get("baseline_sha") != segment.get("baseline_sha")
            or approval_doc.get("baseline_branch") != segment.get("baseline_branch")
            or approval_doc.get("candidate_branch") != segment.get("candidate_branch")
            or approval_doc.get("mission_origin_approval_sha256")
            != mission_doc.get("source_approval_sha256")
        ):
            return False, "mission-derived approval does not bind exact segment authority"
        return True, "ok"
    except Exception as exc:
        return False, f"mission-derived approval verification failed: {type(exc).__name__}: {exc}"


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


def prepare_runtime_generation_resume(
    canonical_repo: Path,
    run_id: str,
    *,
    job_snapshot: dict[str, Any],
    target_runtime_generation: str,
    db_path: Path | None = None,
) -> dict[str, Any] | None:
    """Append an exact, replayable runtime rebind for a typed continuation.

    The supervisor ledger remains the owner of QUARANTINED -> QUEUED. This
    function accepts only a segment admitted by the explicit blocked
    semantic-budget continuation path, then binds the migration to its
    unchanged packet, segment, state/event prefix, candidate, job row, and
    completed attempt ledger. Ordinary automatic segmentation never authorizes
    a mid-mission runtime change. A crash before the ledger update reuses only
    that exact record.
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
        raise MissionAuthorityError("same-segment runtime migration requires an unowned quarantined job")

    run_root = state.run_dir(repo, run_id)
    packet_path = run_root / "WORK_PACKET.md"
    meta, _packet_text = packet.parse_packet_file(packet_path)
    packet_errors = packet.validate_packet_for_approval(meta)
    if packet_errors:
        raise MissionAuthorityError("runtime migration packet is invalid: " + "; ".join(packet_errors))
    if meta.get("schema") != packet.MISSION_PROGRAM_SCHEMA_VERSION:
        raise MissionAuthorityError("same-segment runtime migration is only valid for a sealed v4 mission segment")
    admission = segment.get("source_admission") or {}
    if (
        admission.get("kind") != "blocked_semantic_budget_continuation"
        or admission.get("crossing_candidate_not_adopted") is not True
        or not _FULL_SHA_RE.fullmatch(str(admission.get("crossing_candidate_sha") or ""))
    ):
        raise MissionAuthorityError(
            "same-segment runtime migration is restricted to an explicit blocked semantic-budget continuation"
        )
    approval_doc = approval.load_approval(repo, run_id)
    approval_ok, approval_reason = approval.validate_approval_binding(
        canonical_repo=repo, run_id=run_id, approval=approval_doc,
        packet=meta, packet_path=packet_path,
    )
    if not approval_ok:
        raise MissionAuthorityError("runtime migration approval is invalid: " + approval_reason)
    current = state.load_verified(repo, run_id)
    if not isinstance(current, dict) or transitions.is_terminal(str(current.get("state") or "")):
        raise MissionAuthorityError("same-segment runtime migration refuses terminal engineering state")
    program_state = current.get("program") or {}
    checkpoint_ids = list(program_state.get("current_checkpoints") or [])
    checkpoint_id = str(checkpoint_ids[0]) if len(checkpoint_ids) == 1 else ""
    if not checkpoint_id or checkpoint_id in {
        str(item.get("id") or "") for item in program_state.get("finalized_checkpoints") or []
        if isinstance(item, dict)
    }:
        raise MissionAuthorityError("runtime migration requires one unfinished frozen checkpoint")
    candidate_sha = str(current.get("last_candidate_sha") or "")
    baseline_sha = str(segment.get("baseline_sha") or "")
    branch = str(segment.get("candidate_branch") or "")
    if (
        not _FULL_SHA_RE.fullmatch(candidate_sha)
        or not _FULL_SHA_RE.fullmatch(baseline_sha)
        or not branch
        or not build_finalize._ancestor_of(repo, candidate_sha, baseline_sha)
        or not build_finalize._candidate_branch_contains(repo, branch, candidate_sha)
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

    # Establish the prior segment binding from its existing run capability
    # document before extending the mission runtime chain. This writes only a
    # create-once binding receipt; it does not change the run's capability
    # binding, packet, state, counters, or supervisor ledger.
    from . import capability_binding

    binding = capability_binding._read(capability_binding.binding_path(repo, run_id))
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
        "reason": "explicit supported resume of a quarantined workerless mission segment",
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


def _publish_runtime_migration(
    repo: Path,
    *,
    mission_doc: dict[str, Any],
    source_segment: dict[str, Any],
    source_state: dict[str, Any],
    source_packet_sha256: str,
    source_event_chain_sha256: str,
    approved_checkpoint_id: str,
    approved_candidate_sha: str,
    crossing_candidate_sha: str,
) -> dict[str, Any] | None:
    """Publish an append-only runtime rebind for a typed successor boundary."""
    from . import supervisor_runtime

    mission_id = str(mission_doc.get("mission_id") or "")
    previous, previous_sha, previous_sequence = _active_mission_runtime(repo, mission_doc)
    target_generation = str(supervisor_runtime.runtime_generation() or "")
    if not target_generation:
        raise MissionAuthorityError("installed supervisor runtime generation is unavailable")
    if target_generation == str(previous.get("runtime_generation") or ""):
        if previous_sequence == 0:
            return None
        # A crash may occur after the append-only migration record is
        # published but before the child segment is materialized. Reuse that
        # exact authorization on replay; never append a second migration or
        # silently fall back to the original generation.
        migration, migration_sha = _read_runtime_migration_record(
            _mission_runtime_migration_path(repo, mission_id, previous_sequence),
        )
        if migration.get("schema") == MISSION_RUNTIME_MIGRATION_V2_SCHEMA:
            # The active mission runtime was already rebound at a safe
            # same-segment resume boundary. A later typed successor inherits
            # that exact mission runtime identity; its own segment admission
            # independently binds the predecessor state and approved prefix.
            if (
                migration.get("migration_kind") != "active_segment_resume"
                or migration.get("runtime_generation") != target_generation
            ):
                raise MissionAuthorityError("active runtime migration cannot authorize this successor")
            return {
                "sequence": previous_sequence,
                "sha256": migration_sha,
                "runtime_generation": target_generation,
            }
        if (
            migration.get("runtime_generation") != target_generation
            or migration.get("source_authority", {}).get("run_id")
            != str(source_segment.get("run_id") or "")
            or migration.get("source_authority", {}).get("approved_checkpoint_id")
            != approved_checkpoint_id
            or migration.get("source_authority", {}).get("approved_candidate_sha")
            != approved_candidate_sha
            or migration.get("source_authority", {}).get("crossing_candidate_sha")
            != crossing_candidate_sha
        ):
            raise MissionAuthorityError("existing runtime migration does not match this blocked boundary")
        return {
            "sequence": previous_sequence,
            "sha256": migration_sha,
            "runtime_generation": target_generation,
        }
    if previous_sequence and not _mission_runtime_binding_path(
        repo, mission_id, previous_sequence,
    ).is_file():
        raise MissionAuthorityError("prior runtime migration has no real capability binding receipt")

    runner = str((mission_doc.get("operational_budget") or {}).get("runner") or "")
    previous_profile = previous.get("runner_profile")
    capabilities = previous.get("capabilities")
    if not runner or not isinstance(previous_profile, dict) or not isinstance(capabilities, list):
        raise MissionAuthorityError("previous mission runtime identity is incomplete")
    meta, _ = packet.parse_packet_file(
        state.run_dir(repo, str(source_segment.get("run_id") or "")) / "WORK_PACKET.md"
    )
    profile = runner_profiles.resolve_profile(
        str(meta.get("runner_profile") or "default"), provider=runner,
    )
    runner_profiles.verify_profile_integrity(profile)
    actual_profile = {
        key: profile.get(key)
        for key in ("name", "provider", "model", "effort", "identity_sha256")
    }
    if actual_profile != previous_profile:
        raise MissionAuthorityError("runtime migration would change the sealed runner/profile/model/effort")
    if sorted(str(value) for value in (meta.get("capabilities") or [])) != sorted(
        str(value) for value in capabilities
    ):
        raise MissionAuthorityError("runtime migration would change the sealed capability request")

    source_authority = {
        "run_id": str(source_segment["run_id"]),
        "packet_sha256": source_packet_sha256,
        "state_sha256": util.sha256_file(state.state_path(repo, str(source_segment["run_id"]))),
        "event_chain_sha256": source_event_chain_sha256,
        "approved_checkpoint_id": approved_checkpoint_id,
        "approved_candidate_sha": approved_candidate_sha,
        "crossing_candidate_sha": crossing_candidate_sha,
    }
    sequence = previous_sequence + 1
    payload = {
        "schema": MISSION_RUNTIME_MIGRATION_SCHEMA,
        "mission_id": mission_id,
        "sequence": sequence,
        "previous_runtime_identity_sha256": previous_sha,
        "previous_runtime_generation": str(previous.get("runtime_generation") or ""),
        "runtime_generation": target_generation,
        "runner": runner,
        "capabilities": sorted(str(value) for value in capabilities),
        "runner_profile": actual_profile,
        "source_authority": source_authority,
        "reason": "typed blocked semantic-budget successor after exact runtime commissioning",
        "created_at": str(source_state.get("updated_at") or ""),
    }
    if not payload["created_at"] or not _FULL_SHA_RE.fullmatch(approved_candidate_sha):
        raise MissionAuthorityError("runtime migration source boundary is incomplete")
    digest = _write_once(
        _mission_runtime_migration_path(repo, mission_id, sequence), payload,
    )
    return {
        "sequence": sequence,
        "sha256": digest,
        "runtime_generation": target_generation,
    }


def _verify_approved_prefix(
    meta: dict[str, Any],
    program_state: dict[str, Any],
    events: list[dict[str, Any]],
    *,
    canonical_repo: Path | None = None,
    segment_doc: dict[str, Any] | None = None,
    _seen: set[str] | None = None,
) -> tuple[str, str, str]:
    """Bind the PROGRAM prefix to local approvals or sealed imported history.

    A successor segment has a new EVENT chain, so earlier checkpoint
    advancement events are not copied as if they happened in the new run.
    Instead its immutable segment authority binds a compact approved-prefix
    projection and the child EVENT chain records one typed import event.  The
    source run's exact state/event hashes are rechecked recursively here.
    """
    order = [str(value) for value in (meta.get("checkpoint_graph") or {}).get("execution_order") or []]
    finalized_rows = program_state.get("finalized_checkpoints") or []
    finalized_ids = [str(row.get("id") or "") for row in finalized_rows if isinstance(row, dict)]
    if (
        len(finalized_ids) != len(finalized_rows)
        or finalized_ids != order[:len(finalized_ids)]
        or any(row.get("terminal_state") != "APPROVED" for row in finalized_rows)
    ):
        raise MissionAuthorityError("mission approved-checkpoint history is not an ordered graph prefix")
    checkpoint_rows = {
        str(row.get("id") or ""): row
        for row in (program_state.get("checkpoints") or []) if isinstance(row, dict)
    }
    if any(checkpoint_rows.get(cp_id, {}).get("terminal") != "APPROVED" for cp_id in finalized_ids):
        raise MissionAuthorityError("mission finalized list contradicts checkpoint terminal evidence")
    approval_rows = _approval_history_rows(events, segment_doc=segment_doc)
    event_ids = [str(row.get("checkpoint_id") or "") for row in approval_rows]
    if event_ids != finalized_ids or len(event_ids) != len(set(event_ids)):
        raise MissionAuthorityError("mission approval history does not exactly match finalized checkpoint prefix")
    for index, row in enumerate(approval_rows):
        if (
            row.get("terminal_state") != "APPROVED"
            or not _FULL_SHA_RE.fullmatch(str(row.get("candidate_sha") or ""))
            or not _SHA256_RE.fullmatch(str(row.get("verdict_sha256") or ""))
            or not _SHA256_RE.fullmatch(str(row.get("source_event_sha256") or ""))
            or not isinstance(row.get("next_checkpoints"), list)
            or any(not isinstance(value, str) or not value for value in row["next_checkpoints"])
            or row.get("checkpoint_id") not in order
            or order.index(str(row.get("checkpoint_id"))) != index
        ):
            raise MissionAuthorityError("mission approval history contains malformed or out-of-order evidence")
    if approval_rows and segment_doc is not None:
        _verify_imported_approval_source(
            Path(canonical_repo) if canonical_repo is not None else None,
            segment_doc=segment_doc,
            imported_rows=approval_rows[:len(
                ((segment_doc.get("source_admission") or {}).get("approved_prefix") or [])
            )],
            seen=_seen,
        )
    if not finalized_ids:
        segment_candidates = [str(item) for item in (program_state.get("current_checkpoints") or [])]
        if not segment_candidates:
            raise MissionAuthorityError("mission has no approved or current checkpoint")
        first_id = segment_candidates[0]
        cp = checkpoint_rows.get(first_id) or {}
        baseline = str(cp.get("checkpoint_entry_candidate_sha") or "")
        return baseline, "", ""
    last_id = finalized_ids[-1]
    last_event = approval_rows[-1]
    candidate = str(last_event.get("candidate_sha") or "")
    verdict_sha = str(last_event.get("verdict_sha256") or "")
    if (
        last_event.get("terminal_state") != "APPROVED"
        or last_event.get("checkpoint_id") != last_id
        or not _FULL_SHA_RE.fullmatch(candidate)
        or not _SHA256_RE.fullmatch(verdict_sha)
        or str(program_state.get("current_checkpoints", [""])[0] if program_state.get("current_checkpoints") else "")
            not in order[len(finalized_ids):]
    ):
        raise MissionAuthorityError("latest approved event does not bind the next executable checkpoint")
    current_id = str((program_state.get("current_checkpoints") or [""])[0])
    if (checkpoint_rows.get(current_id) or {}).get("checkpoint_entry_candidate_sha") != candidate:
        raise MissionAuthorityError("next checkpoint entry differs from latest approved candidate")
    return candidate, last_id, verdict_sha


def _approval_history_rows(
    events: list[dict[str, Any]],
    *,
    segment_doc: dict[str, Any] | None,
) -> list[dict[str, Any]]:
    """Project exact approved checkpoint evidence, including one typed import."""
    local_events = [event for event in events if event.get("event_type") == "program_advanced"]
    local_rows: list[dict[str, Any]] = []
    for event in local_events:
        local_rows.append({
            "checkpoint_id": str(event.get("cp_id_finalized") or ""),
            "terminal_state": str(event.get("cp_terminal") or ""),
            "candidate_sha": str(event.get("commit_sha") or ""),
            "verdict_sha256": str(event.get("verdict_sha256") or ""),
            "next_checkpoints": copy.deepcopy(event.get("next_checkpoints")),
            "source_event_sha256": _digest(event),
        })
    import_events = [
        event for event in events
        if event.get("event_type") == "mission_approved_prefix_imported"
    ]
    admission = (segment_doc or {}).get("source_admission") or {}
    imported = admission.get("approved_prefix") or []
    if not isinstance(imported, list):
        raise MissionAuthorityError("mission segment approved-prefix authority is malformed")
    if imported:
        if len(import_events) != 1:
            raise MissionAuthorityError("mission imported approval prefix lacks one unique import event")
        event = import_events[0]
        expected_identity = {
            "mission_id": admission.get("mission_id"),
            "segment_number": admission.get("segment_number"),
            "source_run_id": admission.get("predecessor_run_id"),
            "source_state_sha256": admission.get("source_state_sha256"),
            "source_event_chain_sha256": admission.get("source_event_chain_sha256"),
            "source_authority_sha256": admission.get("source_authority_sha256"),
            "approved_prefix": imported,
        }
        if any(event.get(key) != value for key, value in expected_identity.items()):
            raise MissionAuthorityError("mission imported approval event differs from segment authority")
        first_local_index = next(
            (index for index, item in enumerate(events) if item.get("event_type") == "program_advanced"),
            len(events),
        )
        if events.index(event) >= first_local_index:
            raise MissionAuthorityError("mission approved-prefix import was appended after local checkpoint advancement")
    elif import_events:
        raise MissionAuthorityError("mission contains an unbound approved-prefix import event")
    return copy.deepcopy(imported) + local_rows


def _verify_imported_approval_source(
    canonical_repo: Path | None,
    *,
    segment_doc: dict[str, Any],
    imported_rows: list[dict[str, Any]],
    seen: set[str] | None,
) -> None:
    """Re-read the exact predecessor chain behind a child segment's imports."""
    admission = segment_doc.get("source_admission") or {}
    predecessor = str(admission.get("predecessor_run_id") or segment_doc.get("predecessor_run_id") or "")
    mission_id = str(segment_doc.get("mission_id") or "")
    if not imported_rows:
        return
    if canonical_repo is None or not predecessor or not mission_id:
        raise MissionAuthorityError("mission imported approval source cannot be resolved")
    visited = set(seen or set())
    if predecessor in visited:
        raise MissionAuthorityError("mission predecessor authority contains a cycle")
    visited.add(predecessor)
    source_root = state.run_dir(canonical_repo, predecessor)
    source_state_path = source_root / "STATE.json"
    source_events_path = source_root / "EVENTS.log"
    source_packet_path = source_root / "WORK_PACKET.md"
    if (
        not source_state_path.is_file()
        or not source_events_path.is_file()
        or not source_packet_path.is_file()
        or util.sha256_file(source_state_path) != admission.get("source_state_sha256")
        or util.sha256_file(source_packet_path) != admission.get("source_packet_sha256")
        or integrity.compute_event_chain_hash(source_events_path) != admission.get("source_event_chain_sha256")
    ):
        raise MissionAuthorityError("mission predecessor state/packet/event evidence changed")
    intact, problems = integrity.assert_artifacts_intact(canonical_repo, predecessor)
    if not intact:
        raise MissionAuthorityError("mission predecessor artifact chain is invalid: " + "; ".join(problems[:5]))
    source_state = state.load_verified(canonical_repo, predecessor)
    source_meta, _ = packet.parse_packet_file(source_packet_path)
    source_events = integrity.read_event_chain(source_events_path)
    source_program = (source_state or {}).get("program") or {}
    source_segment = None
    if source_meta.get("schema") == packet.MISSION_PROGRAM_SCHEMA_VERSION:
        loaded = load_segment(canonical_repo, predecessor)
        if loaded is None:
            raise MissionAuthorityError("mission predecessor segment binding is missing")
        source_segment = loaded[0]
    source_approved_sha, _, _ = _verify_approved_prefix(
        source_meta, source_program, source_events,
        canonical_repo=canonical_repo,
        segment_doc=source_segment,
        _seen=visited,
    )
    source_rows = _approval_history_rows(source_events, segment_doc=source_segment)
    if source_rows != imported_rows:
        raise MissionAuthorityError("mission imported checkpoint evidence differs from predecessor history")
    if source_approved_sha != str(segment_doc.get("baseline_sha") or ""):
        raise MissionAuthorityError("mission child baseline differs from predecessor's last approved candidate")


def _capture_approved_prefix(
    canonical_repo: Path,
    *,
    source_meta: dict[str, Any],
    source_program: dict[str, Any],
    source_events: list[dict[str, Any]],
    source_segment: dict[str, Any] | None,
) -> list[dict[str, Any]]:
    """Return the source run's recursively verified approved-prefix records."""
    _verify_approved_prefix(
        source_meta, source_program, source_events,
        canonical_repo=canonical_repo,
        segment_doc=source_segment,
    )
    return _approval_history_rows(source_events, segment_doc=source_segment)


def _line_count(repo: Path, baseline: str, candidate: str) -> int:
    stats = program.source_tree_accounting(
        canonical_repo=repo, baseline_sha=baseline, candidate_sha=candidate,
    )
    return int(stats["diff_lines"])


def source_budget_for_candidate(
    canonical_repo: Path,
    run_id: str,
    candidate_sha: str,
) -> dict[str, Any]:
    """Return authoritative segment/mission line usage for a v4 candidate."""
    loaded = load_segment(Path(canonical_repo), run_id)
    if loaded is None:
        raise MissionAuthorityError("v4 source budget requested without a bound mission segment")
    segment, segment_sha, mission_doc, mission_sha = loaded
    mission_baseline = str(mission_doc.get("mission_original_baseline_sha") or "")
    segment_baseline = str(segment.get("baseline_sha") or "")
    if not _FULL_SHA_RE.fullmatch(mission_baseline) or not _FULL_SHA_RE.fullmatch(segment_baseline):
        raise MissionAuthorityError("mission or segment baseline identity is invalid")
    accounting = program.source_tree_accounting(
        canonical_repo=Path(canonical_repo),
        baseline_sha=mission_baseline,
        candidate_sha=candidate_sha,
    )
    return {
        "mission_id": segment["mission_id"],
        "segment_number": int(segment["segment_number"]),
        "mission_authority_sha256": mission_sha,
        "segment_authority_sha256": segment_sha,
        "segment_baseline_sha": segment_baseline,
        "segment_max_diff_lines": int(mission_doc["segment_max_diff_lines"]),
        "mission_original_baseline_sha": mission_baseline,
        "mission_max_diff_lines": int(mission_doc["mission_max_diff_lines"]),
        "mission_source_lines_total": int(accounting["diff_lines"]),
        "mission_unique_files_total": int(accounting["files_changed_unique"]),
        "mission_max_unique_changed_files": int(
            mission_doc.get("mission_max_unique_changed_files")
            or program.GLOBAL_MAX_UNIQUE_CHANGED_FILES
        ),
    }


def segment_boundary_eligibility(
    canonical_repo: Path,
    run_id: str,
    *,
    meta: dict[str, Any],
    current_state: dict[str, Any],
    candidate_sha: str,
    source_check: dict[str, Any],
    validation_pass: bool,
    infra_failure_count: int,
    identity_reproof: dict[str, Any],
    scope_findings: list[dict[str, Any]],
    protected_findings: list[dict[str, Any]],
    hard_secret_blocks: list[dict[str, Any]],
    outcome_requested: str | None = None,
    candidate_invalid_count: int = 0,
    segment_context: tuple[dict[str, Any], str, dict[str, Any], str] | None = None,
) -> tuple[bool, dict[str, Any]]:
    """Authorize only a budget-only segment boundary; never bypass other gates."""
    reasons: list[str] = []
    try:
        loaded = segment_context or load_segment(canonical_repo, run_id)
        if loaded is None:
            return False, {"result": "refused", "reason": "mission_segment_unbound"}
        segment, _, mission_doc, mission_sha = loaded
        budget = meta.get("mission_budget") or {}
        if not bool(budget.get("auto_segment")):
            reasons.append("automatic_segmentation_not_authorized")
        if int(segment.get("segment_number") or 0) >= int(mission_doc.get("max_segments") or 0):
            reasons.append("maximum_segments_exhausted")
        if current_state.get("state") != "BUILDING":
            reasons.append("source_boundary_not_from_building")
        if outcome_requested in ("blocked", "stopped"):
            reasons.append("semantic_outcome_requests_terminal_stop")
        if not _FULL_SHA_RE.fullmatch(candidate_sha):
            reasons.append("candidate_identity_invalid")
        if not bool(validation_pass) or int(infra_failure_count) != 0:
            reasons.append("validation_or_infrastructure_gate_failed")
        if int(candidate_invalid_count) != 0:
            reasons.append("candidate_environment_invalid")
        if identity_reproof.get("result") != "pass":
            reasons.append("candidate_identity_reproof_failed")
        if scope_findings:
            reasons.append("scope_violation_present")
        if protected_findings:
            reasons.append("protected_path_violation_present")
        if hard_secret_blocks:
            reasons.append("hard_secret_finding_present")
        if state.is_stop_requested(canonical_repo, run_id):
            reasons.append("stop_requested")

        segment_cap = int(mission_doc.get("segment_max_diff_lines") or 0)
        source_lines = int(source_check.get("diff_lines_total") or 0)
        effective_lines = int(source_check.get("effective_max_diff_lines") or 0)
        effective_files = int(source_check.get("effective_max_files_changed") or 0)
        files_changed = int(source_check.get("files_changed_unique") or 0)
        allowed_line_breaches: list[str] = []
        program_line_cap = int(source_check.get("program_max_baseline_to_final_diff_lines") or 0)
        top_line_cap = int(source_check.get("top_level_risk_max_diff_lines") or 0)
        if program_line_cap and source_lines > program_line_cap:
            allowed_line_breaches.append(
                f"global diff-lines cap reached: {source_lines}/{program_line_cap}"
            )
        if top_line_cap and source_lines > top_line_cap:
            allowed_line_breaches.append(
                f"diff_lines={source_lines} exceeds top-level risk_budget max_diff_lines={top_line_cap}"
            )
        if effective_lines and source_lines > effective_lines:
            allowed_line_breaches.append(
                f"effective diff-lines cap exceeded: {source_lines}/{effective_lines}"
            )
        exact_source_breach = "; ".join(allowed_line_breaches)
        if not (
            source_check.get("result") == "fail"
            and source_check.get("accounting") == "absolute_baseline_to_candidate"
            and effective_lines == segment_cap
            and source_lines > segment_cap
            and (not effective_files or files_changed <= effective_files)
            and exact_source_breach != ""
            and source_check.get("breach") == exact_source_breach
        ):
            reasons.append("source_failure_is_not_only_segment_line_ceiling")
        if (
            source_check.get("mission_budget_result") != "pass"
            or source_check.get("mission_id") != segment.get("mission_id")
            or int(source_check.get("segment_number") or 0) != int(segment.get("segment_number") or 0)
            or int(source_check.get("segment_source_ceiling") or 0) != segment_cap
            or int(source_check.get("mission_source_ceiling") or 0)
                != int(mission_doc.get("mission_max_diff_lines") or 0)
            or int(source_check.get("mission_unique_files_ceiling") or 0)
                != int(mission_doc.get("mission_max_unique_changed_files") or 0)
        ):
            reasons.append("mission_source_budget_is_exhausted")
        if source_check.get("mission_source_lines_total") is not None and int(
            source_check.get("mission_source_lines_total")
        ) > int(mission_doc.get("mission_max_diff_lines") or 0):
            reasons.append("crossing_candidate_exceeds_mission_source_ceiling")
        if int(source_check.get("mission_unique_files_total") or 0) > int(
            mission_doc.get("mission_max_unique_changed_files")
            or program.GLOBAL_MAX_UNIQUE_CHANGED_FILES
        ):
            reasons.append("mission_unique_file_ceiling_exhausted")

        prog = current_state.get("program") or {}
        graph_ok, graph_reason = program.verify_frozen_graph(meta, prog)
        if not graph_ok:
            reasons.append("frozen_checkpoint_graph_invalid:" + graph_reason)
        current_ids = prog.get("current_checkpoints") or []
        cp_id = str(current_ids[0]) if current_ids else ""
        cp_state = next((cp for cp in (prog.get("checkpoints") or []) if cp.get("id") == cp_id), None)
        if not cp_id or not isinstance(cp_state, dict) or cp_state.get("terminal"):
            reasons.append("no_reexecutable_current_checkpoint")
        build_entitlement: dict[str, Any] | None = None
        if cp_id and isinstance(cp_state, dict) and not cp_state.get("terminal"):
            packet_cp = next(
                (
                    cp for cp in (meta.get("checkpoint_graph") or {}).get("checkpoints", [])
                    if isinstance(cp, dict) and cp.get("id") == cp_id
                ),
                None,
            )
            if not isinstance(packet_cp, dict):
                reasons.append("current_checkpoint_build_budget_missing")
            else:
                build_entitlement = program.build_pass_entitlement(
                    prog, cp_id=cp_id, packet_cp=packet_cp,
                    packet=meta, state_doc=current_state,
                )
                reasons.extend(build_entitlement["reason_codes"])
        order = (meta.get("checkpoint_graph") or {}).get("execution_order") or []
        finalized = {str(item.get("id")) for item in (prog.get("finalized_checkpoints") or []) if isinstance(item, dict)}
        if cp_id not in order or cp_id in finalized or not any(cid not in finalized for cid in order):
            reasons.append("remaining_checkpoint_graph_not_proven")

        events = integrity.read_event_chain(state.events_path(canonical_repo, run_id))
        last_approved, approved_cp, verdict_sha = _verify_approved_prefix(
            meta, current_state.get("program") or {}, events,
            canonical_repo=Path(canonical_repo), segment_doc=segment,
        )
        prior_candidate = str(current_state.get("last_candidate_sha") or "")
        prior_candidate_lineage_valid = prior_candidate in ("", candidate_sha, last_approved)
        if prior_candidate and not prior_candidate_lineage_valid:
            # A crossing BUILD may itself be a funded repair of an earlier
            # candidate. In that case the state still names the previous
            # candidate until this finalization commits the new one. Accept
            # only a proven ancestor on the same sealed candidate branch;
            # never treat a different or rewritten tip as equivalent.
            prior_candidate_lineage_valid = (
                bool(_FULL_SHA_RE.fullmatch(prior_candidate))
                and build_finalize._candidate_branch_contains(
                    canonical_repo, str(segment.get("candidate_branch") or ""), prior_candidate,
                )
                and build_finalize._ancestor_of(canonical_repo, prior_candidate, last_approved)
                and build_finalize._ancestor_of(canonical_repo, candidate_sha, prior_candidate)
            )
        if not prior_candidate_lineage_valid:
            reasons.append("candidate_differs_from_current_or_last_approved_state")
        if cp_state and cp_state.get("checkpoint_entry_candidate_sha") != last_approved:
            reasons.append("last_approved_candidate_does_not_match_checkpoint_entry")
        original_baseline = str(mission_doc.get("mission_original_baseline_sha") or "")
        mission_candidate_lines = _line_count(canonical_repo, original_baseline, candidate_sha)
        mission_baseline_lines = _line_count(canonical_repo, original_baseline, last_approved)
        segment_stats = program.source_tree_accounting(
            canonical_repo=Path(canonical_repo),
            baseline_sha=str(segment.get("baseline_sha") or ""),
            candidate_sha=candidate_sha,
        )
        actual_segment_lines = int(segment_stats["diff_lines"])
        if source_lines != actual_segment_lines:
            reasons.append("segment_source_measurement_mismatch")
        if source_check.get("mission_source_lines_total") != mission_candidate_lines:
            reasons.append("mission_source_measurement_mismatch")
        mission_stats = program.source_tree_accounting(
            canonical_repo=Path(canonical_repo),
            baseline_sha=original_baseline,
            candidate_sha=candidate_sha,
        )
        actual_mission_unique_files = int(mission_stats["files_changed_unique"])
        if source_check.get("mission_unique_files_total") != actual_mission_unique_files:
            reasons.append("mission_unique_file_measurement_mismatch")
        if actual_mission_unique_files > int(
            mission_doc.get("mission_max_unique_changed_files")
            or program.GLOBAL_MAX_UNIQUE_CHANGED_FILES
        ):
            reasons.append("mission_unique_file_ceiling_exhausted")
        if mission_candidate_lines > int(mission_doc.get("mission_max_diff_lines") or 0):
            reasons.append("mission_source_ceiling_exhausted")
        if mission_baseline_lines > int(mission_doc.get("mission_max_diff_lines") or 0):
            reasons.append("last_approved_candidate_exceeds_mission_source_ceiling")
        if mission_baseline_lines >= int(mission_doc.get("mission_max_diff_lines") or 0):
            reasons.append("no_mission_source_authority_remains_after_last_approval")
        if not build_finalize._candidate_branch_contains(
            canonical_repo, str(segment.get("candidate_branch") or ""), last_approved,
        ) or not build_finalize._candidate_branch_contains(
            canonical_repo, str(segment.get("candidate_branch") or ""), candidate_sha,
        ):
            reasons.append("last_approved_candidate_missing_from_sealed_candidate_branch")
        if git_checks.branch_head(
            canonical_repo, str(segment.get("candidate_branch") or ""),
        ) != candidate_sha:
            reasons.append("crossing_candidate_is_not_exact_candidate_branch_head")
        if not build_finalize._ancestor_of(canonical_repo, last_approved, original_baseline):
            reasons.append("last_approved_candidate_lineage_invalid")
        if not build_finalize._ancestor_of(canonical_repo, candidate_sha, original_baseline):
            reasons.append("crossing_candidate_lineage_invalid")

        proof = {
            "result": "authorized" if not reasons else "refused",
            "mission_id": segment.get("mission_id"),
            "segment_number": segment.get("segment_number"),
            "mission_authority_sha256": mission_sha,
            "source_candidate_sha": candidate_sha,
            "source_candidate_diff_lines_from_mission_baseline": mission_candidate_lines,
            "last_approved_candidate_sha": last_approved,
            "last_approved_checkpoint_id": approved_cp,
            "last_approved_verdict_sha256": verdict_sha,
            "mission_source_lines_at_last_approval": mission_baseline_lines,
            "segment_source_lines": source_lines,
            "segment_source_ceiling": segment_cap,
            "mission_source_lines_total": source_check.get("mission_source_lines_total"),
            "mission_source_ceiling": int(mission_doc.get("mission_max_diff_lines") or 0),
            "mission_unique_files_total": source_check.get("mission_unique_files_total"),
            "mission_unique_files_ceiling": int(
                mission_doc.get("mission_max_unique_changed_files")
                or program.GLOBAL_MAX_UNIQUE_CHANGED_FILES
            ),
            "reexecute_checkpoint": cp_id,
            "reasons": reasons,
        }
        if build_entitlement is not None:
            proof["required_build_entitlement"] = build_entitlement
        return not reasons, proof
    except Exception as exc:
        return False, {
            "result": "refused",
            "reason": "mission_boundary_proof_failed",
            "detail": type(exc).__name__,
        }


def _packet_bytes(meta: dict[str, Any], markdown_tail: str) -> bytes:
    rendered = "```json\n" + json.dumps(meta, indent=2, ensure_ascii=True) + "\n```"
    return (rendered + markdown_tail).encode("utf-8")


def _segment_run_id(mission_id: str, number: int) -> str:
    return f"seg-{mission_id.removeprefix('mission-')[:20]}-s{number:02d}"


def _create_baseline_ref(repo: Path, branch: str, sha: str) -> None:
    if not git_checks.is_valid_branch_name(branch) or not _FULL_SHA_RE.fullmatch(sha):
        raise MissionAuthorityError("derived baseline ref or SHA is invalid")
    existing = git_checks.branch_head(repo, branch)
    if existing is not None:
        if existing != sha:
            raise MissionAuthorityError("derived baseline branch already points elsewhere")
        return
    result = util.run_subprocess(
        ["git", "-C", str(repo), "update-ref", f"refs/heads/{branch}", sha], timeout=10,
    )
    if result.returncode != 0 or git_checks.branch_head(repo, branch) != sha:
        raise MissionAuthorityError("could not establish exact mission baseline ref")


def _write_packet_once(run_root: Path, raw: bytes) -> None:
    path = run_root / "WORK_PACKET.md"
    _atomic_publish_once(path, raw)


def _ensure_approved_prefix_import_event(
    canonical_repo: Path,
    run_id: str,
    *,
    segment: dict[str, Any],
) -> None:
    """Record imported approvals once, without impersonating local reviews."""
    admission = segment.get("source_admission") or {}
    approved_prefix = admission.get("approved_prefix") or []
    if not approved_prefix:
        return
    if not isinstance(approved_prefix, list):
        raise MissionAuthorityError("mission successor approved-prefix projection is invalid")
    expected = {
        "mission_id": segment.get("mission_id"),
        "segment_number": segment.get("segment_number"),
        "source_run_id": admission.get("predecessor_run_id"),
        "source_state_sha256": admission.get("source_state_sha256"),
        "source_event_chain_sha256": admission.get("source_event_chain_sha256"),
        "source_authority_sha256": admission.get("source_authority_sha256"),
        "approved_prefix": approved_prefix,
    }
    events = integrity.read_event_chain(state.events_path(canonical_repo, run_id))
    existing = [
        event for event in events
        if event.get("event_type") == "mission_approved_prefix_imported"
    ]
    if existing:
        if len(existing) != 1 or any(existing[0].get(key) != value for key, value in expected.items()):
            raise MissionAuthorityError("existing imported checkpoint event conflicts with segment authority")
        first_local = next(
            (i for i, event in enumerate(events) if event.get("event_type") == "program_advanced"),
            len(events),
        )
        if events.index(existing[0]) >= first_local:
            raise MissionAuthorityError("imported checkpoint event is not ordered before local approvals")
        return
    if any(event.get("event_type") == "program_advanced" for event in events):
        raise MissionAuthorityError("cannot import historical approvals after local checkpoint advancement")
    last_candidate = str(approved_prefix[-1].get("candidate_sha") or "")
    state_doc = state.load_verified(canonical_repo, run_id)
    if not isinstance(state_doc, dict):
        raise MissionAuthorityError("mission successor state is unavailable for approval-history import")
    state.append_event(
        canonical_repo,
        run_id,
        event_type="mission_approved_prefix_imported",
        old_state=str(state_doc.get("state") or ""),
        new_state=str(state_doc.get("state") or ""),
        actor="ofloop-mission",
        commit_sha=last_candidate,
        reason="bound immutable approved checkpoint history from the predecessor segment",
        extras=expected,
    )


def _write_derived_approval_once(
    repo: Path,
    run_id: str,
    *,
    packet_meta: dict[str, Any],
    packet_sha256: str,
    segment: dict[str, Any],
    segment_sha256: str,
    mission_sha256: str,
    origin_approval_sha256: str,
) -> dict[str, Any]:
    """Create a child execution seal whose only authority is the original seal."""
    path = approval.approval_path(repo, run_id)
    segment_identity = {
        "schema": "ownframework-loop-mission-segment-approval/v1",
        "mission_id": segment["mission_id"],
        "segment_number": segment["segment_number"],
        "predecessor_run_id": segment.get("predecessor_run_id"),
        "mission_authority_sha256": mission_sha256,
        "segment_authority_sha256": segment_sha256,
    }
    existing = approval.load_approval(repo, run_id)
    if existing is not None:
        ok, reason = approval.validate_approval_binding(
            canonical_repo=repo,
            run_id=run_id,
            approval=existing,
            packet=packet_meta,
            packet_path=state.run_dir(repo, run_id) / "WORK_PACKET.md",
        )
        if not ok or existing.get("mission_segment") != segment_identity:
            raise MissionAuthorityError("existing mission-derived execution seal conflicts: " + reason)
        return existing
    seal = {
        "schema": approval.SCHEMA_VERSION,
        "run_id": run_id,
        "packet_sha256": packet_sha256,
        "approved_at": util.utc_now_iso(),
        "approved_actor": "ofloop-mission",
        "canonical_repo": str(repo.resolve(strict=False)),
        "baseline_branch": str(segment["baseline_branch"]),
        "baseline_sha": str(segment["baseline_sha"]),
        "packet_schema": packet_meta.get("schema"),
        "approval_method": "mission_segment",
        "binding_kind": "mission_derived_seal",
        "confirmation_token": approval.derive_confirmation_token(packet_sha256),
        "candidate_branch": str(segment["candidate_branch"]),
        "spec_baseline_branch": str(segment["baseline_branch"]),
        "spec_baseline_sha": str(segment["baseline_sha"]),
        "spec_snapshot_at": util.utc_now_iso(),
        "mission_origin_approval_sha256": origin_approval_sha256,
        "mission_segment": segment_identity,
    }
    errors = approval.validate_approval_shape(seal)
    if errors:
        raise MissionAuthorityError("derived execution seal failed shape validation: " + "; ".join(errors))
    raw = (json.dumps(seal, sort_keys=True, indent=2) + "\n").encode("utf-8")
    _atomic_publish_once(path, raw)
    return seal


def _derived_packet_meta(mission_doc: dict[str, Any], *, run_id: str, number: int,
                         baseline_branch: str, baseline_sha: str) -> dict[str, Any]:
    meta = copy.deepcopy(mission_doc["template_meta"])
    meta["packet_id"] = f"mission-{mission_doc['mission_id'][-12:]}-s{number:02d}"
    target = meta["target"]
    target["branch"] = baseline_branch
    target["expected_baseline_sha"] = baseline_sha
    target["candidate_branch_prefix"] = f"factory/candidate/{run_id}"
    return meta


def _copy_program_for_segment(
    source_program: dict[str, Any],
    *,
    meta: dict[str, Any],
    baseline_sha: str,
    candidate_branch: str,
    mission_segment: dict[str, Any],
) -> dict[str, Any]:
    copied = json.loads(integrity.canonical_json_dumps(source_program))
    copied.pop("rollover_provenance", None)
    copied["checkpoint_graph_sha256"] = program.checkpoint_graph_sha256(meta)
    copied["promotion_policy"] = program.resolve_promotion_policy(meta)
    copied["mission_segment"] = copy.deepcopy(mission_segment)
    policy = (meta.get("mission_budget") or {}).get("semantic_budget_policy")
    if isinstance(policy, dict):
        copied["semantic_budget_policy_sha256"] = program.semantic_budget_policy_sha256(meta)
        copied.setdefault("semantic_budget_allocations", [])
    elif copied.get("semantic_budget_allocations") or copied.get("semantic_budget_policy_sha256"):
        raise MissionAuthorityError(
            "successor cannot discard previously consumed adaptive semantic authority"
        )
    copied["blocked"] = False
    copied["block_reason"] = ""
    source = copied.get("source_sha_provenance") or {}
    source["baseline_sha"] = baseline_sha
    source["candidate_branch"] = candidate_branch
    source["envelope_source"] = "mission_segment_source_ceiling"
    source["packet_global_cap"] = {
        "max_build_passes": int((meta.get("risk_budget") or {}).get("max_build_passes") or 0),
        "max_review_passes": int((meta.get("risk_budget") or {}).get("max_review_passes") or 0),
        "max_repair_rounds": int((meta.get("risk_budget") or {}).get("max_repair_rounds") or 0),
    }
    copied["source_sha_provenance"] = source
    caps = copied.get("cumulative_ceilings") or {}
    source_caps = ((meta.get("checkpoint_graph") or {}).get("global_source_ceilings") or {})
    caps["max_unique_changed_files"] = int(source_caps.get("max_unique_changed_files") or 500)
    caps["max_baseline_to_final_diff_lines"] = int(source_caps.get("max_baseline_to_final_diff_lines") or 0)
    copied["cumulative_ceilings"] = caps
    # The imported history preserves semantic counters and approved checkpoint
    # evidence, while source statistics are measured from this segment baseline.
    stats = program.source_tree_accounting(
        canonical_repo=Path(meta["target"]["repo"]),
        baseline_sha=baseline_sha,
        candidate_sha=baseline_sha,
    )
    counters = copied.get("cumulative_counters") or {}
    counters["files_changed_unique"] = int(stats["files_changed_unique"])
    counters["diff_lines_total"] = int(stats["diff_lines"])
    copied["cumulative_counters"] = counters
    current_ids = copied.get("current_checkpoints") or []
    if not current_ids or len(current_ids) != len(set(current_ids)):
        raise MissionAuthorityError("successor import requires a non-empty unique current checkpoint set")
    checkpoint_rows = copied.get("checkpoints") or []
    for current_id in current_ids:
        current = next((cp for cp in checkpoint_rows if cp.get("id") == current_id), None)
        if not isinstance(current, dict) or current.get("terminal"):
            raise MissionAuthorityError("successor current checkpoint is terminal or missing")
        current["candidate_sha"] = None
        current["build_receipt_sha256"] = None
        current["verdict_sha256"] = None
        current["terminal"] = ""
        current["checkpoint_entry_candidate_sha"] = baseline_sha
    return copied


def _create_child_segment(
    canonical_repo: Path,
    *,
    mission_doc: dict[str, Any],
    mission_sha: str,
    segment_number: int,
    predecessor_run_id: str,
    baseline_sha: str,
    source_program: dict[str, Any],
    source_state: dict[str, Any],
    source_admission: dict[str, Any],
    db_path: Path | None = None,
) -> dict[str, Any]:
    """Create one immutable, replayable segment from verified mission authority.

    Both automatic source-ceiling boundaries and the explicitly typed legacy
    admission use this owner. The caller supplies only already-verified
    last-approved authority; this function never accepts a crossing candidate
    as a baseline.
    """
    repo = Path(canonical_repo).resolve(strict=False)
    mission_id = str(mission_doc.get("mission_id") or "")
    original_baseline = str(mission_doc.get("mission_original_baseline_sha") or "")
    if not _FULL_SHA_RE.fullmatch(original_baseline) or not _FULL_SHA_RE.fullmatch(baseline_sha):
        raise MissionAuthorityError("mission child baseline identity is invalid")
    mission_used = _line_count(repo, original_baseline, baseline_sha)
    mission_cap = int(mission_doc.get("mission_max_diff_lines") or 0)
    if mission_used >= mission_cap:
        raise MissionAuthorityError("mission source ceiling is exhausted at approved baseline")
    if not build_finalize._ancestor_of(repo, baseline_sha, original_baseline):
        raise MissionAuthorityError("mission child baseline is not descended from original baseline")
    if not 1 <= segment_number <= int(mission_doc.get("max_segments") or 0):
        raise MissionAuthorityError("mission segment count is exhausted")

    child_id = _segment_run_id(mission_id, segment_number)
    child_branch = f"factory/candidate/{child_id}"
    baseline_branch = f"ofloop/mission/{mission_id[-12:]}/baseline/s{segment_number:02d}"
    if not git_checks.is_valid_branch_name(child_branch):
        raise MissionAuthorityError("derived candidate branch name is invalid")
    _create_baseline_ref(repo, baseline_branch, baseline_sha)
    source_admission = copy.deepcopy(source_admission)
    overlay = source_admission.get("semantic_budget_policy_overlay")
    if overlay is not None:
        if source_admission.get("kind") != "blocked_semantic_budget_continuation":
            raise MissionAuthorityError(
                "semantic budget policy overlay requires typed blocked-mission continuation"
            )
    child_meta = _derived_packet_meta(
        mission_doc, run_id=child_id, number=segment_number,
        baseline_branch=baseline_branch, baseline_sha=baseline_sha,
    )
    if overlay is not None:
        child_meta.setdefault("mission_budget", {})["semantic_budget_policy"] = copy.deepcopy(overlay)
    errors = packet.validate_packet_for_approval(child_meta)
    if errors:
        raise MissionAuthorityError("derived successor packet is invalid: " + "; ".join(errors[:20]))
    child_packet = _packet_bytes(child_meta, str(mission_doc.get("template_markdown_tail") or ""))
    child_packet_sha = hashlib.sha256(child_packet).hexdigest()
    child_root = state.run_dir(repo, child_id)
    child_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    _write_packet_once(child_root, child_packet)

    projection_sha = str(mission_doc["authority_projection_sha256"])
    source_admission["mission_original_baseline_sha"] = original_baseline
    source_admission["mission_id"] = mission_id
    source_admission["segment_number"] = segment_number
    source_admission["predecessor_run_id"] = predecessor_run_id
    if source_admission.get("kind") in {
        "automatic_segment_successor", "explicit_legacy_continuation",
        "blocked_semantic_budget_continuation",
    }:
        crossing_sha = str(source_admission.get("crossing_candidate_sha") or "")
        if not _FULL_SHA_RE.fullmatch(crossing_sha) or crossing_sha == baseline_sha:
            raise MissionAuthorityError(
                "mission successor must preserve a distinct crossing candidate without adopting it"
            )
        source_admission["crossing_candidate_not_adopted"] = True
    segment_payload = _segment_doc(
        mission_id=mission_id,
        number=segment_number,
        run_id=child_id,
        predecessor_run_id=predecessor_run_id,
        packet_sha256=child_packet_sha,
        baseline_sha=baseline_sha,
        baseline_branch=baseline_branch,
        candidate_branch=child_branch,
        mission_authority_sha256=mission_sha,
        authority_projection_sha256=projection_sha,
        mission_source_lines_at_start=mission_used,
        source_admission=source_admission,
    )
    mission_dir = _mission_dir(repo, mission_id)
    with flock_exclusive(mission_dir / "MISSION.lock"):
        segment_file = _segment_path(repo, mission_id, segment_number)
        if segment_file.exists():
            existing_segment, segment_sha = _read_record(
                segment_file, expected_schema=SEGMENT_SCHEMA,
            )
            if existing_segment != segment_payload:
                raise MissionAuthorityError("replayed successor identity differs from immutable segment record")
        else:
            segment_sha = _write_once(segment_file, segment_payload)
        binding = _mission_segment_binding(segment_payload, segment_sha)
        existing = state.load(repo, child_id)
        if existing is None:
            initial = state.initial_state(child_id)
            initial["spec_baseline_branch"] = baseline_branch
            initial["spec_baseline_sha"] = baseline_sha
            initial["spec_snapshot_at"] = util.utc_now_iso()
            state.save(repo, child_id, initial)
            state.append_event(
                repo, child_id, event_type="run_created", old_state=None,
                new_state="AWAITING_APPROVAL", actor="ofloop-mission",
                reason=f"mission segment {segment_number} derived from {predecessor_run_id}",
                extras={"mission_id": mission_id, "segment_authority_sha256": segment_sha},
            )
            existing = state.load_verified(repo, child_id)
        elif (
            existing.get("run_id") != child_id
            or existing.get("spec_baseline_sha") != baseline_sha
            or existing.get("spec_baseline_branch") != baseline_branch
        ):
            raise MissionAuthorityError("existing deterministic successor state conflicts with segment record")

        if existing.get("program") is None:
            child_events = integrity.read_event_chain(state.events_path(repo, child_id))
            if not any(event.get("event_type") == "run_created" for event in child_events):
                state.append_event(
                    repo, child_id, event_type="run_created", old_state=None,
                    new_state="AWAITING_APPROVAL", actor="ofloop-mission",
                    reason=f"mission segment {segment_number} derived from {predecessor_run_id}",
                    extras={"mission_id": mission_id, "segment_authority_sha256": segment_sha},
                )
        if existing.get("program") is None:
            program_block = _copy_program_for_segment(
                source_program, meta=child_meta, baseline_sha=baseline_sha,
                candidate_branch=child_branch, mission_segment=binding,
            )
            counters = program_block.get("cumulative_counters") or {}
            state.initialize_program_mission_segment(
                repo,
                child_id,
                program_block=program_block,
                build_pass_count=int(counters.get("build_pass_count") or 0),
                review_pass_count=int(counters.get("review_pass_count") or 0),
                repair_round=int(counters.get("repair_round_count") or 0),
                no_progress_streak=int(source_state.get("no_progress_streak") or 0),
                candidate_sha=baseline_sha,
                baseline_sha=baseline_sha,
                baseline_branch=baseline_branch,
                candidate_branch=child_branch,
                mission_segment=binding,
            )
        else:
            child_state = state.load_verified(repo, child_id)
            child_program = (child_state or {}).get("program") or {}
            if (
                not isinstance(child_state, dict)
                or child_state.get("last_candidate_sha") is None
                or child_program.get("mission_segment") != binding
                or child_program.get("source_sha_provenance", {}).get("baseline_sha") != baseline_sha
                or child_program.get("source_sha_provenance", {}).get("candidate_branch") != child_branch
            ):
                raise MissionAuthorityError("replayed successor state conflicts with immutable segment authority")
            graph_ok, graph_reason = program.verify_frozen_graph(child_meta, child_program)
            if not graph_ok:
                raise MissionAuthorityError("replayed successor graph conflicts: " + graph_reason)
            current_candidate = str(child_state.get("last_candidate_sha") or "")
            child_branch_head = git_checks.branch_head(repo, child_branch)
            pristine = (
                child_state.get("state") in ("AWAITING_APPROVAL", "READY_TO_BUILD")
                and current_candidate == baseline_sha
                and child_branch_head in (None, baseline_sha)
            )
            progressed = (
                _FULL_SHA_RE.fullmatch(current_candidate)
                and build_finalize._ancestor_of(repo, current_candidate, baseline_sha)
                and build_finalize._candidate_branch_contains(repo, child_branch, current_candidate)
            )
            if not _FULL_SHA_RE.fullmatch(current_candidate) or not (pristine or progressed):
                raise MissionAuthorityError("replayed successor candidate lineage is invalid")

        _ensure_approved_prefix_import_event(repo, child_id, segment=segment_payload)

    _write_derived_approval_once(
        repo,
        child_id,
        packet_meta=child_meta,
        packet_sha256=child_packet_sha,
        segment=segment_payload,
        segment_sha256=segment_sha,
        mission_sha256=mission_sha,
        origin_approval_sha256=str(mission_doc["source_approval_sha256"]),
    )
    # A derived approval is a real execution seal, but writing the seal alone
    # does not activate an AWAITING_APPROVAL state. Route the child through the
    # same typed execution-start owner used by ordinary runs before enrolling
    # it. This is replay-safe: ensure_executable validates the exact seal and
    # only performs the one legal pre-start transition.
    from . import execution_start

    execution_start.ensure_executable(
        canonical_repo=repo,
        run_id=child_id,
        actor="ofloop-mission",
        binding_method="mission_segment",
    )
    # Segment derivation owns ordinary supervisor admission too. This makes a
    # crash after authority publication replayable and prevents a valid
    # successor from being stranded outside the durable scheduler queue.
    child_job = _job_snapshot_if_present(repo, child_id, db_path=db_path)
    if child_job is None:
        from . import supervisor as supervisor_mod

        enrolled = supervisor_mod.enqueue(
            canonical_repo=repo,
            run_id=child_id,
            runner=str((mission_doc.get("operational_budget") or {}).get("runner") or ""),
            db_path=db_path,
        )
        if not enrolled.get("ok"):
            raise MissionAuthorityError(
                "mission successor was created but normal supervisor enrollment refused: "
                + str(enrolled.get("reason") or enrolled)
            )
        child_job = enrolled
    runtime_migration_ref = _runtime_migration_ref(segment_payload)
    if runtime_migration_ref is None:
        expected_runtime_generation = str(
            (mission_doc.get("operational_budget") or {}).get("runtime_generation") or ""
        )
    else:
        expected_runtime, _ = _runtime_identity_for_segment(repo, mission_id, segment_payload)
        expected_runtime_generation = str(expected_runtime.get("runtime_generation") or "")
    expected_runner = str((mission_doc.get("operational_budget") or {}).get("runner") or "")
    if (
        child_job.get("repo") != str(repo)
        or child_job.get("run_id") != child_id
        or str(child_job.get("candidate_branch") or "") != child_branch
        or str(child_job.get("runtime_generation") or "") != expected_runtime_generation
        or str(child_job.get("runner") or "") != expected_runner
        or str(child_job.get("execution_mode") or "").upper() != "PROGRAM"
        or str(child_job.get("status") or "") not in {
            "QUEUED", "RUNNING", "BACKOFF", "QUARANTINED", "HELD", "DONE", "RETIRED",
        }
    ):
        raise MissionAuthorityError("mission successor enrollment differs from frozen segment identity")
    crossing_sha = str(source_admission.get("crossing_candidate_sha") or "")
    current_ids = list((source_program or {}).get("current_checkpoints") or [])
    return {
        "ok": True,
        "mission_id": mission_id,
        "parent_run_id": predecessor_run_id,
        "run_id": child_id,
        "segment_number": segment_number,
        "segment_authority_sha256": segment_sha,
        "mission_authority_sha256": mission_sha,
        "packet_sha256": child_packet_sha,
        "baseline_sha": baseline_sha,
        "baseline_branch": baseline_branch,
        "candidate_branch": child_branch,
        "current_checkpoint": current_ids[0] if current_ids else None,
        "current_checkpoints": current_ids,
        "crossing_candidate_not_adopted": not crossing_sha or crossing_sha != baseline_sha,
        "crossing_candidate_sha": crossing_sha or None,
        "mission_source_lines_at_start": mission_used,
        "runtime_generation": expected_runtime_generation,
    }


def create_segment_successor(
    canonical_repo: Path,
    parent_run_id: str,
    *,
    db_path: Path | None = None,
) -> dict[str, Any]:
    """Idempotently derive one authorized successor from SEGMENT_BOUNDARY."""
    repo = Path(canonical_repo).resolve(strict=False)
    parent_state = state.load_verified(repo, parent_run_id)
    if not isinstance(parent_state, dict) or parent_state.get("state") != "SEGMENT_BOUNDARY":
        raise MissionAuthorityError("successor derivation requires a terminal SEGMENT_BOUNDARY run")
    if state.is_stop_requested(repo, parent_run_id):
        raise MissionAuthorityError("mission segment has an explicit stop request; automatic continuation refused")
    intact, problems = integrity.assert_artifacts_intact(repo, parent_run_id)
    if not intact:
        raise MissionAuthorityError("segment boundary artifact chain is invalid: " + "; ".join(problems[:10]))
    run_root = state.run_dir(repo, parent_run_id)
    meta, _ = packet.parse_packet_file(run_root / "WORK_PACKET.md")
    graph_ok, graph_reason = program.verify_frozen_graph(meta, parent_state.get("program") or {})
    if not graph_ok:
        raise MissionAuthorityError("boundary frozen PROGRAM graph is invalid: " + graph_reason)
    loaded = load_segment(repo, parent_run_id)
    if loaded is None:
        raise MissionAuthorityError("boundary parent is not a sealed v4 mission segment")
    parent_segment, _, mission_doc, mission_sha = loaded
    if not bool(mission_doc.get("auto_segment")):
        raise MissionAuthorityError("sealed mission does not authorize automatic segmentation")
    parent_job = _parent_job_snapshot(repo, parent_run_id, db_path=db_path)
    if parent_job.get("status") not in ("QUEUED", "DONE") or any(parent_job.get(key) is not None for key in (
        "worker_pid", "worker_pgid", "worker_attempt_id", "worker_role",
    )):
        raise MissionAuthorityError("boundary parent still has active supervisor ownership")
    mission_id = str(parent_segment["mission_id"])
    _read_record(
        _mission_runtime_path(repo, mission_id),
        expected_schema=MISSION_RUNTIME_SCHEMA,
    )
    # Check remaining operational authority before materializing another
    # segment. The child enqueue repeats this reconciliation transactionally;
    # this early read prevents publishing a successor that cannot be funded.
    receipt = util.read_private_json(run_root / "BUILD_RECEIPT.json", default=None)
    if (
        not isinstance(receipt, dict)
        or receipt.get("next_state") != "SEGMENT_BOUNDARY"
        or (receipt.get("segment_boundary") or {}).get("result") != "authorized"
        or receipt.get("candidate_sha") != parent_state.get("last_candidate_sha")
        or (receipt.get("scope_check") or {}).get("result") != "pass"
        or (receipt.get("protected_path_check") or {}).get("result") != "pass"
        or (receipt.get("secret_scan_check") or {}).get("result") != "pass"
        or receipt.get("validation_status") != "PASS"
    ):
        raise MissionAuthorityError("boundary receipt does not prove a clean source-budget-only stop")
    segment_number = int(parent_segment["segment_number"])
    next_number = segment_number + 1
    if next_number > int(mission_doc.get("max_segments") or 0):
        raise MissionAuthorityError("mission segment count is exhausted")
    parent_program = parent_state.get("program") or {}
    try:
        current_id = program_rollover._verified_current_checkpoint_id(meta, parent_program)
    except Exception as exc:
        raise MissionAuthorityError("boundary current checkpoint is not the next approved-prefix successor") from exc
    parent_events = integrity.read_event_chain(state.events_path(repo, parent_run_id))
    last_approved_sha, approved_cp, verdict_sha = _verify_approved_prefix(
        meta, parent_program, parent_events,
        canonical_repo=repo, segment_doc=parent_segment,
    )
    current_ids = parent_program.get("current_checkpoints") or []
    if current_ids != [current_id] or len(current_ids) != len(set(current_ids)):
        raise MissionAuthorityError("parent boundary has no unique current checkpoint set")
    checkpoint_rows = parent_program.get("checkpoints", [])
    current_cps = [next((cp for cp in checkpoint_rows if cp.get("id") == cid), None) for cid in current_ids]
    if any(
        not isinstance(cp, dict) or cp.get("terminal")
        or cp.get("checkpoint_entry_candidate_sha") != last_approved_sha
        for cp in current_cps
    ):
        raise MissionAuthorityError("last approved candidate is not the exact entry for every current checkpoint")
    original_baseline = str(mission_doc.get("mission_original_baseline_sha") or "")
    mission_used = _line_count(repo, original_baseline, last_approved_sha)
    if mission_used >= int(mission_doc.get("mission_max_diff_lines") or 0):
        raise MissionAuthorityError("mission source ceiling is exhausted at last approved checkpoint")
    if not build_finalize._ancestor_of(repo, last_approved_sha, original_baseline):
        raise MissionAuthorityError("last approved candidate is not descended from mission baseline")
    if not build_finalize._candidate_branch_contains(
        repo, str(parent_segment["candidate_branch"]), last_approved_sha,
    ):
        raise MissionAuthorityError("last approved candidate is absent from parent candidate branch")

    parent_segment_sha = _read_record(
        _segment_path(repo, mission_id, segment_number), expected_schema=SEGMENT_SCHEMA,
    )[1]
    approved_prefix = _capture_approved_prefix(
        repo,
        source_meta=meta,
        source_program=parent_program,
        source_events=parent_events,
        source_segment=parent_segment,
    )
    source_admission = {
        "kind": "automatic_segment_successor",
        "mission_original_baseline_sha": original_baseline,
        "parent_run_id": parent_run_id,
        "predecessor_run_id": parent_run_id,
        "mission_id": mission_id,
        "segment_number": next_number,
        "parent_segment_authority_sha256": parent_segment_sha,
        "source_authority_sha256": parent_segment_sha,
        "source_packet_sha256": util.sha256_file(run_root / "WORK_PACKET.md"),
        "source_state_sha256": util.sha256_file(state.state_path(repo, parent_run_id)),
        "source_event_chain_sha256": integrity.compute_event_chain_hash(
            state.events_path(repo, parent_run_id),
        ),
        "approved_prefix": approved_prefix,
        "boundary_receipt_sha256": util.sha256_file(run_root / "BUILD_RECEIPT.json"),
        "last_approved_checkpoint_id": approved_cp,
        "last_approved_candidate_sha": last_approved_sha,
        "last_approved_verdict_sha256": verdict_sha,
        "crossing_candidate_sha": str(receipt.get("candidate_sha") or ""),
        "crossing_candidate_not_adopted": str(receipt.get("candidate_sha") or "") != last_approved_sha,
    }
    runtime_migration = _runtime_migration_ref(parent_segment)
    if runtime_migration is not None:
        source_admission["runtime_migration"] = copy.deepcopy(runtime_migration)
    # A previously published child is a replay, not a request for a second
    # operational budget allocation. A new child must first pass the complete
    # mission-wide spend reconciliation before any successor artifacts appear.
    next_segment_path = _segment_path(repo, mission_id, next_number)
    if not next_segment_path.exists():
        _verified_mission_spend(
            repo, mission_doc, current_run_id=parent_run_id, db_path=db_path,
        )
    return _create_child_segment(
        repo,
        mission_doc=mission_doc,
        mission_sha=mission_sha,
        segment_number=next_number,
        predecessor_run_id=parent_run_id,
        baseline_sha=last_approved_sha,
        source_program=parent_program,
        source_state=parent_state,
        source_admission=source_admission,
        db_path=db_path,
    )


def _parent_job_snapshot(
    canonical_repo: Path,
    run_id: str,
    *,
    db_path: Path | None = None,
) -> dict[str, Any]:
    row = _job_snapshot_if_present(canonical_repo, run_id, db_path=db_path)
    if row is None:
        raise MissionAuthorityError("mission segment has no supervisor enrollment")
    return row


def _job_snapshot_if_present(
    canonical_repo: Path,
    run_id: str,
    *,
    db_path: Path | None = None,
) -> dict[str, Any] | None:
    db = db_path or supervisor_db.default_db_path()
    repo_text = str(Path(canonical_repo).resolve(strict=False))
    with supervisor_db._managed_connect_readonly(db) as conn:
        rows = conn.execute(
            "SELECT * FROM jobs WHERE repo=? AND run_id=? ORDER BY id",
            (repo_text, run_id),
        ).fetchall()
    if len(rows) > 1:
        raise MissionAuthorityError("mission segment has conflicting duplicate supervisor enrollments")
    if not rows:
        return None
    return dict(rows[0])


def _mission_job_ids(repo: Path, mission_doc: dict[str, Any]) -> tuple[list[str], set[str]]:
    """Resolve all durable source/segment enrollments in mission order."""
    segment_ids: list[str] = []
    for number in range(1, int(mission_doc.get("max_segments") or 0) + 1):
        path = _segment_path(repo, str(mission_doc["mission_id"]), number)
        if not path.exists():
            continue
        segment, _ = _read_record(path, expected_schema=SEGMENT_SCHEMA)
        segment_ids.append(str(segment["run_id"]))
    external_ids = mission_doc.get("operational_source_run_ids") or []
    if (
        not isinstance(external_ids, list)
        or any(not isinstance(value, str) or not value for value in external_ids)
        or len(external_ids) != len(set(external_ids))
        or set(external_ids).intersection(segment_ids)
    ):
        raise MissionAuthorityError("mission operational source-run identity is malformed")
    return segment_ids + list(external_ids), set(external_ids)


def _verified_mission_spend(
    repo: Path,
    mission_doc: dict[str, Any],
    *,
    current_run_id: str,
    db_path: Path | None,
    target_runtime_generation: str | None = None,
    runtime_migration_from_generation: str | None = None,
    allow_quarantined_current: bool = False,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """Reconcile mission-wide operational usage without granting a new envelope."""
    run_ids, external_ids = _mission_job_ids(repo, mission_doc)
    db = db_path or supervisor_db.default_db_path()
    repo_text = str(repo.resolve(strict=False))
    jobs: list[dict[str, Any]] = []
    attempt_rows_by_job: dict[int, list[dict[str, Any]]] = {}
    with supervisor_db._managed_connect_readonly(db) as conn:
        for run_id in run_ids:
            rows = conn.execute(
                "SELECT * FROM jobs WHERE repo=? AND run_id=? ORDER BY id",
                (repo_text, run_id),
            ).fetchall()
            if len(rows) > 1:
                raise MissionAuthorityError("mission has duplicate supervisor enrollments")
            if not rows:
                if run_id == current_run_id:
                    continue
                raise MissionAuthorityError(f"mission source enrollment is missing: {run_id}")
            job = dict(rows[0])
            if any(job.get(key) is not None for key in (
                "worker_pid", "worker_pgid", "worker_attempt_id", "worker_role",
            )):
                raise MissionAuthorityError("mission operational envelope cannot be rebound while a worker is owned")
            if run_id != current_run_id and job.get("status") not in {"QUEUED", "DONE"}:
                raise MissionAuthorityError("prior mission segment is not at a safe terminal/queued boundary")
            current_safe_statuses = {"QUEUED", "DONE"}
            if allow_quarantined_current:
                current_safe_statuses.add("QUARANTINED")
            if run_id == current_run_id and job.get("status") not in current_safe_statuses:
                raise MissionAuthorityError("current mission run is not eligible for safe enqueue")
            if int(job.get("legacy_budget_ambiguous") or 0):
                raise MissionAuthorityError("mission operational usage has an ambiguous legacy budget")
            attempt_rows = [dict(item) for item in conn.execute(
                "SELECT * FROM semantic_attempts WHERE job_id=? ORDER BY started_at, attempt_id",
                (int(job["id"]),),
            ).fetchall()]
            if any(item.get("status") in {"RESERVED", "RUNNING"} for item in attempt_rows):
                raise MissionAuthorityError("mission has a nonterminal semantic attempt")
            for item in attempt_rows:
                if item.get("completed_at") is None:
                    raise MissionAuthorityError("mission contains an attempt without terminal timestamp")
            cost = sum(float(item.get("cost_usd") or 0.0) for item in attempt_rows)
            tokens = {
                "total_input_tokens": sum(int(item.get("input_tokens") or 0) for item in attempt_rows),
                "total_output_tokens": sum(int(item.get("output_tokens") or 0) for item in attempt_rows),
                "total_cache_read_tokens": sum(int(item.get("cache_read_tokens") or 0) for item in attempt_rows),
                "total_cache_creation_tokens": sum(int(item.get("cache_creation_tokens") or 0) for item in attempt_rows),
            }
            if not math.isclose(float(job.get("total_cost_usd") or 0.0), cost, rel_tol=0.0, abs_tol=1e-7):
                raise MissionAuthorityError("mission job cost does not reconcile to semantic attempts")
            if any(int(job.get(key) or 0) != value for key, value in tokens.items()):
                raise MissionAuthorityError("mission job tokens do not reconcile to semantic attempts")
            jobs.append(job)
            attempt_rows_by_job[int(job["id"])] = attempt_rows

    budget = mission_doc.get("operational_budget")
    if not isinstance(budget, dict):
        raise MissionAuthorityError("mission operational budget authority is missing")
    segment_runtime_generations: dict[str, str] = {}
    for number in range(1, int(mission_doc.get("max_segments") or 0) + 1):
        path = _segment_path(repo, str(mission_doc["mission_id"]), number)
        if not path.is_file():
            continue
        segment_authority, _ = _read_record(path, expected_schema=SEGMENT_SCHEMA)
        migration_ref = _runtime_migration_ref(segment_authority)
        if migration_ref is None:
            segment_generation = str(budget.get("runtime_generation") or "")
        else:
            runtime_identity, _ = _runtime_identity_for_segment(
                repo, str(mission_doc["mission_id"]), segment_authority,
            )
            segment_generation = str(runtime_identity.get("runtime_generation") or "")
        if not segment_generation:
            raise MissionAuthorityError("mission segment runtime identity is incomplete")
        segment_runtime_generations[str(segment_authority.get("run_id") or "")] = segment_generation
    segment_rows = [job for job in jobs if str(job.get("run_id")) not in external_ids]
    external_rows = [job for job in jobs if str(job.get("run_id")) in external_ids]
    if not segment_rows:
        # The explicitly admitted legacy predecessor is the durable spend
        # anchor for the first v4 child. During the child's initial enqueue,
        # that deterministic segment exists but its job row does not yet.
        # Permit only this exact typed first-segment shape; every other
        # missing segment enrollment remains a hard refusal.
        current_segment = next(
            (
                _read_record(
                    _segment_path(repo, str(mission_doc["mission_id"]), number),
                    expected_schema=SEGMENT_SCHEMA,
                )[0]
                for number in range(1, int(mission_doc.get("max_segments") or 0) + 1)
                if _segment_path(repo, str(mission_doc["mission_id"]), number).is_file()
                and _read_record(
                    _segment_path(repo, str(mission_doc["mission_id"]), number),
                    expected_schema=SEGMENT_SCHEMA,
                )[0].get("run_id") == current_run_id
            ),
            None,
        )
        source_admission = (current_segment or {}).get("source_admission") or {}
        predecessor = str((current_segment or {}).get("predecessor_run_id") or "")
        if not (
            current_run_id in run_ids
            and int((current_segment or {}).get("segment_number") or 0) == 1
            and source_admission.get("kind") == "explicit_legacy_continuation"
            and predecessor in external_ids
            and external_rows
        ):
            raise MissionAuthorityError("mission has no enrolled segment to bind")
    runner = str(budget.get("runner") or "")
    active_runtime, _, _ = _active_mission_runtime(repo, mission_doc)
    active_generation = str(active_runtime.get("runtime_generation") or "")
    installed_generation = str(supervisor_runtime.runtime_generation() or "")
    if not runner or not active_generation or not installed_generation:
        raise MissionAuthorityError("mission runner/runtime identity is incomplete")
    if (
        runtime_migration_from_generation is not None
        and active_generation != str(runtime_migration_from_generation)
    ):
        raise MissionAuthorityError("active mission runtime migration source differs from sealed identity")
    for job in segment_rows:
        expected_generation = segment_runtime_generations.get(str(job.get("run_id") or ""))
        if (
            str(job.get("runner") or "") != runner
            or str(job.get("runtime_generation") or "") != expected_generation
        ):
            raise MissionAuthorityError("mission segment runner or runtime generation drifted")
    for job in external_rows:
        if str(job.get("runner") or "") != runner:
            raise MissionAuthorityError("authorized historical source run uses a different runner")
        expected_generations = mission_doc.get("operational_source_runtime_generations") or {}
        if expected_generations.get(str(job.get("run_id"))) != str(job.get("runtime_generation") or ""):
            raise MissionAuthorityError("historical source runtime provenance differs from legacy admission")

    current_segment_generation = segment_runtime_generations.get(str(current_run_id))
    if target_runtime_generation is not None:
        if (
            str(target_runtime_generation) != installed_generation
            or str(current_run_id) not in segment_runtime_generations
        ):
            raise MissionAuthorityError("prospective segment runtime differs from commissioned runtime")
        if runtime_migration_from_generation is not None and (
            current_segment_generation != str(runtime_migration_from_generation)
        ):
            raise MissionAuthorityError("active segment runtime migration source differs from sealed identity")
        current_segment_generation = str(target_runtime_generation)
    if current_segment_generation is None:
        # Admission runs just before its deterministic segment is created.
        # In that case the typed migration is already durable in the
        # source-admission record prepared by the caller; otherwise only the
        # currently active mission generation is eligible.
        current_segment_generation = active_generation
    if (
        current_segment_generation != (str(target_runtime_generation) if target_runtime_generation else active_generation)
        or installed_generation != (str(target_runtime_generation) if target_runtime_generation else active_generation)
    ):
        raise MissionAuthorityError("mission cannot enqueue under a different installed runtime generation")

    all_attempts = [item for rows in attempt_rows_by_job.values() for item in rows]
    max_cost = float(budget.get("max_total_cost_usd") or 0.0)
    max_tokens = int(budget.get("max_total_tokens") or 0)
    if max_cost > 0 and any(
        int(item.get("cost_known") or 0) != 1 or int(item.get("cost_accounted") or 0) != 1
        for item in all_attempts
    ):
        raise MissionAuthorityError("finite mission cost ceiling cannot reconcile unknown/unaccounted attempt cost")
    if max_tokens > 0 and any(int(item.get("tokens_known") or 0) != 1 for item in all_attempts):
        raise MissionAuthorityError("finite mission token ceiling cannot reconcile unknown attempt tokens")

    spent = {
        "infra_failures": sum(int(job.get("infra_failures") or 0) for job in jobs),
        "transient_failures": sum(int(job.get("transient_failures") or 0) for job in jobs),
        "transient_recovery_cycles": sum(int(job.get("transient_recovery_cycles") or 0) for job in jobs),
        "total_cost_usd": sum(float(job.get("total_cost_usd") or 0.0) for job in jobs),
        "total_tokens": sum(sum(int(job.get(key) or 0) for key in (
            "total_input_tokens", "total_output_tokens", "total_cache_read_tokens", "total_cache_creation_tokens",
        )) for job in jobs),
    }
    keys = (
        ("max_infra_failures", "infra_failures", 3),
        ("max_transient_failures", "transient_failures", 8),
        ("max_transient_recovery_cycles", "transient_recovery_cycles", 2),
        ("max_total_cost_usd", "total_cost_usd", 0.0),
        ("max_total_tokens", "total_tokens", 0),
    )
    remaining: dict[str, Any] = {}
    for cap_key, spent_key, default in keys:
        cap = budget.get(cap_key, default)
        cap = float(cap) if cap_key == "max_total_cost_usd" else int(cap or 0)
        if cap <= 0:
            remaining[cap_key] = 0.0 if cap_key == "max_total_cost_usd" else 0
            continue
        left = cap - spent[spent_key]
        if left <= 0:
            raise MissionAuthorityError(f"mission operational ceiling exhausted: {cap_key}")
        remaining[cap_key] = float(left) if cap_key == "max_total_cost_usd" else int(left)

    max_wall = int(budget.get("max_wall_seconds") or 0)
    if max_wall > 0:
        starts = [float(job.get("execution_started_at") or 0.0) for job in jobs]
        starts = [value for value in starts if value > 0]
        if not starts:
            raise MissionAuthorityError("finite mission wall-clock ceiling has no durable start time")
        start = min(starts)
        deadline = start + max_wall
        wall_left = int(deadline - time.time())
        if wall_left <= 0:
            raise MissionAuthorityError("mission wall-clock operational ceiling is exhausted")
        remaining["max_wall_seconds"] = wall_left
        remaining["execution_started_at"] = start
        remaining["parent_deadline_unix"] = deadline
    else:
        remaining["max_wall_seconds"] = 0
        remaining["execution_started_at"] = None
        remaining["parent_deadline_unix"] = None
    remaining["runner"] = runner
    remaining["runtime_generation"] = (
        str(target_runtime_generation) if target_runtime_generation else active_generation
    )
    return remaining, jobs


def _verified_repair_claim_history(
    repo: Path,
    *,
    current_run_id: str,
    mission_id: str,
    execution_order: list[str],
) -> dict[str, Any]:
    """Reconstruct funded repairs from an immutable predecessor/event chain.

    Checkpoint-local mirrors in older states can be stale after a historical
    repair-funding state merge. This projection counts only the durable
    atomic-funding events, recursively verifies every predecessor artifact,
    and requires each cumulative mirror to reconcile before it can be used to
    materialize a typed successor.
    """
    from . import schema_validate

    seen: set[str] = set()
    runs: list[dict[str, Any]] = []
    claims: list[dict[str, Any]] = []
    counts = {str(value): 0 for value in execution_order}
    finalized: set[str] = set()
    current_total = 0

    def visit(run_id: str) -> None:
        nonlocal current_total
        if run_id in seen:
            raise MissionAuthorityError("mission repair-history lineage contains a cycle or duplicate run")
        seen.add(run_id)
        root = state.run_dir(repo, run_id)
        if (root / "STATE_TXN.json").exists():
            raise MissionAuthorityError(f"repair-history source has an unfinished state transaction: {run_id}")
        intact, problems = integrity.assert_artifacts_intact(repo, run_id)
        if not intact:
            raise MissionAuthorityError(
                f"repair-history source artifact chain is invalid for {run_id}: "
                + "; ".join(problems[:8])
            )
        snapshot = state.load_verified(repo, run_id)
        if not isinstance(snapshot, dict) or schema_validate.validate_state(snapshot):
            raise MissionAuthorityError(f"repair-history source state is invalid: {run_id}")
        source_packet = root / "WORK_PACKET.md"
        source_state = state.state_path(repo, run_id)
        source_events = state.events_path(repo, run_id)
        source_meta, _ = packet.parse_packet_file(source_packet)
        source_program = snapshot.get("program") or {}
        events = integrity.read_event_chain(source_events)
        if not events or integrity.compute_event_chain_hash(source_events) != integrity.get_event_chain_hash(source_events):
            raise MissionAuthorityError(f"repair-history source event chain is invalid: {run_id}")

        segment_doc = None
        admission: dict[str, Any] = {}
        parent_id = ""
        if source_meta.get("schema") == packet.MISSION_PROGRAM_SCHEMA_VERSION:
            loaded = load_segment(repo, run_id, state_snapshot=snapshot)
            if loaded is None or loaded[0].get("mission_id") != mission_id:
                raise MissionAuthorityError("repair-history segment is not bound to this mission")
            segment_doc = loaded[0]
            admission = segment_doc.get("source_admission") or {}
            parent_id = str(admission.get("predecessor_run_id") or "")
        else:
            rollover = source_program.get("rollover_provenance") or {}
            parent_id = str(rollover.get("parent_run_id") or "")

        parent_snapshot: dict[str, Any] | None = None
        if parent_id:
            if parent_id == run_id:
                raise MissionAuthorityError("repair-history run names itself as predecessor")
            visit(parent_id)
            parent_snapshot = state.load_verified(repo, parent_id)
            parent_root = state.run_dir(repo, parent_id)
            parent_packet = parent_root / "WORK_PACKET.md"
            parent_state = state.state_path(repo, parent_id)
            parent_events = state.events_path(repo, parent_id)
            if segment_doc is not None:
                if (
                    util.sha256_file(parent_packet) != admission.get("source_packet_sha256")
                    or util.sha256_file(parent_state) != admission.get("source_state_sha256")
                    or integrity.compute_event_chain_hash(parent_events)
                    != admission.get("source_event_chain_sha256")
                ):
                    raise MissionAuthorityError("mission segment predecessor identity changed")
                imported_prefix = admission.get("approved_prefix") or []
                imported_ids = [str(item.get("checkpoint_id") or "") for item in imported_prefix]
                expected_prefix = [item for item in execution_order if item in finalized]
                if imported_ids != expected_prefix:
                    raise MissionAuthorityError("mission segment approved prefix differs from verified predecessor events")
            else:
                rollover = source_program.get("rollover_provenance") or {}
                if (
                    util.sha256_file(parent_packet) != rollover.get("source_packet_sha256")
                    or util.sha256_file(parent_state) != rollover.get("source_state_sha256")
                    or integrity.compute_event_chain_hash(parent_events)
                    != rollover.get("source_event_chain_sha256")
                ):
                    raise MissionAuthorityError("rollover repair-history predecessor identity changed")
                imported = rollover.get("imported_counters") or {}
                parent_program = (parent_snapshot or {}).get("program") or {}
                if int(imported.get("repair_round_count") or 0) != int(
                    (parent_program.get("cumulative_counters") or {}).get("repair_round_count") or 0
                ):
                    raise MissionAuthorityError("rollover repair total differs from its predecessor")

        source_chain_sha = integrity.compute_event_chain_hash(source_events)
        if segment_doc is not None:
            prefix = admission.get("approved_prefix") or []
            if prefix:
                current_ids = list(prefix[-1].get("next_checkpoints") or [])
            else:
                current_ids = list(execution_order[:1])
        elif parent_id:
            rollover = source_program.get("rollover_provenance") or {}
            current_ids = [str(rollover.get("checkpoint_id") or "")]
        else:
            current_ids = list(execution_order[:1])
        if len(current_ids) != 1 or current_ids[0] not in execution_order:
            raise MissionAuthorityError(f"repair-history current checkpoint is ambiguous in {run_id}")

        before_run_total = current_total
        run_claim_count = 0
        for event in events:
            if event.get("event_type") == "program_advanced":
                finalized_id = str(event.get("cp_id_finalized") or "")
                next_ids = event.get("next_checkpoints")
                if (
                    current_ids != [finalized_id]
                    or finalized_id not in execution_order
                    or finalized_id in finalized
                    or not isinstance(next_ids, list)
                ):
                    raise MissionAuthorityError("repair-history checkpoint advancement is out of order")
                finalized.add(finalized_id)
                current_ids = [str(value) for value in next_ids]
                if len(current_ids) > 1 or any(value not in execution_order for value in current_ids):
                    raise MissionAuthorityError("repair-history next-checkpoint set is invalid")
                expected_next = execution_order[execution_order.index(finalized_id) + 1:
                                                 execution_order.index(finalized_id) + 1 + len(current_ids)]
                if current_ids != expected_next:
                    raise MissionAuthorityError("repair-history advancement skipped or reordered a checkpoint")
                continue
            if not (
                event.get("event_type") == "state_transition"
                and event.get("new_state") == "CHANGES_REQUESTED"
                and "repair entitlement claimed atomically" in str(event.get("reason") or "")
            ):
                continue
            if len(current_ids) != 1:
                raise MissionAuthorityError("funded repair event has no unique current checkpoint")
            cp_id = current_ids[0]
            event_sha = str(event.get("event_chain_sha256") or "")
            candidate_sha = str(event.get("commit_sha") or "")
            if not _SHA256_RE.fullmatch(event_sha) or not _FULL_SHA_RE.fullmatch(candidate_sha):
                raise MissionAuthorityError("funded repair event lacks exact event/candidate identity")
            claims.append({
                "run_id": run_id,
                "checkpoint_id": cp_id,
                "timestamp": str(event.get("ts") or ""),
                "candidate_sha": candidate_sha,
                "source_event_sha256": event_sha,
                "reason": str(event.get("reason") or ""),
                "checkpoint_used_before": counts[cp_id],
                "cumulative_used_before": current_total,
                "approved_checkpoints_before": [value for value in execution_order if value in finalized],
            })
            counts[cp_id] += 1
            current_total += 1
            run_claim_count += 1

        program_counters = source_program.get("cumulative_counters") or {}
        state_total = int(snapshot.get("repair_round") or 0)
        program_total = int(program_counters.get("repair_round_count") or 0)
        if state_total != current_total or program_total != current_total:
            raise MissionAuthorityError(
                f"funded repair event count does not reconcile in {run_id}: "
                f"events={current_total}, state={state_total}, program={program_total}"
            )
        runs.append({
            "run_id": run_id,
            "packet_sha256": util.sha256_file(source_packet),
            "state_sha256": util.sha256_file(source_state),
            "event_chain_sha256": source_chain_sha,
            "repair_claims": run_claim_count,
            "cumulative_repairs": current_total,
            "cumulative_repairs_before_run": before_run_total,
        })

    visit(current_run_id)
    current_loaded = load_segment(repo, current_run_id)
    if current_loaded is None:
        raise MissionAuthorityError("current repair-history source lost its mission-segment binding")
    current_segment = current_loaded[0]
    external_ids = list(
        (_read_record(_manifest_path(repo, mission_id), expected_schema=MISSION_SCHEMA)[0]
         .get("operational_source_run_ids") or [])
    )
    if (
        current_segment.get("run_id") != current_run_id
        or not (current_segment.get("source_admission") or {}).get("predecessor_run_id")
        or (current_segment.get("source_admission") or {}).get("predecessor_run_id") not in seen
        or any(run_id not in seen for run_id in external_ids)
    ):
        raise MissionAuthorityError("mission repair-history does not match its sealed legacy source chain")
    return {
        "runs": runs,
        "claims": claims,
        "counts_by_checkpoint": counts,
        "total_claims": current_total,
        "approved_checkpoints": [value for value in execution_order if value in finalized],
    }


def _verify_semantic_budget_reconciliation(
    repo: Path,
    *,
    segment: dict[str, Any],
    program_state: dict[str, Any],
) -> None:
    """Re-prove imported historical repair reallocations against source events."""
    admission = segment.get("source_admission") or {}
    record = admission.get("semantic_budget_reconciliation")
    if (
        not isinstance(record, dict)
        or record.get("schema") != "ownframework-loop-semantic-budget-reconciliation/v1"
        or record.get("mission_id") != segment.get("mission_id")
        or record.get("mission_authority_sha256") != segment.get("mission_authority_sha256")
        or record.get("approved_candidate_sha") != segment.get("baseline_sha")
        or record.get("crossing_candidate_sha") != admission.get("crossing_candidate_sha")
        or record.get("crossing_candidate_sha") == segment.get("baseline_sha")
    ):
        raise MissionAuthorityError("typed semantic-budget reconciliation record is malformed")
    source_run_id = str(admission.get("predecessor_run_id") or "")
    source_root = state.run_dir(repo, source_run_id)
    if (
        not source_run_id
        or util.sha256_file(source_root / "WORK_PACKET.md") != admission.get("source_packet_sha256")
        or util.sha256_file(source_root / "STATE.json") != admission.get("source_state_sha256")
        or integrity.compute_event_chain_hash(source_root / "EVENTS.log")
            != admission.get("source_event_chain_sha256")
    ):
        raise MissionAuthorityError("typed semantic-budget reconciliation source boundary changed")
    source_meta, _ = packet.parse_packet_file(source_root / "WORK_PACKET.md")
    graph = source_meta.get("checkpoint_graph") or {}
    history = _verified_repair_claim_history(
        repo,
        current_run_id=source_run_id,
        mission_id=str(segment.get("mission_id") or ""),
        execution_order=[str(value) for value in graph.get("execution_order") or []],
    )
    if (
        record.get("source_runs") != history["runs"]
        or record.get("source_repair_claim_count") != history["total_claims"]
        or record.get("source_repair_counts_by_checkpoint") != history["counts_by_checkpoint"]
        or int((program_state.get("cumulative_counters") or {}).get("repair_round_count") or 0)
            < history["total_claims"]
    ):
        raise MissionAuthorityError("typed semantic-budget repair history no longer reconciles")
    imported = [
        item for item in program_state.get("semantic_budget_allocations") or []
        if isinstance(item, dict) and item.get("source_event_sha256") is not None
    ]
    imported_ids = [str(item.get("allocation_id") or "") for item in imported]
    if imported_ids != record.get("reconciliation_allocation_ids"):
        raise MissionAuthorityError("typed semantic-budget allocations differ from their segment admission")
    event_claims = {
        str(claim["source_event_sha256"]): claim for claim in history["claims"]
    }
    for allocation in imported:
        claim = event_claims.get(str(allocation.get("source_event_sha256") or ""))
        if (
            claim is None
            or claim.get("checkpoint_id") != allocation.get("checkpoint_id")
            or claim.get("run_id") != allocation.get("run_id")
            or int(allocation.get("local_used_before") or 0)
                != int(claim.get("checkpoint_used_before") or 0)
            or int(allocation.get("cumulative_used_before") or 0)
                != int(claim.get("cumulative_used_before") or 0)
            or allocation.get("reason")
                != "reconciled_pre_policy_funded_repair_from_verified_event_history"
        ):
            raise MissionAuthorityError("historical repair allocation is not bound to its exact funding event")
    source_counts = record.get("source_persisted_local_repair_counts")
    if not isinstance(source_counts, dict):
        raise MissionAuthorityError("semantic-budget reconciliation lacks persisted-counter comparison")
    if set(source_counts) != set(history["counts_by_checkpoint"]):
        raise MissionAuthorityError("semantic-budget reconciliation checkpoint set changed")
    source_program = (state.load_verified(repo, source_run_id) or {}).get("program") or {}
    source_actual = {
        str(item.get("id")): int(item.get("repair_round_count") or 0)
        for item in source_program.get("checkpoints") or []
    }
    if source_actual != source_counts:
        raise MissionAuthorityError("recorded source repair mirrors differ from the immutable source state")
    current_counts = {
        str(item.get("id")): int(item.get("repair_round_count") or 0)
        for item in program_state.get("checkpoints") or []
    }
    if any(
        current_counts.get(cp_id, -1) < actual
        for cp_id, actual in history["counts_by_checkpoint"].items()
    ):
        raise MissionAuthorityError("successor repair counters fell below verified historical funding")


def _historical_repair_reconciliation_allocations(
    *,
    meta: dict[str, Any],
    program_state: dict[str, Any],
    history: dict[str, Any],
) -> list[dict[str, Any]]:
    """Bind historical over-local funded repairs to safe mission capacity."""
    policy = (meta.get("mission_budget") or {}).get("semantic_budget_policy")
    if not isinstance(policy, dict):
        raise MissionAuthorityError("historical repair reconciliation requires the typed policy overlay")
    order = [str(value) for value in (meta.get("checkpoint_graph") or {}).get("execution_order") or []]
    packet_cps = {
        str(item.get("id")): item
        for item in (meta.get("checkpoint_graph") or {}).get("checkpoints") or []
        if isinstance(item, dict)
    }
    counter = "repair_round_count"
    cap_key = "max_repair_rounds"
    cumulative_cap = int((meta.get("risk_budget") or {}).get(cap_key) or 0)
    declared_sum = sum(
        int((item.get("risk_budget") or {}).get(cap_key) or 0)
        for item in packet_cps.values()
    )
    if cumulative_cap < declared_sum:
        raise MissionAuthorityError("sealed mission repair ceiling is below declared checkpoint allocations")
    if program_state.get("semantic_budget_allocations"):
        raise MissionAuthorityError("legacy repair ledger already contains adaptive allocations")
    policy_sha = program.semantic_budget_policy_sha256(meta)
    allocations: list[dict[str, Any]] = []
    donor_used: dict[str, int] = {}
    flex_used = 0
    target_allocated: dict[str, int] = {}

    for claim in history["claims"]:
        cp_id = str(claim["checkpoint_id"])
        if cp_id not in packet_cps:
            raise MissionAuthorityError("funded repair refers to a checkpoint outside the sealed graph")
        cp_budget = packet_cps[cp_id].get("risk_budget") or {}
        local_cap = int(cp_budget.get(cap_key) or 0)
        local_before = int(claim["checkpoint_used_before"])
        if local_before < local_cap:
            continue
        expected_local = local_cap + target_allocated.get(cp_id, 0)
        if local_before != expected_local:
            raise MissionAuthorityError("historical over-local repair count is not sequentially explainable")
        cumulative_before = int(claim["cumulative_used_before"])
        if cumulative_before >= cumulative_cap:
            raise MissionAuthorityError("historical repair claim exceeds the sealed cumulative ceiling")
        current_index = order.index(cp_id)
        approved = set(claim["approved_checkpoints_before"])
        future_reserved = sum(
            max(
                0,
                int(((packet_cps.get(future_id) or {}).get("risk_budget") or {}).get(cap_key) or 0)
                - int(history["counts_by_checkpoint"].get(future_id) or 0),
            )
            for future_id in order[current_index + 1:]
            if future_id not in approved
        ) + program.minimum_one_repair_final_acceptance_reserve(counter)
        if cumulative_cap - cumulative_before - 1 < future_reserved:
            raise MissionAuthorityError("historical repair reclassification would consume future/final acceptance reserve")

        donor_remaining: list[tuple[str, int]] = []
        if policy.get("reclaim_approved_checkpoint_capacity") is True:
            for donor_id in order:
                if donor_id not in approved or donor_id == cp_id:
                    continue
                donor_cap = int(
                    ((packet_cps[donor_id].get("risk_budget") or {}).get(cap_key) or 0)
                )
                remaining = max(
                    0,
                    donor_cap
                    - int(history["counts_by_checkpoint"].get(donor_id) or 0)
                    - donor_used.get(donor_id, 0),
                )
                if remaining:
                    donor_remaining.append((donor_id, remaining))
        flex_remaining = (
            max(0, cumulative_cap - declared_sum - flex_used)
            if policy.get("use_cumulative_slack") is True else 0
        )
        donor_pool = sum(amount for _, amount in donor_remaining)
        pool_before = donor_pool + flex_remaining
        if pool_before < 1:
            raise MissionAuthorityError("historical over-local repairs have no sealed reclaimable authority")

        if donor_remaining:
            source_kind = "approved_checkpoint_capacity"
            source_checkpoint = donor_remaining[0][0]
            donor_used[source_checkpoint] = donor_used.get(source_checkpoint, 0) + 1
        elif flex_remaining:
            source_kind = "mission_cumulative_slack"
            source_checkpoint = None
            flex_used += 1
        else:
            raise MissionAuthorityError("historical repair overage cannot be safely reclassified")

        prior_for_target = target_allocated.get(cp_id, 0)
        body = {
            "schema": "ownframework-loop-semantic-budget-allocation/v1",
            "mission_id": str((program_state.get("mission_segment") or {}).get("mission_id") or ""),
            "run_id": str(claim["run_id"]),
            "checkpoint_id": cp_id,
            "counter_kind": counter,
            "declared_local_cap": local_cap,
            "local_used_before": local_before,
            "cumulative_used_before": cumulative_before,
            "cumulative_cap": cumulative_cap,
            "reserved_remaining_authority": future_reserved,
            "final_acceptance_reserve": program.minimum_one_repair_final_acceptance_reserve(counter),
            "reclaimable_pool_before": pool_before,
            "amount_borrowed": 1,
            "reclaimable_pool_after": pool_before - 1,
            "reason": "reconciled_pre_policy_funded_repair_from_verified_event_history",
            "source_kind": source_kind,
            "source_checkpoint_id": source_checkpoint,
            "source_authority_sha256": policy_sha,
            "source_event_sha256": str(claim["source_event_sha256"]),
            "allocation_number_for_checkpoint_counter": prior_for_target + 1,
            "created_at": str(claim["timestamp"]),
        }
        body["allocation_id"] = program.sha256_text(program.canonical_json_dumps(body))
        allocations.append(body)
        target_allocated[cp_id] = prior_for_target + 1
    return allocations


def continue_blocked_semantic_budget(
    canonical_repo: Path,
    source_run_id: str,
    *,
    expected_mission_id: str,
    expected_mission_authority_sha256: str,
    expected_packet_sha256: str,
    expected_original_baseline_sha: str,
    expected_crossing_candidate_sha: str,
    expected_checkpoint_id: str,
    expected_approved_checkpoint_id: str,
    expected_approved_candidate_sha: str,
    expected_remaining_checkpoints: list[str],
    confirmation: str,
    db_path: Path | None = None,
) -> dict[str, Any]:
    """Derive one explicitly authorized adaptive-budget mission successor.

    The immutable blocked segment is never reopened. The child starts only at
    the last recursively verified APPROVED candidate, carries a typed
    opt-in allocation policy, and records every historical over-local repair
    claim against event-chain evidence before normal supervisor enrollment.
    """
    repo = Path(canonical_repo).resolve(strict=False)
    expected_confirmation = f"CONTINUE-BLOCKED-SEMANTIC-BUDGET:{expected_mission_id}"
    if confirmation != expected_confirmation:
        raise MissionAuthorityError("blocked semantic-budget continuation confirmation does not match mission")
    if (
        not re.fullmatch(r"mission-[a-f0-9]{24}", expected_mission_id)
        or not _SHA256_RE.fullmatch(expected_mission_authority_sha256)
        or not _SHA256_RE.fullmatch(expected_packet_sha256)
        or not _FULL_SHA_RE.fullmatch(expected_original_baseline_sha)
        or not _FULL_SHA_RE.fullmatch(expected_crossing_candidate_sha)
        or not _FULL_SHA_RE.fullmatch(expected_approved_candidate_sha)
        or not expected_approved_checkpoint_id
        or not isinstance(expected_checkpoint_id, str) or not expected_checkpoint_id
        or not isinstance(expected_remaining_checkpoints, list)
        or not expected_remaining_checkpoints
        or len(expected_remaining_checkpoints) != len(set(expected_remaining_checkpoints))
    ):
        raise MissionAuthorityError("blocked semantic-budget continuation identity is malformed")

    loaded = load_segment(repo, source_run_id)
    if loaded is None:
        raise MissionAuthorityError("blocked source is not a sealed mission segment")
    segment, segment_sha, mission_doc, mission_sha = loaded
    if (
        mission_doc.get("mission_id") != expected_mission_id
        or mission_sha != expected_mission_authority_sha256
        or int(segment.get("segment_number") or 0) >= int(mission_doc.get("max_segments") or 0)
    ):
        raise MissionAuthorityError("blocked mission identity or authorized segment count differs")
    if segment.get("run_id") != source_run_id:
        raise MissionAuthorityError("blocked segment authority names a different source run")
    source_root = state.run_dir(repo, source_run_id)
    if (source_root / "STATE_TXN.json").exists():
        raise MissionAuthorityError("blocked source has an unfinished state transaction")
    intact, problems = integrity.assert_artifacts_intact(repo, source_run_id)
    if not intact:
        raise MissionAuthorityError("blocked source artifact chain is invalid: " + "; ".join(problems[:10]))
    source_state = state.load_verified(repo, source_run_id)
    if not isinstance(source_state, dict) or source_state.get("state") != "BLOCKED":
        raise MissionAuthorityError("typed semantic-budget continuation requires the exact BLOCKED source")
    if state.is_stop_requested(repo, source_run_id):
        raise MissionAuthorityError("STOPPED/stop-requested authority is absorbing")
    source_packet_path = source_root / "WORK_PACKET.md"
    source_packet_sha = util.sha256_file(source_packet_path)
    if source_packet_sha != expected_packet_sha256 or segment.get("packet_sha256") != source_packet_sha:
        raise MissionAuthorityError("blocked source packet differs from the explicit sealed identity")
    meta, _ = packet.parse_packet_file(source_packet_path)
    errors = packet.validate_packet_for_approval(meta)
    if errors:
        raise MissionAuthorityError("blocked source packet is not valid: " + "; ".join(errors[:8]))
    if (
        meta.get("schema") != packet.MISSION_PROGRAM_SCHEMA_VERSION
        or not packet.packet_is_program(meta)
        or str(meta.get("target", {}).get("expected_baseline_sha") or "")
            != str(segment.get("baseline_sha") or "")
        or expected_original_baseline_sha != mission_doc.get("mission_original_baseline_sha")
    ):
        raise MissionAuthorityError("blocked source baseline or PROGRAM schema differs from mission authority")
    seal = approval.load_approval(repo, source_run_id)
    seal_ok, seal_reason = approval.validate_approval_binding(
        canonical_repo=repo,
        run_id=source_run_id,
        approval=seal,
        packet=meta,
        packet_path=source_packet_path,
    )
    if not seal_ok:
        raise MissionAuthorityError("blocked source approval binding is invalid: " + seal_reason)

    source_program = source_state.get("program") or {}
    graph_ok, graph_reason = program.verify_frozen_graph(meta, source_program)
    if not graph_ok:
        raise MissionAuthorityError("blocked source frozen PROGRAM graph is invalid: " + graph_reason)
    events_path = state.events_path(repo, source_run_id)
    events = integrity.read_event_chain(events_path)
    if integrity.compute_event_chain_hash(events_path) != integrity.get_event_chain_hash(events_path):
        raise MissionAuthorityError("blocked source event chain is invalid")
    approved_sha, approved_cp, verdict_sha = _verify_approved_prefix(
        meta, source_program, events,
        canonical_repo=repo, segment_doc=segment,
    )
    current_ids = list(source_program.get("current_checkpoints") or [])
    if (
        approved_sha != expected_approved_candidate_sha
        or approved_cp != expected_approved_checkpoint_id
        or current_ids != [expected_checkpoint_id]
        or current_ids[0] in {str(row.get("id")) for row in source_program.get("finalized_checkpoints") or []}
    ):
        raise MissionAuthorityError("blocked source does not follow the exact requested approved prefix")
    if source_state.get("last_candidate_sha") != expected_crossing_candidate_sha:
        raise MissionAuthorityError("blocked candidate differs from the explicit crossing identity")
    candidate_exists = util.run_subprocess(
        ["git", "-C", str(repo), "cat-file", "-e", f"{expected_crossing_candidate_sha}^{{commit}}"],
        timeout=10,
    )
    if candidate_exists.returncode != 0:
        raise MissionAuthorityError("blocked crossing candidate is absent from Git")
    if not build_finalize._ancestor_of(repo, expected_crossing_candidate_sha, expected_approved_candidate_sha):
        raise MissionAuthorityError("blocked candidate is not descended from the approved baseline")
    if not build_finalize._candidate_branch_contains(
        repo, str(segment.get("candidate_branch") or ""), expected_crossing_candidate_sha,
    ):
        raise MissionAuthorityError("blocked candidate is absent from its sealed candidate branch")

    reason = str(source_state.get("terminal_reason") or "")
    if "checkpoint_build_authority_exhausted" not in reason:
        raise MissionAuthorityError("blocked state is not the adjudicated local BUILD-cap exhaustion")
    packet_cp = next(
        (item for item in (meta.get("checkpoint_graph") or {}).get("checkpoints") or []
         if item.get("id") == expected_checkpoint_id),
        None,
    )
    cp_state = next(
        (item for item in source_program.get("checkpoints") or [] if item.get("id") == expected_checkpoint_id),
        None,
    )
    if (
        not isinstance(packet_cp, dict) or not isinstance(cp_state, dict)
        or int(cp_state.get("build_pass_count") or 0)
            != int((packet_cp.get("risk_budget") or {}).get("max_build_passes") or 0)
        or int(source_state.get("build_pass_count") or 0)
            != int((source_program.get("cumulative_counters") or {}).get("build_pass_count") or -1)
        or int(source_state.get("review_pass_count") or 0)
            != int((source_program.get("cumulative_counters") or {}).get("review_pass_count") or -1)
        or int(source_state.get("repair_round") or 0)
            != int((source_program.get("cumulative_counters") or {}).get("repair_round_count") or -1)
    ):
        raise MissionAuthorityError("current checkpoint has not exhausted exactly its sealed local BUILD allocation")

    job = _parent_job_snapshot(repo, source_run_id, db_path=db_path)
    if (
        job.get("status") != "DONE"
        or any(job.get(key) is not None for key in (
            "worker_pid", "worker_pgid", "worker_attempt_id", "worker_role",
        ))
        or job.get("candidate_branch") != segment.get("candidate_branch")
    ):
        raise MissionAuthorityError("blocked source supervisor ownership is not safely terminal")

    order = [str(value) for value in (meta.get("checkpoint_graph") or {}).get("execution_order") or []]
    try:
        checkpoint_index = order.index(expected_checkpoint_id)
    except ValueError as exc:
        raise MissionAuthorityError("requested active checkpoint is absent from the frozen graph") from exc
    if order[checkpoint_index:checkpoint_index + len(expected_remaining_checkpoints)] != expected_remaining_checkpoints:
        raise MissionAuthorityError("requested continuation suffix differs from the frozen checkpoint graph")
    history = _verified_repair_claim_history(
        repo, current_run_id=source_run_id, mission_id=expected_mission_id,
        execution_order=order,
    )
    if (
        history["total_claims"] != sum(history["counts_by_checkpoint"].values())
        or history["total_claims"] != int(source_state.get("repair_round") or 0)
    ):
        raise MissionAuthorityError("source cumulative repair authority differs from verified event history")

    policy_overlay = {
        "schema": "ownframework-loop-semantic-budget-policy/v1",
        "reclaim_approved_checkpoint_capacity": True,
        "use_cumulative_slack": True,
    }
    next_number = int(segment.get("segment_number") or 0) + 1
    if next_number > int(mission_doc.get("max_segments") or 0):
        raise MissionAuthorityError("mission has no remaining segment authority")
    child_id = _segment_run_id(expected_mission_id, next_number)
    baseline_branch = f"ofloop/mission/{expected_mission_id[-12:]}/baseline/s{next_number:02d}"
    child_meta = _derived_packet_meta(
        mission_doc, run_id=child_id, number=next_number,
        baseline_branch=baseline_branch, baseline_sha=approved_sha,
    )
    child_meta.setdefault("mission_budget", {})["semantic_budget_policy"] = copy.deepcopy(policy_overlay)
    allocations = _historical_repair_reconciliation_allocations(
        meta=child_meta, program_state=source_program, history=history,
    )
    repaired_program = json.loads(integrity.canonical_json_dumps(source_program))
    for cp in repaired_program.get("checkpoints") or []:
        cp_id = str(cp.get("id") or "")
        cp["repair_round_count"] = int(history["counts_by_checkpoint"].get(cp_id) or 0)
        events_for_cp = [item for item in history["claims"] if item["checkpoint_id"] == cp_id]
        if events_for_cp:
            evidence = dict(cp.get("last_evidence_sha_by_counter") or {})
            evidence["repair_round_count"] = events_for_cp[-1]["candidate_sha"]
            cp["last_evidence_sha_by_counter"] = evidence
    repaired_program["semantic_budget_policy_sha256"] = program.semantic_budget_policy_sha256(child_meta)
    repaired_program["semantic_budget_allocations"] = allocations
    graph_ok, graph_reason = program.verify_frozen_graph(child_meta, repaired_program)
    if not graph_ok:
        raise MissionAuthorityError("reconciled successor semantic authority is invalid: " + graph_reason)

    # Validate the complete extant operational envelope before publishing an
    # append-only runtime migration. The second check below proves the new
    # generation after that typed migration is durable.
    target_runtime = str(supervisor_runtime.runtime_generation() or "")
    if not target_runtime:
        raise MissionAuthorityError("commissioned runtime generation is unavailable")
    _verified_mission_spend(
        repo, mission_doc, current_run_id=source_run_id, db_path=db_path,
        target_runtime_generation=target_runtime,
    )
    runtime_migration = _publish_runtime_migration(
        repo,
        mission_doc=mission_doc,
        source_segment=segment,
        source_state=source_state,
        source_packet_sha256=source_packet_sha,
        source_event_chain_sha256=integrity.compute_event_chain_hash(events_path),
        approved_checkpoint_id=approved_cp,
        approved_candidate_sha=approved_sha,
        crossing_candidate_sha=expected_crossing_candidate_sha,
    )
    if runtime_migration is not None:
        _verified_mission_spend(
            repo, mission_doc, current_run_id=source_run_id, db_path=db_path,
            target_runtime_generation=str(runtime_migration["runtime_generation"]),
        )

    source_admission = {
        "kind": "blocked_semantic_budget_continuation",
        "mission_original_baseline_sha": expected_original_baseline_sha,
        "parent_run_id": source_run_id,
        "predecessor_run_id": source_run_id,
        "mission_id": expected_mission_id,
        "segment_number": next_number,
        "parent_segment_authority_sha256": segment_sha,
        "source_authority_sha256": segment_sha,
        "source_packet_sha256": source_packet_sha,
        "source_state_sha256": util.sha256_file(state.state_path(repo, source_run_id)),
        "source_event_chain_sha256": integrity.compute_event_chain_hash(events_path),
        "approved_prefix": _capture_approved_prefix(
            repo, source_meta=meta, source_program=source_program,
            source_events=events, source_segment=segment,
        ),
        "last_approved_checkpoint_id": approved_cp,
        "last_approved_candidate_sha": approved_sha,
        "last_approved_verdict_sha256": verdict_sha,
        "crossing_candidate_sha": expected_crossing_candidate_sha,
        "crossing_candidate_not_adopted": True,
        "semantic_budget_policy_overlay": policy_overlay,
        "semantic_budget_reconciliation": {
            "schema": "ownframework-loop-semantic-budget-reconciliation/v1",
            "mission_id": expected_mission_id,
            "mission_authority_sha256": mission_sha,
            "source_runs": history["runs"],
            "source_repair_claim_count": history["total_claims"],
            "source_repair_counts_by_checkpoint": history["counts_by_checkpoint"],
            "source_persisted_local_repair_counts": {
                str(item.get("id")): int(item.get("repair_round_count") or 0)
                for item in source_program.get("checkpoints") or []
            },
            "reconciliation_allocation_ids": [item["allocation_id"] for item in allocations],
            "approved_candidate_sha": approved_sha,
            "crossing_candidate_sha": expected_crossing_candidate_sha,
        },
    }
    if runtime_migration is not None:
        source_admission["runtime_migration"] = runtime_migration

    # This is the typed mission continuation, not mutation/reopening of the
    # blocked segment. Existing exact child authority is replayed idempotently.
    result = _create_child_segment(
        repo,
        mission_doc=mission_doc,
        mission_sha=mission_sha,
        segment_number=next_number,
        predecessor_run_id=source_run_id,
        baseline_sha=approved_sha,
        source_program=repaired_program,
        source_state=source_state,
        source_admission=source_admission,
        db_path=db_path,
    )
    result.update({
        "source_run_id": source_run_id,
        "source_run_unchanged": True,
        "crossing_candidate_not_adopted": True,
        "crossing_candidate_sha": expected_crossing_candidate_sha,
        "approved_checkpoint_id": approved_cp,
        "approved_candidate_sha": approved_sha,
        "approved_verdict_sha256": verdict_sha,
        "historical_repair_claims_reconciled": history["total_claims"],
        "historical_reconciliation_allocations": [item["allocation_id"] for item in allocations],
        "runtime_migration": runtime_migration,
    })
    return result


def enqueue_envelope_for_child(
    canonical_repo: Path,
    run_id: str,
    *,
    runner: str,
    requested: dict[str, Any] | None = None,
    db_path: Path | None = None,
) -> dict[str, Any] | None:
    """Constrain each v4 segment to mission-wide remaining operational limits."""
    repo = Path(canonical_repo).resolve(strict=False)
    try:
        loaded = load_segment(repo, run_id)
    except MissionAuthorityError:
        if initial_segment_waiting_for_enrollment(
            repo, run_id, db_path=db_path, allow_queued_enrollment=True,
        ):
            return None
        raise
    if loaded is None:
        return None
    segment, _, mission_doc, _ = loaded
    if segment.get("run_id") != run_id:
        raise MissionAuthorityError("mission segment record names a different run")
    target = state.load_verified(repo, run_id)
    if not isinstance(target, dict) or target.get("state") not in {"AWAITING_APPROVAL", "READY_TO_BUILD"}:
        raise MissionAuthorityError("mission segment is not in a pre-execution enqueue state")
    envelope, _jobs = _verified_mission_spend(
        repo, mission_doc, current_run_id=run_id, db_path=db_path,
    )
    if runner != envelope["runner"]:
        raise MissionAuthorityError("mission enqueue runner differs from frozen mission identity")
    for key in (
        "max_infra_failures", "max_transient_failures", "max_transient_recovery_cycles",
        "max_total_cost_usd", "max_total_tokens", "max_wall_seconds",
    ):
        supplied = (requested or {}).get(key)
        if supplied is not None and supplied != envelope.get(key):
            raise MissionAuthorityError(f"enqueue request would alter mission ceiling {key}")
    return envelope


def _finalized_checkpoint_evidence_sha256(
    program_state: dict[str, Any], checkpoint_id: str,
) -> str | None:
    """Return the unique finalized-evidence digest for one checkpoint.

    Legacy PROGRAM state stores this binding in ``finalized_checkpoints``;
    the per-checkpoint progress row intentionally does not contain it.
    """
    rows = program_state.get("finalized_checkpoints") or []
    matches = [
        row for row in rows
        if isinstance(row, dict) and row.get("id") == checkpoint_id
    ]
    if len(matches) != 1:
        return None
    digest = str(matches[0].get("evidence_sha256") or "")
    return digest if _SHA256_RE.fullmatch(digest) else None


def _validate_legacy_source(
    repo: Path,
    predecessor_run_id: str,
    *,
    expected_packet_sha256: str,
    expected_baseline_sha: str,
    approved_checkpoint_id: str,
    approved_candidate_sha: str,
    crossing_candidate_sha: str,
    expected_remaining_checkpoints: list[str],
    authorized_scope_paths: list[str],
    expected_approved_source_lines: int | None,
    db_path: Path | None,
) -> dict[str, Any]:
    """Prove a legacy BLOCKED source-ceiling run without mutating its record."""
    from . import assessment, program_rollover, receipts, schema_validate, verdicts

    root = state.run_dir(repo, predecessor_run_id)
    if (root / "STATE_TXN.json").exists():
        raise MissionAuthorityError("legacy predecessor has an unfinished state transaction")
    intact, problems = integrity.assert_artifacts_intact(repo, predecessor_run_id)
    if not intact:
        raise MissionAuthorityError("legacy predecessor artifact chain is invalid: " + "; ".join(problems[:10]))
    state_path = root / "STATE.json"
    events_path = root / "EVENTS.log"
    current = state.load_verified(repo, predecessor_run_id)
    if not isinstance(current, dict) or schema_validate.validate_state(current):
        raise MissionAuthorityError("legacy predecessor state is missing or schema-invalid")
    if current.get("state") != "BLOCKED" or state.is_stop_requested(repo, predecessor_run_id):
        raise MissionAuthorityError("legacy continuation requires BLOCKED, not STOPPED, state")
    state_ok, state_reason = integrity.verify_state_sha(state_path, events_path)
    events = integrity.read_event_chain(events_path)
    if not state_ok or not events or integrity.compute_event_chain_hash(events_path) != integrity.get_event_chain_hash(events_path):
        raise MissionAuthorityError("legacy predecessor state/event chain is invalid: " + state_reason)

    packet_path = root / "WORK_PACKET.md"
    packet_bytes = packet_path.read_bytes()
    packet_sha = hashlib.sha256(packet_bytes).hexdigest()
    if packet_sha != expected_packet_sha256:
        raise MissionAuthorityError("legacy predecessor packet SHA differs from the explicit authority")
    meta, _ = packet.parse_packet_file(packet_path)
    if meta.get("schema") not in (packet.PROGRAM_SCHEMA_VERSION,) or not packet.packet_is_program(meta):
        raise MissionAuthorityError("legacy admission requires an unchanged v3 PROGRAM packet")
    if packet.validate_packet_for_approval(meta):
        raise MissionAuthorityError("legacy predecessor packet is invalid")

    seal = approval.load_approval(repo, predecessor_run_id)
    ok, reason = approval.validate_approval_binding(
        canonical_repo=repo, run_id=predecessor_run_id, approval=seal,
        packet=meta, packet_path=packet_path,
    )
    if not ok:
        raise MissionAuthorityError("legacy predecessor approval is invalid: " + reason)
    original_baseline = str((seal or {}).get("baseline_sha") or "")
    baseline_branch = str((seal or {}).get("baseline_branch") or "")
    candidate_branch = str((seal or {}).get("candidate_branch") or "")
    if original_baseline != expected_baseline_sha:
        raise MissionAuthorityError("legacy predecessor baseline differs from the explicit authority")
    if git_checks.branch_head(repo, baseline_branch) != original_baseline:
        raise MissionAuthorityError("legacy predecessor baseline branch has moved")
    tracked = util.run_subprocess(
        ["git", "-C", str(repo), "status", "--porcelain", "--untracked-files=no"], timeout=10,
    )
    if tracked.returncode != 0 or tracked.stdout.strip():
        raise MissionAuthorityError("canonical repository has tracked changes")

    program_state = current.get("program") or {}
    graph_ok, graph_reason = program.verify_frozen_graph(meta, program_state)
    if not graph_ok:
        raise MissionAuthorityError("legacy predecessor PROGRAM graph is invalid: " + graph_reason)
    execution_order = [str(value) for value in (meta.get("checkpoint_graph") or {}).get("execution_order") or []]
    finalized_rows = program_state.get("finalized_checkpoints") or []
    finalized_ids = [str(row.get("id") or "") for row in finalized_rows if isinstance(row, dict)]
    if (
        len(finalized_ids) != len(finalized_rows)
        or finalized_ids != execution_order[:len(finalized_ids)]
        or any(row.get("terminal_state") != "APPROVED" for row in finalized_rows)
        or approved_checkpoint_id not in finalized_ids
    ):
        raise MissionAuthorityError("legacy finalized checkpoint history is not an approved graph prefix")
    if execution_order[finalized_ids.index(approved_checkpoint_id)] != approved_checkpoint_id:
        raise MissionAuthorityError("approved checkpoint is not in the frozen graph")
    expected_remaining = execution_order[finalized_ids.index(approved_checkpoint_id) + 1:]
    current_ids = [str(value) for value in (program_state.get("current_checkpoints") or [])]
    if expected_remaining_checkpoints != expected_remaining or current_ids != [expected_remaining[0]]:
        raise MissionAuthorityError("legacy remaining checkpoint authority differs from the frozen graph")
    if not finalized_ids or finalized_ids[-1] != approved_checkpoint_id:
        raise MissionAuthorityError("legacy admission anchor is not the latest approved checkpoint")

    checkpoint_by_id = {
        str(item.get("id")): item
        for item in (program_state.get("checkpoints") or []) if isinstance(item, dict)
    }
    if any(checkpoint_by_id.get(cp_id, {}).get("terminal") != "APPROVED" for cp_id in finalized_ids):
        raise MissionAuthorityError("finalized checkpoint list contradicts checkpoint terminal state")
    if any(
        checkpoint_by_id.get(cp_id, {}).get("terminal") != ""
        for cp_id in expected_remaining_checkpoints
    ):
        raise MissionAuthorityError("a remaining checkpoint already has terminal evidence")

    advanced = [event for event in events if event.get("event_type") == "program_advanced"]
    advanced_ids = [str(event.get("cp_id_finalized") or "") for event in advanced]
    if advanced_ids != finalized_ids or len(advanced_ids) != len(set(advanced_ids)):
        raise MissionAuthorityError("program advancement events do not exactly match the approved prefix")
    approved_event = advanced[-1] if advanced else None
    if (
        not isinstance(approved_event, dict)
        or approved_event.get("cp_terminal") != "APPROVED"
        or approved_event.get("cp_id_finalized") != approved_checkpoint_id
        or approved_event.get("commit_sha") != approved_candidate_sha
        or not _SHA256_RE.fullmatch(str(approved_event.get("verdict_sha256") or ""))
    ):
        raise MissionAuthorityError("last approved checkpoint event does not bind the explicit candidate")
    entry_state = checkpoint_by_id.get(expected_remaining_checkpoints[0]) or {}
    if entry_state.get("checkpoint_entry_candidate_sha") != approved_candidate_sha:
        raise MissionAuthorityError("next checkpoint entry does not bind the last approved candidate")
    if _finalized_checkpoint_evidence_sha256(program_state, approved_checkpoint_id) is None:
        raise MissionAuthorityError("last approved checkpoint lacks finalized evidence binding")

    review_verdict_path = root / "REVIEW_VERDICT.json"
    review_verdict = verdicts.load_verdict(repo, predecessor_run_id)
    if (
        not isinstance(review_verdict, dict)
        or schema_validate.validate_verdict(review_verdict)
        or review_verdict.get("verdict") != "APPROVED"
        or review_verdict.get("checkpoint_id") != approved_checkpoint_id
        or review_verdict.get("candidate_sha_reviewed") != approved_candidate_sha
        or review_verdict.get("review_scope") != "checkpoint"
        or util.sha256_file(review_verdict_path) != approved_event.get("verdict_sha256")
    ):
        raise MissionAuthorityError("latest REVIEW_VERDICT does not prove the last approved checkpoint")

    if current.get("last_candidate_sha") != crossing_candidate_sha:
        raise MissionAuthorityError("legacy crossing candidate differs from blocked STATE")
    receipt = receipts.load_receipt(repo, predecessor_run_id)
    if not isinstance(receipt, dict) or schema_validate.validate_receipt(receipt):
        raise MissionAuthorityError("legacy crossing BUILD_RECEIPT is missing or invalid")
    if (
        receipt.get("candidate_sha") != crossing_candidate_sha
        or receipt.get("baseline_sha") != original_baseline
        or receipt.get("candidate_branch") != candidate_branch
        or receipt.get("packet_sha256") != packet_sha
        or receipt.get("approval_sha256") != approval.approval_artifact_sha256(seal or {})
        or receipt.get("next_state") != "BLOCKED"
        or receipt.get("validation_status") != "PASS"
        or any(not row.get("passed") for row in receipt.get("validation") or [])
        or (receipt.get("candidate_identity_reproof") or {}).get("result") != "pass"
        or (receipt.get("protected_path_check") or {}).get("result") != "pass"
        or (receipt.get("secret_scan_check") or {}).get("result") != "pass"
    ):
        raise MissionAuthorityError("crossing receipt has failures beyond source ceiling and authorized scope")
    source_check = receipt.get("program_source_ceiling_check") or {}
    actual_source_lines = _line_count(repo, original_baseline, crossing_candidate_sha)
    if (
        source_check.get("result") != "fail"
        or source_check.get("accounting") != "absolute_baseline_to_candidate"
        or int(source_check.get("diff_lines_total") or -1) != actual_source_lines
        or int(source_check.get("effective_max_diff_lines") or 0) != 30000
        or actual_source_lines <= 30000
        or int(source_check.get("files_changed_unique") or 0) > int(source_check.get("effective_max_files_changed") or 0)
    ):
        raise MissionAuthorityError("crossing candidate is not proven to exceed only the legacy 30k source ceiling")
    scope_findings = (receipt.get("scope_check") or {}).get("findings") or []
    scope_paths = [str(item.get("path") or "") for item in scope_findings if item.get("kind") == "out_of_scope"]
    if (
        (receipt.get("scope_check") or {}).get("result") != "fail"
        or len(scope_paths) != len(scope_findings)
        or sorted(scope_paths) != sorted(authorized_scope_paths)
        or not authorized_scope_paths
    ):
        raise MissionAuthorityError("scope findings are not exactly the explicitly authorized path correction")
    if (receipt.get("protected_path_check") or {}).get("offending_paths"):
        raise MissionAuthorityError("crossing candidate contains protected-path findings")
    hard_secret_findings = [
        item for item in ((receipt.get("secret_scan_check") or {}).get("findings") or [])
        if item.get("severity") == "hard"
    ]
    if hard_secret_findings:
        raise MissionAuthorityError("crossing candidate contains hard secret findings")

    if not git_checks.commit_exists(repo, approved_candidate_sha) or not git_checks.commit_exists(repo, crossing_candidate_sha):
        raise MissionAuthorityError("legacy approved or crossing candidate commit is missing")
    if not build_finalize._ancestor_of(repo, approved_candidate_sha, original_baseline):
        raise MissionAuthorityError("last approved candidate is not descended from original baseline")
    if not build_finalize._ancestor_of(repo, crossing_candidate_sha, approved_candidate_sha):
        raise MissionAuthorityError("crossing candidate does not descend from last approved candidate")
    if git_checks.branch_head(repo, candidate_branch) != crossing_candidate_sha:
        raise MissionAuthorityError("legacy candidate branch no longer points at the crossing candidate")
    builder_wt = worktrees.builder_worktree(repo, predecessor_run_id)
    reviewer_wt = worktrees.reviewer_worktree(repo, predecessor_run_id)
    for label, worktree, expected_sha in (
        ("builder", builder_wt, crossing_candidate_sha),
        ("reviewer", reviewer_wt, approved_candidate_sha),
    ):
        if (
            not worktree.is_dir()
            or not worktrees.is_registered_worktree(repo, worktree)
            or git_checks.current_head(worktree) != expected_sha
            or git_checks.dirty_status(worktree) != "clean"
        ):
            raise MissionAuthorityError(f"legacy {label} worktree is not registered, clean, and at its expected SHA")
    if git_checks.current_branch(builder_wt) != candidate_branch:
        raise MissionAuthorityError("legacy builder worktree branch differs from sealed candidate branch")

    diff = util.run_subprocess(
        ["git", "-C", str(repo), "diff", "--name-only", original_baseline, crossing_candidate_sha],
        timeout=20,
    )
    if diff.returncode != 0:
        raise MissionAuthorityError("cannot enumerate legacy candidate changed paths")
    changed_paths = sorted({line.strip() for line in diff.stdout.splitlines() if line.strip()})
    if not set(authorized_scope_paths).issubset(changed_paths):
        raise MissionAuthorityError("authorized path correction is not present in the crossing candidate diff")
    unauthorized = [path for path in changed_paths if not packet.is_allowed_path(meta, path)]
    if sorted(unauthorized) != sorted(authorized_scope_paths):
        raise MissionAuthorityError("crossing candidate has additional or unexplained out-of-scope paths")
    for path in authorized_scope_paths:
        if packet._scope_path_error(path) or packet.is_protected_path(meta, path):
            raise MissionAuthorityError("legacy scope correction is not a safe repository-relative product path")
    approved_lines = _line_count(repo, original_baseline, approved_candidate_sha)
    if expected_approved_source_lines is not None and approved_lines != expected_approved_source_lines:
        raise MissionAuthorityError("last approved candidate source-line count differs from the explicit expected value")

    build_total = int(current.get("build_pass_count") or 0)
    review_total = int(current.get("review_pass_count") or 0)
    repair_total = int(current.get("repair_round") or 0)
    counters = program_state.get("cumulative_counters") or {}
    if (
        int(counters.get("build_pass_count") or -1) != build_total
        or int(counters.get("review_pass_count") or -1) != review_total
        or int(counters.get("repair_round_count") or -1) != repair_total
    ):
        raise MissionAuthorityError("legacy state and cumulative PROGRAM counters do not reconcile")
    job, attempts, accounting = program_rollover._db_parent_snapshot(
        repo, predecessor_run_id, db_path=db_path, require_global_idle=True,
    )
    if job.get("status") != "DONE" or job.get("run_id") != predecessor_run_id:
        raise MissionAuthorityError("legacy predecessor supervisor enrollment is not terminal DONE")
    return {
        "state": current,
        "packet_meta": meta,
        "packet_sha256": packet_sha,
        "approval": seal,
        "approval_file_sha256": util.sha256_file(approval.approval_path(repo, predecessor_run_id)),
        "approval_sha256": approval.approval_artifact_sha256(seal or {}),
        "baseline_sha": original_baseline,
        "baseline_branch": baseline_branch,
        "candidate_branch": candidate_branch,
        "program": program_state,
        "events": events,
        "approved_prefix": _capture_approved_prefix(
            repo, source_meta=meta, source_program=program_state,
            source_events=events, source_segment=None,
        ),
        "event_chain_sha256": integrity.compute_event_chain_hash(events_path),
        "state_sha256": util.sha256_file(state_path),
        "review_verdict_sha256": util.sha256_file(review_verdict_path),
        "build_receipt_sha256": util.sha256_file(root / "BUILD_RECEIPT.json"),
        "approved_verdict_sha256": str(approved_event["verdict_sha256"]),
        "approved_source_lines": approved_lines,
        "changed_paths": changed_paths,
        "scope_paths": scope_paths,
        "job": job,
        "attempts": attempts,
        "accounting": accounting,
    }


def admit_legacy_continuation(
    canonical_repo: Path,
    predecessor_run_id: str,
    *,
    expected_packet_sha256: str,
    expected_baseline_sha: str,
    approved_checkpoint_id: str,
    approved_candidate_sha: str,
    crossing_candidate_sha: str,
    expected_remaining_checkpoints: list[str],
    authorized_scope_paths: list[str],
    segment_max_diff_lines: int,
    mission_max_diff_lines: int,
    max_segments: int,
    expected_approved_source_lines: int | None,
    confirmation: str,
    db_path: Path | None = None,
) -> dict[str, Any]:
    """Explicitly admit one verified legacy PROGRAM without changing its run."""
    repo = Path(canonical_repo).resolve(strict=False)
    if confirmation != f"LEGACY-CONTINUE:{predecessor_run_id}":
        raise MissionAuthorityError("typed legacy continuation confirmation does not match predecessor run")
    if (
        not _SHA256_RE.fullmatch(expected_packet_sha256)
        or not _FULL_SHA_RE.fullmatch(expected_baseline_sha)
        or not _FULL_SHA_RE.fullmatch(approved_candidate_sha)
        or not _FULL_SHA_RE.fullmatch(crossing_candidate_sha)
    ):
        raise MissionAuthorityError("legacy continuation requires full exact SHA identities")
    if (
        not isinstance(expected_remaining_checkpoints, list)
        or not expected_remaining_checkpoints
        or len(expected_remaining_checkpoints) != len(set(expected_remaining_checkpoints))
    ):
        raise MissionAuthorityError("legacy continuation remaining checkpoint list is invalid")
    if (
        not isinstance(authorized_scope_paths, list)
        or not authorized_scope_paths
        or len(authorized_scope_paths) != len(set(authorized_scope_paths))
        or len(authorized_scope_paths) > 16
    ):
        raise MissionAuthorityError("legacy continuation scope correction list is invalid")
    if (
        isinstance(segment_max_diff_lines, bool)
        or isinstance(mission_max_diff_lines, bool)
        or isinstance(max_segments, bool)
        or not 1 <= int(segment_max_diff_lines) <= 30000
        or int(mission_max_diff_lines) < int(segment_max_diff_lines)
        or not 1 <= int(max_segments) <= 16
    ):
        raise MissionAuthorityError("legacy continuation source budget/segment count is outside its typed envelope")

    validated = _validate_legacy_source(
        repo, predecessor_run_id,
        expected_packet_sha256=expected_packet_sha256,
        expected_baseline_sha=expected_baseline_sha,
        approved_checkpoint_id=approved_checkpoint_id,
        approved_candidate_sha=approved_candidate_sha,
        crossing_candidate_sha=crossing_candidate_sha,
        expected_remaining_checkpoints=expected_remaining_checkpoints,
        authorized_scope_paths=authorized_scope_paths,
        expected_approved_source_lines=expected_approved_source_lines,
        db_path=db_path,
    )
    source_meta = copy.deepcopy(validated["packet_meta"])
    source_meta["schema"] = packet.MISSION_PROGRAM_SCHEMA_VERSION
    source_meta["risk_budget"]["max_diff_lines"] = int(segment_max_diff_lines)
    source_meta["checkpoint_graph"]["global_source_ceilings"]["max_baseline_to_final_diff_lines"] = int(segment_max_diff_lines)
    source_meta["allowed_paths"] = list(source_meta.get("allowed_paths") or [])
    for path in authorized_scope_paths:
        if packet.is_allowed_path(source_meta, path):
            raise MissionAuthorityError(f"legacy scope path is already covered and needs no admission: {path}")
        source_meta["allowed_paths"].append(path)
    cp_id = expected_remaining_checkpoints[0]
    cp_meta = next(
        (cp for cp in (source_meta.get("checkpoint_graph") or {}).get("checkpoints") or [] if cp.get("id") == cp_id),
        None,
    )
    if not isinstance(cp_meta, dict):
        raise MissionAuthorityError("legacy current checkpoint is absent from packet graph")
    required_paths = list(cp_meta.get("required_paths") or [])
    for path in authorized_scope_paths:
        if path not in required_paths:
            required_paths.append(path)
    cp_meta["required_paths"] = required_paths
    source_meta["mission_budget"] = {
        "schema": "ownframework-loop-mission-budget/v1",
        "auto_segment": True,
        "segment_max_diff_lines": int(segment_max_diff_lines),
        "mission_max_diff_lines": int(mission_max_diff_lines),
        "max_segments": int(max_segments),
        "segment_boundary_policy": "last_approved_checkpoint",
    }
    errors = packet.validate_packet_for_approval(source_meta)
    if errors:
        raise MissionAuthorityError("corrected v4 authority projection is invalid: " + "; ".join(errors[:20]))

    original = validated["packet_meta"]
    immutable_diff = {
        "schema": [original.get("schema"), source_meta.get("schema")],
        "risk_budget.max_diff_lines": [
            (original.get("risk_budget") or {}).get("max_diff_lines"),
            int(segment_max_diff_lines),
        ],
        "checkpoint_graph.global_source_ceilings.max_baseline_to_final_diff_lines": [
            (((original.get("checkpoint_graph") or {}).get("global_source_ceilings") or {}).get("max_baseline_to_final_diff_lines")),
            int(segment_max_diff_lines),
        ],
        "mission_budget": source_meta["mission_budget"],
        "allowed_paths_added": list(authorized_scope_paths),
        "required_paths_added_to_checkpoint": {cp_id: list(authorized_scope_paths)},
    }
    if "created_at" not in source_meta:
        source_meta["created_at"] = original.get("created_at")
    source_approval_sha = validated["approval_sha256"]
    mission_id = _authority_id(
        predecessor_run_id, expected_packet_sha256,
        expected_baseline_sha, source_approval_sha,
    )
    current_runtime = supervisor_runtime.runtime_generation()
    job = validated["job"]
    operational_budget = {
        "runner": str(job.get("runner") or ""),
        "runtime_generation": current_runtime,
        "max_infra_failures": int(job.get("max_infra_failures") or 0),
        "max_transient_failures": int(job.get("max_transient_failures") or 0),
        "max_transient_recovery_cycles": int(job.get("max_transient_recovery_cycles") or 0),
        "max_total_cost_usd": float(job.get("max_total_cost_usd") or 0.0),
        "max_total_tokens": int(job.get("max_total_tokens") or 0),
        "max_wall_seconds": int(job.get("max_wall_seconds") or 0),
    }
    admission_path = _mission_dir(repo, mission_id) / "LEGACY_ADMISSION.json"
    admission_doc = {
        "schema": LEGACY_ADMISSION_SCHEMA,
        "mission_id": mission_id,
        "predecessor_run_id": predecessor_run_id,
        "source_packet_sha256": validated["packet_sha256"],
        "source_approval_file_sha256": validated["approval_file_sha256"],
        "source_approval_sha256": source_approval_sha,
        "source_state_sha256": validated["state_sha256"],
        "source_event_chain_sha256": validated["event_chain_sha256"],
        "source_review_verdict_sha256": validated["review_verdict_sha256"],
        "source_build_receipt_sha256": validated["build_receipt_sha256"],
        "approved_checkpoint_id": approved_checkpoint_id,
        "approved_candidate_sha": approved_candidate_sha,
        "crossing_candidate_sha_not_adopted": crossing_candidate_sha,
        "original_baseline_sha": expected_baseline_sha,
        "approved_source_lines": validated["approved_source_lines"],
        "crossing_source_lines": _line_count(repo, expected_baseline_sha, crossing_candidate_sha),
        "remaining_checkpoints": list(expected_remaining_checkpoints),
        "mission_budget": copy.deepcopy(source_meta["mission_budget"]),
        "mission_contract_sha256": _digest(_authority_projection(source_meta)),
        "authorized_scope_paths": list(authorized_scope_paths),
        "authority_changes": immutable_diff,
        "operational_budget": operational_budget,
        "source_runtime_generation": str(job.get("runtime_generation") or ""),
        "new_runtime_generation": current_runtime,
        "accounting": copy.deepcopy(validated["accounting"]),
        "attempt_count": len(validated["attempts"]),
        "admitted_at": util.utc_now_iso(),
    }
    admission_dir = admission_path.parent
    admission_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    if admission_path.exists():
        prior, prior_sha = _read_record(admission_path, expected_schema=LEGACY_ADMISSION_SCHEMA)
        comparable_prior = dict(prior)
        comparable_new = dict(admission_doc)
        comparable_prior.pop("admitted_at", None)
        comparable_new.pop("admitted_at", None)
        if comparable_prior != comparable_new:
            raise MissionAuthorityError("one-time legacy admission already exists with conflicting authority")
        admission_doc = prior
        admission_sha = prior_sha
    else:
        admission_sha = _write_once(admission_path, admission_doc)

    mission_doc = {
        "schema": MISSION_SCHEMA,
        "mission_id": mission_id,
        "source_run_id": predecessor_run_id,
        "source_packet_sha256": expected_packet_sha256,
        "source_approval_sha256": source_approval_sha,
        "mission_original_baseline_sha": expected_baseline_sha,
        "mission_max_diff_lines": int(mission_max_diff_lines),
        "mission_max_unique_changed_files": _mission_unique_file_ceiling(
            source_meta, validated["program"],
        ),
        "segment_max_diff_lines": int(segment_max_diff_lines),
        "auto_segment": True,
        "max_segments": int(max_segments),
        "segment_boundary_policy": "last_approved_checkpoint",
        "operational_budget": operational_budget,
        "operational_source_run_ids": [predecessor_run_id],
        "operational_source_runtime_generations": {
            predecessor_run_id: str(job.get("runtime_generation") or ""),
        },
        "legacy_admission_sha256": admission_sha,
        "authority_projection_sha256": _digest(_authority_projection(source_meta)),
        "template_meta": source_meta,
        "template_markdown_tail": _markdown_tail(state.run_dir(repo, predecessor_run_id) / "WORK_PACKET.md"),
    }
    mission_sha = _write_once(_manifest_path(repo, mission_id), mission_doc)
    source_admission = {
        "kind": "explicit_legacy_continuation",
        "mission_original_baseline_sha": expected_baseline_sha,
        "legacy_admission_sha256": admission_sha,
        "predecessor_run_id": predecessor_run_id,
        "mission_id": mission_id,
        "segment_number": 1,
        "source_authority_sha256": admission_sha,
        "source_packet_sha256": validated["packet_sha256"],
        "source_state_sha256": validated["state_sha256"],
        "source_event_chain_sha256": validated["event_chain_sha256"],
        "approved_prefix": copy.deepcopy(validated["approved_prefix"]),
        "last_approved_checkpoint_id": approved_checkpoint_id,
        "last_approved_candidate_sha": approved_candidate_sha,
        "last_approved_verdict_sha256": validated["approved_verdict_sha256"],
        "crossing_candidate_sha": crossing_candidate_sha,
        "crossing_candidate_not_adopted": True,
    }
    child = _create_child_segment(
        repo,
        mission_doc=mission_doc,
        mission_sha=mission_sha,
        segment_number=1,
        predecessor_run_id=predecessor_run_id,
        baseline_sha=approved_candidate_sha,
        source_program=validated["program"],
        source_state=validated["state"],
        source_admission=source_admission,
        db_path=db_path,
    )
    return {
        **child,
        "legacy_admission_sha256": admission_sha,
        "source_packet_sha256": expected_packet_sha256,
        "source_state_sha256": validated["state_sha256"],
        "source_event_chain_sha256": validated["event_chain_sha256"],
        "source_crossing_candidate_preserved": crossing_candidate_sha,
        "source_run_unchanged": True,
        "source_build_pass_count": int(validated["state"].get("build_pass_count") or 0),
        "source_review_pass_count": int(validated["state"].get("review_pass_count") or 0),
        "source_repair_round": int(validated["state"].get("repair_round") or 0),
    }


def reconcile_pending_boundaries(*, db_path: Path | None = None) -> dict[str, Any]:
    """Replay eligible parent boundaries into their deterministic successors."""
    db = db_path or supervisor_db.default_db_path()
    processed: list[dict[str, Any]] = []
    with supervisor_db._managed_connect_readonly(db) as conn:
        rows = conn.execute(
            "SELECT * FROM jobs WHERE status IN ('QUEUED','DONE') ORDER BY id"
        ).fetchall()
    for row in rows:
        repo = Path(str(row["repo"])).resolve(strict=False)
        run_id = str(row["run_id"])
        try:
            current = state.load_verified(repo, run_id)
            if not isinstance(current, dict) or current.get("state") != "SEGMENT_BOUNDARY":
                continue
            if any(row[key] is not None for key in ("worker_pid", "worker_pgid", "worker_attempt_id", "worker_role")):
                continue
            child = create_segment_successor(repo, run_id, db_path=db)
            from . import supervisor as supervisor_mod
            child_job = _job_snapshot_if_present(repo, str(child["run_id"]), db_path=db)
            if child_job is None:
                result = supervisor_mod.enqueue(
                    canonical_repo=repo,
                    run_id=str(child["run_id"]),
                    runner=str(row["runner"] or "claude-code"),
                    db_path=db,
                )
                if not result.get("ok"):
                    raise MissionAuthorityError(
                        "mission successor was created but supervisor enrollment refused: "
                        + str(result.get("reason") or result)
                    )
            elif child_job.get("repo") != str(repo) or child_job.get("run_id") != str(child["run_id"]):
                raise MissionAuthorityError("existing successor enrollment has a conflicting identity")
            else:
                child_loaded = load_segment(repo, str(child["run_id"]))
                child_state = state.load_verified(repo, str(child["run_id"]))
                if child_loaded is None:
                    raise MissionAuthorityError("existing successor has no verified mission segment authority")
                child_segment, _, child_mission, _ = child_loaded
                expected_runtime = str(
                    (child_mission.get("operational_budget") or {}).get("runtime_generation") or ""
                )
                expected_runner = str(
                    (child_mission.get("operational_budget") or {}).get("runner") or ""
                )
                status = str(child_job.get("status") or "")
                if (
                    str(child_job.get("candidate_branch") or "") != str(child_segment.get("candidate_branch") or "")
                    or str(child_job.get("runtime_generation") or "") != expected_runtime
                    or str(child_job.get("runner") or "") != expected_runner
                    or str(child_job.get("execution_mode") or "").upper() != "PROGRAM"
                    or status not in {
                        "QUEUED", "RUNNING", "BACKOFF", "QUARANTINED", "HELD",
                        "DONE", "RETIRED",
                    }
                ):
                    raise MissionAuthorityError("existing successor enrollment differs from frozen segment identity")
                if status in {"DONE", "RETIRED"} and (
                    not isinstance(child_state, dict)
                    or child_state.get("state") not in {
                        "APPROVED", "BLOCKED", "STOPPED", "SEGMENT_BOUNDARY",
                    }
                ):
                    raise MissionAuthorityError(
                        "terminal successor enrollment contradicts its engineering state"
                    )
            processed.append({"parent_run_id": run_id, **child, "enqueued": True})
        except MissionAuthorityError as exc:
            processed.append({"parent_run_id": run_id, "ok": False, "error": str(exc)})
    return {"ok": all(item.get("ok", True) for item in processed), "processed": processed}


def mission_status(canonical_repo: Path, mission_id: str, *, db_path: Path | None = None) -> dict[str, Any]:
    """Read-only mission projection; segment records remain authoritative."""
    repo = Path(canonical_repo).resolve(strict=False)
    mission_doc, mission_sha = _read_record(_manifest_path(repo, mission_id), expected_schema=MISSION_SCHEMA)
    segments: list[dict[str, Any]] = []
    latest_state: dict[str, Any] | None = None
    previous_run_id: str | None = None
    for number in range(1, int(mission_doc.get("max_segments") or 0) + 1):
        path = _segment_path(repo, mission_id, number)
        if not path.exists() and not path.is_symlink():
            continue
        segment, digest = _read_record(path, expected_schema=SEGMENT_SCHEMA)
        if (
            segment.get("mission_id") != mission_id
            or segment.get("segment_number") != number
            or (number > 1 and segment.get("predecessor_run_id") != previous_run_id)
        ):
            raise MissionAuthorityError("mission segment sequence or predecessor lineage is inconsistent")
        run_id = str(segment.get("run_id") or "")
        loaded = load_segment(repo, run_id)
        if loaded is None or loaded[1] != digest or loaded[0] != segment:
            raise MissionAuthorityError("mission segment does not match the run's verified packet/state binding")
        current = state.load_verified(repo, run_id)
        if not isinstance(current, dict):
            raise MissionAuthorityError("mission segment state is unavailable or unverifiable")
        from . import supervisor as supervisor_mod
        job = supervisor_mod.status(canonical_repo=repo, run_id=run_id, db_path=db_path)
        job_status = str(job.get("status") or "")
        if job_status in {"LEDGER_UNREADABLE", "LEDGER_AMBIGUOUS"}:
            raise MissionAuthorityError(f"mission segment supervisor ledger is {job_status.lower()}")
        if not job.get("ok") and job_status != "NOT_ENQUEUED":
            raise MissionAuthorityError("mission segment supervisor status could not be proven")
        program_state = current.get("program") or {}
        segments.append({
            **segment,
            "segment_authority_sha256": digest,
            "engineering_state": current.get("state"),
            "supervisor_status": job_status,
            "current_checkpoint": list(program_state.get("current_checkpoints") or []),
            "last_candidate_sha": current.get("last_candidate_sha"),
            "finalized_checkpoints": [
                str(item.get("id"))
                for item in program_state.get("finalized_checkpoints") or []
                if isinstance(item, dict) and item.get("id")
            ],
            "observed_cost_usd": float(job.get("total_cost_usd") or 0.0),
            "observed_input_tokens": int(job.get("total_input_tokens") or 0),
            "observed_output_tokens": int(job.get("total_output_tokens") or 0),
            "observed_cache_read_tokens": int(job.get("total_cache_read_tokens") or 0),
            "observed_cache_creation_tokens": int(job.get("total_cache_creation_tokens") or 0),
            "_job": job,
        })
        latest_state = current
        previous_run_id = run_id

    if not segments or [item["segment_number"] for item in segments] != list(
        range(1, len(segments) + 1)
    ):
        raise MissionAuthorityError("mission segment records are missing or non-contiguous")

    external_runs = mission_doc.get("operational_source_run_ids") or []
    if (
        not isinstance(external_runs, list)
        or any(not isinstance(run_id, str) or not run_id for run_id in external_runs)
        or len(external_runs) != len(set(external_runs))
        or set(external_runs).intersection({str(item["run_id"]) for item in segments})
    ):
        raise MissionAuthorityError("mission external source-run identity is malformed")
    source_rows: list[dict[str, Any]] = []
    if external_runs:
        from . import supervisor as supervisor_mod
        for run_id in external_runs:
            row = supervisor_mod.status(canonical_repo=repo, run_id=run_id, db_path=db_path)
            if not row.get("ok"):
                raise MissionAuthorityError(f"mission source-run supervisor record is unavailable: {run_id}")
            source_rows.append(row)

    active = [
        item for item in segments
        if item.get("engineering_state") not in {"APPROVED", "BLOCKED", "STOPPED", "SEGMENT_BOUNDARY"}
        or (
            item.get("supervisor_status") in {"QUEUED", "RUNNING", "BACKOFF", "QUARANTINED", "HELD"}
            and not (
                item.get("engineering_state") == "SEGMENT_BOUNDARY"
                and any(later["segment_number"] > item["segment_number"] for later in segments)
            )
        )
    ]
    if len(active) > 1:
        raise MissionAuthorityError("mission has multiple simultaneously active segments")
    current = active[0] if active else segments[-1]
    current_candidate = str(current.get("last_candidate_sha") or current.get("baseline_sha") or "")
    if not _FULL_SHA_RE.fullmatch(current_candidate):
        raise MissionAuthorityError("mission current candidate/baseline identity is invalid")
    source_budget = source_budget_for_candidate(repo, str(current["run_id"]), current_candidate)
    segment_source_lines = _line_count(repo, str(current["baseline_sha"]), current_candidate)
    spend_rows = [item["_job"] for item in segments if item.get("_job", {}).get("ok")]
    spend_rows.extend(source_rows)
    completed = [
        str(item.get("id"))
        for item in (latest_state.get("program") or {}).get("finalized_checkpoints", [])
        if isinstance(item, dict) and item.get("id")
    ] if isinstance(latest_state, dict) else []
    mission_source_cap = int(mission_doc.get("mission_max_diff_lines") or 0)
    mission_source_used = int(source_budget["mission_source_lines_total"])
    mission_source_remaining = mission_source_cap - mission_source_used
    totals = {
        "cost_usd": sum(float(row.get("total_cost_usd") or 0.0) for row in spend_rows),
        "input_tokens": sum(int(row.get("total_input_tokens") or 0) for row in spend_rows),
        "output_tokens": sum(int(row.get("total_output_tokens") or 0) for row in spend_rows),
        "cache_read_tokens": sum(int(row.get("total_cache_read_tokens") or 0) for row in spend_rows),
        "cache_creation_tokens": sum(int(row.get("total_cache_creation_tokens") or 0) for row in spend_rows),
    }
    totals["total_tokens"] = sum(totals[key] for key in (
        "input_tokens", "output_tokens", "cache_read_tokens", "cache_creation_tokens",
    ))
    for item in segments:
        item.pop("_job", None)
    return {
        "ok": True,
        "mission_id": mission_id,
        "mission_authority_sha256": mission_sha,
        "mission_original_baseline_sha": mission_doc.get("mission_original_baseline_sha"),
        "mission_max_diff_lines": mission_doc.get("mission_max_diff_lines"),
        "segment_max_diff_lines": mission_doc.get("segment_max_diff_lines"),
        "max_segments": mission_doc.get("max_segments"),
        "segments": segments,
        "current_run_id": current.get("run_id"),
        "current_segment_number": current.get("segment_number"),
        "current_candidate_sha": current_candidate,
        "current_checkpoint": current.get("current_checkpoint"),
        "completed_checkpoints": completed,
        "mission_source_lines_used": mission_source_used,
        "mission_source_lines_remaining": max(0, mission_source_remaining),
        "mission_source_lines_over_ceiling": max(0, -mission_source_remaining),
        "current_segment_source_lines": segment_source_lines,
        "current_segment_source_lines_remaining": max(
            0, int(mission_doc.get("segment_max_diff_lines") or 0) - segment_source_lines,
        ),
        "aggregate_observed_spend": totals,
        "operational_source_run_ids": list(external_runs),
        "mission_operational_budget": mission_doc.get("operational_budget"),
    }


__all__ = [
    "MISSION_SCHEMA", "SEGMENT_SCHEMA", "SEGMENT_STATE_SCHEMA",
    "LEGACY_ADMISSION_SCHEMA", "MissionAuthorityError", "ensure_initial_segment",
    "load_segment", "verify_segment_approval", "segment_boundary_eligibility",
    "source_budget_for_candidate", "create_segment_successor",
    "enqueue_envelope_for_child", "admit_legacy_continuation",
    "reconcile_pending_boundaries", "mission_status",
]
