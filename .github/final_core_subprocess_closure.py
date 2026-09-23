from __future__ import annotations

import ast
from pathlib import Path


def read(path: str) -> str:
    return Path(path).read_text(encoding="utf-8")


def write(path: str, text: str) -> None:
    Path(path).write_text(text, encoding="utf-8")


def replace_once_if_present(path: str, old: str, new: str, label: str) -> None:
    text = read(path)
    count = text.count(old)
    if count > 1:
        raise SystemExit(f"{label}: ambiguous old contract count={count}")
    if count == 1:
        write(path, text.replace(old, new, 1))


def require(path: str, needle: str, label: str) -> None:
    if needle not in read(path):
        raise SystemExit(f"{label}: required postcondition missing")


# The central runner was independently hardened while this closure was staged.
# Preserve it and require the semantics callers now rely on.
require("lib/ownframework_loop/process_runner.py", "def run_bounded_capture(", "bounded capture")
require("lib/ownframework_loop/process_runner.py", "capture_output: bool = True", "capture compatibility")
require("lib/ownframework_loop/process_runner.py", "check: bool = False", "check compatibility")
require("lib/ownframework_loop/process_runner.py", "class ProcessGroupLeakError", "leak exception")

# dispatch: internal finalizer transport is an owned subprocess tree.
p = "lib/ownframework_loop/dispatch.py"
text = read(p)
if "    process_runner,\n" not in text:
    anchor = "    packet as packet_mod,\n    program as program_mod,\n"
    if text.count(anchor) != 1:
        raise SystemExit("dispatch import anchor missing")
    text = text.replace(anchor, "    packet as packet_mod,\n    process_runner,\n    program as program_mod,\n", 1)
old = '''        proc = subprocess.run(
            [_ofloop_bin(), *args],
            capture_output=True,
            text=True,
            check=False,
            timeout=(int(timeout_seconds) if timeout_seconds and timeout_seconds > 0 else None),
        )
'''
new = '''        proc = process_runner.run_bounded_capture(
            [_ofloop_bin(), *args],
            timeout_seconds=(
                int(timeout_seconds) if timeout_seconds and timeout_seconds > 0 else None
            ),
        )
'''
if old in text:
    text = text.replace(old, new, 1)
leak_block = '''    except process_runner.ProcessGroupLeakError as exc:
        raise DispatchError(
            f"ofloop {' '.join(args)} left descendant processes after command exit"
        ) from exc
'''
if leak_block not in text:
    anchor = '''    except subprocess.TimeoutExpired as exc:
        raise DispatchError(
            f"ofloop {' '.join(args)} exceeded finalization wall budget "
            f"({int(timeout_seconds or 0)}s)"
        ) from exc
'''
    if text.count(anchor) != 1:
        raise SystemExit("dispatch timeout boundary anchor missing")
    text = text.replace(anchor, anchor + leak_block, 1)
write(p, text)

# runtime identity: preserve binary output support while bounding git helpers.
p = "lib/ownframework_loop/runtime_identity.py"
text = read(p)
if "from . import process_runner\n" not in text:
    text = text.replace("from pathlib import Path\n", "from pathlib import Path\n\nfrom . import process_runner\n", 1)
old = '''    return subprocess.run(
        ["git", "-C", str(root), *args],
        capture_output=True,
        text=text,
        check=False,
        timeout=10,
    )
'''
new = '''    return process_runner.run_bounded_capture(
        ["git", "-C", str(root), *args],
        text=text,
        timeout_seconds=10,
    )
'''
if old in text:
    text = text.replace(old, new, 1)
text = text.replace("(OSError, subprocess.TimeoutExpired)", "(OSError, subprocess.SubprocessError)")
write(p, text)

# Release-gate read-only git probes.
p = "lib/ownframework_loop/release_gate_runtime.py"
text = read(p)
text = text.replace(
    "from .process_runner import CommandResult, run_bounded\n",
    "from .process_runner import CommandResult, run_bounded, run_bounded_capture\n",
    1,
)
text = text.replace(
    '    return subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, check=False, timeout=10).stdout.strip()\n',
    '    return run_bounded_capture(["git", "-C", str(root), *args], timeout_seconds=10).stdout.strip()\n',
    1,
)
write(p, text)

# macOS service-manager command lifecycle.
p = "lib/ownframework_loop/macos_service_lifecycle.py"
text = read(p)
if "from . import process_runner\n" not in text:
    text = text.replace("from typing import Sequence\n", "from typing import Sequence\n\nfrom . import process_runner\n", 1)
old = '''    proc = subprocess.run(
        list(args),
        check=False,
        capture_output=True,
        text=True,
        timeout=_LAUNCHCTL_TIMEOUT_SECONDS,
    )
'''
new = '''    proc = process_runner.run_bounded_capture(
        list(args),
        timeout_seconds=_LAUNCHCTL_TIMEOUT_SECONDS,
    )
'''
text = text.replace(old, new, 1)
write(p, text)

# Read-model git observations.
p = "lib/ownframework_loop/supervisor_readmodel.py"
text = read(p)
if "from . import process_runner\n" not in text:
    text = text.replace("from . import state as state_mod\n", "from . import process_runner\nfrom . import state as state_mod\n", 1)
old = '''        r = subprocess.run(
            ["git", "-C", str(repo), *args],
            capture_output=True,
            text=True,
            check=False,
            timeout=timeout,
        )
'''
new = '''        r = process_runner.run_bounded_capture(
            ["git", "-C", str(repo), *args],
            timeout_seconds=timeout,
        )
'''
text = text.replace(old, new, 1)
text = text.replace("    except (OSError, subprocess.TimeoutExpired) as exc:\n", "    except (OSError, subprocess.SubprocessError) as exc:\n")
write(p, text)

# PID/start-time observation on macOS.
p = "lib/ownframework_loop/supervisor_process.py"
text = read(p)
if "from . import process_runner\n" not in text:
    text = text.replace("import time\n", "import time\n\nfrom . import process_runner\n", 1)
old = '''        r = subprocess.run(
            ["ps", "-o", "etime=", "-p", str(pid)],
            capture_output=True, text=True, check=False, timeout=2,
        )
'''
new = '''        r = process_runner.run_bounded_capture(
            ["ps", "-o", "etime=", "-p", str(pid)],
            timeout_seconds=2,
        )
'''
text = text.replace(old, new, 1)
write(p, text)

# Governed research broker: timeout/lifecycle owns the entire broker group.
p = "lib/ownframework_loop/supervisor_research.py"
text = read(p)
if "from . import process_runner\n" not in text:
    text = text.replace("from typing import Any, Callable\n", "from typing import Any, Callable\n\nfrom . import process_runner\n", 1)
text = text.replace("subprocess.run calls", "bounded broker process calls")
text = text.replace("via ``subprocess.run`` (NOT", "via the bounded supervisor process runner (NOT")
text = text.replace("dispatches the broker via subprocess.run —", "dispatches the broker via the bounded process runner —")
old = '''        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=False,
            timeout=float(os.environ.get(
                "OFLOOP_RESEARCH_BROKER_TIMEOUT",
                "60",
            )),
        )
'''
new = '''        proc = process_runner.run_bounded_capture(
            cmd,
            timeout_seconds=float(os.environ.get(
                "OFLOOP_RESEARCH_BROKER_TIMEOUT",
                "60",
            )),
        )
'''
text = text.replace(old, new, 1)
leak = '''    except process_runner.ProcessGroupLeakError as exc:
        return {
            "ok": False,
            "error_class": "BrokerProcessLeak",
            "error": str(exc),
        }
'''
if leak not in text:
    anchor = '''    except Exception as exc:  # pragma: no cover
        return {
            "ok": False,
            "error_class": "BrokerDispatchFailed",
'''
    if text.count(anchor) != 1:
        raise SystemExit("research generic exception anchor missing")
    text = text.replace(anchor, leak + anchor, 1)
write(p, text)

# Execution-start cleanliness probe cannot hang indefinitely.
p = "lib/ownframework_loop/execution_start.py"
text = read(p)
if "    process_runner,\n" not in text:
    text = text.replace("    packet as packet_mod,\n    state as state_mod,\n", "    packet as packet_mod,\n    process_runner,\n    state as state_mod,\n", 1)
old = '''    p = subprocess.run(
        [
            "git",
            "-C",
            str(canonical_repo),
            "status",
            "--porcelain",
            "--untracked-files=no",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
'''
new = '''    p = process_runner.run_bounded_capture(
        [
            "git",
            "-C",
            str(canonical_repo),
            "status",
            "--porcelain",
            "--untracked-files=no",
        ],
        timeout_seconds=10,
    )
'''
text = text.replace(old, new, 1)
write(p, text)

# Program source accounting is bounded and preserves check=True semantics.
p = "lib/ownframework_loop/program.py"
text = read(p)
if "from . import process_runner\n" not in text:
    text = text.replace("from typing import Any\n", "from typing import Any\n\nfrom . import process_runner\n", 1)
old = '''    diff = subprocess.run(
        ["git", "-C", str(canonical_repo), "diff", "--no-color", baseline_sha, candidate_sha, "--numstat"],
        capture_output=True,
        text=True,
        check=True,
    )
'''
new = '''    diff = process_runner.run_bounded_capture(
        ["git", "-C", str(canonical_repo), "diff", "--no-color", baseline_sha, candidate_sha, "--numstat"],
        timeout_seconds=30,
        check=True,
    )
'''
text = text.replace(old, new, 1)
write(p, text)

# New-repo bootstrap git effects are bounded and still check failures.
p = "lib/ownframework_loop/cli.py"
text = read(p)
if "    process_runner,\n" not in text:
    text = text.replace(
        "    branch_resolver, capabilities as capabilities_mod, commissioning as commissioning_mod, execution_start,\n",
        "    branch_resolver, capabilities as capabilities_mod, commissioning as commissioning_mod, execution_start,\n    process_runner,\n",
        1,
    )
text = text.replace('    import subprocess\n    subprocess.run(["git", "init", "-b", "master", str(target)], check=True)\n',
                    '    process_runner.run_bounded_capture(\n        ["git", "init", "-b", "master", str(target)],\n        timeout_seconds=30, capture_output=False, check=True,\n    )\n', 1)
text = text.replace('        subprocess.run(["git", "-C", str(target), "add", "README.md", ".gitignore"], check=True)\n',
                    '        process_runner.run_bounded_capture(\n            ["git", "-C", str(target), "add", "README.md", ".gitignore"],\n            timeout_seconds=30, capture_output=False, check=True,\n        )\n', 1)
old = '''        subprocess.run(
            ["git", "-C", str(target), "commit", "-m", "loop-v1: minimal bootstrap baseline"],
            check=True, env=env,
        )
'''
new = '''        process_runner.run_bounded_capture(
            ["git", "-C", str(target), "commit", "-m", "loop-v1: minimal bootstrap baseline"],
            timeout_seconds=30, capture_output=False, check=True, env=env,
        )
'''
text = text.replace(old, new, 1)
write(p, text)

# Semantic provider: version probe + worker process group ownership.
p = "lib/ownframework_loop/supervisor_runner.py"
text = read(p)
if "from . import process_runner\n" not in text:
    text = text.replace("from . import git_checks\n", "from . import git_checks\nfrom . import process_runner\n", 1)
old = '''        proc = subprocess.run(
            [executable, "--version"],
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
'''
new = '''        proc = process_runner.run_bounded_capture(
            [executable, "--version"],
            timeout_seconds=10,
        )
'''
text = text.replace(old, new, 1)
text = text.replace("    except (OSError, subprocess.TimeoutExpired):\n        return None\n", "    except (OSError, subprocess.SubprocessError):\n        return None\n", 1)
old_term = '''def _terminate_group(proc: subprocess.Popen[str], grace_seconds: float = 3.0) -> None:
    """Terminate and reap one semantic worker process group."""
    if proc.poll() is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        proc.wait(timeout=grace_seconds)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    proc.wait()
'''
new_term = '''def _terminate_group(proc: subprocess.Popen[str], grace_seconds: float = 3.0) -> None:
    """Terminate and reap one semantic worker process group."""
    process_runner.terminate_process_group(proc, grace_seconds=grace_seconds)
'''
text = text.replace(old_term, new_term, 1)
if "        lifecycle_leak = False\n" not in text:
    text = text.replace("        timed_out = False\n        # Use communicate(input=prompt)", "        timed_out = False\n        lifecycle_leak = False\n        # Use communicate(input=prompt)", 1)
old_timeout = '''        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                stdout_data, stderr_data = proc.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                stdout_data, stderr_data = proc.communicate()
'''
new_timeout = '''        except subprocess.TimeoutExpired:
            timed_out = True
            process_runner.terminate_process_group(proc)
            stdout_data, stderr_data = proc.communicate()
'''
text = text.replace(old_timeout, new_timeout, 1)
normal_drain = '''        if not timed_out and process_runner.process_group_exists(proc.pid):
            lifecycle_leak = True
            process_runner.terminate_process_group(proc)

'''
if normal_drain not in text:
    anchor = '''        if durable_files is not None:
            # Close our handles; the child holds its own dup until exit.
'''
    if text.count(anchor) != 1:
        raise SystemExit("runner durable-files anchor missing")
    text = text.replace(anchor, normal_drain + anchor, 1)
leak_result = '''        if lifecycle_leak:
            return RunnerResult(
                ok=False,
                returncode=process_runner.PROCESS_GROUP_LEAK_RC,
                cost_usd=0.0,
                stdout=(stdout_data or "")[-RUNNER_DIAGNOSTIC_MAX_CHARS:],
                stderr=((stderr_data or "") + "\\n" + process_runner.PROCESS_GROUP_LEAK_MARKER)[-RUNNER_DIAGNOSTIC_MAX_CHARS:],
                pid=int(proc.pid),
                cost_known=False,
                tokens_known=False,
            )

'''
if leak_result not in text:
    anchor = "        if timed_out:\n            if durable_files is not None and envelope_error:\n"
    if text.count(anchor) != 1:
        raise SystemExit("runner timeout-result anchor missing")
    text = text.replace(anchor, leak_result + anchor, 1)
write(p, text)

# Documentation drift after rerouting broker execution.
for p in ("lib/ownframework_loop/capabilities.py", "lib/ownframework_loop/supervisor.py"):
    text = read(p)
    text = text.replace("subprocess.run (NOT under Claude's Bash sandbox)", "the bounded supervisor process runner (NOT under Claude's Bash sandbox)")
    text = text.replace("dispatches the broker via subprocess.run —", "dispatches the broker via the bounded process runner —")
    write(p, text)

# Canonical static regression: core cannot re-introduce raw subprocess.run;
# direct Popen ownership is restricted to audited lifecycle owners.
p = "tests/unit/test_final_hardening_process_and_lock.sh"
text = read(p)
if 'export OFLOOP_ROOT="$ROOT"\n' not in text:
    text = text.replace('export PYTHONPATH="$ROOT/lib${PYTHONPATH:+:$PYTHONPATH}"\n', 'export PYTHONPATH="$ROOT/lib${PYTHONPATH:+:$PYTHONPATH}"\nexport OFLOOP_ROOT="$ROOT"\n', 1)
if "import ast\n" not in text:
    text = text.replace("import os\n", "import ast\nimport os\n", 1)
fn = '''def prove_core_has_no_raw_subprocess_run() -> None:
    root = Path(os.environ["OFLOOP_ROOT"])
    raw_runs: list[str] = []
    popen_calls: list[str] = []
    allowed_popen = {
        "process_runner.py",
        "validation_environment.py",
        "validation_executor.py",
        "supervisor_runner.py",
    }
    for path in sorted((root / "lib" / "ownframework_loop").rglob("*.py")):
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Attribute):
                continue
            if not isinstance(node.func.value, ast.Name) or node.func.value.id != "subprocess":
                continue
            if node.func.attr == "run":
                raw_runs.append(f"{path.relative_to(root)}:{node.lineno}")
            elif node.func.attr == "Popen" and path.name not in allowed_popen:
                popen_calls.append(f"{path.relative_to(root)}:{node.lineno}")
    assert not raw_runs, f"raw subprocess.run bypasses remain: {raw_runs}"
    assert not popen_calls, f"unaudited subprocess.Popen owners remain: {popen_calls}"


'''
if "def prove_core_has_no_raw_subprocess_run()" not in text:
    marker = "def prove_validation_timeout_drains_descendants() -> None:\n"
    if text.count(marker) != 1:
        raise SystemExit("test insertion anchor missing")
    text = text.replace(marker, fn + marker, 1)
if "prove_core_has_no_raw_subprocess_run()\n" not in text.split("print(\"FINAL_HARDENING_PROCESS_AND_LOCK=PASS\")", 1)[0].splitlines()[-5:]:
    anchor = "prove_capability_version_probe_requires_zero_exit()\nprove_validation_timeout_drains_descendants()\n"
    if anchor in text:
        text = text.replace(anchor, "prove_capability_version_probe_requires_zero_exit()\nprove_core_has_no_raw_subprocess_run()\nprove_validation_timeout_drains_descendants()\n", 1)
write(p, text)

# Mechanical final census.
raw_runs: list[str] = []
bad_popen: list[str] = []
allowed = {"process_runner.py", "validation_environment.py", "validation_executor.py", "supervisor_runner.py"}
for path in sorted(Path("lib/ownframework_loop").rglob("*.py")):
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Attribute):
            continue
        if not isinstance(node.func.value, ast.Name) or node.func.value.id != "subprocess":
            continue
        if node.func.attr == "run":
            raw_runs.append(f"{path}:{node.lineno}")
        elif node.func.attr == "Popen" and path.name not in allowed:
            bad_popen.append(f"{path}:{node.lineno}")
if raw_runs:
    raise SystemExit(f"raw subprocess.run remains: {raw_runs}")
if bad_popen:
    raise SystemExit(f"unaudited subprocess.Popen owners remain: {bad_popen}")

print("FINAL_CORE_SUBPROCESS_TRANSFORM=PASS")
