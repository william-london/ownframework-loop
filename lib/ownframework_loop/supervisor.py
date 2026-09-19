"""Durable, vendor-thin supervisor for OwnFramework Loop.

Protocol truth remains in the repository's OwnFramework Loop artifacts. SQLite
stores only machine operations: queue state, retries, backoff, runner identity,
and cost/runtime observations.

The supervisor consumes typed work orders from dispatch.py. It never decides
engineering transitions itself.
"""
from __future__ import annotations
import sys

from concurrent.futures import Future, ThreadPoolExecutor
import hashlib
import json
import math
import re
import os
import shlex
import signal
import sqlite3
import shutil
import stat
import subprocess
import threading
import time
import uuid
from contextlib import contextmanager
from dataclasses import dataclass
from functools import wraps
from pathlib import Path
from typing import Any

from . import (
    approval as approval_mod,
    branch_resolver as branch_resolver_mod,
    build_agent as build_agent_mod,
    capabilities as capabilities_mod,
    capability_binding as capability_binding_mod,
    continuation_authority as continuation_authority_mod,
    dispatch as dispatch_mod,
    dispatch_hold as dispatch_hold_mod,
    git_checks,
    packet as packet_mod,
    program as program_mod,
    protected_recovery,
    runner_profiles as runner_profiles_mod,
    runtime_env,
    state as state_mod,
    transitions,
    util,
    runtime_identity,
)
from .locking import flock_exclusive
from . import supervisor_db as _db_mod
from . import supervisor_holds as _holds_mod
from . import supervisor_runner_io as _runner_io_mod
from . import supervisor_identity as _identity_mod
from . import supervisor_readmodel as _readmodel_mod
from . import supervisor_recovery as _recovery_mod
from . import supervisor_attempts as _attempts_mod
from . import supervisor_claims as _claims_mod

SCHEMA = _db_mod.SCHEMA
DISPATCH_HOLD_KIND = _holds_mod.DISPATCH_HOLD_KIND
DISPATCH_HOLD_STATES = _holds_mod.DISPATCH_HOLD_STATES
CLAUDE_PROVIDER_ENVELOPE_MAX_BYTES = _runner_io_mod.CLAUDE_PROVIDER_ENVELOPE_MAX_BYTES
RUNNER_DIAGNOSTIC_MAX_CHARS = _runner_io_mod.RUNNER_DIAGNOSTIC_MAX_CHARS
# Per-pass runaway fuse fallback. A semantic worker that neither declared a
# packet budget nor got an operational narrowing is bounded to one hour so a
# stuck worker cannot hold the single global execution slot indefinitely.
# Long PROGRAM passes are funded deliberately through
# risk_budget.max_pass_runtime_seconds (packet authority; up to 28800 for v3)
# rather than by widening the default fuse.
DEFAULT_SEMANTIC_TIMEOUT_SECONDS = 3600
# Commissioned semantic passes are sealed local workers.  Builder and reviewer
# intentionally get different first-party Claude capability sets so reviewer
# source immutability is structural, not merely a prompt/hook convention.
CLAUDE_BUILDER_TOOLS = "Read,Edit,Write,NotebookEdit,Bash,Glob,Grep"
CLAUDE_REVIEWER_TOOLS = "Read,Bash,Glob,Grep"

# A worker child can finish before its execution lane has durably accounted the
# result and finalized the engineering artifact. During that handoff window
# the child PID is necessarily dead, but the current supervisor still owns the
# job. Keep this narrow process-local fence so another lane in this same
# supervisor cannot perform stale recovery against the lane that is finishing.
# A replacement supervisor has a different process and an empty registry, so
# crash recovery remains durable/ledger-authoritative rather than depending on
# this optimization.
_LOCAL_EXECUTION_LOCK = threading.Lock()
_LOCAL_EXECUTION_JOBS: dict[int, set[int]] = {}
# _LOCAL_CONNECTION_DEPTH is owned by supervisor_db (the canonical
# persistence owner).  We additionally keep a parallel depth counter here
# so the supervisor can clear _LOCAL_EXECUTION_JOBS on depth=0 — the
# previous design coupled connection lifecycle to execution-job lifecycle
# for the per-thread connection ownership check.
_LOCAL_CONNECTION_DEPTH_SUPERVISOR: dict[int, int] = {}
_SUPERVISOR_LIFECYCLE_LOCK_NAME = "SUPERVISOR_LIFECYCLE.lock"


def _supervisor_lifecycle_lock_path(canonical_repo: Path, run_id: str) -> Path:
    state_mod.validate_run_id(run_id)
    return state_mod.run_dir(canonical_repo, run_id) / _SUPERVISOR_LIFECYCLE_LOCK_NAME


def _serialize_run_lifecycle(func):
    """Serialize supported operator transitions for one logical run.

    Capability resolution is intentionally performed while this narrow
    per-run lock is held.  The SQLite transaction remains short, while resume,
    retire, enqueue, and PROGRAM continuation cannot invalidate the
    QUARANTINED eligibility snapshot mid-migration.
    """
    @wraps(func)
    def guarded(*args, **kwargs):
        canonical_repo = kwargs.get("canonical_repo")
        run_id = kwargs.get("run_id")
        if canonical_repo is None or run_id is None:
            raise TypeError("lifecycle operation requires canonical_repo and run_id")
        with flock_exclusive(
            _supervisor_lifecycle_lock_path(Path(canonical_repo), str(run_id)),
            blocking=True,
            timeout_seconds=30,
        ):
            return func(*args, **kwargs)
    return guarded


def _register_local_execution(job_id: int) -> None:
    with _LOCAL_EXECUTION_LOCK:
        _LOCAL_EXECUTION_JOBS.setdefault(threading.get_ident(), set()).add(int(job_id))


def _local_execution_owned(job_id: int) -> bool:
    with _LOCAL_EXECUTION_LOCK:
        return any(int(job_id) in jobs for jobs in _LOCAL_EXECUTION_JOBS.values())


def _clear_local_executions_for_thread() -> None:
    with _LOCAL_EXECUTION_LOCK:
        _LOCAL_EXECUTION_JOBS.pop(threading.get_ident(), None)


# A commissioned service may need provider authentication/model aliases that a
# launchd/systemd user manager does not inherit from the operator shell. Those
# values live in one private Loop-owned JSON file, never in the service
# definition or runtime provenance. Only this explicit whitelist may be loaded.
_SERVICE_ENV_FILE_VAR = "OFLOOP_SERVICE_ENV_FILE"
_SERVICE_ENV_ALLOWED_KEYS = frozenset({
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_MODEL",
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "CLAUDE_CODE_OAUTH_REFRESH_TOKEN",
    "CLAUDE_CODE_OAUTH_SCOPES",
    "CLAUDE_CONFIG_DIR",
})


def _private_mode(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


def _ensure_private_dir(path: Path) -> Path:
    """Create/repair a supervisor-owned private directory (0700 on POSIX).

    Thin delegate to ``supervisor_db._ensure_private_dir``.  Kept as
    a module-local symbol so existing callers do not need an import
    rewrite; the canonical owner is ``supervisor_db``.
    """
    return _db_mod._ensure_private_dir(path)


def _ensure_private_file_mode(path: Path) -> None:
    """Force a supervisor-owned file to 0600 where POSIX modes are available.

    Thin delegate to ``supervisor_db._ensure_private_file_mode``.
    Canonical owner is ``supervisor_db``.
    """
    _db_mod._ensure_private_file_mode(path)


def _load_service_env_file() -> list[str]:
    """Load a private commissioned-service environment without leaking values.

    The service definition carries only OFLOOP_SERVICE_ENV_FILE. The referenced
    file must be an owned regular file beneath a private directory and have no
    group/other permission bits. Unknown keys or non-string values fail closed.
    """
    raw = os.environ.get(_SERVICE_ENV_FILE_VAR, "").strip()
    if not raw:
        return []
    candidate = Path(raw).expanduser()
    if not candidate.is_absolute() or candidate.is_symlink():
        raise RuntimeError("service_env_refused: path must be an absolute non-symlink")
    try:
        path = candidate.resolve(strict=True)
        st = path.stat()
        parent_st = path.parent.stat()
    except OSError as exc:
        raise RuntimeError(
            f"service_env_refused: unreadable service env ({type(exc).__name__})"
        ) from exc
    if not stat.S_ISREG(st.st_mode):
        raise RuntimeError("service_env_refused: service env is not a regular file")
    if hasattr(os, "getuid") and st.st_uid != os.getuid():
        raise RuntimeError("service_env_refused: service env owner mismatch")
    if stat.S_IMODE(st.st_mode) & 0o077:
        raise RuntimeError("service_env_refused: service env must be mode 0600 or stricter")
    if stat.S_IMODE(parent_st.st_mode) & 0o077:
        raise RuntimeError("service_env_refused: service env directory must be mode 0700 or stricter")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(
            f"service_env_refused: invalid service env ({type(exc).__name__})"
        ) from exc
    if not isinstance(payload, dict):
        raise RuntimeError("service_env_refused: service env must be a JSON object")
    unknown = sorted(set(payload) - _SERVICE_ENV_ALLOWED_KEYS)
    if unknown:
        raise RuntimeError(
            "service_env_refused: unsupported keys=" + ",".join(unknown)
        )
    loaded: list[str] = []
    for key, value in payload.items():
        if not isinstance(value, str) or not value:
            raise RuntimeError(f"service_env_refused: {key} must be a non-empty string")
        os.environ[key] = value
        loaded.append(key)
    return sorted(loaded)

TERMINAL_SEMANTIC_ATTEMPT_STATUSES = frozenset({
    "COMPLETED", "COST_UNKNOWN", "TOKENS_UNKNOWN",
    "FAILED", "RECOVERED", "SUPERSEDED",
})


class WorkerLaunchError(RuntimeError):
    """The semantic process provably failed before a child existed."""


# The OS child is born as this tiny gate, not as the model process. It inherits
# one read end of a pipe. The parent publishes exact PID/attempt/deadline
# ownership to SQLite and commits it before writing the release byte. If the
# parent dies in the post-Popen/pre-publication window, the write end closes
# and the gate exits without ever exec'ing the semantic provider.
_WORKER_RELEASE_GATE_CODE = r"""
import os
import sys
fd = int(sys.argv[1])
try:
    token = os.read(fd, 1)
finally:
    os.close(fd)
if token != b"1":
    os._exit(125)
argv = sys.argv[2:]
if not argv:
    os._exit(126)
os.execvpe(argv[0], argv, os.environ)
"""

# --restricted is Claude Code's native scripted/evaluation boundary for shared
# machines. It confines built-in file tools to working directories, ignores
# user/project/local settings, refuses bypass/cloud sessions, and removes
# command/code/web tools unless explicitly named. Available from v2.1.248.
MIN_SECURE_CLAUDE_CODE_VERSION = (2, 1, 248)

# Claude print-mode JSON is authoritative runner transport. Commissioned runs
# spool it to disk, so bound every subsequent in-memory parse without regressing
# legitimate >64 KiB responses. 8 MiB is intentionally far above diagnostic
# retention while preventing accidental/malicious unbounded supervisor reads.
# Canonical owners are in ``supervisor_runner_io``; the names below are
# re-bindings so existing callers keep the same identifier.


def _read_durable_provider_envelope(path: Path) -> str:
    """Thin delegate to ``supervisor_runner_io._read_durable_provider_envelope``."""
    return _runner_io_mod._read_durable_provider_envelope(path)


def _read_durable_diagnostic_tail(path: Path) -> str:
    """Thin delegate to ``supervisor_runner_io._read_durable_diagnostic_tail``."""
    return _runner_io_mod._read_durable_diagnostic_tail(path)

# Extra arguments are operator convenience only. They must never be able to
# replace the unattended worker's tool boundary, sandbox, project-root, or
# settings-source authority.
_CLAUDE_EXTRA_ARG_AUTHORITY_FLAGS = {
    "--settings",
    "--setting-sources",
    "--tools",
    "--allowedTools",
    "--allowed-tools",
    "--disallowedTools",
    "--disallowed-tools",
    "--permission-mode",
    "--dangerously-skip-permissions",
    "--allow-dangerously-skip-permissions",
    "--add-dir",
    "--cwd",
    "--plugin-dir",
    "--mcp-config",
    "--strict-mcp-config",
    "--chrome",
    "--no-chrome",
    "--remote",
    "--teleport",
    "--no-session-persistence",
    "--restricted",
    "--model",
    "--effort",
    "--max-budget-usd",
}


def _claude_cli_version(executable: str) -> tuple[int, int, int] | None:
    """Return Claude Code semantic version, or None when it cannot be proven."""
    try:
        proc = subprocess.run(
            [executable, "--version"],
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    match = re.search(r"(?<!\d)(\d+)\.(\d+)\.(\d+)(?!\d)", proc.stdout or "")
    if not match:
        return None
    return tuple(int(part) for part in match.groups())


def _validate_claude_extra_args(extra: list[str]) -> None:
    """Semantic-worker invocation has no free-form Claude CLI extension point.

    Claude's CLI surface evolves and includes model fallbacks, custom agents,
    prompt replacement, hooks, cloud execution, worktrees and permission
    controls. A denylist can only lag that authority surface. Model/effort are
    typed runner-profile authority and budgets are supervisor-owned; every
    other semantic invocation flag is core-owned.
    """
    if extra:
        raise RuntimeError(
            "OFLOOP_CLAUDE_EXTRA_ARGS may not override semantic-worker "
            "invocation authority; free-form Claude arguments are disabled"
        )


def _parse_adapter_auth_read_paths() -> list[str]:
    """Resolve exact private credential files an adapter may read.

    The semantic Bash sandbox denies the operator's entire home. A platform
    installer may reopen only a concrete credential FILE (never an auth/config
    directory). Each path must be absolute, existing, owned by the current user,
    and have no group/other permission bits. Malformed/loose entries are dropped
    rather than widening the sandbox.
    """
    raw = os.environ.get("OFLOOP_ADAPTER_AUTH_READ_PATHS", "").strip()
    if not raw:
        return []
    out: list[str] = []
    seen: set[str] = set()
    for entry in raw.split(","):
        candidate = entry.strip()
        if not candidate:
            continue
        p = Path(candidate).expanduser()
        if not p.is_absolute() or p.is_symlink():
            continue
        try:
            resolved_path = p.resolve(strict=True)
            st = resolved_path.stat()
        except (OSError, RuntimeError):
            continue
        resolved = str(resolved_path)
        if resolved in seen:
            continue
        seen.add(resolved)
        if not stat.S_ISREG(st.st_mode):
            continue
        if hasattr(os, "getuid") and st.st_uid != os.getuid():
            continue
        if stat.S_IMODE(st.st_mode) & 0o077:
            continue
        out.append(resolved)
    return out


def _semantic_worker_settings(
    *,
    canonical_repo: Path,
    run_id: str,
    role: str,
    worktree: Path,
    semantic_path: Path,
    network_read_allowlist: list[str] | None = None,
    capability_resolution: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Fail-closed Claude settings for one unattended semantic worker.

    The Bash sandbox is intentionally narrower than the Edit/Write hook
    boundary: builder commands may write the builder worktree; reviewer
    commands may not mutate the exact-SHA reviewer worktree; both roles may
    write only their pass-scoped semantic-result directory and Loop's
    externalized runtime cache outside the worktree.

    --restricted excludes user/project/local settings from the semantic worker.
    Managed policy remains the explicit organization-owned trust boundary;
    Loop supplies the pass-specific sandbox through CLI --settings.
    """
    cache_root = runtime_env.runtime_cache_path(canonical_repo, run_id, role)

    # Restricted mode already confines built-in Read/Edit/Write to the working
    # directories. Bash is explicitly re-enabled for local compilers/tests/git,
    # so give Bash the complementary OS-level read boundary: deny the operator's
    # entire home directory, then re-open only the current pass and trusted Loop
    # runtime surfaces. More-specific allowRead wins over the broad denyRead.
    home = Path.home().expanduser().resolve(strict=False)
    run_evidence_dir = (canonical_repo / ".ownframework-loop" / run_id).resolve(strict=False)
    capability_resolution = capability_resolution or {}
    capability_fs = capability_resolution.get("filesystem") or {}
    capability_allow_read = {
        str(Path(p).expanduser().resolve(strict=False))
        for p in (capability_fs.get("allowRead") or [])
    }
    capability_allow_write = {
        str(Path(p).expanduser().resolve(strict=False))
        for p in (capability_fs.get("allowWrite") or [])
    }
    allow_read = sorted({
        str(worktree.resolve(strict=False)),
        str(semantic_path.parent.resolve(strict=False)),
        str(run_evidence_dir),
        str(cache_root.resolve(strict=False)),
        str((git_checks.git_common_dir(canonical_repo) or (canonical_repo / ".git")).resolve(strict=False)),
        str(_source_root().resolve(strict=False)),
        *_parse_adapter_auth_read_paths(),
        *capability_allow_read,
    })
    allow_write = sorted({
        str(cache_root.resolve(strict=False)),
        str(semantic_path.parent.resolve(strict=False)),
        *capability_allow_write,
    })
    state_root = default_db_path().parent.expanduser().resolve(strict=False)
    # Raw container-daemon sockets are root-equivalent host authority. Even
    # when a Docker broker capability is commissioned, the semantic worker
    # must not bypass that broker by addressing a conventional daemon socket.
    raw_container_sockets = {
        "/var/run/docker.sock",
        "/run/docker.sock",
        "/var/run/podman/podman.sock",
        "/run/podman/podman.sock",
        "/run/containerd/containerd.sock",
        str(home / ".orbstack" / "run" / "docker.sock"),
        str(home / ".docker" / "run" / "docker.sock"),
        str(home / ".local" / "share" / "containers" / "podman" / "podman.sock"),
    }
    deny_read = sorted({str(home), str(state_root), *raw_container_sockets})
    filesystem: dict[str, Any] = {
        "denyRead": deny_read,
        "allowRead": allow_read,
        "allowWrite": allow_write,
    }
    if role == "reviewer":
        filesystem["denyWrite"] = [str(worktree.resolve(strict=False))]

    # Semantic passes never inherit broad host credentials. Outbound Bash
    # reads are restricted to exact packet-frozen network_read_allowlist hosts
    # (empty by default); these native credential rules keep common non-cloud
    # tokens out of Bash even if
    # they exist in the supervisor's environment; the subprocess scrub env var
    # separately strips Anthropic/cloud-provider credentials.
    credential_vars = [
        "GITHUB_TOKEN", "GH_TOKEN", "NPM_TOKEN", "NODE_AUTH_TOKEN",
        "PYPI_TOKEN", "TWINE_PASSWORD", "DOCKER_AUTH_CONFIG",
    ]
    effective_network_domains = sorted(
        set(network_read_allowlist or [])
        | set(capability_resolution.get("network_domains") or [])
    )
    capability_sandbox_network = capability_resolution.get("sandbox_network") or {}
    sandbox_network: dict[str, Any] = {
        "allowedDomains": effective_network_domains,
        "strictAllowlist": True,
    }
    if capability_sandbox_network.get("allowLocalBinding") is True:
        sandbox_network["allowLocalBinding"] = True

    return {
        "autoMemoryEnabled": False,
        "sandbox": {
            "enabled": True,
            "failIfUnavailable": True,
            "autoAllowBashIfSandboxed": True,
            "allowUnsandboxedCommands": False,
            "excludedCommands": [],
            "filesystem": filesystem,
            "network": sandbox_network,
            "credentials": {
                "envVars": [
                    {"name": name, "mode": "deny"} for name in credential_vars
                ],
            },
        },
    }


def resolve_semantic_timeout(
    packet_meta: dict[str, Any] | None,
    supervisor_timeout_seconds: int | float = 0,
) -> int:
    """Resolve one semantic-pass timeout.

    Packet max_pass_runtime_seconds is authority. A positive supervisor
    timeout may narrow it operationally but cannot widen it. With neither,
    preserve the historical one-hour fallback fuse for both single and
    PROGRAM runs; a PROGRAM funds wider passes through its packet budget.
    """
    rb = (packet_meta or {}).get("risk_budget") or {}
    packet_limit = 0
    if isinstance(rb, dict):
        try:
            packet_limit = int(rb.get("max_pass_runtime_seconds") or 0)
        except (TypeError, ValueError):
            packet_limit = 0
    try:
        operational = int(supervisor_timeout_seconds or 0)
    except (TypeError, ValueError):
        operational = 0
    if packet_limit > 0 and operational > 0:
        return min(packet_limit, operational)
    if packet_limit > 0:
        return packet_limit
    if operational > 0:
        return operational
    return DEFAULT_SEMANTIC_TIMEOUT_SECONDS

ACTIVE = {"QUEUED", "BACKOFF", "RUNNING"}
TERMINAL = {"DONE", "QUARANTINED", "RETIRED"}


def runtime_generation() -> str:
    """Deterministic identity of the exact runtime bytes serving this process."""
    from . import __version__
    root = Path(__file__).resolve().parents[2]
    return runtime_identity.runtime_generation_for_root(root, __version__)


# Alias so enqueue() can compute the default binding even though its
# ``runtime_generation`` parameter shadows the function name.
_current_runtime_generation = runtime_generation


def default_db_path() -> Path:
    """Thin delegate to ``supervisor_db.default_db_path`` (canonical owner)."""
    return _db_mod.default_db_path()


def default_worker_log_dir() -> Path:
    root = os.environ.get("XDG_STATE_HOME", "").strip()
    base = Path(root).expanduser() if root else Path.home() / ".local" / "state"
    return base / "ownframework-loop" / "worker-logs"


def _runtime_cache_run_root(canonical_repo: Path, run_id: str) -> Path:
    """Pure path for disposable semantic runtime cache for one run."""
    return runtime_env.runtime_cache_path(canonical_repo, run_id, "builder").parent


def _cleanup_terminal_runtime_cache(
    canonical_repo: Path,
    run_id: str,
) -> dict[str, Any]:
    """Best-effort GC for non-evidence cache after durable DONE."""
    root = _runtime_cache_run_root(canonical_repo, run_id)
    existed = root.exists()
    error = ""
    if existed:
        try:
            shutil.rmtree(root)
            try:
                root.parent.rmdir()
            except OSError:
                pass
        except OSError as exc:
            error = str(exc)
    return {
        "path": str(root),
        "existed": existed,
        "removed": existed and not root.exists(),
        "error": error,
    }


def _cleanup_done_runtime_caches(db_path: Path | None = None) -> list[dict[str, Any]]:
    """Retry disposable-cache GC for durable DONE jobs at supervisor startup."""
    db = db_path or default_db_path()
    if not db.exists():
        return []
    with _managed_connect_readonly(db) as conn:
        rows = conn.execute(
            "SELECT repo,run_id FROM jobs WHERE status='DONE' ORDER BY id"
        ).fetchall()
    return [
        _cleanup_terminal_runtime_cache(Path(row["repo"]), str(row["run_id"]))
        for row in rows
    ]


def _publish_startup_ready_attestation(db_path: Path | None) -> None:
    """Write the durable supervisor's startup-ready attestation.

    The launcher (pre-exec) wrote an activation receipt that proves
    the launcher's pre-exec identity.  That receipt alone does NOT
    prove the durable supervisor actually entered its scheduler
    loop.  This helper derives the durable supervisor's own
    post-exec identity independently from the receipt (Seam 1 of
    the residual-closure) and publishes a startup-ready attestation
    only when the durable process's own observations match the
    receipt.  Any mismatch fails closed; the supervisor logs the
    refusal to stderr and the launchd installer — the load-bearing
    authority for SUPERVISOR_INSTALL verification — observes a
    missing/mismatched attestation and REFUSES PASS.

    Independent derivation sources:

    - ``ofloop_bin`` and ``runtime_root``: ``sys.argv`` of THIS
      post-exec supervisor (it was exec'd with the ofloop binary as
      argv[0]).
    - ``runtime_generation``: recomputed through the same
      ``runtime_identity.runtime_generation_for_root`` against the
      runtime root THIS supervisor observes.  ``env_fallback`` is
      not accepted at commissioning time (Seam 2).
    - ``supervisor_db``: the ``db_path`` this serve() instance is
      bound to, canonicalized.  When ``db_path`` is None, the
      canonical ``default_db_path()`` is used.
    - ``ledger_marker``: derived from the canonical state root the
      durable supervisor reads from.
    - ``activation_id`` and ``label``: read from the launchd env
      (commissioned activation context), exact-matched against the
      receipt.
    """
    from . import service_identity  # local import to avoid startup cycles

    activation_id = os.environ.get("OFLOOP_ACTIVATION_ID", "").strip()
    if not activation_id:
        # No active commissioning attempt.  The supervisor may have
        # been launched directly (e.g. ``ofloop supervisor serve``
        # from an operator's shell).  Nothing to attest.
        return
    receipt_path_env = os.environ.get("OFLOOP_RECEIPT_PATH", "").strip()
    if not receipt_path_env:
        print(
            "SUPERVISOR_STARTUP_READY=skipped reason=receipt_path_unset",
            file=sys.stderr,
        )
        return
    try:
        receipt = service_identity.load_receipt(Path(receipt_path_env))
    except (FileNotFoundError, ValueError, OSError) as exc:
        print(
            "SUPERVISOR_STARTUP_READY=skipped reason=receipt_unreadable detail="
            + str(exc),
            file=sys.stderr,
        )
        return
    # Resolve canonical state root for ledger_marker derivation.
    # The supervisor's own canonical db path provides this.  When
    # ``db_path`` is None we fall through to ``default_db_path()``
    # which honours XDG_STATE_HOME the same way the launcher did.
    if db_path is None:
        actual_db = default_db_path()
    else:
        actual_db = Path(db_path).expanduser().resolve(strict=False)
    # state_root: the parent directory of ``ownframework-loop/`` that
    # contains ``supervisor.sqlite3`` (mirrors the launcher's
    # ``default_receipt_path`` derivation).
    actual_db_path = Path(actual_db).expanduser().resolve(strict=False)
    actual_state_root = actual_db_path.parent.parent  # ../.. from <state>/ownframework-loop/supervisor.sqlite3

    try:
        attestation = service_identity.derive_startup_ready(
            receipt=receipt,
            ready_pid=os.getpid(),
            actual_argv=list(sys.argv),
            actual_env=os.environ,
            actual_db_path=actual_db_path,
            actual_state_root=actual_state_root,
        )
    except ValueError as exc:
        print(
            "SUPERVISOR_STARTUP_READY=refused reason=durable_identity_mismatch detail="
            + str(exc),
            file=sys.stderr,
        )
        return
    ready_path = Path(receipt_path_env).with_name("supervisor-startup-ready.json")
    try:
        service_identity.write_receipt_atomic(attestation, ready_path)
    except OSError as exc:
        print(
            "SUPERVISOR_STARTUP_READY=skipped reason=write_failed detail="
            + str(exc),
            file=sys.stderr,
        )
        return
    print(
        "SUPERVISOR_STARTUP_READY=ATTESTED",
        f"activation_id={attestation['activation_id']}",
        f"ready_pid={attestation['ready_pid']}",
        f"attestation={ready_path}",
    )


def _slug_repo(canonical_repo: Path) -> str:
    p = str(Path(canonical_repo).resolve(strict=False))
    import hashlib
    return hashlib.sha256(p.encode("utf-8")).hexdigest()[:16]


def worker_log_paths(
    canonical_repo: Path,
    run_id: str,
    job_id: int,
    role: str,
    attempt_id: str | None = None,
) -> tuple[Path, Path]:
    """Return durable (stdout, stderr) log paths for one worker attempt.

    The supervisor or any replacement supervisor can read these files even if
    the original parent process died while the child Claude process was still
    alive. Output paths survive both processes by design.
    """
    state_mod.validate_run_id(run_id)
    safe_role = "builder" if role not in ("builder", "reviewer") else role
    safe_run = run_id
    _ensure_private_dir(default_db_path().parent)
    log_root = _ensure_private_dir(default_worker_log_dir())
    repo_root = _ensure_private_dir(log_root / _slug_repo(canonical_repo))
    d = _ensure_private_dir(repo_root / safe_run)
    safe_attempt = "".join(
        ch for ch in str(attempt_id or "") if ch.isalnum() or ch in "-_."
    )[:80]
    suffix = f"-attempt-{safe_attempt}" if safe_attempt else ""
    return (
        d / f"job-{int(job_id)}-{safe_role}{suffix}.out",
        d / f"job-{int(job_id)}-{safe_role}{suffix}.err",
    )


# Ledger data-version. Existing resource ceilings are durable operator state.
# Historical rows may carry the old $25 / unlimited-token / 8h fingerprint,
# but that tuple is indistinguishable from an operator explicitly selecting it.
# Preserve it and mark ambiguity rather than inventing intent.
# Canonical owners are in ``supervisor_db``; the names below are re-bindings
# so existing callers (96 internal SCHEMA references + 4 external
# default_db_path callers + many more) keep the same identifier.
SCHEMA_DATA_VERSION = _db_mod.SCHEMA_DATA_VERSION
DEFAULT_MAX_CONCURRENCY = _db_mod.DEFAULT_MAX_CONCURRENCY
IMPLEMENTATION_MAX_CONCURRENCY = _db_mod.IMPLEMENTATION_MAX_CONCURRENCY
_CONFIG_MAX_CONCURRENCY = _db_mod._CONFIG_MAX_CONCURRENCY
_LEGACY_BUDGET_DEFAULT_FINGERPRINT = _db_mod._LEGACY_BUDGET_DEFAULT_FINGERPRINT
_CONTINUATION_SCHEMA = "ownframework-loop-program-continuation/v1"
_PROGRAM_READY_STATE = next(
    value for value in transitions.STATES
    if value.startswith("READY_TO_") and value.endswith("_BUILD")
)


def _repository_scheduling_identity(repo: Path) -> tuple[str, bool]:
    """Thin delegate to ``supervisor_identity._repository_scheduling_identity``."""
    return _identity_mod._repository_scheduling_identity(repo)


def _workspace_scheduling_identity(
    repo: Path,
    run_id: str,
    *,
    repository_key: str,
    repository_proven: bool,
) -> tuple[str, str, bool]:
    """Thin delegate to ``supervisor_identity._workspace_scheduling_identity``."""
    return _identity_mod._workspace_scheduling_identity(
        repo, run_id,
        repository_key=repository_key,
        repository_proven=repository_proven,
    )


def _packet_execution_mode(repo: Path, run_id: str) -> str:
    """Thin delegate to ``supervisor_identity._packet_execution_mode``."""
    return _identity_mod._packet_execution_mode(repo, run_id)


def _continuation_path(canonical_repo: Path, run_id: str, continuation_id: str) -> Path:
    return (
        state_mod.run_dir(canonical_repo, run_id)
        / "continuations"
        / f"{continuation_id}.json"
    )


def _continuation_id(run_id: str, checkpoint_id: str, candidate_sha: str, reason: str) -> str:
    # Canonical writer of continuation identity. Continuation-Authority
    # (`continuation_authority.derive_continuation_id`) must always agree
    # byte-for-byte with this hash so the dispatcher can reproduce the file
    # path when validating the durable ledger.
    return continuation_authority_mod.derive_continuation_id(
        run_id=run_id,
        checkpoint_id=checkpoint_id,
        candidate_sha=candidate_sha,
        reason=reason,
    )


def _continuation_read(path: Path) -> dict[str, Any] | None:
    value = util.read_private_json(path)
    return value if isinstance(value, dict) else None


def _continuation_write(path: Path, payload: dict[str, Any]) -> None:
    util.atomic_write_json(path, payload, mode=0o600)


def _continuation_conflict(
    repo_path: Path,
    run_id: str,
    *,
    checkpoint_id: str,
    candidate_sha: str,
    continuation_id: str,
    target_repair_round: int | None = None,
) -> bool:
    """Refuse only when ANOTHER funded continuation exists at the same
    (run, checkpoint, candidate, target_repair_round). Prior-round
    continuations are NOT a conflict — they record historical funding
    events that already played out and do not block new rounds. Without
    `target_repair_round`, fall back to the historical scope (any same
    (run, checkpoint, candidate) receipt in PENDING/FUNDED/QUEUED) for
    backwards compatibility.
    """
    directory = state_mod.run_dir(repo_path, run_id) / "continuations"
    if not directory.is_dir():
        return False
    for path in directory.glob("*.json"):
        if path.name == f"{continuation_id}.json":
            continue
        value = _continuation_read(path)
        if not isinstance(value, dict):
            return True
        if not (
            value.get("schema") == _CONTINUATION_SCHEMA
            and value.get("run_id") == run_id
            and value.get("checkpoint_id") == checkpoint_id
            and value.get("candidate_sha") == candidate_sha
            and value.get("status") in {"PENDING", "FUNDED", "QUEUED"}
        ):
            continue
        if target_repair_round is not None:
            before = value.get("before") or {}
            try:
                before_round = int(before.get("repair_round") or -1)
            except (TypeError, ValueError):
                before_round = -1
            # Same run/cp/candidate AND same pre-funding repair_round →
            # conflict. Different round → not a conflict. continue_program
            # captures current.repair_round into before.repair_round BEFORE
            # the eventual increment, so each funded round has a distinct
            # before.repair_round and never blocks its successor.
            if before_round != int(target_repair_round):
                continue
        return True
    return False


def _protected_terminal_recovery(
    *,
    canonical_repo: Path,
    run_id: str,
    packet: dict[str, Any],
    current_state: dict[str, Any],
    checkpoint_id: str,
    builder_worktree: Path,
    candidate_branch: str,
    candidate_sha: str,
) -> dict[str, Any] | None:
    """Recover a terminal protected-only candidate before re-funding a PROGRAM.

    This is the only continuation-specific source transition.  It is
    activated solely by a durable BUILD receipt proving that the terminal
    blocker was protected candidate drift without scope, secret, source-
    ceiling, or validation corruption.  The recovery primitive discards the
    entire candidate tree and returns a core-owned safe descendant.
    """
    path = state_mod.run_dir(canonical_repo, run_id) / "BUILD_RECEIPT.json"
    receipt = util.read_json(path, default=None)
    if not isinstance(receipt, dict):
        return None
    if str(receipt.get("next_state") or "") != "BLOCKED":
        return None
    protected = receipt.get("protected_path_check") or {}
    offending = protected.get("offending_paths") or []
    if str(protected.get("result") or "") != "fail" or not isinstance(offending, list) or not offending:
        return None
    for key in ("scope_check", "secret_scan_check", "program_source_check"):
        value = receipt.get(key) or {}
        if str(value.get("result") or "") == "fail":
            return None
    return protected_recovery.recover_candidate_only_protected_drift(
        canonical_repo=canonical_repo,
        run_id=run_id,
        packet=packet,
        current_state=current_state,
        checkpoint_id=checkpoint_id,
        builder_worktree=builder_worktree,
        candidate_branch=candidate_branch,
        candidate_sha=candidate_sha,
        offending_paths=[str(item) for item in offending],
    )


@_serialize_run_lifecycle
def continue_program(
    *,
    canonical_repo: Path,
    run_id: str,
    reason: str,
    expected_candidate_sha: str,
    db_path: Path | None = None,
) -> dict[str, Any]:
    """Continue one unfinished, blocked PROGRAM checkpoint safely.

    This public operator action is deliberately narrower than ``enqueue`` and
    ``resume``.  It consumes one protocol repair entitlement through the
    state owner, then reactivates the already-enrolled DONE ledger row without
    rebinding runtime, resetting the execution clock, or changing accounting.
    The private receipt makes the state/ledger boundary restart-safe.
    """
    state_mod.validate_run_id(run_id)
    repo_path = Path(canonical_repo).expanduser().resolve(strict=False)
    repo = str(repo_path)
    reason = str(reason or "").strip()
    expected_candidate_sha = str(expected_candidate_sha or "").strip().lower()
    if not reason:
        return {"schema": SCHEMA, "ok": False, "reason": "continuation_reason_required"}
    if not re.fullmatch(r"[0-9a-f]{40}", expected_candidate_sha):
        return {"schema": SCHEMA, "ok": False, "reason": "expected_candidate_sha_invalid"}
    db = db_path or default_db_path()

    with _managed_connect_readonly(db) as conn:
        job, lookup_reason = _logical_job_row(conn, repo_path, run_id)
        if job is None:
            return {
                "schema": SCHEMA, "ok": False, "reason": lookup_reason or "not_enqueued",
                "repo": repo, "run_id": run_id,
            }
        job = dict(job)

    if str(job.get("execution_mode") or "SINGLE").upper() != "PROGRAM":
        return {"schema": SCHEMA, "ok": False, "reason": "continuation_requires_program_mode"}
    if str(job.get("status") or "") not in {"DONE", "QUEUED"}:
        return {
            "schema": SCHEMA, "ok": False,
            "reason": "continuation_requires_done_or_queued_enrollment",
            "status": job.get("status"),
        }
    worker_pid = job.get("worker_pid")
    if worker_pid and _pid_alive(int(worker_pid), float(job.get("worker_started_at") or 0) or None):
        return {"schema": SCHEMA, "ok": False, "reason": "continuation_worker_still_alive"}

    packet_path = state_mod.run_dir(repo_path, run_id) / "WORK_PACKET.md"
    try:
        packet, _ = packet_mod.parse_packet_file(packet_path)
        current = state_mod.load_verified(repo_path, run_id)
    except Exception as exc:
        return {
            "schema": SCHEMA, "ok": False,
            "reason": "continuation_authority_unreadable",
            "error": f"{type(exc).__name__}: {exc}",
        }
    if str(packet.get("execution_mode") or "").lower() != "program":
        return {"schema": SCHEMA, "ok": False, "reason": "packet_is_not_program_mode"}
    if not isinstance(current, dict) or current.get("schema") != state_mod.PROGRAM_STATE_SCHEMA_VERSION:
        return {"schema": SCHEMA, "ok": False, "reason": "program_state_required"}
    program_state = current.get("program")
    if not isinstance(program_state, dict):
        return {"schema": SCHEMA, "ok": False, "reason": "program_state_missing"}
    checkpoint_id = program_mod.select_next_checkpoint(packet, program_state)
    if not checkpoint_id:
        return {"schema": SCHEMA, "ok": False, "reason": "no_unfinished_checkpoint"}
    continuation_id = _continuation_id(run_id, checkpoint_id, expected_candidate_sha, reason)
    receipt_path = _continuation_path(repo_path, run_id, continuation_id)
    receipt = _continuation_read(receipt_path)
    active_candidate_sha = expected_candidate_sha
    if isinstance(receipt, dict):
        recorded_active = str(receipt.get("active_candidate_sha") or "")
        if recorded_active:
            active_candidate_sha = recorded_active
    current_candidate_sha = str(current.get("last_candidate_sha") or "")
    if current_candidate_sha != expected_candidate_sha:
        if not (
            current.get("state") == _PROGRAM_READY_STATE
            and isinstance(receipt, dict)
            and receipt.get("candidate_sha") == expected_candidate_sha
            and receipt.get("active_candidate_sha") == current_candidate_sha
        ):
            return {"schema": SCHEMA, "ok": False, "reason": "candidate_sha_mismatch"}
    branch = str(job.get("candidate_branch") or "")
    if not branch:
        try:
            branch = branch_resolver_mod.resolve_candidate_branch(repo_path, run_id, packet=packet)
        except Exception as exc:
            return {"schema": SCHEMA, "ok": False, "reason": "candidate_branch_unresolved", "error": str(exc)}
    builder_path = util.builder_worktree(repo_path, run_id)
    if not builder_path.is_dir():
        return {"schema": SCHEMA, "ok": False, "reason": "builder_worktree_candidate_mismatch"}
    if git_checks.current_branch(builder_path) != branch:
        return {"schema": SCHEMA, "ok": False, "reason": "builder_worktree_branch_mismatch"}
    if current.get("state") == "BLOCKED" and active_candidate_sha == expected_candidate_sha:
        try:
            recovery = _protected_terminal_recovery(
                canonical_repo=repo_path,
                run_id=run_id,
                packet=packet,
                current_state=current,
                checkpoint_id=checkpoint_id,
                builder_worktree=builder_path,
                candidate_branch=branch,
                candidate_sha=expected_candidate_sha,
            )
        except protected_recovery.ProtectedDriftRecoveryError as exc:
            return {"schema": SCHEMA, "ok": False, "reason": "protected_drift_recovery_refused", "error": str(exc)}
        if recovery is not None:
            active_candidate_sha = str(recovery["candidate_sha"])
    if git_checks.branch_head(repo_path, branch) != active_candidate_sha:
        return {"schema": SCHEMA, "ok": False, "reason": "candidate_branch_head_mismatch", "candidate_branch": branch}
    if git_checks.current_head(builder_path) != active_candidate_sha:
        return {"schema": SCHEMA, "ok": False, "reason": "builder_worktree_candidate_mismatch"}
    cumulative_round = int(
        (((current.get("program") or {}).get("cumulative_counters") or {}).get(
            "repair_round_count"
        ) or 0)
    )
    pre_repair_round = int(current.get("repair_round") or 0)
    if _continuation_conflict(
        repo_path,
        run_id,
        checkpoint_id=checkpoint_id,
        candidate_sha=expected_candidate_sha,
        continuation_id=continuation_id,
        target_repair_round=pre_repair_round,
    ):
        return {"schema": SCHEMA, "ok": False, "reason": "continuation_receipt_conflict"}
    if current.get("state") == _PROGRAM_READY_STATE and receipt is None:
        return {"schema": SCHEMA, "ok": False, "reason": "continuation_receipt_missing"}
    before = {
        "build_pass_count": int(current.get("build_pass_count") or 0),
        "review_pass_count": int(current.get("review_pass_count") or 0),
        "repair_round": int(current.get("repair_round") or 0),
        "total_cost_usd": float(job.get("total_cost_usd") or 0),
        "total_input_tokens": int(job.get("total_input_tokens") or 0),
        "total_output_tokens": int(job.get("total_output_tokens") or 0),
        "total_cache_read_tokens": int(job.get("total_cache_read_tokens") or 0),
        "execution_started_at": job.get("execution_started_at"),
        "runtime_generation": str(job.get("runtime_generation") or ""),
    }
    receipt_before = receipt.get("before") if isinstance(receipt, dict) else None
    if receipt_before is not None and not isinstance(receipt_before, dict):
        return {"schema": SCHEMA, "ok": False, "reason": "continuation_receipt_conflict"}
    immutable_before = receipt_before if isinstance(receipt_before, dict) else before
    immutable = {
        "schema": _CONTINUATION_SCHEMA,
        "run_id": run_id,
        "checkpoint_id": checkpoint_id,
        "continuation_id": continuation_id,
        "candidate_sha": expected_candidate_sha,
        "active_candidate_sha": active_candidate_sha,
        "candidate_branch": branch,
        "reason": reason,
        "before": immutable_before,
    }
    immutable["active_candidate_sha"] = active_candidate_sha
    if receipt is None:
        if receipt_path.exists():
            return {"schema": SCHEMA, "ok": False, "reason": "continuation_receipt_invalid"}
        receipt = dict(immutable)
        receipt.update({"status": "PENDING", "created_at": util.utc_now_iso()})
        _continuation_write(receipt_path, receipt)
    else:
        for key in immutable:
            if receipt.get(key) != immutable[key]:
                return {"schema": SCHEMA, "ok": False, "reason": "continuation_receipt_conflict"}
        if receipt.get("status") not in {"PENDING", "FUNDED", "QUEUED"}:
            return {"schema": SCHEMA, "ok": False, "reason": "continuation_receipt_status_invalid"}
        if receipt.get("status") == "QUEUED" and str(job.get("status") or "") == "DONE":
            return {"schema": SCHEMA, "ok": False, "reason": "continuation_ledger_receipt_conflict"}
        before = immutable_before

    if current.get("state") == "BLOCKED":
        try:
            state_result = state_mod.continue_blocked_program(
                repo_path,
                run_id,
                packet=packet,
                actor="ofloop-operator-continuation",
                reason=reason,
                commit_sha=active_candidate_sha,
                expected_previous_candidate_sha=(
                    expected_candidate_sha
                    if active_candidate_sha != expected_candidate_sha else None
                ),
                continuation_id=continuation_id,
            )
        except (program_mod.ProgramStateError, transitions.InvalidTransitionError, ValueError) as exc:
            return {"schema": SCHEMA, "ok": False, "reason": "continuation_refused", "error": str(exc)}
    elif current.get("state") == _PROGRAM_READY_STATE:
        if receipt.get("status") not in {"PENDING", "FUNDED", "QUEUED"}:
            return {"schema": SCHEMA, "ok": False, "reason": "continuation_state_receipt_conflict"}
        state_result = {
            "ok": True, "continued": False, "idempotent": True,
            "state": _PROGRAM_READY_STATE, "checkpoint_id": checkpoint_id,
            "repair_round": int(current.get("repair_round") or 0),
            "cumulative_repair_round_count": int(
                program_state["cumulative_counters"].get("repair_round_count", 0)
            ),
        }
    else:
        return {"schema": SCHEMA, "ok": False, "reason": "continuation_requires_blocked_program_state", "state": current.get("state")}

    current_after = state_mod.load_verified(repo_path, run_id)
    after = {
        "build_pass_count": int(current_after.get("build_pass_count") or 0),
        "review_pass_count": int(current_after.get("review_pass_count") or 0),
        "repair_round": int(current_after.get("repair_round") or 0),
        "cumulative_repair_round_count": int(
            (current_after.get("program") or {}).get("cumulative_counters", {}).get("repair_round_count", 0)
        ),
    }
    receipt.update({"status": "FUNDED", "funded_at": receipt.get("funded_at") or util.utc_now_iso(), "after": after})
    _continuation_write(receipt_path, receipt)

    with _managed_connect(db) as conn:
        conn.execute("BEGIN IMMEDIATE")
        row = conn.execute("SELECT * FROM jobs WHERE id=?", (int(job["id"]),)).fetchone()
        if row is None:
            return {"schema": SCHEMA, "ok": False, "reason": "enrollment_disappeared"}
        if str(row["status"] or "") == "DONE":
            cur = conn.execute(
                "UPDATE jobs SET status='QUEUED', next_attempt_at=0, updated_at=? WHERE id=? AND status='DONE'",
                (time.time(), int(row["id"])),
            )
            if cur.rowcount != 1:
                row = conn.execute("SELECT * FROM jobs WHERE id=?", (int(row["id"]),)).fetchone()
                if row is None or str(row["status"] or "") != "QUEUED":
                    return {"schema": SCHEMA, "ok": False, "reason": "continuation_ledger_race"}
        elif str(row["status"] or "") != "QUEUED":
            return {"schema": SCHEMA, "ok": False, "reason": "continuation_ledger_state_conflict", "status": row["status"]}
        row = conn.execute("SELECT * FROM jobs WHERE id=?", (int(row["id"]),)).fetchone()
    receipt.update({"status": "QUEUED", "queued_at": receipt.get("queued_at") or util.utc_now_iso()})
    _continuation_write(receipt_path, receipt)
    out = _job_dict(row, db)
    out.update({
        "continuation": {
            "id": continuation_id,
            "checkpoint_id": checkpoint_id,
            "state": state_result,
            "repair_round_before": before["repair_round"],
            "repair_round_after": after["repair_round"],
            "cumulative_repair_round_before": before["repair_round"],
            "cumulative_repair_round_after": after["cumulative_repair_round_count"],
            "receipt": str(receipt_path),
        }
    })
    return out


def _validate_max_concurrency(value: Any) -> int:
    """Thin delegate to ``supervisor_db._validate_max_concurrency``."""
    return _db_mod._validate_max_concurrency(value)


def _apply_data_migrations(conn: sqlite3.Connection) -> None:
    """Versioned migrations; ambiguous historical limits are never rewritten."""
    version = int(conn.execute("PRAGMA user_version").fetchone()[0])
    if version < 3:
        conn.execute(
            """UPDATE jobs
               SET legacy_budget_ambiguous=1
               WHERE max_total_cost_usd=? AND max_total_tokens=?
                 AND max_wall_seconds=?""",
            _LEGACY_BUDGET_DEFAULT_FINGERPRINT,
        )
        conn.execute("PRAGMA user_version = 3")
        version = 3
    if version < 5:
        conn.execute("PRAGMA user_version = 5")
        version = 5
    if version < 6:
        # v0.9 scheduler metadata is operational authority for unfinished jobs.
        # Reconstruct it exactly once from local repository/packet truth instead
        # of paying for Git identity probes on every SQLite connection.
        rows = conn.execute(
            """SELECT id, repo, run_id, status
                 FROM jobs"""
        ).fetchall()
        for row in rows:
            status_value = str(row["status"] or "")
            if status_value in {"DONE", "RETIRED"}:
                continue
            repo = Path(str(row["repo"] or "")).expanduser().resolve(strict=False)
            if not repo.exists():
                # Unfinished work whose repository disappeared remains
                # identity-unproven and therefore cannot be scheduled.
                conn.execute(
                    "UPDATE jobs SET repository_identity_proven=0 WHERE id=?",
                    (int(row["id"]),),
                )
                continue
            key, proven = _repository_scheduling_identity(repo)
            mode = _packet_execution_mode(repo, str(row["run_id"]))
            conn.execute(
                """UPDATE jobs
                      SET repository_scheduling_key=?,
                          repository_identity_proven=?,
                          execution_mode=?
                    WHERE id=?""",
                (key, int(proven), mode, int(row["id"])),
            )
        conn.execute("PRAGMA user_version = 6")
        version = 6
        conn.commit()
    if version < 7:
        rows = conn.execute(
            """SELECT id, repo, run_id, status,
                      repository_scheduling_key, repository_identity_proven
                 FROM jobs"""
        ).fetchall()
        for row in rows:
            if str(row["status"] or "") in {"DONE", "RETIRED"}:
                continue
            repo = Path(str(row["repo"] or "")).expanduser().resolve(strict=False)
            if not repo.exists():
                conn.execute(
                    """UPDATE jobs
                          SET repository_identity_proven=0,
                              workspace_identity_proven=0
                        WHERE id=?""",
                    (int(row["id"]),),
                )
                continue
            repository_key = str(row["repository_scheduling_key"] or "")
            repository_proven = bool(int(row["repository_identity_proven"] or 0))
            if not repository_key or not repository_proven:
                repository_key, repository_proven = _repository_scheduling_identity(repo)
            candidate_branch, workspace_key, workspace_proven = _workspace_scheduling_identity(
                repo, str(row["run_id"]), repository_key=repository_key,
                repository_proven=repository_proven,
            )
            conn.execute(
                """UPDATE jobs
                      SET repository_scheduling_key=?, repository_identity_proven=?,
                          candidate_branch=?, workspace_scheduling_key=?,
                          workspace_identity_proven=?
                    WHERE id=?""",
                (repository_key, int(repository_proven), candidate_branch,
                 workspace_key, int(workspace_proven), int(row["id"])),
            )
        conn.execute(f"PRAGMA user_version = {SCHEMA_DATA_VERSION}")
        conn.commit()

def _connect(path: Path) -> sqlite3.Connection:
    """Thin delegate to ``supervisor_db._connect``.

    The canonical connection bootstrap (file-mode protection,
    schema CREATE TABLE statements, column migrations, config-row
    priming, ``PRAGMA journal_mode=WAL`` /
    ``PRAGMA synchronous=FULL``) lives in ``supervisor_db``.  This
    delegate wires the supervisor-owned data-migration callable
    (``_apply_data_migrations``) through the explicit
    ``data_migrations`` seam so the DB owner never imports this
    module.
    """
    return _db_mod._connect(path, data_migrations=_apply_data_migrations)



@contextmanager
def _managed_connect(path: Path):
    """Thin delegate to ``supervisor_db._managed_connect``.

    The context-manager wrapper (commit/rollback + close +
    per-thread depth tracking) lives in ``supervisor_db``.  This
    delegate threads the supervisor-owned data-migration callable
    through the same ``data_migrations`` seam as ``_connect`` so
    the two stay in lockstep.  It also keeps a parallel
    per-thread depth counter so that when the DB-level depth
    returns to zero the supervisor can clear its own
    ``_LOCAL_EXECUTION_JOBS`` for the thread — this preserves
    the historical coupling between connection lifecycle and
    per-thread execution ownership.
    """
    tid = threading.get_ident()
    with _LOCAL_EXECUTION_LOCK:
        _LOCAL_CONNECTION_DEPTH_SUPERVISOR[tid] = (
            _LOCAL_CONNECTION_DEPTH_SUPERVISOR.get(tid, 0) + 1
        )
    try:
        with _db_mod._managed_connect(
            path, data_migrations=_apply_data_migrations
        ) as conn:
            yield conn
    finally:
        with _LOCAL_EXECUTION_LOCK:
            remaining = _LOCAL_CONNECTION_DEPTH_SUPERVISOR.get(tid, 1) - 1
            if remaining <= 0:
                _LOCAL_CONNECTION_DEPTH_SUPERVISOR.pop(tid, None)
                _LOCAL_EXECUTION_JOBS.pop(tid, None)
            else:
                _LOCAL_CONNECTION_DEPTH_SUPERVISOR[tid] = remaining


def _connect_readonly(path: Path) -> sqlite3.Connection:
    """Thin delegate to ``supervisor_db._connect_readonly``."""
    return _db_mod._connect_readonly(path)


@contextmanager
def _managed_connect_readonly(path: Path):
    """Thin delegate to ``supervisor_db._managed_connect_readonly``."""
    with _db_mod._managed_connect_readonly(path) as conn:
        yield conn


def _pid_alive(pid: int | None, worker_started_at: float | None = None) -> bool:
    """True iff `pid` is alive AND consistent with our recorded worker.

    Beyond the bare kill(pid, 0) probe, if `worker_started_at` is provided,
    we cross-check that the process start time is within ±10 seconds of the
    recorded value. This defends against PID reuse — an unrelated process
    that inherited the same PID is NOT our worker. PermissionError
    (different uid) is treated as "not our worker" rather than alive.

    The start-time cross-check is best-effort. If introspection fails
    (sandbox, container cgroup stall, missing psutil-like APIs), the bare
    kill() probe is the fallback.
    """
    if not pid or int(pid) <= 0:
        return False
    pid = int(pid)
    try:
        os.kill(pid, 0)
    except (ProcessLookupError, PermissionError):
        return False
    if worker_started_at is None or worker_started_at <= 0:
        return True
    try:
        start_ts = _read_pid_start_time(pid)
        if start_ts is None:
            return True
        if abs(start_ts - worker_started_at) > 10:
            return False
    except Exception:
        return True
    return True


def _read_pid_start_identity(pid: int) -> str | None:
    """Return a durable exact process-start identity for safe signalling.

    Linux binds kernel start ticks to /proc's boot_id, preventing a false match
    after reboot. Darwin reads proc_bsdinfo's microsecond start timestamp via
    libproc rather than relying on second-granularity ps output. Failure to
    obtain either identity is fail-safe: replacement recovery will not signal.
    """
    try:
        if sys.platform == "linux":
            with open(f"/proc/{int(pid)}/stat", encoding="utf-8") as f:
                content = f.read()
            rp = content.rfind(")")
            if rp < 0:
                return None
            fields = content[rp + 1:].split()
            if len(fields) < 20:
                return None
            with open("/proc/sys/kernel/random/boot_id", encoding="utf-8") as f:
                boot_id = f.read().strip()
            if not boot_id:
                return None
            return f"linux-boot:{boot_id}:startticks:{int(fields[19])}"
        if sys.platform == "darwin":
            import ctypes

            class _ProcBsdInfo(ctypes.Structure):
                _fields_ = [
                    ("pbi_flags", ctypes.c_uint32),
                    ("pbi_status", ctypes.c_uint32),
                    ("pbi_xstatus", ctypes.c_uint32),
                    ("pbi_pid", ctypes.c_uint32),
                    ("pbi_ppid", ctypes.c_uint32),
                    ("pbi_uid", ctypes.c_uint32),
                    ("pbi_gid", ctypes.c_uint32),
                    ("pbi_ruid", ctypes.c_uint32),
                    ("pbi_rgid", ctypes.c_uint32),
                    ("pbi_svuid", ctypes.c_uint32),
                    ("pbi_svgid", ctypes.c_uint32),
                    ("rfu_1", ctypes.c_uint32),
                    ("pbi_comm", ctypes.c_char * 16),
                    ("pbi_name", ctypes.c_char * 32),
                    ("pbi_nfiles", ctypes.c_uint32),
                    ("pbi_pgid", ctypes.c_uint32),
                    ("pbi_pjobc", ctypes.c_uint32),
                    ("e_tdev", ctypes.c_uint32),
                    ("e_tpgid", ctypes.c_uint32),
                    ("pbi_nice", ctypes.c_int32),
                    ("pbi_start_tvsec", ctypes.c_uint64),
                    ("pbi_start_tvusec", ctypes.c_uint64),
                ]

            libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
            proc_pidinfo = libproc.proc_pidinfo
            proc_pidinfo.argtypes = [
                ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                ctypes.c_void_p, ctypes.c_int,
            ]
            proc_pidinfo.restype = ctypes.c_int
            info = _ProcBsdInfo()
            PROC_PIDTBSDINFO = 3
            size = ctypes.sizeof(info)
            rc = int(proc_pidinfo(
                int(pid), PROC_PIDTBSDINFO, 0, ctypes.byref(info), size
            ))
            if rc != size or int(info.pbi_pid) != int(pid):
                return None
            return (
                f"darwin-start:{int(info.pbi_start_tvsec)}:"
                f"{int(info.pbi_start_tvusec)}"
            )
    except Exception:
        return None
    return None


def _pid_identity_proven(pid: int | None, expected_identity: str | None) -> bool:
    """Strict identity proof used before signalling a recovered orphan."""
    if not pid or int(pid) <= 0 or not expected_identity:
        return False
    pid = int(pid)
    try:
        os.kill(pid, 0)
    except (ProcessLookupError, PermissionError):
        return False
    observed = _read_pid_start_identity(pid)
    return observed is not None and observed == str(expected_identity)


def _terminate_owned_process_group(
    pid: int,
    pgid: int | None,
    expected_identity: str | None,
    worker_started_at: float | None,
) -> bool:
    """Terminate only a process group whose exact leader identity is proven."""
    if not pgid or int(pgid) != int(pid):
        return False
    if not _pid_identity_proven(pid, expected_identity):
        return False
    try:
        os.killpg(int(pgid), signal.SIGTERM)
    except ProcessLookupError:
        return True
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline:
        if not _pid_alive(pid, worker_started_at):
            return True
        time.sleep(0.05)
    if not _pid_identity_proven(pid, expected_identity):
        return not _pid_alive(pid, worker_started_at)
    try:
        os.killpg(int(pgid), signal.SIGKILL)
    except ProcessLookupError:
        return True
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline:
        if not _pid_alive(pid, worker_started_at):
            return True
        time.sleep(0.05)
    return not _pid_alive(pid, worker_started_at)


def _read_pid_start_time(pid: int) -> float | None:
    """Best-effort cross-platform process start-time read.

    Linux: read /proc/<pid>/stat field 22 (start_time in clock ticks since boot).
    macOS: use ps -o etime= to compute approximate age.
    Returns Unix timestamp in seconds, or None on failure.
    """
    try:
        if sys.platform == "linux":
            with open(f"/proc/{pid}/stat", encoding="utf-8") as f:
                content = f.read()
            rp = content.rfind(")")
            if rp < 0:
                return None
            fields = content[rp + 1:].split()
            # We removed fields 1(pid) and 2(comm), so fields[0] is proc
            # stat field 3 (state). Linux starttime is field 22 => index 19.
            if len(fields) < 20:
                return None
            ticks = int(fields[19])
            try:
                clk_tck = os.sysconf("SC_CLK_TCK")
            except Exception:
                clk_tck = 100
            boot = _boot_time_unix()
            if boot is None:
                return None
            return boot + ticks / float(clk_tck)
        # macOS fallback
        r = subprocess.run(
            ["ps", "-o", "etime=", "-p", str(pid)],
            capture_output=True, text=True, check=False, timeout=2,
        )
        if r.returncode != 0 or not r.stdout.strip():
            return None
        etime = r.stdout.strip()
        # Parse [[dd-]hh:]mm:ss without losing hour/day forms.
        parts = etime.split(":")
        try:
            if len(parts) == 2:
                minutes, seconds = (int(parts[0]), int(parts[1]))
                total = minutes * 60 + seconds
            elif len(parts) == 3:
                first, minutes_s, seconds_s = parts
                minutes, seconds = int(minutes_s), int(seconds_s)
                if "-" in first:
                    days_s, hours_s = first.split("-", 1)
                    total = (
                        int(days_s) * 86400
                        + int(hours_s) * 3600
                        + minutes * 60
                        + seconds
                    )
                else:
                    total = int(first) * 3600 + minutes * 60 + seconds
            else:
                return None
        except ValueError:
            return None
        return time.time() - total
    except Exception:
        return None


_BOOT_TIME_CACHE: float | None = None


def _boot_time_unix() -> float | None:
    """Read system boot time in Unix seconds (Linux)."""
    global _BOOT_TIME_CACHE
    if _BOOT_TIME_CACHE is not None:
        return _BOOT_TIME_CACHE
    try:
        with open("/proc/stat", encoding="utf-8") as f:
            for line in f:
                if line.startswith("btime "):
                    _BOOT_TIME_CACHE = float(line.split()[1])
                    return _BOOT_TIME_CACHE
    except Exception:
        return None
    return None


def _parse_cost_from_durable_stdout(path: str | None) -> float | None:
    # thin delegation: canonical implementation lives in
    # supervisor_accounting.py.
    from . import supervisor_accounting as _accounting_mod
    return _accounting_mod.parse_cost_from_durable_stdout(path)


def _parse_token_usage_from_durable_stdout(path: str | None) -> dict[str, int] | None:
    # thin delegation: canonical implementation lives in
    # supervisor_accounting.py.
    from . import supervisor_accounting as _accounting_mod
    return _accounting_mod.parse_token_usage_from_durable_stdout(path)


def _durable_envelope_payload(path: str | None) -> dict[str, Any] | None:
    from . import supervisor_accounting as _accounting_mod
    return _accounting_mod._durable_envelope_payload(path)


def _extract_effective_model_from_durable_stdout(path: str | None) -> str:
    from . import supervisor_accounting as _accounting_mod
    return _accounting_mod.extract_effective_model_from_durable_stdout(path)


def _extract_model_usage_json_from_durable_stdout(path: str | None) -> str:
    from . import supervisor_accounting as _accounting_mod
    return _accounting_mod.extract_model_usage_json_from_durable_stdout(path)


def _extract_effective_model(payload: dict[str, Any] | None) -> str:
    from . import supervisor_accounting as _accounting_mod
    return _accounting_mod.extract_effective_model(payload)


def _extract_model_usage_json(payload: dict[str, Any] | None) -> str:
    from . import supervisor_accounting as _accounting_mod
    return _accounting_mod.extract_model_usage_json(payload)


def _strict_profile_model_violation(
    requested_model: str, *, result_ok: bool, effective_model: str
) -> str:
    from . import supervisor_accounting as _accounting_mod
    return _accounting_mod.strict_profile_model_violation(
        requested_model, result_ok=result_ok, effective_model=effective_model,
    )


def _replay_candidate_sha(
    *,
    role: str,
    work_order: dict[str, Any],
    repo: str,
    run_id: str,
) -> str:
    """Thin delegate to ``supervisor_attempts._replay_candidate_sha``."""
    return _attempts_mod._replay_candidate_sha(
        role=role, work_order=work_order, repo=repo, run_id=run_id
    )


def _attempt_provenance_gate(
    conn: sqlite3.Connection,
    *,
    job: sqlite3.Row,
    work_order: dict[str, Any],
    attempt_id: str,
) -> tuple[bool, str, dict[str, Any] | None]:
    """Thin delegate to ``supervisor_attempts._attempt_provenance_gate``."""
    return _attempts_mod._attempt_provenance_gate(
        conn, job=job, work_order=work_order, attempt_id=attempt_id
    )


def _extract_model_usage_json(payload: dict[str, Any] | None) -> str:
    """Canonical JSON of the FULL provider-reported modelUsage, or "".

    Preserves every model the provider billed (including multi-model mixes)
    so the ledger never loses usage truth that a singular effective model
    cannot express.
    """
    if not isinstance(payload, dict):
        return ""
    usage = payload.get("modelUsage")
    if not isinstance(usage, dict) or not usage:
        return ""
    try:
        encoded = json.dumps(
            usage, sort_keys=True, separators=(",", ":"), ensure_ascii=True
        )
    except (TypeError, ValueError):
        return ""
    # The durable provider envelope is already bounded. Preserve complete,
    # valid canonical JSON instead of slicing evidence into an invalid fragment.
    return encoded


def _account_attempt_cost(
    conn: sqlite3.Connection,
    *,
    job_id: int,
    attempt_id: str,
    cost_usd: float,
    returncode: int | None = None,
    status_value: str = "COMPLETED",
    cost_known: bool = True,
    input_tokens: int = 0,
    output_tokens: int = 0,
    cache_read_tokens: int = 0,
    cache_creation_tokens: int = 0,
    tokens_known: bool = False,
    manage_transaction: bool = True,
    effective_model: str | None = None,
    model_usage_json: str | None = None,
) -> float | None:
    """Thin delegate to ``supervisor_attempts._account_attempt_cost``."""
    return _attempts_mod._account_attempt_cost(
        conn,
        job_id=job_id,
        attempt_id=attempt_id,
        cost_usd=cost_usd,
        returncode=returncode,
        status_value=status_value,
        cost_known=cost_known,
        input_tokens=input_tokens,
        output_tokens=output_tokens,
        cache_read_tokens=cache_read_tokens,
        cache_creation_tokens=cache_creation_tokens,
        tokens_known=tokens_known,
        manage_transaction=manage_transaction,
        effective_model=effective_model,
        model_usage_json=model_usage_json,
    )


def _publish_semantic_acceptance(
    conn: sqlite3.Connection,
    *,
    job_id: int,
    attempt_id: str,
    semantic_path: Path,
    candidate_sha: str,
) -> None:
    """Thin delegate to ``supervisor_attempts._publish_semantic_acceptance``."""
    _attempts_mod._publish_semantic_acceptance(
        conn,
        job_id=job_id,
        attempt_id=attempt_id,
        semantic_path=semantic_path,
        candidate_sha=candidate_sha,
    )


def _remaining_funded_cost_budget(max_total_cost_usd: float, spent_cost_usd: float) -> float | None:
    """Thin delegate to ``supervisor_attempts._remaining_funded_cost_budget``."""
    return _attempts_mod._remaining_funded_cost_budget(
        max_total_cost_usd, spent_cost_usd
    )


def _unknown_cost_attempt_count(conn: sqlite3.Connection, job_id: int) -> int:
    """Thin delegate to ``supervisor_attempts._unknown_cost_attempt_count``."""
    return _attempts_mod._unknown_cost_attempt_count(conn, job_id)


PRE_PROVIDER_FAILURE_REASONS = frozenset({
    "worker_launch_failed",
    "capability_resolution_failed",
    "capability_binding_failed",
    "runner_profile_resolution_failed",
    "worker_ownership_not_published",
})


def _capability_binding_creation_allowed(
    conn: sqlite3.Connection,
    job_id: int,
) -> bool:
    """Allow first binding only when no provider-reachable historical attempt exists."""
    rows = conn.execute(
        """SELECT status, failure_reason, cost_accounted, cost_usd
             FROM semantic_attempts WHERE job_id=?""",
        (int(job_id),),
    ).fetchall()
    if not rows:
        return True
    return all(
        str(row["status"] or "") == "FAILED"
        and str(row["failure_reason"] or "") in PRE_PROVIDER_FAILURE_REASONS
        and int(row["cost_accounted"] or 0) == 1
        and float(row["cost_usd"] or 0.0) == 0.0
        for row in rows
    )


def _mark_attempt_launch_failed(
    conn: sqlite3.Connection,
    *,
    job_id: int,
    attempt_id: str,
    detail: str,
    failure_reason: str = "worker_launch_failed",
) -> None:
    """Terminalize only a semantic attempt proven not to have reached provider exec."""
    conn.execute("BEGIN IMMEDIATE")
    cur = conn.execute(
        """UPDATE semantic_attempts SET
             status='FAILED', completed_at=?, returncode=NULL,
             worker_pid=NULL, worker_pgid=NULL, deadline_at=NULL,
             worker_start_identity=NULL,
             cost_usd=0, cost_accounted=1, cost_known=1,
             input_tokens=0, output_tokens=0, cache_read_tokens=0,
             cache_creation_tokens=0, tokens_known=1,
             failure_class='configuration', failure_reason=?
           WHERE attempt_id=? AND job_id=?
             AND (
               status='RESERVED'
               OR (status='RUNNING' AND launch_gate_version>=1)
             )""",
        (time.time(), failure_reason, attempt_id, int(job_id)),
    )
    if cur.rowcount != 1:
        conn.rollback()
        raise RuntimeError(
            f"launch-failed attempt was not provably pre-provider: "
            f"{attempt_id}: {detail[-500:]}"
        )
    conn.commit()


_RECOVERY_OWNERSHIP_FIELDS = _recovery_mod._RECOVERY_OWNERSHIP_FIELDS


def _recovery_ownership_matches(
    current: sqlite3.Row | None,
    observed: sqlite3.Row,
) -> bool:
    """Thin delegate to ``supervisor_recovery._recovery_ownership_matches``."""
    return _recovery_mod._recovery_ownership_matches(current, observed)


def _recover_stale_running(conn: sqlite3.Connection) -> int:
    """Thin delegate to ``supervisor_recovery._recover_stale_running``."""
    return _recovery_mod._recover_stale_running(conn)


def _validate_dispatch_hold_request(
    kind: str | None,
    previous_checkpoint_id: str | None,
    next_checkpoint_id: str | None,
) -> None:
    """Thin delegate to ``supervisor_holds._validate_dispatch_hold_request``."""
    return _holds_mod._validate_dispatch_hold_request(
        kind, previous_checkpoint_id, next_checkpoint_id
    )


def _hold_row(conn: sqlite3.Connection, job_id: int) -> sqlite3.Row | None:
    """Thin delegate to ``supervisor_holds._hold_row``."""
    return _holds_mod._hold_row(conn, job_id)


def _hold_dict(row: sqlite3.Row | None) -> dict[str, Any] | None:
    """Thin delegate to ``supervisor_holds._hold_dict``."""
    return _holds_mod._hold_dict(row)


def _hold_matches_before_claim(
    conn: sqlite3.Connection,
    row: sqlite3.Row,
) -> tuple[sqlite3.Row | None, str]:
    """Thin delegate to ``supervisor_holds._hold_matches_before_claim``."""
    return _holds_mod._hold_matches_before_claim(conn, row)


@_serialize_run_lifecycle
def enqueue(
    *,
    canonical_repo: Path,
    run_id: str,
    runner: str = "claude-code",
    db_path: Path | None = None,
    max_infra_failures: int | None = None,
    max_transient_failures: int | None = None,
    max_transient_recovery_cycles: int | None = None,
    max_total_cost_usd: float | None = None,
    max_total_tokens: int | None = None,
    max_wall_seconds: int | None = None,
    runtime_generation: str | None = None,
    dispatch_hold_kind: str | None = None,
    dispatch_hold_previous_checkpoint_id: str | None = None,
    dispatch_hold_next_checkpoint_id: str | None = None,
) -> dict[str, Any]:
    """Thin delegate to ``supervisor_claims.enqueue``."""
    return _claims_mod.enqueue(
        canonical_repo=canonical_repo,
        run_id=run_id,
        runner=runner,
        db_path=db_path,
        max_infra_failures=max_infra_failures,
        max_transient_failures=max_transient_failures,
        max_transient_recovery_cycles=max_transient_recovery_cycles,
        max_total_cost_usd=max_total_cost_usd,
        max_total_tokens=max_total_tokens,
        max_wall_seconds=max_wall_seconds,
        runtime_generation=runtime_generation,
        dispatch_hold_kind=dispatch_hold_kind,
        dispatch_hold_previous_checkpoint_id=dispatch_hold_previous_checkpoint_id,
        dispatch_hold_next_checkpoint_id=dispatch_hold_next_checkpoint_id,
    )


def _logical_job_row(
    conn: sqlite3.Connection,
    canonical_repo: Path,
    run_id: str,
) -> tuple[sqlite3.Row | None, str | None]:
    """Thin delegate to ``supervisor_db._logical_job_row``."""
    return _db_mod._logical_job_row(conn, canonical_repo, run_id)

def status(
    *,
    canonical_repo: Path,
    run_id: str,
    db_path: Path | None = None,
) -> dict[str, Any]:
    """Thin delegate to ``supervisor_readmodel.status``."""
    return _readmodel_mod.status(
        canonical_repo=canonical_repo, run_id=run_id, db_path=db_path
    )


def _readonly_columns(conn: sqlite3.Connection, table: str) -> set[str]:
    """Thin delegate to ``supervisor_readmodel._readonly_columns``."""
    return _readmodel_mod._readonly_columns(conn, table)


def _legacy_readonly_fleet_projection(
    conn: sqlite3.Connection, db: Path
) -> dict[str, Any]:
    """Thin delegate to ``supervisor_readmodel._legacy_readonly_fleet_projection``."""
    return _readmodel_mod._legacy_readonly_fleet_projection(conn, db)

def supervisor_config_get(*, db_path: Path | None = None) -> dict[str, Any]:
    """Thin delegate to ``supervisor_readmodel.supervisor_config_get``."""
    return _readmodel_mod.supervisor_config_get(db_path=db_path)


def supervisor_config_set(*, max_concurrency: Any, db_path: Path | None = None) -> dict[str, Any]:
    """Persist the bounded operational execution capacity."""
    from . import supervisor_operator as _operator_mod
    return _operator_mod.supervisor_config_set(
        max_concurrency=max_concurrency, db_path=db_path
    )


def fleet_status(*, db_path: Path | None = None) -> dict[str, Any]:
    """Thin delegate to ``supervisor_readmodel.fleet_status``."""
    return _readmodel_mod.fleet_status(db_path=db_path)


def dispatch_hold_status(
    *,
    canonical_repo: Path,
    run_id: str,
    hold_id: str | None = None,
    db_path: Path | None = None,
) -> dict[str, Any]:
    """Read-only operator view of one (or the active) dispatch hold."""
    return _holds_mod.dispatch_hold_status(
        canonical_repo=canonical_repo,
        run_id=run_id,
        hold_id=hold_id,
        db_path=db_path,
    )


def release_dispatch_hold(
    *,
    canonical_repo: Path,
    run_id: str,
    hold_id: str,
    db_path: Path | None = None,
) -> dict[str, Any]:
    """Release one HELD dispatch hold (idempotent on already-RELEASED)."""
    return _holds_mod.release_dispatch_hold(
        canonical_repo=canonical_repo,
        run_id=run_id,
        hold_id=hold_id,
        db_path=db_path,
    )


def cancel_dispatch_hold(
    *,
    canonical_repo: Path,
    run_id: str,
    hold_id: str,
    db_path: Path | None = None,
) -> dict[str, Any]:
    """Cancel one ARMED/HELD dispatch hold (refuses RELEASED)."""
    return _holds_mod.cancel_dispatch_hold(
        canonical_repo=canonical_repo,
        run_id=run_id,
        hold_id=hold_id,
        db_path=db_path,
    )


def _run_git_readonly(repo: Path, args: list[str], *, timeout: int = 10) -> dict[str, Any]:
    """Thin delegate to ``supervisor_readmodel._run_git_readonly``."""
    return _readmodel_mod._run_git_readonly(repo, args, timeout=timeout)


def _registered_worktree_paths(repo: Path) -> tuple[set[str], str | None]:
    """Thin delegate to ``supervisor_readmodel._registered_worktree_paths``."""
    return _readmodel_mod._registered_worktree_paths(repo)


def _worktree_visibility(
    canonical_repo: Path,
    path: Path,
    *,
    registered_paths: set[str],
    registry_error: str | None,
) -> dict[str, Any]:
    """Thin delegate to ``supervisor_readmodel._worktree_visibility``."""
    return _readmodel_mod._worktree_visibility(
        canonical_repo,
        path,
        registered_paths=registered_paths,
        registry_error=registry_error,
    )


def _candidate_diff_visibility(
    canonical_repo: Path,
    *,
    baseline_sha: str,
    candidate_sha: str,
    max_paths: int = 100,
) -> dict[str, Any]:
    """Thin delegate to ``supervisor_readmodel._candidate_diff_visibility``."""
    return _readmodel_mod._candidate_diff_visibility(
        canonical_repo,
        baseline_sha=baseline_sha,
        candidate_sha=candidate_sha,
        max_paths=max_paths,
    )


def _core_snapshot(repo: Path, run_id: str) -> dict[str, Any]:
    """Thin delegate to ``supervisor_readmodel._core_snapshot``."""
    return _readmodel_mod._core_snapshot(repo, run_id)

def _job_dict(row: sqlite3.Row, db: Path) -> dict[str, Any]:
    """Thin delegate to ``supervisor_readmodel._job_dict``."""
    return _readmodel_mod._job_dict(row, db)


def _source_root() -> Path:
    return Path(__file__).resolve().parent.parent.parent


def _load_role_prompt(role: str) -> str:
    name = "of-builder.md" if role == "builder" else "of-reviewer.md"
    path = _source_root() / "agents" / name
    if not path.is_file():
        raise RuntimeError(f"runner prompt missing: {path}")
    return path.read_text(encoding="utf-8")


def _write_semantic_prompt_provenance(
    *,
    work_order: dict[str, Any],
    effective_work_order: dict[str, Any],
    prompt: str,
    role_contract: str,
) -> Path:
    """Persist the exact semantic envelope before provider launch.

    Only the sealed work order and public capability summaries are recorded;
    process environment, credentials, and provider output are intentionally
    excluded.  The prompt bytes are stored so a retry or adjudication can
    prove exactly what the provider received.
    """
    repo = Path(str(work_order.get("canonical_repo") or "")).resolve(strict=False)
    run_id = str(work_order.get("run_id") or "")
    attempt_id = str(work_order.get("attempt_id") or "")
    role = str(work_order.get("role") or "")
    if not attempt_id or role not in {"builder", "reviewer"}:
        raise RuntimeError("semantic provenance requires attempt identity and role")
    # Work orders are core-owned JSON.  These are the only fields written;
    # notably no shell environment, access token, or provider credential is
    # copied into the durable artifact.
    safe_order = json.loads(json.dumps(effective_work_order, sort_keys=True))
    for forbidden in ("env", "environment", "token", "credential", "secret", "api_key", "authorization"):
        safe_order.pop(forbidden, None)
    payload = {
        "schema": "ownframework-loop-semantic-prompt-provenance/v1",
        "run_id": run_id,
        "attempt_id": attempt_id,
        "role": role,
        "decision": str(work_order.get("decision") or ""),
        "checkpoint_id": str(work_order.get("checkpoint_id") or ""),
        "work_unit_id": str(work_order.get("work_unit_id") or ""),
        "candidate_sha": str(work_order.get("candidate_sha") or ""),
        "packet_sha256": str(work_order.get("packet_sha256") or ""),
        "approval_sha256": str(work_order.get("approval_sha256") or ""),
        "work_order": safe_order,
        "prompt": prompt,
        "prompt_sha256": util.sha256_bytes(prompt.encode("utf-8")),
        "role_contract_sha256": util.sha256_bytes(role_contract.encode("utf-8")),
        "recorded_at": util.utc_now_iso(),
    }
    target_dir = state_mod.run_dir(repo, run_id) / "semantic-provenance"
    target_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(target_dir, 0o700)
    target = target_dir / f"{attempt_id}-{role}.json"
    if target.exists():
        prior = util.read_private_json(target, default=None)
        if not isinstance(prior, dict) or prior.get("prompt_sha256") != payload["prompt_sha256"]:
            raise RuntimeError("semantic prompt provenance collision")
        return target
    util.atomic_write_json(target, payload, mode=0o600)
    if stat.S_IMODE(target.stat().st_mode) != 0o600:
        raise RuntimeError("semantic prompt provenance mode proof failed")
    return target


def _terminate_group(proc: subprocess.Popen[str], grace_seconds: float = 3.0) -> None:
    """Terminate and reap one semantic worker process group."""
    if proc.poll() is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        proc.wait(timeout=grace_seconds)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    proc.wait()


# RunnerResult / RunnerReadiness are owned by supervisor_runner_registry
# so the runner contract lives in one place.  Import them now so
# downstream code in this module uses the canonical classes, not a
# duplicate.  Existing call sites that reference
# ``supervisor.RunnerResult`` / ``supervisor.RunnerReadiness`` keep
# working because the supervisor module re-exports the same class
# objects via the post-import assignment below.
from . import supervisor_runner_registry as _runner_registry_mod  # noqa: E402
RunnerResult = _runner_registry_mod.RunnerResult
RunnerReadiness = _runner_registry_mod.RunnerReadiness


class ClaudeCodeRunner:
    """One fresh non-interactive Claude Code process per semantic pass."""

    runner_id = "claude-code"
    requires_capability_receipt = True
    # Only runners that actually implement the persist-before-exec release
    # handshake may claim gate-v1 recovery semantics.
    launch_gate_version = 1

    def preflight(self) -> RunnerReadiness:
        """Check executable availability without starting a semantic attempt."""
        pinned = os.environ.get("OFLOOP_CLAUDE_BIN", "").strip()
        if pinned:
            p = Path(pinned).expanduser().resolve(strict=False)
            if not (p.is_file() and os.access(p, os.X_OK)):
                return RunnerReadiness(
                    False,
                    classification="configuration",
                    reason="pinned_runner_unavailable",
                    detail=f"commissioned Claude binary unavailable: {p}",
                    retry_after_seconds=0.0,
                )
            version = _claude_cli_version(str(p))
            if version is None:
                return RunnerReadiness(
                    False,
                    classification="configuration",
                    reason="runner_version_unproven",
                    detail="commissioned Claude Code version could not be proven",
                    retry_after_seconds=0.0,
                )
            if version < MIN_SECURE_CLAUDE_CODE_VERSION:
                return RunnerReadiness(
                    False,
                    classification="configuration",
                    reason="runner_secure_sandbox_version_too_old",
                    detail=(
                        "Claude Code "
                        + ".".join(str(x) for x in version)
                        + " is older than the required secure unattended-worker baseline "
                        + ".".join(str(x) for x in MIN_SECURE_CLAUDE_CODE_VERSION)
                    ),
                    retry_after_seconds=0.0,
                )
            return RunnerReadiness(True)

        discovered = shutil.which("claude")
        if discovered:
            p = Path(discovered).expanduser().resolve(strict=False)
            if p.is_file() and os.access(p, os.X_OK):
                version = _claude_cli_version(str(p))
                if version is None:
                    return RunnerReadiness(
                        False,
                        classification="configuration",
                        reason="runner_version_unproven",
                        detail="discovered Claude Code version could not be proven",
                        retry_after_seconds=0.0,
                    )
                if version < MIN_SECURE_CLAUDE_CODE_VERSION:
                    return RunnerReadiness(
                        False,
                        classification="configuration",
                        reason="runner_secure_sandbox_version_too_old",
                        detail=(
                            "Claude Code "
                            + ".".join(str(x) for x in version)
                            + " is older than the required secure unattended-worker baseline "
                            + ".".join(str(x) for x in MIN_SECURE_CLAUDE_CODE_VERSION)
                        ),
                        retry_after_seconds=0.0,
                    )
                return RunnerReadiness(True)

        return RunnerReadiness(
            False,
            classification="environment_wait",
            reason="runner_not_discoverable",
            detail="Claude CLI not currently discoverable on service PATH",
            retry_after_seconds=30.0,
        )

    def run(
        self,
        work_order: dict[str, Any],
        *,
        timeout_seconds: int = 3600,
        on_start=None,
        durable_files: tuple[Path, Path] | None = None,
    ) -> RunnerResult:
        role = str(work_order.get("role") or "")
        if role not in {"builder", "reviewer"}:
            raise RuntimeError(f"unsupported work-order role: {role!r}")
        worktree = Path(str(work_order.get("worktree") or "")).resolve(strict=False)
        if not worktree.is_dir():
            raise RuntimeError(f"prepared worktree missing: {worktree}")

        role_contract = _load_role_prompt(role)
        canonical_repo = Path(
            str(work_order.get("canonical_repo") or "")
        ).resolve(strict=False)
        semantic_path = Path(
            str(work_order.get("semantic_path") or "")
        ).resolve(strict=False)
        attempt_id = str(work_order.get("attempt_id") or "")
        if not attempt_id:
            raise capabilities_mod.CapabilityResolutionError(
                "semantic work order missing durable attempt identity"
            )
        capability_resolution = capabilities_mod.resolve_capabilities(
            [str(item) for item in (work_order.get("capabilities") or [])],
            canonical_repo=canonical_repo,
            role=role,
            repo_cache_root=runtime_env.repo_tool_cache_dir(canonical_repo),
            ephemeral_cache_root=(
                runtime_env.runtime_cache_dir(
                    canonical_repo,
                    str(work_order.get("run_id") or ""),
                    role,
                ) / "capability-cache"
            ),
            packet_network_allowlist=[
                str(item) for item in (work_order.get("network_read_allowlist") or [])
            ],
        )
        runner_profile = runner_profiles_mod.resolve_profile(
            str(work_order.get("runner_profile") or "default"),
            provider=self.runner_id,
        )
        runner_profiles_mod.verify_profile_integrity(runner_profile)
        effort_attestation = runner_profiles_mod.verify_effort_attestation(
            runner_profile
        )
        if effort_attestation is not None:
            runner_profile = dict(runner_profile)
            runner_profile["effort_attestation"] = effort_attestation
        run_binding = capability_binding_mod.ensure_run_binding(
            canonical_repo,
            str(work_order.get("run_id") or ""),
            capability_resolution,
            runner_profile,
            allow_create=bool(work_order.get("allow_capability_binding_create", True)),
        )
        capability_receipt = capabilities_mod.write_resolution_receipt(
            canonical_repo,
            str(work_order.get("run_id") or ""),
            role,
            attempt_id,
            capability_resolution,
            run_binding=run_binding,
            runner_profile=runner_profile,
        )
        effective_work_order = dict(work_order)
        effective_work_order["capability_resolution"] = capabilities_mod.public_summary(
            capability_resolution
        )
        effective_work_order["capability_receipt"] = str(capability_receipt)
        effective_work_order["capability_binding_sha256"] = run_binding["binding_sha256"]
        effective_work_order["runner_profile_resolution"] = runner_profiles_mod.public_summary(
            runner_profile
        )
        payload = json.dumps(effective_work_order, indent=2, sort_keys=True)
        prompt = (
            role_contract
            + "\n\n# SUPERVISOR WORK ORDER\n"
            + "You are running as one fresh unattended semantic pass. "
              "The deterministic core already claimed and prepared the pass. "
              "Do not call claim, prepare, finalize, push, merge, deploy, or create remotes. "
              "Use the exact paths and identities below. Complete the source work (builder) "
              "or exact-SHA assessment (reviewer). The supplied semantic artifact may sit "
              "outside restricted built-in file-tool scope; write that artifact with sandboxed "
              "Bash when needed. Do not widen access. Protected paths in the sealed work order "
              "are immutable; a broad allowed parent never overrides a protected child. "
              "Then stop.\n\n"
            + payload
        )
        provenance_path = _write_semantic_prompt_provenance(
            work_order=work_order,
            effective_work_order=effective_work_order,
            prompt=prompt,
            role_contract=role_contract,
        )
        effective_work_order["semantic_prompt_provenance"] = str(provenance_path)

        claude_bin = os.environ.get("OFLOOP_CLAUDE_BIN", "claude")
        pass_budget_raw = work_order.get("max_budget_usd")
        pass_budget: float | None = None
        if pass_budget_raw is not None:
            try:
                pass_budget = float(pass_budget_raw)
            except (TypeError, ValueError) as exc:
                raise capabilities_mod.CapabilityResolutionError(
                    "invalid supervisor per-pass model budget"
                ) from exc
            if not math.isfinite(pass_budget) or pass_budget <= 0:
                raise capabilities_mod.CapabilityResolutionError(
                    "supervisor per-pass model budget must be finite and positive"
                )
        extra = shlex.split(os.environ.get("OFLOOP_CLAUDE_EXTRA_ARGS", ""))
        _validate_claude_extra_args(extra)
        # Tool availability is product authority, not an environment-tunable
        # convenience. Reviewers structurally lack Edit/Write/NotebookEdit.
        allowed_tools = (
            CLAUDE_BUILDER_TOOLS if role == "builder" else CLAUDE_REVIEWER_TOOLS
        )
        secure_settings = _semantic_worker_settings(
            canonical_repo=canonical_repo,
            run_id=str(work_order.get("run_id") or ""),
            role=role,
            worktree=worktree,
            semantic_path=semantic_path,
            network_read_allowlist=[
                str(item) for item in (work_order.get("network_read_allowlist") or [])
            ],
            capability_resolution=capability_resolution,
        )
        # --restricted is the native shared-machine isolation boundary.
        # dontAsk + explicit --allowedTools means there are no human permission
        # prompts: capabilities inside the sealed set run, everything else is
        # denied. The Bash sandbox auto-allows contained commands.
        #
        # Pipe the prompt via stdin. Passing it as an argv string lets Claude
        # CLI mis-parse leading `---` (YAML frontmatter in the role file) as
        # an unknown option. stdin is the supported, robust path.
        cmd = [
            claude_bin,
            "-p",
            "--output-format",
            "json",
            "--restricted",
            "--permission-mode",
            "dontAsk",
            "--no-chrome",
            "--no-session-persistence",
            "--strict-mcp-config",
            "--mcp-config",
            # Claude 2.1.251+ rejects the bare ``{}`` form: ``--strict-mcp-config``
            # requires a ``mcpServers`` record. Declare an explicitly empty
            # one to keep the inherited-MCP surface empty without tripping
            # Claude's MCP-config validator.
            json.dumps({"mcpServers": {}}, separators=(",", ":"), sort_keys=True),
            "--plugin-dir",
            str(_source_root()),
            *(
                ["--model", str(runner_profile["model"])]
                if runner_profile.get("model") else []
            ),
            *(
                ["--effort", str(runner_profile["effort"])]
                if runner_profile.get("effort") else []
            ),
            *(
                ["--max-budget-usd", f"{pass_budget:.12g}"]
                if pass_budget is not None else []
            ),
            *extra,
            "--settings",
            json.dumps(secure_settings, separators=(",", ":"), sort_keys=True),
            "--tools",
            allowed_tools,
            "--allowedTools",
            allowed_tools,
        ]
        if durable_files is not None:
            out_path, err_path = durable_files
            _ensure_private_dir(out_path.parent)
            stdout_fh = out_path.open("w", encoding="utf-8")
            stderr_fh = err_path.open("w", encoding="utf-8")
            _ensure_private_file_mode(out_path)
            _ensure_private_file_mode(err_path)
        else:
            stdout_fh = subprocess.PIPE
            stderr_fh = subprocess.PIPE

        worker_env = runtime_env.hermetic_subprocess_env(
            canonical_repo,
            str(work_order.get("run_id") or ""),
            role,
            capability_environment=dict(capability_resolution.get("environment") or {}),
            path_prepend=list(capability_resolution.get("path_prepend") or []),
        )
        # Claude-native subprocess scrub: keep model authentication available to
        # the Claude process itself while stripping Anthropic/cloud credentials
        # from Bash children. This also forces filesystem isolation to remain on.
        worker_env["CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"] = "1"
        privileged_names = sorted(
            str(item.get("name"))
            for item in (capability_resolution.get("resolved") or [])
            if isinstance(item, dict) and item.get("privileged") is True
        )
        worker_env["OFLOOP_PRIVILEGED_CAPABILITIES"] = ",".join(privileged_names)
        docker_brokers = [
            str(item.get("executable"))
            for item in (capability_resolution.get("resolved") or [])
            if isinstance(item, dict) and item.get("name") == "container.docker"
        ]
        worker_env["OFLOOP_CONTAINER_BROKER_EXECUTABLE"] = (
            docker_brokers[0] if len(docker_brokers) == 1 else ""
        )

        # Do not expose ~/.gitconfig merely so an unattended builder can commit.
        # Give semantic Git a deterministic bot identity and disable terminal
        # credential prompting/global config discovery.
        worker_env["GIT_CONFIG_GLOBAL"] = os.devnull
        worker_env["GIT_CONFIG_NOSYSTEM"] = "1"
        worker_env["GIT_TERMINAL_PROMPT"] = "0"
        worker_env["GIT_AUTHOR_NAME"] = "OwnFramework Loop"
        worker_env["GIT_AUTHOR_EMAIL"] = "loop@localhost"
        worker_env["GIT_COMMITTER_NAME"] = "OwnFramework Loop"
        worker_env["GIT_COMMITTER_EMAIL"] = "loop@localhost"

        # Authority-bearing host/profile bytes are rechecked immediately before
        # child creation. The child is still held behind the durable release
        # gate, so any drift here produces zero model calls.
        capabilities_mod.verify_resolution_integrity(capability_resolution)
        runner_profiles_mod.verify_profile_integrity(runner_profile)
        current_effort_attestation = runner_profiles_mod.verify_effort_attestation(
            runner_profile
        )
        if current_effort_attestation != runner_profile.get("effort_attestation"):
            raise runner_profiles_mod.RunnerProfileError(
                "runner effort attestation changed after run binding"
            )
        capability_binding_mod.verify_run_binding(
            canonical_repo,
            str(work_order.get("run_id") or ""),
            capability_resolution,
            runner_profile,
        )

        release_r, release_w = os.pipe()
        os.set_inheritable(release_r, True)
        gated_cmd = [
            sys.executable, "-c", _WORKER_RELEASE_GATE_CODE,
            str(release_r), *cmd,
        ]
        try:
            proc = subprocess.Popen(
                gated_cmd,
                cwd=str(worktree),
                stdin=subprocess.PIPE,
                stdout=stdout_fh,
                stderr=stderr_fh,
                text=True,
                start_new_session=True,
                env=worker_env,
                pass_fds=(release_r,),
            )
        except OSError as exc:
            try:
                os.close(release_r)
            except OSError:
                pass
            try:
                os.close(release_w)
            except OSError:
                pass
            if durable_files is not None:
                stdout_fh.close()  # type: ignore[union-attr]
                stderr_fh.close()  # type: ignore[union-attr]
            raise WorkerLaunchError(
                f"semantic worker launch failed before child creation: {exc}"
            ) from exc
        finally:
            try:
                os.close(release_r)
            except OSError:
                pass

        # The child is alive but cannot exec the semantic provider until exact
        # ownership is durably published by on_start. Any ordinary exception
        # before the release byte is written is therefore provably pre-provider,
        # even if PID publication already committed.
        try:
            if on_start is not None:
                on_start(int(proc.pid), role)
            os.write(release_w, b"1")
        except BaseException as exc:
            try:
                os.close(release_w)
            except OSError:
                pass
            _terminate_group(proc)
            if durable_files is not None:
                stdout_fh.close()  # type: ignore[union-attr]
                stderr_fh.close()  # type: ignore[union-attr]
            if isinstance(exc, (KeyboardInterrupt, SystemExit)):
                raise
            if isinstance(exc, WorkerLaunchError):
                raise
            raise WorkerLaunchError(
                "semantic worker failed before provider release: "
                f"{type(exc).__name__}: {exc}"
            ) from exc
        finally:
            try:
                os.close(release_w)
            except OSError:
                pass

        timed_out = False
        # Use communicate(input=prompt) to feed stdin in a portable way
        # across Python 3.12+. The previous manual stdin.write()+close()
        # pattern was not portable: on some CPython 3.12 builds
        # communicate() reliably raised ValueError after manual stdin
        # close due to tightened pipe-close ordering.
        try:
            stdout_data, stderr_data = proc.communicate(
                input=prompt, timeout=int(timeout_seconds)
            )
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                stdout_data, stderr_data = proc.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                stdout_data, stderr_data = proc.communicate()
        except BaseException:
            _terminate_group(proc)
            if durable_files is not None:
                stdout_fh.close()  # type: ignore[union-attr]
                stderr_fh.close()  # type: ignore[union-attr]
            raise

        if durable_files is not None:
            # Close our handles; the child holds its own dup until exit.
            try:
                stdout_fh.close()  # type: ignore[union-attr]
            except Exception:
                pass
            try:
                stderr_fh.close()  # type: ignore[union-attr]
            except Exception:
                pass
            out_path, err_path = durable_files
            envelope_error = ""
            try:
                # The complete durable provider envelope is authoritative for
                # parsing and usage extraction, but commissioned unattended
                # execution must not read an unbounded file into supervisor
                # memory. The ceiling remains far above the diagnostic limit.
                stdout_data = _read_durable_provider_envelope(out_path)
            except ValueError as exc:
                stdout_data = ""
                envelope_error = str(exc)
            except Exception:
                stdout_data = ""
                envelope_error = "claude provider envelope could not be read"
            try:
                stderr_data = _read_durable_diagnostic_tail(err_path)
            except Exception:
                stderr_data = ""

        if timed_out:
            if durable_files is not None and envelope_error:
                stderr_data = (stderr_data or "") + "\n" + envelope_error
            return RunnerResult(
                ok=False,
                returncode=124,
                cost_usd=0.0,
                stdout=(stdout_data or "")[-RUNNER_DIAGNOSTIC_MAX_CHARS:],
                stderr=((stderr_data or "") + "\nclaude runner timed out")[-RUNNER_DIAGNOSTIC_MAX_CHARS:],
                pid=int(proc.pid),
                cost_known=False,
            )

        if durable_files is not None and envelope_error:
            return RunnerResult(
                ok=False,
                returncode=int(proc.returncode or 0),
                cost_usd=0.0,
                stdout="",
                stderr=((stderr_data or "") + "\n" + envelope_error)[-RUNNER_DIAGNOSTIC_MAX_CHARS:],
                pid=int(proc.pid),
                cost_known=False,
                tokens_known=False,
            )

        cost = 0.0
        cost_known = False
        input_tokens = 0
        output_tokens = 0
        cache_read_tokens = 0
        cache_creation_tokens = 0
        tokens_known = False
        effective_model = ""
        model_usage_json = ""
        parsed: dict[str, Any] | None = None
        try:
            data = json.loads(stdout_data or "")
        except json.JSONDecodeError:
            data = None
        if isinstance(data, dict):
            parsed = data
            # The EFFECTIVE model the provider PROVABLY reported (distinct
            # from the requested profile model); empty when not provable.
            effective_model = _extract_effective_model(data)
            # The FULL provider-reported usage is preserved regardless.
            model_usage_json = _extract_model_usage_json(data)
            # Telemetry extraction degrades independently: a malformed cost
            # or usage value must demote that TELEMETRY to unknown, never
            # discard the semantic result envelope itself (which would turn
            # a completed pass into a duplicate model call).
            if "total_cost_usd" in data:
                try:
                    candidate_cost = float(data.get("total_cost_usd"))
                except (TypeError, ValueError):
                    candidate_cost = None
                if (
                    candidate_cost is not None
                    and math.isfinite(candidate_cost)
                    and candidate_cost >= 0
                ):
                    cost = candidate_cost
                    cost_known = True
            usage = data.get("usage")
            if isinstance(usage, dict):
                token_keys = (
                    ("input_tokens", "input_tokens"),
                    ("output_tokens", "output_tokens"),
                    ("cache_read_tokens", "cache_read_input_tokens"),
                    ("cache_creation_tokens", "cache_creation_input_tokens"),
                )
                values: dict[str, int] = {}
                usage_valid = False
                usage_malformed = False
                for target, source in token_keys:
                    if source not in usage:
                        values[target] = 0
                        continue
                    try:
                        candidate = int(usage.get(source) or 0)
                    except (TypeError, ValueError):
                        usage_malformed = True
                        break
                    if candidate < 0:
                        usage_malformed = True
                        break
                    values[target] = candidate
                    usage_valid = True
                if usage_valid and not usage_malformed:
                    input_tokens = values["input_tokens"]
                    output_tokens = values["output_tokens"]
                    cache_read_tokens = values["cache_read_tokens"]
                    cache_creation_tokens = values["cache_creation_tokens"]
                    tokens_known = True

        # Treat Claude as success when its structured JSON output says
        # is_error is false AND there is a substantive result. Claude CLI
        # may exit non-zero for warnings (e.g. unrecognized model warnings)
        # while still producing a valid result envelope. The semantic
        # completion check + deterministic finalizer are the real authority.
        claude_ok = False
        if parsed is not None:
            if parsed.get("is_error") is False:
                claude_ok = True
            elif "is_error" not in parsed and (
                parsed.get("result") or parsed.get("subtype") == "success"
            ):
                claude_ok = True

        return RunnerResult(
            ok=bool(claude_ok and (parsed is not None)),
            returncode=int(proc.returncode or 0),
            cost_usd=cost,
            stdout=(stdout_data or "")[-RUNNER_DIAGNOSTIC_MAX_CHARS:],
            stderr=(stderr_data or "")[-RUNNER_DIAGNOSTIC_MAX_CHARS:],
            pid=int(proc.pid),
            cost_known=cost_known,
            input_tokens=input_tokens,
            output_tokens=output_tokens,
            cache_read_tokens=cache_read_tokens,
            cache_creation_tokens=cache_creation_tokens,
            tokens_known=tokens_known,
            effective_model=effective_model,
            model_usage_json=model_usage_json,
        )


# Vendor-neutral runner registry.  The canonical implementation lives
# in supervisor_runner_registry.py so the registry's authority is
# explicit (this module owns the runner contract; this module also
# owns ClaudeCodeRunner itself).  We re-export the registry
# internals here so existing call sites within supervisor.py keep
# working without an import-site rewrite.
from . import supervisor_runner_registry as _runner_registry_mod
_RUNNER_REGISTRY = _runner_registry_mod._RUNNER_REGISTRY


def register_runner(cls: type) -> type:
    return _runner_registry_mod.register_runner(cls)


def registered_runner_ids() -> tuple[str, ...]:
    return _runner_registry_mod.registered_runner_ids()


def _runner(name: str):
    return _runner_registry_mod.get_runner(name)


def _runner_preflight(name: str) -> RunnerReadiness:
    return _runner_registry_mod.runner_preflight(name)


@_runner_registry_mod.register_runner
class _RegisteredClaudeCodeRunner(ClaudeCodeRunner):
    runner_id = "claude-code"


def _classify_runner_failure(result: RunnerResult) -> tuple[str, str]:
    """Classify operational runner failure without interpreting engineering truth.

    Classification only selects retry/quarantine policy. It can never alter
    packet authority, candidate identity, checkpoint state, or review verdict.
    """
    text = f"{result.stderr}\n{result.stdout}".lower()
    if result.returncode == 124 or "runner timed out" in text:
        return "timeout", "runner_timeout"

    budget_markers = (
        "max budget", "max_budget_usd", "budget limit",
        "budget exceeded", "maximum budget", "reached the budget",
    )
    if any(marker in text for marker in budget_markers):
        return "usage_ceiling", "pass_budget_exhausted"

    configuration_markers = (
        "not authenticated",
        "authentication failed",
        "invalid api key",
        "invalid_api_key",
        "unauthorized",
        "forbidden",
        "login required",
        "command not found",
        "no such file or directory",
    )
    if result.returncode in {126, 127} or any(
        marker in text for marker in configuration_markers
    ):
        return "configuration", "runner_configuration_failure"

    transient_markers = (
        "rate limit",
        "rate-limit",
        "too many requests",
        "429",
        "overloaded",
        "capacity",
        "temporarily unavailable",
        "service unavailable",
        "bad gateway",
        "gateway timeout",
        "502",
        "503",
        "504",
        "connection reset",
        "connection refused",
        "network error",
        "network unavailable",
        "econnreset",
        "etimedout",
        "upstream",
    )
    if any(marker in text for marker in transient_markers):
        return "transient", "runner_transient_failure"
    return "runner", "runner_unclassified_failure"


def _classify_exception(exc: BaseException) -> tuple[str, str]:
    if isinstance(exc, WorkerLaunchError):
        return "configuration", "worker_launch_failed"
    if isinstance(exc, capability_binding_mod.CapabilityBindingError):
        return "configuration", "capability_binding_failed"
    if isinstance(exc, runner_profiles_mod.RunnerProfileError):
        return "configuration", "runner_profile_resolution_failed"
    if isinstance(exc, capabilities_mod.CapabilityResolutionError):
        return "configuration", "capability_resolution_failed"
    if isinstance(exc, dispatch_mod.SemanticResultIncomplete):
        if exc.retryable:
            return "runner", "semantic_result_incomplete"
        return "invariant", "semantic_result_not_finalizable"
    if isinstance(exc, dispatch_mod.DispatchError):
        return "invariant", "dispatch_refused"
    if isinstance(exc, (FileNotFoundError, PermissionError)):
        return "configuration", type(exc).__name__
    if isinstance(exc, (TimeoutError, ConnectionError)):
        return "transient", type(exc).__name__
    message = str(exc).lower()
    if (
        "not registered" in message
        or "runner prompt missing" in message
        or "prepared worktree missing" in message
    ):
        return "configuration", type(exc).__name__
    return "supervisor", type(exc).__name__


def _apply_failure_policy(
    conn: sqlite3.Connection,
    *,
    job_id: int,
    failure_class: str,
    failure_reason: str,
    detail: str,
    total_cost_usd: float | None = None,
) -> dict[str, Any]:
    """Apply operational retry policy while leaving engineering state untouched."""
    row = conn.execute("SELECT * FROM jobs WHERE id=?", (int(job_id),)).fetchone()
    if row is None:
        raise RuntimeError(f"supervisor job missing during failure policy: {job_id}")

    immediate = failure_class in {
        "configuration",
        "invariant",
        "usage_unknown",
        "timeout_usage_unknown",
        "usage_ceiling",
    }
    infra_failures = int(row["infra_failures"] or 0)
    transient_failures = int(row["transient_failures"] or 0)
    transient_recovery_cycles = int(row["transient_recovery_cycles"] or 0)

    if failure_class == "transient":
        transient_failures += 1
        ceiling = int(row["max_transient_failures"] or 0)
        max_cycles = int(row["max_transient_recovery_cycles"] or 0)
        threshold_hit = ceiling > 0 and transient_failures >= ceiling
        if threshold_hit and transient_recovery_cycles < max_cycles:
            # Open a bounded provider circuit instead of requiring an operator
            # resume. Cost/token/wall-clock ledgers are preserved and keep
            # bounding the run; only the transient streak is cooled down.
            transient_recovery_cycles += 1
            transient_failures = 0
            quarantined = False
            backoff = 600.0
        else:
            quarantined = threshold_hit
            streak = transient_failures
            backoff = min(300.0, float(5 * (2 ** max(0, streak - 1))))
    elif immediate:
        # A hard non-transient refusal ends any active transient streak.
        transient_failures = 0
        quarantined = True
        streak = 1
        backoff = 0.0
    else:
        infra_failures += 1
        ceiling = int(row["max_infra_failures"] or 0)
        quarantined = ceiling > 0 and infra_failures >= ceiling
        streak = infra_failures
        backoff = min(300.0, float(5 * (2 ** max(0, streak - 1))))

    status_value = "QUARANTINED" if quarantined else "BACKOFF"
    next_attempt = 0.0 if quarantined else time.time() + backoff
    _update_job(
        conn,
        int(job_id),
        status_value=status_value,
        infra_failures=infra_failures,
        transient_failures=transient_failures,
        transient_recovery_cycles=transient_recovery_cycles,
        total_cost_usd=total_cost_usd,
        last_error=detail[-4000:],
        last_failure_class=failure_class,
        last_failure_reason=failure_reason,
        next_attempt_at=next_attempt,
    )
    return {
        "status": status_value,
        "failure_class": failure_class,
        "failure_reason": failure_reason,
        "infra_failures": infra_failures,
        "transient_failures": transient_failures,
        "transient_recovery_cycles": transient_recovery_cycles,
        "max_transient_recovery_cycles": int(row["max_transient_recovery_cycles"] or 0),
        "circuit_opened": bool(
            failure_class == "transient"
            and not quarantined
            and backoff == 600.0
            and transient_failures == 0
        ),
        "backoff_seconds": 0.0 if quarantined else backoff,
    }


def _take_next_job(conn: sqlite3.Connection) -> sqlite3.Row | None:
    """Thin delegate to ``supervisor_claims._take_next_job``."""
    return _claims_mod._take_next_job(conn)


def _reserve_semantic_attempt(
    conn: sqlite3.Connection,
    *,
    job: sqlite3.Row,
    role: str,
) -> tuple[str, dict[str, Any]]:
    """Thin delegate to ``supervisor_attempts._reserve_semantic_attempt``."""
    return _attempts_mod._reserve_semantic_attempt(conn, job=job, role=role)


def _set_worker_pid(
    conn: sqlite3.Connection,
    job_id: int,
    pid: int,
    role: str,
    *,
    out_path: Path | None = None,
    err_path: Path | None = None,
    attempt_id: str | None = None,
    deadline_at: float | None = None,
) -> None:
    """Thin delegate to ``supervisor_attempts._set_worker_pid``."""
    _attempts_mod._set_worker_pid(
        conn, job_id, pid, role,
        out_path=out_path, err_path=err_path,
        attempt_id=attempt_id, deadline_at=deadline_at,
    )


def _update_job(
    conn: sqlite3.Connection,
    job_id: int,
    *,
    status_value: str,
    infra_failures: int | None = None,
    transient_failures: int | None = None,
    transient_recovery_cycles: int | None = None,
    total_cost_usd: float | None = None,
    last_error: str | None = None,
    last_failure_class: str | None = None,
    last_failure_reason: str | None = None,
    next_attempt_at: float | None = None,
) -> None:
    """Thin delegate to ``supervisor_db._update_job``.

    ``_update_job`` is the generic durable job-state transition
    primitive.  Canonical owner is ``supervisor_db`` (DB layer);
    the supervisor facade re-exports it for backward compatibility.
    """
    _db_mod._update_job(
        conn,
        job_id,
        status_value=status_value,
        infra_failures=infra_failures,
        transient_failures=transient_failures,
        transient_recovery_cycles=transient_recovery_cycles,
        total_cost_usd=total_cost_usd,
        last_error=last_error,
        last_failure_class=last_failure_class,
        last_failure_reason=last_failure_reason,
        next_attempt_at=next_attempt_at,
    )


def _ensure_execution_started(conn: sqlite3.Connection, job_id: int) -> float:
    """Thin delegate to ``supervisor_attempts._ensure_execution_started``."""
    return _attempts_mod._ensure_execution_started(conn, job_id)


def _maybe_complete_semantic_artifact(
    *,
    conn: sqlite3.Connection,
    work_order: dict[str, Any],
    semantic_reason: str,
    job_id: int,
) -> bool:
    """Thin delegate to ``supervisor_attempts._maybe_complete_semantic_artifact``."""
    return _attempts_mod._maybe_complete_semantic_artifact(
        conn=conn, work_order=work_order,
        semantic_reason=semantic_reason, job_id=job_id,
    )


def _publish_acceptance_for_ready_artifact(
    *,
    conn: sqlite3.Connection,
    work_order: dict[str, Any],
    job_id: int,
) -> None:
    """Thin delegate to ``supervisor_attempts._publish_acceptance_for_ready_artifact``."""
    _attempts_mod._publish_acceptance_for_ready_artifact(
        conn=conn, work_order=work_order, job_id=job_id,
    )


def run_one(*, db_path: Path | None = None, timeout_seconds: int = 0) -> dict[str, Any]:
    """Execute at most one semantic BUILD/REVIEW action."""
    db = db_path or default_db_path()
    with _managed_connect(db) as conn:
        from . import supervisor_claims as _claims_mod
        job = _claims_mod._take_next_job(conn)
        if job is None:
            return {"schema": SCHEMA, "ok": True, "action": "IDLE", "db_path": str(db)}

        _register_local_execution(int(job["id"]))

        # RUNTIME-GENERATION CONTRACT. A job binds the generation that
        # enrolled it; executing it under a different generation is a
        # silent runtime switch of a sealed run and fails closed toward
        # quarantine. Legacy rows with no recorded binding are ambiguous
        # unfinished executions and fail closed; migration to a new generation
        # is an explicit operator act: re-enqueue or resume.
        bound_generation = str(job["runtime_generation"] or "")
        try:
            serving_generation = _current_runtime_generation()
        except Exception as exc:
            _update_job(
                conn,
                job["id"],
                status_value="QUARANTINED",
                last_error=(
                    "serving runtime generation could not be proven; refusing "
                    f"semantic execution: {type(exc).__name__}: {exc}"
                ),
                last_failure_class="runtime_generation_unavailable",
                last_failure_reason="runtime_generation_unavailable",
                next_attempt_at=0,
            )
            return {
                "schema": SCHEMA,
                "ok": False,
                "action": "QUARANTINED",
                "job_id": job["id"],
                "reason": "runtime_generation_unavailable",
                "bound_runtime_generation": bound_generation,
            }
        if bound_generation and bound_generation != serving_generation:
            _update_job(
                conn,
                job["id"],
                status_value="QUARANTINED",
                last_error=(
                    "runtime generation mismatch: job bound to "
                    f"{bound_generation}, serving runtime is "
                    f"{serving_generation}; refusing silent generation "
                    "switch — operator migration required "
                    "(supervisor resume rebinds the run)"
                ),
                last_failure_class="runtime_generation_mismatch",
                last_failure_reason="runtime_generation_mismatch",
                next_attempt_at=0,
            )
            return {
                "schema": SCHEMA,
                "ok": False,
                "action": "QUARANTINED",
                "job_id": job["id"],
                "reason": "runtime_generation_mismatch",
                "bound_runtime_generation": bound_generation,
                "serving_runtime_generation": serving_generation,
            }
        if not bound_generation:
            _update_job(
                conn,
                job["id"],
                status_value="QUARANTINED",
                last_error=(
                    "runtime generation is unbound for an unfinished legacy job; "
                    "refusing implicit adoption under a new serving runtime — "
                    "operator re-enqueue/resume is required"
                ),
                last_failure_class="runtime_generation_unbound",
                last_failure_reason="runtime_generation_unbound",
                next_attempt_at=0,
            )
            return {
                "schema": SCHEMA,
                "ok": False,
                "action": "QUARANTINED",
                "job_id": job["id"],
                "reason": "runtime_generation_unbound",
                "bound_runtime_generation": "",
                "serving_runtime_generation": serving_generation,
            }

        attempt_id: str | None = None
        try:
            work_order = dispatch_mod.claim_next(
                canonical_repo=Path(job["repo"]),
                run_id=str(job["run_id"]),
            )
            decision = str(work_order.get("decision") or "")
            if decision == "TERMINAL":
                _update_job(conn, job["id"], status_value="DONE", last_error=None)
                cache_cleanup = _cleanup_terminal_runtime_cache(
                    Path(job["repo"]), str(job["run_id"])
                )
                return {
                    "schema": SCHEMA,
                    "ok": True,
                    "action": "TERMINAL",
                    "job_id": job["id"],
                    "work_order": work_order,
                    "runtime_cache_cleanup": cache_cleanup,
                }
            if decision == "WAIT":
                # Bounded next-attempt delay so a recurring WAIT cannot
                # busy-spin the durable execution clock. The delay is short
                # (5s default) to remain responsive to genuine transitions
                # but long enough that a continuously-WAIT run does not
                # spam the supervisor stdout with IDLE/WAIT events.
                wait_seconds = 5.0
                _update_job(
                    conn,
                    job["id"],
                    status_value="QUEUED",
                    last_error=None,
                    next_attempt_at=time.time() + wait_seconds,
                )
                return {
                    "schema": SCHEMA,
                    "ok": True,
                    "action": "WAIT",
                    "job_id": job["id"],
                    "wait_seconds": wait_seconds,
                    "work_order": work_order,
                }

            semantic_ready, semantic_reason = dispatch_mod.semantic_result_ready(
                work_order
            )
            if not semantic_ready:
                # v0.9.9-h: deterministic semantic-result completion recovery.
                #
                # When a paid semantic pass exits with the engineering work
                # already durably complete (clean worktree, candidate HEAD
                # exists on the right branch, all fixed-identity fields intact)
                # but the typed JSON contract is still unpopulated, the
                # core fills the deterministic fillable fields itself rather
                # than burning another full provider call to redo engineering
                # that already exists.
                completed = _maybe_complete_semantic_artifact(
                    conn=conn, work_order=work_order, semantic_reason=semantic_reason,
                    job_id=int(job["id"]),
                )
                if completed:
                    # v0.9.9-h: completion also publishes the latest
                    # attempt's `semantic_accepted` flag inside
                    # `_maybe_complete_semantic_artifact` so the
                    # provenance gate below recognizes the zero-cost
                    # replay as the durable accepted artifact.
                    semantic_ready, semantic_reason = dispatch_mod.semantic_result_ready(work_order)
            if semantic_ready:
                # v0.9.9-h: when the artifact is already valid (either
                # because completion filled it, or because a prior tick
                # already completed it but acceptance was not yet
                # published), make sure the latest attempt's
                # `semantic_accepted` flag is recorded before the gate
                # inspects it. Best-effort: any publish failure is
                # surfaced by the gate's structured replay rejection.
                _publish_acceptance_for_ready_artifact(
                    conn=conn, work_order=work_order, job_id=int(job["id"]),
                )
                replay_attempt_id = str(job["latest_attempt_id"] or "")
                replay_ok, replay_reason, _receipt = _attempt_provenance_gate(
                    conn,
                    job=job,
                    work_order=work_order,
                    attempt_id=replay_attempt_id,
                )
                if not replay_ok:
                    _update_job(
                        conn,
                        job["id"],
                        status_value="QUARANTINED",
                        last_error=(
                            "semantic artifact exists but its durable launch "
                            f"provenance cannot be certified: {replay_reason}"
                        ),
                        last_failure_class="replay_provenance",
                        last_failure_reason=replay_reason,
                        next_attempt_at=0,
                    )
                    return {
                        "schema": SCHEMA,
                        "ok": False,
                        "action": "QUARANTINED",
                        "job_id": job["id"],
                        "reason": replay_reason,
                        "semantic_replay": True,
                    }
                finalized = dispatch_mod.finalize_work_order(work_order)
                _update_job(
                    conn,
                    job["id"],
                    status_value="QUEUED",
                    infra_failures=0,
                    transient_failures=0,
                    transient_recovery_cycles=0,
                    last_error=None,
                    last_failure_class=None,
                    last_failure_reason=None,
                    next_attempt_at=0,
                )
                return {
                    "schema": SCHEMA,
                    "ok": True,
                    "action": f"{decision}_REPLAY_FINALIZED",
                    "job_id": job["id"],
                    "cost_usd": 0.0,
                    "semantic_replay": True,
                    "finalized": finalized,
                }

            # A retryable semantic-shape failure belongs to the same claimed
            # engineering pass, but its model-authored envelope is poisoned.
            # Preserve that envelope privately and reseed the exact same
            # canonical path before launching a fresh provider process. Resume
            # intentionally clears operational error fields, so consult the
            # durable prior attempt row as well as the job projection.
            prior_attempt_id = str(job["latest_attempt_id"] or "")
            prior_attempt_reason = ""
            if prior_attempt_id:
                prior_attempt = conn.execute(
                    "SELECT status, failure_reason FROM semantic_attempts "
                    "WHERE attempt_id=? AND job_id=?",
                    (prior_attempt_id, int(job["id"])),
                ).fetchone()
                if prior_attempt is not None:
                    prior_attempt_reason = str(prior_attempt["failure_reason"] or "")
            prior_shape_failure = (
                prior_attempt_id
                and prior_attempt_reason == "semantic_result_incomplete"
            ) or str(job["last_failure_reason"] or "") == "semantic_result_incomplete"
            if (
                not semantic_ready
                and semantic_reason in dispatch_mod._RETRYABLE_SEMANTIC_RESULT_REASONS
                and prior_shape_failure
            ):
                dispatch_mod.reseed_semantic_artifact_for_retry(
                    work_order,
                    previous_attempt_id=prior_attempt_id,
                )

            readiness = _runner_preflight(str(job["runner"]))
            if not readiness.ready:
                if readiness.classification == "environment_wait":
                    retry_after = max(5.0, float(readiness.retry_after_seconds))
                    _update_job(
                        conn,
                        job["id"],
                        status_value="BACKOFF",
                        last_error=readiness.detail,
                        last_failure_class=readiness.classification,
                        last_failure_reason=readiness.reason,
                        next_attempt_at=time.time() + retry_after,
                    )
                    return {
                        "schema": SCHEMA,
                        "ok": True,
                        "action": "RUNNER_WAIT",
                        "job_id": job["id"],
                        "reason": readiness.reason,
                        "retry_after_seconds": retry_after,
                        "semantic_attempt_created": False,
                        "execution_clock_started": False,
                    }
                policy = _apply_failure_policy(
                    conn,
                    job_id=int(job["id"]),
                    failure_class=readiness.classification,
                    failure_reason=readiness.reason,
                    detail=readiness.detail,
                    total_cost_usd=float(job["total_cost_usd"] or 0.0),
                )
                return {
                    "schema": SCHEMA,
                    "ok": False,
                    "action": policy["status"],
                    "job_id": job["id"],
                    "reason": readiness.reason,
                    "semantic_attempt_created": False,
                    "execution_clock_started": False,
                    **policy,
                }

            started_at = _ensure_execution_started(conn, int(job["id"]))
            elapsed = max(0.0, time.time() - started_at)
            max_wall = int(job["max_wall_seconds"] or 0)
            max_cost = float(job["max_total_cost_usd"] or 0.0)
            spent = float(job["total_cost_usd"] or 0.0)
            remaining_cost_budget = _remaining_funded_cost_budget(max_cost, spent)
            if max_cost > 0:
                unknown_cost_attempts = _unknown_cost_attempt_count(
                    conn, int(job["id"])
                )
                if unknown_cost_attempts:
                    _update_job(
                        conn,
                        job["id"],
                        status_value="QUARANTINED",
                        last_error=(
                            "finite cost ceiling cannot be enforced from a known "
                            f"baseline: {unknown_cost_attempts} historical semantic "
                            "attempt(s) have unknown provider cost"
                        ),
                        last_failure_class="usage_unknown",
                        last_failure_reason="historical_cost_unknown",
                        next_attempt_at=0,
                    )
                    return {
                        "schema": SCHEMA,
                        "ok": False,
                        "action": "QUARANTINED",
                        "job_id": job["id"],
                        "reason": "historical_cost_unknown",
                        "unknown_cost_attempts": unknown_cost_attempts,
                    }
            max_tokens = int(job["max_total_tokens"] or 0)
            spent_tokens = (
                int(job["total_input_tokens"] or 0)
                + int(job["total_output_tokens"] or 0)
                + int(job["total_cache_read_tokens"] or 0)
                + int(job["total_cache_creation_tokens"] or 0)
            )
            if max_wall > 0 and elapsed >= max_wall:
                _update_job(
                    conn,
                    job["id"],
                    status_value="QUARANTINED",
                    last_error=f"operational wall-clock ceiling reached: {elapsed:.1f}s >= {max_wall}s",
                    next_attempt_at=0,
                )
                return {
                    "schema": SCHEMA,
                    "ok": False,
                    "action": "QUARANTINED",
                    "job_id": job["id"],
                    "reason": "wall_clock_ceiling",
                    "elapsed_seconds": elapsed,
                    "max_wall_seconds": max_wall,
                }
            if max_cost > 0 and spent >= max_cost:
                _update_job(
                    conn,
                    job["id"],
                    status_value="QUARANTINED",
                    last_error=f"operational model-cost ceiling reached: ${spent:.4f} >= ${max_cost:.4f}",
                    next_attempt_at=0,
                )
                return {
                    "schema": SCHEMA,
                    "ok": False,
                    "action": "QUARANTINED",
                    "job_id": job["id"],
                    "reason": "cost_ceiling",
                    "total_cost_usd": spent,
                    "max_total_cost_usd": max_cost,
                }

            if max_tokens > 0 and spent_tokens >= max_tokens:
                _update_job(
                    conn,
                    job["id"],
                    status_value="QUARANTINED",
                    last_error=(
                        f"operational token ceiling reached: "
                        f"{spent_tokens} >= {max_tokens}"
                    ),
                    last_failure_class="usage_ceiling",
                    last_failure_reason="token_ceiling",
                    next_attempt_at=0,
                )
                return {
                    "schema": SCHEMA,
                    "ok": False,
                    "action": "QUARANTINED",
                    "job_id": job["id"],
                    "reason": "token_ceiling",
                    "observed_total_tokens": spent_tokens,
                    "max_total_tokens": max_tokens,
                }

            role = str(work_order.get("role") or "builder")
            binding_create_allowed = _capability_binding_creation_allowed(
                conn, int(job["id"])
            )
            attempt_id, durable_files = _reserve_semantic_attempt(
                conn, job=job, role=role
            )

            packet_path = state_mod.run_dir(
                Path(str(job["repo"])), str(job["run_id"])
            ) / "WORK_PACKET.md"
            packet_meta, _ = packet_mod.parse_packet_file(packet_path)
            semantic_timeout_seconds = resolve_semantic_timeout(
                packet_meta, timeout_seconds
            )
            # The whole-run wall ceiling must constrain the pass actually
            # launched, not only the between-pass checks: a pass started
            # with one minute of budget left may not run for its full
            # packet timeout. Clamp the pass timeout to the remaining wall
            # budget whenever a wall ceiling is funded.
            if max_wall > 0:
                remaining_wall = max(0, int(max_wall - elapsed))
                semantic_timeout_seconds = min(
                    semantic_timeout_seconds, remaining_wall
                )

            runner_work_order = dict(work_order)
            runner_work_order["attempt_id"] = attempt_id
            runner_work_order["allow_capability_binding_create"] = binding_create_allowed
            if remaining_cost_budget is not None:
                runner_work_order["max_budget_usd"] = remaining_cost_budget
            runner_impl = _runner(str(job["runner"]))
            result = runner_impl.run(
                runner_work_order,
                timeout_seconds=semantic_timeout_seconds,
                on_start=lambda pid, started_role: _set_worker_pid(
                    conn,
                    int(job["id"]),
                    pid,
                    started_role,
                    out_path=durable_files[0],
                    err_path=durable_files[1],
                    attempt_id=attempt_id,
                    deadline_at=time.time() + semantic_timeout_seconds,
                ),
                durable_files=durable_files,
            )
            if not result.cost_known:
                # Cost-telemetry fail-closed applies only while an operator
                # cost ceiling is actually active. Without a ceiling, unknown
                # cost cannot breach any declared budget; the attempt is
                # recorded COST_UNKNOWN at zero and execution continues so an
                # unattended PROGRAM is not stopped by telemetry loss.
                conn.execute(
                    """UPDATE semantic_attempts SET status='COST_UNKNOWN',
                       completed_at=?, returncode=?, cost_known=0
                       WHERE attempt_id=? AND job_id=?""",
                    (time.time(), int(result.returncode), attempt_id, int(job["id"])),
                )
                conn.commit()
                if float(job["max_total_cost_usd"] or 0) > 0:
                    _update_job(
                        conn,
                        job["id"],
                        status_value="QUARANTINED",
                        last_error=(
                            "semantic worker completed without a trustworthy finite "
                            "total_cost_usd while a cost ceiling is active; refusing "
                            "to assume zero cost"
                        ),
                        last_failure_class=(
                            "timeout_usage_unknown"
                            if int(result.returncode) == 124
                            else "usage_unknown"
                        ),
                        last_failure_reason=(
                            "runner_timeout_cost_unknown"
                            if int(result.returncode) == 124
                            else "model_cost_unknown"
                        ),
                        next_attempt_at=0,
                    )
                    return {
                        "schema": SCHEMA,
                        "ok": False,
                        "action": "QUARANTINED",
                        "job_id": job["id"],
                        "reason": "model_cost_unknown",
                        "attempt_id": attempt_id,
                    }

            if int(job["max_total_tokens"] or 0) > 0 and not result.tokens_known:
                # Account the completed attempt exactly once BEFORE the
                # TOKENS_UNKNOWN quarantine. Terminalizing the attempt without
                # accounting would leave cost_accounted=0 forever: a provable
                # provider cost would never reach jobs.total_cost_usd (a funded
                # cost ceiling would then under-count spend across the
                # quarantine/resume cycle), and an unprovable cost would keep
                # the INSERT-default cost_known=1 instead of the honest 0.
                tokens_unknown_total = _account_attempt_cost(
                    conn,
                    job_id=int(job["id"]),
                    attempt_id=attempt_id,
                    cost_usd=float(result.cost_usd),
                    returncode=int(result.returncode),
                    status_value="TOKENS_UNKNOWN",
                    cost_known=result.cost_known,
                    tokens_known=False,
                    effective_model=result.effective_model,
                    model_usage_json=result.model_usage_json,
                )
                conn.execute(
                    """UPDATE semantic_attempts SET
                       failure_class='usage_unknown',
                       failure_reason='token_usage_unknown'
                       WHERE attempt_id=? AND job_id=?""",
                    (attempt_id, int(job["id"])),
                )
                conn.commit()
                _update_job(
                    conn,
                    job["id"],
                    status_value="QUARANTINED",
                    total_cost_usd=tokens_unknown_total,
                    last_error=(
                        "semantic worker completed without trustworthy token usage "
                        "while a token ceiling is enabled"
                    ),
                    last_failure_class="usage_unknown",
                    last_failure_reason="token_usage_unknown",
                    next_attempt_at=0,
                )
                return {
                    "schema": SCHEMA,
                    "ok": False,
                    "action": "QUARANTINED",
                    "job_id": job["id"],
                    "reason": "token_usage_unknown",
                    "attempt_id": attempt_id,
                }

            new_cost = _account_attempt_cost(
                conn,
                job_id=int(job["id"]),
                attempt_id=attempt_id,
                cost_usd=float(result.cost_usd),
                returncode=int(result.returncode),
                status_value=("COMPLETED" if result.cost_known else "COST_UNKNOWN"),
                cost_known=result.cost_known,
                input_tokens=result.input_tokens,
                output_tokens=result.output_tokens,
                cache_read_tokens=result.cache_read_tokens,
                cache_creation_tokens=result.cache_creation_tokens,
                tokens_known=result.tokens_known,
                effective_model=result.effective_model,
                model_usage_json=result.model_usage_json,
            )

            # Strict-profile truth: a profile that REQUESTED an explicit model
            # is certified only when the provider PROVABLY ran that model. A
            # provable substitution — or an unprovable effective model under a
            # strict request — fails closed here. The attempt's cost was
            # already accounted above; the envelope truth (full modelUsage) is
            # preserved in the ledger either way.
            strict_failure_reason = ""
            strict_failure_class = ""
            if bool(getattr(runner_impl, "requires_capability_receipt", False)):
                try:
                    receipt = capabilities_mod.read_resolution_receipt(
                        Path(str(job["repo"])),
                        str(job["run_id"]),
                        role,
                        attempt_id,
                    )
                except capabilities_mod.CapabilityResolutionError:
                    strict_failure_reason = "semantic_attempt_capability_receipt_invalid"
                    strict_failure_class = "invariant"
                else:
                    requested_profile = receipt.get("requested_runner_profile") or {}
                    strict_model = str(requested_profile.get("model") or "")
                    strict_failure_reason = _strict_profile_model_violation(
                        strict_model,
                        result_ok=bool(result.ok),
                        effective_model=str(result.effective_model or ""),
                    )
                    if strict_failure_reason:
                        strict_failure_class = "configuration"

            if not result.ok or strict_failure_reason:
                if strict_failure_reason:
                    failure_class, failure_reason = (
                        strict_failure_class or "configuration", strict_failure_reason,
                    )
                else:
                    failure_class, failure_reason = _classify_runner_failure(result)
                detail = (
                    f"runner rc={result.returncode}: "
                    f"{result.stderr or result.stdout}"
                )[-4000:]
                conn.execute(
                    """UPDATE semantic_attempts SET
                       failure_class=?, failure_reason=?
                       WHERE attempt_id=? AND job_id=?""",
                    (
                        failure_class,
                        failure_reason,
                        attempt_id,
                        int(job["id"]),
                    ),
                )
                conn.commit()
                policy = _apply_failure_policy(
                    conn,
                    job_id=int(job["id"]),
                    failure_class=failure_class,
                    failure_reason=failure_reason,
                    detail=detail,
                    total_cost_usd=new_cost,
                )
                return {
                    "schema": SCHEMA,
                    "ok": False,
                    "action": policy["status"],
                    "job_id": job["id"],
                    "returncode": result.returncode,
                    "cost_usd": result.cost_usd,
                    **policy,
                }

            # A successful provider envelope is not itself replay authority.
            # Prove the exact semantic artifact is structurally ready, then
            # publish an explicit durable entitlement BEFORE deterministic
            # finalization. A crash before this point fails closed; a crash
            # after it may legitimately replay at zero semantic cost.
            #
            # The acceptance publication captures the exact semantic artifact
            # digest and the exact role-specific finalization identity so a
            # subsequent zero-cost replay can re-prove them. Zero-cost replay
            # without identity binding would let a crashed-pending replay
            # operate on different bytes/HEAD than what was accepted.
            acceptance_ready, acceptance_reason = dispatch_mod.semantic_result_ready(
                work_order
            )
            if not acceptance_ready:
                raise dispatch_mod.SemanticResultIncomplete(acceptance_reason)
            acceptance_candidate_sha = _replay_candidate_sha(
                role=role,
                work_order=work_order,
                repo=str(job["repo"] or ""),
                run_id=str(job["run_id"] or ""),
            )
            if not acceptance_candidate_sha:
                raise RuntimeError(
                    f"semantic acceptance cannot resolve candidate SHA for role={role!r}"
                )
            _publish_semantic_acceptance(
                conn,
                job_id=int(job["id"]),
                attempt_id=attempt_id,
                semantic_path=str(work_order.get("semantic_path") or ""),
                candidate_sha=acceptance_candidate_sha,
            )

            finalizer_timeout: int | None = None
            if max_wall > 0:
                elapsed_after_worker = max(0.0, time.time() - started_at)
                remaining_after_worker = int(max_wall - elapsed_after_worker)
                if remaining_after_worker <= 0:
                    _update_job(
                        conn,
                        job["id"],
                        status_value="QUARANTINED",
                        total_cost_usd=new_cost,
                        last_error=(
                            "operational wall-clock ceiling exhausted after semantic "
                            "worker completed; semantic artifact preserved for "
                            "zero-cost replay after explicit operator action"
                        ),
                        last_failure_class="usage_ceiling",
                        last_failure_reason="wall_clock_ceiling_before_finalization",
                        next_attempt_at=0,
                    )
                    return {
                        "schema": SCHEMA,
                        "ok": False,
                        "action": "QUARANTINED",
                        "job_id": job["id"],
                        "reason": "wall_clock_ceiling_before_finalization",
                        "elapsed_seconds": elapsed_after_worker,
                        "max_wall_seconds": max_wall,
                        "semantic_artifact_preserved": True,
                    }
                finalizer_timeout = remaining_after_worker

            if finalizer_timeout is None:
                # Preserve the stable single-argument dispatch surface for
                # unfunded/unbounded runs and test/adapter implementations.
                finalized = dispatch_mod.finalize_work_order(work_order)
            else:
                finalized = dispatch_mod.finalize_work_order(
                    work_order, timeout_seconds=finalizer_timeout
                )
            _update_job(
                conn,
                job["id"],
                status_value="QUEUED",
                infra_failures=0,
                transient_failures=0,
                transient_recovery_cycles=0,
                total_cost_usd=new_cost,
                last_error=None,
                last_failure_class=None,
                last_failure_reason=None,
                next_attempt_at=0,
            )
            return {
                "schema": SCHEMA,
                "ok": True,
                "action": decision,
                "job_id": job["id"],
                "cost_usd": result.cost_usd,
                "finalized": finalized,
            }
        except Exception as exc:
            if attempt_id and isinstance(
                exc,
                (
                    WorkerLaunchError,
                    capabilities_mod.CapabilityResolutionError,
                    capability_binding_mod.CapabilityBindingError,
                    runner_profiles_mod.RunnerProfileError,
                ),
            ):
                _mark_attempt_launch_failed(
                    conn,
                    job_id=int(job["id"]),
                    attempt_id=attempt_id,
                    detail=str(exc),
                    failure_reason=(
                        "capability_binding_failed"
                        if isinstance(exc, capability_binding_mod.CapabilityBindingError)
                        else "runner_profile_resolution_failed"
                        if isinstance(exc, runner_profiles_mod.RunnerProfileError)
                        else "capability_resolution_failed"
                        if isinstance(exc, capabilities_mod.CapabilityResolutionError)
                        else "worker_launch_failed"
                    ),
                )
            elif attempt_id and isinstance(exc, dispatch_mod.SemanticResultIncomplete):
                conn.execute(
                    """UPDATE semantic_attempts SET status='FAILED',
                       failure_class=?, failure_reason=?, completed_at=COALESCE(completed_at, ?)
                       WHERE attempt_id=? AND job_id=?""",
                    (
                        "runner" if exc.retryable else "invariant",
                        "semantic_result_incomplete",
                        time.time(),
                        attempt_id,
                        int(job["id"]),
                    ),
                )
                conn.commit()
            # Completed semantic attempts are accounted transactionally by
            # attempt identity. If an exception happened before completion,
            # stale-worker recovery will inspect the durable attempt/output;
            # never synthesize cost from output digests here.
            current_cost_row = conn.execute(
                "SELECT total_cost_usd FROM jobs WHERE id=?", (job["id"],)
            ).fetchone()
            total_attempted_cost = float(
                (current_cost_row[0] if current_cost_row is not None else 0.0) or 0.0
            )
            failure_class, failure_reason = _classify_exception(exc)
            detail = f"{type(exc).__name__}: {exc}"[-4000:]
            policy = _apply_failure_policy(
                conn,
                job_id=int(job["id"]),
                failure_class=failure_class,
                failure_reason=failure_reason,
                detail=detail,
                total_cost_usd=total_attempted_cost,
            )
            return {
                "schema": SCHEMA,
                "ok": False,
                "action": policy["status"],
                "job_id": job["id"],
                "error": str(exc),
                **policy,
            }


def _scheduler_submission_budget(
    *,
    db_path: Path,
    configured: int,
    local_inflight: int,
) -> int:
    """Thin delegate to ``supervisor_claims._scheduler_submission_budget``."""
    return _claims_mod._scheduler_submission_budget(
        db_path=db_path,
        configured=configured,
        local_inflight=local_inflight,
    )


def serve(
    *,
    db_path: Path | None = None,
    poll_seconds: float = 2.0,
    timeout_seconds: int = 0,
    once: bool = False,
) -> dict[str, Any] | None:
    """Run the durable execution clock. Idle iterations make zero model calls."""
    _load_service_env_file()
    _cleanup_done_runtime_caches(db_path)
    _publish_startup_ready_attestation(db_path)
    if once:
        return run_one(db_path=db_path, timeout_seconds=timeout_seconds)
    last_emit: float = 0.0
    idle_log_interval = max(60.0, float(poll_seconds) * 30)
    # One durable scheduler process owns a bounded pool of execution lanes.
    # SQLite, rather than pool occupancy, remains the capacity authority.
    futures: set[Future[dict[str, Any]]] = set()
    with ThreadPoolExecutor(max_workers=IMPLEMENTATION_MAX_CONCURRENCY) as pool:
        while True:
            db = db_path or default_db_path()
            try:
                with _managed_connect_readonly(db) as read_conn:
                    cfg = read_conn.execute(
                        "SELECT value FROM supervisor_config WHERE key=?",
                        (_CONFIG_MAX_CONCURRENCY,),
                    ).fetchone()
                    configured = _validate_max_concurrency(
                        cfg[0] if cfg is not None else DEFAULT_MAX_CONCURRENCY
                    )
            except (OSError, sqlite3.Error, ValueError):
                configured = DEFAULT_MAX_CONCURRENCY
            # Retire completed lanes and emit their durable result. A failed
            # lane is isolated; the scheduler continues to reconcile others.
            completed = {f for f in futures if f.done()}
            for future in completed:
                futures.remove(future)
                try:
                    event = future.result()
                except Exception as exc:  # pragma: no cover - defensive lane fence
                    event = {"schema": SCHEMA, "ok": False, "action": "LANE_ERROR",
                             "error": f"{type(exc).__name__}: {exc}"}
                action = event.get("action")
                now = time.time()
                if action != "IDLE" or (now - last_emit) >= idle_log_interval:
                    print(json.dumps(event, sort_keys=True), flush=True)
                    last_emit = now
            # SQLite remains authority; this projection only limits pointless
            # idle probes when configured capacity is much larger than demand.
            submit_count = _scheduler_submission_budget(
                db_path=Path(db),
                configured=configured,
                local_inflight=len(futures),
            )
            for _ in range(submit_count):
                futures.add(pool.submit(
                    run_one, db_path=db_path, timeout_seconds=timeout_seconds
                ))
            if not futures and submit_count == 0:
                time.sleep(max(0.25, float(poll_seconds)))
            else:
                time.sleep(max(0.1, min(float(poll_seconds), 1.0)))


def _migrate_quarantined_run_capabilities(
    *,
    canonical_repo: Path,
    run_id: str,
    existing: sqlite3.Row,
    reason: str,
    actor: str,
) -> dict[str, Any]:
    """Resolve and explicitly migrate one quarantined run's capabilities."""
    if str(existing["status"] or "") != "QUARANTINED":
        raise RuntimeError("capability migration requires QUARANTINED enrollment")
    if existing["worker_pid"]:
        if _pid_alive(
            int(existing["worker_pid"]),
            float(existing["worker_started_at"])
            if existing["worker_started_at"] is not None else None,
        ):
            raise RuntimeError("capability migration refused while semantic worker is live")
        if not existing["worker_start_identity"] or existing["worker_started_at"] is None:
            raise RuntimeError("capability migration refused for ambiguous worker identity")

    repo_path = canonical_repo.resolve(strict=False)
    current_state = state_mod.load_verified(repo_path, run_id)
    if transitions.is_terminal(str(current_state.get("state") or "")):
        raise RuntimeError("capability migration refused for terminal engineering state")

    packet_path = state_mod.run_dir(repo_path, run_id) / "WORK_PACKET.md"
    packet_meta, _ = packet_mod.parse_packet_file(packet_path)
    packet_errors = packet_mod.validate_packet_for_approval(packet_meta)
    if packet_errors:
        raise RuntimeError("packet authority invalid: " + "; ".join(packet_errors))
    approval_doc = approval_mod.load_approval(repo_path, run_id)
    approval_ok, approval_reason = approval_mod.validate_approval_binding(
        canonical_repo=repo_path,
        run_id=run_id,
        approval=approval_doc,
        packet=packet_meta,
        packet_path=packet_path,
    )
    if not approval_ok:
        raise RuntimeError("approval authority invalid: " + approval_reason)

    requested = packet_meta.get("capabilities")
    if not isinstance(requested, list) or not all(isinstance(item, str) for item in requested):
        raise RuntimeError("packet capability authority is malformed")
    runner_name = str(existing["runner"] or "")
    runner_impl = _runner(runner_name)
    provider = str(getattr(runner_impl, "runner_id", runner_name))
    profile = runner_profiles_mod.resolve_profile(
        str(packet_meta.get("runner_profile") or "default"),
        provider=provider,
    )
    runner_profiles_mod.verify_profile_integrity(profile)
    attestation = runner_profiles_mod.verify_effort_attestation(profile)
    if attestation is not None:
        profile = dict(profile)
        profile["effort_attestation"] = attestation

    resolution = capabilities_mod.resolve_capabilities(
        [str(item) for item in requested],
        canonical_repo=repo_path,
        role="reviewer",
        repo_cache_root=runtime_env.repo_tool_cache_dir(repo_path),
        ephemeral_cache_root=(
            runtime_env.runtime_cache_dir(repo_path, run_id, "validation")
            / "capability-cache"
        ),
        packet_network_allowlist=[
            str(item) for item in (packet_meta.get("network_read_allowlist") or [])
        ],
    )
    capability_binding_mod._assert_runtime_ready_resolution(resolution, requested)
    program = current_state.get("program") or {}
    checkpoints = program.get("current_checkpoints") or []
    context = {
        "runtime_generation": str(existing["runtime_generation"] or ""),
        "engineering_state": str(current_state.get("state") or ""),
        "checkpoint": str(checkpoints[0]) if checkpoints else "",
        "supervisor_job_id": int(existing["id"]),
        "packet_sha256": util.sha256_text(packet_path.read_text(encoding="utf-8")),
        "approval_sha256": approval_mod.approval_artifact_sha256(approval_doc or {}),
    }
    return capability_binding_mod.migrate_run_binding(
        repo_path,
        run_id,
        resolution,
        profile,
        reason=reason,
        actor=actor,
        context=context,
        requested_capabilities=requested,
    )


__all__ = [
    "SCHEMA",
    "ClaudeCodeRunner",
    "RunnerReadiness",
    "default_db_path",
    "default_worker_log_dir",
    "DISPATCH_HOLD_KIND",
    "DISPATCH_HOLD_STATES",
    "dispatch_hold_status",
    "release_dispatch_hold",
    "cancel_dispatch_hold",
    "supervisor_config_get",
    "supervisor_config_set",
    "fleet_status",
    "enqueue",
    "continue_program",
    "register_runner",
    "resume",
    "run_one",
    "serve",
    "status",
    "worker_log_paths",
]


@_serialize_run_lifecycle
def resume(
    *,
    canonical_repo: Path,
    run_id: str,
    db_path: Path | None = None,
    max_infra_failures: int | None = None,
    max_transient_failures: int | None = None,
    max_transient_recovery_cycles: int | None = None,
    max_total_cost_usd: float | None = None,
    max_total_tokens: int | None = None,
    max_wall_seconds: int | None = None,
    reset_execution_started_at: bool = False,
    rebind_capabilities: bool = False,
    capability_migration_reason: str = "explicit operator recovery from trusted capability drift",
    capability_migration_actor: str = "operator",
) -> dict[str, Any]:
    """Clear operational quarantine and reset operational counters only.

    Does NOT alter STATE.json, packet scope, candidate SHA, review verdict, or
    engineering pass counters. Cumulative observed cost is preserved.

    The wall-clock origin is PRESERVED by default: resuming a run that
    exhausted its funded wall budget must not silently grant a fresh
    budget — the ceiling check would quarantine the run again, and
    silently resetting the clock would make the funded wall ceiling
    unenforceable across resumes. A fresh clock is an explicit budget
    decision: pass ``reset_execution_started_at=True`` (operator
    ``--reset-execution-clock``) — normally together with a widened
    ``max_wall_seconds``.

    Runtime-generation migration: resume is an explicit operator act, so
    it also REBINDS the job to the resuming runtime's generation. This is
    the clean migration path after a deliberate runtime replacement: the
    run was quarantined on the generation mismatch, the operator inspects
    and resumes, and the run continues under the new generation with the
    rebinding recorded. The previous binding is reported in the result.

    Capability migration is separate and opt-in through
    ``rebind_capabilities=True``. It validates and records the new trusted
    capability authority before this operational resume transaction; ordinary
    resume never silently changes capability binding.

    Returns the updated job dict (or NOT_ENQUEUED).
    """
    state_mod.validate_run_id(run_id)
    repo = str(Path(canonical_repo).resolve(strict=False))
    db = db_path or default_db_path()
    now = time.time()
    # Resume is exclusively a QUARANTINED -> QUEUED recovery action. Any
    # other state is refused without changing budgets, wall-clock origin, PID
    # ownership, backoff or error evidence.
    with _managed_connect(db) as conn:
        existing, lookup_reason = _logical_job_row(conn, canonical_repo, run_id)
    if existing is None:
        return {
            "schema": SCHEMA,
            "ok": False,
            "repo": repo,
            "run_id": run_id,
            "status": "NOT_ENQUEUED",
            "db_path": str(db),
            "resumed": False,
            "reason": "not_enqueued",
        }
    # Retired enrollments are durable historical evidence; ``supervisor resume``
    # must not accidentally resurrect them. The architecture intentionally
    # exposes no reactivation command — preserved historical enrollments must
    # stay preserved. Fail closed with a precise retirement diagnostic that
    # operators can grep, distinct from the generic QUARANTINED-required one.
    if str(existing["status"] or "") == "RETIRED":
        result = _job_dict(existing, db)
        result.update({
            "ok": False,
            "resumed": False,
            "reason": "resume_refuses_retired_enrollment",
        })
        return result
    if str(existing["status"]) != "QUARANTINED":
        result = _job_dict(existing, db)
        result.update({
            "ok": False,
            "resumed": False,
            "reason": "resume_requires_quarantined",
        })
        return result
    if existing["worker_pid"] and _pid_alive(
        int(existing["worker_pid"]),
        float(existing["worker_started_at"]) if existing["worker_started_at"] else None,
    ):
        result = _job_dict(existing, db)
        result.update({
            "ok": False,
            "resumed": False,
            "reason": "quarantined_worker_still_alive",
        })
        return result

    migration = None
    if rebind_capabilities:
        try:
            migration = _migrate_quarantined_run_capabilities(
                canonical_repo=canonical_repo,
                run_id=run_id,
                existing=existing,
                reason=capability_migration_reason,
                actor=capability_migration_actor,
            )
        except Exception as exc:  # deterministic refusal; no supervisor write yet
            result = _job_dict(existing, db)
            result.update({
                "ok": False,
                "resumed": False,
                "reason": "capability_rebind_refused",
                "error": str(exc),
            })
            return result

    sets = [
        "status='QUEUED'",
        "infra_failures=0",
        "transient_failures=0",
        "transient_recovery_cycles=0",
        "next_attempt_at=0",
        "last_error=NULL",
        "last_failure_class=NULL",
        "last_failure_reason=NULL",
        "worker_pid=NULL",
        "worker_started_at=NULL",
        "worker_pgid=NULL",
        "worker_deadline_at=NULL",
        "worker_start_identity=NULL",
        "worker_role=NULL",
        "updated_at=?",
    ]
    params: list[Any] = [now]
    if max_infra_failures is not None:
        sets.append("max_infra_failures=?")
        params.append(int(max_infra_failures))
    if max_transient_failures is not None:
        sets.append("max_transient_failures=?")
        params.append(int(max_transient_failures))
    if max_transient_recovery_cycles is not None:
        sets.append("max_transient_recovery_cycles=?")
        params.append(int(max_transient_recovery_cycles))
    if max_total_cost_usd is not None:
        sets.append("max_total_cost_usd=?")
        params.append(float(max_total_cost_usd))
    if max_total_tokens is not None:
        sets.append("max_total_tokens=?")
        params.append(int(max_total_tokens))
    if max_wall_seconds is not None:
        sets.append("max_wall_seconds=?")
        params.append(int(max_wall_seconds))
    if (
        max_total_cost_usd is not None
        and max_total_tokens is not None
        and max_wall_seconds is not None
    ):
        sets.append("legacy_budget_ambiguous=0")
    if reset_execution_started_at:
        sets.append("execution_started_at=?")
        params.append(now)
    # Explicit operator migration: rebind the run to the resuming
    # runtime's generation (recorded; previous binding reported back).
    previous_generation = str(existing["runtime_generation"] or "")
    sets.append("runtime_generation=?")
    params.append(_current_runtime_generation())
    params.extend([int(existing["id"]), previous_generation])
    with _managed_connect(db) as conn:
        cur = conn.execute(
            f"UPDATE jobs SET {', '.join(sets)} "
            "WHERE id=? AND status='QUARANTINED' AND runtime_generation=?",
            params,
        )
        row = conn.execute(
            "SELECT * FROM jobs WHERE id=?", (int(existing["id"]),)
        ).fetchone()
        if cur.rowcount != 1:
            result = _job_dict(row, db) if row is not None else {
                "schema": SCHEMA,
                "ok": False,
                "repo": repo,
                "run_id": run_id,
                "status": "NOT_ENQUEUED",
                "db_path": str(db),
            }
            result.update({
                "ok": False,
                "resumed": False,
                "reason": "resume_lost_quarantine_race",
            })
            if migration is not None:
                result.update({
                    "capability_migration_completed": True,
                    "capability_migration": migration,
                    "safe_retry": "supervisor resume --rebind-capabilities",
                })
            return result
    if row is None:
        return {
            "schema": SCHEMA,
            "ok": False,
            "repo": repo,
            "run_id": run_id,
            "status": "NOT_ENQUEUED",
            "db_path": str(db),
        }
    result = _job_dict(row, db)
    result["resumed"] = True
    result["runtime_generation_previous"] = previous_generation
    if migration is not None:
        result["capability_migration"] = migration
    return result


@_serialize_run_lifecycle
def retire(
    *,
    canonical_repo: Path,
    run_id: str,
    db_path: Path | None = None,
) -> dict[str, Any]:
    """Non-destructively retire a historical supervisor enrollment.

    Retirement is a SUPERVISOR-LEDGER lifecycle transition only. It MUST NOT
    modify the target repository, .ownframework-loop run artifacts, WORK_PACKET.md,
    STATE.json, EVENTS.log, APPROVAL.json, scratch evidence, candidate refs,
    runtime_generation, semantic-attempt history, or cost/token/retry evidence.

    Supported transition: ``QUARANTINED -> RETIRED`` only. ``QUEUED``,
    ``BACKOFF``, ``RUNNING``, ``DONE``, and ``RETIRED`` are refused because
    retirement is not a reactivation, migration, or completion.

    A live or ambiguous semantic worker / attempt refuses retirement; the
    enrollment must first drain through the normal supervisor lifecycle.

    A retired row's existing ``runtime_generation`` value (including an empty
    legacy ``UNBOUND`` value) is preserved. Retirement never masquerades as
    migration or successful completion. The retired enrollment is excluded
    from runtime-generation dependency checks at install/refresh time, so
    normal future supervisor replacement no longer requires the migration
    override to bypass durable historical evidence.

    ``supervisor resume`` continues to refuse ``RETIRED`` rows because it
    requires the source status to be exactly ``QUARANTINED``. The architecture
    intentionally does not expose a reactivation command — preserved historical
    enrollments must stay preserved.
    """
    state_mod.validate_run_id(run_id)
    repo = str(Path(canonical_repo).resolve(strict=False))
    db = db_path or default_db_path()
    now = time.time()
    with _managed_connect(db) as conn:
        existing, lookup_reason = _logical_job_row(conn, canonical_repo, run_id)
    if existing is None:
        return {
            "schema": SCHEMA,
            "ok": False,
            "repo": repo,
            "run_id": run_id,
            "status": "NOT_ENQUEUED",
            "db_path": str(db),
            "retired": False,
            "reason": "not_enqueued",
        }
    current_status = str(existing["status"] or "")
    if current_status != "QUARANTINED":
        result = _job_dict(existing, db)
        result.update({
            "ok": False,
            "retired": False,
            "reason": (
                "retire_requires_quarantined"
                if current_status in ("QUEUED", "BACKOFF", "RUNNING")
                else "retire_refuses_terminal_enrollment"
            ),
        })
        return result
    # An unresolved semantic-attempt row is ambiguous paid/model execution
    # evidence even when the job-level PID is empty or dead. Retirement must
    # not hide it behind a historical status before crash reconciliation has
    # proven the attempt terminal.
    with _managed_connect_readonly(db) as attempt_conn:
        attempt_rows = attempt_conn.execute(
            "SELECT attempt_id,status,worker_pid FROM semantic_attempts "
            "WHERE job_id=? ORDER BY started_at DESC",
            (int(existing["id"]),),
        ).fetchall()
    unresolved_attempts = [
        row for row in attempt_rows
        if str(row["status"] or "") not in TERMINAL_SEMANTIC_ATTEMPT_STATUSES
    ]
    if unresolved_attempts:
        result = _job_dict(existing, db)
        result.update({
            "ok": False,
            "retired": False,
            "reason": "retire_refuses_unresolved_semantic_attempt",
            "unresolved_attempts": [
                {
                    "attempt_id": str(row["attempt_id"] or ""),
                    "status": str(row["status"] or ""),
                    "worker_pid": row["worker_pid"],
                }
                for row in unresolved_attempts[:8]
            ],
        })
        return result

    # Live job ownership also refuses retirement. The operator must wait for
    # the worker to drain through the normal supervisor lifecycle before
    # retiring the enrollment.
    if existing["worker_pid"] and _pid_alive(
        int(existing["worker_pid"]),
        float(existing["worker_started_at"]) if existing["worker_started_at"] else None,
    ):
        result = _job_dict(existing, db)
        result.update({
            "ok": False,
            "retired": False,
            "reason": "quarantined_worker_still_alive",
        })
        return result
    # Preserve runtime_generation verbatim, including legacy empty / UNBOUND.
    preserved_runtime_generation = str(existing["runtime_generation"] or "")
    preserved_cost_usd = float(existing["total_cost_usd"] or 0.0)
    preserved_attempt_id = str(existing["latest_attempt_id"] or "")
    with _managed_connect(db) as conn:
        cur = conn.execute(
            """UPDATE jobs SET
                 status='RETIRED',
                 updated_at=?
               WHERE id=? AND status='QUARANTINED'""",
            (now, int(existing["id"])),
        )
        if cur.rowcount != 1:
            # Concurrent transition lost; refuse without rewriting state.
            row = conn.execute(
                "SELECT * FROM jobs WHERE id=?", (int(existing["id"]),)
            ).fetchone()
            result = _job_dict(row, db) if row is not None else {
                "schema": SCHEMA, "ok": False, "status": "NOT_ENQUEUED",
            }
            result.update({
                "ok": False,
                "retired": False,
                "reason": "retire_lost_quarantine_race",
            })
            return result
        # Read back the exact logical enrollment we just retired. The
        # operator may have addressed it through a symlink or linked worktree,
        # so the caller's literal repo path is not durable row identity.
        row = conn.execute(
            "SELECT * FROM jobs WHERE id=?", (int(existing["id"]),)
        ).fetchone()
    if row is None:
        return {
            "schema": SCHEMA,
            "ok": False,
            "repo": repo,
            "run_id": run_id,
            "status": "NOT_ENQUEUED",
            "db_path": str(db),
            "retired": False,
        }
    # Defensive: confirm the preservation contract held end-to-end.
    actual_runtime_generation = str(row["runtime_generation"] or "")
    if actual_runtime_generation != preserved_runtime_generation:
        raise RuntimeError(
            "retire must preserve runtime_generation verbatim; "
            f"expected {preserved_runtime_generation!r}, got {actual_runtime_generation!r}"
        )
    if float(row["total_cost_usd"] or 0.0) != preserved_cost_usd:
        raise RuntimeError("retire must preserve total_cost_usd verbatim")
    if str(row["latest_attempt_id"] or "") != preserved_attempt_id:
        raise RuntimeError("retire must preserve latest_attempt_id verbatim")
    result = _job_dict(row, db)
    result["retired"] = True
    result["runtime_generation_preserved"] = preserved_runtime_generation
    return result
