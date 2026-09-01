"""Trusted host-capability resolution for semantic workers.

Packets declare semantic capability NAMES, never host paths.  The deterministic
runtime resolves those names against a small built-in registry plus an optional
operator-owned host manifest.  Resolution is fail-closed and produces a
receipt before the model process starts.

Security invariants:
- HOME is never reopened wholesale for tool discovery.
- writable durable caches are repository-scoped, not cross-repository;
- global/shared assets are read-only to semantic workers;
- privileged capabilities (notably Docker) require an operator-commissioned
  broker and never expose a raw host daemon socket;
- local binding is unavailable unless the host manifest records an explicit
  commissioned provider/proof because Claude's native allowLocalBinding has
  historically widened network authority on macOS.
"""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import sys
import re
import shutil
import stat
import subprocess
import uuid
from typing import Any

SCHEMA = "ownframework-loop-capability-resolution/v1"
HOST_MANIFEST_SCHEMA = "ownframework-loop-host-capabilities/v1"
CAPABILITY_CONTRACT_REVISION = "host-capability-contract/v2"
CAPABILITY_NAME_RE = re.compile(r"^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$")
MAX_CAPABILITIES = 32


class CapabilityResolutionError(RuntimeError):
    """Requested capability cannot be proven safely on this host."""


@dataclass(frozen=True)
class CapabilityDefinition:
    name: str
    kind: str
    executable_names: tuple[str, ...] = ()
    version_args: tuple[str, ...] = ("--version",)
    network_domains: tuple[str, ...] = ()
    cache_key: str | None = None
    cache_env: str | None = None
    privileged: bool = False
    requires_commissioned_provider: bool = False


BUILTIN_CAPABILITIES: dict[str, CapabilityDefinition] = {
    "toolchain.git": CapabilityDefinition("toolchain.git", "tool", ("git",)),
    "toolchain.python": CapabilityDefinition("toolchain.python", "tool", ("python3", "python")),
    "toolchain.node": CapabilityDefinition("toolchain.node", "tool", ("node",)),
    "toolchain.java": CapabilityDefinition("toolchain.java", "tool", ("java",), ("-version",)),
    "toolchain.go": CapabilityDefinition("toolchain.go", "tool", ("go",), ("version",)),
    "toolchain.rust": CapabilityDefinition("toolchain.rust", "tool", ("rustc",)),
    "toolchain.ffmpeg": CapabilityDefinition("toolchain.ffmpeg", "tool", ("ffmpeg",), ("-version",)),
    "package.uv": CapabilityDefinition(
        "package.uv", "package", ("uv",), network_domains=("pypi.org", "files.pythonhosted.org"),
        cache_key="uv", cache_env="UV_CACHE_DIR",
    ),
    "package.pip": CapabilityDefinition(
        "package.pip", "package", ("pip3", "pip"), network_domains=("pypi.org", "files.pythonhosted.org"),
        cache_key="pip", cache_env="PIP_CACHE_DIR",
    ),
    "package.npm": CapabilityDefinition(
        "package.npm", "package", ("npm",), network_domains=("registry.npmjs.org",),
        cache_key="npm", cache_env="npm_config_cache",
    ),
    "package.pnpm": CapabilityDefinition(
        "package.pnpm", "package", ("pnpm",), network_domains=("registry.npmjs.org",),
        cache_key="pnpm-store", cache_env="npm_config_store_dir",
    ),
    "browser.playwright.chromium": CapabilityDefinition(
        "browser.playwright.chromium", "browser",
        # Current Playwright Chromium downloads can use the Playwright CDN,
        # Microsoft's fallback CDN, and Chrome-for-Testing redirects.
        network_domains=(
            "cdn.playwright.dev",
            "playwright.download.prss.microsoft.com",
            "storage.googleapis.com",
        ),
        cache_key="playwright-browsers", cache_env="PLAYWRIGHT_BROWSERS_PATH",
    ),
    "local.http-service": CapabilityDefinition(
        "local.http-service", "local-service", requires_commissioned_provider=True,
    ),
    "container.docker": CapabilityDefinition(
        "container.docker", "privileged", privileged=True, requires_commissioned_provider=True,
    ),
}


def default_host_manifest_path() -> Path:
    root = os.environ.get("XDG_STATE_HOME", "").strip()
    base = Path(root).expanduser() if root else Path.home() / ".local" / "state"
    return base / "ownframework-loop" / "host-capabilities.json"


def platform_identity() -> dict[str, str]:
    return {
        "platform": sys.platform,
        "platform_release": os.uname().release if hasattr(os, "uname") else "",
        "machine": os.uname().machine if hasattr(os, "uname") else "",
    }


def semantic_runtime_fingerprint() -> str:
    """Fingerprint host + Claude sandbox generation for privileged proof."""
    claude_raw = os.environ.get("OFLOOP_CLAUDE_BIN", "claude")
    discovered = shutil.which(claude_raw) if not Path(claude_raw).is_absolute() else claude_raw
    claude_path = ""
    claude_version = "unavailable"
    if discovered:
        p = Path(discovered).expanduser().resolve(strict=False)
        if p.is_file() and os.access(p, os.X_OK):
            claude_path = str(p)
            try:
                proc = subprocess.run(
                    [claude_path, "--version"], capture_output=True, text=True,
                    check=False, timeout=5,
                )
                lines = (proc.stdout or proc.stderr or "").strip().splitlines()
                if lines:
                    claude_version = lines[0][:512]
            except (OSError, subprocess.SubprocessError):
                pass
    payload = {
        **platform_identity(),
        "claude_path": claude_path,
        "claude_version": claude_version,
    }
    encoded = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _file_sha256(path: str | None) -> str | None:
    if not path:
        return None
    h = hashlib.sha256()
    with Path(path).open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _trusted_asset_identity(path: Path) -> dict[str, Any]:
    raw = path.expanduser()
    if raw.is_symlink():
        raise CapabilityResolutionError("trusted asset root must not be a symlink")
    root = raw.resolve(strict=True)
    if root.is_file():
        return {"path": str(root), "kind": "file", "sha256": _file_sha256(str(root))}
    if not root.is_dir():
        raise CapabilityResolutionError(f"trusted asset is not file/directory: {root}")
    h = hashlib.sha256()
    for current, dirs, files in os.walk(root, followlinks=False):
        base = Path(current)
        dirs.sort()
        files.sort()
        for name in list(dirs) + list(files):
            p = base / name
            if p.is_symlink():
                raise CapabilityResolutionError(
                    f"trusted asset tree contains symlink: {p.relative_to(root)}"
                )
            rel = p.relative_to(root).as_posix()
            st = p.stat()
            kind = "d" if p.is_dir() else "f"
            h.update(f"{kind}\0{rel}\0{stat.S_IMODE(st.st_mode):o}\0".encode())
            if p.is_file():
                h.update((_file_sha256(str(p)) or "").encode())
            h.update(b"\n")
    return {"path": str(root), "kind": "directory", "tree_sha256": h.hexdigest()}


def validate_capability_names(values: Any) -> list[str]:
    errors: list[str] = []
    if values is None:
        return errors
    if not isinstance(values, list):
        return ["capabilities must be an array"]
    if len(values) > MAX_CAPABILITIES:
        errors.append(f"capabilities may contain at most {MAX_CAPABILITIES} entries")
    seen: set[str] = set()
    for idx, value in enumerate(values):
        if not isinstance(value, str) or not CAPABILITY_NAME_RE.fullmatch(value):
            errors.append(f"capabilities[{idx}] must be a canonical capability name")
            continue
        if value in seen:
            errors.append(f"capabilities contains duplicate capability: {value}")
        seen.add(value)
    return errors


def _load_host_manifest(path: Path | None = None) -> tuple[dict[str, Any], str | None, str | None]:
    manifest_path = (path or default_host_manifest_path()).expanduser().resolve(strict=False)
    if not manifest_path.exists():
        return {}, None, None
    if manifest_path.is_symlink():
        raise CapabilityResolutionError("host capability manifest must not be a symlink")
    st = manifest_path.stat()
    if not stat.S_ISREG(st.st_mode):
        raise CapabilityResolutionError("host capability manifest must be a regular file")
    if hasattr(os, "getuid") and st.st_uid != os.getuid():
        raise CapabilityResolutionError("host capability manifest must be owned by the supervisor user")
    if st.st_mode & 0o022:
        raise CapabilityResolutionError("host capability manifest must not be group/world writable")
    raw = manifest_path.read_bytes()
    try:
        data = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CapabilityResolutionError(f"host capability manifest is invalid JSON: {exc}") from exc
    if not isinstance(data, dict) or data.get("schema") != HOST_MANIFEST_SCHEMA:
        raise CapabilityResolutionError(
            f"host capability manifest schema must be {HOST_MANIFEST_SCHEMA!r}"
        )
    unknown_top = sorted(set(data) - {"schema", "capabilities"})
    if unknown_top:
        raise CapabilityResolutionError(
            f"host capability manifest has unsupported top-level keys: {unknown_top}"
        )
    entries = data.get("capabilities")
    if not isinstance(entries, dict):
        raise CapabilityResolutionError("host capability manifest capabilities must be an object")
    return entries, str(manifest_path), hashlib.sha256(raw).hexdigest()


def _entry_for(name: str, entries: dict[str, Any]) -> dict[str, Any]:
    raw = entries.get(name, {})
    if raw is None:
        return {}
    if not isinstance(raw, dict):
        raise CapabilityResolutionError(f"host manifest entry {name!r} must be an object")
    allowed = {
        "kind", "enabled", "executable", "broker_executable", "version_args",
        "read_paths", "network_domains", "trusted_asset_path", "provider", "proof",
        "canary_executable",
    }
    unknown = sorted(set(raw) - allowed)
    if unknown:
        raise CapabilityResolutionError(
            f"host manifest entry {name!r} has unsupported keys: {unknown}"
        )
    if raw.get("enabled") is False:
        raise CapabilityResolutionError(f"capability {name!r} is disabled by host manifest")
    return raw


def _absolute_existing_paths(values: Any, *, field: str, name: str) -> list[str]:
    if values is None:
        return []
    if not isinstance(values, list):
        raise CapabilityResolutionError(f"{name}.{field} must be an array")
    out: list[str] = []
    for value in values:
        if not isinstance(value, str):
            raise CapabilityResolutionError(f"{name}.{field} entries must be strings")
        p = Path(value).expanduser()
        if not p.is_absolute():
            raise CapabilityResolutionError(f"{name}.{field} paths must be absolute")
        rp = p.resolve(strict=False)
        if not rp.exists():
            raise CapabilityResolutionError(f"{name}.{field} path does not exist: {rp}")
        out.append(str(rp))
    return sorted(set(out))


def _network_domains(values: Any, *, name: str) -> list[str]:
    if values is None:
        return []
    if not isinstance(values, list):
        raise CapabilityResolutionError(f"{name}.network_domains must be an array")
    out: list[str] = []
    host_re = re.compile(
        r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*"
        r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"
    )
    for value in values:
        if not isinstance(value, str) or value != value.lower() or not host_re.fullmatch(value):
            raise CapabilityResolutionError(
                f"{name}.network_domains entries must be exact lowercase hostnames"
            )
        out.append(value)
    return sorted(set(out))


def _path_within(path: Path, parent: Path) -> bool:
    try:
        path.resolve(strict=False).relative_to(parent.resolve(strict=False))
        return True
    except ValueError:
        return False


def _resolve_executable(
    definition: CapabilityDefinition,
    entry: dict[str, Any],
    *,
    broker: bool = False,
) -> tuple[str | None, str | None, str | None, list[str]]:
    field = "broker_executable" if broker else "executable"
    explicit = entry.get(field)
    executable: str | None = None
    if explicit is not None:
        if not isinstance(explicit, str):
            raise CapabilityResolutionError(f"{definition.name}.{field} must be a string")
        p = Path(explicit).expanduser()
        if not p.is_absolute():
            raise CapabilityResolutionError(f"{definition.name}.{field} must be absolute")
        rp = p.resolve(strict=False)
        if not (rp.is_file() and os.access(rp, os.X_OK)):
            raise CapabilityResolutionError(
                f"{definition.name}.{field} is not an executable file: {rp}"
            )
        executable = str(rp)
    elif not broker:
        for candidate in definition.executable_names:
            discovered = shutil.which(candidate)
            if discovered:
                rp = Path(discovered).resolve(strict=False)
                if rp.is_file() and os.access(rp, os.X_OK):
                    executable = str(rp)
                    break

    if executable is None and (
        definition.executable_names
        or (definition.name not in BUILTIN_CAPABILITIES and not broker)
    ):
        raise CapabilityResolutionError(
            f"capability {definition.name!r} executable is not discoverable/commissioned"
        )

    read_paths = _absolute_existing_paths(
        entry.get("read_paths"), field="read_paths", name=definition.name
    )
    if executable:
        exe_path = Path(executable)
        home = Path.home().resolve(strict=False)
        if _path_within(exe_path, home) and not entry:
            raise CapabilityResolutionError(
                f"capability {definition.name!r} resolves under HOME and requires "
                "explicit host commissioning"
            )
        read_paths.append(executable)

    version: str | None = None
    if executable:
        args = entry.get("version_args", list(definition.version_args))
        if not isinstance(args, list) or not all(isinstance(x, str) for x in args):
            raise CapabilityResolutionError(
                f"{definition.name}.version_args must be an array of strings"
            )
        try:
            proc = subprocess.run(
                [executable, *args], capture_output=True, text=True,
                check=False, timeout=5,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            raise CapabilityResolutionError(
                f"could not prove version for {definition.name!r}: {exc}"
            ) from exc
        text = (proc.stdout or proc.stderr or "").strip().splitlines()
        if not text:
            raise CapabilityResolutionError(
                f"could not prove version for {definition.name!r}"
            )
        version = text[0][:512]

    return executable, version, _file_sha256(executable), sorted(set(read_paths))


def resolve_capabilities(
    requested: list[str] | None,
    *,
    canonical_repo: Path,
    role: str,
    repo_cache_root: Path,
    ephemeral_cache_root: Path | None = None,
    packet_network_allowlist: list[str] | None = None,
    manifest_path: Path | None = None,
) -> dict[str, Any]:
    requested = list(requested or [])
    errors = validate_capability_names(requested)
    if errors:
        raise CapabilityResolutionError("; ".join(errors))
    if role not in {"builder", "reviewer"}:
        raise CapabilityResolutionError(f"unsupported capability role: {role!r}")

    entries, manifest_name, manifest_sha = _load_host_manifest(manifest_path)
    repo_cache_root = repo_cache_root.expanduser().resolve(strict=False)
    repo_cache_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(repo_cache_root, 0o700)
    except OSError:
        pass
    if ephemeral_cache_root is None:
        ephemeral_cache_root = repo_cache_root / ".reviewer-ephemeral"
    ephemeral_cache_root = ephemeral_cache_root.expanduser().resolve(strict=False)
    ephemeral_cache_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(ephemeral_cache_root, 0o700)
    except OSError:
        pass

    resolved: list[dict[str, Any]] = []
    allow_read: set[str] = set()
    allow_write: set[str] = set()
    stable_allow_read: set[str] = set()
    environment: dict[str, str] = {}
    path_prepend: list[str] = []
    network_domains: set[str] = set(packet_network_allowlist or [])
    sandbox_network: dict[str, Any] = {}

    for name in requested:
        entry = _entry_for(name, entries)
        definition = BUILTIN_CAPABILITIES.get(name)
        if definition is None:
            if not entry:
                raise CapabilityResolutionError(
                    f"capability {name!r} is not built-in and is not commissioned"
                )
            kind = str(entry.get("kind") or "")
            if kind != "tool":
                raise CapabilityResolutionError(
                    f"custom capability {name!r} currently supports kind='tool' only"
                )
            definition = CapabilityDefinition(name, "tool", ())

        if definition.name in {"container.docker", "local.http-service"}:
            from . import commissioning as commissioning_mod
            if definition.name == "container.docker" and entry.get("provider") != "broker":
                raise CapabilityResolutionError("container.docker requires provider='broker'")
            if (
                definition.name == "local.http-service"
                and entry.get("provider") != "claude_native_safe_local_binding"
            ):
                raise CapabilityResolutionError(
                    "local.http-service requires the safe-local-binding provider"
                )
            try:
                commissioned = commissioning_mod.verify_commissioning(
                    name, entry, manifest_sha256=manifest_sha
                )
            except commissioning_mod.CommissioningError as exc:
                raise CapabilityResolutionError(str(exc)) from exc
            provider_identity = commissioned["provider_identity"]
            if definition.name == "container.docker":
                executable = str(provider_identity.get("executable") or "")
                version = provider_identity.get("version")
                executable_sha256 = provider_identity.get("executable_sha256")
                if not executable or Path(executable).name != "docker":
                    raise CapabilityResolutionError("commissioned Docker broker identity invalid")
                extra_reads = _absolute_existing_paths(
                    entry.get("read_paths"), field="read_paths", name=name
                )
                extra_reads.append(executable)
                allow_read.update(extra_reads)
                stable_allow_read.update(extra_reads)
                path_prepend.append(str(Path(executable).parent))
                manifest_domains = _network_domains(entry.get("network_domains"), name=name)
                network_domains.update(manifest_domains)
                resolved.append({
                    "name": name, "kind": "privileged", "privileged": True,
                    "provider": "broker", "executable": executable, "version": version,
                    "executable_sha256": executable_sha256,
                    "network_domains": manifest_domains,
                    "commissioning_evidence_path": commissioned["evidence_path"],
                    "commissioning_evidence_sha256": commissioned["evidence_sha256"],
                    "commissioning_canary_kind": commissioned["canary_kind"],
                })
            else:
                sandbox_network["allowLocalBinding"] = True
                resolved.append({
                    "name": name, "kind": "local-service", "privileged": True,
                    "provider": str(entry.get("provider")),
                    "commissioning_evidence_path": commissioned["evidence_path"],
                    "commissioning_evidence_sha256": commissioned["evidence_sha256"],
                    "commissioning_canary_kind": commissioned["canary_kind"],
                })
            continue

        executable, version, executable_sha256, extra_reads = _resolve_executable(definition, entry)
        allow_read.update(extra_reads)
        stable_allow_read.update(extra_reads)
        manifest_domains = _network_domains(entry.get("network_domains"), name=name)
        effective_domains = sorted(set(definition.network_domains) | set(manifest_domains))
        network_domains.update(effective_domains)

        cache_path: str | None = None
        cache_scope: str | None = None
        trusted_asset = entry.get("trusted_asset_path")
        if trusted_asset is not None:
            if not isinstance(trusted_asset, str):
                raise CapabilityResolutionError(f"{name}.trusted_asset_path must be a string")
            asset = Path(trusted_asset).expanduser()
            if not asset.is_absolute():
                raise CapabilityResolutionError(f"{name}.trusted_asset_path must be absolute")
            asset = asset.resolve(strict=False)
            if not asset.exists():
                raise CapabilityResolutionError(f"{name}.trusted_asset_path does not exist: {asset}")
            identity = _trusted_asset_identity(asset)
            cache_path = str(asset)
            cache_scope = "trusted_read_only"
            allow_read.add(cache_path)
            stable_allow_read.add(cache_path)
        elif definition.cache_key:
            cache_base = repo_cache_root if role == "builder" else ephemeral_cache_root
            cache = (cache_base / definition.cache_key).resolve(strict=False)
            cache.mkdir(parents=True, exist_ok=True, mode=0o700)
            try:
                os.chmod(cache, 0o700)
            except OSError:
                pass
            cache_path = str(cache)
            cache_scope = "repository_durable" if role == "builder" else "pass_ephemeral"
            allow_read.add(cache_path)
            allow_write.add(cache_path)

        if definition.cache_env and cache_path:
            environment[definition.cache_env] = cache_path
        if definition.name == "package.pnpm" and cache_path:
            # Reviewer metadata stays pass-ephemeral, never persistent.
            npm_base = repo_cache_root if role == "builder" else ephemeral_cache_root
            npm_cache = (npm_base / "npm").resolve(strict=False)
            npm_cache.mkdir(parents=True, exist_ok=True, mode=0o700)
            allow_read.add(str(npm_cache))
            allow_write.add(str(npm_cache))
            environment.setdefault("npm_config_cache", str(npm_cache))

        if definition.name == "browser.playwright.chromium" and role == "reviewer":
            environment["PLAYWRIGHT_SKIP_BROWSER_GC"] = "1"

        resolved.append({
            "name": name,
            "kind": definition.kind,
            "privileged": definition.privileged,
            "provider": "builtin" if not entry else "commissioned",
            "executable": executable,
            "version": version,
            "executable_sha256": executable_sha256,
            "cache_path": cache_path,
            "cache_scope": cache_scope,
            "trusted_asset_identity": identity if trusted_asset is not None else None,
            "network_domains": effective_domains,
        })

    # Never allow capability resolution to widen a worker by smuggling a daemon
    # socket. Docker is broker-only and local-service has a separate explicit
    # sandbox primitive.
    forbidden_socket_markers = ("/docker.sock", "/containerd.sock", "/podman.sock")
    if any(any(marker in p for marker in forbidden_socket_markers) for p in allow_read | allow_write):
        raise CapabilityResolutionError("capability filesystem authority contains a forbidden daemon socket")

    return {
        "schema": SCHEMA,
        "capability_contract_revision": CAPABILITY_CONTRACT_REVISION,
        "requested": requested,
        "resolved": resolved,
        "network_domains": sorted(network_domains),
        "filesystem": {
            "allowRead": sorted(allow_read),
            "allowWrite": sorted(allow_write),
        },
        "environment": dict(sorted(environment.items())),
        "path_prepend": sorted(set(path_prepend)),
        "sandbox_network": sandbox_network,
        "stable_filesystem": {
            "allowRead": sorted(stable_allow_read),
            "allowWrite": [],
        },
        "host_manifest_path": manifest_name,
        "host_manifest_sha256": manifest_sha,
        "semantic_runtime_fingerprint": semantic_runtime_fingerprint(),
        "platform_identity": platform_identity(),
    }


def probe_host_capabilities(
    *, manifest_path: Path | None = None,
) -> dict[str, Any]:
    """Read-only capability inventory including canary commissioning state."""
    try:
        entries, manifest_name, manifest_sha = _load_host_manifest(manifest_path)
        manifest_error = None
    except CapabilityResolutionError as exc:
        entries = {}
        manifest_name = str(
            (manifest_path or default_host_manifest_path()).expanduser().resolve(strict=False)
        )
        manifest_sha = None
        manifest_error = str(exc)
    items: list[dict[str, Any]] = []
    for name, definition in sorted(BUILTIN_CAPABILITIES.items()):
        item: dict[str, Any] = {
            "name": name, "kind": definition.kind,
            "privileged": bool(definition.requires_commissioned_provider or definition.privileged),
            "available": False,
        }
        if manifest_error:
            item["reason"] = f"host_manifest_invalid: {manifest_error}"
            items.append(item)
            continue
        try:
            entry = _entry_for(name, entries)
            if definition.requires_commissioned_provider:
                from . import commissioning as commissioning_mod
                commissioned = commissioning_mod.verify_commissioning(
                    name, entry, manifest_sha256=manifest_sha
                )
                item.update({
                    "available": True,
                    "provider": entry.get("provider"),
                    "commissioning_evidence_sha256": commissioned["evidence_sha256"],
                    "canary_kind": commissioned["canary_kind"],
                })
                if name == "container.docker":
                    item.update(commissioned["provider_identity"])
            elif definition.executable_names:
                executable, version, digest, _ = _resolve_executable(definition, entry)
                item.update({
                    "available": True,
                    "provider": "builtin" if not entry else "commissioned",
                    "executable": executable, "version": version,
                    "executable_sha256": digest,
                })
            else:
                item.update({"available": True, "provider": "project_runtime"})
                if entry.get("trusted_asset_path"):
                    item["trusted_asset_identity"] = _trusted_asset_identity(
                        Path(str(entry["trusted_asset_path"]))
                    )
        except Exception as exc:
            item["reason"] = str(exc)
        items.append(item)
    return {
        "schema": "ownframework-loop-host-capability-inventory/v1",
        "capability_contract_revision": CAPABILITY_CONTRACT_REVISION,
        "runtime_fingerprint": semantic_runtime_fingerprint(),
        "platform_identity": platform_identity(),
        "host_manifest_path": manifest_name,
        "host_manifest_sha256": manifest_sha,
        "manifest_error": manifest_error,
        "capabilities": items,
    }


def public_summary(resolution: dict[str, Any]) -> dict[str, Any]:
    return {
        "schema": resolution.get("schema"),
        "requested": list(resolution.get("requested") or []),
        "resolved": [
            {
                k: item.get(k)
                for k in (
                    "name", "kind", "privileged", "provider", "executable",
                    "version", "executable_sha256", "cache_path", "cache_scope",
                )
                if item.get(k) is not None
            }
            for item in (resolution.get("resolved") or [])
            if isinstance(item, dict)
        ],
        "network_domains": list(resolution.get("network_domains") or []),
    }


def verify_resolution_integrity(resolution: dict[str, Any]) -> None:
    path_value = resolution.get("host_manifest_path")
    _, _, current_manifest = _load_host_manifest(
        Path(str(path_value)) if path_value else None
    )
    if current_manifest != resolution.get("host_manifest_sha256"):
        raise CapabilityResolutionError("host capability manifest changed after resolution")
    for item in resolution.get("resolved") or []:
        if not isinstance(item, dict):
            continue
        executable = item.get("executable")
        digest = item.get("executable_sha256")
        if executable and digest and _file_sha256(str(executable)) != digest:
            raise CapabilityResolutionError(
                f"capability executable changed after resolution: {item.get('name')}"
            )
        trusted = item.get("trusted_asset_identity")
        if isinstance(trusted, dict):
            if _trusted_asset_identity(Path(str(trusted.get("path") or ""))) != trusted:
                raise CapabilityResolutionError(
                    f"trusted capability asset changed after resolution: {item.get('name')}"
                )
        evidence_path_value = item.get("commissioning_evidence_path")
        evidence_sha = item.get("commissioning_evidence_sha256")
        if evidence_path_value and evidence_sha:
            p = Path(str(evidence_path_value))
            if not p.is_file() or p.is_symlink():
                raise CapabilityResolutionError("commissioning evidence disappeared after resolution")
            try:
                doc = json.loads(p.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                raise CapabilityResolutionError("commissioning evidence became unreadable") from exc
            if doc.get("evidence_sha256") != evidence_sha:
                raise CapabilityResolutionError("commissioning evidence changed after resolution")


def _publish_immutable_text(path: Path, encoded: str) -> bool:
    """Publish an immutable complete file without a visible partial-write window."""
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


def write_resolution_receipt(
    canonical_repo: Path,
    run_id: str,
    role: str,
    attempt_id: str,
    resolution: dict[str, Any],
    *,
    run_binding: dict[str, Any] | None = None,
    runner_profile: dict[str, Any] | None = None,
) -> Path:
    safe_prefix = re.sub(r"[^A-Za-z0-9_.-]", "_", str(attempt_id))[:64]
    safe_attempt = safe_prefix + "-" + hashlib.sha256(str(attempt_id).encode()).hexdigest()[:16]
    if not safe_attempt:
        raise CapabilityResolutionError("capability receipt requires attempt identity")
    root = canonical_repo.resolve(strict=False) / ".ownframework-loop" / run_id / "capabilities"
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(root, 0o700)
    except OSError:
        pass
    path = root / f"{safe_attempt}-{role}.json"
    payload = dict(resolution)
    payload["run_id"] = run_id
    payload["role"] = role
    payload["attempt_id"] = attempt_id
    if run_binding is not None:
        payload["run_binding_sha256"] = run_binding.get("binding_sha256")
    if runner_profile is not None:
        payload["runner_profile"] = {
            k: runner_profile.get(k)
            for k in ("name", "provider", "model", "effort", "identity_sha256")
        }
    encoded = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    if path.exists():
        if path.is_symlink() or path.read_text(encoding="utf-8") != encoded:
            raise CapabilityResolutionError("capability receipt collision/overwrite refused")
        return path
    if _publish_immutable_text(path, encoded):
        return path
    if path.is_symlink() or path.read_text(encoding="utf-8") != encoded:
        raise CapabilityResolutionError("capability receipt race/collision refused")
    return path


__all__ = [
    "BUILTIN_CAPABILITIES",
    "CAPABILITY_CONTRACT_REVISION",
    "CAPABILITY_NAME_RE",
    "CapabilityDefinition",
    "CapabilityResolutionError",
    "HOST_MANIFEST_SCHEMA",
    "MAX_CAPABILITIES",
    "SCHEMA",
    "default_host_manifest_path",
    "platform_identity",
    "probe_host_capabilities",
    "public_summary",
    "resolve_capabilities",
    "semantic_runtime_fingerprint",
    "validate_capability_names",
    "verify_resolution_integrity",
    "write_resolution_receipt",
]
