"""Durable, vendor-thin supervisor for OwnFramework Loop.

Protocol truth remains in the repository's OwnFramework Loop artifacts. SQLite
stores only machine operations: queue state, retries, backoff, runner identity,
and cost/runtime observations.

The supervisor consumes typed work orders from dispatch.py. It never decides
engineering transitions itself.
"""
from __future__ import annotations
import sys

import json
import os
import shlex
import signal
import sqlite3
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from . import dispatch as dispatch_mod, runtime_env

SCHEMA = "ownframework-loop-supervisor/v1"
ACTIVE = {"QUEUED", "BACKOFF", "RUNNING"}
TERMINAL = {"DONE", "QUARANTINED"}


def default_db_path() -> Path:
    root = os.environ.get("XDG_STATE_HOME", "").strip()
    base = Path(root).expanduser() if root else Path.home() / ".local" / "state"
    return base / "ownframework-loop" / "supervisor.sqlite3"


def default_worker_log_dir() -> Path:
    root = os.environ.get("XDG_STATE_HOME", "").strip()
    base = Path(root).expanduser() if root else Path.home() / ".local" / "state"
    return base / "ownframework-loop" / "worker-logs"


def _slug_repo(canonical_repo: Path) -> str:
    p = str(Path(canonical_repo).resolve(strict=False))
    import hashlib
    return hashlib.sha256(p.encode("utf-8")).hexdigest()[:16]


def worker_log_paths(
    canonical_repo: Path,
    run_id: str,
    job_id: int,
    role: str,
) -> tuple[Path, Path]:
    """Return durable (stdout, stderr) log paths for one worker attempt.

    The supervisor or any replacement supervisor can read these files even if
    the original parent process died while the child Claude process was still
    alive. Output paths survive both processes by design.
    """
    safe_role = "builder" if role not in ("builder", "reviewer") else role
    safe_run = "".join(ch for ch in str(run_id) if ch.isalnum() or ch in "-_.")[:64]
    d = default_worker_log_dir() / _slug_repo(canonical_repo) / safe_run
    d.mkdir(parents=True, exist_ok=True)
    return (
        d / f"job-{int(job_id)}-{safe_role}.out",
        d / f"job-{int(job_id)}-{safe_role}.err",
    )


def _connect(path: Path) -> sqlite3.Connection:
    path = Path(path).expanduser().resolve(strict=False)
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path, timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=FULL")
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS jobs (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          repo TEXT NOT NULL,
          run_id TEXT NOT NULL,
          runner TEXT NOT NULL DEFAULT 'claude-code',
          status TEXT NOT NULL DEFAULT 'QUEUED',
          infra_failures INTEGER NOT NULL DEFAULT 0,
          max_infra_failures INTEGER NOT NULL DEFAULT 3,
          total_cost_usd REAL NOT NULL DEFAULT 0,
          last_error TEXT,
          next_attempt_at REAL NOT NULL DEFAULT 0,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          worker_pid INTEGER,
          worker_started_at REAL,
          worker_role TEXT,
          max_total_cost_usd REAL NOT NULL DEFAULT 25,
          max_wall_seconds INTEGER NOT NULL DEFAULT 28800,
          execution_started_at REAL,
          worker_stdout_path TEXT,
          worker_stderr_path TEXT,
          UNIQUE(repo, run_id)
        );
        CREATE TABLE IF NOT EXISTS cost_attempts (
          job_id INTEGER NOT NULL,
          attempt_digest TEXT NOT NULL,
          cost_usd REAL NOT NULL,
          recorded_at REAL NOT NULL,
          PRIMARY KEY (job_id, attempt_digest)
        );
        """
    )
    columns = {
        str(row["name"])
        for row in conn.execute("PRAGMA table_info(jobs)").fetchall()
    }
    migrations = {
        "worker_pid": "ALTER TABLE jobs ADD COLUMN worker_pid INTEGER",
        "worker_started_at": "ALTER TABLE jobs ADD COLUMN worker_started_at REAL",
        "worker_role": "ALTER TABLE jobs ADD COLUMN worker_role TEXT",
        "max_total_cost_usd": "ALTER TABLE jobs ADD COLUMN max_total_cost_usd REAL NOT NULL DEFAULT 25",
        "max_wall_seconds": "ALTER TABLE jobs ADD COLUMN max_wall_seconds INTEGER NOT NULL DEFAULT 28800",
        "execution_started_at": "ALTER TABLE jobs ADD COLUMN execution_started_at REAL",
        "worker_stdout_path": "ALTER TABLE jobs ADD COLUMN worker_stdout_path TEXT",
        "worker_stderr_path": "ALTER TABLE jobs ADD COLUMN worker_stderr_path TEXT",
    }
    for name, statement in migrations.items():
        if name not in columns:
            conn.execute(statement)
    conn.commit()
    return conn


def _pid_alive(pid: int | None, worker_started_at: float | None = None) -> bool:
    """True iff `pid` is alive AND consistent with our recorded worker.

    Beyond the bare kill(pid, 0) probe, if `worker_started_at` is provided,
    we cross-check that the process start time is within ±10 minutes of the
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
        if abs(start_ts - worker_started_at) > 600:
            return False
    except Exception:
        return True
    return True


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
            # Field 22 (0-indexed 21) is start_time in clock ticks since boot
            if len(fields) < 22:
                return None
            ticks = int(fields[21])
            try:
                clk_tck = os.sysconf("SC_CLK_TCK")
            except Exception:
                clk_tck = 100
            boot = _boot_time_unix() or 0.0
            return boot + ticks / float(clk_tck)
        # macOS fallback
        r = subprocess.run(
            ["ps", "-o", "etime=", "-p", str(pid)],
            capture_output=True, text=True, check=False, timeout=2,
        )
        if r.returncode != 0 or not r.stdout.strip():
            return None
        etime = r.stdout.strip()
        # Parse [[dd-]hh:]mm:ss
        total = 0
        parts = etime.split(":")
        try:
            if len(parts) == 2:
                total = int(parts[0]) * 60 + int(parts[1])
            elif len(parts) == 3:
                d, h, m_s = parts
                if "-" in d:
                    dd, hh = d.split("-")
                    total = int(dd) * 86400 + int(hh) * 3600
                else:
                    total = int(d) * 3600
                mm, ss = m_s.split(":")
                total += int(mm) * 60 + int(ss)
        except Exception:
            return None
        return time.time() - total
    except Exception:
        return None


_BOOT_TIME_CACHE: float | None = None


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


def _recover_stale_running(conn: sqlite3.Connection) -> int:
    """Requeue only RUNNING jobs whose recorded worker process is gone.

    A live orphan is left RUNNING so another supervisor cannot duplicate it.
    When that process later exits, the next recovery pass requeues the same
    core claim. Dispatch replay + semantic_result_ready then either finalizes
    the completed artifact with zero model calls or resumes the same pass.
    """
    recovered = 0
    rows = conn.execute(
        "SELECT * FROM jobs WHERE status='RUNNING' ORDER BY id"
    ).fetchall()
    for row in rows:
        pid = row["worker_pid"]
        started_at = float(row["worker_started_at"]) if row["worker_started_at"] else None
        if _pid_alive(pid, started_at):
            continue
        conn.execute(
            """
            UPDATE jobs SET
              status='QUEUED',
              worker_pid=NULL,
              worker_started_at=NULL,
              worker_role=NULL,
              last_error=?,
              next_attempt_at=0,
              updated_at=?
            WHERE id=?
            """,
            ("recovered stale RUNNING job after supervisor/worker exit", time.time(), row["id"]),
        )
        recovered += 1
    if recovered:
        conn.commit()
    return recovered


def enqueue(
    *,
    canonical_repo: Path,
    run_id: str,
    runner: str = "claude-code",
    db_path: Path | None = None,
    max_infra_failures: int = 3,
    max_total_cost_usd: float = 25.0,
    max_wall_seconds: int = 28800,
) -> dict[str, Any]:
    repo = str(Path(canonical_repo).resolve(strict=False))
    db = db_path or default_db_path()
    now = time.time()
    # Idempotent enqueue: create a new QUEUED row, or update only safe
    # configuration on an existing row. Operational state, backoff and worker
    # ownership are never rewritten by a repeated enqueue.
    with _connect(db) as conn:
        conn.execute(
            """
            INSERT INTO jobs
              (repo, run_id, runner, status, infra_failures,
               max_infra_failures, total_cost_usd, next_attempt_at,
               max_total_cost_usd, max_wall_seconds, created_at, updated_at)
            VALUES (?, ?, ?, 'QUEUED', 0, ?, 0, 0, ?, ?, ?, ?)
            ON CONFLICT(repo, run_id) DO UPDATE SET
              runner=excluded.runner,
              max_infra_failures=excluded.max_infra_failures,
              max_total_cost_usd=excluded.max_total_cost_usd,
              max_wall_seconds=excluded.max_wall_seconds,
              updated_at=excluded.updated_at
            """,
            (
                repo,
                run_id,
                runner,
                int(max_infra_failures),
                float(max_total_cost_usd),
                int(max_wall_seconds),
                now,
                now,
            ),
        )
        row = conn.execute(
            "SELECT * FROM jobs WHERE repo=? AND run_id=?", (repo, run_id)
        ).fetchone()
    return _job_dict(row, db)


def status(
    *,
    canonical_repo: Path,
    run_id: str,
    db_path: Path | None = None,
) -> dict[str, Any]:
    repo = str(Path(canonical_repo).resolve(strict=False))
    db = db_path or default_db_path()
    with _connect(db) as conn:
        row = conn.execute(
            "SELECT * FROM jobs WHERE repo=? AND run_id=?", (repo, run_id)
        ).fetchone()
    if row is None:
        return {
            "schema": SCHEMA,
            "ok": False,
            "repo": repo,
            "run_id": run_id,
            "status": "NOT_ENQUEUED",
            "db_path": str(db),
        }
    return _job_dict(row, db)


def _core_snapshot(repo: Path, run_id: str) -> dict[str, Any]:
    """Read protocol state without disguising malformed evidence as absence."""
    run_dir = repo / ".ownframework-loop" / run_id
    loaded: dict[str, dict[str, Any]] = {}
    errors: list[str] = []
    for name in ("STATE.json", "BUILD_RECEIPT.json", "REVIEW_VERDICT.json"):
        path = run_dir / name
        if not path.exists():
            if name == "STATE.json":
                errors.append("STATE.json:missing")
            loaded[name] = {}
            continue
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            errors.append(f"{name}:{type(exc).__name__}")
            loaded[name] = {}
            continue
        if not isinstance(value, dict):
            errors.append(f"{name}:not_object")
            loaded[name] = {}
            continue
        loaded[name] = value
    state = loaded["STATE.json"]
    receipt = loaded["BUILD_RECEIPT.json"]
    verdict = loaded["REVIEW_VERDICT.json"]
    program = state.get("program") or {}
    return {
        "core_snapshot_ok": not errors,
        "core_snapshot_errors": errors,
        "core_state": state.get("state"),
        "last_candidate_sha": state.get("last_candidate_sha"),
        "build_pass_count": state.get("build_pass_count"),
        "review_pass_count": state.get("review_pass_count"),
        "repair_round": state.get("repair_round"),
        "current_checkpoints": program.get("current_checkpoints") or [],
        "last_build_candidate_sha": receipt.get("candidate_sha"),
        "last_review_verdict": verdict.get("verdict"),
        "last_reviewed_candidate_sha": verdict.get("candidate_sha_reviewed"),
    }


def _job_dict(row: sqlite3.Row, db: Path) -> dict[str, Any]:
    d = dict(row)
    d.update({"schema": SCHEMA, "ok": True, "db_path": str(db)})
    try:
        d.update(_core_snapshot(Path(str(row["repo"])), str(row["run_id"])))
    except Exception as exc:
        d.update({
            "core_snapshot_ok": False,
            "core_snapshot_errors": [f"snapshot_error:{type(exc).__name__}"],
        })
    return d


def _source_root() -> Path:
    return Path(__file__).resolve().parent.parent.parent


def _load_role_prompt(role: str) -> str:
    name = "of-builder.md" if role == "builder" else "of-reviewer.md"
    path = _source_root() / "agents" / name
    if not path.is_file():
        raise RuntimeError(f"runner prompt missing: {path}")
    return path.read_text(encoding="utf-8")


@dataclass
class RunnerResult:
    ok: bool
    returncode: int
    cost_usd: float
    stdout: str
    stderr: str
    pid: int | None = None


class ClaudeCodeRunner:
    """One fresh non-interactive Claude Code process per semantic pass."""

    runner_id = "claude-code"

    def run(
        self,
        work_order: dict[str, Any],
        *,
        timeout_seconds: int = 3600,
        on_start=None,
        durable_files: tuple[Path, Path] | None = None,
    ) -> RunnerResult:
        role = str(work_order.get("role") or "")
        if role not in {"builder", "reviewer"}:
            raise RuntimeError(f"unsupported work-order role: {role!r}")
        worktree = Path(str(work_order.get("worktree") or "")).resolve(strict=False)
        if not worktree.is_dir():
            raise RuntimeError(f"prepared worktree missing: {worktree}")

        role_contract = _load_role_prompt(role)
        payload = json.dumps(work_order, indent=2, sort_keys=True)
        prompt = (
            role_contract
            + "\n\n# SUPERVISOR WORK ORDER\n"
            + "You are running as one fresh unattended semantic pass. "
              "The deterministic core already claimed and prepared the pass. "
              "Do not call claim, prepare, finalize, push, merge, deploy, or create remotes. "
              "Use the exact paths and identities below. Complete the source work (builder) "
              "or exact-SHA assessment (reviewer), fill only the supplied semantic artifact, "
              "then stop.\n\n"
            + payload
        )

        claude_bin = os.environ.get("OFLOOP_CLAUDE_BIN", "claude")
        extra = shlex.split(os.environ.get("OFLOOP_CLAUDE_EXTRA_ARGS", ""))
        allowed_tools = os.environ.get(
            "OFLOOP_CLAUDE_ALLOWED_TOOLS",
            "Read,Edit,Write,Bash,Glob,Grep,WebSearch,WebFetch",
        )
        # Pipe the prompt via stdin. Passing it as an argv string lets Claude
        # CLI mis-parse leading `---` (YAML frontmatter in the role file) as
        # an unknown option. stdin is the supported, robust path.
        cmd = [
            claude_bin,
            "-p",
            "--output-format",
            "json",
            "--plugin-dir",
            str(_source_root()),
            "--allowedTools",
            allowed_tools,
            *extra,
        ]
        if durable_files is not None:
            out_path, err_path = durable_files
            out_path.parent.mkdir(parents=True, exist_ok=True)
            stdout_fh = out_path.open("w", encoding="utf-8")
            stderr_fh = err_path.open("w", encoding="utf-8")
        else:
            stdout_fh = subprocess.PIPE
            stderr_fh = subprocess.PIPE

        proc = subprocess.Popen(
            cmd,
            cwd=str(worktree),
            stdin=subprocess.PIPE,
            stdout=stdout_fh,
            stderr=stderr_fh,
            text=True,
            start_new_session=True,
            env=runtime_env.hermetic_subprocess_env(
                Path(str(work_order.get("canonical_repo") or "")).resolve(strict=False),
                str(work_order.get("run_id") or ""),
                role,
            ),
        )
        # Persist worker ownership BEFORE the child produces any output. If
        # anything between here and a successful communicate() raises, the
        # worker is terminated and reaped so we never leak an unowned Claude
        # process.
        if on_start is not None:
            try:
                on_start(int(proc.pid), role)
            except Exception as on_start_exc:
                _terminate_group(proc)
                raise

        timed_out = False
        # Use communicate(input=prompt) to feed stdin in a portable way
        # across Python 3.12+. The previous manual stdin.write()+close()
        # pattern was not portable: on some CPython 3.12 builds
        # communicate() reliably raised ValueError after manual stdin
        # close due to tightened pipe-close ordering.
        try:
            stdout_data, stderr_data = proc.communicate(
                input=prompt, timeout=int(timeout_seconds)
            )
        except subprocess.TimeoutExpired:
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

        if durable_files is not None:
            # Close our handles; the child holds its own dup until exit.
            try:
                stdout_fh.close()  # type: ignore[union-attr]
            except Exception:
                pass
            try:
                stderr_fh.close()  # type: ignore[union-attr]
            except Exception:
                pass
            out_path, err_path = durable_files
            try:
                stdout_data = out_path.read_text(encoding="utf-8", errors="replace")[-65536:]
            except Exception:
                stdout_data = ""
            try:
                stderr_data = err_path.read_text(encoding="utf-8", errors="replace")[-65536:]
            except Exception:
                stderr_data = ""

        if timed_out:
            return RunnerResult(
                ok=False,
                returncode=124,
                cost_usd=0.0,
                stdout=(stdout_data or "")[-65536:],
                stderr=((stderr_data or "") + "\nclaude runner timed out")[-65536:],
                pid=int(proc.pid),
            )

        cost = 0.0
        parsed: dict[str, Any] | None = None
        try:
            data = json.loads(stdout_data or "")
            if isinstance(data, dict):
                parsed = data
                cost = float(data.get("total_cost_usd") or 0.0)
        except Exception:
            pass

        # Treat Claude as success when its structured JSON output says
        # is_error is false AND there is a substantive result. Claude CLI
        # may exit non-zero for warnings (e.g. unrecognized model warnings)
        # while still producing a valid result envelope. The semantic
        # completion check + deterministic finalizer are the real authority.
        claude_ok = False
        if parsed is not None:
            if parsed.get("is_error") is False:
                claude_ok = True
            elif "is_error" not in parsed and (
                parsed.get("result") or parsed.get("subtype") == "success"
            ):
                claude_ok = True

        return RunnerResult(
            ok=bool(claude_ok and (parsed is not None)) or proc.returncode == 0,
            returncode=int(proc.returncode or 0),
            cost_usd=cost,
            stdout=(stdout_data or "")[-65536:],
            stderr=(stderr_data or "")[-65536:],
            pid=int(proc.pid),
        )


# Vendor-neutral runner registry. A new provider only needs to register a
# subclass of SemanticRunner (or duck-typed class with runner_id + run()).
# Adding a runner MUST NOT require any change to dispatch / supervisor FSM.
_RUNNER_REGISTRY: dict[str, Any] = {}


def register_runner(cls: type) -> type:
    rid = getattr(cls, "runner_id", None)
    if not rid or not isinstance(rid, str):
        raise RuntimeError(f"runner {cls!r} missing string runner_id")
    _RUNNER_REGISTRY[rid] = cls()
    return cls


@register_runner
class _RegisteredClaudeCodeRunner(ClaudeCodeRunner):
    runner_id = "claude-code"


def _runner(name: str):
    if name not in _RUNNER_REGISTRY:
        raise RuntimeError(
            f"runner {name!r} is not registered; live implementations: "
            + ", ".join(sorted(_RUNNER_REGISTRY))
        )
    return _RUNNER_REGISTRY[name]


def _take_next_job(conn: sqlite3.Connection) -> sqlite3.Row | None:
    _recover_stale_running(conn)
    now = time.time()
    conn.execute("BEGIN IMMEDIATE")
    already_running = conn.execute(
        "SELECT id FROM jobs WHERE status='RUNNING' LIMIT 1"
    ).fetchone()
    if already_running is not None:
        conn.commit()
        return None
    row = conn.execute(
        """
        SELECT * FROM jobs
        WHERE status IN ('QUEUED','BACKOFF') AND next_attempt_at <= ?
        ORDER BY created_at, id
        LIMIT 1
        """,
        (now,),
    ).fetchone()
    if row is None:
        conn.commit()
        return None
    conn.execute(
        """
        UPDATE jobs SET
          status='RUNNING',
          worker_pid=?,
          worker_started_at=?,
          worker_role='dispatching',
          execution_started_at=COALESCE(execution_started_at, ?),
          updated_at=?
        WHERE id=?
        """,
        (os.getpid(), now, now, now, row["id"]),
    )
    conn.commit()
    return conn.execute("SELECT * FROM jobs WHERE id=?", (row["id"],)).fetchone()


def _set_worker_pid(
    conn: sqlite3.Connection,
    job_id: int,
    pid: int,
    role: str,
    *,
    out_path: Path | None = None,
    err_path: Path | None = None,
) -> None:
    conn.execute(
        """
        UPDATE jobs SET worker_pid=?, worker_started_at=?, worker_role=?,
          worker_stdout_path=?, worker_stderr_path=?, updated_at=?
        WHERE id=? AND status='RUNNING'
        """,
        (
            int(pid),
            time.time(),
            role,
            str(out_path) if out_path else None,
            str(err_path) if err_path else None,
            time.time(),
            job_id,
        ),
    )
    conn.commit()


def _compute_attempt_digest(stdout_tail: str, returncode: int, job_id: int) -> str:
    import hashlib
    h = hashlib.sha256()
    h.update(f"{int(job_id)}|{int(returncode)}|".encode("utf-8"))
    h.update((stdout_tail or "")[-8192:].encode("utf-8", errors="replace"))
    return h.hexdigest()


def _record_cost_attempt(
    conn: sqlite3.Connection, job_id: int, digest: str, cost_usd: float
) -> float:
    """Add the cost of one attempt at most once. Returns the amount actually added."""
    try:
        conn.execute(
            "INSERT INTO cost_attempts (job_id, attempt_digest, cost_usd, recorded_at)"
            " VALUES (?, ?, ?, ?)",
            (int(job_id), digest, float(cost_usd), time.time()),
        )
        conn.commit()
        return float(cost_usd)
    except sqlite3.IntegrityError:
        # Duplicate attempt digest — already accounted for.
        return 0.0


def _update_job(
    conn: sqlite3.Connection,
    job_id: int,
    *,
    status_value: str,
    infra_failures: int | None = None,
    total_cost_usd: float | None = None,
    last_error: str | None = None,
    next_attempt_at: float | None = None,
) -> None:
    row = conn.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
    if row is None:
        return
    conn.execute(
        """
        UPDATE jobs SET
          status=?,
          infra_failures=?,
          total_cost_usd=?,
          last_error=?,
          next_attempt_at=?,
          worker_pid=NULL,
          worker_started_at=NULL,
          worker_role=NULL,
          updated_at=?
        WHERE id=?
        """,
        (
            status_value,
            int(row["infra_failures"] if infra_failures is None else infra_failures),
            float(row["total_cost_usd"] if total_cost_usd is None else total_cost_usd),
            last_error,
            float(row["next_attempt_at"] if next_attempt_at is None else next_attempt_at),
            time.time(),
            job_id,
        ),
    )
    conn.commit()


def run_one(*, db_path: Path | None = None, timeout_seconds: int = 3600) -> dict[str, Any]:
    """Execute at most one semantic BUILD/REVIEW action."""
    db = db_path or default_db_path()
    with _connect(db) as conn:
        job = _take_next_job(conn)
        if job is None:
            return {"schema": SCHEMA, "ok": True, "action": "IDLE", "db_path": str(db)}

        try:
            work_order = dispatch_mod.claim_next(
                canonical_repo=Path(job["repo"]),
                run_id=str(job["run_id"]),
            )
            decision = str(work_order.get("decision") or "")
            if decision == "TERMINAL":
                _update_job(conn, job["id"], status_value="DONE", last_error=None)
                return {
                    "schema": SCHEMA,
                    "ok": True,
                    "action": "TERMINAL",
                    "job_id": job["id"],
                    "work_order": work_order,
                }
            if decision == "WAIT":
                # Bounded next-attempt delay so a recurring WAIT cannot
                # busy-spin the durable execution clock. The delay is short
                # (5s default) to remain responsive to genuine transitions
                # but long enough that a continuously-WAIT run does not
                # spam the supervisor stdout with IDLE/WAIT events.
                wait_seconds = 5.0
                _update_job(
                    conn,
                    job["id"],
                    status_value="QUEUED",
                    last_error=None,
                    next_attempt_at=time.time() + wait_seconds,
                )
                return {
                    "schema": SCHEMA,
                    "ok": True,
                    "action": "WAIT",
                    "job_id": job["id"],
                    "wait_seconds": wait_seconds,
                    "work_order": work_order,
                }

            semantic_ready, semantic_reason = dispatch_mod.semantic_result_ready(
                work_order
            )
            if semantic_ready:
                finalized = dispatch_mod.finalize_work_order(work_order)
                _update_job(
                    conn,
                    job["id"],
                    status_value="QUEUED",
                    infra_failures=0,
                    last_error=None,
                    next_attempt_at=0,
                )
                return {
                    "schema": SCHEMA,
                    "ok": True,
                    "action": f"{decision}_REPLAY_FINALIZED",
                    "job_id": job["id"],
                    "cost_usd": 0.0,
                    "semantic_replay": True,
                    "finalized": finalized,
                }

            started_at = float(job["execution_started_at"] or time.time())
            elapsed = max(0.0, time.time() - started_at)
            max_wall = int(job["max_wall_seconds"] or 0)
            max_cost = float(job["max_total_cost_usd"] or 0.0)
            spent = float(job["total_cost_usd"] or 0.0)
            if max_wall > 0 and elapsed >= max_wall:
                _update_job(
                    conn,
                    job["id"],
                    status_value="QUARANTINED",
                    last_error=f"operational wall-clock ceiling reached: {elapsed:.1f}s >= {max_wall}s",
                    next_attempt_at=0,
                )
                return {
                    "schema": SCHEMA,
                    "ok": False,
                    "action": "QUARANTINED",
                    "job_id": job["id"],
                    "reason": "wall_clock_ceiling",
                    "elapsed_seconds": elapsed,
                    "max_wall_seconds": max_wall,
                }
            if max_cost > 0 and spent >= max_cost:
                _update_job(
                    conn,
                    job["id"],
                    status_value="QUARANTINED",
                    last_error=f"operational model-cost ceiling reached: ${spent:.4f} >= ${max_cost:.4f}",
                    next_attempt_at=0,
                )
                return {
                    "schema": SCHEMA,
                    "ok": False,
                    "action": "QUARANTINED",
                    "job_id": job["id"],
                    "reason": "cost_ceiling",
                    "total_cost_usd": spent,
                    "max_total_cost_usd": max_cost,
                }

            durable_files = worker_log_paths(
                Path(job["repo"]),
                str(job["run_id"]),
                int(job["id"]),
                str(work_order.get("role") or "builder"),
            )

            result = _runner(str(job["runner"])).run(
                work_order,
                timeout_seconds=timeout_seconds,
                on_start=lambda pid, role: _set_worker_pid(
                    conn,
                    int(job["id"]),
                    pid,
                    role,
                    out_path=durable_files[0],
                    err_path=durable_files[1],
                ),
                durable_files=durable_files,
            )
            attempt_digest = _compute_attempt_digest(
                result.stdout, result.returncode, job["id"]
            )
            added_cost = _record_cost_attempt(
                conn, job["id"], attempt_digest, result.cost_usd
            )
            # Derive cumulative cost from cost_attempts (exact-once) rather
            # than from in-memory total_cost_usd so the value is always the
            # sum of recorded attempts.
            try:
                new_cost = float(
                    conn.execute(
                        "SELECT COALESCE(SUM(cost_usd),0) FROM cost_attempts WHERE job_id=?",
                        (job["id"],),
                    ).fetchone()[0]
                    or 0.0
                )
            except Exception:
                new_cost = float(job["total_cost_usd"] or 0.0) + added_cost
            if not result.ok:
                failures = int(job["infra_failures"]) + 1
                max_failures = int(job["max_infra_failures"])
                quarantined = failures >= max_failures
                backoff = min(300.0, float(5 * (2 ** max(0, failures - 1))))
                _update_job(
                    conn,
                    job["id"],
                    status_value="QUARANTINED" if quarantined else "BACKOFF",
                    infra_failures=failures,
                    total_cost_usd=new_cost,
                    last_error=(
                        f"runner rc={result.returncode}: "
                        f"{result.stderr or result.stdout}"
                    )[-4000:],
                    next_attempt_at=0 if quarantined else time.time() + backoff,
                )
                return {
                    "schema": SCHEMA,
                    "ok": False,
                    "action": "QUARANTINED" if quarantined else "BACKOFF",
                    "job_id": job["id"],
                    "returncode": result.returncode,
                    "cost_usd": result.cost_usd,
                }

            finalized = dispatch_mod.finalize_work_order(work_order)
            _update_job(
                conn,
                job["id"],
                status_value="QUEUED",
                infra_failures=0,
                total_cost_usd=new_cost,
                last_error=None,
                next_attempt_at=0,
            )
            return {
                "schema": SCHEMA,
                "ok": True,
                "action": decision,
                "job_id": job["id"],
                "cost_usd": result.cost_usd,
                "finalized": finalized,
            }
        except Exception as exc:
            failures = int(job["infra_failures"]) + 1
            max_failures = int(job["max_infra_failures"])
            quarantined = failures >= max_failures
            backoff = min(300.0, float(5 * (2 ** max(0, failures - 1))))
            # Persist any cost the runner already accumulated before the
            # exception. cost_attempts deduplicates; jobs.total_cost_usd is
            # the operator-visible cumulative number.
            try:
                total_attempted_cost = float(
                    conn.execute(
                        "SELECT COALESCE(SUM(cost_usd),0) FROM cost_attempts WHERE job_id=?",
                        (job["id"],),
                    ).fetchone()[0]
                    or 0.0
                )
            except Exception:
                total_attempted_cost = float(job["total_cost_usd"] or 0.0)
            _update_job(
                conn,
                job["id"],
                status_value="QUARANTINED" if quarantined else "BACKOFF",
                infra_failures=failures,
                total_cost_usd=total_attempted_cost,
                last_error=f"{type(exc).__name__}: {exc}"[-4000:],
                next_attempt_at=0 if quarantined else time.time() + backoff,
            )
            return {
                "schema": SCHEMA,
                "ok": False,
                "action": "QUARANTINED" if quarantined else "BACKOFF",
                "job_id": job["id"],
                "error": str(exc),
            }


def serve(
    *,
    db_path: Path | None = None,
    poll_seconds: float = 2.0,
    timeout_seconds: int = 3600,
    once: bool = False,
) -> dict[str, Any] | None:
    """Run the durable execution clock. Idle iterations make zero model calls."""
    last_emit: float = 0.0
    idle_log_interval = max(60.0, float(poll_seconds) * 30)
    while True:
        event = run_one(db_path=db_path, timeout_seconds=timeout_seconds)
        if once:
            return event
        action = event.get("action")
        # Emit non-IDLE actions immediately; rate-limit IDLE so the durable
        # launchd-owned service does not flood its stdout with an unbounded
        # 2-second heartbeat stream.
        now = time.time()
        if action != "IDLE" or (now - last_emit) >= idle_log_interval:
            print(json.dumps(event, sort_keys=True), flush=True)
            last_emit = now
        if action == "IDLE":
            time.sleep(max(0.25, float(poll_seconds)))


__all__ = [
    "SCHEMA",
    "ClaudeCodeRunner",
    "default_db_path",
    "default_worker_log_dir",
    "enqueue",
    "register_runner",
    "resume",
    "run_one",
    "serve",
    "status",
    "worker_log_paths",
]


def resume(
    *,
    canonical_repo: Path,
    run_id: str,
    db_path: Path | None = None,
    max_infra_failures: int | None = None,
    max_total_cost_usd: float | None = None,
    max_wall_seconds: int | None = None,
    reset_execution_started_at: bool = True,
) -> dict[str, Any]:
    """Clear operational quarantine and reset operational counters only.

    Does NOT alter STATE.json, packet scope, candidate SHA, review verdict, or
    engineering pass counters. Cumulative observed cost is preserved; only the
    wall-clock ceiling start is reset (if requested) so the run can make fresh
    progress after an infrastructure ceiling was reached.

    Returns the updated job dict (or NOT_ENQUEUED).
    """
    repo = str(Path(canonical_repo).resolve(strict=False))
    db = db_path or default_db_path()
    now = time.time()
    # Resume is exclusively a QUARANTINED -> QUEUED recovery action. Any
    # other state is refused without changing budgets, wall-clock origin, PID
    # ownership, backoff or error evidence.
    with _connect(db) as conn:
        existing = conn.execute(
            "SELECT * FROM jobs WHERE repo=? AND run_id=?", (repo, run_id)
        ).fetchone()
    if existing is None:
        return {
            "schema": SCHEMA,
            "ok": False,
            "repo": repo,
            "run_id": run_id,
            "status": "NOT_ENQUEUED",
            "db_path": str(db),
            "resumed": False,
            "reason": "not_enqueued",
        }
    if str(existing["status"]) != "QUARANTINED":
        result = _job_dict(existing, db)
        result.update({
            "ok": False,
            "resumed": False,
            "reason": "resume_requires_quarantined",
        })
        return result
    if existing["worker_pid"] and _pid_alive(
        int(existing["worker_pid"]),
        float(existing["worker_started_at"]) if existing["worker_started_at"] else None,
    ):
        result = _job_dict(existing, db)
        result.update({
            "ok": False,
            "resumed": False,
            "reason": "quarantined_worker_still_alive",
        })
        return result

    sets = [
        "status='QUEUED'",
        "infra_failures=0",
        "next_attempt_at=0",
        "last_error=NULL",
        "worker_pid=NULL",
        "worker_started_at=NULL",
        "worker_role=NULL",
        "updated_at=?",
    ]
    params: list[Any] = [now]
    if max_infra_failures is not None:
        sets.append("max_infra_failures=?")
        params.append(int(max_infra_failures))
    if max_total_cost_usd is not None:
        sets.append("max_total_cost_usd=?")
        params.append(float(max_total_cost_usd))
    if max_wall_seconds is not None:
        sets.append("max_wall_seconds=?")
        params.append(int(max_wall_seconds))
    if reset_execution_started_at:
        sets.append("execution_started_at=?")
        params.append(now)
    params.extend([repo, run_id])
    with _connect(db) as conn:
        conn.execute(
            f"UPDATE jobs SET {', '.join(sets)} WHERE repo=? AND run_id=?",
            params,
        )
        row = conn.execute(
            "SELECT * FROM jobs WHERE repo=? AND run_id=?", (repo, run_id)
        ).fetchone()
    if row is None:
        return {
            "schema": SCHEMA,
            "ok": False,
            "repo": repo,
            "run_id": run_id,
            "status": "NOT_ENQUEUED",
            "db_path": str(db),
        }
    result = _job_dict(row, db)
    result["resumed"] = True
    return result
