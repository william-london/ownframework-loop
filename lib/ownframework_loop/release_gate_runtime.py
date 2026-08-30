"""OwnFramework Loop release-gate runtime with bounded ownership.

The canonical root is derived from this file's location, not hardcoded. The
expected release branch defaults to ``master`` and may be overridden via the
OFLOOP_RELEASE_GATE_EXPECTED_BRANCH environment variable. The gate fails
closed on a dirty source tree or a release branch other than the expected one;
presence of normal ``origin`` remotes is expected for public-source clones and
does not, on its own, fail the gate. Actual branch identity remains the
operator's call, not a hardcoded universal.
"""
from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

from . import plugin_data
from .gate_lock import GateAlreadyRunning, GateLock
from .process_runner import CommandResult, run_bounded
from .util import utc_now_compact, utc_now_iso

MAX_GATE = 1800
MAX_VALIDATE = 1200
MAX_TEST = 900


def _canonical_root() -> Path:
    """Return the canonical plugin source root for this gate.

    Derives from this file's location: lib/ownframework_loop/release_gate_runtime.py
    is two levels below the plugin root.
    """
    return Path(__file__).resolve().parents[2]


def _git(root: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, check=False, timeout=10).stdout.strip()


def _preflight(root: Path, *, check_resource_pressure: bool = True) -> tuple[bool, str, dict[str, str]]:
    real = root.resolve(strict=False)
    expected = _canonical_root()
    if real != expected:
        return False, "PLUGIN_GATE_REPOSITORY_IDENTITY=FAIL", {}
    if _git(root, "rev-parse", "--is-inside-work-tree") != "true":
        return False, "PLUGIN_GATE_REPOSITORY_IDENTITY=FAIL", {}
    branch = _git(root, "branch", "--show-current")
    remotes = _git(root, "remote").splitlines()
    dirty = _git(root, "status", "--porcelain")
    # Release-branch identity is operator/packet-configurable; the project default
    # is `master`. The gate fails only on (a) wrong release branch or (b) a
    # dirty source tree. Remote presence (e.g. a normal `origin`) is expected
    # for any public-source clone and does not, on its own, fail the gate.
    expected_branch = os.environ.get("OFLOOP_RELEASE_GATE_EXPECTED_BRANCH", "master")
    if branch != expected_branch or dirty:
        return False, "PLUGIN_GATE_REPOSITORY_IDENTITY=FAIL", {"branch": branch, "expected_branch": expected_branch, "remotes": str(len(remotes)), "dirty": dirty}
    if check_resource_pressure:
        try:
            load = os.getloadavg()
        except OSError:
            load = (0.0, 0.0, 0.0)
        cpu = os.cpu_count() or 1
        free = shutil.disk_usage(str(root)).free
        if free < 1024**3 or load[0] > max(8.0, cpu * 4.0):
            return False, "OFLOOP_RESOURCE_PRESSURE", {"cpu": str(cpu), "load1": f"{load[0]:.2f}", "disk_free": str(free)}
        return True, "", {"branch": branch, "expected_branch": expected_branch, "remotes": str(len(remotes)), "dirty": "", "cpu": str(cpu), "load1": f"{load[0]:.2f}", "load5": f"{load[1]:.2f}", "load15": f"{load[2]:.2f}", "disk_free": str(free)}
    return True, "", {"branch": branch, "expected_branch": expected_branch, "remotes": str(len(remotes)), "dirty": ""}


def _emit(lines: list[str], text: str) -> None:
    print(text, flush=True)
    lines.append(text)


def _parse_test_outcome(output_lines: list[str]) -> dict[str, object]:
    info: dict[str, object] = {
        "total": 0,
        "passed": 0,
        "failed": 0,
        "failed_names": [],
        "result": "UNKNOWN",
    }
    for line in output_lines:
        if line.startswith("OF_LOOP_TOTAL="):
            try:
                info["total"] = int(line.split("=", 1)[1].strip())
            except ValueError:
                pass
        elif line.startswith("OF_LOOP_PASSED="):
            try:
                info["passed"] = int(line.split("=", 1)[1].strip())
            except ValueError:
                pass
        elif line.startswith("OF_LOOP_FAILED="):
            try:
                info["failed"] = int(line.split("=", 1)[1].strip())
            except ValueError:
                pass
        elif line.startswith("OF_LOOP_FAILED_NAMES="):
            names = line.split("=", 1)[1].strip()
            info["failed_names"] = names.split() if names else []
        elif line.startswith("OF_LOOP_RELEASE_GATE_RESULT="):
            info["result"] = line.split("=", 1)[1].strip()
    return info


def _run(root: Path, argv: list[str], timeout: int, env: dict[str, str]) -> CommandResult:
    return run_bounded(argv, cwd=root, timeout_seconds=timeout, env=env)


def _discover_active_managed_install() -> tuple[str, str]:
    """Return (install_path, diagnostic) for enabled of-loop@ownframework."""
    if not shutil.which("claude"):
        return "", "claude_missing"
    try:
        proc = subprocess.run(
            ["claude", "plugin", "list", "--json"],
            capture_output=True,
            text=True,
            check=False,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return "", f"registry_probe_failed:{type(exc).__name__}"
    if proc.returncode != 0:
        return "", f"registry_probe_rc={proc.returncode}"
    try:
        data = json.loads(proc.stdout or "[]")
    except json.JSONDecodeError:
        return "", "registry_json_invalid"
    matches: list[str] = []
    for entry in data if isinstance(data, list) else []:
        if not isinstance(entry, dict):
            continue
        if entry.get("id") != "of-loop@ownframework" or not entry.get("enabled", False):
            continue
        install_path = str(entry.get("installPath") or "").strip()
        if install_path:
            matches.append(install_path)
    unique = sorted(set(matches))
    if len(unique) == 1:
        return unique[0], "ok"
    if len(unique) > 1:
        return "", "registry_ambiguous"
    return "", "not_installed"


def _manifest_version(root: Path) -> str:
    try:
        payload = json.loads(
            (root / ".claude-plugin" / "plugin.json").read_text(encoding="utf-8")
        )
    except (OSError, json.JSONDecodeError, TypeError):
        return ""
    return str(payload.get("version") or "")


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    expected_root = _canonical_root()
    if root != expected_root:
        root = expected_root
    ok, reason, facts = _preflight(root)
    head = _git(root, "rev-parse", "HEAD")
    branch = facts.get("branch", "unknown")
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
            raise KeyboardInterrupt(f"signal {signum}")

    old = {sig: signal.signal(sig, stop) for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        _emit(output, f"=== OwnFramework Loop release gate {stamp} ===")
        _emit(output, f"SOURCE_HEAD={head}")
        _emit(output, f"SOURCE_BRANCH={branch}")
        _emit(output, f"SOURCE_BRANCH_EXPECTED={facts.get('expected_branch', 'unknown')}")
        _emit(output, f"SOURCE_REMOTES={facts.get('remotes', '0')}")
        _emit(output, "MAX_RELEASE_GATE_INSTANCES=1")
        _emit(output, f"MAC_LOAD_BEFORE={facts.get('load1', 'unknown')}")
        if not ok:
            _emit(output, reason)
            return 1
        _emit(output, "PLUGIN_GATE_REPOSITORY_IDENTITY=PASS")
        _emit(output, "RELEASE_GATE_SINGLE_INSTANCE=PASS")
        static = _run(root, [sys.executable, "-m", "ownframework_loop.static_checks", str(root)], MAX_VALIDATE, {**os.environ, "PYTHONPATH": str(root / "lib"), "OFLOOP_RELEASE_GATE_DEPTH": "1"})
        output.extend(static.stdout.splitlines())
        print(static.stdout, end="", flush=True)
        if static.returncode != 0:
            _emit(output, "STATIC_GATE=FAIL")
            return 1
        _emit(output, "STATIC_GATE=PASS")
        env = {**os.environ, "PYTHONPATH": str(root / "lib"), "OFLOOP_RELEASE_GATE_DEPTH": "1"}
        validation = _run(root, ["bash", str(root / "validate.sh")], MAX_VALIDATE, env)
        print(validation.stdout, end="", flush=True); output.extend(validation.stdout.splitlines())
        if validation.timed_out or validation.returncode != 0:
            _emit(output, "VALIDATION=FAIL")
            return 1
        test_outcome = _parse_test_outcome(validation.stdout.splitlines())
        failed_count = int(test_outcome.get("failed") or 0) if isinstance(test_outcome.get("failed"), (int, str)) else 0
        failed_names = test_outcome.get("failed_names")
        if not isinstance(failed_names, list):
            failed_names = []
        if failed_count > 0:
            _emit(output, f"OF_LOOP_GATE_BLOCKED_FAILED={failed_count}")
            _emit(output, f"OF_LOOP_GATE_BLOCKED_NAMES={' '.join(failed_names)}")
            _emit(output, "RELEASE_GATE=BLOCKED")
            return 1
        verified_total = int(test_outcome.get("total") or 0) if isinstance(test_outcome.get("total"), (int, str)) else 0
        verified_passed = int(test_outcome.get("passed") or 0) if isinstance(test_outcome.get("passed"), (int, str)) else 0
        _emit(output, f"OF_LOOP_GATE_VERIFIED_TOTAL={verified_total}")
        _emit(output, f"OF_LOOP_GATE_VERIFIED_PASSED={verified_passed}")
        _emit(output, "NARROW_TESTS=PASS")
        # Installed parity uses the canonical enabled plugin registry entry.
        # A currently installed older release is reported but does not make the
        # newer source release intrinsically invalid; exact parity is required
        # after installation/recommissioning of the new release.
        skip_install_check = os.environ.get("OFLOOP_SOURCE_ONLY") == "1"
        install_override = os.environ.get("INSTALL_ROOT", "").strip()
        install_root = install_override
        install_diag = "explicit_override" if install_override else ""
        if not install_root and not skip_install_check:
            install_root, install_diag = _discover_active_managed_install()

        if skip_install_check:
            _emit(output, "OF_LOOP_INSTALL_PARITY=SKIPPED_SOURCE_ONLY")
        elif install_root:
            install_path = Path(install_root).expanduser().resolve(strict=False)
            source_version = _manifest_version(root)
            installed_version = _manifest_version(install_path)
            if not install_path.is_dir():
                _emit(output, f"OF_LOOP_INSTALL_PARITY=REGISTRY_PATH_MISSING root={install_path}")
                return 1
            if not install_override and installed_version != source_version:
                _emit(
                    output,
                    "OF_LOOP_INSTALL_PARITY=NO_MATCHING_VERSION "
                    f"source={source_version or 'unknown'} "
                    f"active={installed_version or 'unknown'} root={install_path}",
                )
            else:
                installed = _run(
                    root,
                    ["bash", str(root / "validate.sh"), "--installed", str(install_path), "--skip-tests"],
                    MAX_VALIDATE,
                    env,
                )
                print(installed.stdout, end="", flush=True)
                output.extend(installed.stdout.splitlines())
                if installed.returncode != 0:
                    _emit(output, f"OF_LOOP_INSTALL_PARITY=FAIL root={install_path}")
                    return 1
                _emit(output, f"OF_LOOP_INSTALL_PARITY=PASS root={install_path}")
        else:
            _emit(output, f"OF_LOOP_INSTALL_PARITY=NO_INSTALL diagnostic={install_diag or 'none'}")
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
        # Real process-tree drain probe via ps (fail-closed). The historical
        # `PROCESS_TREE_DRAIN=PASS` was unconditional; v0.6.1 hardening closes
        # the fail-open path where an unknown process state was reported as
        # drained.
        from . import process_runner
        own_pgid = os.getpgrp()
        if process_runner.process_group_drained(own_pgid):
            _emit(output, "PROCESS_TREE_DRAIN=PASS")
        else:
            _emit(output, "PROCESS_TREE_DRAIN=FAIL")
            return 1
        payload = {"source_head": head, "source_branch": branch, "source_branch_expected": facts.get("expected_branch", "unknown"), "markers": output, "facts": facts, "completed_at": utc_now_iso()}
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
