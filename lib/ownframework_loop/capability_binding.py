"""Immutable run-level capability/execution-environment binding."""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import stat
import uuid
from typing import Any

SCHEMA = "ownframework-loop-capability-binding/v1"
PROJECTION_REVISION = "capability-binding-projection/v3"


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
            for k in ("name", "provider", "model", "effort", "identity_sha256")
        },
    }


def _read(path: Path) -> dict[str, Any]:
    if path.is_symlink():
        raise CapabilityBindingError("capability binding must not be a symlink")
    st = path.stat()
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
    projection = doc.get("projection") if isinstance(doc, dict) else None
    if doc.get("schema") != SCHEMA or not isinstance(projection, dict):
        raise CapabilityBindingError("capability binding schema/projection mismatch")
    if doc.get("binding_sha256") != hashlib.sha256(_canonical(projection)).hexdigest():
        raise CapabilityBindingError("capability binding digest mismatch")
    return doc


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
    payload = {"schema": SCHEMA, "run_id": run_id, "projection": projection, "binding_sha256": digest}
    encoded = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    if _publish_complete_no_replace(path, encoded):
        return payload
    existing = _read(path)
    if existing.get("binding_sha256") != digest or existing.get("projection") != projection:
        raise CapabilityBindingError("concurrent first-attempt capability binding conflict")
    return existing


def verify_run_binding(
    canonical_repo: Path, run_id: str, resolution: dict[str, Any], runner_profile: dict[str, Any]
) -> dict[str, Any]:
    return ensure_run_binding(
        canonical_repo, run_id, resolution, runner_profile, allow_create=False
    )


__all__ = [
    "CapabilityBindingError", "PROJECTION_REVISION", "SCHEMA", "binding_path",
    "ensure_run_binding", "stable_projection", "verify_run_binding",
]
