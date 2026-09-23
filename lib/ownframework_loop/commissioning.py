"""Trusted privileged-capability canary commissioning evidence."""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
from typing import Any

from . import process_runner

EVIDENCE_SCHEMA = "ownframework-loop-privileged-commissioning/v1"
CANARY_RESULT_SCHEMA = "ownframework-loop-privileged-canary/v1"
CANARY_VERSION = 1
_CANARY_KINDS = {
    "container.docker": "docker-broker-local-control",
    "local.http-service": "claude-safe-local-binding",
    "research.public": "core-research-broker-boundary",
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


def read_commissioning_evidence(
    name: str,
    *,
    evidence_dir: Path | None = None,
) -> dict[str, Any]:
    """Canonical read/verify API for privileged-capability evidence.

    Returns the FULL evidence document (the same shape
    ``commission_capability`` wrote) AFTER verifying:

      - evidence file exists and is a regular non-symlink file
        with private mode;
      - evidence JSON is a single object;
      - ``schema`` matches the canonical ``EVIDENCE_SCHEMA``;
      - ``evidence_sha256`` matches the canonical SHA-256 over the
        rest of the document (i.e. the receipt is intact);
      - ``capability`` matches the requested ``name``;
      - the broker executable path resolves to a regular
        non-symlink file, has private mode, and its CURRENT bytes
        hash to the expected ``provider_identity.executable_sha256``;
      - the expected ``provider_identity.executable_sha256`` is
        non-empty and canonical (64-char lowercase hex).

    Returns the broker executable path + current SHA on success.

    Raises ``CommissioningError`` on any drift / missing / private /
    unsymlink / sha-mismatch condition. Does NOT catch and return
    a soft error — callers must treat CommissioningError as fail
    closed.
    """
    ev_dir = Path(evidence_dir).expanduser() if evidence_dir is not None else default_evidence_dir()
    path = evidence_path(name, ev_dir)
    if not path.is_file() or path.is_symlink():
        raise CommissioningError(
            f"{name} commissioning evidence missing or symlink: {path}"
        )
    st = path.stat()
    if not stat.S_ISREG(st.st_mode):
        raise CommissioningError(
            f"{name} commissioning evidence not a regular file: {path}"
        )
    if stat.S_IMODE(st.st_mode) & 0o022:
        raise CommissioningError(
            f"{name} commissioning evidence must not be group/world writable"
        )
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise CommissioningError(
            f"{name} commissioning evidence unreadable: {exc}"
        )
    try:
        doc = json.loads(text)
    except json.JSONDecodeError as exc:
        raise CommissioningError(
            f"{name} commissioning evidence not JSON: {exc}"
        )
    if not isinstance(doc, dict):
        raise CommissioningError(
            f"{name} commissioning evidence is not a JSON object"
        )
    if doc.get("schema") != EVIDENCE_SCHEMA:
        raise CommissioningError(
            f"{name} commissioning evidence schema mismatch"
        )
    if doc.get("capability") != name:
        raise CommissioningError(
            f"{name} commissioning evidence capability mismatch"
        )
    expected_digest = doc.get("evidence_sha256")
    if not isinstance(expected_digest, str) or not expected_digest:
        raise CommissioningError(
            f"{name} commissioning evidence digest missing"
        )
    raw = dict(doc)
    raw.pop("evidence_sha256", None)
    if expected_digest != hashlib.sha256(_canonical(raw)).hexdigest():
        raise CommissioningError(
            f"{name} commissioning evidence digest mismatch"
        )
    provider_identity = doc.get("provider_identity") or {}
    if not isinstance(provider_identity, dict):
        raise CommissioningError(
            f"{name} commissioning evidence provider_identity missing"
        )
    executable_path = provider_identity.get("executable")
    expected_sha = provider_identity.get("executable_sha256")
    if not isinstance(executable_path, str) or not executable_path:
        raise CommissioningError(
            f"{name} commissioning evidence missing broker executable"
        )
    if (
        not isinstance(expected_sha, str)
        or len(expected_sha) != 64
        or any(c not in "0123456789abcdef" for c in expected_sha)
    ):
        raise CommissioningError(
            f"{name} commissioning evidence missing canonical broker SHA"
        )
    actual_path, current_sha = _trusted_executable(
        executable_path, field=f"{name}.provider_identity.executable"
    )
    if current_sha != expected_sha:
        raise CommissioningError(
            f"{name} commissioning broker executable SHA drift: "
            f"expected={expected_sha} current={current_sha}"
        )
    doc["_broker_path"] = actual_path
    doc["_broker_sha256"] = current_sha
    return doc


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
            proc = process_runner.run_bounded_capture(
                [executable, *args], timeout_seconds=5,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            raise CommissioningError(f"Docker broker version proof failed: {exc}") from exc
        if proc.returncode != 0:
            raise CommissioningError(
                "Docker broker version proof did not exit 0; "
                f"rc={proc.returncode}"
            )
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
    if name == "research.public":
        if entry.get("provider") != "core_research_broker":
            raise CommissioningError(
                "research.public provider must be 'core_research_broker'"
            )
        executable, digest = _trusted_executable(
            entry.get("broker_executable"),
            field="research.public.broker_executable",
        )
        if Path(executable).name != "ofloop-research-broker":
            raise CommissioningError(
                "research.public broker_executable must be named "
                "'ofloop-research-broker' (not a drop-in replacer)"
            )
        args = entry.get("version_args", ["--op", "ping"])
        if not isinstance(args, list) or not all(isinstance(x, str) for x in args):
            raise CommissioningError(
                "research.public.version_args must be an array of strings"
            )
        try:
            proc = process_runner.run_bounded_capture(
                [executable, *args], timeout_seconds=5,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            raise CommissioningError(
                f"research.public broker version proof failed: {exc}"
            ) from exc
        if proc.returncode != 0:
            raise CommissioningError(
                "research.public broker did not exit 0 on --op=ping; "
                f"rc={proc.returncode}"
            )
        try:
            payload = json.loads(proc.stdout)
        except json.JSONDecodeError as exc:
            raise CommissioningError(
                "research.public broker --op=ping returned invalid JSON"
            ) from exc
        if not isinstance(payload, dict):
            raise CommissioningError(
                "research.public broker --op=ping did not return a JSON object"
            )
        if payload.get("ok") is not True or payload.get("op") != "ping":
            raise CommissioningError(
                "research.public broker --op=ping did not return a healthy "
                "ping envelope"
            )
        if payload.get("capability") != "research.public":
            raise CommissioningError(
                "research.public broker --op=ping reports a different "
                "capability name"
            )
        observed_sha = str(payload.get("broker_sha256") or "")
        if not observed_sha or observed_sha != digest:
            raise CommissioningError(
                "research.public broker executable SHA-256 reported by "
                "--op=ping does not match the file digest; the broker "
                "identity is not self-consistent"
            )
        version = str(payload.get("version") or "")
        return {
            "provider": "core_research_broker",
            "executable": executable,
            "version": version,
            "executable_sha256": digest,
        }
    raise CommissioningError(f"unsupported privileged capability: {name}")


def commission_capability(
    name: str,
    *,
    manifest_path: Path | None = None,
    evidence_dir: Path | None = None,
    timeout_seconds: float = 30.0,
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
    try:
        proc = process_runner.run_bounded_capture(
            [
                canary_path, "--ofloop-capability-canary", name, fingerprint,
                _CANARY_KINDS[name], cap.CAPABILITY_CONTRACT_REVISION,
            ],
            timeout_seconds=timeout_seconds,
        )
    except subprocess.TimeoutExpired as exc:
        raise CommissioningError(
            f"privileged canary timed out after {timeout_seconds}s: {name}"
        ) from exc
    except (OSError, subprocess.SubprocessError, ValueError) as exc:
        raise CommissioningError(
            f"privileged canary launch failed for {name}: "
            f"{type(exc).__name__}: {exc}"
        ) from exc
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
    "evidence_path", "read_commissioning_evidence", "verify_commissioning",
]
