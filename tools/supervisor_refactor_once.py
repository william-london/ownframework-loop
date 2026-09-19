from __future__ import annotations

import ast
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "lib" / "ownframework_loop"
SUP = LIB / "supervisor.py"

source = SUP.read_text(encoding="utf-8")
tree = ast.parse(source)
lines = source.splitlines(keepends=True)


def top_node(name: str):
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and node.name == name:
            return node
    raise KeyError(name)


def assign_node(name: str):
    for node in tree.body:
        if isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = []
            if isinstance(node, ast.Assign):
                targets = node.targets
            else:
                targets = [node.target]
            for target in targets:
                if isinstance(target, ast.Name) and target.id == name:
                    return node
    raise KeyError(name)


def bounds(node) -> tuple[int, int]:
    start = node.lineno
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and node.decorator_list:
        start = min([start, *(d.lineno for d in node.decorator_list)])
    return start, node.end_lineno


def segment_node(node) -> str:
    start, end = bounds(node)
    return "".join(lines[start - 1 : end]).rstrip() + "\n"


def segment(name: str) -> str:
    return segment_node(top_node(name))


def assignment(name: str) -> str:
    return segment_node(assign_node(name))


def replace_nodes(replacements: dict[str, str], assignment_replacements: dict[str, str] | None = None) -> str:
    edits: list[tuple[int, int, str]] = []
    for name, replacement in replacements.items():
        node = top_node(name)
        start, end = bounds(node)
        edits.append((start, end, replacement.rstrip() + "\n"))
    for name, replacement in (assignment_replacements or {}).items():
        node = assign_node(name)
        start, end = bounds(node)
        edits.append((start, end, replacement.rstrip() + "\n"))
    out = lines[:]
    for start, end, replacement in sorted(edits, reverse=True):
        out[start - 1 : end] = [replacement]
    return "".join(out)


# ---------------------------------------------------------------------------
# Process authority: process-local execution ownership + PID identity/liveness.
# ---------------------------------------------------------------------------
process_module = '''"""Supervisor process authority.

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

'''
for name in [
    "_register_local_execution",
    "_local_execution_owned",
    "_clear_local_executions_for_thread",
    "_pid_alive",
    "_read_pid_start_identity",
    "_pid_identity_proven",
    "_terminate_owned_process_group",
    "_read_pid_start_time",
    "_boot_time_unix",
]:
    process_module += segment(name) + "\n"
process_module += '''__all__ = [
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
]\n'''
(LIB / "supervisor_process.py").write_text(process_module, encoding="utf-8")


# ---------------------------------------------------------------------------
# Runtime/environment authority: commissioned env, runtime generation, cache GC.
# ---------------------------------------------------------------------------
runtime_module = '''"""Supervisor runtime/environment authority.

Owns commissioned service-environment loading, exact installed-runtime
generation observation, and disposable semantic runtime-cache lifecycle.
Runtime identity itself remains delegated to runtime_identity.py.
"""
from __future__ import annotations

import json
import os
import shutil
import stat
from pathlib import Path
from typing import Any

from . import runtime_env, runtime_identity
from . import supervisor_db as _db_mod

'''
runtime_module += assignment("_SERVICE_ENV_FILE_VAR") + "\n"
runtime_module += assignment("_SERVICE_ENV_ALLOWED_KEYS") + "\n"
runtime_module += segment("_load_service_env_file") + "\n"
runtime_module += segment("runtime_generation") + "\n"
runtime_module += "_current_runtime_generation = runtime_generation\n\n"
runtime_module += segment("_runtime_cache_run_root") + "\n"
runtime_module += segment("_cleanup_terminal_runtime_cache") + "\n"
cleanup_done = segment("_cleanup_done_runtime_caches")
cleanup_done = cleanup_done.replace("default_db_path()", "_db_mod.default_db_path()")
cleanup_done = cleanup_done.replace("_managed_connect_readonly(", "_db_mod._managed_connect_readonly(")
runtime_module += cleanup_done + "\n"
runtime_module += '''__all__ = [
    "_load_service_env_file",
    "runtime_generation",
    "_current_runtime_generation",
    "_runtime_cache_run_root",
    "_cleanup_terminal_runtime_cache",
    "_cleanup_done_runtime_caches",
]\n'''
(LIB / "supervisor_runtime.py").write_text(runtime_module, encoding="utf-8")


# ---------------------------------------------------------------------------
# Prompt authority: deterministic role prompt bytes + immutable provenance.
# ---------------------------------------------------------------------------
prompt_module = '''"""Supervisor prompt construction and provenance authority."""
from __future__ import annotations

import hashlib
import json
import os
import stat
from pathlib import Path
from typing import Any

from . import state as state_mod
from . import util

'''
for name in ["_source_root", "_load_role_prompt", "_write_semantic_prompt_provenance"]:
    prompt_module += segment(name) + "\n"
prompt_module += '''__all__ = [
    "_source_root",
    "_load_role_prompt",
    "_write_semantic_prompt_provenance",
]\n'''
(LIB / "supervisor_prompts.py").write_text(prompt_module, encoding="utf-8")


# ---------------------------------------------------------------------------
# Runner I/O also owns durable worker output path construction.
# ---------------------------------------------------------------------------
runner_io_path = LIB / "supervisor_runner_io.py"
runner_io = runner_io_path.read_text(encoding="utf-8")
runner_io = runner_io.replace(
    "from pathlib import Path\n",
    "from pathlib import Path\n\nfrom . import state as state_mod\nfrom . import supervisor_db as _db_mod\n",
)
# Remove the old __all__ tail and replace it after adding the path primitives.
runner_io = runner_io[: runner_io.index("\n__all__ = [")].rstrip() + "\n\n"
runner_io += segment("default_worker_log_dir") + "\n"
runner_io += segment("_slug_repo") + "\n"
worker_paths = segment("worker_log_paths")
worker_paths = worker_paths.replace("_ensure_private_dir(", "_db_mod._ensure_private_dir(")
worker_paths = worker_paths.replace("default_db_path()", "_db_mod.default_db_path()")
runner_io += worker_paths + "\n"
runner_io += '''__all__ = [
    "CLAUDE_PROVIDER_ENVELOPE_MAX_BYTES",
    "RUNNER_DIAGNOSTIC_MAX_CHARS",
    "_read_durable_provider_envelope",
    "_read_durable_diagnostic_tail",
    "default_worker_log_dir",
    "_slug_repo",
    "worker_log_paths",
]\n'''
runner_io_path.write_text(runner_io, encoding="utf-8")


# ---------------------------------------------------------------------------
# Claude runner: provider execution/configuration and failure observation only.
# Durable retry/quarantine policy stays outside this provider module.
# ---------------------------------------------------------------------------
runner_module = '''"""Claude Code supervisor runner implementation.

This is one provider implementation behind supervisor_runner_registry's generic
contract. It owns Claude-specific invocation, sandbox/settings construction,
provider-version observation, subprocess lifecycle, and failure observation.
It does not own durable retry/quarantine policy.
"""
from __future__ import annotations

import json
import math
import os
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any

from . import capabilities as capabilities_mod
from . import capability_binding as capability_binding_mod
from . import dispatch as dispatch_mod
from . import git_checks
from . import runner_profiles as runner_profiles_mod
from . import runtime_env
from . import supervisor_accounting as _accounting_mod
from . import supervisor_db as _db_mod
from . import supervisor_prompts as _prompts_mod
from . import supervisor_runner_io as _runner_io_mod
from . import supervisor_runner_registry as _runner_registry_mod

RunnerResult = _runner_registry_mod.RunnerResult
RunnerReadiness = _runner_registry_mod.RunnerReadiness
RUNNER_DIAGNOSTIC_MAX_CHARS = _runner_io_mod.RUNNER_DIAGNOSTIC_MAX_CHARS

'''
for constant in [
    "CLAUDE_BUILDER_TOOLS",
    "CLAUDE_REVIEWER_TOOLS",
    "_WORKER_RELEASE_GATE_CODE",
    "MIN_SECURE_CLAUDE_CODE_VERSION",
]:
    runner_module += assignment(constant) + "\n"
runner_module += segment("WorkerLaunchError") + "\n"
for name in [
    "_claude_cli_version",
    "_validate_claude_extra_args",
    "_parse_adapter_auth_read_paths",
    "_semantic_worker_settings",
    "_terminate_group",
    "ClaudeCodeRunner",
    "_RegisteredClaudeCodeRunner",
    "_classify_runner_failure",
    "_classify_exception",
]:
    runner_module += segment(name) + "\n"
runner_module = runner_module.replace("default_db_path()", "_db_mod.default_db_path()")
runner_module = runner_module.replace("_ensure_private_dir(", "_db_mod._ensure_private_dir(")
runner_module = runner_module.replace("_ensure_private_file_mode(", "_db_mod._ensure_private_file_mode(")
runner_module = runner_module.replace("_source_root()", "_prompts_mod._source_root()")
runner_module = runner_module.replace("_load_role_prompt(", "_prompts_mod._load_role_prompt(")
runner_module = runner_module.replace("_write_semantic_prompt_provenance(", "_prompts_mod._write_semantic_prompt_provenance(")
runner_module = runner_module.replace("_read_durable_provider_envelope(", "_runner_io_mod._read_durable_provider_envelope(")
runner_module = runner_module.replace("_read_durable_diagnostic_tail(", "_runner_io_mod._read_durable_diagnostic_tail(")
runner_module = runner_module.replace("_extract_effective_model(", "_accounting_mod._extract_effective_model(")
runner_module = runner_module.replace("_extract_model_usage_json(", "_accounting_mod._extract_model_usage_json(")
runner_module += '''__all__ = [
    "WorkerLaunchError",
    "ClaudeCodeRunner",
    "_RegisteredClaudeCodeRunner",
    "_claude_cli_version",
    "_validate_claude_extra_args",
    "_parse_adapter_auth_read_paths",
    "_semantic_worker_settings",
    "_terminate_group",
    "_classify_runner_failure",
    "_classify_exception",
]\n'''
(LIB / "supervisor_runner.py").write_text(runner_module, encoding="utf-8")


# ---------------------------------------------------------------------------
# Remove production upward imports from attempts/claims/recovery.
# ---------------------------------------------------------------------------
attempts_path = LIB / "supervisor_attempts.py"
attempts = attempts_path.read_text(encoding="utf-8")
attempts = attempts.replace(
    "from . import supervisor_runner_registry as _runner_registry_mod\n",
    "from . import supervisor_runner_registry as _runner_registry_mod\n"
    "from . import supervisor_process as _process_mod\n"
    "from . import supervisor_runner_io as _runner_io_mod\n",
)
attempts = attempts.replace(
    "    # worker_log_paths is owned by supervisor.py until it is relocated\n"
    "    # with the runner-execution authority.  Lazy import keeps the\n"
    "    # dependency direction correct.\n"
    "    from . import supervisor as _supervisor_mod\n"
    "    worker_log_paths = _supervisor_mod.worker_log_paths\n",
    "    worker_log_paths = _runner_io_mod.worker_log_paths\n",
)
attempts = attempts.replace(
    "    # _read_pid_start_identity is a PID-introspection helper owned\n"
    "    # by the runner-execution authority once that lands.  Until\n"
    "    # then it lives in supervisor.py and is reached via a lazy\n"
    "    # function-scope import.\n"
    "    from . import supervisor as _supervisor_mod\n"
    "    _read_pid_start_identity = _supervisor_mod._read_pid_start_identity\n",
    "    _read_pid_start_identity = _process_mod._read_pid_start_identity\n",
)
attempts = attempts.replace(
    "  * The ClaudeCodeRunner class + its ``run`` method (still\n    pending extraction to ``supervisor_runner.py``).\n"
    "  * ``_pid_alive`` / ``_terminate_owned_process_group`` /\n"
    "    ``_local_execution_owned`` / ``_read_pid_start_identity`` —\n"
    "    these are process / PID introspection helpers owned by the\n"
    "    runner-execution authority once that lands; until then they\n"
    "    live in supervisor.py and attempts reaches them via a\n"
    "    lazy function-scope import (documented follow-up target).\n",
    "  * Composition/orchestration remains in ``supervisor.py``.\n"
    "  * Process identity is owned by ``supervisor_process`` and runner\n"
    "    output paths are owned by ``supervisor_runner_io``.\n",
)
attempts = attempts.replace(
    "  supervisor_attempts -> supervisor (LAZY function-scope only,\n"
    "      for the process-introspection helpers and the runner\n"
    "      preflight, with documented test-monkey-patch aliases)\n",
    "  supervisor_attempts -> supervisor_process + supervisor_runner_io\n",
)
attempts_path.write_text(attempts, encoding="utf-8")

claims_path = LIB / "supervisor_claims.py"
claims = claims_path.read_text(encoding="utf-8")
claims = claims.replace(
    "from . import supervisor_identity as _identity_mod\n",
    "from . import supervisor_identity as _identity_mod\n"
    "from . import supervisor_runner_registry as _runner_registry_mod\n"
    "from . import supervisor_runtime as _runtime_mod\n",
)
old_claim_bridge = '''    # registered_runner_ids + _current_runtime_generation + identity
    # helpers: all reached through the supervisor facade (NOT
    # directly from supervisor_runner_registry / supervisor_identity)
    # so test monkey-patches on ``supervisor.X`` continue to apply.
    # The supervisor facade re-exports the canonical bodies, so the
    # monkey-patch surface stays stable.
    from . import supervisor as _supervisor_mod
    _current_runtime_generation = _supervisor_mod._current_runtime_generation
    _repository_scheduling_identity = _supervisor_mod._repository_scheduling_identity
    _workspace_scheduling_identity = _supervisor_mod._workspace_scheduling_identity
    _packet_execution_mode = _supervisor_mod._packet_execution_mode
    registered_runner_ids = _supervisor_mod.registered_runner_ids
'''
new_claim_bridge = '''    _current_runtime_generation = _runtime_mod.runtime_generation
    _repository_scheduling_identity = _identity_mod._repository_scheduling_identity
    _workspace_scheduling_identity = _identity_mod._workspace_scheduling_identity
    _packet_execution_mode = _identity_mod._packet_execution_mode
    registered_runner_ids = _runner_registry_mod.registered_runner_ids
'''
if old_claim_bridge not in claims:
    raise RuntimeError("claims monkey-patch bridge text drifted")
claims = claims.replace(old_claim_bridge, new_claim_bridge)
claims = claims.replace(
    "  supervisor_claims -> supervisor (LAZY function-scope only,\n"
    "      for the composition-facade helpers that will move to\n"
    "      the runner-execution authority once it is extracted)\n",
    "  supervisor_claims -> supervisor_runner_registry + supervisor_runtime\n",
)
claims_path.write_text(claims, encoding="utf-8")

recovery_path = LIB / "supervisor_recovery.py"
recovery = recovery_path.read_text(encoding="utf-8")
recovery = recovery.replace(
    "from . import supervisor_accounting as _accounting_mod\n",
    "from . import supervisor_accounting as _accounting_mod\n"
    "from . import supervisor_attempts as _attempts_mod\n"
    "from . import supervisor_process as _process_mod\n",
)
start = recovery.index("    from . import supervisor as _supervisor_mod\n")
end_marker = "    _account_attempt_cost = _supervisor_mod._account_attempt_cost\n"
end = recovery.index(end_marker, start) + len(end_marker)
recovery_bridge = '''    _local_execution_owned = _process_mod._local_execution_owned
    _pid_alive = _process_mod._pid_alive
    _terminate_owned_process_group = _process_mod._terminate_owned_process_group
    _parse_cost_from_durable_stdout = _accounting_mod._parse_cost_from_durable_stdout
    _parse_token_usage_from_durable_stdout = _accounting_mod._parse_token_usage_from_durable_stdout
    _extract_effective_model_from_durable_stdout = _accounting_mod._extract_effective_model_from_durable_stdout
    _extract_model_usage_json_from_durable_stdout = _accounting_mod._extract_model_usage_json_from_durable_stdout
    _account_attempt_cost = _attempts_mod._account_attempt_cost
'''
recovery = recovery[:start] + recovery_bridge + recovery[end:]
# Add durable failure policy here: classification remains provider-side; policy is recovery authority.
policy = segment("_apply_failure_policy").replace("_update_job(", "_db_mod._update_job(")
recovery += "\n\n" + policy
recovery = recovery.replace(
    "Dependency direction: this module imports from supervisor_db\n"
    "for the connection primitives, from supervisor_accounting\n"
    "for cost/token/model observation, and from supervisor via\n"
    "lazy function-scope imports for the process-ownership\n"
    "helpers (``_local_execution_owned``, ``_pid_alive``,\n"
    "``_terminate_owned_process_group``, ``_account_attempt_cost``).\n",
    "Dependency direction: this module imports the persistence, accounting,\n"
    "attempt, and process leaves directly. It never imports supervisor.py.\n",
)
recovery_path.write_text(recovery, encoding="utf-8")


# ---------------------------------------------------------------------------
# Convert supervisor.py into composition + compatibility delegates.
# ---------------------------------------------------------------------------
import_anchor = "from . import supervisor_claims as _claims_mod\n"
extra_imports = (
    "from . import supervisor_claims as _claims_mod\n"
    "from . import supervisor_process as _process_mod\n"
    "from . import supervisor_runtime as _runtime_mod\n"
    "from . import supervisor_prompts as _prompts_mod\n"
    "from . import supervisor_runner_registry as _runner_registry_mod\n"
    "from . import supervisor_runner as _runner_mod\n"
)
source_with_imports = source.replace(import_anchor, extra_imports, 1)
# Reparse after import insertion only changes lines before all definitions, so use the original
# node bounds for replacements against original source, then insert imports again afterwards.

replacements = {
    "_register_local_execution": "def _register_local_execution(job_id: int) -> None:\n    _process_mod._register_local_execution(job_id)",
    "_local_execution_owned": "def _local_execution_owned(job_id: int) -> bool:\n    return _process_mod._local_execution_owned(job_id)",
    "_clear_local_executions_for_thread": "def _clear_local_executions_for_thread() -> None:\n    _process_mod._clear_local_executions_for_thread()",
    "_load_service_env_file": "def _load_service_env_file() -> list[str]:\n    return _runtime_mod._load_service_env_file()",
    "WorkerLaunchError": "WorkerLaunchError = _runner_mod.WorkerLaunchError",
    "_claude_cli_version": "def _claude_cli_version(executable: str):\n    return _runner_mod._claude_cli_version(executable)",
    "_validate_claude_extra_args": "def _validate_claude_extra_args(extra: list[str]) -> None:\n    _runner_mod._validate_claude_extra_args(extra)",
    "_parse_adapter_auth_read_paths": "def _parse_adapter_auth_read_paths() -> list[str]:\n    return _runner_mod._parse_adapter_auth_read_paths()",
    "_semantic_worker_settings": "def _semantic_worker_settings(**kwargs):\n    return _runner_mod._semantic_worker_settings(**kwargs)",
    "runtime_generation": "def runtime_generation() -> str:\n    return _runtime_mod.runtime_generation()",
    "default_worker_log_dir": "def default_worker_log_dir() -> Path:\n    return _runner_io_mod.default_worker_log_dir()",
    "_runtime_cache_run_root": "def _runtime_cache_run_root(canonical_repo: Path, run_id: str) -> Path:\n    return _runtime_mod._runtime_cache_run_root(canonical_repo, run_id)",
    "_cleanup_terminal_runtime_cache": "def _cleanup_terminal_runtime_cache(canonical_repo: Path, run_id: str) -> dict[str, Any]:\n    return _runtime_mod._cleanup_terminal_runtime_cache(canonical_repo, run_id)",
    "_cleanup_done_runtime_caches": "def _cleanup_done_runtime_caches(db_path: Path | None = None) -> list[dict[str, Any]]:\n    return _runtime_mod._cleanup_done_runtime_caches(db_path)",
    "_slug_repo": "def _slug_repo(canonical_repo: Path) -> str:\n    return _runner_io_mod._slug_repo(canonical_repo)",
    "worker_log_paths": "def worker_log_paths(canonical_repo: Path, run_id: str, job_id: int, role: str, attempt_id: str | None = None) -> tuple[Path, Path]:\n    return _runner_io_mod.worker_log_paths(canonical_repo, run_id, job_id, role, attempt_id)",
    "_pid_alive": "def _pid_alive(pid: int | None, worker_started_at: float | None = None) -> bool:\n    return _process_mod._pid_alive(pid, worker_started_at)",
    "_read_pid_start_identity": "def _read_pid_start_identity(pid: int) -> str:\n    return _process_mod._read_pid_start_identity(pid)",
    "_pid_identity_proven": "def _pid_identity_proven(pid: int, expected_identity: str | None) -> bool:\n    return _process_mod._pid_identity_proven(pid, expected_identity)",
    "_terminate_owned_process_group": "def _terminate_owned_process_group(pid: int, pgid: int | None, expected_identity: str | None, worker_started_at: float | None) -> bool:\n    return _process_mod._terminate_owned_process_group(pid, pgid, expected_identity, worker_started_at)",
    "_read_pid_start_time": "def _read_pid_start_time(pid: int) -> float | None:\n    return _process_mod._read_pid_start_time(pid)",
    "_boot_time_unix": "def _boot_time_unix() -> float:\n    return _process_mod._boot_time_unix()",
    "_source_root": "def _source_root() -> Path:\n    return _prompts_mod._source_root()",
    "_load_role_prompt": "def _load_role_prompt(role: str) -> str:\n    return _prompts_mod._load_role_prompt(role)",
    "_write_semantic_prompt_provenance": "def _write_semantic_prompt_provenance(**kwargs):\n    return _prompts_mod._write_semantic_prompt_provenance(**kwargs)",
    "_terminate_group": "def _terminate_group(proc: subprocess.Popen[str], grace_seconds: float = 3.0) -> None:\n    _runner_mod._terminate_group(proc, grace_seconds)",
    "ClaudeCodeRunner": "ClaudeCodeRunner = _runner_mod.ClaudeCodeRunner",
    "_RegisteredClaudeCodeRunner": "_RegisteredClaudeCodeRunner = _runner_mod._RegisteredClaudeCodeRunner",
    "_classify_runner_failure": "def _classify_runner_failure(result: RunnerResult) -> tuple[str, str]:\n    return _runner_mod._classify_runner_failure(result)",
    "_classify_exception": "def _classify_exception(exc: BaseException) -> tuple[str, str, str]:\n    return _runner_mod._classify_exception(exc)",
    "_apply_failure_policy": "def _apply_failure_policy(conn, row, *, failure_class: str, failure_reason: str, detail: str = '') -> None:\n    _recovery_mod._apply_failure_policy(conn, row, failure_class=failure_class, failure_reason=failure_reason, detail=detail)",
}
assignment_replacements = {
    "_LOCAL_EXECUTION_LOCK": "_LOCAL_EXECUTION_LOCK = _process_mod._LOCAL_EXECUTION_LOCK",
    "_LOCAL_EXECUTION_JOBS": "_LOCAL_EXECUTION_JOBS = _process_mod._LOCAL_EXECUTION_JOBS",
    "_LOCAL_CONNECTION_DEPTH_SUPERVISOR": "_LOCAL_CONNECTION_DEPTH_SUPERVISOR = _process_mod._LOCAL_CONNECTION_DEPTH_SUPERVISOR",
    "_SERVICE_ENV_FILE_VAR": "_SERVICE_ENV_FILE_VAR = _runtime_mod._SERVICE_ENV_FILE_VAR",
    "_SERVICE_ENV_ALLOWED_KEYS": "_SERVICE_ENV_ALLOWED_KEYS = _runtime_mod._SERVICE_ENV_ALLOWED_KEYS",
}
new_supervisor = replace_nodes(replacements, assignment_replacements)
new_supervisor = new_supervisor.replace(import_anchor, extra_imports, 1)
# Remove the duplicate late registry import after the runner block was moved.
new_supervisor = new_supervisor.replace(
    "from . import supervisor_runner_registry as _runner_registry_mod  # noqa: E402\n",
    "",
)
SUP.write_text(new_supervisor, encoding="utf-8")


# ---------------------------------------------------------------------------
# Final dependency-direction regression: zero upward imports, no lazy allowlist.
# ---------------------------------------------------------------------------
dep_test = ROOT / "tests" / "integration" / "test_v10c_supervisor_dependency_direction.sh"
dep_test.write_text(r'''#!/usr/bin/env bash
# v0.10.0-dev c: final supervisor dependency-direction regression.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
cd "$ROOT_DIR"

PYTHONPATH="$ROOT_DIR/lib" python3 -B <<'PY'
import ast
from pathlib import Path

LIB = Path("lib/ownframework_loop")
supervisor_path = LIB / "supervisor.py"
supervisor_src = supervisor_path.read_text(encoding="utf-8")
supervisor_tree = ast.parse(supervisor_src)
modules = sorted(p.stem for p in LIB.glob("supervisor_*.py"))
print(f"  modules discovered: {modules}")


def upward_imports(path: Path):
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    hits = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name in {"supervisor", "ownframework_loop.supervisor"} or alias.name.endswith(".supervisor"):
                    hits.append((node.lineno, f"import {alias.name}"))
        elif isinstance(node, ast.ImportFrom):
            module = node.module or ""
            names = [a.name for a in node.names]
            if module == "supervisor" or module.endswith(".supervisor"):
                hits.append((node.lineno, f"from {module} import {','.join(names)}"))
            if node.level and module == "" and "supervisor" in names:
                hits.append((node.lineno, "from . import supervisor"))
    return hits

for module in modules:
    hits = upward_imports(LIB / f"{module}.py")
    assert not hits, f"{module}: forbidden upward import(s): {hits}"
print("  PASS: every canonical supervisor_* module has zero imports of supervisor.py")

required_imports = {
    "supervisor_db",
    "supervisor_holds",
    "supervisor_operator",
    "supervisor_runner_io",
    "supervisor_runner_registry",
    "supervisor_accounting",
    "supervisor_readmodel",
    "supervisor_identity",
    "supervisor_recovery",
    "supervisor_attempts",
    "supervisor_claims",
    "supervisor_process",
    "supervisor_runtime",
    "supervisor_prompts",
    "supervisor_runner",
}
for module in required_imports:
    assert f"{module} as _" in supervisor_src or f"import {module}" in supervisor_src, (
        f"supervisor.py does not compose {module}"
    )
print("  PASS: supervisor.py composes every named authority")

# Canonical implementation symbols may remain in supervisor.py only as thin
# compatibility delegates. A delegate may contain an optional docstring plus
# a single return/call/assignment expression; control-flow or multiple semantic
# statements is a duplicate implementation.
canonical = {
    "_register_local_execution", "_local_execution_owned", "_clear_local_executions_for_thread",
    "_load_service_env_file", "_claude_cli_version", "_validate_claude_extra_args",
    "_parse_adapter_auth_read_paths", "_semantic_worker_settings", "runtime_generation",
    "default_worker_log_dir", "_runtime_cache_run_root", "_cleanup_terminal_runtime_cache",
    "_cleanup_done_runtime_caches", "_slug_repo", "worker_log_paths", "_pid_alive",
    "_read_pid_start_identity", "_pid_identity_proven", "_terminate_owned_process_group",
    "_read_pid_start_time", "_boot_time_unix", "_source_root", "_load_role_prompt",
    "_write_semantic_prompt_provenance", "_terminate_group", "_classify_runner_failure",
    "_classify_exception", "_apply_failure_policy",
}
for node in supervisor_tree.body:
    if isinstance(node, ast.ClassDef) and node.name in {"WorkerLaunchError", "ClaudeCodeRunner", "_RegisteredClaudeCodeRunner"}:
        raise AssertionError(f"supervisor.py duplicates canonical class {node.name}")
    if isinstance(node, ast.FunctionDef) and node.name in canonical:
        body = node.body[:]
        if body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant) and isinstance(body[0].value.value, str):
            body = body[1:]
        assert len(body) == 1 and isinstance(body[0], (ast.Return, ast.Expr)), (
            f"supervisor.py compatibility surface {node.name} is not a thin delegate"
        )
print("  PASS: no duplicate canonical implementations remain in supervisor.py")
PY

echo "V10C_SUPERVISOR_DEPENDENCY_DIRECTION=PASS"
''', encoding="utf-8")


# ---------------------------------------------------------------------------
# static_checks.py: provider subprocess creation belongs in supervisor_runner.py.
# ---------------------------------------------------------------------------
static_path = LIB / "static_checks.py"
static = static_path.read_text(encoding="utf-8")
static = static.replace(
    '"process_runner.py", "supervisor.py", "validation_executor.py"',
    '"process_runner.py", "supervisor_runner.py", "validation_executor.py"',
)
static_path.write_text(static, encoding="utf-8")


# Compile before returning control to the workflow; this catches extraction/import
# defects early and keeps the transformation fail-closed.
import compileall
if not compileall.compile_dir(str(LIB), quiet=1, force=True):
    raise SystemExit("compileall failed after supervisor refactor")

print("SUPERVISOR_REFACTOR_ONCE=APPLIED")
