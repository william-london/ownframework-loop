"""Durable, vendor-thin supervisor for OwnFramework Loop.

Protocol truth remains in the repository's OwnFramework Loop artifacts. SQLite
stores only machine operations: queue state, retries, backoff, runner identity,
and cost/runtime observations.

The supervisor consumes typed work orders from dispatch.py. It never decides
engineering transitions itself.
"""
from __future__ import annotations

import json
import os
import shlex
import sqlite3
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from . import dispatch as dispatch_mod

SCHEMA = "ownframework-loop-supervisor/v1"
ACTIVE = {"QUEUED", "BACKOFF", "RUNNING"}
TERMINAL = {"DONE", "QUARANTINED"}


def default_db_path() -> Path:
    root = os.environ.get("XDG_STATE_HOME", "").strip()
    base = Path(root).expanduser() if root else Path.home() / ".local" / "state"
    return base / "ownframework-loop" / "supervisor.sqlite3"


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
          UNIQUE(repo, run_id)
        );
        """
    )
    return conn


def enqueue(
    *,
    canonical_repo: Path,
    run_id: str,
    runner: str = "claude-code",
    db_path: Path | None = None,
    max_infra_failures: int = 3,
) -> dict[str, Any]:
    repo = str(Path(canonical_repo).resolve(strict=False))
    db = db_path or default_db_path()
    now = time.time()
    with _connect(db) as conn:
        conn.execute(
            """
            INSERT INTO jobs
              (repo, run_id, runner, status, infra_failures,
               max_infra_failures, total_cost_usd, next_attempt_at,
               created_at, updated_at)
            VALUES (?, ?, ?, 'QUEUED', 0, ?, 0, 0, ?, ?)
            ON CONFLICT(repo, run_id) DO UPDATE SET
              runner=excluded.runner,
              max_infra_failures=excluded.max_infra_failures,
              status=CASE
                WHEN jobs.status IN ('DONE','QUARANTINED') THEN jobs.status
                ELSE 'QUEUED'
              END,
              updated_at=excluded.updated_at
            """,
            (repo, run_id, runner, int(max_infra_failures), now, now),
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


def _job_dict(row: sqlite3.Row, db: Path) -> dict[str, Any]:
    d = dict(row)
    d.update({"schema": SCHEMA, "ok": True, "db_path": str(db)})
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


class ClaudeCodeRunner:
    """One fresh non-interactive Claude Code process per semantic pass."""

    runner_id = "claude-code"

    def run(self, work_order: dict[str, Any], *, timeout_seconds: int = 3600) -> RunnerResult:
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
        cmd = [
            claude_bin,
            "-p",
            prompt,
            "--output-format",
            "json",
            *extra,
        ]
        try:
            proc = subprocess.run(
                cmd,
                cwd=str(worktree),
                capture_output=True,
                text=True,
                timeout=int(timeout_seconds),
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            return RunnerResult(
                ok=False,
                returncode=124,
                cost_usd=0.0,
                stdout=(exc.stdout or "") if isinstance(exc.stdout, str) else "",
                stderr="claude runner timed out",
            )

        cost = 0.0
        try:
            data = json.loads(proc.stdout)
            cost = float(data.get("total_cost_usd") or 0.0)
        except Exception:
            pass
        return RunnerResult(
            ok=proc.returncode == 0,
            returncode=int(proc.returncode),
            cost_usd=cost,
            stdout=proc.stdout[-65536:],
            stderr=proc.stderr[-65536:],
        )


def _runner(name: str) -> ClaudeCodeRunner:
    if name == "claude-code":
        return ClaudeCodeRunner()
    raise RuntimeError(f"runner {name!r} is not live-implemented")


def _take_next_job(conn: sqlite3.Connection) -> sqlite3.Row | None:
    now = time.time()
    conn.execute("BEGIN IMMEDIATE")
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
        "UPDATE jobs SET status='RUNNING', updated_at=? WHERE id=?",
        (now, row["id"]),
    )
    conn.commit()
    return conn.execute("SELECT * FROM jobs WHERE id=?", (row["id"],)).fetchone()


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
                _update_job(conn, job["id"], status_value="QUEUED", last_error=None)
                return {
                    "schema": SCHEMA,
                    "ok": True,
                    "action": "WAIT",
                    "job_id": job["id"],
                    "work_order": work_order,
                }

            result = _runner(str(job["runner"])).run(
                work_order, timeout_seconds=timeout_seconds
            )
            new_cost = float(job["total_cost_usd"]) + result.cost_usd
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
            _update_job(
                conn,
                job["id"],
                status_value="QUARANTINED" if quarantined else "BACKOFF",
                infra_failures=failures,
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
    while True:
        event = run_one(db_path=db_path, timeout_seconds=timeout_seconds)
        if once:
            return event
        print(json.dumps(event, sort_keys=True), flush=True)
        if event.get("action") == "IDLE":
            time.sleep(max(0.25, float(poll_seconds)))


__all__ = [
    "SCHEMA",
    "ClaudeCodeRunner",
    "default_db_path",
    "enqueue",
    "run_one",
    "serve",
    "status",
]
