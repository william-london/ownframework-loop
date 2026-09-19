from __future__ import annotations

import ast
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "lib" / "ownframework_loop"


def function_nodes(text: str, name: str) -> list[ast.FunctionDef]:
    tree = ast.parse(text)
    return [
        node for node in tree.body
        if isinstance(node, ast.FunctionDef) and node.name == name
    ]


def node_segment(text: str, node: ast.AST) -> str:
    lines = text.splitlines(keepends=True)
    start = getattr(node, "lineno")
    decorators = getattr(node, "decorator_list", [])
    if decorators:
        start = min([start, *(d.lineno for d in decorators)])
    end = getattr(node, "end_lineno")
    return "".join(lines[start - 1:end]).rstrip() + "\n"


def replace_node_ranges(text: str, replacements: list[tuple[ast.AST, str]]) -> str:
    lines = text.splitlines(keepends=True)
    ranged: list[tuple[int, int, str]] = []
    for node, replacement in replacements:
        start = getattr(node, "lineno")
        decorators = getattr(node, "decorator_list", [])
        if decorators:
            start = min([start, *(d.lineno for d in decorators)])
        end = getattr(node, "end_lineno")
        ranged.append((start, end, replacement.rstrip() + ("\n" if replacement else "")))
    for start, end, replacement in sorted(ranged, reverse=True):
        lines[start - 1:end] = [replacement] if replacement else []
    return "".join(lines)


# The extraction source owns this cache as module state immediately before
# _boot_time_unix; AST function extraction intentionally does not copy adjacent
# assignments, so restore that process-authority state explicitly.
process_path = LIB / "supervisor_process.py"
process = process_path.read_text(encoding="utf-8")
needle = "_LOCAL_CONNECTION_DEPTH_SUPERVISOR: dict[int, int] = {}\n"
if "_BOOT_TIME_CACHE: float | None = None" not in process:
    process = process.replace(
        needle,
        needle + "_BOOT_TIME_CACHE: float | None = None\n",
        1,
    )
process_path.write_text(process, encoding="utf-8")

# supervisor_accounting intentionally exposes descriptive canonical names
# (without the historical supervisor-private underscore). Bind extracted
# consumers to that API rather than recreating compatibility aliases below it.
recovery_path = LIB / "supervisor_recovery.py"
recovery = recovery_path.read_text(encoding="utf-8")
for old, new in {
    "_accounting_mod._parse_cost_from_durable_stdout": "_accounting_mod.parse_cost_from_durable_stdout",
    "_accounting_mod._parse_token_usage_from_durable_stdout": "_accounting_mod.parse_token_usage_from_durable_stdout",
    "_accounting_mod._extract_effective_model_from_durable_stdout": "_accounting_mod.extract_effective_model_from_durable_stdout",
    "_accounting_mod._extract_model_usage_json_from_durable_stdout": "_accounting_mod.extract_model_usage_json_from_durable_stdout",
}.items():
    recovery = recovery.replace(old, new)
recovery_path.write_text(recovery, encoding="utf-8")

runner_path = LIB / "supervisor_runner.py"
runner = runner_path.read_text(encoding="utf-8")
runner = runner.replace("_accounting_mod._extract_effective_model(", "_accounting_mod.extract_effective_model(")
runner = runner.replace("_accounting_mod._extract_model_usage_json(", "_accounting_mod.extract_model_usage_json(")
runner_path.write_text(runner, encoding="utf-8")

# Grade-B defect found during the refactor audit: supervisor.py currently has
# TWO definitions named _extract_model_usage_json. The later implementation
# wins at runtime, so the older accounting delegate did not actually own the
# canonical behavior. Preserve the effective compact/canonical JSON semantics
# in supervisor_accounting, then leave exactly one thin compatibility delegate
# in supervisor.py.
accounting_path = LIB / "supervisor_accounting.py"
accounting = accounting_path.read_text(encoding="utf-8")
acc_nodes = function_nodes(accounting, "extract_model_usage_json")
if len(acc_nodes) != 1:
    raise RuntimeError(f"expected one accounting extract_model_usage_json, found {len(acc_nodes)}")
canonical_model_usage = '''def extract_model_usage_json(payload: dict[str, Any] | None) -> str:
    """Return compact canonical JSON of the full provider-reported modelUsage.

    This preserves the behavior of the historically effective supervisor
    implementation: multi-model usage is retained intact and malformed values
    fail closed to an empty string.
    """
    if not isinstance(payload, dict):
        return ""
    usage = payload.get("modelUsage")
    if not isinstance(usage, dict) or not usage:
        return ""
    try:
        return json.dumps(
            usage, sort_keys=True, separators=(",", ":"), ensure_ascii=True
        )
    except (TypeError, ValueError):
        return ""
'''
accounting = replace_node_ranges(accounting, [(acc_nodes[0], canonical_model_usage)])
accounting_path.write_text(accounting, encoding="utf-8")

# Preserve exact historical compatibility signatures on the composition facade.
supervisor_path = LIB / "supervisor.py"
supervisor = supervisor_path.read_text(encoding="utf-8")
supervisor = supervisor.replace(
    "def _read_pid_start_identity(pid: int) -> str:\n    return _process_mod._read_pid_start_identity(pid)",
    "def _read_pid_start_identity(pid: int) -> str | None:\n    return _process_mod._read_pid_start_identity(pid)",
)
supervisor = supervisor.replace(
    "def _pid_identity_proven(pid: int, expected_identity: str | None) -> bool:\n    return _process_mod._pid_identity_proven(pid, expected_identity)",
    "def _pid_identity_proven(pid: int | None, expected_identity: str | None) -> bool:\n    return _process_mod._pid_identity_proven(pid, expected_identity)",
)
supervisor = supervisor.replace(
    "def _boot_time_unix() -> float:\n    return _process_mod._boot_time_unix()",
    "def _boot_time_unix() -> float | None:\n    return _process_mod._boot_time_unix()",
)
wrong_policy = "def _apply_failure_policy(conn, row, *, failure_class: str, failure_reason: str, detail: str = '') -> None:\n    _recovery_mod._apply_failure_policy(conn, row, failure_class=failure_class, failure_reason=failure_reason, detail=detail)"
right_policy = '''def _apply_failure_policy(
    conn: sqlite3.Connection,
    *,
    job_id: int,
    failure_class: str,
    failure_reason: str,
    detail: str,
    total_cost_usd: float | None = None,
) -> dict[str, Any]:
    return _recovery_mod._apply_failure_policy(
        conn,
        job_id=job_id,
        failure_class=failure_class,
        failure_reason=failure_reason,
        detail=detail,
        total_cost_usd=total_cost_usd,
    )'''
if wrong_policy not in supervisor:
    raise RuntimeError("expected generated failure-policy compatibility wrapper not found")
supervisor = supervisor.replace(wrong_policy, right_policy, 1)

# The later duplicate model-usage body is the historical winner. Accounting now
# owns those exact semantics, so delete every duplicate after the first facade
# delegate rather than leaving shadow definitions behind.
model_nodes = function_nodes(supervisor, "_extract_model_usage_json")
if len(model_nodes) < 1:
    raise RuntimeError("supervisor model-usage compatibility surface disappeared")
if len(model_nodes) > 1:
    supervisor = replace_node_ranges(
        supervisor,
        [(node, "") for node in model_nodes[1:]],
    )

# Two more attempt-lifecycle bodies were left in the facade by the previous
# Stage-2 pass. They mutate/query semantic_attempts and therefore belong with
# supervisor_attempts, not composition.
sup_tree = ast.parse(supervisor)
pre_provider_node = next(
    node for node in sup_tree.body
    if isinstance(node, ast.Assign)
    and any(isinstance(t, ast.Name) and t.id == "PRE_PROVIDER_FAILURE_REASONS" for t in node.targets)
)
cap_node = next(
    node for node in sup_tree.body
    if isinstance(node, ast.FunctionDef) and node.name == "_capability_binding_creation_allowed"
)
launch_node = next(
    node for node in sup_tree.body
    if isinstance(node, ast.FunctionDef) and node.name == "_mark_attempt_launch_failed"
)
attempts_path = LIB / "supervisor_attempts.py"
attempts = attempts_path.read_text(encoding="utf-8").rstrip() + "\n\n"
if "def _capability_binding_creation_allowed(" in attempts or "def _mark_attempt_launch_failed(" in attempts:
    raise RuntimeError("attempt lifecycle fixup would duplicate an existing attempts owner body")
attempts += node_segment(supervisor, pre_provider_node) + "\n"
attempts += node_segment(supervisor, cap_node) + "\n"
attempts += node_segment(supervisor, launch_node) + "\n"
attempts_path.write_text(attempts, encoding="utf-8")

cap_wrapper = '''def _capability_binding_creation_allowed(
    conn: sqlite3.Connection,
    job_id: int,
) -> bool:
    return _attempts_mod._capability_binding_creation_allowed(conn, job_id)
'''
launch_wrapper = '''def _mark_attempt_launch_failed(
    conn: sqlite3.Connection,
    *,
    job_id: int,
    attempt_id: str,
    detail: str,
    failure_reason: str = "worker_launch_failed",
) -> None:
    _attempts_mod._mark_attempt_launch_failed(
        conn,
        job_id=job_id,
        attempt_id=attempt_id,
        detail=detail,
        failure_reason=failure_reason,
    )
'''
# Reparse because deleting the duplicate model function changed line positions.
sup_tree = ast.parse(supervisor)
pre_provider_node = next(
    node for node in sup_tree.body
    if isinstance(node, ast.Assign)
    and any(isinstance(t, ast.Name) and t.id == "PRE_PROVIDER_FAILURE_REASONS" for t in node.targets)
)
cap_node = next(
    node for node in sup_tree.body
    if isinstance(node, ast.FunctionDef) and node.name == "_capability_binding_creation_allowed"
)
launch_node = next(
    node for node in sup_tree.body
    if isinstance(node, ast.FunctionDef) and node.name == "_mark_attempt_launch_failed"
)
supervisor = replace_node_ranges(
    supervisor,
    [
        (pre_provider_node, "PRE_PROVIDER_FAILURE_REASONS = _attempts_mod.PRE_PROVIDER_FAILURE_REASONS\n"),
        (cap_node, cap_wrapper),
        (launch_node, launch_wrapper),
    ],
)
supervisor_path.write_text(supervisor, encoding="utf-8")

# Strengthen the architecture regression itself: old compatibility delegates
# may contain one local import before their one call/return, but duplicate
# top-level definitions are forbidden and the newly relocated accounting /
# attempt surfaces are now part of the canonical-body set.
dep_path = ROOT / "tests" / "integration" / "test_v10c_supervisor_dependency_direction.sh"
dep = dep_path.read_text(encoding="utf-8")
dep = dep.replace(
    '    "_classify_exception", "_apply_failure_policy",\n}',
    '    "_classify_exception", "_apply_failure_policy",\n'
    '    "_parse_cost_from_durable_stdout", "_parse_token_usage_from_durable_stdout",\n'
    '    "_durable_envelope_payload", "_extract_effective_model_from_durable_stdout",\n'
    '    "_extract_model_usage_json_from_durable_stdout", "_extract_effective_model",\n'
    '    "_extract_model_usage_json", "_strict_profile_model_violation",\n'
    '    "_capability_binding_creation_allowed", "_mark_attempt_launch_failed",\n'
    '}',
)
old_loop = '''for node in supervisor_tree.body:
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
'''
new_loop = '''defs = {}
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
'''
if old_loop not in dep:
    raise RuntimeError("dependency regression body drifted before fixup")
dep = dep.replace(old_loop, new_loop, 1)
dep_path.write_text(dep, encoding="utf-8")

# Static distribution parity must inspect the canonical runtime owner after the
# move. Keeping this regex pointed at supervisor.py would make the test itself
# enforce the old monolith architecture.
dist_path = ROOT / "tests" / "integration" / "test_v085_distribution_parity.sh"
dist = dist_path.read_text(encoding="utf-8")
dist = dist.replace("def from_supervisor_py():", "def from_runtime_owner():")
dist = dist.replace(
    'text = (root / "lib/ownframework_loop/supervisor.py").read_text()',
    'text = (root / "lib/ownframework_loop/supervisor_runtime.py").read_text()',
)
dist = dist.replace("sur = from_supervisor_py()", "sur = from_runtime_owner()")
dist = dist.replace("supervisor.py={sur}", "supervisor_runtime.py={sur}")
dist_path.write_text(dist, encoding="utf-8")

# ClaudeCodeRunner now canonically owns subprocess.Popen in supervisor_runner.
# Keep the unsafe-process static check narrow: add only that explicit owner to
# the existing execution allowlist; do not weaken or disable the detector.
static_path = LIB / "static_checks.py"
static = static_path.read_text(encoding="utf-8")
if '"supervisor_runner.py"' not in static:
    static_allow_anchor = '"supervisor.py", "validation_executor.py"'
    if static.count(static_allow_anchor) != 1:
        raise RuntimeError("static Popen allowlist drifted before runner extraction")
    static = static.replace(
        static_allow_anchor,
        '"supervisor.py", "supervisor_runner.py", "validation_executor.py"',
        1,
    )
static_path.write_text(static, encoding="utf-8")

# Replace the stale/contradictory Stage-2 roadmap with the architecture that
# this gated transformation actually publishes.  Historical Stage-A material
# above the marker remains intact; only the now-obsolete BLOCKED/partial tail is
# rewritten.
doc_path = ROOT / "docs" / "architecture" / "IMPLEMENTATION_CONSOLIDATION.md"
doc = doc_path.read_text(encoding="utf-8")
marker = "## Stage 2 Inversion (post-Stage-A)\n"
if doc.count(marker) != 1:
    raise RuntimeError("implementation-consolidation Stage-2 marker drifted")
head = doc.split(marker, 1)[0]
final_stage = '''## Stage 2 Finalization (current architecture)

The supervisor decomposition is complete at the named-owner boundary.  The
composition facade remains intentionally broad because it owns orchestration,
not because leaf authorities still depend upward on it.

### Canonical body owners

| Module | Canonical authority |
|---|---|
| `supervisor_db.py` | connection, schema, file-mode, lookup, validator, transition primitive |
| `supervisor_holds.py` | dispatch-hold validation, persistence, matching, release/cancel, projection |
| `supervisor_readmodel.py` | status/fleet/config read models and job/core visibility projection |
| `supervisor_operator.py` | operator configuration mutation |
| `supervisor_identity.py` | repository/workspace scheduling identity and packet execution mode |
| `supervisor_accounting.py` | durable cost/token/model observation |
| `supervisor_attempts.py` | semantic-attempt reservation, provenance, acceptance, completion, launch-failure lifecycle |
| `supervisor_recovery.py` | stale-RUNNING recovery and durable failure/retry/quarantine policy |
| `supervisor_claims.py` | enrollment, atomic claim, scheduler submission budget |
| `supervisor_process.py` | local execution fence, PID/start identity, liveness, owned process-group termination |
| `supervisor_runtime.py` | commissioned service environment, runtime generation, runtime-cache lifecycle |
| `supervisor_prompts.py` | role prompt construction and immutable prompt provenance |
| `supervisor_runner_io.py` | provider envelope/diagnostic readers and durable worker-log paths |
| `supervisor_runner_registry.py` | generic runner result/readiness contract and registry |
| `supervisor_runner.py` | Claude-specific provider execution, subprocess lifecycle, configuration and failure observation |

`supervisor.py` composes these authorities and keeps compatibility delegates
for established imports.  Cross-domain orchestration stays there: `run_one`,
`serve`, `resume`, `retire`, PROGRAM continuation/protected recovery,
startup-ready attestation, and `_apply_data_migrations` as the explicit
persistence/identity migration callback.

### Dependency direction

`tests/integration/test_v10c_supervisor_dependency_direction.sh` rejects any
module- or function-scope import of `supervisor.py` from a canonical
`supervisor_*` owner.  There is no lazy-import exception list.  The facade may
import downward; canonical owners may depend on lower/cohesive owners, but not
back upward into the composition module.

Compatibility tests patch the canonical owner consumed by the code under test.
Production modules no longer import upward merely to preserve historical test
monkey-patch behavior.

### Runner extraction

The previously blocked runner prerequisites are now explicit owners:
`supervisor_process`, `supervisor_prompts`, and `supervisor_runtime`.
`ClaudeCodeRunner` and `_RegisteredClaudeCodeRunner` live in
`supervisor_runner.py`; provider-output paths live in `supervisor_runner_io`;
retry/quarantine policy remains in `supervisor_recovery`.  `static_checks.py`
permits `subprocess.Popen` in the explicit runner owner without weakening the
unsafe-process detector elsewhere.

### Consolidation invariants

- zero canonical `supervisor_* -> supervisor.py` imports, including lazy imports;
- zero duplicate canonical implementations or shadow top-level definitions in
  `supervisor.py`;
- runner/provider execution separated from durable recovery policy;
- tests target canonical owners rather than forcing production dependency
  inversions for monkey-patch compatibility;
- `supervisor.py` is reduced from the original 6817-line monolith to a
  composition/compatibility surface of roughly 3000 lines, with authority
  bodies moved to named owners;
- the one-shot transformation is published only after canonical validation and
  the release gate succeed on the committed candidate.
'''
doc_path.write_text(head + final_stage, encoding="utf-8")

print("SUPERVISOR_REFACTOR_FIXUPS=APPLIED")
