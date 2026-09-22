"""Deterministic candidate-bound project environment for required validations.

Background
==========

The packet's ``required_validation`` commands may legitimately use
``uv run`` (or any uv-mediated project entry point) to execute project
code against the candidate's declared dependencies. ``uv run`` defaults to
auto-syncing the project environment into ``.venv`` next to the
candidate's ``uv.lock`` — i.e. inside the exact-SHA worktree the
deterministic validator just sealed.

That default breaks several invariants:

1. The builder/reviewer worktrees must remain immutable after sealing;
   an in-worktree ``.venv`` is a tracked-or-ignored-mutable artifact that
   the post-validation cleanliness check must special-case. Reviewer
   immutability is the most important: a polluted reviewer worktree
   invalidates the reviewer's verdict.

2. The builder's ``.venv`` is not authoritative for the reviewer. The
   reviewer is supposed to validate against an environment it
   independently produced from the same ``uv.lock``. Otherwise the
   reviewer is testing the builder's success rather than the candidate.

3. ``uv sync`` failures (registry outages, hash drift, local mirror
   unreachability) must not consume semantic repair rounds. Today a sync
   failure yields a non-zero validation exit and falls into
   ``validation_failed`` → ``CHANGES_REQUESTED`` → the next repair round
   burns an entitlement on something the candidate author cannot fix.

Design
======

The deterministic validator owns a single project environment per
(candidate, project lock, project metadata) triple. The environment:

  - Lives under the supervisor-owned runtime cache, OUTSIDE the builder
    and reviewer worktrees. Builder and reviewer worktrees can never
    observe a ``.venv`` because the env is provisioned in a different
    filesystem location entirely.
  - Is identified by ``env_id = sha256(candidate_sha ||
    uv_lock_sha256 || project_metadata_sha256)``. A different lock,
    metadata, or candidate produces a different env identity.
  - Is provisioned ONCE per env_id by running ``uv sync --project
    <candidate_worktree> --python-preference only-system ...`` into the
    env_dir. Subsequent runs of the SAME env_id are no-ops.
  - Subprocesses that need the env (validation commands invoking
    ``uv run``, or any subprocess that should auto-activate the env)
    receive ``UV_PROJECT_ENVIRONMENT=<env_dir>`` and
    ``VIRTUAL_ENV=<env_dir>`` in their hermetic subprocess environment.
  - A validation that needs the env but the env cannot be provisioned
    is reported as ``infra_failure`` (terminal BLOCKED) rather than
    ``validation_failed`` (repairable). Infra failures NEVER consume a
    repair round.

The module does NOT widen any worker's authority. The env_dir is not in
any worker's allowRead/allowWrite; it is the validator's exclusive
runtime artifact.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import time
from pathlib import Path
from typing import Any

from . import runtime_env, util


SCHEMA = "ownframework-loop-validation-environment/v1"


class ValidationEnvironmentError(RuntimeError):
    """A candidate-bound project environment could not be provisioned."""


# Maximum time to wait for uv sync to finish. Network registries can be
# slow; this is intentionally generous. The packet's
# ``required_runtime_proof.max_runtime_seconds`` is the per-command
# budget and remains the authoritative per-validation timeout — this
# bound only guards the provisioning step from wedging the whole
# finalizer indefinitely when uv itself hangs on a hostile network.
DEFAULT_PROVISION_TIMEOUT_SECONDS = 600


_UV_COMMAND_RE = re.compile(
    r"\buv\s+(?:run|sync|exec|test|python|lock)\b"
)


def _slug(s: str) -> str:
    return "".join(ch for ch in str(s) if ch.isalnum() or ch in "-_.")[:96]


def _sha256_file(path: Path) -> str | None:
    if not path.is_file():
        return None
    try:
        h = hashlib.sha256()
        with path.open("rb") as fh:
            for chunk in iter(lambda: fh.read(1024 * 1024), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return None


def _project_lock_identity(candidate_worktree: Path) -> str | None:
    """Return the sha256 of the candidate's uv.lock, or None if absent.

    The lock file binds the project's resolved dependency set. A different
    lock (different version, different resolution, different transitive
    closure) MUST produce a different env identity so two unrelated
    candidates never accidentally share a cached environment.
    """
    lock = candidate_worktree / "uv.lock"
    return _sha256_file(lock)


def _project_metadata_identity(candidate_worktree: Path) -> str:
    """Return the sha256 of the candidate's pyproject.toml.

    The pyproject.toml binds the project's declared build system /
    project metadata that ``uv sync`` honors (project name, version,
    requires-python, dependencies). It is intentionally distinct from
    the lock identity so a lock-vs-metadata drift changes the env
    identity.
    """
    pyproject = candidate_worktree / "pyproject.toml"
    digest = _sha256_file(pyproject)
    if digest is None:
        # No pyproject.toml means there is no uv project to sync. We
        # still want a stable identity for the "no project" case so
        # caching remains deterministic.
        digest = "no-pyproject"
    return digest


def candidate_bound_environment_id(
    candidate_sha: str,
    candidate_worktree: Path,
) -> str:
    """Derive the deterministic env identity for one candidate.

    Two candidates that share the same lock and metadata but differ in
    git history produce different ids. Two checks of the same candidate
    produce the same id. A re-validation of the same candidate after
    ``uv.lock`` changes produces a different id (and a fresh env).
    """
    if not candidate_sha or not isinstance(candidate_sha, str):
        raise ValidationEnvironmentError("candidate_sha is required")
    lock_id = _project_lock_identity(candidate_worktree)
    meta_id = _project_metadata_identity(candidate_worktree)
    material = "\0".join([
        str(candidate_sha),
        str(lock_id or ""),
        str(meta_id),
    ]).encode("utf-8")
    return hashlib.sha256(material).hexdigest()


def project_environment_dir(
    canonical_repo: Path,
    run_id: str,
    role: str,
    env_id: str,
) -> Path:
    """Pure derivation of the per-(repo, run, role, env_id) env path.

    The path lives under the supervisor-owned runtime cache, far outside
    the builder / reviewer worktrees. ``role`` distinguishes the
    builder-side validator's env from the reviewer-side validator's env
    so neither sees the other's intermediate state and the immutable
    reviewer worktree can never accidentally observe a freshly-synced
    env being constructed.
    """
    safe_role = "validation-builder" if role not in {
        "builder", "reviewer", "validation", "validation-builder", "validation-reviewer",
    } else role
    if role in ("builder",):
        safe_role = "validation-builder"
    elif role in ("reviewer",):
        safe_role = "validation-reviewer"
    return (
        runtime_env.runtime_cache_dir(canonical_repo, run_id, "validation")
        / "project-env"
        / safe_role
        / _slug(env_id)
    ).resolve(strict=False)


def project_environment_status(env_dir: Path) -> dict[str, Any]:
    """Snapshot the provisioning state of one env directory.

    Pure read — never invokes uv, never touches the network. Callers
    that want to act on this must call :func:`provision_project_environment`
    explicitly.
    """
    raw = Path(env_dir).expanduser().resolve(strict=False)
    exists = raw.is_dir()
    marker = raw / ".ofloop-env-provisioned.json"
    state: dict[str, Any] = {
        "path": str(raw),
        "exists": exists,
        "provisioned": False,
        "identity": "",
        "candidate_sha": "",
        "lock_sha256": "",
        "metadata_sha256": "",
        "provisioned_at": "",
        "uv_executable": "",
        "uv_version": "",
    }
    if not exists:
        return state
    if marker.is_symlink() or not marker.is_file():
        return state
    try:
        st = marker.stat()
    except OSError:
        return state
    if not stat.S_ISREG(st.st_mode):
        return state
    if hasattr(os, "getuid") and st.st_uid != os.getuid():
        return state
    if stat.S_IMODE(st.st_mode) & 0o077:
        return state
    try:
        doc = json.loads(marker.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return state
    if not isinstance(doc, dict) or doc.get("schema") != SCHEMA:
        return state
    # The body is what the file's contents are; the embedded
    # ``identity`` is the canonical env_id and must match what the file
    # digest produces. Recompute and compare.
    body = {k: v for k, v in doc.items() if k != "marker_sha256"}
    expected_marker = hashlib.sha256(
        json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    ).hexdigest()
    if expected_marker != doc.get("marker_sha256"):
        return state
    state.update({
        "provisioned": True,
        "identity": str(doc.get("identity") or ""),
        "candidate_sha": str(doc.get("candidate_sha") or ""),
        "lock_sha256": str(doc.get("lock_sha256") or ""),
        "metadata_sha256": str(doc.get("metadata_sha256") or ""),
        "uv_executable": str(doc.get("uv_executable") or ""),
        "uv_version": str(doc.get("uv_version") or ""),
        "provisioned_at": str(doc.get("provisioned_at") or ""),
    })
    return state


def _resolve_uv_executable() -> str:
    """Return the absolute path of the uv executable on PATH.

    The deterministic validator runs ``uv sync`` as a subprocess.run
    directly (not under any worker Bash sandbox). The executable is
    resolved by environment-and-PATH lookup, fail-closed if missing.
    """
    uv_path = shutil.which("uv")
    if not uv_path:
        raise ValidationEnvironmentError(
            "uv executable not on PATH; cannot provision candidate-bound project environment"
        )
    resolved = Path(uv_path).expanduser().resolve(strict=False)
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        raise ValidationEnvironmentError(
            f"uv executable is not a runnable file: {resolved}"
        )
    return str(resolved)


def _uv_version(uv_executable: str) -> str:
    try:
        proc = subprocess.run(
            [uv_executable, "--version"],
            capture_output=True, text=True, check=False, timeout=5,
        )
        text = (proc.stdout or proc.stderr or "").strip()
        return text.splitlines()[0][:512] if text else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def _uuid_name() -> str:
    import uuid
    return uuid.uuid4().hex


def _publish_marker(env_dir: Path, body: dict[str, Any]) -> None:
    body = dict(body)
    body["marker_sha256"] = hashlib.sha256(
        json.dumps(
            {k: v for k, v in body.items() if k != "marker_sha256"},
            sort_keys=True, separators=(",", ":"), ensure_ascii=True,
        ).encode("utf-8")
    ).hexdigest()
    encoded = json.dumps(body, indent=2, sort_keys=True) + "\n"
    tmp = env_dir / f".{_uuid_name()}.marker.tmp"
    tmp.write_text(encoded, encoding="utf-8")
    try:
        os.chmod(tmp, 0o600)
    except OSError:
        pass
    os.replace(tmp, env_dir / ".ofloop-env-provisioned.json")


def provision_project_environment(
    *,
    canonical_repo: Path,
    run_id: str,
    role: str,
    candidate_sha: str,
    candidate_worktree: Path,
    timeout_seconds: int = DEFAULT_PROVISION_TIMEOUT_SECONDS,
) -> dict[str, Any]:
    """Provision the candidate-bound project environment.

    Idempotent: a second call with the same env_id returns the cached
    ``status`` without invoking uv. A different env_id (different
    candidate / lock / metadata) creates a fresh env_dir and provisions
    it from scratch.

    Raises ``ValidationEnvironmentError`` on any infra-level failure
    (uv missing, sync timeout, sync non-zero exit, marker unwritable).
    Such failures are caller-classified as ``infra_failure`` and never
    consume semantic repair rounds.
    """
    canonical_repo = Path(canonical_repo).resolve(strict=False)
    candidate_worktree = Path(candidate_worktree).resolve(strict=False)
    if not candidate_worktree.is_dir():
        raise ValidationEnvironmentError(
            f"candidate worktree is not a directory: {candidate_worktree}"
        )
    env_id = candidate_bound_environment_id(candidate_sha, candidate_worktree)
    env_dir = project_environment_dir(canonical_repo, run_id, role, env_id)

    lock_id = _project_lock_identity(candidate_worktree) or ""
    meta_id = _project_metadata_identity(candidate_worktree)
    pyproject = candidate_worktree / "pyproject.toml"
    has_project = pyproject.is_file()

    # No uv project in this candidate. There is nothing to sync, but we
    # still publish a marker so the rest of the system knows the env
    # contract was honored. Subsequent ``uv run`` invocations inside
    # this run will fail naturally (no project) and that failure is
    # reported as ``validation_failed``, not ``infra_failure``.
    if not has_project:
        env_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        try:
            os.chmod(env_dir, 0o700)
        except OSError:
            pass
        _publish_marker(env_dir, {
            "schema": SCHEMA,
            "identity": env_id,
            "candidate_sha": candidate_sha,
            "lock_sha256": lock_id,
            "metadata_sha256": meta_id,
            "uv_executable": "",
            "uv_version": "",
            "provisioned_at": util.utc_now_iso(),
            "no_project": True,
        })
        return project_environment_status(env_dir)

    existing = project_environment_status(env_dir)
    if existing["provisioned"] and existing["identity"] == env_id:
        return existing

    # Clean any partial / stale provisioning state before re-provisioning.
    if env_dir.is_symlink():
        raise ValidationEnvironmentError(
            f"project env path must not be a symlink: {env_dir}"
        )
    if env_dir.exists():
        # Keep the path private; ``uv sync`` refuses to write into a
        # non-empty target unless explicitly cleared.
        shutil.rmtree(env_dir, ignore_errors=True)
    env_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(env_dir, 0o700)
    except OSError:
        pass

    uv_executable = _resolve_uv_executable()
    uv_version = _uv_version(uv_executable)
    sync_env = runtime_env.hermetic_subprocess_env(
        canonical_repo, run_id, "validation",
    )
    # uv must honor the candidate-bound env path. UV_PROJECT_ENVIRONMENT
    # is the documented knob that overrides the default ``.venv``
    # location; pairing it with ``UV_NO_SYNC`` prevents re-sync during
    # ``uv run`` once we have already provisioned.
    sync_env["UV_PROJECT_ENVIRONMENT"] = str(env_dir)
    sync_env["VIRTUAL_ENV"] = str(env_dir)

    cmd = [
        uv_executable, "sync",
        "--project", str(candidate_worktree),
        # Pin to system Python so the env is reproducible across the
        # validator's own host and any future worker reusing it.
        "--python-preference", "only-system",
        # Refuse silent registry drift. ``--locked`` makes uv fail
        # closed when ``uv.lock`` would have to mutate, which is the
        # exact behavior a candidate-bound env requires.
        "--locked",
    ]

    stdout_path = env_dir / ".provision.stdout"
    stderr_path = env_dir / ".provision.stderr"
    start = time.monotonic()
    timed_out = False
    with stdout_path.open("wb") as stdout_fh, stderr_path.open("wb") as stderr_fh:
        try:
            os.chmod(stdout_path, 0o600)
        except OSError:
            pass
        try:
            os.chmod(stderr_path, 0o600)
        except OSError:
            pass
        try:
            proc = subprocess.run(
                cmd,
                cwd=str(candidate_worktree),
                env=sync_env,
                stdout=stdout_fh,
                stderr=stderr_fh,
                check=False,
                timeout=timeout_seconds,
            )
            returncode = int(proc.returncode)
        except subprocess.TimeoutExpired:
            timed_out = True
            returncode = 124
    duration = time.monotonic() - start
    stdout_bytes = stdout_path.read_bytes() if stdout_path.exists() else b""
    stderr_bytes = stderr_path.read_bytes() if stderr_path.exists() else b""
    excerpt = (stderr_bytes or stdout_bytes).decode("utf-8", errors="replace")
    excerpt = excerpt[:4096]

    if timed_out:
        raise ValidationEnvironmentError(
            f"uv sync timed out after {timeout_seconds}s for env_id={env_id[:12]}: "
            f"{excerpt}"
        )
    if returncode != 0:
        raise ValidationEnvironmentError(
            f"uv sync failed rc={returncode} for env_id={env_id[:12]}: {excerpt}"
        )

    _publish_marker(env_dir, {
        "schema": SCHEMA,
        "identity": env_id,
        "candidate_sha": candidate_sha,
        "lock_sha256": lock_id,
        "metadata_sha256": meta_id,
        "uv_executable": uv_executable,
        "uv_version": uv_version,
        "provisioned_at": util.utc_now_iso(),
        "duration_seconds": float(duration),
    })
    return project_environment_status(env_dir)


def command_uses_uv_run(command: str) -> bool:
    """Return True when the command string invokes a uv subcommand that
    requires the project environment to exist.

    Used by the validator to decide whether the command needs the
    candidate-bound env to be provisioned BEFORE it runs. ``uv run`` is
    the canonical case (``uv run python -c '...'``); ``uv exec``,
    ``uv test``, and ``uv python`` are all equivalent.
    """
    return bool(_UV_COMMAND_RE.search(command or ""))


def env_overrides(env_dir: Path) -> dict[str, str]:
    """Return the hermetic subprocess environment keys required to bind
    the project env into a child process.

    These are the ONLY env vars the validation_executor should add on
    top of the standard hermetic subprocess env to make the candidate-
    bound env take effect. Workers never see this; only the
    deterministic validator's spawned subprocess does.
    """
    env_dir = Path(env_dir).expanduser().resolve(strict=False)
    return {
        "UV_PROJECT_ENVIRONMENT": str(env_dir),
        "VIRTUAL_ENV": str(env_dir),
    }


__all__ = [
    "DEFAULT_PROVISION_TIMEOUT_SECONDS",
    "SCHEMA",
    "ValidationEnvironmentError",
    "candidate_bound_environment_id",
    "command_uses_uv_run",
    "env_overrides",
    "project_environment_dir",
    "project_environment_status",
    "provision_project_environment",
]
