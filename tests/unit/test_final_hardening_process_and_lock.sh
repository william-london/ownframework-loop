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

from ownframework_loop import capabilities
from ownframework_loop import locking
from ownframework_loop import process_runner
from ownframework_loop import validation_executor as ve
from ownframework_loop import validation_policy


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


def prove_successful_leader_cannot_hide_live_descendant() -> None:
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        sentinel = root / "leader-child-survived"
        grandchild_code = (
            "from pathlib import Path; import sys,time; "
            "time.sleep(1); Path(sys.argv[1]).write_text('survived'); time.sleep(30)"
        )
        parent_code = r'''
import subprocess, sys
subprocess.Popen(
    [sys.executable, "-c", sys.argv[1], sys.argv[2]],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    close_fds=True,
)
'''
        try:
            process_runner.run_bounded_capture(
                [sys.executable, "-c", parent_code, grandchild_code, str(sentinel)],
                timeout_seconds=5,
            )
        except process_runner.ProcessGroupLeakError as exc:
            assert exc.returncode == process_runner.PROCESS_GROUP_LEAK_RC
            assert str(exc) == process_runner.PROCESS_GROUP_LEAK_MARKER
        else:
            raise AssertionError("live descendant was not refused exceptionally")
        time.sleep(1.3)
        assert not sentinel.exists(), (
            "direct child exited but an in-group descendant escaped bounded cleanup"
        )


def prove_validation_detachment_is_refused() -> None:
    for command in (
        "setsid python3 -c 'print(1)'",
        "nohup python3 -c 'print(1)'",
        "daemonize /tmp/example python3 -c 'print(1)'",
        "printf ok; disown",
        "systemd-run --user python3 -c 'print(1)'",
        "launchctl submit -l example -- /bin/true",
    ):
        decision = validation_policy.classify_required_validation(
            command, run_id="run-20260923T000000Z-deadbeef"
        )
        assert decision["allowed"] is False, (command, decision)
        assert decision["external_decision"] == "BLOCK:OF_LOOP_VALIDATION_DETACH", (
            command, decision
        )


def prove_capability_version_probe_requires_zero_exit() -> None:
    with tempfile.TemporaryDirectory(dir="/tmp") as raw:
        root = Path(raw)
        executable = root / "fake-version-tool"
        executable.write_text(
            "#!/bin/sh\necho 'fake tool 99.0' >&2\nexit 7\n",
            encoding="utf-8",
        )
        executable.chmod(0o700)
        definition = capabilities.CapabilityDefinition(
            "tool.fake-version", "tool", ()
        )
        try:
            capabilities._resolve_executable(
                definition,
                {
                    "executable": str(executable),
                    "version_args": ["--version"],
                },
            )
        except capabilities.CapabilityResolutionError as exc:
            assert "rc=7" in str(exc), exc
        else:
            raise AssertionError(
                "nonzero capability version probe was accepted as authoritative"
            )


def prove_validation_timeout_drains_descendants() -> None:
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        cwd = root / "candidate"
        cache = root / "cache"
        cwd.mkdir()
        cache.mkdir()

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
        time.sleep(2.5)
        assert not (cwd / "child-survived").exists(), (
            "validation descendant survived the timeout boundary"
        )


prove_nonblocking_shared_lock_normalizes_busy()
prove_successful_leader_cannot_hide_live_descendant()
prove_validation_detachment_is_refused()
prove_capability_version_probe_requires_zero_exit()
prove_validation_timeout_drains_descendants()
print("FINAL_HARDENING_PROCESS_AND_LOCK=PASS")
PY
