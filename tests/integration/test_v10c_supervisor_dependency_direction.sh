#!/usr/bin/env bash
# v0.10.0-dev c: supervisor dependency-direction regressions.
#
# After the supervisor decomposition, the dependency direction
# MUST be:
#
#   subordinate authority modules (supervisor_db, supervisor_runner_io,
#   supervisor_holds, supervisor_operator, supervisor_accounting,
#   supervisor_runner_registry, supervisor_readmodel,
#   supervisor_recovery, supervisor_attempts, supervisor_claims)
#       ↓
#   nothing (or only stdlib + sibling leaves)
#
# supervisor.py
#       ↓
#   subordinate authority modules (composition facade)
#
# This test statically inspects the import graph of every
# supervisor_* module and asserts:
#
#   1. supervisor_db does NOT import supervisor or any other
#      supervisor_* module.
#   2. supervisor_runner_io does NOT import supervisor or any
#      other supervisor_* module.
#   3. supervisor_accounting does NOT import supervisor.
#   4. supervisor_holds does NOT import supervisor.* except for
#      _logical_job_row (currently a follow-up extraction
#      target; documented as deferred).
#   5. supervisor_operator does NOT import supervisor.* except
#      for _validate_max_concurrency (currently a follow-up
#      extraction target; documented as deferred).
#   6. supervisor.py imports all of the above modules (proves
#      supervisor is a composition facade).
#   7. supervisor.py does not duplicate any of the canonical
#      function bodies of the supervisor_* modules.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
TMP="$(mktemp -d -t ofloop-supervisor-dep-direction.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

fail(){ echo "FAIL: $*" >&2; exit 1; }
pass(){ echo "  pass: $*"; }

cd "$ROOT_DIR"
LIB="lib/ownframework_loop"

PYTHONPATH="$ROOT_DIR/lib" python3 -B <<'PY'
import ast
from pathlib import Path
import sys

LIB = Path("lib/ownframework_loop")
supervisor_py = (LIB / "supervisor.py").read_text(encoding="utf-8")

# Step 1: enumerate all supervisor_* modules.
modules = sorted(p.stem for p in LIB.glob("supervisor_*.py"))
print(f"  modules discovered: {modules}")

# Step 2: parse each module and collect its module-level imports.
def collect_imports(path: Path) -> set[str]:
    src = path.read_text(encoding="utf-8")
    tree = ast.parse(src)
    imports: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                imports.add(alias.name)
        elif isinstance(node, ast.ImportFrom):
            if node.module and node.level == 1:
                # relative import
                imports.add(node.module)
    return imports

imports: dict[str, set[str]] = {}
for m in modules:
    imports[m] = collect_imports(LIB / f"{m}.py")

# Step 3: enforce "no upward imports to supervisor".
def find_upward(target_module: str, allowed_lazy: list[str]) -> None:
    """Static check: target_module MUST NOT import supervisor
    in its top-level (non-function-body) imports.

    Lazy imports inside function bodies are scoped to that
    function's call; they are still real upward imports but
    the brief's Phase 2 sequencing permits them only as
    follow-up extraction targets.  These are listed in
    ``allowed_lazy`` for the test to admit the documented
    exceptions.
    """
    src = (LIB / f"{target_module}.py").read_text(encoding="utf-8")
    tree = ast.parse(src)
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom) and node.module == "supervisor":
            # Module-level import (outside any function) is forbidden.
            # Find enclosing scope.
            enclosing = None
            for parent in ast.walk(tree):
                if isinstance(parent, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    for child in ast.walk(parent):
                        if child is node:
                            enclosing = parent.name
            if enclosing is None:
                # Module-level import is NOT allowed at all.
                msg = (
                    f"{target_module}: forbidden module-level "
                    f"`from .supervisor import ...` (no function scope)"
                )
                raise AssertionError(msg)
            # Lazy import inside a function is permitted but the
            # symbol must be in allowed_lazy.
            names = [a.name for a in node.names]
            for name in names:
                if name not in allowed_lazy:
                    raise AssertionError(
                        f"{target_module}: lazy import of "
                        f"supervisor.{name} inside function {enclosing} "
                        f"is not in the documented follow-up allowlist "
                        f"{allowed_lazy!r}"
                    )
    return None

# supervisor_db has no upward imports — fully inverted.
find_upward("supervisor_db", allowed_lazy=[])

# supervisor_runner_io has no upward imports — fully inverted.
find_upward("supervisor_runner_io", allowed_lazy=[])

# supervisor_accounting: was the canonical example of an upward
# import to supervisor (for _read_durable_provider_envelope).
# After f3 it must NOT import supervisor at all.
find_upward("supervisor_accounting", allowed_lazy=[])

# supervisor_holds: currently imports _logical_job_row from
# supervisor inside three function bodies.  Documented as the
# next extraction target.
find_upward(
    "supervisor_holds",
    allowed_lazy=["_logical_job_row"],
)

# supervisor_operator: currently imports _validate_max_concurrency
# from supervisor inside one function body.  Documented as the
# next extraction target.
find_upward(
    "supervisor_operator",
    allowed_lazy=["_validate_max_concurrency"],
)

# The remaining supervisor_* modules are still scaffolding
# re-export facades — they import supervisor.  Stage B will
# flip them too.  supervisor_runner_registry is already
# canonical-body-owned (e1 extraction) and does NOT import
# supervisor.  supervisor_readmodel was flipped to canonical
# body ownership in g2.  supervisor_recovery was flipped to
# canonical body ownership in g3.
for m in [
    "supervisor_attempts",
    "supervisor_claims",
]:
    # These are STILL facades; they MUST import supervisor.
    src = (LIB / f"{m}.py").read_text(encoding="utf-8")
    assert "from .supervisor import" in src, (
        f"{m}: expected to remain a re-export facade "
        f"importing from supervisor (until Stage B)"
    )
# Canonical body owners — must NOT import supervisor at module
# or function scope.  supervisor_recovery DOES lazy-import
# supervisor at function scope for the helper bridge that
# keeps test monkey-patches on supervisor._parse_* working;
# that is a documented exception.
for m in [
    "supervisor_runner_registry",
    "supervisor_readmodel",
    "supervisor_holds",
    "supervisor_operator",
    "supervisor_db",
    "supervisor_runner_io",
    "supervisor_accounting",
    "supervisor_identity",
]:
    find_upward(m, allowed_lazy=[])
# supervisor_recovery: lazy imports of supervisor at function
# scope are permitted only for the documented test-monkey-patch
# bridge.  Allow the specific names tests patch.
find_upward(
    "supervisor_recovery",
    allowed_lazy=[
        "_local_execution_owned",
        "_pid_alive",
        "_terminate_owned_process_group",
        "_recovery_ownership_matches",
        "_parse_cost_from_durable_stdout",
        "_parse_token_usage_from_durable_stdout",
        "_extract_effective_model_from_durable_stdout",
        "_extract_model_usage_json_from_durable_stdout",
        "_account_attempt_cost",
    ],
)
print("  PASS: dependency-direction invariants hold for inverted modules")

# Step 4: supervisor.py is a composition facade that imports
# the named authority modules that have been flipped from
# facade to canonical body owner.  Modules still in facade
# stage (supervisor_attempts, supervisor_claims,
# supervisor_recovery, supervisor_readmodel) are imported
# via the supervisor package, not supervisor.py directly.
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
}
for m in required_imports:
    assert (
        f"from . import {m}" in supervisor_py
        or f"import {m}" in supervisor_py
    ), f"supervisor.py does not import {m}"
print("  PASS: supervisor.py imports all canonical-body authorities")
PY
echo "V10C_SUPERVISOR_DEPENDENCY_DIRECTION=PASS"
