#!/usr/bin/env bash
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
    "_parse_cost_from_durable_stdout", "_parse_token_usage_from_durable_stdout",
    "_durable_envelope_payload", "_extract_effective_model_from_durable_stdout",
    "_extract_model_usage_json_from_durable_stdout", "_extract_effective_model",
    "_extract_model_usage_json", "_strict_profile_model_violation",
    "_capability_binding_creation_allowed", "_mark_attempt_launch_failed",
}
defs = {}
for node in supervisor_tree.body:
    if isinstance(node, ast.ClassDef) and node.name in {"WorkerLaunchError", "ClaudeCodeRunner", "_RegisteredClaudeCodeRunner"}:
        raise AssertionError(f"supervisor.py duplicates canonical class {node.name}")
    if isinstance(node, ast.FunctionDef) and node.name in canonical:
        defs.setdefault(node.name, []).append(node)
        body = node.body[:]
        if body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant) and isinstance(body[0].value.value, str):
            body = body[1:]
        body = [stmt for stmt in body if isinstance(stmt, (ast.Import, ast.ImportFrom)) is False]
        assert len(body) == 1 and isinstance(body[0], (ast.Return, ast.Expr)), (
            f"supervisor.py compatibility surface {node.name} is not a thin delegate"
        )
for name, nodes in defs.items():
    assert len(nodes) == 1, f"supervisor.py defines canonical compatibility symbol {name} {len(nodes)} times"
print("  PASS: no duplicate canonical implementations or shadow definitions remain in supervisor.py")
PY

echo "V10C_SUPERVISOR_DEPENDENCY_DIRECTION=PASS"
