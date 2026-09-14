"""Shared deterministic executor for packet-declared validation commands."""

from __future__ import annotations

import hashlib
import os
import subprocess
import time
from pathlib import Path
from typing import Any

from . import runtime_env, secrets_v2, validation_policy


MAX_CAPTURE_BYTES = 64 * 1024
MAX_EXCERPT_CHARS = 4096


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
) -> dict[str, Any]:
    """Run one validation under the sealed capability binding.

    Raw output is retained only in 0600 files below the supervisor-owned
    runtime cache. Authoritative callers receive bounded redacted excerpts and
    digests, enough to identify a failing nested recipe without exposing raw
    command output.
    """
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
    start = time.monotonic()
    timed_out = False
    with stdout_path.open("wb") as stdout_fh, stderr_path.open("wb") as stderr_fh:
        os.chmod(stdout_path, 0o600)
        os.chmod(stderr_path, 0o600)
        env = runtime_env.commissioned_validation_env(
            canonical_repo, run_id, packet
        )
        process = subprocess.Popen(
            ["/bin/sh", "-c", command],
            cwd=str(cwd),
            stdout=stdout_fh,
            stderr=stderr_fh,
            env=env,
        )
        try:
            returncode = process.wait(timeout=timeout_seconds)
        except subprocess.TimeoutExpired:
            timed_out = True
            process.kill()
            process.wait()
            returncode = 124
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
    }


__all__ = ["MAX_CAPTURE_BYTES", "MAX_EXCERPT_CHARS", "run_required_validation"]
