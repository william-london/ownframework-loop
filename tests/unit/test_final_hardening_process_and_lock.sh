#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PYTHONPATH="$ROOT/lib${PYTHONPATH:+:$PYTHONPATH}"

python3 - <<'PY'
from __future__ import annotations

import os
import shlex
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from ownframework_loop import locking
from ownframework_loop import validation_executor as ve


def prove_nonblocking_shared_lock_normalizes_busy() -> None:
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        lock_path = root / "contract.lock"
        holder_code = r'''
import fcntl, pathlib, sys, time
p = pathlib.Path(sys.argv[1])
fd = p.open("a+")
fcntl.flock(fd.fileno(), fcntl.LOCK_EX)
print("LOCKED", flush=True)
time.sleep(30)
'''
        holder = subprocess.Popen(
            [sys.executable, "-c", holder_code, str(lock_path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            assert holder.stdout is not None
            assert holder.stdout.readline().strip() == "LOCKED"
            try:
                with locking.flock_shared(lock_path, blocking=False):
                    raise AssertionError("shared lock unexpectedly acquired")
            except locking.LockBusyError:
                pass
            except BlockingIOError as exc:
                raise AssertionError(
                    "flock_shared leaked platform BlockingIOError instead of LockBusyError"
                ) from exc
        finally:
            holder.terminate()
            try:
                holder.wait(timeout=3)
            except subprocess.TimeoutExpired:
                holder.kill()
                holder.wait()


def prove_validation_timeout_drains_descendants() -> None:
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        cwd = root / "candidate"
        cache = root / "cache"
        cwd.mkdir()
        cache.mkdir()

        # Keep the unit focused on subprocess lifecycle rather than capability
        # resolution. The command is deliberately non-uv, so project-env
        # provisioning is not involved.
        ve.runtime_env.runtime_cache_dir = lambda *_args, **_kwargs: cache
        ve.runtime_env.commissioned_validation_env = (
            lambda *_args, **_kwargs: dict(os.environ)
        )
        ve.validation_policy.classify_required_validation = (
            lambda *_args, **_kwargs: {
                "allowed": True,
                "reason": "",
                "structural": None,
                "external_decision": "ALLOW",
            }
        )

        child_code = (
            "from pathlib import Path; import time; "
            "Path('child-started').write_text('1'); "
            "time.sleep(2); "
            "Path('child-survived').write_text('1'); "
            "time.sleep(30)"
        )
        command = (
            f"{shlex.quote(sys.executable)} -c {shlex.quote(child_code)} & "
            "while [ ! -f child-started ]; do sleep 0.01; done; wait"
        )
        result = ve.run_required_validation(
            cwd=cwd,
            validation={
                "name": "descendant-timeout",
                "command": command,
                "kind": "fast",
                "expected_exit_code": 0,
            },
            timeout_seconds=1,
            canonical_repo=root,
            run_id="run-20260923T000000Z-deadbeef",
            packet={},
        )
        assert result["timed_out"] is True, result
        assert result["exit_code"] == 124, result
        assert (cwd / "child-started").is_file(), "background descendant never started"

        # If timeout killed only /bin/sh, the background Python child writes this
        # sentinel after two seconds. Whole-group termination makes that
        # impossible. Give it enough time to expose the old behavior.
        time.sleep(2.5)
        assert not (cwd / "child-survived").exists(), (
            "validation descendant survived the timeout boundary"
        )


prove_nonblocking_shared_lock_normalizes_busy()
prove_validation_timeout_drains_descendants()
print("FINAL_HARDENING_PROCESS_AND_LOCK=PASS")
PY
