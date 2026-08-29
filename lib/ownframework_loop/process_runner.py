"""Bounded, foreground subprocess execution for the release gate."""

from __future__ import annotations

import os
import signal
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping, Sequence


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str
    timed_out: bool = False


def _terminate_group(proc: subprocess.Popen[str], grace_seconds: float = 3.0) -> None:
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


def run_bounded(
    argv: Sequence[str],
    *,
    cwd: Path,
    timeout_seconds: float,
    env: Mapping[str, str] | None = None,
) -> CommandResult:
    """Run one command in its own process group and always await its exit."""
    proc = subprocess.Popen(
        list(argv),
        cwd=str(cwd),
        env=dict(env) if env is not None else None,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        start_new_session=True,
    )
    try:
        output, _ = proc.communicate(timeout=timeout_seconds)
        return CommandResult(proc.returncode, output)
    except subprocess.TimeoutExpired:
        _terminate_group(proc)
        output, _ = proc.communicate()
        return CommandResult(124, output, timed_out=True)
    except BaseException:
        _terminate_group(proc)
        raise


def process_group_drained(pgid: int) -> bool:
    """Return true when the caller's process group has no foreign members.

    "Drained" means: every process currently sharing the caller's pgid is
    the caller itself. Anything else in our pgid is a leaked child that
    joined our session and never exited — the gate's `start_new_session`
    children all carry their own pgid, so any other-pgid process in our
    pgid is unambiguously a leak. The previous implementation flagged our
    OWN pgid as not-drained whenever our shell session had any siblings
    (which it always does on a real CI runner or developer machine),
    making the probe useless on any environment with a populated shell.

    FAIL-CLOSED: any probe failure (non-zero returncode, empty stdout,
    TimeoutExpired, FileNotFoundError, OSError, missing our own PID in
    the ps listing) returns False. "Unknown process state" is NEVER
    collapsed to "drained" — the release gate and recovery paths must
    prove the tree is empty rather than assume it.
    """
    try:
        result = subprocess.run(
            ["ps", "-axo", "pid=,pgid="],
            capture_output=True, text=True, check=False, timeout=5,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return False
    if result.returncode != 0 or not result.stdout.strip():
        return False
    own_pid = os.getpid()
    foreign_members = 0
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            pid_str, pgid_str = line.split()
            pid = int(pid_str)
            pgrp = int(pgid_str)
        except (ValueError, IndexError):
            # Skip malformed lines rather than mis-classify them as leaks.
            continue
        if pgrp != pgid:
            continue
        if pid == own_pid:
            continue
        foreign_members += 1
    return foreign_members == 0
