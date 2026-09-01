"""Trusted privileged-capability canary commissioning evidence."""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
from typing import Any

EVIDENCE_SCHEMA = "ownframework-loop-privileged-commissioning/v1"
CANARY_RESULT_SCHEMA = "ownframework-loop-privileged-canary/v1"
CANARY_VERSION = 1
_CANARY_KINDS = {
    "container.docker": "docker-broker-local-control",
    "local.http-service": "claude-safe-local-binding",
}


class CommissioningError(RuntimeError):
    pass


def _canonical(obj: Any) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()


def default_evidence_dir() -> Path:
    root = os.environ.get("XDG_STATE_HOME", "").strip()
    base = Path(root).expanduser() if root else Path.home() / ".local" / "state"
    return base / "ownframework-loop" / "commissioning"


def evidence_path(name: str, evidence_dir: Path | None = None) -> Path:
    return (evidence_dir or default_evidence_dir()).expanduser().resolve(strict=False) / (name.replace(".", "_") + ".json")


def _trusted_executable(value: Any, *, field: str) -> tuple[str, str]:
    if not isinstance(value, str):
        raise CommissioningError(f"{field} must be an absolute executable path")
    raw = Path(value).expanduser()
    if not raw.is_absolute() or raw.is_symlink():
        raise CommissioningError(f"{field} must be absolute and not a symlink")
    p = raw.resolve(strict=False)
    if not (p.is_file() and os.access(p, os.X_OK)):
        raise CommissioningError(f"{field} is not executable: {p}")
    st = p.stat()
    if hasattr(os, "getuid") and st.st_uid != os.getuid():
        raise CommissioningError(f"{field} must be owned by supervisor user")
    if st.st_mode & 0o022:
        raise CommissioningError(f"{field} must not be group/world writable")
    h = hashlib.sha256()
    with p.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return str(p), h.hexdigest()


def _provider_identity(name: str, entry: dict[str, Any]) -> dict[str, Any]:
    from . import capabilities as cap
    if name == "container.docker":
        executable, digest = _trusted_executable(
            entry.get("broker_executable"), field="container.docker.broker_executable"
        )
        if Path(executable).name != "docker":
            raise CommissioningError("Docker broker must be a drop-in executable named docker")
        args = entry.get("version_args", ["--version"])
        if not isinstance(args, list) or not all(isinstance(x, str) for x in args):
            raise CommissioningError("container.docker.version_args must be an array of strings")
        try:
            proc = subprocess.run(
                [executable, *args], capture_output=True, text=True,
                check=False, timeout=5,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            raise CommissioningError(f"Docker broker version proof failed: {exc}") from exc
        lines = (proc.stdout or proc.stderr or "").strip().splitlines()
        if not lines:
            raise CommissioningError("Docker broker version could not be proven")
        return {
            "provider": "broker", "executable": executable,
            "version": lines[0][:512], "executable_sha256": digest,
        }
    if name == "local.http-service":
        if entry.get("provider") != "claude_native_safe_local_binding":
            raise CommissioningError("local.http-service provider is not commissioned")
        return {"provider": str(entry.get("provider"))}
    raise CommissioningError(f"unsupported privileged capability: {name}")


def commission_capability(
    name: str, *, manifest_path: Path | None = None, evidence_dir: Path | None = None
) -> dict[str, Any]:
    from . import capabilities as cap
    if name not in _CANARY_KINDS:
        raise CommissioningError(f"{name!r} has no privileged canary contract")
    entries, manifest_name, manifest_sha = cap._load_host_manifest(manifest_path)
    entry = cap._entry_for(name, entries)
    if not entry:
        raise CommissioningError(f"{name!r} is not declared in host manifest")
    canary_path, canary_sha = _trusted_executable(
        entry.get("canary_executable"), field=f"{name}.canary_executable"
    )
    provider = _provider_identity(name, entry)
    fingerprint = cap.semantic_runtime_fingerprint()
    proc = subprocess.run(
        [
            canary_path, "--ofloop-capability-canary", name, fingerprint,
            _CANARY_KINDS[name], cap.CAPABILITY_CONTRACT_REVISION,
        ],
        capture_output=True, text=True, check=False, timeout=30,
    )
    if proc.returncode != 0:
        raise CommissioningError(
            f"privileged canary failed rc={proc.returncode}: {(proc.stderr or proc.stdout)[-1000:]}"
        )
    try:
        canary = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise CommissioningError("privileged canary returned invalid JSON") from exc
    expected = {
        "schema": CANARY_RESULT_SCHEMA, "ok": True, "capability": name,
        "capability_contract_revision": cap.CAPABILITY_CONTRACT_REVISION,
        "semantic_runtime_fingerprint": fingerprint,
        "provider": str(entry.get("provider") or provider.get("provider") or ""),
        "canary_kind": _CANARY_KINDS[name], "canary_version": CANARY_VERSION,
    }
    if not isinstance(canary, dict) or any(canary.get(k) != v for k, v in expected.items()):
        raise CommissioningError("privileged canary result does not match runtime contract")
    body = {
        "schema": EVIDENCE_SCHEMA, "capability": name,
        "capability_contract_revision": cap.CAPABILITY_CONTRACT_REVISION,
        "semantic_runtime_fingerprint": fingerprint,
        "platform_identity": cap.platform_identity(),
        "provider": expected["provider"], "provider_identity": provider,
        "canary_executable": canary_path, "canary_executable_sha256": canary_sha,
        "canary_kind": _CANARY_KINDS[name], "canary_version": CANARY_VERSION,
        "canary_result": True,
        "canary_output_sha256": hashlib.sha256(_canonical(canary)).hexdigest(),
        "host_manifest_path": manifest_name, "host_manifest_sha256": manifest_sha,
    }
    body["evidence_sha256"] = hashlib.sha256(_canonical(body)).hexdigest()
    path = evidence_path(name, evidence_dir)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(body, indent=2, sort_keys=True) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    return {**body, "evidence_path": str(path)}


def verify_commissioning(
    name: str,
    entry: dict[str, Any],
    *,
    manifest_sha256: str | None,
    evidence_dir: Path | None = None,
) -> dict[str, Any]:
    from . import capabilities as cap
    path = evidence_path(name, evidence_dir)
    if not path.exists():
        raise CommissioningError(f"{name} has no canary-proven commissioning evidence")
    if path.is_symlink():
        raise CommissioningError("commissioning evidence must not be a symlink")
    st = path.stat()
    if not stat.S_ISREG(st.st_mode) or st.st_mode & 0o022:
        raise CommissioningError("commissioning evidence must be a private regular file")
    if hasattr(os, "getuid") and st.st_uid != os.getuid():
        raise CommissioningError("commissioning evidence must be owned by supervisor user")
    try:
        doc = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise CommissioningError(f"commissioning evidence corrupt: {exc}") from exc
    if not isinstance(doc, dict) or doc.get("schema") != EVIDENCE_SCHEMA:
        raise CommissioningError("commissioning evidence schema mismatch")
    claimed = doc.get("evidence_sha256")
    raw = dict(doc); raw.pop("evidence_sha256", None)
    if claimed != hashlib.sha256(_canonical(raw)).hexdigest():
        raise CommissioningError("commissioning evidence digest mismatch")
    canary_path, canary_sha = _trusted_executable(
        entry.get("canary_executable"), field=f"{name}.canary_executable"
    )
    current_provider = _provider_identity(name, entry)
    checks = {
        "capability": name,
        "capability_contract_revision": cap.CAPABILITY_CONTRACT_REVISION,
        "semantic_runtime_fingerprint": cap.semantic_runtime_fingerprint(),
        "platform_identity": cap.platform_identity(),
        "provider_identity": current_provider,
        "canary_executable": canary_path,
        "canary_executable_sha256": canary_sha,
        "canary_kind": _CANARY_KINDS.get(name),
        "canary_version": CANARY_VERSION,
        "canary_result": True,
        "host_manifest_sha256": manifest_sha256,
    }
    for key, expected in checks.items():
        if doc.get(key) != expected:
            raise CommissioningError(f"{name} commissioning evidence drift: {key}")
    return {
        "evidence_path": str(path), "evidence_sha256": str(claimed),
        "canary_kind": doc.get("canary_kind"), "canary_version": CANARY_VERSION,
        "provider_identity": current_provider,
    }


__all__ = [
    "CANARY_RESULT_SCHEMA", "CANARY_VERSION", "CommissioningError",
    "EVIDENCE_SCHEMA", "commission_capability", "default_evidence_dir",
    "evidence_path", "verify_commissioning",
]
