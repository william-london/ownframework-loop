"""Kernel-authoritative single-instance lock for plugin release gates."""

from __future__ import annotations

import fcntl
import json
import os
import socket
from dataclasses import dataclass
from pathlib import Path

from . import plugin_data
from .util import utc_now_iso


class GateAlreadyRunning(RuntimeError):
    pass


@dataclass
class GateLock:
    path: Path
    fd: int

    @classmethod
    def acquire(cls, *, source_head: str, command: str) -> "GateLock":
        path = plugin_data.locks_dir() / "release-gate.lock"
        fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            os.close(fd)
            raise GateAlreadyRunning(str(path)) from exc
        metadata = {
            "pid": os.getpid(),
            "pgid": os.getpgid(0),
            "source_head": source_head,
            "started_at": utc_now_iso(),
            "hostname": socket.gethostname(),
            "command": command,
        }
        encoded = (json.dumps(metadata, sort_keys=True) + "\n").encode()
        os.ftruncate(fd, 0)
        os.write(fd, encoded)
        os.fsync(fd)
        return cls(path, fd)

    def close(self) -> None:
        if self.fd < 0:
            return
        try:
            fcntl.flock(self.fd, fcntl.LOCK_UN)
        finally:
            os.close(self.fd)
            self.fd = -1

    def __enter__(self) -> "GateLock":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()
