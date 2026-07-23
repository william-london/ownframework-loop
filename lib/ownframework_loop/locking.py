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
        yield
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(fd)


@contextmanager
def flock_shared(path: Path, *, blocking: bool = True, timeout_seconds: float = 30.0) -> Iterator[None]:
    """Acquire a shared (read) flock."""
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
            fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        yield
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(fd)
