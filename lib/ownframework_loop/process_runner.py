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
    """Return true when the caller has no leaked live direct descendants.

    "Drained" of leaked children means: every direct child of the caller
    whose state is not "Z" (zombie already reaped) has exited. The gate
    uses `run_bounded` with `start_new_session=True` for every
    subprocess, so each child becomes the leader of its own session and
    process group and is reaped by the gate via `proc.communicate()`.
    Any non-zombie direct child still alive at gate end is a leak.

    Zombie children are intentionally counted as drained: they are
    already dead, just not yet `wait()`-ed by their grandparent. Any
    live (R/S/D/T) direct child is a real leak.

    Earlier implementations probed the caller's own pgid, but on any
    real shell (CI runner or developer terminal) the caller's pgid is
    shared with the launching shell and its other children, which made
    that probe useless on populated environments. Direct-parent probing
    is the narrowest correct check for "did we leak a child?".

    FAIL-CLOSED: any probe failure (non-zero returncode, empty stdout,
    TimeoutExpired, FileNotFoundError, OSError) returns False. "Unknown
    process state" is NEVER collapsed to "drained" — the release gate
    and recovery paths must prove the tree is empty rather than assume
    it.
    """
    _ = pgid  # accepted for API symmetry; the drain semantics is by-ppid
    # Reap any zombie children before the probe so a recent fork-exit
    # does not show up as a live child to a race-prone `ps` snapshot.
    try:
        while True:
            waited_pid, _ = os.waitpid(-1, os.WNOHANG)
            if waited_pid <= 0:
                break
    except ChildProcessError:
        pass
    except OSError:
        pass
    try:
        result = subprocess.run(
            ["ps", "-axo", "pid=,ppid=,stat=,comm="],
            capture_output=True, text=True, check=False, timeout=5,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return False
    if result.returncode != 0 or not result.stdout.strip():
        return False
    own_pid = os.getpid()
    live_children = 0
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        try:
            pid_str, ppid_str, stat, comm = parts[0], parts[1], parts[2], parts[3]
            ppid = int(ppid_str)
        except ValueError:
            continue
        if ppid != own_pid:
            continue
        # Zombies are already-dead children not yet reaped; not a leak.
        if stat.startswith("Z"):
            continue
        # The probe's own `ps` child appears in ps's own row at the moment
        # ps walks /proc. That is the calling-side race, not a leak.
        if pid_str == str(own_pid):
            continue
        if comm.startswith("ps"):
            continue
        live_children += 1
    return live_children == 0
