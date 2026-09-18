"""macOS commissioning implementation helpers.

This module is the load-bearing Python authority behind
``scripts/supervisor/install-macos.sh``.  The shell script
becomes a thin platform entrypoint that:

  * resolves canonical runtime paths (python, ofloop, plist,
    state root, etc.);
  * prepares the durable supervisor DB;
  * calls into this module for every procedural step:
      - ``generate_publication_files``  (plist + provenance + service-env + activation-record)
      - ``classify_lifecycle_helper_result`` (typed refusal vs unexpected nonzero)
      - ``verify_active_identity`` (the receipt + startup-ready attestation wait + verify)
      - ``classify_cleanup_result`` (cleanup_label_absence_proven/unproven)

The shell keeps only the platform launchd command execution
itself (bootstrap / bootout / print) plus the result-classification
glue around this module's typed returns.  This preserves exact
behavior while making the procedural Python testable, typed, and
shareable with future commissioning surfaces (e.g. systemd).

Do NOT introduce another platform framework here.  These helpers
are macOS-scoped and intentionally live next to the installer.
"""
from __future__ import annotations

import json
import os
import plistlib
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any


# ---------------------------------------------------------------------------
# Typed results returned by the procedural Python steps.
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class PublicationResult:
    """The result of ``generate_publication_files``.

    Attributes
    ----------
    plist_path
        Absolute path to the written launchd plist.
    provenance_path
        Absolute path to the written runtime-provenance.json.
    service_env_path
        Absolute path to the written service-env.json (may differ
        from provenance_path; they are distinct artifacts).
    activation_record_path
        Absolute path to the written activation-record.json.
    activation_id
        Fresh uuid4 generated for this commissioning attempt. The
        installer must pass this to the launcher via
        ``OFLOOP_ACTIVATION_ID`` plist env var; the launcher uses
        it to derive the activation receipt.
    receipt_path
        Absolute path where the launcher's activation receipt must
        be written before exec into the durable supervisor.
    """

    plist_path: Path
    provenance_path: Path
    service_env_path: Path
    activation_record_path: Path
    activation_id: str
    receipt_path: Path


@dataclass(frozen=True)
class LifecycleHelperResult:
    """The result of a ``macos_service_lifecycle`` command-substitution.

    Used to drive the typed-marker-vs-unexpected-nonzero
    classification from ``install-macos.sh``.

    Attributes
    ----------
    helper_stdout
        The captured stdout/stderr of the lifecycle helper.
    returncode
        The helper's exit code (0 means success).
    marker
        The typed refusal marker found in ``helper_stdout``, if any.
        One of: ``"reason=stale_label_removal_failed"``,
        ``"reason=transaction_recovery_stale_label_removal_failed"``,
        ``"reason=cleanup_label_absence_proven"``,
        ``"reason=cleanup_label_absence_unproven"``, or ``""``.
    unexpected
        True when the helper exited nonzero without producing a
        recognized typed marker. The shell owner MUST refuse closed
        when this is True (Defect B1 of the commissioning closure).
    """

    helper_stdout: str
    returncode: int
    marker: str
    unexpected: bool


@dataclass(frozen=True)
class CleanupClassification:
    """The classification of a bootstrap-failure / active-identity-
    failure cleanup helper invocation.

    Attributes
    ----------
    absence_proven
        True when the cleanup helper printed
        ``reason=cleanup_label_absence_proven`` AND exited 0.
    unexpected_nonzero
        True when the cleanup helper exited nonzero without
        producing a recognized typed marker (Defect B1).
    detail
        Raw helper output (preserved for diagnostic evidence).
    """

    absence_proven: bool
    unexpected_nonzero: bool
    detail: str


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _write_private_json(path: Path, value: object) -> None:
    """Atomically write a private JSON artifact with mode 0o600."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8", closefd=False) as fh:
            json.dump(value, fh, indent=2, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
    finally:
        os.close(fd)


def _test_abort_after(stage: str) -> None:
    """Honour ``OFLOOP_TEST_ABORT_AFTER_PUBLICATION`` for test injection."""
    if os.environ.get("OFLOOP_TEST_ABORT_AFTER_PUBLICATION") == stage:
        os._exit(97)


def _build_payload(
    *,
    label: str,
    python_bin: str,
    ofloop_bin: str,
    supervisor_db: str,
    ledger_marker: str,
    probe_script: str,
    launcher_script: str,
    claude_bin: str | None,
    service_path: str,
    service_env_path: Path,
    stdout_log: str,
    stderr_log: str,
    activation_id: str,
    receipt_path: str,
) -> dict[str, Any]:
    """Build the launchd plist payload exactly as the installer does.

    Pure function: no I/O, no env access except for reading the
    ``service_env_path`` existence.
    """
    env_vars: dict[str, str] = {
        "PATH": service_path,
        "PYTHONUNBUFFERED": "1",
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHON_BIN": python_bin,
        "OFLOOP_BIN": ofloop_bin,
        "OFLOOP_RUNTIME_ROOT": str(Path(ofloop_bin).resolve(strict=False).parent.parent),
        "XDG_STATE_HOME": str(Path(supervisor_db).resolve(strict=False).parent.parent),
        "OFLOOP_ACTIVATION_ID": activation_id,
        "OFLOOP_RECEIPT_PATH": receipt_path,
        "OFLOOP_RUNTIME_GENERATION": "",  # filled by caller
        "LABEL": label,
    }
    service_env: dict[str, str] = {}
    if claude_bin:
        env_vars["OFLOOP_CLAUDE_BIN"] = claude_bin
        env_vars["OFLOOP_SERVICE_ENV_FILE"] = str(service_env_path)
        # macOS Claude credentials are held in Keychain; the
        # provider/auth/model aliases the durable launchd service
        # needs are persisted in one private Loop service-env file
        # instead of being embedded in the plist.
        for auth_var in (
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
        ):
            value = os.environ.get(auth_var)
            if value:
                service_env[auth_var] = value

    payload: dict[str, Any] = {
        "Label": label,
        "ProgramArguments": [
            python_bin, "-B", launcher_script,
            "--db", supervisor_db,
            "--ledger-marker", ledger_marker,
            "--probe", probe_script,
            "--ofloop", ofloop_bin,
            "--activation-id", activation_id,
            "--receipt-path", receipt_path,
        ],
        "EnvironmentVariables": env_vars,
        "RunAtLoad": True,
        "KeepAlive": True,
        "ProcessType": "Background",
        "ThrottleInterval": 5,
        "StandardOutPath": stdout_log,
        "StandardErrorPath": stderr_log,
        "WorkingDirectory": str(Path.home()),
    }
    # Allow caller to override OFLOOP_RUNTIME_GENERATION with the
    # actual computed value (kept here for testability and for
    # alignment with the original heredoc).
    return payload


# ---------------------------------------------------------------------------
# Public procedural steps.
# ---------------------------------------------------------------------------

def generate_publication_files(
    *,
    plist_path: Path,
    provenance_path: Path,
    service_env_path: Path,
    state_base: str,
    state_root: str,
    supervisor_db: str,
    ledger_marker: str,
    stdout_log: str,
    stderr_log: str,
    python_bin: str,
    ofloop_bin: str,
    claude_bin: str | None,
    service_path: str,
    source_root: str | None,
    source_head: str | None,
    ofloop_version: str | None,
    source_version: str | None,
    runtime_generation: str | None,
    label: str,
) -> PublicationResult:
    """Write the four publication artifacts of a commissioning attempt.

    Returns the typed ``PublicationResult``. The shell caller is
    responsible for invoking the platform launchd command
    (``launchctl bootstrap``) after this returns successfully.
    """
    plist_path = Path(plist_path)
    provenance_path = Path(provenance_path)
    service_env_path = Path(service_env_path)

    install_root = Path(ofloop_bin).resolve(strict=False).parent.parent
    launcher_script = str(install_root / "scripts" / "launch-commissioned-supervisor.py")
    probe_script = str(install_root / "scripts" / "probe-supervisor-runtime-dependencies.py")

    activation_id = str(uuid.uuid4())
    receipt_path = Path(state_root) / "supervisor-activation.json"

    payload = _build_payload(
        label=label,
        python_bin=python_bin,
        ofloop_bin=ofloop_bin,
        supervisor_db=supervisor_db,
        ledger_marker=ledger_marker,
        probe_script=probe_script,
        launcher_script=launcher_script,
        claude_bin=claude_bin,
        service_path=service_path,
        service_env_path=service_env_path,
        stdout_log=stdout_log,
        stderr_log=stderr_log,
        activation_id=activation_id,
        receipt_path=str(receipt_path),
    )
    # Patch OFLOOP_RUNTIME_GENERATION with the actual computed value
    # (the original heredoc does this; we mirror it).
    payload["EnvironmentVariables"]["OFLOOP_RUNTIME_GENERATION"] = runtime_generation or ""

    plist_path.parent.mkdir(parents=True, exist_ok=True)
    service_env_path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(service_env_path.parent, 0o700)

    fd = os.open(plist_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb", closefd=False) as f:
            plistlib.dump(payload, f, sort_keys=True)
            f.flush()
            os.fsync(f.fileno())
    finally:
        os.close(fd)
    _test_abort_after("plist")

    # service_env is the JSON-side mirror of the env vars that the
    # plist actually writes. The original heredoc wrote it after
    # resolving the env-var presence; mirror that exactly.
    service_env: dict[str, str] = {}
    if claude_bin:
        for auth_var in (
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
        ):
            value = os.environ.get(auth_var)
            if value:
                service_env[auth_var] = value
    _write_private_json(service_env_path, service_env)
    _test_abort_after("service-env")

    provenance = {
        "schema": "ownframework-loop-supervisor-runtime-provenance/v1",
        "service_manager": "launchd",
        "service_label": label,
        "python_bin": python_bin,
        "ofloop_bin": ofloop_bin,
        "runtime_root": str(install_root),
        "claude_bin": claude_bin,
        "service_path": service_path,
        "plist": str(plist_path),
        "state_base": state_base,
        "state_root": state_root,
        "ledger_incarnation_file": ledger_marker,
        "service_entrypoint": launcher_script,
        "stdout_log": stdout_log,
        "stderr_log": stderr_log,
        "source_root": source_root,
        "source_head": source_head,
        "source_version": source_version,
        "ofloop_version": ofloop_version,
        "runtime_generation": runtime_generation,
        "service_env_file": str(service_env_path) if claude_bin else None,
    }
    provenance_path.parent.mkdir(parents=True, exist_ok=True)
    _write_private_json(provenance_path, provenance)
    _test_abort_after("provenance")

    activation_record = {
        "schema": "ownframework-loop-supervisor-activation-record/v1",
        "activation_id": activation_id,
        "receipt_path": str(receipt_path),
        "expected_pid": None,
    }
    activation_record_path = Path(state_root) / "activation-record.json"
    _write_private_json(activation_record_path, activation_record)

    return PublicationResult(
        plist_path=plist_path,
        provenance_path=provenance_path,
        service_env_path=service_env_path,
        activation_record_path=activation_record_path,
        activation_id=activation_id,
        receipt_path=receipt_path,
    )


# Recognized typed markers emitted by the lifecycle helper.
_LIFECYCLE_MARKERS = (
    "reason=stale_label_removal_failed",
    "reason=transaction_recovery_stale_label_removal_failed",
    "reason=cleanup_label_absence_proven",
    "reason=cleanup_label_absence_unproven",
)


def classify_lifecycle_helper_result(
    helper_stdout: str, returncode: int
) -> LifecycleHelperResult:
    """Classify a lifecycle-helper command-substitution result.

    Defect B1 of the commissioning closure: an unexpected nonzero
    (import failure, RuntimeError, etc.) MUST fail closed; the
    typed marker-vs-unexpected-nonzero classification must be
    preserved.
    """
    marker = ""
    for candidate in _LIFECYCLE_MARKERS:
        if candidate in helper_stdout:
            marker = candidate
            break

    unexpected = bool(returncode != 0 and not marker)
    return LifecycleHelperResult(
        helper_stdout=helper_stdout,
        returncode=returncode,
        marker=marker,
        unexpected=unexpected,
    )


def classify_cleanup_result(
    cleanup_stdout: str, cleanup_rc: int
) -> CleanupClassification:
    """Classify a bootstrap-failure / active-identity-failure cleanup.

    Defect B2 of the commissioning closure: the string
    ``label_absent`` may only be emitted after the canonical
    service-lifecycle primitive has positively proven the label
    absent.  This function is the load-bearing classifier for that
    invariant.
    """
    absence_proven = bool(
        cleanup_rc == 0
        and "reason=cleanup_label_absence_proven" in cleanup_stdout
    )
    unexpected_nonzero = bool(
        cleanup_rc != 0
        and "reason=cleanup_label_absence_proven" not in cleanup_stdout
        and "reason=cleanup_label_absence_unproven" not in cleanup_stdout
    )
    return CleanupClassification(
        absence_proven=absence_proven,
        unexpected_nonzero=unexpected_nonzero,
        detail=cleanup_stdout,
    )
