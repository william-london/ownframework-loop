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
   validator-owned infrastructure failures (uv missing, registry
   unreachable, runtime-cache filesystem refused, provisioning
   timeout). Others are candidate-repairable defects (the builder
   modified ``pyproject.toml`` without regenerating ``uv.lock``;
   declared a dependency that does not exist; produced invalid
   metadata; etc.). The validator distinguishes them so infra
   failures terminalize as ``BLOCKED`` (no repair round burned) and
   candidate-repairable failures transition to ``CHANGES_REQUESTED``
   (the next builder pass can fix the metadata mistake).

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
    into the env_dir. Subsequent runs of the SAME env_id are no-ops.
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
    (uv executable missing, provisioning timeout, runtime-cache
    filesystem/permission refused, external registry/network
    unreachable, host tool execution failure independent of candidate
    contents). The candidate author cannot fix this; the run
    terminalizes as ``BLOCKED`` without burning a repair round.

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
        timeout / uv-missing / FS-refused cases.
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


_UV_COMMAND_RE = re.compile(
    r"\buv\s+(?:run|sync|exec|test|python|lock)\b"
)


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
        "provisioned_at": str(doc.get("provisioned_at") or ""),
    })
    return state


def _resolve_uv_executable() -> str:
    """Return the absolute path of the uv executable on PATH.

    Raises :class:`ValidationEnvironmentError` (infra failure) when uv
    cannot be resolved.
    """
    uv_path = shutil.which("uv")
    if not uv_path:
        raise ValidationEnvironmentError(
            "uv executable not on PATH; cannot provision candidate-bound "
            "project environment"
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
    # No decisive pattern matched. Default to INFRA so the run
    # terminalizes without burning a repair round; the validator
    # owner can reclassify after inspection.
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
    timeout_seconds: int = DEFAULT_PROVISION_TIMEOUT_SECONDS,
) -> dict[str, Any]:
    """Provision the candidate-bound project environment.

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
        failure (uv executable missing, provisioning timeout,
        runtime-cache filesystem refused, registry/network unreachable).
        The run terminalizes as ``BLOCKED`` without burning a repair
        round.

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

    # No uv project in this candidate. There is nothing to sync, but we
    # still publish a marker so the rest of the system knows the env
    # contract was honored. Subsequent ``uv run`` invocations inside
    # this run will fail naturally (no project) and that failure is
    # reported as ``validation_failed``, not ``infra_failure``.
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

    existing = project_environment_status(env_dir)
    if existing["provisioned"] and existing["identity"] == env_id:
        return _outcome_dict(ProvisionOutcome(
            outcome=OUTCOME_PROVISIONED,
            reason="already_provisioned",
            stderr_excerpt="",
            returncode=0,
            timed_out=False,
            marker_path=str(env_dir),
            identity=env_id,
        ), status_fields=existing)

    # Clean any partial / stale provisioning state before re-provisioning.
    # uv refuses to write into a non-empty target when UV_PROJECT_ENVIRONMENT
    # is set, so we must remove any stale partial env first. We do NOT
    # pre-create the env_dir as an empty directory: uv also rejects that
    # ("not a valid Python environment (no Python executable was found)").
    # We let uv create the env itself; a chmod 0700 pass at the end
    # enforces the supervisor-private mode.
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

    try:
        uv_executable = _resolve_uv_executable()
    except ValidationEnvironmentError as exc:
        return _infra(f"uv_executable_unavailable:{exc}")
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
    except OSError as exc:
        return _infra(f"subprocess_spawn_failed:{exc.strerror or exc}")
    duration = time.monotonic() - start
    stdout_bytes = stdout_path.read_bytes() if stdout_path.exists() else b""
    stderr_bytes = stderr_path.read_bytes() if stderr_path.exists() else b""
    excerpt = _excerpt(stderr_bytes, stdout_bytes)
    # Best-effort: clean up the diagnostic artifacts (env_dir
    # itself is the durable artifact, not these captures).
    try:
        stdout_path.unlink()
    except OSError:
        pass
    try:
        stderr_path.unlink()
    except OSError:
        pass

    if returncode == 0 and not timed_out:
        # Tighten the env_dir to supervisor-private mode after uv
        # creates the venv (uv sets the venv to world-readable by
        # default; we want 0700 because the env_dir is validator-
        # owned and the validator subprocess is the only consumer).
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
    return _outcome_dict(ProvisionOutcome(
        outcome=outcome_class,
        reason=label,
        stderr_excerpt=excerpt,
        returncode=returncode,
        timed_out=timed_out,
        marker_path=str(env_dir),
        identity=env_id,
    ))


def command_uses_uv_run(command: str) -> bool:
    """Return True when the command string invokes a uv subcommand that
    requires the project environment to exist.
    """
    return bool(_UV_COMMAND_RE.search(command or ""))


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
    "DEFAULT_PROVISION_TIMEOUT_SECONDS",
    "OUTCOME_CANDIDATE_INVALID",
    "OUTCOME_INFRA_FAILURE",
    "OUTCOME_PROVISIONED",
    "ProvisionOutcome",
    "SCHEMA",
    "ValidationEnvironmentError",
    "candidate_bound_environment_id",
    "classify_sync_failure",
    "command_uses_uv_run",
    "env_overrides",
    "project_environment_dir",
    "project_environment_status",
    "provision_project_environment",
]
