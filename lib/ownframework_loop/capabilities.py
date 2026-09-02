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
import importlib.metadata
import importlib.util
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
        # Microsoft's fallback CDN, and Chrome-for-Testing redirects. These
        # domains serve the ONE-TIME operator provisioning of the shared
        # immutable asset root; runtime-proven workers consume the assets
        # read-only and never re-download them per pass.
        network_domains=(
            "cdn.playwright.dev",
            "playwright.download.prss.microsoft.com",
            "storage.googleapis.com",
        ),
        # No per-role cache_key: browser binaries are NOT a mutable cache.
        # Resolution wires default_browser_asset_dir() read-only instead.
        cache_env="PLAYWRIGHT_BROWSERS_PATH",
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
    """Fingerprint host + Claude sandbox generation for privileged proof.

    The Claude runtime is BYTE-bound: the fingerprint includes the SHA-256 of
    the resolved Claude executable's bytes, not just its path/version string.
    A swapped/modified binary that reports the same `--version` therefore
    changes the fingerprint and invalidates any commissioning evidence bound to
    the prior runtime.
    """
    claude_raw = os.environ.get("OFLOOP_CLAUDE_BIN", "claude")
    discovered = shutil.which(claude_raw) if not Path(claude_raw).is_absolute() else claude_raw
    claude_path = ""
    claude_version = "unavailable"
    claude_sha256 = ""
    if discovered:
        p = Path(discovered).expanduser().resolve(strict=False)
        if p.is_file() and os.access(p, os.X_OK):
            claude_path = str(p)
            try:
                claude_sha256 = _file_sha256(claude_path) or ""
            except OSError:
                claude_sha256 = ""
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
        "claude_sha256": claude_sha256,
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


def _playwright_client_tree_sha256(root: Path) -> str:
    """Hash Playwright client implementation bytes, excluding Python caches."""
    raw = Path(root).expanduser()
    if raw.is_symlink():
        raise CapabilityResolutionError("Playwright client package root must not be a symlink")
    package_root = raw.resolve(strict=True)
    if not package_root.is_dir():
        raise CapabilityResolutionError("Playwright client package root is not a directory")
    h = hashlib.sha256()
    observed = 0
    for dirpath, dirnames, filenames in os.walk(package_root, followlinks=False):
        base = Path(dirpath)
        kept_dirs: list[str] = []
        for name in sorted(dirnames):
            if name == "__pycache__":
                continue
            p = base / name
            if p.is_symlink():
                raise CapabilityResolutionError(
                    f"Playwright client tree contains directory symlink: {p.relative_to(package_root)}"
                )
            kept_dirs.append(name)
            rel = p.relative_to(package_root).as_posix()
            h.update(f"d\0{rel}\0{stat.S_IMODE(p.stat().st_mode):o}\0".encode())
        dirnames[:] = kept_dirs
        for name in sorted(filenames):
            if name.endswith((".pyc", ".pyo")):
                continue
            p = base / name
            if p.is_symlink():
                raise CapabilityResolutionError(
                    f"Playwright client tree contains file symlink: {p.relative_to(package_root)}"
                )
            st = p.stat()
            if not stat.S_ISREG(st.st_mode):
                raise CapabilityResolutionError(
                    f"Playwright client tree contains non-regular entry: {p.relative_to(package_root)}"
                )
            rel = p.relative_to(package_root).as_posix()
            h.update(f"f\0{rel}\0{stat.S_IMODE(st.st_mode):o}\0".encode())
            h.update((_file_sha256(str(p)) or "").encode("ascii"))
            h.update(b"\0")
            observed += 1
    if observed == 0:
        raise CapabilityResolutionError("Playwright client package has no implementation files")
    return h.hexdigest()


def playwright_client_identity() -> dict[str, str]:
    """Byte-bind the exact imported Python Playwright client implementation.

    Browser asset proof alone is insufficient: the same Chromium tree can be
    driven by different Playwright client bytes. Bind the resolved import root,
    deterministic implementation-tree digest, and installed distribution
    version. Python-generated __pycache__/pyc files are excluded so harmless
    interpreter cache churn cannot stale commissioning evidence.
    """
    try:
        spec = importlib.util.find_spec("playwright")
    except (ImportError, AttributeError, ValueError) as exc:
        raise CapabilityResolutionError(
            f"Playwright client identity is unavailable: {exc}"
        ) from exc
    if spec is None or spec.submodule_search_locations is None:
        raise CapabilityResolutionError("Playwright client package is not importable")
    roots = [Path(str(p)).expanduser() for p in spec.submodule_search_locations]
    if len(roots) != 1:
        raise CapabilityResolutionError(
            f"Playwright client package has ambiguous roots: {len(roots)}"
        )
    raw_root = roots[0]
    if raw_root.is_symlink():
        raise CapabilityResolutionError("Playwright client package root must not be a symlink")
    root = raw_root.resolve(strict=True)
    try:
        version = importlib.metadata.version("playwright")
    except importlib.metadata.PackageNotFoundError:
        version = ""
    return {
        "package_root": str(root),
        "package_tree_sha256": _playwright_client_tree_sha256(root),
        "distribution_version": str(version),
    }


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
    raw_path = (path or default_host_manifest_path()).expanduser()
    # Refuse a symlinked authority manifest on the UNRESOLVED path. The previous
    # resolve()-then-is_symlink() ordering followed the link first, so the
    # check ran against the target and could never fire.
    if raw_path.is_symlink():
        raise CapabilityResolutionError("host capability manifest must not be a symlink")
    manifest_path = raw_path.resolve(strict=False)
    if not manifest_path.exists():
        return {}, None, None
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
    browser_asset_root: Path | None = None,
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
        browser_binding: dict[str, Any] | None = None
        trusted_asset = entry.get("trusted_asset_path")
        if trusted_asset is not None:
            if not isinstance(trusted_asset, str):
                raise CapabilityResolutionError(f"{name}.trusted_asset_path must be a string")
            asset_raw = Path(trusted_asset).expanduser()
            if not asset_raw.is_absolute():
                raise CapabilityResolutionError(f"{name}.trusted_asset_path must be absolute")
            if asset_raw.is_symlink():
                raise CapabilityResolutionError(
                    f"{name}.trusted_asset_path must not be a symlink"
                )
            asset = asset_raw.resolve(strict=False)
            if not asset.exists():
                raise CapabilityResolutionError(f"{name}.trusted_asset_path does not exist: {asset}")
            identity = _trusted_asset_identity(asset_raw)
            cache_path = str(asset)
            cache_scope = "trusted_read_only"
            allow_read.add(cache_path)
            stable_allow_read.add(cache_path)
        elif definition.kind == "browser":
            # Execution resolution is stronger than inventory discovery: a
            # requested browser must already be empirically proven against the
            # EXACT immutable asset root workers receive. Probe remains the
            # surface for provisionable/resolvable-but-not-ready states.
            root_raw = Path(browser_asset_root or default_browser_asset_dir()).expanduser()
            if root_raw.is_symlink():
                raise CapabilityResolutionError(
                    f"browser asset root must not be a symlink: {root_raw}"
                )
            root = _browser_asset_root(root_raw, require_exists=True)
            proven, proof_reason, proof_identity = _browser_runtime_proof_status(
                definition.name, expected_asset_root=root
            )
            provisionable, _pw_ref = _playwright_resolvable()
            if not proven or proof_identity is None:
                raise CapabilityResolutionError(
                    f"browser capability is not execution-ready: {proof_reason}; "
                    "provision the shared asset root and run the browser canary"
                )
            browser_binding = {
                **proof_identity,
                "runtime_proven": True,
                "provisionable": bool(provisionable),
                "proof_status": "",
            }
            allow_read.add(str(root))
            stable_allow_read.add(str(root))
            cache_path = str(root)
            cache_scope = "commissioned_shared_read_only"
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

        if definition.name == "browser.playwright.chromium":
            # The shared asset root is immutable for workers of BOTH roles:
            # never let Playwright's browser GC delete or rewrite the
            # commissioned binaries underneath a run.
            environment["PLAYWRIGHT_SKIP_BROWSER_GC"] = "1"

        resolved_item = {
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
        }
        if browser_binding is not None:
            # Explicit provisionable-vs-runtime-proven semantics for consumers
            # (binding, probe, preflight): resolution wires the shared asset
            # root either way and never certifies an unproven browser.
            resolved_item["browser"] = browser_binding
        resolved.append(resolved_item)

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


BROWSER_RUNTIME_PROOF_SCHEMA = "ownframework-loop-browser-runtime-proof/v4"


def browser_runtime_proof_path(
    name: str = "browser.playwright.chromium",
    evidence_dir: Path | None = None,
) -> Path:
    """Durable runtime-proof evidence path for one browser capability."""
    from . import commissioning as commissioning_mod
    base = (evidence_dir or commissioning_mod.default_evidence_dir())
    return base.expanduser().resolve(strict=False) / (
        name.replace(".", "_") + "_runtime_proof.json"
    )


def default_browser_asset_dir() -> Path:
    """Shared immutable browser asset root (commissioned host artifact).

    Return the lexical path without resolving the leaf: callers must be able
    to detect if an operator replaced the commissioned root with a symlink.
    """
    from . import commissioning as commissioning_mod
    base = commissioning_mod.default_evidence_dir()
    return base.parent / "browser-assets" / "playwright-chromium"


def _browser_asset_root(value: Path, *, require_exists: bool = True) -> Path:
    raw = Path(value).expanduser()
    if raw.is_symlink():
        raise CapabilityResolutionError(
            f"browser asset root must not be a symlink: {raw}"
        )
    resolved = raw.resolve(strict=False)
    if require_exists and not resolved.is_dir():
        raise CapabilityResolutionError(
            f"browser asset root is not a real directory: {raw}"
        )
    return resolved


def browser_asset_merkle_sha256(asset_root: Path) -> str:
    """Deterministic identity of the exact browser asset tree.

    Identity covers relative path, entry type, POSIX mode and file bytes.
    Root/file/directory symlinks are refused before they can disappear through
    path resolution or os.walk(followlinks=False).
    """
    root = _browser_asset_root(asset_root, require_exists=True)
    entries: list[tuple[str, str, int, str]] = []
    root_mode = stat.S_IMODE(root.stat().st_mode)
    entries.append(("d", ".", root_mode, ""))
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        base = Path(dirpath)
        dirnames.sort()
        filenames.sort()
        for name in list(dirnames):
            p = base / name
            if p.is_symlink():
                raise CapabilityResolutionError(
                    f"browser asset tree contains directory symlink: {p.relative_to(root)}"
                )
            st = p.stat()
            entries.append(("d", p.relative_to(root).as_posix(), stat.S_IMODE(st.st_mode), ""))
        for name in filenames:
            p = base / name
            if p.is_symlink():
                raise CapabilityResolutionError(
                    f"browser asset tree contains file symlink: {p.relative_to(root)}"
                )
            st = p.stat()
            if not stat.S_ISREG(st.st_mode):
                raise CapabilityResolutionError(
                    f"browser asset tree contains non-regular entry: {p.relative_to(root)}"
                )
            fh = hashlib.sha256()
            with p.open("rb") as f:
                for chunk in iter(lambda: f.read(1 << 20), b""):
                    fh.update(chunk)
            entries.append((
                "f", p.relative_to(root).as_posix(),
                stat.S_IMODE(st.st_mode), fh.hexdigest(),
            ))
    h = hashlib.sha256()
    for kind, rel, mode, digest in sorted(entries):
        h.update(
            kind.encode("ascii") + b"\0" + rel.encode("utf-8") + b"\0"
            + f"{mode:o}".encode("ascii") + b"\0" + digest.encode("ascii") + b"\0"
        )
    return h.hexdigest()


def _playwright_resolvable() -> tuple[bool, str]:
    """Discover a Playwright entry point WITHOUT launching a browser.

    Returns (resolvable, reference). Resolvable means the Playwright tooling is
    present and the capability can be provisioned; it does NOT mean a browser
    has been empirically launched (that is the separate runtime proof).
    """
    exe = shutil.which("playwright")
    if exe:
        return True, str(Path(exe).expanduser().resolve(strict=False))
    try:
        proc = subprocess.run(
            [sys.executable, "-m", "playwright", "--version"],
            capture_output=True, text=True, check=False, timeout=10,
        )
        if proc.returncode == 0:
            return True, f"{sys.executable} -m playwright"
    except (OSError, subprocess.SubprocessError):
        pass
    return False, ""


def _browser_runtime_proof_status(
    name: str,
    *,
    evidence_dir: Path | None = None,
    expected_asset_root: Path | None = None,
) -> tuple[bool, str, dict[str, Any] | None]:
    """Verify current browser proof and return its exact bound identity."""
    p = browser_runtime_proof_path(name, evidence_dir)
    if p.is_symlink() or not p.is_file():
        return False, "no browser runtime proof commissioned", None
    try:
        st = p.stat()
    except OSError:
        return False, "browser runtime proof unreadable", None
    if not stat.S_ISREG(st.st_mode):
        return False, "browser runtime proof is not a regular file", None
    if hasattr(os, "getuid") and st.st_uid != os.getuid():
        return False, "browser runtime proof is not owned by supervisor user", None
    if st.st_mode & 0o077:
        return False, "browser runtime proof is not private", None
    try:
        doc = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False, "browser runtime proof unreadable", None
    if not isinstance(doc, dict) or doc.get("schema") != BROWSER_RUNTIME_PROOF_SCHEMA:
        return False, "browser runtime proof schema mismatch", None
    if doc.get("capability") != name or doc.get("ok") is not True:
        return False, "browser runtime proof does not attest this capability", None
    claimed = doc.get("proof_sha256")
    body = {k: v for k, v in doc.items() if k != "proof_sha256"}
    recomputed = hashlib.sha256(
        json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    ).hexdigest()
    if not claimed or recomputed != claimed:
        return False, "browser runtime proof digest mismatch", None
    if doc.get("platform_identity") != platform_identity():
        return False, "browser runtime proof stale: platform identity drift", None
    if doc.get("semantic_runtime_fingerprint") != semantic_runtime_fingerprint():
        return False, "browser runtime proof stale: runtime fingerprint drift", None

    claimed_client = doc.get("playwright_client_identity")
    if not isinstance(claimed_client, dict):
        return False, "browser runtime proof missing Playwright client identity", None
    try:
        current_client = playwright_client_identity()
    except CapabilityResolutionError as exc:
        return False, f"browser runtime proof stale: {exc}", None
    if claimed_client != current_client:
        return False, "browser runtime proof stale: Playwright client drift", None
    canonical_playwright_version = str(
        current_client.get("distribution_version") or ""
    )
    if str(doc.get("playwright_version") or "") != canonical_playwright_version:
        return False, "browser runtime proof stale: Playwright version identity mismatch", None

    asset_root_value = doc.get("browser_asset_root")
    if not isinstance(asset_root_value, str) or not asset_root_value:
        return False, "browser runtime proof missing asset root binding", None
    proof_raw = Path(asset_root_value).expanduser()
    if proof_raw.is_symlink():
        return False, "browser runtime proof asset root became a symlink", None
    try:
        proof_root = _browser_asset_root(proof_raw, require_exists=True)
    except CapabilityResolutionError as exc:
        return False, str(exc), None
    if expected_asset_root is not None:
        expected_raw = Path(expected_asset_root).expanduser()
        if expected_raw.is_symlink():
            return False, "resolved browser asset root is a symlink", None
        try:
            expected_root = _browser_asset_root(expected_raw, require_exists=True)
        except CapabilityResolutionError as exc:
            return False, str(exc), None
        if proof_root != expected_root:
            return False, "browser runtime proof binds a different asset root", None

    claimed_merkle = str(doc.get("browser_asset_merkle_sha256") or "")
    try:
        actual_merkle = browser_asset_merkle_sha256(proof_root)
    except (OSError, CapabilityResolutionError) as exc:
        return False, f"browser asset root unreadable: {exc}", None
    if claimed_merkle != actual_merkle:
        return False, "browser runtime proof stale: browser asset drift", None
    identity = {
        "proof_schema": BROWSER_RUNTIME_PROOF_SCHEMA,
        "browser_asset_root": str(proof_root),
        "browser_asset_merkle_sha256": actual_merkle,
        "browser_proof_sha256": str(claimed),
        "playwright_client_identity": current_client,
        "playwright_version": str(doc.get("playwright_version") or ""),
        "browser_version": str(doc.get("browser_version") or ""),
    }
    return True, "", identity


def _browser_runtime_proven(
    name: str,
    evidence_dir: Path | None = None,
    *,
    expected_asset_root: Path | None = None,
) -> tuple[bool, str]:
    proven, reason, _identity = _browser_runtime_proof_status(
        name,
        evidence_dir=evidence_dir,
        expected_asset_root=expected_asset_root,
    )
    return proven, reason

def write_browser_runtime_proof(
    name: str = "browser.playwright.chromium",
    *,
    asset_root: str,
    asset_merkle_sha256: str,
    playwright_client: dict[str, str],
    playwright_version: str = "",
    browser_version: str = "",
    evidence_dir: Path | None = None,
) -> dict[str, Any]:
    """Persist a canary-attested browser runtime proof (physical commissioning).

    Called by the real browser canary after it has empirically launched the
    browser FROM the exact shared asset root workers will receive. The proof
    is private (0600/0700), freshness-bound to the current platform/runtime
    fingerprint, and byte-bound to the exact browser asset tree; any drift
    stales it automatically. Not invoked by the source/CI suite.
    """
    from . import util as _util_mod
    root_raw = Path(asset_root).expanduser()
    if not root_raw.is_absolute() or root_raw.is_symlink():
        raise CapabilityResolutionError(
            f"browser asset root must be an absolute non-symlink directory: {asset_root}"
        )
    root = _browser_asset_root(root_raw, require_exists=True)
    actual_merkle = browser_asset_merkle_sha256(root)
    if asset_merkle_sha256 != actual_merkle:
        raise CapabilityResolutionError(
            "browser asset merkle digest does not match the current commissioned tree"
        )
    current_client = playwright_client_identity()
    if playwright_client != current_client:
        raise CapabilityResolutionError(
            "Playwright client identity changed between canary launch and proof write"
        )
    canonical_playwright_version = str(
        current_client.get("distribution_version") or ""
    )
    if str(playwright_version or "") != canonical_playwright_version:
        raise CapabilityResolutionError(
            "caller Playwright version does not match verified client distribution identity"
        )
    body = {
        "schema": BROWSER_RUNTIME_PROOF_SCHEMA,
        "capability": name,
        "ok": True,
        "browser_asset_root": str(root),
        "browser_asset_merkle_sha256": asset_merkle_sha256,
        "browser_cache_env": "PLAYWRIGHT_BROWSERS_PATH",
        "playwright_client_identity": current_client,
        "playwright_version": canonical_playwright_version,
        "browser_version": browser_version,
        "platform_identity": platform_identity(),
        "semantic_runtime_fingerprint": semantic_runtime_fingerprint(),
        "proven_at": _util_mod.utc_now_iso(),
    }
    body["proof_sha256"] = hashlib.sha256(
        json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    ).hexdigest()
    path = browser_runtime_proof_path(name, evidence_dir)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(body, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    return {**body, "proof_path": str(path)}


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
            elif definition.kind == "browser":
                # Truthful browser inventory with three explicit tiers:
                # PROVISIONABLE/RESOLVABLE (Playwright tooling present),
                # ASSETS-INSTALLED (the shared immutable asset root exists),
                # and EMPIRICALLY RUNTIME-PROVEN (a canary launched the exact
                # browser from the exact asset root under the current
                # platform/runtime). `available` reflects the strongest tier
                # only, so the inventory never claims a browser works before
                # it is proven.
                resolvable, resolved_ref = _playwright_resolvable()
                asset_root = default_browser_asset_dir()
                proven, proven_reason = _browser_runtime_proven(
                    name, expected_asset_root=asset_root
                )
                item.update({
                    "available": bool(proven),
                    "provisionable": bool(resolvable),
                    "resolvable": bool(resolvable),
                    "assets_installed": asset_root.is_dir() and not asset_root.is_symlink(),
                    "runtime_proven": bool(proven),
                    "provider": "project_runtime",
                    "browser_asset_root": str(asset_root),
                })
                if resolved_ref:
                    item["playwright_ref"] = resolved_ref
                if entry.get("trusted_asset_path"):
                    item["trusted_asset_identity"] = _trusted_asset_identity(
                        Path(str(entry["trusted_asset_path"]))
                    )
                if not proven:
                    item["reason"] = (
                        f"{proven_reason or 'browser not runtime-proven'}; "
                        "run the browser canary to commission"
                    )
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
                    "version", "executable_sha256", "cache_path", "cache_scope", "browser",
                )
                if item.get(k) is not None
            }
            for item in (resolution.get("resolved") or [])
            if isinstance(item, dict)
        ],
        "network_domains": list(resolution.get("network_domains") or []),
    }


def verify_resolution_integrity(resolution: dict[str, Any]) -> None:
    """Final pre-provider re-proof. Re-proves, immediately before the model
    process is created, that the authority-bearing bytes are EXACTLY what the
    resolution bound: the current Claude/platform runtime fingerprint, the host
    manifest identity, every resolved provider executable digest, trusted asset
    identity, and the commissioning evidence body digest (recomputed, not just
    compared by its embedded field). Any drift fails closed with zero model
    calls."""
    # Re-prove the CURRENT semantic runtime (byte-bound Claude executable +
    # platform). A swapped Claude binary or platform change after resolution is
    # refused here even if every other artifact is intact.
    current_fingerprint = semantic_runtime_fingerprint()
    if current_fingerprint != resolution.get("semantic_runtime_fingerprint"):
        raise CapabilityResolutionError(
            "semantic runtime (Claude binary/platform) changed after resolution"
        )
    path_value = resolution.get("host_manifest_path")
    _, _, current_manifest = _load_host_manifest(
        Path(str(path_value)) if path_value else None
    )
    if current_manifest != resolution.get("host_manifest_sha256"):
        raise CapabilityResolutionError("host capability manifest changed after resolution")
    for item in resolution.get("resolved") or []:
        if not isinstance(item, dict):
            continue
        if item.get("kind") == "browser":
            # A resolved browser must STILL be runtime-proven at pre-provider
            # time: re-prove freshness (current platform/runtime, exact asset
            # bytes). Resolution never certifies an unproven browser.
            browser_meta = item.get("browser") or {}
            if not browser_meta.get("runtime_proven"):
                raise CapabilityResolutionError(
                    f"browser capability resolved without runtime proof: {item.get('name')}"
                )
            expected_root = Path(str(browser_meta.get("browser_asset_root") or ""))
            proven_now, proof_reason, current_identity = _browser_runtime_proof_status(
                str(item.get("name") or ""),
                expected_asset_root=expected_root,
            )
            if not proven_now or current_identity is None:
                raise CapabilityResolutionError(
                    f"browser runtime proof no longer valid after resolution: {proof_reason}"
                )
            for key in (
                "browser_asset_root", "browser_asset_merkle_sha256",
                "browser_proof_sha256", "proof_schema",
            ):
                if current_identity.get(key) != browser_meta.get(key):
                    raise CapabilityResolutionError(
                        f"browser capability identity changed after resolution: {key}"
                    )
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
            # Recompute the evidence BODY digest (canonical JSON of every field
            # except evidence_sha256) rather than trusting the embedded field
            # alone; a body mutation that preserved the embedded field would
            # otherwise slip through.
            body = {k: v for k, v in doc.items() if k != "evidence_sha256"}
            recomputed = hashlib.sha256(
                json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
            ).hexdigest()
            if recomputed != evidence_sha:
                raise CapabilityResolutionError(
                    "commissioning evidence body digest mismatch after resolution"
                )


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


def resolution_receipt_path(
    canonical_repo: Path,
    run_id: str,
    role: str,
    attempt_id: str,
) -> Path:
    from . import state as _state_mod
    _state_mod.validate_run_id(run_id)
    if role not in {"builder", "reviewer"}:
        raise CapabilityResolutionError(f"invalid capability receipt role: {role!r}")
    if not str(attempt_id):
        raise CapabilityResolutionError("capability receipt requires attempt identity")
    safe_prefix = re.sub(r"[^A-Za-z0-9_.-]", "_", str(attempt_id))[:64]
    safe_attempt = safe_prefix + "-" + hashlib.sha256(str(attempt_id).encode()).hexdigest()[:16]
    root = canonical_repo.resolve(strict=False) / ".ownframework-loop" / run_id / "capabilities"
    return root / f"{safe_attempt}-{role}.json"


def read_resolution_receipt(
    canonical_repo: Path,
    run_id: str,
    role: str,
    attempt_id: str,
) -> dict[str, Any]:
    """Read one immutable launch receipt and prove it matches the run binding."""
    path = resolution_receipt_path(canonical_repo, run_id, role, attempt_id)
    if path.is_symlink() or not path.is_file():
        raise CapabilityResolutionError("capability receipt missing or symlinked")
    st = path.stat()
    if not stat.S_ISREG(st.st_mode):
        raise CapabilityResolutionError("capability receipt must be a regular file")
    if hasattr(os, "getuid") and st.st_uid != os.getuid():
        raise CapabilityResolutionError("capability receipt must be owned by supervisor user")
    if st.st_mode & 0o077:
        raise CapabilityResolutionError("capability receipt must be private")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise CapabilityResolutionError("capability receipt unreadable") from exc
    if not isinstance(payload, dict):
        raise CapabilityResolutionError("capability receipt must be an object")
    if payload.get("run_id") != run_id or payload.get("role") != role:
        raise CapabilityResolutionError("capability receipt run/role mismatch")
    if payload.get("attempt_id") != attempt_id:
        raise CapabilityResolutionError("capability receipt attempt mismatch")
    requested_profile = payload.get("requested_runner_profile")
    if not isinstance(requested_profile, dict):
        raise CapabilityResolutionError("capability receipt missing requested runner profile")
    from . import capability_binding as _binding_mod
    try:
        binding = _binding_mod._read(_binding_mod.binding_path(canonical_repo, run_id))
    except _binding_mod.CapabilityBindingError as exc:
        # A receipt whose run binding cannot be proven is an invalid receipt.
        # Callers contractually catch CapabilityResolutionError; letting the
        # binding error type (or a raw OSError from a vanished file) escape
        # would misclassify a sealed-run authority failure.
        raise CapabilityResolutionError(
            f"capability receipt cannot verify run binding: {exc}"
        ) from exc
    if payload.get("run_binding_sha256") != binding.get("binding_sha256"):
        raise CapabilityResolutionError("capability receipt run-binding digest mismatch")
    projection = _binding_mod.stable_projection(payload, requested_profile)
    if projection != binding.get("projection"):
        raise CapabilityResolutionError(
            "capability receipt resolution/profile does not match immutable run binding"
        )
    return payload


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
    path = resolution_receipt_path(canonical_repo, run_id, role, attempt_id)
    root = path.parent
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(root, 0o700)
    except OSError:
        pass
    payload = dict(resolution)
    payload["run_id"] = run_id
    payload["role"] = role
    payload["attempt_id"] = attempt_id
    if run_binding is not None:
        payload["run_binding_sha256"] = run_binding.get("binding_sha256")
    if runner_profile is not None:
        # Explicitly the REQUESTED profile; the effective model (when the
        # provider reveals it) is recorded on the semantic attempt ledger.
        payload["requested_runner_profile"] = {
            k: runner_profile.get(k)
            for k in (
                "name", "provider", "model", "effort", "identity_sha256",
                "effort_attestation",
            )
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
    "read_resolution_receipt",
    "resolution_receipt_path",
    "public_summary",
    "resolve_capabilities",
    "semantic_runtime_fingerprint",
    "validate_capability_names",
    "verify_resolution_integrity",
    "write_resolution_receipt",
]
