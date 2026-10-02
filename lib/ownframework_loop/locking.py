"""File locking using fcntl.flock (POSIX advisory locks)."""

from __future__ import annotations

import fcntl
import os
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator


class LockBusyError(RuntimeError):
    """Raised when a non-blocking lock cannot be acquired."""


def _lock_exclusive_fd(
    fd: int,
    path: Path,
    *,
    blocking: bool,
    timeout_seconds: float,
    poll_seconds: float,
) -> None:
    """Take an exclusive flock on an open descriptor.

    Shared by every exclusive-lock entry point so that retry, blocking and
    release semantics cannot drift between them. Only the way `fd` was opened
    differs between callers.
    """
    if blocking:
        deadline = time.monotonic() + timeout_seconds
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise LockBusyError(
                        f"could not acquire lock {path} within {timeout_seconds}s"
                    )
                time.sleep(poll_seconds)
    else:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as e:
            raise LockBusyError(f"lock {path} busy") from e


@contextmanager
def flock_exclusive(
    path: Path,
    *,
    blocking: bool = True,
    timeout_seconds: float = 30.0,
    poll_seconds: float = 0.05,
) -> Iterator[None]:
    """Acquire an exclusive flock on `path`. Creates the file if missing.

    Raises LockBusyError if `blocking=False` and the lock cannot be acquired,
    or if `blocking=True` and the timeout elapses first.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(path), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        _lock_exclusive_fd(
            fd, path, blocking=blocking,
            timeout_seconds=timeout_seconds, poll_seconds=poll_seconds,
        )
        yield
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(fd)


@contextmanager
def flock_exclusive_existing_parent(
    path: Path,
    *,
    blocking: bool = True,
    timeout_seconds: float = 30.0,
    poll_seconds: float = 0.05,
) -> Iterator[None]:
    """Acquire an exclusive flock on `path` WITHOUT ever creating its parent.

    The authoritative-read counterpart to :func:`flock_exclusive`. The parent
    directory must already exist: this creates the lock FILE inside it, but it
    never calls ``mkdir``, so it cannot resurrect a repository, a run
    directory, or any other ancestor that a caller merely meant to observe.

    A missing parent raises ``FileNotFoundError`` from the open and creates
    nothing. That is also exactly what happens when the parent is removed
    concurrently with this call, so the check-then-create window that
    :func:`flock_exclusive` leaves open is closed structurally rather than by
    a pre-flight existence test.

    Lock semantics (retry, blocking/non-blocking, release) are identical to
    :func:`flock_exclusive`; only directory creation differs. Mutation owners
    that legitimately establish new run state keep using
    :func:`flock_exclusive`, which does create.
    """
    fd = os.open(str(path), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        _lock_exclusive_fd(
            fd, path, blocking=blocking,
            timeout_seconds=timeout_seconds, poll_seconds=poll_seconds,
        )
        yield
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(fd)


@contextmanager
def flock_shared(path: Path, *, blocking: bool = True, timeout_seconds: float = 30.0) -> Iterator[None]:
    """Acquire a shared (read) flock.

    Raises LockBusyError when a non-blocking shared lock cannot be acquired,
    matching the exclusive-lock contract and keeping callers independent of
    platform-specific fcntl exceptions.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(path), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        if blocking:
            deadline = time.monotonic() + timeout_seconds
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise LockBusyError(
                            f"could not acquire shared lock {path} within {timeout_seconds}s"
                        )
                    time.sleep(0.05)
        else:
            try:
                fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
            except BlockingIOError as e:
                raise LockBusyError(f"shared lock {path} busy") from e
        yield
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(fd)
