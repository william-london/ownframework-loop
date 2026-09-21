"""Hermetic subprocess environment for worktree-isolated execution.

Deterministic verifier and validator subprocesses must not pollute the
exact-SHA candidate or reviewer worktree with ephemeral cache state
(`__pycache__`, `.pytest_cache`, temp files, XDG cache state). The
deterministic finalizer rejects any reviewer worktree that does not describe
the exact reviewed candidate.

The fix is NOT to weaken the dirty check. The fix is to keep ephemeral
runtime state OUT of the worktree in the first place by setting well-known
environment variables to a supervisor-owned directory outside the worktree.

HOME / PATH / Claude authentication variables are intentionally NOT
overridden so that normal local tool discovery and model authentication
continue to work.
"""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
from typing import Any


SCHEMA = "ownframework-loop-runtime-env/v1"

CAPABILITY_ENV_ALLOWED_KEYS = frozenset({
    "UV_CACHE_DIR",
    "PIP_CACHE_DIR",
    "npm_config_cache",
    "npm_config_store_dir",
    "PLAYWRIGHT_BROWSERS_PATH",
    "PLAYWRIGHT_SKIP_BROWSER_GC",
})

HOST_IPC_ENV_KEYS = frozenset({
    "DOCKER_HOST",
    "DOCKER_CONTEXT",
    "DOCKER_CONFIG",
    "CONTAINER_HOST",
    "PODMAN_HOST",
    "KUBECONFIG",
    "KUBERNETES_MASTER",
    "SSH_AUTH_SOCK",
    "GPG_AGENT_INFO",
})


def _ensure_private_dir(path: Path) -> Path:
    """Create/repair runtime cache directories as 0700 on POSIX."""
    p = Path(path).expanduser().resolve(strict=False)
    p.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(p, 0o700)
    except OSError:
        pass
    return p



def default_runtime_cache_root() -> Path:
    root = os.environ.get("XDG_STATE_HOME", "").strip()
    base = Path(root).expanduser() if root else Path.home() / ".local" / "state"
    # Normalize macOS alias roots such as /var -> /private/var at the pure
    # derivation boundary so path identity never depends on whether a caller
    # has already created/resolved the directory.
    return (base / "ownframework-loop" / "runtime-cache").resolve(strict=False)


def default_repo_tool_cache_root() -> Path:
    """Durable repository-scoped tool cache root.

    This is intentionally distinct from the per-pass runtime cache.  Untrusted
    semantic workers never receive a cross-repository writable cache: durable
    writes are scoped by canonical repository identity so one client project
    cannot poison another project's future tool state.
    """
    explicit = os.environ.get("OFLOOP_TOOL_CACHE_ROOT", "").strip()
    if explicit:
        return Path(explicit).expanduser().resolve(strict=False)
    return (default_runtime_cache_root().parent / "tool-cache").resolve(strict=False)


def repo_tool_cache_path(canonical_repo: Path) -> Path:
    return (default_repo_tool_cache_root() / _repo_key(canonical_repo)).resolve(strict=False)


def repo_tool_cache_dir(canonical_repo: Path) -> Path:
    root = default_repo_tool_cache_root()
    _ensure_private_dir(root)
    return _ensure_private_dir(repo_tool_cache_path(canonical_repo))


def _slug(s: str) -> str:
    return "".join(ch for ch in str(s) if ch.isalnum() or ch in "-_.")[:64]


def _repo_key(canonical_repo: Path) -> str:
    resolved_path = Path(canonical_repo).expanduser().resolve(strict=False)
    identity = resolved_path
    try:
        from . import git_checks
        common = git_checks.git_common_dir(resolved_path)
    except Exception:
        common = None
    if common is not None:
        identity = common.resolve(strict=False)
    return hashlib.sha256(str(identity).encode("utf-8")).hexdigest()[:24]


def runtime_cache_path(
    canonical_repo: Path,
    run_id: str,
    role: str,
) -> Path:
    """Pure path derivation for one run/role cache (does not create it)."""
    safe_role = "builder" if role not in ("builder", "reviewer", "validation") else role
    return (
        default_runtime_cache_root()
        / _repo_key(canonical_repo)
        / _slug(run_id)
        / safe_role
    ).resolve(strict=False)


def runtime_cache_dir(
    canonical_repo: Path,
    run_id: str,
    role: str,
) -> Path:
    """Per (repo, run, role) deterministic private externalized cache."""
    cache_root = default_runtime_cache_root()
    _ensure_private_dir(cache_root.parent)
    _ensure_private_dir(cache_root)
    return _ensure_private_dir(runtime_cache_path(canonical_repo, run_id, role))


def hermetic_subprocess_env(
    canonical_repo: Path,
    run_id: str,
    role: str,
    *,
    base_env: dict[str, str] | None = None,
    capability_environment: dict[str, str] | None = None,
    path_prepend: list[str] | None = None,
) -> dict[str, str]:
    """Return env for a subprocess that must not pollute the worktree.

    The returned dict is meant to be passed as ``env=`` to
    ``subprocess.run`` / ``subprocess.Popen`` (which replaces the inherited
    environment). ``HOME`` / ``PATH`` / authentication variables are
    preserved from ``base_env`` (defaults to current process ``os.environ``).

    Python bytecode / cache is redirected to ``PYTHONPYCACHEPREFIX`` and
    further suppressed by ``PYTHONDONTWRITEBYTECODE=1``.

    pytest cache state is disabled via ``PYTEST_ADDOPTS=-p no:cacheprovider``
    and redirected via ``--override-ini=cache_dir=...`` so even if a user
    forgot to disable it, the cache lands outside the candidate tree.

    TMPDIR / XDG_CACHE_HOME point to a per-(repo, run, role) directory so
    that general ephemeral state also stays outside the worktree.
    """
    cache_dir = runtime_cache_dir(canonical_repo, run_id, role)
    pycache = cache_dir / "pycache"
    tmp = cache_dir / "tmp"
    xdg = cache_dir / "xdg-cache"
    pytest_cache = cache_dir / "pytest-cache"
    for d in (pycache, tmp, xdg, pytest_cache):
        _ensure_private_dir(d)

    env = dict(base_env) if base_env is not None else dict(os.environ)

    # Host IPC/daemon selectors are authority, not harmless developer
    # convenience. Privileged services must enter through a typed broker.
    for key in HOST_IPC_ENV_KEYS:
        env.pop(key, None)

    # Capability resolution is core-owned.  Only a tiny non-secret environment
    # surface may be injected here; host manifests cannot smuggle arbitrary
    # credentials or loader/runtime overrides into semantic Bash.
    for key, value in (capability_environment or {}).items():
        if key not in CAPABILITY_ENV_ALLOWED_KEYS:
            raise ValueError(f"unsupported capability environment key: {key}")
        if not isinstance(value, str) or not value:
            raise ValueError(f"invalid capability environment value for {key}")
        env[key] = value
    prepend = [str(Path(p).expanduser().resolve(strict=False)) for p in (path_prepend or [])]
    if prepend:
        existing_path = env.get("PATH", "")
        env["PATH"] = os.pathsep.join(prepend + ([existing_path] if existing_path else []))
    # Ensure the OwnFramework Loop library dir is on PYTHONPATH so our
    # pytest plugin (of_disable_cache) can be imported when the env is
    # passed to a subprocess whose parent did not already include it
    # (e.g. launchd-managed services, sandboxed shells).
    lib_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    existing_pp = env.get("PYTHONPATH", "").strip()
    if existing_pp:
        if lib_dir not in existing_pp.split(os.pathsep):
            env["PYTHONPATH"] = lib_dir + os.pathsep + existing_pp
    else:
        env["PYTHONPATH"] = lib_dir
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env["PYTHONPYCACHEPREFIX"] = str(pycache)
    env["TMPDIR"] = str(tmp)
    env["TMP"] = str(tmp)  # Windows-style fallback (no-op on POSIX)
    env["TEMP"] = str(tmp)  # Windows-style fallback (no-op on POSIX)
    env["XDG_CACHE_HOME"] = str(xdg)
    # Belt-and-braces pytest cache protection:
    # - -p no:cacheprovider disables the cacheplugin via PYTEST_ADDOPTS
    # - --override-ini=cache_dir=... redirects the cache directory if plugin still loads
    # - PYTEST_PLUGINS auto-loads our of_disable_cache plugin that unregisters
    #   the cacheprovider entirely (most robust layer).
    # IMPORTANT: do NOT set --rootdir or --confcutdir; that would redirect
    # pytest's rootdir away from the caller's cwd, breaking test collection
    # and import resolution for the caller's project layout.
    existing_addopts = env.get("PYTEST_ADDOPTS", "").strip()
    guard_addopts = (
        f"-p no:cacheprovider "
        f"--override-ini=cache_dir={pytest_cache}"
    )
    env["PYTEST_ADDOPTS"] = (
        f"{existing_addopts} {guard_addopts}".strip()
        if existing_addopts else guard_addopts
    )
    existing_plugins = env.get("PYTEST_PLUGINS", "").strip()
    of_plugin = "ownframework_loop._pytest_plugins.of_disable_cache"
    if existing_plugins:
        if of_plugin not in existing_plugins.split(","):
            env["PYTEST_PLUGINS"] = existing_plugins + "," + of_plugin
    else:
        env["PYTEST_PLUGINS"] = of_plugin

    # v0.6.1 execution-context markers. The Loop supervisor is the
    # PROVENANCE SOURCE for semantic-worker context. Setting these env
    # vars here means every bash command spawned inside the Claude Code
    # worker (including incidental git/helper invocations) carries the
    # explicit role contract so the textual bash guard can enforce it
    # without falling back to path heuristics. role must be
    # "builder" or "reviewer"; for non-semantic roles this is skipped.
    if role in ("builder", "reviewer"):
        from . import role_context as role_context_mod
        try:
            ctx = role_context_mod.build_context(
                run_id=run_id, role=role, canonical_repo=canonical_repo,
            )
            role_context_mod.apply_context_to_env(env, ctx)
        except role_context_mod.RoleContextError:
            # A malformed role/run_id/canonical_repo MUST NOT silently
            # degrade to "no context" because that would lift the
            # semantic-worker restrictions. Re-raise so the supervisor
            # fails the work order with a clear refusal.
            raise

    return env


def commissioned_validation_env(
    canonical_repo: Path,
    run_id: str,
    packet: dict[str, Any],
) -> dict[str, str]:
    """Build the deterministic validation environment from the sealed run binding.

    Semantic workers receive a capability resolution at launch time.  Required
    validation used to receive only the supervisor's ambient environment,
    which made BUILD and REVIEW sensitive to PATH and cache differences.  A
    validator instead re-resolves exactly the capability names frozen in the
    run binding, verifies the current host resolution against that binding,
    and uses one role-neutral validation cache for both finalizers.
    """
    from . import capability_binding, capabilities, runner_profiles

    binding = capability_binding._read(
        capability_binding.binding_path(canonical_repo, run_id)
    )
    projection = binding.get("projection") or {}
    requested = projection.get("requested")
    requested_profile = projection.get("requested_runner_profile") or {}
    if not isinstance(requested, list):
        raise capability_binding.CapabilityBindingError(
            "sealed capability binding has no requested capability list"
        )
    if not isinstance(requested_profile, dict):
        raise capability_binding.CapabilityBindingError(
            "sealed capability binding has no requested runner profile"
        )

    profile = runner_profiles.resolve_profile(
        str(requested_profile.get("name") or ""),
        provider=str(requested_profile.get("provider") or ""),
    )
    runner_profiles.verify_profile_integrity(profile)
    attestation = runner_profiles.verify_effort_attestation(profile)
    bound_attestation = requested_profile.get("effort_attestation")
    if attestation != bound_attestation:
        raise runner_profiles.RunnerProfileError(
            "sealed runner effort attestation changed after run binding"
        )
    if profile.get("identity_sha256") != requested_profile.get("identity_sha256"):
        raise runner_profiles.RunnerProfileError(
            "sealed runner profile identity changed after run binding"
        )
    if attestation is not None:
        profile = dict(profile)
        profile["effort_attestation"] = attestation

    resolution = capabilities.resolve_capabilities(
        [str(item) for item in requested],
        canonical_repo=canonical_repo,
        role="reviewer",
        repo_cache_root=repo_tool_cache_dir(canonical_repo),
        ephemeral_cache_root=(
            runtime_cache_dir(canonical_repo, run_id, "validation")
            / "capability-cache"
        ),
        packet_network_allowlist=[
            str(item) for item in (packet.get("network_read_allowlist") or [])
        ],
    )
    capabilities.verify_resolution_integrity(resolution)
    capability_binding.verify_run_binding(
        canonical_repo, run_id, resolution, profile
    )
    return hermetic_subprocess_env(
        canonical_repo,
        run_id,
        "validation",
        capability_environment=dict(resolution.get("environment") or {}),
        path_prepend=list(resolution.get("path_prepend") or []),
    )


def research_evidence_root() -> Path:
    """Operator-owned research evidence root.

    Lives one level DEEPER than the supervisor state root contents so the
    resolution layer can decide independently what to put in the worker's
    allowRead list. This is the only writer entry point for the
    ``research.public`` capability.
    """
    explicit = os.environ.get("OFLOOP_RESEARCH_EVIDENCE_ROOT", "").strip()
    if explicit:
        return Path(explicit).expanduser().resolve(strict=False)
    base = Path("~/.local/state").expanduser() / "ownframework-loop" / "research"
    return base.resolve(strict=False)


def research_evidence_dir(run_id: str | None = None) -> Path:
    """Per-run research evidence directory.

    Returns the operator-owned root when ``run_id`` is None. When ``run_id``
    is supplied, the run_id is validated as a strict identity (it must match
    OwnFramework Loop's own ``validate_run_id`` so the helper cannot be
    coerced into path traversal) and the per-run leaf is appended.

    Defense in depth: the resolved path is normalized and explicitly
    asserted to remain inside ``research_evidence_root()`` before being
    returned. Callers that deviate are refused.
    """
    base = research_evidence_root()
    if run_id is None:
        return base
    # Reuse the durable identity validation the rest of Loop applies so the
    # helper never builds a path under any non-Loop-controlled identifier.
    from . import state as _state_mod
    _state_mod.validate_run_id(run_id)
    candidate = (base / run_id).resolve(strict=False)
    try:
        candidate.relative_to(base.resolve(strict=False))
    except ValueError as exc:
        raise ValueError(
            f"research_evidence_dir escaped its root: {candidate!r}"
        ) from exc
    if os.path.sep + "" == "/":
        # POSIX: refuse any control char in the path (paranoia after
        # validate_run_id already passed).
        if any(ord(c) < 0x20 or ord(c) == 0x7f for c in str(candidate)):
            raise ValueError(
                f"research_evidence_dir contains control characters: {candidate!r}"
            )
    return candidate


__all__ = [
    "SCHEMA",
    "CAPABILITY_ENV_ALLOWED_KEYS",
    "HOST_IPC_ENV_KEYS",
    "default_repo_tool_cache_root",
    "repo_tool_cache_dir",
    "repo_tool_cache_path",
    "default_runtime_cache_root",
    "hermetic_subprocess_env",
    "runtime_cache_dir",
    "runtime_cache_path",
    "commissioned_validation_env",
    "research_evidence_root",
    "research_evidence_dir",
]
