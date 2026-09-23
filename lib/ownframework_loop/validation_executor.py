"""Shared deterministic executor for packet-declared validation commands.

Candidate-bound project environment
==================================

When a validation command invokes ``uv run`` (or any other uv subcommand
that requires the project environment to exist), the deterministic
validator owns the project environment instead of letting uv auto-sync a
``.venv`` next to the candidate. See
:mod:`ownframework_loop.validation_environment` for the full design.

The executor is responsible for:

  1. Detecting uv-mediated commands and pre-provisioning the
     candidate-bound environment before the subprocess is launched.
  2. Binding ``UV_PROJECT_ENVIRONMENT`` / ``VIRTUAL_ENV`` into the
     hermetic subprocess env so uv honors the validator-owned path
     instead of auto-syncing inside the candidate worktree.
  3. Classifying a provisioning failure as ``infra_failure`` so the
     finalizers can refuse the run without burning a semantic repair
     round. Infra failure is a distinct envelope from validation
     failure.
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import time
import uuid
from pathlib import Path
from typing import Any

from . import (
    process_runner,
    runtime_env,
    secrets_v2,
    validation_environment,
    validation_policy,
)


MAX_CAPTURE_BYTES = 64 * 1024
MAX_EXCERPT_CHARS = 4096


def _terminate_validation_group(
    process: subprocess.Popen[Any], grace_seconds: float = 3.0
) -> None:
    """Terminate/reap the whole validation group, including post-leader children."""
    process_runner.terminate_process_group(process, grace_seconds=grace_seconds)


def command_uses_uv_run(command: str) -> bool:
    """Public surface for the uv-command classifier."""
    return validation_environment.is_uv_command(command)


def _resolution_names(resolution: dict[str, Any]) -> list[str]:
    return [str(item.get("name") or "") for item in (resolution.get("resolved") or [])]


def _extract_bound_uv_from_resolution(
    resolution: dict[str, Any],
) -> validation_environment.BoundUvIdentity | None:
    for item in (resolution.get("resolved") or []):
        if str(item.get("name") or "") == "package.uv":
            return validation_environment.build_bound_uv_identity(
                item,
                cache_path=str(item.get("cache_path") or ""),
                cache_scope=str(item.get("cache_scope") or ""),
            )
    return None


def _cached_environment_matches_bound_uv(
    status: dict[str, Any],
    bound_uv: validation_environment.BoundUvIdentity,
) -> bool:
    if not status.get("provisioned") or status.get("package_uv_unbound"):
        return False
    no_project = str(status.get("metadata_sha256") or "") == "no-pyproject"
    uv_executable = str(status.get("uv_executable") or "")
    uv_executable_matches = (
        (no_project and not uv_executable)
        or uv_executable == bound_uv.executable
    )
    return (
        uv_executable_matches
        and str(status.get("bound_uv_sha256") or "") == bound_uv.executable_sha256
        and str(status.get("bound_uv_version") or "") == bound_uv.version
        and str(status.get("bound_uv_cache_path") or "") == bound_uv.cache_path
        and str(status.get("bound_uv_cache_scope") or "") == bound_uv.cache_scope
        and sorted(str(v) for v in (status.get("bound_uv_network_domains") or []))
        == sorted(bound_uv.network_domains)
    )


def _file_snapshot(path: Path) -> tuple[bytes, int, str]:
    digest = hashlib.sha256()
    size = 0
    prefix = bytearray()
    with path.open("rb") as fh:
        while True:
            chunk = fh.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            size += len(chunk)
            if len(prefix) < MAX_CAPTURE_BYTES:
                prefix.extend(chunk[: MAX_CAPTURE_BYTES - len(prefix)])
    return bytes(prefix), size, digest.hexdigest()


def _redacted_excerpt(data: bytes) -> str:
    text = data.decode("utf-8", errors="replace")
    findings = secrets_v2.scan_text_for_redacted(text, source="validation-output")
    secret_lines = {
        int(item["line"])
        for item in findings
        if isinstance(item.get("line"), int) and item.get("line") >= 1
    }
    lines = text.splitlines(keepends=True)
    safe: list[str] = []
    for number, line in enumerate(lines, start=1):
        if number in secret_lines:
            safe.append("[redacted secret-like validation output line]\n")
        else:
            safe.append(line)
    excerpt = "".join(safe)
    if len(excerpt) > MAX_EXCERPT_CHARS:
        excerpt = excerpt[:MAX_EXCERPT_CHARS] + "\n[excerpt truncated]"
    return excerpt


def _diagnostic_paths(
    canonical_repo: Path,
    run_id: str,
    cwd: Path,
    command: str,
) -> tuple[Path, Path]:
    root = runtime_env.runtime_cache_dir(canonical_repo, run_id, "validation")
    directory = root / "validation-diagnostics"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(directory, 0o700)
    identity = hashlib.sha256(
        (str(cwd) + "\0" + command).encode("utf-8", errors="replace")
    ).hexdigest()[:32]
    return directory / f"{identity}.stdout", directory / f"{identity}.stderr"


def run_required_validation(
    *,
    cwd: Path,
    validation: dict[str, Any],
    timeout_seconds: int,
    canonical_repo: Path,
    run_id: str,
    packet: dict[str, Any],
    candidate_sha: str | None = None,
    role: str = "builder",
    infra_failure_path: Path | None = None,
) -> dict[str, Any]:
    """Run one validation under the sealed capability binding."""
    command = str(validation.get("command") or "")
    name = str(validation.get("name") or "validation")
    kind = str(validation.get("kind") or "fast")
    policy = validation_policy.classify_required_validation(command, run_id=run_id)
    if not policy.get("allowed"):
        raise RuntimeError(
            "required_validation command refused by deterministic authority policy: "
            + str(policy.get("reason") or "forbidden command")
        )

    stdout_path, stderr_path = _diagnostic_paths(
        canonical_repo, run_id, cwd, command
    )
    env_overrides: dict[str, str] = {}
    infra_failure = False
    infra_failure_reason = ""
    candidate_invalid = False
    candidate_invalid_reason = ""
    candidate_invalid_excerpt = ""
    env_id = ""
    env_dir = None
    bound_uv: validation_environment.BoundUvIdentity | None = None
    needs_uv = validation_environment.is_uv_command(command)
    if needs_uv:
        if not candidate_sha:
            infra_failure = True
            infra_failure_reason = (
                "uv-mediated validation command requires candidate_sha; "
                "the finalizer did not pass it through"
            )
        else:
            try:
                resolution = runtime_env.commissioned_validation_resolution(
                    canonical_repo, run_id, packet
                )
            except Exception as exc:  # noqa: BLE001 — boundary
                infra_failure = True
                infra_failure_reason = f"bound_uv_resolution_failed:{exc}"
            else:
                resolution_names = _resolution_names(resolution)
                try:
                    bound_uv = _extract_bound_uv_from_resolution(resolution)
                except validation_environment.ValidationEnvironmentError as exc:
                    infra_failure = True
                    infra_failure_reason = (
                        "bound_uv_resolution_missing_fields: package.uv "
                        f"resolution is incomplete: {exc}"
                    )
                else:
                    if bound_uv is None:
                        infra_failure = True
                        if "package.uv" in resolution_names:
                            infra_failure_reason = (
                                "bound_uv_resolution_missing_fields: package.uv "
                                "resolved but executable/version/sha256 absent"
                            )
                        else:
                            infra_failure_reason = (
                                "bound_uv_capability_not_bound: uv-mediated validation "
                                "requires frozen package.uv authority"
                            )
                    else:
                        env_id = validation_environment.candidate_bound_environment_id(
                            str(candidate_sha), cwd
                        )
                        env_dir = validation_environment.project_environment_dir(
                            canonical_repo, run_id, role, env_id
                        )
                        existing = validation_environment.project_environment_status(env_dir)
                        if existing.get("provisioned") and not _cached_environment_matches_bound_uv(
                            existing, bound_uv
                        ):
                            infra_failure = True
                            infra_failure_reason = (
                                "bound_uv_cached_environment_mismatch: existing project "
                                "environment was not provisioned under the full frozen "
                                "package.uv binding"
                            )
            if not infra_failure:
                try:
                    outcome = validation_environment.provision_project_environment(
                        canonical_repo=canonical_repo,
                        run_id=run_id,
                        role=role,
                        candidate_sha=str(candidate_sha),
                        candidate_worktree=cwd,
                        bound_uv=bound_uv,
                    )
                except validation_environment.ValidationEnvironmentError as exc:
                    infra_failure = True
                    infra_failure_reason = str(exc)
                else:
                    env_id = str(outcome.get("identity") or "")
                    env_dir = Path(str(outcome.get("marker_path") or "")).expanduser().resolve(strict=False)
                    outcome_class = str(outcome.get("outcome") or "")
                    if outcome_class == validation_environment.OUTCOME_PROVISIONED:
                        env_overrides = validation_environment.env_overrides(env_dir)
                    elif outcome_class == validation_environment.OUTCOME_CANDIDATE_INVALID:
                        candidate_invalid = True
                        candidate_invalid_reason = str(outcome.get("reason") or "")
                        candidate_invalid_excerpt = str(outcome.get("stderr_excerpt") or "")
                    else:
                        infra_failure = True
                        infra_failure_reason = str(outcome.get("reason") or "")

    if infra_failure and infra_failure_path is not None:
        _write_infra_failure_marker(infra_failure_path, {
            "name": name,
            "command": command,
            "reason": infra_failure_reason,
            "validation_env_id": env_id,
            "validation_env_path": str(env_dir) if env_dir is not None else "",
            "recorded_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        })

    if infra_failure:
        return {
            "name": name,
            "command": command,
            "kind": kind,
            "exit_code": None,
            "duration_seconds": 0.0,
            "expected_exit_code": int(
                validation.get("expected_exit_code")
                if validation.get("expected_exit_code") is not None
                else 0
            ),
            "passed": False,
            "timed_out": False,
            "marker_match": False,
            "stdout_truncated": False,
            "stderr_truncated": False,
            "output_truncated": False,
            "stdout_excerpt_redacted": "",
            "stderr_excerpt_redacted": "",
            "stdout_sha256": "",
            "stderr_sha256": "",
            "diagnostic_stdout_path": str(stdout_path),
            "diagnostic_stderr_path": str(stderr_path),
            "infra_failure": True,
            "infra_failure_reason": infra_failure_reason,
            "candidate_invalid": False,
            "validation_env_id": env_id,
            "validation_env_path": str(env_dir) if env_dir is not None else "",
        }

    if candidate_invalid:
        return {
            "name": name,
            "command": command,
            "kind": kind,
            "exit_code": None,
            "duration_seconds": 0.0,
            "expected_exit_code": int(
                validation.get("expected_exit_code")
                if validation.get("expected_exit_code") is not None
                else 0
            ),
            "passed": False,
            "timed_out": False,
            "marker_match": False,
            "stdout_truncated": False,
            "stderr_truncated": False,
            "output_truncated": False,
            "stdout_excerpt_redacted": "",
            "stderr_excerpt_redacted": "",
            "stdout_sha256": "",
            "stderr_sha256": "",
            "diagnostic_stdout_path": str(stdout_path),
            "diagnostic_stderr_path": str(stderr_path),
            "infra_failure": False,
            "candidate_invalid": True,
            "candidate_invalid_reason": candidate_invalid_reason,
            "candidate_invalid_excerpt": candidate_invalid_excerpt,
            "validation_env_id": env_id,
            "validation_env_path": str(env_dir) if env_dir is not None else "",
        }

    start = time.monotonic()
    timed_out = False
    with stdout_path.open("wb") as stdout_fh, stderr_path.open("wb") as stderr_fh:
        os.chmod(stdout_path, 0o600)
        os.chmod(stderr_path, 0o600)
        if needs_uv and bound_uv is not None:
            try:
                validation_environment.verify_bound_uv_identity(bound_uv)
            except validation_environment.ValidationEnvironmentError as exc:
                infra_failure_reason = f"bound_uv_drift_pre_launch:{exc}"
                if infra_failure_path is not None:
                    _write_infra_failure_marker(infra_failure_path, {
                        "name": name,
                        "command": command,
                        "reason": infra_failure_reason,
                        "validation_env_id": env_id,
                        "validation_env_path": str(env_dir) if env_dir is not None else "",
                        "recorded_at": time.strftime(
                            "%Y-%m-%dT%H:%M:%SZ", time.gmtime()
                        ),
                    })
                return {
                    "name": name,
                    "command": command,
                    "kind": kind,
                    "exit_code": None,
                    "duration_seconds": float(time.monotonic() - start),
                    "expected_exit_code": int(
                        validation.get("expected_exit_code")
                        if validation.get("expected_exit_code") is not None
                        else 0
                    ),
                    "passed": False,
                    "timed_out": False,
                    "marker_match": False,
                    "stdout_truncated": False,
                    "stderr_truncated": False,
                    "output_truncated": False,
                    "stdout_excerpt_redacted": "",
                    "stderr_excerpt_redacted": "",
                    "stdout_sha256": "",
                    "stderr_sha256": "",
                    "diagnostic_stdout_path": str(stdout_path),
                    "diagnostic_stderr_path": str(stderr_path),
                    "infra_failure": True,
                    "infra_failure_reason": infra_failure_reason,
                    "candidate_invalid": False,
                    "validation_env_id": env_id,
                    "validation_env_path": str(env_dir) if env_dir is not None else "",
                }
        env = runtime_env.commissioned_validation_env(
            canonical_repo, run_id, packet
        )
        for key, value in env_overrides.items():
            env[key] = value
        process = subprocess.Popen(
            ["/bin/sh", "-c", command],
            cwd=str(cwd),
            stdout=stdout_fh,
            stderr=stderr_fh,
            env=env,
            start_new_session=True,
        )
        try:
            returncode = process.wait(timeout=timeout_seconds)
        except subprocess.TimeoutExpired:
            timed_out = True
            _terminate_validation_group(process)
            returncode = 124
        except BaseException:
            _terminate_validation_group(process)
            raise
        else:
            if process_runner.process_group_exists(process.pid):
                _terminate_validation_group(process)
                returncode = process_runner.PROCESS_GROUP_LEAK_RC
                stderr_fh.write(
                    ("\n" + process_runner.PROCESS_GROUP_LEAK_MARKER + "\n").encode("utf-8")
                )
                stderr_fh.flush()
    duration = time.monotonic() - start

    stdout_prefix, stdout_size, stdout_sha = _file_snapshot(stdout_path)
    stderr_prefix, stderr_size, stderr_sha = _file_snapshot(stderr_path)
    stdout_text = stdout_prefix.decode("utf-8", errors="replace")
    stderr_text = stderr_prefix.decode("utf-8", errors="replace")
    expected_exit = int(
        validation.get("expected_exit_code")
        if validation.get("expected_exit_code") is not None
        else 0
    )
    expected_marker = validation.get("expected_marker")
    marker_match = (
        True
        if expected_marker is None
        else str(expected_marker) in stdout_text + stderr_text
    )
    passed = (
        not timed_out
        and int(returncode) == expected_exit
        and marker_match
    )
    return {
        "name": name,
        "command": command,
        "kind": kind,
        "exit_code": int(returncode),
        "duration_seconds": float(duration),
        "expected_exit_code": expected_exit,
        "passed": passed,
        "timed_out": timed_out,
        "marker_match": marker_match,
        "stdout_truncated": stdout_size > MAX_CAPTURE_BYTES,
        "stderr_truncated": stderr_size > MAX_CAPTURE_BYTES,
        "output_truncated": (
            stdout_size > MAX_CAPTURE_BYTES or stderr_size > MAX_CAPTURE_BYTES
        ),
        "stdout_excerpt_redacted": _redacted_excerpt(stdout_prefix),
        "stderr_excerpt_redacted": _redacted_excerpt(stderr_prefix),
        "stdout_sha256": stdout_sha,
        "stderr_sha256": stderr_sha,
        "diagnostic_stdout_path": str(stdout_path),
        "diagnostic_stderr_path": str(stderr_path),
        "infra_failure": False,
        "candidate_invalid": False,
        "validation_env_id": env_id,
        "validation_env_path": str(env_dir) if env_dir is not None else "",
    }


def _write_infra_failure_marker(path: Path, payload: dict[str, Any]) -> None:
    path = Path(path).expanduser().resolve(strict=False)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(path.parent, 0o700)
    except OSError:
        pass
    tmp = path.with_name(f".{path.name}.{os.getpid()}.{uuid.uuid4().hex}.tmp")
    tmp.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    try:
        os.chmod(tmp, 0o600)
    except OSError:
        pass
    os.replace(tmp, path)


__all__ = [
    "MAX_CAPTURE_BYTES",
    "MAX_EXCERPT_CHARS",
    "run_required_validation",
]
