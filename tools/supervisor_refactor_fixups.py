from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "lib" / "ownframework_loop"

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

# Preserve the exact historical compatibility signatures on the composition
# facade. The canonical bodies live below it; these wrappers are intentionally
# boring and signature-compatible.
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
supervisor_path.write_text(supervisor, encoding="utf-8")

print("SUPERVISOR_REFACTOR_FIXUPS=APPLIED")
