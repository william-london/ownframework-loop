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

3. ``uv sync`` failures must be classified correctly. Some are genuine
   validator-owned infrastructure failures (bound uv unavailable or drifted,
   registry unreachable, runtime-cache filesystem refused, provisioning
   timeout). Others are candidate-repairable defects (the builder modified
   ``pyproject.toml`` without regenerating ``uv.lock``; declared a dependency
   that does not exist; produced invalid metadata; etc.). The validator
   distinguishes them so infra failures terminalize as ``BLOCKED`` (no repair
   round burned) and candidate-repairable failures transition to
   ``CHANGES_REQUESTED`` (the next builder pass can fix the metadata mistake).

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
    <candidate_worktree> --python-preference only-system --locked``
    into the env_dir. Subsequent runs of the SAME env_id are no-ops only
    when the durable marker proves the same frozen ``package.uv`` identity.
  - Subprocesses that need the env (validation commands invoking
    ``uv run``, or any subprocess that should auto-activate the env)
    receive ``UV_PROJECT_ENVIRONMENT=<env_dir>`` and
    ``VIRTUAL_ENV=<env_dir>`` in their hermetic subprocess environment.

The module does NOT widen any worker's authority. The env_dir is not in
any worker's allowRead/allowWrite; it is the validator's exclusive
runtime artifact.

Failure classification
======================

``provision_project_environment`` returns a structured
``ProvisionOutcome`` rather than raising on every non-zero exit. The
three outcome classes are:

  - ``PROVISIONED``: ``uv sync --project <candidate> --locked`` wrote a
    usable project environment into the env_dir. The marker is published
    and downstream ``uv run --no-sync`` invocations will succeed.

  - ``CANDIDATE_INVALID``: the candidate's own metadata is unprovable
    (stale lockfile, missing dependency in pyproject, malformed
    pyproject.toml, etc.). The candidate author / next builder pass
    can repair this; the validator records
    ``validation_failed/candidate_environment_invalid`` and the run
    transitions to ``CHANGES_REQUESTED`` with a normal repair
    entitlement. This is the Sourcecard-failure-class behavior.

  - ``INFRA_FAILURE``: the validator/host cannot prove the environment
    (bound package.uv identity missing or drifted, provisioning timeout,
    runtime-cache filesystem refused, external registry/network
    unreachable, host tool execution failure independent of candidate
    contents). The candidate author cannot fix this; the run terminalizes
    as ``BLOCKED`` without burning a repair round.

The classifier inspects the redacted stderr excerpt plus the exit
state to assign the class. Ambiguous cases fail closed as infra
``BLOCKED`` and record the ambiguity explicitly rather than falsely
asserting that the validator can prove the environment is good.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from . import runtime_env, util


SCHEMA = "ownframework-loop-validation-environment/v1"


class ValidationEnvironmentError(RuntimeError):
    """A validator/host-side infrastructure failure (cannot be fixed by
    the candidate author). Always terminal BLOCKED, never repairable.
    """


# Maximum time to wait for uv sync to finish. Network registries can be
# slow; this is intentionally generous.
DEFAULT_PROVISION_TIMEOUT_SECONDS = 600


def _terminate_process_group(
    process: subprocess.Popen[Any], grace_seconds: float = 3.0
) -> None:
    """Terminate and reap one validator-owned subprocess tree.

    Bound tools are executable authority, but they may themselves be wrappers
    or spawn helpers. Timeout ownership therefore applies to the whole process
    group, not only the direct child PID. Every process launched through this
    module starts a new session before this helper may be used.
    """
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=grace_seconds)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


@dataclass(frozen=True)
class BoundUvIdentity:
    """Exact identity of the bound ``package.uv`` capability.

    Built from the resolved capability envelope (not from PATH
    discovery) and used as the SOLE authority for any uv subprocess
    invocation. Pre-launch drift checks refuse to launch when the
    path/SHA/version no longer matches the frozen resolution.
    """
    executable: str
    version: str
    executable_sha256: str
    cache_path: str
    cache_scope: str
    network_domains: tuple[str, ...]

    def to_dict(self) -> dict[str, Any]:
        return {
            "executable": self.executable,
            "version": self.version,
            "executable_sha256": self.executable_sha256,
            "cache_path": self.cache_path,
            "cache_scope": self.cache_scope,
            "network_domains": list(self.network_domains),
        }


def build_bound_uv_identity(
    resolved_item: dict[str, Any],
    *,
    cache_path: str = "",
    cache_scope: str = "",
) -> BoundUvIdentity:
    """Construct a BoundUvIdentity from a resolved capability item.

    Refuses to construct when the resolved item is missing the
    minimal authority surface (executable / version / sha256) so
    the caller cannot fall back to PATH-discovered uv.
    """
    executable = str(resolved_item.get("executable") or "")
    version = str(resolved_item.get("version") or "")
    sha = str(resolved_item.get("executable_sha256") or "")
    if not executable or not version or not sha:
        raise ValidationEnvironmentError(
            "bound package.uv resolution missing executable/version/sha256; "
            "cannot construct BoundUvIdentity from an untrusted resolution"
        )
    domains = tuple(str(d) for d in (resolved_item.get("network_domains") or ()))
    return BoundUvIdentity(
        executable=executable,
        version=version,
        executable_sha256=sha,
        cache_path=str(cache_path),
        cache_scope=str(cache_scope),
        network_domains=domains,
    )


def verify_bound_uv_identity(bound: BoundUvIdentity) -> None:
    """Re-prove the bound uv identity immediately before any subprocess.

    Refuses to launch when:
      - the executable path no longer exists;
      - the executable path has been replaced by a symlink;
      - the SHA-256 of the on-disk bytes no longer matches the
        frozen binding (silent swap, byte mutation, reinstall);
      - the executable is no longer a regular executable file.

    Refusal raises ``ValidationEnvironmentError`` so the executor can
    surface it as a terminal BLOCKED, infra-class, no-repair failure.
    """
    if not bound.executable:
        raise ValidationEnvironmentError(
            "bound package.uv executable path is empty"
        )
    p = Path(bound.executable)
    if not p.exists():
        raise ValidationEnvironmentError(
            f"bound package.uv executable disappeared: {bound.executable}"
        )
    if p.is_symlink():
        raise ValidationEnvironmentError(
            f"bound package.uv executable is now a symlink: {bound.executable}"
        )
    if not p.is_file() or not os.access(bound.executable, os.X_OK):
        raise ValidationEnvironmentError(
            f"bound package.uv executable is no longer a regular runnable file: "
            f"{bound.executable}"
        )
    actual = _sha256_file(Path(bound.executable)) or ""
    if not actual or actual != bound.executable_sha256:
        raise ValidationEnvironmentError(
            "CAPABILITY_DRIFT: bound package.uv SHA mismatch — "
            f"expected {bound.executable_sha256}, observed {actual or '<none>'}; "
            f"refusing uv execution"
        )


# Outcome class constants. Use these strings verbatim; they are part
# of the receipt/verdict contract surfaced by build_finalize and
# review_finalize.
OUTCOME_PROVISIONED = "provisioned"
OUTCOME_CANDIDATE_INVALID = "candidate_invalid"
OUTCOME_INFRA_FAILURE = "infra_failure"

ALL_OUTCOMES = (OUTCOME_PROVISIONED, OUTCOME_CANDIDATE_INVALID, OUTCOME_INFRA_FAILURE)


@dataclass(frozen=True)
class ProvisionOutcome:
    """Structured outcome of one ``provision_project_environment`` call.

    Attributes:
      - outcome: one of ``OUTCOME_PROVISIONED`` / ``OUTCOME_CANDIDATE_INVALID``
        / ``OUTCOME_INFRA_FAILURE``.
      - reason: short human-readable classifier reason.
      - stderr_excerpt: bounded (4096 chars) redacted stderr excerpt.
      - returncode: ``uv sync`` exit code when captured; ``None`` for
        timeout / identity / FS-refused cases.
      - timed_out: True iff the subprocess exhausted the timeout budget.
      - marker_path: env_dir path when an env_dir was created.
      - identity: env_id when known.
    """

    outcome: str
    reason: str
    stderr_excerpt: str
    returncode: int | None
    timed_out: bool
    marker_path: str
    identity: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "outcome": self.outcome,
            "reason": self.reason,
            "stderr_excerpt": self.stderr_excerpt,
            "returncode": self.returncode,
            "timed_out": self.timed_out,
            "marker_path": self.marker_path,
            "identity": self.identity,
        }


# Canonical uv subcommands that require the candidate-bound project
# environment. EVERY uv-mediated validation/provisioning operation that
# could reach the package network MUST be declared via this predicate so
# packet admission (which refuses undeclared `package.uv`) and the
# validation executor (which provisions the project env) agree on the
# exact same set. The packet layer imports
# `validation_environment.is_uv_command`; the executor imports the
# SAME function — never an independent regex.
UV_MEDIATED_SUBCOMMANDS: tuple[str, ...] = (
    "run", "sync", "exec", "test", "python", "lock",
)

_UV_COMMAND_RE = re.compile(
    r"\buv\s+(?:"
    + "|".join(re.escape(subcommand) for subcommand in UV_MEDIATED_SUBCOMMANDS)
    + r")\b"
)


def is_uv_command(command: str) -> bool:
    """Return True when `command` invokes a uv subcommand that needs
    the candidate-bound project environment.

    This is THE canonical predicate. Both packet admission and
    validation execution MUST consume it (never an independent regex)
    so the two cannot drift. Adding a new uv subcommand that
    requires the env → extend UV_MEDIATED_SUBCOMMANDS here; both
    layers pick it up automatically.
    """
    if not command:
        return False
    return bool(_UV_COMMAND_RE.search(command))


# Pattern catalogue: each tuple is (compiled-regex, class, label).
# Matched against uv's stderr text after lowercasing. Order matters:
# the first match wins. INFRA patterns are deliberately conservative —
# they only fire on signatures uv emits for genuine host/registry
# problems, not on metadata problems that look superficially similar.
_INFRA_PATTERNS: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"failed to connect"), "registry_network_unreachable"),
    (re.compile(r"could not connect"), "registry_network_unreachable"),
    (re.compile(r"connection (timed out|refused|reset)"), "registry_network_unreachable"),
    (re.compile(r"tls handshake|ssl certificate"), "registry_tls_error"),
    (re.compile(r"failed to download"), "registry_download_failed"),
    (re.compile(r"network is unreachable"), "host_network_unreachable"),
    (re.compile(r"temporary failure in name resolution"), "dns_resolution_failed"),
    (re.compile(r"operation timed out"), "registry_timeout"),
    (re.compile(r"timed out waiting"), "registry_timeout"),
    (re.compile(r"permission denied"), "filesystem_permission_denied"),
    (re.compile(r"read-only file system"), "filesystem_read_only"),
    (re.compile(r"no space left on device"), "filesystem_no_space"),
    (re.compile(r"disk quota exceeded"), "filesystem_quota_exceeded"),
    (re.compile(r"i/o error"), "filesystem_io_error"),
    (re.compile(r"signal \d+ \(sig"), "subprocess_signalled"),
    (re.compile(r"failed to invoke"), "host_tool_execution_failed"),
)


_CANDIDATE_PATTERNS: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"the lockfile at .* needs to be updated"), "stale_lockfile"),
    (re.compile(r"the lockfile would have been updated"), "stale_lockfile"),
    (re.compile(r"would be updated to"), "stale_lockfile"),
    (re.compile(r"unidentified error .* look.* like a stale lockfile"),
     "stale_lockfile"),
    (re.compile(r"failed to parse .*pyproject\.toml"), "invalid_pyproject"),
    (re.compile(r"toml decode error"), "invalid_pyproject"),
    (re.compile(r"no `?project\.?workspace`? found"), "no_pyproject"),
    (re.compile(r"failed to read (lock|pyproject)"), "unreadable_metadata"),
    (re.compile(r"distribution .* not found"), "missing_dependency"),
    (re.compile(r"package .* not found in package list"),
     "missing_dependency"),
    (re.compile(r"requires-python .* does not match"), "python_version_mismatch"),
    (re.compile(r"no matching distribution"), "missing_dependency"),
    (re.compile(r"invalid project name"), "invalid_project_name"),
    (re.compile(r"error: package metadata"), "invalid_metadata"),
    (re.compile(r"version .* is not a valid"), "invalid_metadata"),
    (re.compile(r"duplicate dependency"), "duplicate_dependency"),
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
    """Return the sha256 of the candidate's uv.lock, or None if absent."""
    lock = candidate_worktree / "uv.lock"
    return _sha256_file(lock)


def _project_metadata_identity(candidate_worktree: Path) -> str:
    """Return the sha256 of the candidate's pyproject.toml."""
    pyproject = candidate_worktree / "pyproject.toml"
    digest = _sha256_file(pyproject)
    if digest is None:
        return "no-pyproject"
    return digest


def candidate_bound_environment_id(
    candidate_sha: str,
    candidate_worktree: Path,
) -> str:
    """Derive the deterministic env identity for one candidate."""
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

    Role isolation: ``builder`` and ``reviewer`` validators get
    independent env dirs even when their candidate_sha/lock/metadata
    triple is identical. The reviewer's env_dir must NEVER alias the
    builder's so the immutable reviewer worktree can never observe
    the builder's freshly-provisioned env through shared filesystem
    state.

    This is a PURE path derivation. It does NOT touch the filesystem
    and does NOT require the runtime-cache root to exist or be
    writable. The provisioner is responsible for catching any
    filesystem failures that occur during actual provisioning.
    """
    safe_role = "validation-builder" if role == "builder" else (
        "validation-reviewer" if role == "reviewer" else (
            role if role in (
                "validation", "validation-builder", "validation-reviewer",
            ) else "validation"
        )
    )
    return (
        runtime_env.runtime_cache_path(canonical_repo, run_id, "validation")
        / "project-env"
        / safe_role
        / _slug(env_id)
    ).resolve(strict=False)


def project_environment_status(env_dir: Path) -> dict[str, Any]:
    """Snapshot the provisioning state of one env directory."""
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
        "package_uv_unbound": bool(doc.get("package_uv_unbound", False)),
        "bound_uv_sha256": str(doc.get("bound_uv_sha256") or ""),
        "bound_uv_version": str(doc.get("bound_uv_version") or ""),
        "bound_uv_cache_path": str(doc.get("bound_uv_cache_path") or ""),
        "bound_uv_cache_scope": str(doc.get("bound_uv_cache_scope") or ""),
        "bound_uv_network_domains": list(
            doc.get("bound_uv_network_domains") or []
        ),
        "provisioned_at": str(doc.get("provisioned_at") or ""),
    })
    return state


def _real_project_environment_matches_bound_uv(
    status: dict[str, Any],
    bound_uv: BoundUvIdentity,
) -> bool:
    """Return True only when a real-project marker proves the frozen uv identity."""
    return (
        bool(status.get("provisioned"))
        and not bool(status.get("package_uv_unbound"))
        and str(status.get("uv_executable") or "") == bound_uv.executable
        and str(status.get("bound_uv_sha256") or "") == bound_uv.executable_sha256
        and str(status.get("bound_uv_version") or "") == bound_uv.version
        and str(status.get("bound_uv_cache_path") or "") == bound_uv.cache_path
        and str(status.get("bound_uv_cache_scope") or "") == bound_uv.cache_scope
        and sorted(str(value) for value in (status.get("bound_uv_network_domains") or []))
        == sorted(bound_uv.network_domains)
    )


def _uv_version(uv_executable: str) -> str:
    process: subprocess.Popen[str] | None = None
    try:
        process = subprocess.Popen(
            [uv_executable, "--version"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        stdout, stderr = process.communicate(timeout=5)
        text = (stdout or stderr or "").strip()
        return text.splitlines()[0][:512] if text else ""
    except subprocess.TimeoutExpired:
        if process is not None:
            _terminate_process_group(process)
        return ""
    except OSError:
        if process is not None:
            _terminate_process_group(process)
        return ""
    except BaseException:
        if process is not None:
            _terminate_process_group(process)
        raise


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


def _excerpt(stderr_bytes: bytes, stdout_bytes: bytes, limit: int = 4096) -> str:
    raw = (stderr_bytes or stdout_bytes or b"").decode("utf-8", errors="replace")
    return raw[:limit]


def classify_sync_failure(
    *,
    returncode: int | None,
    timed_out: bool,
    stderr_bytes: bytes,
    stdout_bytes: bytes,
) -> tuple[str, str]:
    """Return (outcome, reason) for a uv sync failure.

    The classifier inspects the redacted stderr text and the exit
    state to assign one of:
      - (OUTCOME_INFRA_FAILURE, ``<reason>``)
      - (OUTCOME_CANDIDATE_INVALID, ``<reason>``)

    Order of preference:
      1. Timed-out subprocess → INFRA (timeout is a host/network signal,
         never a candidate defect).
      2. INFRA pattern matched in stderr → INFRA.
      3. CANDIDATE pattern matched in stderr → CANDIDATE_INVALID.
      4. Default: INFRA. The conservative default prevents a builder
         from burning a repair round on something that is genuinely the
         validator's responsibility; the receipt records the default
         reason and the operator can reclassify if needed.
    """
    if timed_out:
        return OUTCOME_INFRA_FAILURE, "provisioning_timeout"
    text = _excerpt(stderr_bytes, stdout_bytes, limit=8192).lower()
    if not text and returncode is not None:
        text = f"uv sync returned non-zero exit code {returncode} with empty stderr"
    for pattern, label in _INFRA_PATTERNS:
        if pattern.search(text):
            return OUTCOME_INFRA_FAILURE, label
    for pattern, label in _CANDIDATE_PATTERNS:
        if pattern.search(text):
            return OUTCOME_CANDIDATE_INVALID, label
    return (
        OUTCOME_INFRA_FAILURE,
        f"unclassified_sync_failure_rc={returncode or 'unknown'}",
    )


def _outcome_dict(o: ProvisionOutcome, *, status_fields: dict[str, Any] | None = None) -> dict[str, Any]:
    """Render a ProvisionOutcome as the legacy dict shape.

    The legacy status dict (path / provisioned / identity / ...) is
    preserved for backward compatibility with code that pre-dates the
    outcome classifier. The outcome / reason / returncode / timed_out
    fields are added so callers can act on the classification.
    """
    base = {
        "outcome": o.outcome,
        "reason": o.reason,
        "stderr_excerpt": o.stderr_excerpt,
        "returncode": o.returncode,
        "timed_out": o.timed_out,
        "marker_path": o.marker_path,
        "identity": o.identity,
        "path": o.marker_path,
        "provisioned": o.outcome == OUTCOME_PROVISIONED,
    }
    if status_fields:
        base.update(status_fields)
    return base


def provision_project_environment(
    *,
    canonical_repo: Path,
    run_id: str,
    role: str,
    candidate_sha: str,
    candidate_worktree: Path,
    bound_uv: BoundUvIdentity | None = None,
    timeout_seconds: int = DEFAULT_PROVISION_TIMEOUT_SECONDS,
) -> dict[str, Any]:
    """Provision the candidate-bound project environment.

    The ``bound_uv`` argument is the EXACT ``package.uv`` resolution from the
    frozen run's CAPABILITY_BINDING.json. The provisioner never uses PATH
    discovery as authority: every real uv subprocess or real-project cache
    reuse requires ``bound_uv`` and verifies it against the current executable
    plus the durable environment marker. ``bound_uv=None`` is accepted only
    for candidates without ``pyproject.toml``, where no uv effect exists.

    Returns a dict with two compatible shapes layered on top of each
    other. Callers that only need the legacy ``project_environment_status``
    shape (``provisioned``, ``path``, ``identity``, ...) keep working.
    Callers that need the outcome classifier consume ``outcome``,
    ``reason``, ``returncode``, ``timed_out``, ``stderr_excerpt``,
    ``marker_path``.

    The ``outcome`` field is one of:

      - ``OUTCOME_PROVISIONED``: env_dir has a usable project
        environment. The marker is published; ``uv run --no-sync``
        downstream will succeed.
      - ``OUTCOME_CANDIDATE_INVALID``: the candidate's own metadata
        is unprovable (stale lockfile, malformed pyproject.toml,
        declared-but-unresolvable dependency). The next builder pass
        can fix this; the validator surfaces this so the run
        transitions to ``CHANGES_REQUESTED`` and consumes a normal
        repair round.
      - ``OUTCOME_INFRA_FAILURE``: a genuine validator/host-side
        failure (bound identity missing/drifted, provisioning timeout,
        runtime-cache filesystem refused, registry/network unreachable).
        The run terminalizes as ``BLOCKED`` without burning a repair round.

    Raises :class:`ValidationEnvironmentError` only when the validator
    cannot even initialize a provisioning attempt (e.g. the candidate
    worktree itself is missing — both indicators that state is
    corrupt rather than candidate-fixable).
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

    def _infra(reason: str, **fields: Any) -> dict[str, Any]:
        return _outcome_dict(ProvisionOutcome(
            outcome=OUTCOME_INFRA_FAILURE,
            reason=reason,
            stderr_excerpt="",
            returncode=None,
            timed_out=False,
            marker_path=str(env_dir),
            identity=env_id,
        ), status_fields=fields)

    if not has_project:
        try:
            env_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        except OSError as exc:
            return _infra(f"runtime_cache_create_failed:{exc.strerror or exc}")
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
            "package_uv_unbound": False,
            "bound_uv_sha256": (
                bound_uv.executable_sha256 if bound_uv is not None else ""
            ),
            "bound_uv_version": (
                bound_uv.version if bound_uv is not None else ""
            ),
            "bound_uv_cache_path": (
                bound_uv.cache_path if bound_uv is not None else ""
            ),
            "bound_uv_cache_scope": (
                bound_uv.cache_scope if bound_uv is not None else ""
            ),
            "bound_uv_network_domains": (
                list(bound_uv.network_domains) if bound_uv is not None else []
            ),
            "provisioned_at": util.utc_now_iso(),
            "no_project": True,
        })
        status = project_environment_status(env_dir)
        return _outcome_dict(ProvisionOutcome(
            outcome=OUTCOME_PROVISIONED,
            reason="no_pyproject",
            stderr_excerpt="",
            returncode=0,
            timed_out=False,
            marker_path=str(env_dir),
            identity=env_id,
        ), status_fields=status)

    if bound_uv is None:
        return _infra(
            "bound_uv_required: package.uv must be frozen before uv provisioning"
        )
    try:
        verify_bound_uv_identity(bound_uv)
    except ValidationEnvironmentError as exc:
        return _infra(f"bound_uv_drift:{exc}")

    existing = project_environment_status(env_dir)
    if existing["provisioned"] and existing["identity"] == env_id:
        if not _real_project_environment_matches_bound_uv(existing, bound_uv):
            return _infra(
                "bound_uv_cached_environment_mismatch: existing project "
                "environment does not prove the current frozen package.uv identity"
            )
        return _outcome_dict(ProvisionOutcome(
            outcome=OUTCOME_PROVISIONED,
            reason="already_provisioned",
            stderr_excerpt="",
            returncode=0,
            timed_out=False,
            marker_path=str(env_dir),
            identity=env_id,
        ), status_fields=existing)

    if env_dir.is_symlink():
        return _infra("env_dir_is_symlink")
    if env_dir.exists():
        try:
            shutil.rmtree(env_dir)
        except OSError as exc:
            return _infra(f"env_dir_clear_failed:{exc.strerror or exc}")
    try:
        env_dir.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    except OSError as exc:
        return _infra(f"runtime_cache_create_failed:{exc.strerror or exc}")

    uv_executable = bound_uv.executable
    uv_version = _uv_version(uv_executable)
    sync_env = runtime_env.hermetic_subprocess_env(
        canonical_repo, run_id, "validation",
    )
    sync_env["UV_PROJECT_ENVIRONMENT"] = str(env_dir)
    sync_env["VIRTUAL_ENV"] = str(env_dir)

    cmd = [
        uv_executable, "sync",
        "--project", str(candidate_worktree),
        "--python-preference", "only-system",
        "--locked",
    ]

    stdout_path = env_dir.parent / f".{env_dir.name}.provision.stdout"
    stderr_path = env_dir.parent / f".{env_dir.name}.provision.stderr"
    start = time.monotonic()
    timed_out = False
    returncode: int | None = None
    process: subprocess.Popen[bytes] | None = None
    try:
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
                process = subprocess.Popen(
                    cmd,
                    cwd=str(candidate_worktree),
                    env=sync_env,
                    stdout=stdout_fh,
                    stderr=stderr_fh,
                    start_new_session=True,
                )
                returncode = int(process.wait(timeout=timeout_seconds))
            except subprocess.TimeoutExpired:
                timed_out = True
                if process is not None:
                    _terminate_process_group(process)
                returncode = 124
            except BaseException:
                if process is not None:
                    _terminate_process_group(process)
                raise
    except OSError as exc:
        if process is not None:
            _terminate_process_group(process)
        return _infra(f"subprocess_spawn_failed:{exc.strerror or exc}")
    duration = time.monotonic() - start
    stdout_bytes = stdout_path.read_bytes() if stdout_path.exists() else b""
    stderr_bytes = stderr_path.read_bytes() if stderr_path.exists() else b""
    excerpt = _excerpt(stderr_bytes, stdout_bytes)
    try:
        stdout_path.unlink()
    except OSError:
        pass
    try:
        stderr_path.unlink()
    except OSError:
        pass

    if returncode == 0 and not timed_out:
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
            "uv_executable": uv_executable,
            "uv_version": uv_version,
            "package_uv_unbound": False,
            "bound_uv_sha256": bound_uv.executable_sha256,
            "bound_uv_version": bound_uv.version,
            "bound_uv_cache_path": bound_uv.cache_path,
            "bound_uv_cache_scope": bound_uv.cache_scope,
            "bound_uv_network_domains": list(bound_uv.network_domains),
            "provisioned_at": util.utc_now_iso(),
            "duration_seconds": float(duration),
        })
        status = project_environment_status(env_dir)
        return _outcome_dict(ProvisionOutcome(
            outcome=OUTCOME_PROVISIONED,
            reason="uv_sync_returned_zero",
            stderr_excerpt="",
            returncode=0,
            timed_out=False,
            marker_path=str(env_dir),
            identity=env_id,
        ), status_fields=status)

    outcome_class, label = classify_sync_failure(
        returncode=returncode,
        timed_out=timed_out,
        stderr_bytes=stderr_bytes,
        stdout_bytes=stdout_bytes,
    )
    result = _outcome_dict(ProvisionOutcome(
        outcome=outcome_class,
        reason=label,
        stderr_excerpt=excerpt,
        returncode=returncode,
        timed_out=timed_out,
        marker_path=str(env_dir),
        identity=env_id,
    ))
    result["package_uv_unbound"] = False
    result["bound_uv_sha256"] = bound_uv.executable_sha256
    result["bound_uv_version"] = bound_uv.version
    return result


def command_uses_uv_run(command: str) -> bool:
    """Return True when the command string invokes a uv subcommand that
    requires the project environment to exist.
    """
    return is_uv_command(command)


def env_overrides(env_dir: Path) -> dict[str, str]:
    """Return the hermetic subprocess environment keys required to bind
    the project env into a child process.
    """
    env_dir = Path(env_dir).expanduser().resolve(strict=False)
    return {
        "UV_PROJECT_ENVIRONMENT": str(env_dir),
        "VIRTUAL_ENV": str(env_dir),
    }


__all__ = [
    "ALL_OUTCOMES",
    "BoundUvIdentity",
    "DEFAULT_PROVISION_TIMEOUT_SECONDS",
    "OUTCOME_CANDIDATE_INVALID",
    "OUTCOME_INFRA_FAILURE",
    "OUTCOME_PROVISIONED",
    "ProvisionOutcome",
    "SCHEMA",
    "UV_MEDIATED_SUBCOMMANDS",
    "ValidationEnvironmentError",
    "build_bound_uv_identity",
    "candidate_bound_environment_id",
    "classify_sync_failure",
    "command_uses_uv_run",
    "env_overrides",
    "is_uv_command",
    "project_environment_dir",
    "project_environment_status",
    "provision_project_environment",
    "verify_bound_uv_identity",
]
