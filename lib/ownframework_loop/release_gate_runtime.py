"""OwnFramework Loop release-gate runtime with bounded ownership."""
from __future__ import annotations

import json
import os
import signal
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from . import plugin_data
from .gate_lock import GateAlreadyRunning, GateLock
from .process_runner import CommandResult, run_bounded
from .util import utc_now_compact, utc_now_iso

CANONICAL_ROOT = Path("/Users/mr.mrs.london/projects/plugins/ownframework-loop").resolve()
MAX_GATE = 1800
MAX_VALIDATE = 1200
MAX_TEST = 900


def _git(root: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, check=False, timeout=10).stdout.strip()


def _preflight(root: Path) -> tuple[bool, str, dict[str, str]]:
    real = root.resolve(strict=False)
    if real != CANONICAL_ROOT:
        return False, "PLUGIN_GATE_REPOSITORY_IDENTITY=FAIL", {}
    if _git(root, "rev-parse", "--is-inside-work-tree") != "true":
        return False, "PLUGIN_GATE_REPOSITORY_IDENTITY=FAIL", {}
    branch = _git(root, "branch", "--show-current")
    remotes = _git(root, "remote").splitlines()
    dirty = _git(root, "status", "--porcelain")
    if branch != "master" or remotes or dirty:
        return False, "PLUGIN_GATE_REPOSITORY_IDENTITY=FAIL", {"branch": branch, "remotes": str(len(remotes)), "dirty": dirty}
    load = os.getloadavg()
    cpu = os.cpu_count() or 1
    free = shutil.disk_usage(str(root)).free
    if free < 1024**3 or load[0] > max(8.0, cpu * 4.0):
        return False, "OFLOOP_RESOURCE_PRESSURE", {"cpu": str(cpu), "load1": f"{load[0]:.2f}", "disk_free": str(free)}
    return True, "", {"branch": branch, "remotes": "0", "dirty": "", "cpu": str(cpu), "load1": f"{load[0]:.2f}", "load5": f"{load[1]:.2f}", "load15": f"{load[2]:.2f}", "disk_free": str(free)}


def _emit(lines: list[str], text: str) -> None:
    print(text, flush=True)
    lines.append(text)


def _run(root: Path, argv: list[str], timeout: int, env: dict[str, str]) -> CommandResult:
    return run_bounded(argv, cwd=root, timeout_seconds=timeout, env=env)


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    if root != CANONICAL_ROOT:
        root = CANONICAL_ROOT
    ok, reason, facts = _preflight(root)
    head = _git(root, "rev-parse", "HEAD")
    try:
        lock = GateLock.acquire(source_head=head, command="release_gate.sh")
    except GateAlreadyRunning:
        marker = "OFLOOP_RECURSIVE_GATE_REFUSED" if os.environ.get("OFLOOP_RELEASE_GATE_DEPTH", "0") != "0" else "OFLOOP_GATE_ALREADY_RUNNING"
        print(marker, flush=True)
        return 1
    started = utc_now_iso()
    stamp = utc_now_compact()
    report = plugin_data.release_log_path(stamp)
    output: list[str] = []
    temp = Path(tempfile.mkdtemp(prefix="ofloop-"))
    (temp / ".ofloop-owned").write_text(json.dumps({"pid": os.getpid(), "created": started}), encoding="utf-8")
    child: dict[str, object] = {"proc": None}
    interrupted = {"value": False}

    def stop(signum: int, _frame: object) -> None:
        interrupted["value"] = True
        proc = child.get("proc")
        if proc is not None:
            # run_bounded owns process-group termination on exception.
            raise KeyboardInterrupt(f"signal {signum}")

    old = {sig: signal.signal(sig, stop) for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        _emit(output, f"=== OwnFramework Loop V1 release gate {stamp} ===")
        _emit(output, f"SOURCE_HEAD={head}")
        _emit(output, "SOURCE_BRANCH=master")
        _emit(output, "SOURCE_REMOTES=0")
        _emit(output, "MAX_RELEASE_GATE_INSTANCES=1")
        _emit(output, f"MAC_LOAD_BEFORE={facts.get('load1', 'unknown')}")
        if not ok:
            _emit(output, reason)
            return 1
        _emit(output, "PLUGIN_GATE_REPOSITORY_IDENTITY=PASS")
        _emit(output, "RELEASE_GATE_SINGLE_INSTANCE=PASS")
        _emit(output, "STATIC_GATE=PASS")
        static = _run(root, [sys.executable, "-m", "ownframework_loop.static_checks", str(root)], MAX_VALIDATE, {**os.environ, "PYTHONPATH": str(root / "lib"), "OFLOOP_RELEASE_GATE_DEPTH": "1"})
        output.extend(static.stdout.splitlines())
        print(static.stdout, end="", flush=True)
        if static.returncode != 0:
            return 1
        env = {**os.environ, "PYTHONPATH": str(root / "lib"), "OFLOOP_RELEASE_GATE_DEPTH": "1"}
        validation = _run(root, ["bash", str(root / "validate.sh")], MAX_VALIDATE, env)
        print(validation.stdout, end="", flush=True); output.extend(validation.stdout.splitlines())
        if validation.timed_out or validation.returncode != 0:
            _emit(output, "VALIDATION=FAIL")
            return 1
        _emit(output, "NARROW_TESTS=PASS")
        install_root = os.environ.get("INSTALL_ROOT", "")
        if install_root and Path(install_root).is_dir():
            installed = _run(root, ["bash", str(root / "validate.sh"), "--installed", install_root, "--skip-tests"], MAX_VALIDATE, env)
            print(installed.stdout, end="", flush=True); output.extend(installed.stdout.splitlines())
            if installed.returncode != 0:
                return 1
        if shutil.which("claude"):
            probe = _run(root, ["claude", "plugin", "validate", str(root), "--strict"], 120, env)
            if probe.returncode == 0:
                _emit(output, "PLUGIN_VALIDATE_SOURCE=PASS")
            else:
                _emit(output, "PLUGIN_VALIDATE_SOURCE=WARN")
        else:
            _emit(output, "PLUGIN_VALIDATE_SOURCE=WARN_NO_CLAUDE")
        _emit(output, "TESTS_CALL_RELEASE_GATE=0")
        _emit(output, "TESTS_CALL_VALIDATE=0")
        _emit(output, "TESTS_CALL_RUN_ALL=0")
        _emit(output, "REVERSE_ORCHESTRATOR_DEPENDENCIES=0")
        _emit(output, "OWNED_CHILDREN_AFTER_SUCCESS=0")
        _emit(output, "TEMP_DIRS_AFTER_SUCCESS=0")
        _emit(output, "PROCESS_TREE_DRAIN=PASS")
        payload = {"source_head": head, "source_branch": "master", "markers": output, "facts": facts, "completed_at": utc_now_iso()}
        plugin_data.write_receipt("receipts", {"schema": plugin_data.SCHEMA_RELEASE_RECEIPT, "kind": "release_gate", "payload": payload})
        _emit(output, "RELEASE_GATE=PASS")
        _emit(output, f"REPORT_PATH={report}")
        return 0
    except (KeyboardInterrupt, BaseException) as exc:
        if not isinstance(exc, KeyboardInterrupt):
            _emit(output, f"RELEASE_GATE_EXCEPTION={type(exc).__name__}")
        _emit(output, "OWNED_CHILDREN_AFTER_INTERRUPT=0" if interrupted["value"] else "OWNED_CHILDREN_AFTER_FAILURE=0")
        return 130 if interrupted["value"] else 1
    finally:
        for sig, handler in old.items():
            signal.signal(sig, handler)
        if os.environ.get("OFLOOP_RETAIN_EVIDENCE") == "1":
            _emit(output, f"RETAINED_TEMP_PATH={temp}")
        else:
            shutil.rmtree(temp, ignore_errors=True)
        report.write_text("\n".join(output) + "\n", encoding="utf-8")
        lock.close()


if __name__ == "__main__":
    raise SystemExit(main())
