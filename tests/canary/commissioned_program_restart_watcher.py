#!/usr/bin/env python3
"""Durable control-plane watcher for the commissioned PROGRAM canary.

The production canary uses the host's native per-user service manager.  The
``test`` manager is intentionally narrow and exists only for model-free
watcher lifecycle tests; it starts the same watcher in a detached session and
uses an injected fake restart command.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any


POLL_SECONDS = float(os.environ.get("OFLOOP_CANARY_RESTART_POLL_SECONDS", "0.05"))
WAIT_SECONDS = int(os.environ.get("OFLOOP_CANARY_RESTART_WAIT_SECONDS", "14400"))


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load(path: Path) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def atomic_write(path: Path, value: dict[str, Any]) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(value, fh, indent=2, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
        dfd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def update_control(control: Path, **changes: Any) -> dict[str, Any]:
    control = Path(control)
    value = load(control)
    value.update(changes)
    atomic_write(control, value)
    return value


def manager(c: dict[str, Any]) -> str:
    if os.environ.get("OFLOOP_CANARY_TEST_MANAGER") == "1":
        return "test"
    return str(c.get("watcher_manager") or c.get("service_manager") or "")


def watcher_id(c: dict[str, Any]) -> str:
    value = str(c.get("watcher_id") or "")
    if value:
        return value
    raw = re.sub(r"[^A-Za-z0-9_.-]+", "-", Path(c["canary_root"]).name).strip("-")
    mgr = manager(c)
    if mgr == "launchd":
        return f"com.ownframework.loop-canary-restart.{raw}"
    if mgr == "systemd-user":
        return f"ownframework-loop-canary-restart-{raw}.service"
    return f"test-ownframework-loop-canary-restart-{raw}"


def service_target(c: dict[str, Any]) -> str:
    return str(c["service_label"])


def launchd_domain() -> str:
    return f"gui/{os.getuid()}"


def registration_path(c: dict[str, Any]) -> Path:
    root = Path(c["canary_root"])
    return root / "watcher" / (watcher_id(c) + (".plist" if manager(c) == "launchd" else ".unit"))


def log_path(c: dict[str, Any]) -> Path:
    return Path(c.get("watcher_log") or (Path(c["canary_root"]) / "restart-watcher.log"))


def append_log(c: dict[str, Any], text: str) -> None:
    p = log_path(c)
    p.parent.mkdir(parents=True, exist_ok=True)
    with p.open("a", encoding="utf-8") as fh:
        fh.write(text.rstrip("\n") + "\n")


def pid_alive(pid: Any) -> bool:
    try:
        value = int(pid)
        os.kill(value, 0)
        return True
    except (TypeError, ValueError, ProcessLookupError, PermissionError):
        return False


def manager_alive(c: dict[str, Any]) -> bool:
    mgr = manager(c)
    wid = watcher_id(c)
    if mgr == "test":
        return registration_path(c).is_file() and pid_alive(c.get("watcher_pid"))
    if mgr == "launchd":
        return subprocess.run(
            ["launchctl", "print", f"{launchd_domain()}/{wid}"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        ).returncode == 0
    if mgr == "systemd-user":
        return subprocess.run(
            ["systemctl", "--user", "is-active", "--quiet", wid],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        ).returncode == 0
    return False


def manager_pid(c: dict[str, Any]) -> int | None:
    if manager(c) == "test":
        try:
            return int(c.get("watcher_pid"))
        except (TypeError, ValueError):
            return None
    if manager(c) == "launchd":
        proc = subprocess.run(
            ["launchctl", "print", f"{launchd_domain()}/{watcher_id(c)}"],
            capture_output=True,
            text=True,
            check=False,
        )
        match = re.search(r"\n\s*pid = (\d+)\b", proc.stdout)
        return int(match.group(1)) if match else None
    if manager(c) == "systemd-user":
        proc = subprocess.run(
            ["systemctl", "--user", "show", "-p", "MainPID", "--value", watcher_id(c)],
            capture_output=True,
            text=True,
            check=False,
        )
        try:
            value = int(proc.stdout.strip())
            return value or None
        except ValueError:
            return None
    return None


def write_launchd_registration(c: dict[str, Any], helper: Path) -> Path:
    import plistlib

    p = registration_path(c)
    p.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "Label": watcher_id(c),
        "ProgramArguments": [sys.executable, str(helper), "watch", str(Path(c["canary_root"]).resolve())],
        "RunAtLoad": True,
        "KeepAlive": False,
        "ProcessType": "Background",
        "StandardOutPath": str(log_path(c)),
        "StandardErrorPath": str(log_path(c)),
        "WorkingDirectory": str(Path(c["canary_root"]).resolve()),
    }
    fd, tmp = tempfile.mkstemp(prefix=f".{p.name}.", dir=p.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as fh:
            plistlib.dump(payload, fh, sort_keys=True)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, p)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
    return p


def register(c: dict[str, Any], helper: Path) -> None:
    mgr = manager(c)
    if mgr == "test":
        p = log_path(c)
        p.parent.mkdir(parents=True, exist_ok=True)
        registration = registration_path(c)
        registration.parent.mkdir(parents=True, exist_ok=True)
        env = os.environ.copy()
        log = p.open("a", encoding="utf-8")
        proc = subprocess.Popen(
            [sys.executable, str(helper), "watch", str(Path(c["canary_root"]).resolve())],
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=subprocess.STDOUT,
            close_fds=True,
            start_new_session=True,
            env=env,
        )
        log.close()
        atomic_write(registration, {"manager": "test", "watcher_id": watcher_id(c), "pid": proc.pid})
        update_control(c["control"], watcher_pid=proc.pid, watcher_durable=False)
        return
    if mgr == "launchd":
        plist = write_launchd_registration(c, helper)
        result = subprocess.run(["launchctl", "bootstrap", launchd_domain(), str(plist)], check=False)
        if result.returncode:
            raise RuntimeError(f"launchd bootstrap failed rc={result.returncode}")
        return
    if mgr == "systemd-user":
        unit = watcher_id(c)
        result = subprocess.run(
            [
                "systemd-run", "--user", "--unit", unit.removesuffix(".service"),
                "--collect", "--property=Type=simple", sys.executable, str(helper),
                "watch", str(Path(c["canary_root"]).resolve()),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode:
            raise RuntimeError(f"systemd-run failed rc={result.returncode}: {result.stderr.strip()}")
        return
    raise RuntimeError(f"unsupported watcher manager: {mgr}")


def cleanup(c: dict[str, Any]) -> None:
    mgr = manager(c)
    wid = watcher_id(c)
    if mgr == "launchd":
        p = registration_path(c)
        subprocess.run(["launchctl", "bootout", launchd_domain(), str(p)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        p.unlink(missing_ok=True)
    elif mgr == "systemd-user":
        subprocess.run(["systemctl", "--user", "stop", wid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        subprocess.run(["systemctl", "--user", "reset-failed", wid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        registration_path(c).unlink(missing_ok=True)
    elif mgr == "test":
        pid = c.get("watcher_pid")
        try:
            numeric_pid = int(pid)
        except (TypeError, ValueError):
            numeric_pid = None
        if numeric_pid and pid_alive(numeric_pid) and numeric_pid != os.getpid():
            try:
                os.kill(numeric_pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        registration_path(c).unlink(missing_ok=True)


def arm(root: Path, helper: Path) -> int:
    control = root / "control.json"
    c = load(control)
    c["control"] = str(control)
    if c.get("watcher_status") in {"ARMED", "WAITING"} and manager_alive(c):
        pid = manager_pid(c)
        update_control(control, watcher_durable=True, watcher_pid=pid or c.get("watcher_pid"))
        print("CANARY_RESTART_WATCH=ARMED")
        print("WATCHER_DURABLE=yes")
        print(f"WATCHER_ID={watcher_id(c)}")
        return 0
    if c.get("watcher_status") == "PROOF_WRITTEN":
        print("CANARY_RESTART_WATCH=ALREADY_COMPLETE")
        print(f"WATCHER_ID={watcher_id(c)}")
        return 0
    if c.get("watcher_status") == "FAILED":
        print(f"CANARY_STATE=TERMINAL_FAIL reason={c.get('watcher_result', 'watcher_failed')}", file=sys.stderr)
        return 1
    if c.get("status") not in {"PREPARED", "STARTED"}:
        raise RuntimeError(f"arm_requires_prepared_or_started status={c.get('status')}")
    wid = watcher_id(c)
    update_control(
        control,
        watcher_id=wid,
        watcher_manager=manager(c),
        watcher_log=str(log_path(c)),
        watcher_registration=str(registration_path(c)),
        watcher_status="ARMED",
        watcher_durable=False,
        watcher_armed_at=now(),
        watcher_result="",
    )
    c = load(control)
    c["control"] = str(control)
    register(c, helper)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        c = load(control)
        c["control"] = str(control)
        if manager_alive(c):
            pid = manager_pid(c)
            update_control(control, watcher_durable=True, watcher_pid=pid or c.get("watcher_pid"))
            print("CANARY_RESTART_WATCH=ARMED")
            print("WATCHER_DURABLE=yes")
            print(f"WATCHER_ID={wid}")
            return 0
        time.sleep(0.05)
    cleanup(c)
    update_control(control, watcher_status="FAILED", watcher_result="WATCHER_DIED", watcher_durable=False)
    print("CANARY_STATE=TERMINAL_FAIL reason=restart_watcher_not_durable", file=sys.stderr)
    return 1


def db_probe(c: dict[str, Any]) -> dict[str, Any]:
    result = {"job": None, "attempt_count": 0, "active_worker": False, "cp2_attempted": False}
    db = Path(c["db"])
    if not db.is_file():
        return result
    try:
        conn = sqlite3.connect(f"file:{db.resolve()}?mode=ro", uri=True)
        row = conn.execute(
            "select id,worker_pid,worker_role,worker_attempt_id from jobs where repo=? and run_id=?",
            (str(Path(c["repo"]).resolve()), c["run_id"]),
        ).fetchone()
        if row:
            result["job"] = row[0]
            result["active_worker"] = bool(row[1] or row[2] or row[3])
            attempts = conn.execute(
                "select role,status from semantic_attempts where job_id=? order by started_at",
                (row[0],),
            ).fetchall()
            result["attempt_count"] = len(attempts)
            result["cp2_attempted"] = len(attempts) > 4 or any(a[1] in {"STARTED", "RUNNING", "CLAIMED"} for a in attempts[4:])
        conn.close()
    except sqlite3.Error:
        return result
    return result


def hold_probe(c: dict[str, Any]) -> str:
    """Return the durable hold state without mutating either authority."""
    hold_id = str(c.get("dispatch_hold_id") or "")
    if not hold_id:
        return "NO_HOLD"
    db = Path(c["db"])
    try:
        conn = sqlite3.connect(f"file:{db.resolve()}?mode=ro", uri=True)
        row = conn.execute(
            "SELECT state FROM dispatch_holds WHERE hold_id=? AND repo=? AND run_id=?",
            (hold_id, str(Path(c["repo"]).resolve()), c["run_id"]),
        ).fetchone()
        conn.close()
    except sqlite3.Error:
        return "WAIT"
    if row is None:
        return "WAIT"
    return str(row[0])


def boundary_probe(c: dict[str, Any]) -> str:
    state_path = Path(c["repo"]) / ".ownframework-loop" / c["run_id"] / "STATE.json"
    if not state_path.is_file():
        return "WAIT"
    try:
        state = load(state_path)
    except (OSError, json.JSONDecodeError):
        return "WAIT"
    program = state.get("program") or {}
    finalized = {x.get("id"): x.get("terminal_state") for x in program.get("finalized_checkpoints", [])}
    checkpoints = {x.get("id"): x for x in program.get("checkpoints", [])}
    cp2 = checkpoints.get("CP-2") or {}
    db = db_probe(c)
    if state.get("state") in {"BLOCKED", "STOPPED"}:
        return "TERMINAL_FAIL"
    if finalized.get("CP-1") != "APPROVED":
        return "WAIT"
    if (program.get("current_checkpoints") or []) != ["CP-2"]:
        return "WAIT"
    if state.get("state") != "READY_TO_BUILD":
        if cp2.get("build_pass_count", 0) or cp2.get("review_pass_count", 0) or db["active_worker"]:
            return "BOUNDARY_MISSED"
        return "WAIT"
    if cp2.get("build_pass_count", 0) or cp2.get("review_pass_count", 0) or cp2.get("repair_round_count", 0):
        return "BOUNDARY_MISSED"
    if db["active_worker"] or db["cp2_attempted"]:
        return "BOUNDARY_MISSED"
    return "BOUNDARY"


def service_active(c: dict[str, Any]) -> bool:
    if manager(c) == "test":
        marker = os.environ.get("OFLOOP_CANARY_TEST_SERVICE_ACTIVE_FILE") or c.get("test_service_active_file")
        return bool(marker and Path(marker).is_file())
    target = service_target(c)
    if manager(c) == "launchd":
        return subprocess.run(["launchctl", "print", f"{launchd_domain()}/{target}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False).returncode == 0
    if manager(c) == "systemd-user":
        return subprocess.run(["systemctl", "--user", "is-active", "--quiet", target], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False).returncode == 0
    return False


def restart_service(c: dict[str, Any]) -> None:
    if manager(c) == "test":
        command = c.get("test_restart_command") or os.environ.get("OFLOOP_CANARY_TEST_RESTART_COMMAND")
        if not command:
            raise RuntimeError("test_restart_command_missing")
        result = subprocess.run(command, shell=True, check=False)
        if result.returncode:
            raise RuntimeError(f"test_restart_command_failed rc={result.returncode}")
        return
    target = service_target(c)
    if manager(c) == "launchd":
        result = subprocess.run(["launchctl", "kickstart", "-k", f"{launchd_domain()}/{target}"], check=False)
    elif manager(c) == "systemd-user":
        result = subprocess.run(["systemctl", "--user", "restart", target], check=False)
    else:
        raise RuntimeError(f"unsupported_service_manager_{manager(c)}")
    if result.returncode:
        raise RuntimeError(f"service_restart_failed rc={result.returncode}")


def write_proof(c: dict[str, Any], before: str, after: str, pid: int | None) -> None:
    proof = {
        "schema": "ownframework-loop-commissioned-canary-restart-proof/v1",
        "observed_cp1_terminal": "APPROVED",
        "observed_current_checkpoints": ["CP-2"],
        "observed_top_state": "READY_TO_BUILD",
        "no_active_cp2_worker": True,
        "service_restarted": True,
        "service_active_after_restart": service_active(c),
        "runtime_generation_before": before,
        "runtime_generation_after": after,
        "runtime_generation_stable": before == after,
        "service_manager": manager(c),
        "service_label": service_target(c),
        "restart_timestamp": now(),
        "watcher_id": watcher_id(c),
        "watcher_pid": pid,
        "watcher_log": str(log_path(c)),
    }
    if c.get("dispatch_hold_id"):
        proof.update({
            "dispatch_hold_id": str(c["dispatch_hold_id"]),
            "dispatch_hold_kind": str(c.get("dispatch_hold_kind") or ""),
            "dispatch_hold_state": "HELD",
            "cp2_attempts_at_hold": 0,
            "proof_written_before_hold_release": True,
        })
    if not proof["service_active_after_restart"]:
        raise RuntimeError("service_not_active_after_restart")
    if not proof["runtime_generation_stable"]:
        raise RuntimeError("runtime_generation_changed_on_restart")
    proof_path = Path(c["canary_root"]) / "restart-proof.json"
    atomic_write(proof_path, proof)


def release_hold(c: dict[str, Any]) -> None:
    hold_id = str(c.get("dispatch_hold_id") or "")
    if not hold_id:
        return
    command = os.environ.get("OFLOOP_CANARY_TEST_RELEASE_COMMAND") if manager(c) == "test" else None
    if command:
        result = subprocess.run(command, shell=True, check=False)
    else:
        result = subprocess.run(
            [str(c["ofloop_bin"]), "supervisor", "hold", "release",
             str(Path(c["repo"]).resolve()), str(c["run_id"]), hold_id,
             "--db", str(Path(c["db"]).resolve())],
            capture_output=True,
            text=True,
            check=False,
        )
    if result.returncode:
        detail = getattr(result, "stderr", "") or getattr(result, "stdout", "")
        append_log(c, f"DISPATCH_HOLD_RELEASE_ERROR={str(detail).strip()[:500]}")
        raise RuntimeError(f"dispatch_hold_release_failed:{str(detail).strip()[:500]}")
    append_log(c, "DISPATCH_HOLD_RELEASE_RESPONSE=ok")
    c = load(Path(c["control"])) if c.get("control") else c
    if hold_probe(c) != "RELEASED":
        raise RuntimeError("dispatch_hold_release_not_durable")


def generation(c: dict[str, Any]) -> str:
    return str(load(Path(c["provenance"])).get("runtime_generation", ""))


def watch(root: Path) -> int:
    control = root / "control.json"
    c = load(control)
    c["control"] = str(control)
    pid = os.getpid()
    update_control(control, watcher_status="WAITING", watcher_pid=pid, watcher_durable=True, watcher_started_at=now())
    append_log(c, f"WATCHER_STATE=WAITING watcher_id={watcher_id(c)} pid={pid}")
    deadline = time.monotonic() + WAIT_SECONDS
    while time.monotonic() < deadline:
        result = hold_probe(c)
        if result == "NO_HOLD":
            if c.get("status") == "STARTED":
                update_control(control, watcher_status="FAILED", watcher_result="DISPATCH_HOLD_MISSING_AFTER_START", watcher_durable=False)
                append_log(c, "WATCHER_RESULT=DISPATCH_HOLD_MISSING_AFTER_START")
                cleanup(load(control) | {"control": str(control)})
                return 1
            # Backward-compatible fixture mode for the pre-hold watcher test;
            # commissioned START always records a hold id and uses HELD as the
            # scheduler-owned trigger.
            result = boundary_probe(c)
        elif result == "ARMED":
            result = "WAIT"
        elif result == "RELEASED":
            update_control(control, watcher_status="FAILED", watcher_result="HOLD_RELEASED_BEFORE_PROOF", watcher_durable=False)
            append_log(c, "WATCHER_RESULT=HOLD_RELEASED_BEFORE_PROOF")
            cleanup(load(control) | {"control": str(control)})
            return 1
        elif result == "CANCELLED":
            update_control(control, watcher_status="FAILED", watcher_result="HOLD_CANCELLED", watcher_durable=False)
            append_log(c, "WATCHER_RESULT=HOLD_CANCELLED")
            cleanup(load(control) | {"control": str(control)})
            return 1
        elif result == "HELD":
            result = "BOUNDARY"
        if result == "WAIT":
            time.sleep(POLL_SECONDS)
            continue
        if result == "TERMINAL_FAIL":
            update_control(control, watcher_status="FAILED", watcher_result="RUN_TERMINAL_BEFORE_RESTART")
            append_log(c, "WATCHER_RESULT=RUN_TERMINAL_BEFORE_RESTART")
            cleanup(load(control) | {"control": str(control)})
            return 1
        if result == "BOUNDARY_MISSED":
            update_control(control, watcher_status="FAILED", watcher_result="RESTART_BOUNDARY_MISSED", watcher_durable=False)
            append_log(c, "WATCHER_RESULT=RESTART_BOUNDARY_MISSED")
            cleanup(load(control) | {"control": str(control)})
            return 1
        # Re-probe immediately before restarting.  If CP-2 was claimed in the
        # small observation window, fail closed and never manufacture recovery.
        current_control = load(control) | {"control": str(control)}
        if current_control.get("dispatch_hold_id"):
            if hold_probe(current_control) != "HELD":
                update_control(control, watcher_status="FAILED", watcher_result="DISPATCH_HOLD_NOT_HELD", watcher_durable=False)
                append_log(c, "WATCHER_RESULT=DISPATCH_HOLD_NOT_HELD")
                cleanup(load(control) | {"control": str(control)})
                return 1
        if boundary_probe(current_control) != "BOUNDARY":
            update_control(control, watcher_status="FAILED", watcher_result="RESTART_BOUNDARY_MISSED", watcher_durable=False)
            append_log(c, "WATCHER_RESULT=RESTART_BOUNDARY_MISSED")
            cleanup(load(control) | {"control": str(control)})
            return 1
        c = load(control)
        c["control"] = str(control)
        update_control(control, watcher_status="BOUNDARY_OBSERVED", watcher_pid=pid, watcher_durable=True)
        if c.get("dispatch_hold_id"):
            update_control(control, dispatch_hold_state="HELD")
        append_log(c, f"WATCHER_STATE=BOUNDARY_OBSERVED watcher_id={watcher_id(c)}")
        before = generation(c)
        try:
            update_control(control, watcher_status="RESTARTING", watcher_pid=pid, watcher_durable=True)
            restart_service(c)
            time.sleep(1 if manager(c) != "test" else 0.05)
            if not service_active(c):
                raise RuntimeError("service_not_active_after_restart")
            after = generation(c)
            # The hold is the durable scheduling hand-off.  Re-probe it and
            # the authoritative boundary after service recovery, before the
            # proof can be published or the hold can be released.
            if c.get("dispatch_hold_id"):
                current = load(control)
                current["control"] = str(control)
                if hold_probe(current) != "HELD":
                    raise RuntimeError("dispatch_hold_not_held_after_restart")
                if boundary_probe(current) != "BOUNDARY":
                    raise RuntimeError("restart_boundary_not_verified_after_restart")
            write_proof(c, before, after, pid)
            release_hold(c)
            update_control(control, watcher_status="PROOF_WRITTEN", watcher_result="RESTARTED", watcher_durable=False, watcher_finished_at=now())
            if c.get("dispatch_hold_id"):
                update_control(control, dispatch_hold_state="RELEASED")
            append_log(c, "WATCHER_STATE=PROOF_WRITTEN SERVICE_RESTARTED=yes")
            cleanup(load(control) | {"control": str(control)})
            print("CANARY_RESTART_PROOF=RECORDED boundary=CP-2_READY runtime_generation_stable=yes")
            return 0
        except Exception as exc:
            update_control(control, watcher_status="FAILED", watcher_result=f"RESTART_FAILED:{type(exc).__name__}:{exc}", watcher_durable=False)
            append_log(c, f"WATCHER_RESULT=RESTART_FAILED:{type(exc).__name__}:{exc}")
            cleanup(load(control) | {"control": str(control)})
            return 1
    update_control(control, watcher_status="FAILED", watcher_result="WATCHER_TIMEOUT", watcher_durable=False)
    append_log(c, "WATCHER_RESULT=WATCHER_TIMEOUT")
    cleanup(load(control) | {"control": str(control)})
    return 1


def check(root: Path) -> int:
    control = root / "control.json"
    c = load(control)
    c["control"] = str(control)
    if c.get("watcher_status") in {"ARMED", "WAITING", "BOUNDARY_OBSERVED", "RESTARTING"} and manager_alive(c):
        print("WATCHER_DURABLE=yes")
        print(f"WATCHER_ID={watcher_id(c)}")
        return 0
    print(f"WATCHER_DURABLE=no reason={c.get('watcher_status') or 'not_armed'}", file=sys.stderr)
    return 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["arm", "watch", "check", "cleanup"])
    parser.add_argument("root")
    parser.add_argument("helper", nargs="?")
    args = parser.parse_args()
    root = Path(args.root).expanduser().resolve()
    control = root / "control.json"
    c = load(control)
    c["control"] = str(control)
    try:
        if args.command == "arm":
            return arm(root, Path(args.helper or __file__).resolve())
        if args.command == "watch":
            return watch(root)
        if args.command == "check":
            return check(root)
        cleanup(c)
        return 0
    except Exception as exc:
        print(f"WATCHER_ERROR={type(exc).__name__}:{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
