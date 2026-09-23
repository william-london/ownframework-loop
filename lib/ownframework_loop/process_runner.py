"""Bounded, foreground subprocess execution for Loop-owned effects."""

from __future__ import annotations

import os
import signal
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping, Sequence


PROCESS_GROUP_LEAK_RC = 125
PROCESS_GROUP_LEAK_MARKER = "OFLOOP_PROCESS_GROUP_LEAK=refused"


class ProcessGroupLeakError(subprocess.SubprocessError):
    """A direct command exited while descendants remained alive."""

    def __init__(self, argv: Sequence[str], stdout: str = "", stderr: str = "") -> None:
        super().__init__(PROCESS_GROUP_LEAK_MARKER)
        self.argv = list(argv)
        self.stdout = stdout
        self.stderr = stderr
        self.returncode = PROCESS_GROUP_LEAK_RC


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str
    timed_out: bool = False


def process_group_exists(pgid: int) -> bool:
    """Return whether a POSIX process group still has any members."""
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def terminate_process_group(
    proc: subprocess.Popen[str], grace_seconds: float = 3.0
) -> None:
    """Terminate a whole child group even when its original leader exited.

    ``Popen.poll()`` only tells us about the direct child. A shell/wrapper may
    exit while descendants remain in the process group, so leader exit is never
    accepted as proof that the group is drained.
    """
    pgid = proc.pid
    try:
        os.killpg(pgid, signal.SIGTERM)
    except ProcessLookupError:
        if proc.poll() is None:
            proc.wait()
        return

    deadline = time.monotonic() + grace_seconds
    while process_group_exists(pgid) and time.monotonic() < deadline:
        proc.poll()
        time.sleep(0.05)

    if process_group_exists(pgid):
        try:
            os.killpg(pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    if proc.poll() is None:
        proc.wait()


# Backward-compatible private name used by older imports/tests.
_terminate_group = terminate_process_group


def run_bounded_capture(
    argv: Sequence[str],
    *,
    cwd: Path | str | None = None,
    timeout_seconds: float | None = None,
    env: Mapping[str, str] | None = None,
    stdin: int | None = subprocess.DEVNULL,
) -> subprocess.CompletedProcess[str]:
    """Run explicit argv with separate captured streams and bounded lifecycle.

    The child is always the leader of a fresh session/process group. Timeout
    drains descendants before the traditional ``TimeoutExpired`` contract is
    re-raised. Normal direct-child completion is accepted only after the whole
    process group is empty. A surviving descendant is terminated and raises
    ``ProcessGroupLeakError``; lifecycle refusal is exceptional so callers can
    never accidentally treat diagnostic output as successful authority.
    """
    proc = subprocess.Popen(
        list(argv),
        cwd=str(cwd) if cwd is not None else None,
        env=dict(env) if env is not None else None,
        stdin=stdin,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    try:
        stdout, stderr = proc.communicate(timeout=timeout_seconds)
    except subprocess.TimeoutExpired as exc:
        terminate_process_group(proc)
        stdout, stderr = proc.communicate()
        raise subprocess.TimeoutExpired(
            list(argv), timeout_seconds, output=stdout, stderr=stderr
        ) from exc
    except BaseException:
        terminate_process_group(proc)
        raise

    if process_group_exists(proc.pid):
        terminate_process_group(proc)
        raise ProcessGroupLeakError(list(argv), stdout or "", stderr or "")

    return subprocess.CompletedProcess(
        args=list(argv),
        returncode=int(proc.returncode),
        stdout=stdout,
        stderr=stderr,
    )


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
    except subprocess.TimeoutExpired:
        terminate_process_group(proc)
        output, _ = proc.communicate()
        return CommandResult(124, output, timed_out=True)
    except BaseException:
        terminate_process_group(proc)
        raise

    if process_group_exists(proc.pid):
        terminate_process_group(proc)
        output = (output or "") + "\n" + PROCESS_GROUP_LEAK_MARKER + "\n"
        return CommandResult(PROCESS_GROUP_LEAK_RC, output)
    return CommandResult(int(proc.returncode), output)


def process_group_drained(pgid: int) -> bool:
    """Return true when the caller has no leaked live direct descendants.

    "Drained" of leaked children means: every direct child of the caller
    whose state is not "Z" (zombie already reaped) has exited. The gate
    uses group-bounded subprocess execution for every owned effect. Any
    non-zombie direct child still alive at gate end is therefore a leak.

    FAIL-CLOSED: any probe failure returns False. "Unknown process state" is
    never collapsed to "drained".
    """
    _ = pgid
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
        if stat.startswith("Z"):
            continue
        if pid_str == str(own_pid):
            continue
        if comm.startswith("ps"):
            continue
        live_children += 1
    return live_children == 0


__all__ = [
    "CommandResult",
    "PROCESS_GROUP_LEAK_MARKER",
    "PROCESS_GROUP_LEAK_RC",
    "ProcessGroupLeakError",
    "process_group_drained",
    "process_group_exists",
    "run_bounded",
    "run_bounded_capture",
    "terminate_process_group",
]
