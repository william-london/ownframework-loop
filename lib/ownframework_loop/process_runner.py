"""Bounded, foreground subprocess execution for Loop-owned effects."""

from __future__ import annotations

import os
import signal
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, BinaryIO, Mapping, Sequence


PROCESS_GROUP_LEAK_RC = 125
PROCESS_GROUP_LEAK_MARKER = "OFLOOP_PROCESS_GROUP_LEAK=refused"
_POST_KILL_DRAIN_SECONDS = 1.0
_POST_KILL_POLL_SECONDS = 0.05


class ProcessGroupLeakError(subprocess.SubprocessError):
    """A direct command exited while descendants remained alive."""

    def __init__(self, argv: Sequence[str], stdout: Any = "", stderr: Any = "") -> None:
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
    proc: subprocess.Popen[Any], grace_seconds: float = 3.0
) -> None:
    """Terminate a whole child group even when its original leader exited.

    ``Popen.poll()`` only tells us about the direct child. A shell/wrapper may
    exit while descendants remain in the process group, so leader exit is never
    accepted as proof that the group is drained.
    """
    pgid = proc.pid
    argv = getattr(proc, "args", None) or [f"pid={pgid}"]
    try:
        os.killpg(pgid, signal.SIGTERM)
    except ProcessLookupError:
        pass

    deadline = time.monotonic() + max(0.0, float(grace_seconds))
    while True:
        proc.poll()
        group_alive = process_group_exists(pgid)
        if not group_alive and proc.poll() is not None:
            # poll() reaps the direct child on Popen implementations; wait()
            # here is consequently non-blocking but makes the ownership
            # contract explicit for compatible Popen-like test doubles.
            try:
                proc.wait(timeout=0)
            except subprocess.TimeoutExpired:
                pass
            if proc.poll() is not None:
                return
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        time.sleep(min(_POST_KILL_POLL_SECONDS, remaining))

    if process_group_exists(pgid):
        try:
            os.killpg(pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    kill_deadline = time.monotonic() + _POST_KILL_DRAIN_SECONDS
    while True:
        proc.poll()
        group_alive = process_group_exists(pgid)
        if not group_alive:
            try:
                proc.wait(timeout=max(0.0, kill_deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                pass
            if proc.poll() is not None:
                return
        remaining = kill_deadline - time.monotonic()
        if remaining <= 0:
            break
        time.sleep(min(_POST_KILL_POLL_SECONDS, remaining))

    raise ProcessGroupLeakError(argv)


def _communicate_after_termination(
    proc: subprocess.Popen[Any], argv: Sequence[str], timeout_seconds: float = 1.0
) -> tuple[Any, Any]:
    """Drain pipes with a bound after the owned process group was killed."""
    try:
        return proc.communicate(timeout=timeout_seconds)
    except subprocess.TimeoutExpired as exc:
        for stream in (proc.stdin, proc.stdout, proc.stderr):
            if stream is not None:
                try:
                    stream.close()
                except OSError:
                    pass
        raise ProcessGroupLeakError(argv) from exc


# Backward-compatible private name used by older imports/tests.
_terminate_group = terminate_process_group


def run_bounded_capture(
    argv: Sequence[str],
    *,
    cwd: Path | str | None = None,
    timeout_seconds: float | None = None,
    env: Mapping[str, str] | None = None,
    stdin: int | None = subprocess.DEVNULL,
    text: bool = True,
    capture_output: bool = True,
    check: bool = False,
) -> subprocess.CompletedProcess[Any]:
    """Run explicit argv with subprocess.run-like semantics and bounded lifecycle.

    The child is always the leader of a fresh session/process group. Timeout
    drains descendants before the traditional ``TimeoutExpired`` contract is
    re-raised. Normal direct-child completion is accepted only after the whole
    process group is empty. A surviving descendant is terminated and raises
    ``ProcessGroupLeakError`` so lifecycle refusal cannot be mistaken for a
    successful authority probe.
    """
    proc = subprocess.Popen(
        list(argv),
        cwd=str(cwd) if cwd is not None else None,
        env=dict(env) if env is not None else None,
        stdin=stdin,
        stdout=subprocess.PIPE if capture_output else None,
        stderr=subprocess.PIPE if capture_output else None,
        text=text,
        start_new_session=True,
    )
    try:
        stdout, stderr = proc.communicate(timeout=timeout_seconds)
    except subprocess.TimeoutExpired as exc:
        terminate_process_group(proc)
        stdout, stderr = _communicate_after_termination(proc, argv)
        raise subprocess.TimeoutExpired(
            list(argv), timeout_seconds, output=stdout, stderr=stderr
        ) from exc
    except BaseException:
        terminate_process_group(proc)
        raise

    if process_group_exists(proc.pid):
        terminate_process_group(proc)
        raise ProcessGroupLeakError(list(argv), stdout, stderr)

    result = subprocess.CompletedProcess(
        args=list(argv),
        returncode=int(proc.returncode),
        stdout=stdout,
        stderr=stderr,
    )
    if check and result.returncode != 0:
        raise subprocess.CalledProcessError(
            result.returncode,
            result.args,
            output=result.stdout,
            stderr=result.stderr,
        )
    return result


def run_bounded_capture_bytes(
    argv: Sequence[str],
    *,
    cwd: Path | str | None = None,
    timeout_seconds: float | None = None,
    env: Mapping[str, str] | None = None,
    stdin: int | None = subprocess.DEVNULL,
    check: bool = False,
) -> subprocess.CompletedProcess[bytes]:
    """Bytes variant of :func:`run_bounded_capture` with identical proof."""
    return run_bounded_capture(
        argv,
        cwd=cwd,
        timeout_seconds=timeout_seconds,
        env=env,
        stdin=stdin,
        text=False,
        capture_output=True,
        check=check,
    )


def run_bounded_to_files(
    argv: Sequence[str],
    *,
    cwd: Path | str | None,
    timeout_seconds: float,
    stdout_fh: BinaryIO,
    stderr_fh: BinaryIO,
    env: Mapping[str, str] | None = None,
    stdin: int | None = subprocess.DEVNULL,
) -> CommandResult:
    """Run explicit argv with output streamed to caller-owned durable files.

    This is the file-output counterpart to :func:`run_bounded_capture` for
    commands whose output may be large. Timeout drains the whole process group
    and returns rc=124. A direct-child success with surviving descendants is
    drained and returned as ``PROCESS_GROUP_LEAK_RC`` with the canonical marker
    appended to stderr. No caller needs its own ``Popen`` lifecycle code.
    """
    proc = subprocess.Popen(
        list(argv),
        cwd=str(cwd) if cwd is not None else None,
        env=dict(env) if env is not None else None,
        stdin=stdin,
        stdout=stdout_fh,
        stderr=stderr_fh,
        start_new_session=True,
    )
    try:
        returncode = int(proc.wait(timeout=timeout_seconds))
    except subprocess.TimeoutExpired:
        terminate_process_group(proc)
        return CommandResult(124, "", timed_out=True)
    except BaseException:
        terminate_process_group(proc)
        raise

    if process_group_exists(proc.pid):
        terminate_process_group(proc)
        stderr_fh.write(("\n" + PROCESS_GROUP_LEAK_MARKER + "\n").encode("utf-8"))
        stderr_fh.flush()
        return CommandResult(PROCESS_GROUP_LEAK_RC, "")
    return CommandResult(returncode, "")


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
        output, _ = _communicate_after_termination(proc, argv)
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
        result = run_bounded_capture(
            ["ps", "-axo", "pid=,ppid=,stat=,comm="],
            timeout_seconds=5,
        )
    except (subprocess.SubprocessError, FileNotFoundError, OSError):
        return False
    if result.returncode != 0 or not result.stdout or not result.stdout.strip():
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
    "run_bounded_capture_bytes",
    "run_bounded_to_files",
    "terminate_process_group",
]
