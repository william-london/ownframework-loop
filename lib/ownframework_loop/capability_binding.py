"""Immutable run-level capability/execution-environment binding."""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import stat
import uuid
from typing import Any

from .locking import flock_exclusive
from .util import fsync_dir, utc_now_iso

SCHEMA = "ownframework-loop-capability-binding/v1"
PROJECTION_REVISION = "capability-binding-projection/v3"
MIGRATION_SCHEMA = "ownframework-loop-capability-binding-migration/v1"
MIGRATION_DIRNAME = "CAPABILITY_BINDING_MIGRATIONS"


class CapabilityBindingError(RuntimeError):
    pass


def _canonical(obj: Any) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()


def binding_path(canonical_repo: Path, run_id: str) -> Path:
    # Defense in depth: callers already validate run_id, but this path
    # builds filesystem locations from it and must never be reachable with
    # an unvalidated identifier.
    from . import state as _state_mod
    _state_mod.validate_run_id(run_id)
    return canonical_repo.resolve(strict=False) / ".ownframework-loop" / run_id / "CAPABILITY_BINDING.json"


def migration_root(canonical_repo: Path, run_id: str) -> Path:
    from . import state as _state_mod
    _state_mod.validate_run_id(run_id)
    return (
        canonical_repo.resolve(strict=False)
        / ".ownframework-loop"
        / run_id
        / MIGRATION_DIRNAME
    )


def stable_projection(resolution: dict[str, Any], runner_profile: dict[str, Any]) -> dict[str, Any]:
    keys = (
        "name", "kind", "privileged", "provider", "executable", "version",
        "executable_sha256", "network_domains", "commissioning_evidence_sha256",
        "commissioning_canary_kind", "trusted_asset_identity", "browser",
    )
    caps = []
    for item in resolution.get("resolved") or []:
        if isinstance(item, dict):
            caps.append({k: item.get(k) for k in keys if item.get(k) is not None})
    return {
        "projection_revision": PROJECTION_REVISION,
        "capability_contract_revision": resolution.get("capability_contract_revision"),
        "requested": list(resolution.get("requested") or []),
        "host_manifest_sha256": resolution.get("host_manifest_sha256"),
        "semantic_runtime_fingerprint": resolution.get("semantic_runtime_fingerprint"),
        "platform_identity": resolution.get("platform_identity"),
        "capabilities": caps,
        "network_domains": list(resolution.get("network_domains") or []),
        "stable_filesystem": resolution.get("stable_filesystem") or {"allowRead": [], "allowWrite": []},
        "sandbox_network": resolution.get("sandbox_network") or {},
        # The REQUESTED runner profile. This binds what the run asked for;
        # it is deliberately NOT a claim about what the provider effectively
        # used. The effective model (when the provider reveals it) is recorded
        # separately on the semantic attempt ledger, so a silent model/effort
        # substitution is never certified as the requested profile.
        "requested_runner_profile": {
            k: runner_profile.get(k)
            for k in (
                "name", "provider", "model", "effort", "identity_sha256",
                "effort_attestation",
            )
        },
    }


def _validate_document(doc: Any, *, run_id: str | None = None) -> dict[str, Any]:
    if not isinstance(doc, dict):
        raise CapabilityBindingError("capability binding must be an object")
    projection = doc.get("projection")
    if doc.get("schema") != SCHEMA or not isinstance(projection, dict):
        raise CapabilityBindingError("capability binding schema/projection mismatch")
    if run_id is not None and doc.get("run_id") != run_id:
        raise CapabilityBindingError("capability binding run_id mismatch")
    if doc.get("binding_sha256") != hashlib.sha256(_canonical(projection)).hexdigest():
        raise CapabilityBindingError("capability binding digest mismatch")
    return doc


def _read(path: Path) -> dict[str, Any]:
    if path.is_symlink():
        raise CapabilityBindingError("capability binding must not be a symlink")
    try:
        st = path.stat()
    except OSError as exc:
        # A missing/unreadable binding must fail closed as the module's own
        # error type. Letting FileNotFoundError escape would bypass callers'
        # CapabilityBindingError handling and misclassify a sealed-run
        # authority failure as a generic configuration fault.
        raise CapabilityBindingError(
            f"capability binding unreadable: {type(exc).__name__}"
        ) from exc
    if not stat.S_ISREG(st.st_mode):
        raise CapabilityBindingError("capability binding must be a regular file")
    if hasattr(os, "getuid") and st.st_uid != os.getuid():
        raise CapabilityBindingError("capability binding must be owned by supervisor user")
    if st.st_mode & 0o022:
        raise CapabilityBindingError("capability binding must not be group/world writable")
    try:
        doc = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise CapabilityBindingError(f"capability binding corrupt: {exc}") from exc
    return _validate_document(doc)


def _publish_complete_no_replace(path: Path, encoded: str) -> bool:
    """Publish complete bytes atomically without ever exposing a partial path."""
    tmp = path.with_name(f".{path.name}.{os.getpid()}.{uuid.uuid4().hex}.tmp")
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(encoded)
            fh.flush()
            os.fsync(fh.fileno())
        try:
            os.link(tmp, path)
        except FileExistsError:
            return False
        try:
            dir_fd = os.open(str(path.parent), os.O_RDONLY)
            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)
        except OSError:
            pass
        return True
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def _atomic_replace_json(path: Path, payload: dict[str, Any]) -> None:
    """Atomically replace one private JSON authority file."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(path.parent, 0o700)
    except OSError:
        pass
    tmp = path.with_name(f".{path.name}.{os.getpid()}.{uuid.uuid4().hex}.tmp")
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        encoded = json.dumps(payload, indent=2, sort_keys=True) + "\n"
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(encoded)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
        fsync_dir(path.parent)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def _publish_json_no_replace(path: Path, payload: dict[str, Any]) -> bool:
    encoded = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(path.parent, 0o700)
    except OSError:
        pass
    return _publish_complete_no_replace(path, encoded)


# Tests use this private seam to model process death at each publication
# boundary.  Production leaves it as a no-op; the migration protocol itself
# remains the authority for recovery.
def _migration_fault_hook(stage: str) -> None:
    return None


def _read_private_binding_snapshot(path: Path, *, run_id: str) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise CapabilityBindingError("capability migration snapshot missing or symlinked")
    try:
        st = path.stat()
    except OSError as exc:
        raise CapabilityBindingError("capability migration snapshot unreadable") from exc
    if st.st_mode & 0o077:
        raise CapabilityBindingError("capability migration snapshot must be private")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise CapabilityBindingError("capability migration snapshot corrupt") from exc
    return _validate_document(payload, run_id=run_id)


def _binding_document(run_id: str, projection: dict[str, Any]) -> dict[str, Any]:
    return {
        "schema": SCHEMA,
        "run_id": run_id,
        "projection": projection,
        "binding_sha256": hashlib.sha256(_canonical(projection)).hexdigest(),
    }


def _read_migration_record(path: Path, *, run_id: str) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise CapabilityBindingError("capability migration record missing or symlinked")
    try:
        if path.stat().st_mode & 0o077:
            raise CapabilityBindingError("capability migration record must be private")
    except OSError as exc:
        raise CapabilityBindingError("capability migration record unreadable") from exc
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise CapabilityBindingError("capability migration record unreadable") from exc
    if not isinstance(doc, dict) or doc.get("schema") != MIGRATION_SCHEMA:
        raise CapabilityBindingError("capability migration record schema mismatch")
    if doc.get("run_id") != run_id:
        raise CapabilityBindingError("capability migration record run_id mismatch")
    record_digest = str(doc.get("migration_record_sha256") or "")
    body = dict(doc)
    body.pop("migration_record_sha256", None)
    if record_digest != hashlib.sha256(_canonical(body)).hexdigest():
        raise CapabilityBindingError("capability migration record digest mismatch")
    _validate_document(doc.get("previous_binding"), run_id=run_id)
    _validate_document(doc.get("new_binding"), run_id=run_id)
    if doc.get("status") not in {"PREPARED", "COMPLETE"}:
        raise CapabilityBindingError("capability migration record status invalid")
    return doc


def _migration_inventory(
    canonical_repo: Path, run_id: str
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Read complete records and fail-closed partial migration directories."""
    root = migration_root(canonical_repo, run_id)
    if not root.exists():
        return [], []
    if root.is_symlink() or not root.is_dir():
        raise CapabilityBindingError("capability migration history root is invalid")
    records: list[dict[str, Any]] = []
    incomplete: list[dict[str, Any]] = []
    allowed = {"PREVIOUS_BINDING.json", "NEW_BINDING.json", "RECORD.json"}
    for child in sorted(root.iterdir()):
        if child.is_symlink() or not child.is_dir():
            raise CapabilityBindingError("unexpected capability migration history entry")
        names = {item.name for item in child.iterdir()}
        if names - allowed:
            raise CapabilityBindingError("unexpected file in capability migration directory")
        if any(item.is_symlink() for item in child.iterdir()):
            raise CapabilityBindingError("symlink in capability migration directory")
        record_path = child / "RECORD.json"
        previous_path = child / "PREVIOUS_BINDING.json"
        new_path = child / "NEW_BINDING.json"
        if record_path.exists():
            record = _read_migration_record(record_path, run_id=run_id)
            if record.get("migration_directory") != child.name:
                raise CapabilityBindingError("capability migration directory identity mismatch")
            if not previous_path.exists() or not new_path.exists():
                raise CapabilityBindingError("migration record lacks immutable snapshots")
            if _read_private_binding_snapshot(previous_path, run_id=run_id) != record.get("previous_binding"):
                raise CapabilityBindingError("previous migration snapshot contradicts record")
            if _read_private_binding_snapshot(new_path, run_id=run_id) != record.get("new_binding"):
                raise CapabilityBindingError("new migration snapshot contradicts record")
            records.append(record)
            continue
        snapshots: dict[str, dict[str, Any] | None] = {
            "previous": (
                _read_private_binding_snapshot(previous_path, run_id=run_id)
                if previous_path.exists() else None
            ),
            "new": (
                _read_private_binding_snapshot(new_path, run_id=run_id)
                if new_path.exists() else None
            ),
        }
        incomplete.append({"directory": child, **snapshots})
    records.sort(key=lambda item: int(item.get("migration_sequence") or 0))
    return records, incomplete


def _migration_records(canonical_repo: Path, run_id: str) -> list[dict[str, Any]]:
    records, incomplete = _migration_inventory(canonical_repo, run_id)
    if incomplete:
        raise CapabilityBindingError("capability migration history has incomplete evidence")
    return records


def _validate_migration_chain(records: list[dict[str, Any]], active: dict[str, Any]) -> None:
    complete = [r for r in records if r.get("status") == "COMPLETE"]
    complete.sort(key=lambda item: int(item.get("migration_sequence") or 0))
    prepared = [r for r in records if r.get("status") == "PREPARED"]
    if len(prepared) > 1:
        raise CapabilityBindingError("multiple prepared capability migrations")

    prior_record_sha: str | None = None
    prior_binding_sha: str | None = None
    for expected_sequence, record in enumerate(complete, start=1):
        sequence = int(record.get("migration_sequence") or 0)
        if sequence != expected_sequence:
            raise CapabilityBindingError("capability migration sequence continuity failure")
        previous = record.get("previous_binding")
        new_binding = record.get("new_binding")
        if not isinstance(previous, dict) or not isinstance(new_binding, dict):
            raise CapabilityBindingError("capability migration binding document missing")
        if record.get("previous_binding_sha256") != previous.get("binding_sha256"):
            raise CapabilityBindingError("capability migration previous binding digest mismatch")
        if record.get("new_binding_sha256") != new_binding.get("binding_sha256"):
            raise CapabilityBindingError("capability migration new binding digest mismatch")
        if record.get("prior_migration_record_sha256") != prior_record_sha:
            raise CapabilityBindingError("capability migration record chain continuity failure")
        if prior_binding_sha is not None and record.get("previous_binding_sha256") != prior_binding_sha:
            raise CapabilityBindingError("capability migration binding chain continuity failure")
        prior_record_sha = str(record.get("migration_record_sha256") or "")
        prior_binding_sha = str(record.get("new_binding_sha256") or "")

    if prepared:
        pending = prepared[0]
        pending_sequence = int(pending.get("migration_sequence") or 0)
        if pending_sequence != len(complete) + 1:
            raise CapabilityBindingError("prepared capability migration is not the next frontier")
        pending_previous = pending.get("previous_binding")
        pending_new = pending.get("new_binding")
        if not isinstance(pending_previous, dict) or not isinstance(pending_new, dict):
            raise CapabilityBindingError("prepared capability migration binding document missing")
        if pending.get("previous_binding_sha256") != pending_previous.get("binding_sha256"):
            raise CapabilityBindingError("prepared capability migration previous binding digest mismatch")
        if pending.get("new_binding_sha256") != pending_new.get("binding_sha256"):
            raise CapabilityBindingError("prepared capability migration new binding digest mismatch")
        if pending.get("prior_migration_record_sha256") != prior_record_sha:
            raise CapabilityBindingError("prepared capability migration record chain continuity failure")
        if prior_binding_sha is not None:
            if pending.get("previous_binding_sha256") != prior_binding_sha:
                raise CapabilityBindingError("prepared capability migration binding chain continuity failure")
        elif pending.get("previous_binding_sha256") != pending_previous.get("binding_sha256"):
            raise CapabilityBindingError("prepared first migration binding continuity failure")
        active_sha = active.get("binding_sha256")
        if active_sha not in {
            pending.get("previous_binding_sha256"),
            pending.get("new_binding_sha256"),
        }:
            raise CapabilityBindingError("active capability binding is outside the prepared migration frontier")
    elif prior_binding_sha is not None and active.get("binding_sha256") != prior_binding_sha:
        raise CapabilityBindingError("active capability binding is not the completed migration frontier")


def _migration_record(
    *,
    run_id: str,
    repo: Path,
    migration_directory: str,
    sequence: int,
    previous: dict[str, Any],
    new_binding: dict[str, Any],
    latest: dict[str, Any] | None,
    reason: str,
    actor: str,
    context: dict[str, Any] | None,
) -> dict[str, Any]:
    ctx = dict(context or {})
    record: dict[str, Any] = {
        "schema": MIGRATION_SCHEMA,
        "run_id": run_id,
        "canonical_repo": str(repo),
        "migration_id": f"{run_id}:{sequence}:{new_binding['binding_sha256']}",
        "migration_sequence": sequence,
        "migration_directory": migration_directory,
        "status": "PREPARED",
        "previous_binding_sha256": previous["binding_sha256"],
        "previous_binding": previous,
        "new_binding_sha256": new_binding["binding_sha256"],
        "new_binding": new_binding,
        "previous_projection_revision": (previous.get("projection") or {}).get("projection_revision"),
        "new_projection_revision": (new_binding.get("projection") or {}).get("projection_revision"),
        "reason": reason,
        "actor": actor,
        "created_at": utc_now_iso(),
        "runtime_generation": ctx.get("runtime_generation"),
        "engineering_state": ctx.get("engineering_state"),
        "checkpoint": ctx.get("checkpoint"),
        "supervisor_job_id": ctx.get("supervisor_job_id"),
        "packet_sha256": ctx.get("packet_sha256"),
        "approval_sha256": ctx.get("approval_sha256"),
        "prior_migration_record_sha256": (
            latest.get("migration_record_sha256") if latest else None
        ),
    }
    record["migration_record_sha256"] = hashlib.sha256(_canonical(record)).hexdigest()
    return record


def _latest_complete_record(records: list[dict[str, Any]]) -> dict[str, Any] | None:
    complete = [r for r in records if r.get("status") == "COMPLETE"]
    if not complete:
        return None
    return max(complete, key=lambda r: int(r.get("migration_sequence") or 0))


def _assert_runtime_ready_resolution(
    resolution: dict[str, Any],
    requested_capabilities: list[str] | None = None,
) -> None:
    requested = list(resolution.get("requested") or [])
    if requested_capabilities is not None and requested != list(requested_capabilities):
        raise CapabilityBindingError("current capability set differs from sealed packet authority")
    resolved = resolution.get("resolved") or []
    names = [str(item.get("name") or "") for item in resolved if isinstance(item, dict)]
    if names != requested:
        raise CapabilityBindingError("current capability resolution is incomplete or reordered")
    for item in resolved:
        if not isinstance(item, dict):
            raise CapabilityBindingError("current capability resolution contains a malformed item")
        if item.get("privileged") and not item.get("commissioning_evidence_sha256"):
            raise CapabilityBindingError("privileged capability lacks commissioned evidence")
        if item.get("kind") == "browser":
            browser = item.get("browser") or {}
            if browser.get("runtime_proven") is not True:
                raise CapabilityBindingError("new browser capability is not runtime-proven")


def ensure_run_binding(
    canonical_repo: Path,
    run_id: str,
    resolution: dict[str, Any],
    runner_profile: dict[str, Any],
    *,
    allow_create: bool,
) -> dict[str, Any]:
    path = binding_path(canonical_repo, run_id)
    projection = stable_projection(resolution, runner_profile)
    digest = hashlib.sha256(_canonical(projection)).hexdigest()
    if path.exists():
        existing = _read(path)
        if existing.get("binding_sha256") != digest or existing.get("projection") != projection:
            raise CapabilityBindingError("sealed run capability/environment drift detected before model launch")
        return existing
    if not allow_create:
        raise CapabilityBindingError(
            "executed/historical run has no v0.9.1 capability binding; refusing silent rebind"
        )
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        # mkdir(exist_ok=True) leaves a pre-existing directory's mode intact;
        # tighten it explicitly so the sealed authority artifact never sits
        # in a group/world-listable directory.
        os.chmod(path.parent, 0o700)
    except OSError:
        pass
    payload = {"schema": SCHEMA, "run_id": run_id, "projection": projection, "binding_sha256": digest}
    encoded = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    if _publish_complete_no_replace(path, encoded):
        return payload
    existing = _read(path)
    if existing.get("binding_sha256") != digest or existing.get("projection") != projection:
        raise CapabilityBindingError("concurrent first-attempt capability binding conflict")
    return existing


def migrate_run_binding(
    canonical_repo: Path,
    run_id: str,
    resolution: dict[str, Any],
    runner_profile: dict[str, Any],
    *,
    reason: str,
    actor: str,
    context: dict[str, Any] | None = None,
    requested_capabilities: list[str] | None = None,
) -> dict[str, Any]:
    """Explicitly migrate a run's trusted capability authority.

    A prepared migration record and complete old/new snapshots are durable
    before the active binding is replaced. Retrying recovers a prepared
    switch or returns the completed record without creating a duplicate.
    Engineering state and accounting are intentionally outside this module.
    """
    from . import state as _state_mod
    _state_mod.validate_run_id(run_id)
    _assert_runtime_ready_resolution(resolution, requested_capabilities)
    if not isinstance(reason, str) or not reason.strip():
        raise CapabilityBindingError("capability migration requires a reason")
    if not isinstance(actor, str) or not actor.strip():
        raise CapabilityBindingError("capability migration requires an actor")

    repo = canonical_repo.resolve(strict=False)
    active_path = binding_path(repo, run_id)
    history = migration_root(repo, run_id)
    history.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    history.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(history.parent, 0o700)
        os.chmod(history, 0o700)
    except OSError:
        pass

    with flock_exclusive(history.parent / "CAPABILITY_BINDING_MIGRATION.lock"):
        previous = _read(active_path)
        new_binding = _binding_document(run_id, stable_projection(resolution, runner_profile))
        previous_sha = str(previous["binding_sha256"])
        new_sha = str(new_binding["binding_sha256"])
        records, incomplete = _migration_inventory(repo, run_id)
        _validate_migration_chain(records, previous)

        # A process can die after creating the numbered directory, or after
        # either immutable snapshot, but before RECORD.json is published.
        # Recover that one deterministic operation instead of ignoring the
        # directory and colliding with it on retry.
        if incomplete:
            if len(incomplete) != 1:
                raise CapabilityBindingError("multiple incomplete capability migrations require adjudication")
            partial = incomplete[0]
            directory = partial["directory"]
            expected_prefix = new_sha[:16]
            try:
                sequence_text, prefix = directory.name.split("-", 1)
                partial_sequence = int(sequence_text)
            except (ValueError, TypeError) as exc:
                raise CapabilityBindingError("incomplete capability migration directory name invalid") from exc
            if prefix != expected_prefix:
                raise CapabilityBindingError("incomplete capability migration contradicts requested new binding")
            expected_sequence = max(
                [int(r.get("migration_sequence") or 0) for r in records] or [0]
            ) + 1
            if partial_sequence != expected_sequence:
                raise CapabilityBindingError("incomplete capability migration sequence is not the next frontier")
            if partial["previous"] is not None and partial["previous"] != previous:
                raise CapabilityBindingError("incomplete migration previous snapshot contradicts active binding")
            if partial["new"] is not None and partial["new"] != new_binding:
                raise CapabilityBindingError("incomplete migration new snapshot contradicts requested binding")
            if previous_sha == new_sha:
                raise CapabilityBindingError("incomplete migration has no distinct new binding")
            previous_snapshot = partial["previous"]
            if previous_snapshot is None:
                if not _publish_json_no_replace(directory / "PREVIOUS_BINDING.json", previous):
                    previous_snapshot = _read_private_binding_snapshot(
                        directory / "PREVIOUS_BINDING.json", run_id=run_id
                    )
                else:
                    previous_snapshot = previous
                _migration_fault_hook("previous_snapshot_recovered")
            if previous_snapshot != previous:
                raise CapabilityBindingError("recovered previous migration snapshot contradicts active binding")
            new_snapshot = partial["new"]
            if new_snapshot is None:
                if not _publish_json_no_replace(directory / "NEW_BINDING.json", new_binding):
                    new_snapshot = _read_private_binding_snapshot(
                        directory / "NEW_BINDING.json", run_id=run_id
                    )
                else:
                    new_snapshot = new_binding
                _migration_fault_hook("new_snapshot_recovered")
            if new_snapshot != new_binding:
                raise CapabilityBindingError("recovered new migration snapshot contradicts requested binding")
            latest = _latest_complete_record(records)
            record = _migration_record(
                run_id=run_id,
                repo=repo,
                migration_directory=directory.name,
                sequence=partial_sequence,
                previous=previous,
                new_binding=new_binding,
                latest=latest,
                reason=reason,
                actor=actor,
                context=context,
            )
            if not _publish_json_no_replace(directory / "RECORD.json", record):
                record = _read_migration_record(directory / "RECORD.json", run_id=run_id)
            fsync_dir(history)
            records.append(record)
            incomplete = []

        if previous_sha == new_sha and previous.get("projection") == new_binding.get("projection"):
            matching = next(
                (
                    r for r in records
                    if r.get("status") in {"PREPARED", "COMPLETE"}
                    and r.get("new_binding_sha256") == new_sha
                ),
                None,
            )
            if matching is not None:
                if matching.get("status") == "PREPARED":
                    record_path = (
                        history
                        / str(matching.get("migration_directory") or "")
                        / "RECORD.json"
                    )
                    matching = dict(matching)
                    matching["status"] = "COMPLETE"
                    matching["completed_at"] = utc_now_iso()
                    matching.pop("migration_record_sha256", None)
                    matching["migration_record_sha256"] = hashlib.sha256(
                        _canonical(matching)
                    ).hexdigest()
                    _atomic_replace_json(record_path, matching)
                return dict(matching, idempotent=True)
            raise CapabilityBindingError(
                "active capability binding already has requested identity without migration evidence"
            )

        for record in records:
            if (
                record.get("previous_binding_sha256") == previous_sha
                and record.get("new_binding_sha256") == new_sha
            ):
                record_dir = history / str(record.get("migration_directory") or "")
                record_path = record_dir / "RECORD.json"
                current = _read(active_path)
                if record.get("status") == "PREPARED":
                    if current["binding_sha256"] == previous_sha:
                        _atomic_replace_json(active_path, new_binding)
                    elif current["binding_sha256"] != new_sha:
                        raise CapabilityBindingError(
                            "pending capability migration found contradictory active binding"
                        )
                    body = dict(record)
                    body["status"] = "COMPLETE"
                    body["completed_at"] = utc_now_iso()
                    body.pop("migration_record_sha256", None)
                    body["migration_record_sha256"] = hashlib.sha256(_canonical(body)).hexdigest()
                    _atomic_replace_json(record_path, body)
                    record = body
                elif current["binding_sha256"] != new_sha:
                    raise CapabilityBindingError(
                        "completed capability migration is not the active binding"
                    )
                return dict(record, idempotent=True)

        if any(r.get("status") == "PREPARED" for r in records):
            raise CapabilityBindingError("another capability migration is pending recovery")

        latest = _latest_complete_record(records)
        sequence = max([int(r.get("migration_sequence") or 0) for r in records] or [0]) + 1
        migration_directory = f"{sequence:06d}-{new_sha[:16]}"
        directory = history / migration_directory
        try:
            directory.mkdir(mode=0o700)
        except FileExistsError as exc:
            raise CapabilityBindingError("capability migration directory collision") from exc
        _migration_fault_hook("directory_created")

        if not _publish_json_no_replace(directory / "PREVIOUS_BINDING.json", previous):
            raise CapabilityBindingError("previous capability binding snapshot collision")
        _migration_fault_hook("previous_snapshot_published")
        if not _publish_json_no_replace(directory / "NEW_BINDING.json", new_binding):
            raise CapabilityBindingError("new capability binding snapshot collision")
        _migration_fault_hook("new_snapshot_published")

        record = _migration_record(
            run_id=run_id,
            repo=repo,
            migration_directory=migration_directory,
            sequence=sequence,
            previous=previous,
            new_binding=new_binding,
            latest=latest,
            reason=reason,
            actor=actor,
            context=context,
        )
        record_path = directory / "RECORD.json"
        _migration_fault_hook("before_record_published")
        if not _publish_json_no_replace(record_path, record):
            raise CapabilityBindingError("capability migration record collision")
        fsync_dir(history)

        current = _read(active_path)
        if current["binding_sha256"] == new_sha:
            # Crash after the switch but before completion marker.
            record["status"] = "COMPLETE"
        elif current["binding_sha256"] == previous_sha:
            _atomic_replace_json(active_path, new_binding)
            record["status"] = "COMPLETE"
        else:
            raise CapabilityBindingError("active capability binding changed unexpectedly")

        record["completed_at"] = utc_now_iso()
        record.pop("migration_record_sha256", None)
        record["migration_record_sha256"] = hashlib.sha256(_canonical(record)).hexdigest()
        _atomic_replace_json(record_path, record)
        return dict(record, idempotent=False)


def historical_binding(
    canonical_repo: Path,
    run_id: str,
    binding_sha256: str,
) -> dict[str, Any]:
    """Read an immutable binding snapshot preserved by a completed migration."""
    active = _read(binding_path(canonical_repo, run_id))
    if active.get("binding_sha256") == binding_sha256:
        return active
    for record in _migration_records(canonical_repo, run_id):
        if record.get("status") != "COMPLETE":
            continue
        for key in ("previous_binding", "new_binding"):
            candidate = record.get(key)
            if isinstance(candidate, dict) and candidate.get("binding_sha256") == binding_sha256:
                return _validate_document(candidate, run_id=run_id)
    raise CapabilityBindingError("requested historical capability binding is not preserved")


def verify_run_binding(
    canonical_repo: Path, run_id: str, resolution: dict[str, Any], runner_profile: dict[str, Any]
) -> dict[str, Any]:
    return ensure_run_binding(
        canonical_repo, run_id, resolution, runner_profile, allow_create=False
    )


__all__ = [
    "CapabilityBindingError", "MIGRATION_SCHEMA", "PROJECTION_REVISION", "SCHEMA",
    "binding_path", "historical_binding", "migration_root", "migrate_run_binding",
    "ensure_run_binding", "stable_projection", "verify_run_binding",
]
