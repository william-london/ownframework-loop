"""Durable, private evidence emitted by deterministic validation infrastructure.

Package-network events originate in Loop's host broker, not in candidate
stdout/stderr.  This module persists those structured events under the run's
authoritative state directory so a recovery decision never depends on the
reusable runtime-cache diagnostics.
"""
from __future__ import annotations

import hashlib
import json
import os
import stat
import tempfile
import time
from pathlib import Path
from typing import Any

from . import util

SCHEMA = "ownframework-loop-validation-evidence/v1"
_EVIDENCE_ROOT = Path("validation-evidence/package-network")
_MAX_EVIDENCE_BYTES = 1024 * 1024
_EVENT_KINDS = {
    "dns_resolution_failed",
    "no_public_package_registry_address",
    "package_registry_connect_failed",
}
_BROKERS = {"connect_proxy", "unix_package_broker"}


def _canonical_json(value: Any) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("ascii")


def _canonical_sha(value: Any) -> str:
    return hashlib.sha256(_canonical_json(value)).hexdigest()


def _normalized_host(value: Any) -> str:
    host = str(value or "").strip().rstrip(".").lower()
    try:
        return host.encode("idna").decode("ascii")
    except UnicodeError:
        return ""


def validation_identity(
    *,
    canonical_repo: Path,
    run_id: str,
    checkpoint_id: str,
    role: str,
    pass_number: int,
    validation_index: int,
    candidate_sha: str,
    cwd: Path,
    validation: dict[str, Any],
) -> dict[str, Any]:
    """Return the canonical identity for one declared validation invocation."""
    return {
        "canonical_repo": str(Path(canonical_repo).expanduser().resolve()),
        "run_id": str(run_id),
        "checkpoint_id": str(checkpoint_id or ""),
        "role": str(role),
        "pass_number": int(pass_number),
        "validation_index": int(validation_index),
        "candidate_sha": str(candidate_sha or ""),
        "cwd": str(Path(cwd).expanduser().resolve()),
        "name": str(validation.get("name") or "validation"),
        "command": str(validation.get("command") or ""),
        "kind": str(validation.get("kind") or "fast"),
        "expected_exit_code": int(
            validation.get("expected_exit_code")
            if validation.get("expected_exit_code") is not None else 0
        ),
        "expected_marker": validation.get("expected_marker"),
    }


def _validate_events(events: Any) -> list[dict[str, Any]]:
    if not isinstance(events, list) or not events:
        raise ValueError("trusted package-network event list is missing")
    clean: list[dict[str, Any]] = []
    for event in events:
        if not isinstance(event, dict) or set(event) != {"kind", "host", "port", "broker"}:
            raise ValueError("trusted package-network event has an invalid shape")
        kind = str(event.get("kind") or "")
        host = _normalized_host(event.get("host"))
        broker = str(event.get("broker") or "")
        port = event.get("port")
        if (
            kind not in _EVENT_KINDS
            or not host
            or isinstance(port, bool)
            or int(port or 0) != 443
            or broker not in _BROKERS
        ):
            raise ValueError("trusted package-network event contradicts broker contract")
        clean.append({"kind": kind, "host": host, "port": 443, "broker": broker})
    return clean


def _run_root(canonical_repo: Path, run_id: str, *, create: bool = False) -> Path:
    root = util.run_dir(canonical_repo, run_id)
    if create:
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not root.is_dir() or root.is_symlink() or root.resolve(strict=True) != root:
        raise RuntimeError("run-owned validation evidence root is redirected")
    if create:
        os.chmod(root, 0o700)
    return root


def _evidence_directory(run_root: Path, *, create: bool) -> Path:
    directory = run_root
    for component in _EVIDENCE_ROOT.parts:
        directory = directory / component
        if directory.is_symlink():
            raise RuntimeError("validation evidence directory is redirected")
        if create:
            directory.mkdir(exist_ok=True, mode=0o700)
        if not directory.is_dir() or directory.resolve(strict=True).parent != directory.parent.resolve(strict=True):
            raise RuntimeError("validation evidence directory is not a private run child")
        st = directory.stat()
        if (
            stat.S_IMODE(st.st_mode) & 0o077
            or (hasattr(os, "getuid") and st.st_uid != os.getuid())
        ):
            if not create:
                raise RuntimeError("validation evidence directory permissions are invalid")
        if create:
            os.chmod(directory, 0o700)
    return directory


def evidence_path(canonical_repo: Path, run_id: str, evidence_id: str) -> Path:
    if len(evidence_id) != 64 or any(ch not in "0123456789abcdef" for ch in evidence_id):
        raise ValueError("validation evidence identity is invalid")
    root = _run_root(canonical_repo, run_id)
    directory = _evidence_directory(root, create=False)
    return directory / f"{evidence_id}.json"


def _read_record(path: Path, *, expected_sha256: str | None = None) -> tuple[dict[str, Any], str]:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        raise RuntimeError("durable validation evidence is missing or redirected") from exc
    with os.fdopen(fd, "rb") as handle:
        st = os.fstat(handle.fileno())
        if (
            not stat.S_ISREG(st.st_mode)
            or stat.S_IMODE(st.st_mode) & 0o077
            or (hasattr(os, "getuid") and st.st_uid != os.getuid())
            or st.st_size > _MAX_EVIDENCE_BYTES
        ):
            raise RuntimeError("durable validation evidence permissions or type are invalid")
        raw = handle.read(_MAX_EVIDENCE_BYTES + 1)
    if len(raw) > _MAX_EVIDENCE_BYTES:
        raise RuntimeError("durable validation evidence exceeds size limit")
    digest = hashlib.sha256(raw).hexdigest()
    if expected_sha256 and digest != expected_sha256:
        raise RuntimeError("durable validation evidence SHA-256 mismatch")
    try:
        record = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RuntimeError("durable validation evidence is malformed") from exc
    if not isinstance(record, dict) or record.get("schema") != SCHEMA:
        raise RuntimeError("durable validation evidence schema mismatch")
    _validate_events(record.get("package_network_events"))
    if not isinstance(record.get("identity"), dict):
        raise RuntimeError("durable validation evidence identity is missing")
    return record, digest


def publish_package_network_events(
    *, identity: dict[str, Any], events: list[dict[str, Any]],
) -> dict[str, str]:
    """Create-once publish trusted broker events and return a sealed reference."""
    canonical_repo = Path(str(identity.get("canonical_repo") or "")).resolve(strict=True)
    run_id = str(identity.get("run_id") or "")
    evidence_id = _canonical_sha(identity)
    run_root = _run_root(canonical_repo, run_id, create=True)
    evidence_dir = _evidence_directory(run_root, create=True)
    path = evidence_dir / f"{evidence_id}.json"
    clean_events = _validate_events(events)
    record = {
        "schema": SCHEMA,
        "evidence_id": evidence_id,
        "identity": identity,
        "package_network_events": clean_events,
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    data = json.dumps(record, sort_keys=True, indent=2, ensure_ascii=True).encode("ascii") + b"\n"
    if len(data) > _MAX_EVIDENCE_BYTES:
        raise RuntimeError("durable validation evidence exceeds size limit")
    fd, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent,
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "wb") as handle:
            os.fchmod(handle.fileno(), 0o600)
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        try:
            # A same-directory hard link publishes the complete, fsynced inode
            # atomically and fails rather than replacing an existing record.
            os.link(temporary, path, follow_symlinks=False)
            util.fsync_dir(path.parent)
            digest = hashlib.sha256(data).hexdigest()
        except FileExistsError:
            existing, digest = _read_record(path)
            if (
                existing.get("evidence_id") != evidence_id
                or existing.get("identity") != identity
                or existing.get("package_network_events") != clean_events
            ):
                raise RuntimeError("durable validation evidence identity collision")
    finally:
        try:
            temporary.unlink()
            util.fsync_dir(path.parent)
        except FileNotFoundError:
            pass
    relative_path = path.relative_to(run_root).as_posix()
    return {
        "schema": SCHEMA,
        "evidence_id": evidence_id,
        "relative_path": relative_path,
        "sha256": digest,
    }


def verify_reference(
    *,
    canonical_repo: Path,
    run_id: str,
    reference: dict[str, Any],
    expected_identity: dict[str, Any],
) -> tuple[dict[str, Any], str]:
    """Verify a run-owned evidence reference against exact validation identity."""
    if not isinstance(reference, dict) or set(reference) != {
        "schema", "evidence_id", "relative_path", "sha256"
    }:
        raise RuntimeError("durable validation evidence reference has an invalid shape")
    evidence_id = _canonical_sha(expected_identity)
    expected_relative = (_EVIDENCE_ROOT / f"{evidence_id}.json").as_posix()
    if any((
        reference.get("schema") != SCHEMA,
        reference.get("evidence_id") != evidence_id,
        reference.get("relative_path") != expected_relative,
        not isinstance(reference.get("sha256"), str),
    )):
        raise RuntimeError("durable validation evidence reference contradicts expected identity")
    path = evidence_path(Path(canonical_repo).resolve(strict=True), run_id, evidence_id)
    record, digest = _read_record(path, expected_sha256=str(reference.get("sha256")))
    if record.get("evidence_id") != evidence_id or record.get("identity") != expected_identity:
        raise RuntimeError("durable validation evidence has contradictory identity")
    return record, digest


def proves_registry_dns_failure(
    *,
    record: dict[str, Any],
    allowed_domains: set[str],
) -> bool:
    """Return true only for a broker-emitted DNS failure inside frozen authority."""
    allowed = {_normalized_host(domain) for domain in allowed_domains}
    allowed.discard("")
    if not allowed:
        return False
    events = record.get("package_network_events")
    if not isinstance(events, list) or not events:
        return False
    try:
        clean = _validate_events(events)
    except (TypeError, ValueError):
        return False
    return any(
        event["kind"] == "dns_resolution_failed" and event["host"] in allowed
        for event in clean
    )


def event_references(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Return the compact, ordered evidence identities bound by a finalizer event."""
    refs: list[dict[str, Any]] = []
    for index, row in enumerate(rows):
        reference = row.get("infrastructure_evidence")
        if isinstance(reference, dict):
            refs.append({
                "validation_index": int(row.get("validation_index", index)),
                "evidence_id": str(reference.get("evidence_id") or ""),
                "sha256": str(reference.get("sha256") or ""),
            })
    return refs
