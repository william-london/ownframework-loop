"""Supervisor process authority.

Owns process-local execution fencing, PID/start-identity observation, liveness
proof, and bounded termination of an exactly-owned worker process group.
This module is deliberately below recovery and attempts and never imports the
supervisor composition facade.
"""
from __future__ import annotations

import os
import signal
import subprocess
import sys
import threading
import time

_LOCAL_EXECUTION_LOCK = threading.Lock()
_LOCAL_EXECUTION_JOBS: dict[int, set[int]] = {}
_LOCAL_CONNECTION_DEPTH_SUPERVISOR: dict[int, int] = {}
_BOOT_TIME_CACHE: float | None = None

def _register_local_execution(job_id: int) -> None:
    with _LOCAL_EXECUTION_LOCK:
        _LOCAL_EXECUTION_JOBS.setdefault(threading.get_ident(), set()).add(int(job_id))

def _local_execution_owned(job_id: int) -> bool:
    with _LOCAL_EXECUTION_LOCK:
        return any(int(job_id) in jobs for jobs in _LOCAL_EXECUTION_JOBS.values())

def _clear_local_executions_for_thread() -> None:
    with _LOCAL_EXECUTION_LOCK:
        _LOCAL_EXECUTION_JOBS.pop(threading.get_ident(), None)

def _pid_alive(pid: int | None, worker_started_at: float | None = None) -> bool:
    """True iff `pid` is alive AND consistent with our recorded worker.

    Beyond the bare kill(pid, 0) probe, if `worker_started_at` is provided,
    we cross-check that the process start time is within ±10 seconds of the
    recorded value. This defends against PID reuse — an unrelated process
    that inherited the same PID is NOT our worker. PermissionError
    (different uid) is treated as "not our worker" rather than alive.

    The start-time cross-check is best-effort. If introspection fails
    (sandbox, container cgroup stall, missing psutil-like APIs), the bare
    kill() probe is the fallback.
    """
    if not pid or int(pid) <= 0:
        return False
    pid = int(pid)
    try:
        os.kill(pid, 0)
    except (ProcessLookupError, PermissionError):
        return False
    if worker_started_at is None or worker_started_at <= 0:
        return True
    try:
        start_ts = _read_pid_start_time(pid)
        if start_ts is None:
            return True
        if abs(start_ts - worker_started_at) > 10:
            return False
    except Exception:
        return True
    return True

def _read_pid_start_identity(pid: int) -> str | None:
    """Return a durable exact process-start identity for safe signalling.

    Linux binds kernel start ticks to /proc's boot_id, preventing a false match
    after reboot. Darwin reads proc_bsdinfo's microsecond start timestamp via
    libproc rather than relying on second-granularity ps output. Failure to
    obtain either identity is fail-safe: replacement recovery will not signal.
    """
    try:
        if sys.platform == "linux":
            with open(f"/proc/{int(pid)}/stat", encoding="utf-8") as f:
                content = f.read()
            rp = content.rfind(")")
            if rp < 0:
                return None
            fields = content[rp + 1:].split()
            if len(fields) < 20:
                return None
            with open("/proc/sys/kernel/random/boot_id", encoding="utf-8") as f:
                boot_id = f.read().strip()
            if not boot_id:
                return None
            return f"linux-boot:{boot_id}:startticks:{int(fields[19])}"
        if sys.platform == "darwin":
            import ctypes

            class _ProcBsdInfo(ctypes.Structure):
                _fields_ = [
                    ("pbi_flags", ctypes.c_uint32),
                    ("pbi_status", ctypes.c_uint32),
                    ("pbi_xstatus", ctypes.c_uint32),
                    ("pbi_pid", ctypes.c_uint32),
                    ("pbi_ppid", ctypes.c_uint32),
                    ("pbi_uid", ctypes.c_uint32),
                    ("pbi_gid", ctypes.c_uint32),
                    ("pbi_ruid", ctypes.c_uint32),
                    ("pbi_rgid", ctypes.c_uint32),
                    ("pbi_svuid", ctypes.c_uint32),
                    ("pbi_svgid", ctypes.c_uint32),
                    ("rfu_1", ctypes.c_uint32),
                    ("pbi_comm", ctypes.c_char * 16),
                    ("pbi_name", ctypes.c_char * 32),
                    ("pbi_nfiles", ctypes.c_uint32),
                    ("pbi_pgid", ctypes.c_uint32),
                    ("pbi_pjobc", ctypes.c_uint32),
                    ("e_tdev", ctypes.c_uint32),
                    ("e_tpgid", ctypes.c_uint32),
                    ("pbi_nice", ctypes.c_int32),
                    ("pbi_start_tvsec", ctypes.c_uint64),
                    ("pbi_start_tvusec", ctypes.c_uint64),
                ]

            libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
            proc_pidinfo = libproc.proc_pidinfo
            proc_pidinfo.argtypes = [
                ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                ctypes.c_void_p, ctypes.c_int,
            ]
            proc_pidinfo.restype = ctypes.c_int
            info = _ProcBsdInfo()
            PROC_PIDTBSDINFO = 3
            size = ctypes.sizeof(info)
            rc = int(proc_pidinfo(
                int(pid), PROC_PIDTBSDINFO, 0, ctypes.byref(info), size
            ))
            if rc != size or int(info.pbi_pid) != int(pid):
                return None
            return (
                f"darwin-start:{int(info.pbi_start_tvsec)}:"
                f"{int(info.pbi_start_tvusec)}"
            )
    except Exception:
        return None
    return None

def _pid_identity_proven(pid: int | None, expected_identity: str | None) -> bool:
    """Strict identity proof used before signalling a recovered orphan."""
    if not pid or int(pid) <= 0 or not expected_identity:
        return False
    pid = int(pid)
    try:
        os.kill(pid, 0)
    except (ProcessLookupError, PermissionError):
        return False
    observed = _read_pid_start_identity(pid)
    return observed is not None and observed == str(expected_identity)

def _terminate_owned_process_group(
    pid: int,
    pgid: int | None,
    expected_identity: str | None,
    worker_started_at: float | None,
) -> bool:
    """Terminate only a process group whose exact leader identity is proven."""
    if not pgid or int(pgid) != int(pid):
        return False
    if not _pid_identity_proven(pid, expected_identity):
        return False
    try:
        os.killpg(int(pgid), signal.SIGTERM)
    except ProcessLookupError:
        return True
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline:
        if not _pid_alive(pid, worker_started_at):
            return True
        time.sleep(0.05)
    if not _pid_identity_proven(pid, expected_identity):
        return not _pid_alive(pid, worker_started_at)
    try:
        os.killpg(int(pgid), signal.SIGKILL)
    except ProcessLookupError:
        return True
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline:
        if not _pid_alive(pid, worker_started_at):
            return True
        time.sleep(0.05)
    return not _pid_alive(pid, worker_started_at)

def _read_pid_start_time(pid: int) -> float | None:
    """Best-effort cross-platform process start-time read.

    Linux: read /proc/<pid>/stat field 22 (start_time in clock ticks since boot).
    macOS: use ps -o etime= to compute approximate age.
    Returns Unix timestamp in seconds, or None on failure.
    """
    try:
        if sys.platform == "linux":
            with open(f"/proc/{pid}/stat", encoding="utf-8") as f:
                content = f.read()
            rp = content.rfind(")")
            if rp < 0:
                return None
            fields = content[rp + 1:].split()
            # We removed fields 1(pid) and 2(comm), so fields[0] is proc
            # stat field 3 (state). Linux starttime is field 22 => index 19.
            if len(fields) < 20:
                return None
            ticks = int(fields[19])
            try:
                clk_tck = os.sysconf("SC_CLK_TCK")
            except Exception:
                clk_tck = 100
            boot = _boot_time_unix()
            if boot is None:
                return None
            return boot + ticks / float(clk_tck)
        # macOS fallback
        r = subprocess.run(
            ["ps", "-o", "etime=", "-p", str(pid)],
            capture_output=True, text=True, check=False, timeout=2,
        )
        if r.returncode != 0 or not r.stdout.strip():
            return None
        etime = r.stdout.strip()
        # Parse [[dd-]hh:]mm:ss without losing hour/day forms.
        parts = etime.split(":")
        try:
            if len(parts) == 2:
                minutes, seconds = (int(parts[0]), int(parts[1]))
                total = minutes * 60 + seconds
            elif len(parts) == 3:
                first, minutes_s, seconds_s = parts
                minutes, seconds = int(minutes_s), int(seconds_s)
                if "-" in first:
                    days_s, hours_s = first.split("-", 1)
                    total = (
                        int(days_s) * 86400
                        + int(hours_s) * 3600
                        + minutes * 60
                        + seconds
                    )
                else:
                    total = int(first) * 3600 + minutes * 60 + seconds
            else:
                return None
        except ValueError:
            return None
        return time.time() - total
    except Exception:
        return None

def _boot_time_unix() -> float | None:
    """Read system boot time in Unix seconds (Linux)."""
    global _BOOT_TIME_CACHE
    if _BOOT_TIME_CACHE is not None:
        return _BOOT_TIME_CACHE
    try:
        with open("/proc/stat", encoding="utf-8") as f:
            for line in f:
                if line.startswith("btime "):
                    _BOOT_TIME_CACHE = float(line.split()[1])
                    return _BOOT_TIME_CACHE
    except Exception:
        return None
    return None

__all__ = [
    "_LOCAL_CONNECTION_DEPTH_SUPERVISOR",
    "_register_local_execution",
    "_local_execution_owned",
    "_clear_local_executions_for_thread",
    "_pid_alive",
    "_read_pid_start_identity",
    "_pid_identity_proven",
    "_terminate_owned_process_group",
    "_read_pid_start_time",
    "_boot_time_unix",
]
