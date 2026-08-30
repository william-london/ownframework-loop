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
import math
import re
import os
import shlex
import signal
import sqlite3
import shutil
import subprocess
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from . import dispatch as dispatch_mod, packet as packet_mod, runtime_env, state as state_mod, util, runtime_identity

SCHEMA = "ownframework-loop-supervisor/v1"
# Per-pass runaway fuse fallback. A semantic worker that neither declared a
# packet budget nor got an operational narrowing is bounded to one hour so a
# stuck worker cannot hold the single global execution slot indefinitely.
# Long PROGRAM passes are funded deliberately through
# risk_budget.max_pass_runtime_seconds (packet authority; up to 28800 for v3)
# rather than by widening the default fuse.
DEFAULT_SEMANTIC_TIMEOUT_SECONDS = 3600
# Commissioned semantic passes are sealed local workers.  Builder and reviewer
# intentionally get different first-party Claude capability sets so reviewer
# source immutability is structural, not merely a prompt/hook convention.
CLAUDE_BUILDER_TOOLS = "Read,Edit,Write,NotebookEdit,Bash,Glob,Grep"
CLAUDE_REVIEWER_TOOLS = "Read,Bash,Glob,Grep"

TERMINAL_SEMANTIC_ATTEMPT_STATUSES = frozenset({
    "COMPLETED", "COST_UNKNOWN", "TOKENS_UNKNOWN",
    "FAILED", "RECOVERED", "SUPERSEDED",
})

# --restricted is Claude Code's native scripted/evaluation boundary for shared
# machines. It confines built-in file tools to working directories, ignores
# user/project/local settings, refuses bypass/cloud sessions, and removes
# command/code/web tools unless explicitly named. Available from v2.1.248.
MIN_SECURE_CLAUDE_CODE_VERSION = (2, 1, 248)

# Extra arguments are operator convenience only. They must never be able to
# replace the unattended worker's tool boundary, sandbox, project-root, or
# settings-source authority.
_CLAUDE_EXTRA_ARG_AUTHORITY_FLAGS = {
    "--settings",
    "--setting-sources",
    "--tools",
    "--allowedTools",
    "--allowed-tools",
    "--disallowedTools",
    "--disallowed-tools",
    "--permission-mode",
    "--dangerously-skip-permissions",
    "--allow-dangerously-skip-permissions",
    "--add-dir",
    "--cwd",
    "--plugin-dir",
    "--mcp-config",
    "--strict-mcp-config",
    "--chrome",
    "--no-chrome",
    "--remote",
    "--teleport",
    "--no-session-persistence",
    "--restricted",
}


def _claude_cli_version(executable: str) -> tuple[int, int, int] | None:
    """Return Claude Code semantic version, or None when it cannot be proven."""
    try:
        proc = subprocess.run(
            [executable, "--version"],
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    match = re.search(r"(?<!\d)(\d+)\.(\d+)\.(\d+)(?!\d)", proc.stdout or "")
    if not match:
        return None
    return tuple(int(part) for part in match.groups())


def _validate_claude_extra_args(extra: list[str]) -> None:
    """Refuse operator extra args that could weaken semantic-worker authority."""
    for arg in extra:
        flag = str(arg).split("=", 1)[0]
        if flag in _CLAUDE_EXTRA_ARG_AUTHORITY_FLAGS:
            raise RuntimeError(
                f"OFLOOP_CLAUDE_EXTRA_ARGS may not override semantic-worker authority: {flag}"
            )


def _semantic_worker_settings(
    *,
    canonical_repo: Path,
    run_id: str,
    role: str,
    worktree: Path,
    semantic_path: Path,
) -> dict[str, Any]:
    """Fail-closed Claude settings for one unattended semantic worker.

    The Bash sandbox is intentionally narrower than the Edit/Write hook
    boundary: builder commands may write the builder worktree; reviewer
    commands may not mutate the exact-SHA reviewer worktree; both roles may
    write only their pass-scoped semantic-result directory and Loop's
    externalized runtime cache outside the worktree.

    --restricted excludes user/project/local settings from the semantic worker.
    Managed policy remains the explicit organization-owned trust boundary;
    Loop supplies the pass-specific sandbox through CLI --settings.
    """
    cache_root = runtime_env.runtime_cache_path(canonical_repo, run_id, role)

    # Restricted mode already confines built-in Read/Edit/Write to the working
    # directories. Bash is explicitly re-enabled for local compilers/tests/git,
    # so give Bash the complementary OS-level read boundary: deny the operator's
    # entire home directory, then re-open only the current pass and trusted Loop
    # runtime surfaces. More-specific allowRead wins over the broad denyRead.
    home = Path.home().expanduser().resolve(strict=False)
    allow_read = sorted({
        str(worktree.resolve(strict=False)),
        str(semantic_path.parent.resolve(strict=False)),
        str(cache_root.resolve(strict=False)),
        str((canonical_repo / ".git").resolve(strict=False)),
        str(_source_root().resolve(strict=False)),
    })
    allow_write = sorted({
        str(cache_root.resolve(strict=False)),
        str(semantic_path.parent.resolve(strict=False)),
    })
    filesystem: dict[str, Any] = {
        "denyRead": [str(home)],
        "allowRead": allow_read,
        "allowWrite": allow_write,
    }
    if role == "reviewer":
        filesystem["denyWrite"] = [str(worktree.resolve(strict=False))]

    # No semantic pass needs host credentials or outbound network. Dependency
    # provisioning/research is a pre-SPEC/bootstrap responsibility. These
    # native credential rules keep common non-cloud tokens out of Bash even if
    # they exist in the supervisor's environment; the subprocess scrub env var
    # separately strips Anthropic/cloud-provider credentials.
    credential_vars = [
        "GITHUB_TOKEN", "GH_TOKEN", "NPM_TOKEN", "NODE_AUTH_TOKEN",
        "PYPI_TOKEN", "TWINE_PASSWORD", "DOCKER_AUTH_CONFIG",
    ]
    return {
        "autoMemoryEnabled": False,
        "sandbox": {
            "enabled": True,
            "failIfUnavailable": True,
            "autoAllowBashIfSandboxed": True,
            "allowUnsandboxedCommands": False,
            "excludedCommands": [],
            "filesystem": filesystem,
            "network": {
                "allowedDomains": [],
                "strictAllowlist": True,
            },
            "credentials": {
                "envVars": [
                    {"name": name, "mode": "deny"} for name in credential_vars
                ],
            },
        },
    }


def resolve_semantic_timeout(
    packet_meta: dict[str, Any] | None,
    supervisor_timeout_seconds: int | float = 0,
) -> int:
    """Resolve one semantic-pass timeout.

    Packet max_pass_runtime_seconds is authority. A positive supervisor
    timeout may narrow it operationally but cannot widen it. With neither,
    preserve the historical one-hour fallback fuse for both single and
    PROGRAM runs; a PROGRAM funds wider passes through its packet budget.
    """
    rb = (packet_meta or {}).get("risk_budget") or {}
    packet_limit = 0
    if isinstance(rb, dict):
        try:
            packet_limit = int(rb.get("max_pass_runtime_seconds") or 0)
        except (TypeError, ValueError):
            packet_limit = 0
    try:
        operational = int(supervisor_timeout_seconds or 0)
    except (TypeError, ValueError):
        operational = 0
    if packet_limit > 0 and operational > 0:
        return min(packet_limit, operational)
    if packet_limit > 0:
        return packet_limit
    if operational > 0:
        return operational
    return DEFAULT_SEMANTIC_TIMEOUT_SECONDS

ACTIVE = {"QUEUED", "BACKOFF", "RUNNING"}
TERMINAL = {"DONE", "QUARANTINED", "RETIRED"}


def runtime_generation() -> str:
    """Deterministic identity of the exact runtime bytes serving this process."""
    from . import __version__
    root = Path(__file__).resolve().parents[2]
    return runtime_identity.runtime_generation_for_root(root, __version__)


# Alias so enqueue() can compute the default binding even though its
# ``runtime_generation`` parameter shadows the function name.
_current_runtime_generation = runtime_generation


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
    attempt_id: str | None = None,
) -> tuple[Path, Path]:
    """Return durable (stdout, stderr) log paths for one worker attempt.

    The supervisor or any replacement supervisor can read these files even if
    the original parent process died while the child Claude process was still
    alive. Output paths survive both processes by design.
    """
    state_mod.validate_run_id(run_id)
    safe_role = "builder" if role not in ("builder", "reviewer") else role
    safe_run = run_id
    d = default_worker_log_dir() / _slug_repo(canonical_repo) / safe_run
    d.mkdir(parents=True, exist_ok=True)
    safe_attempt = "".join(
        ch for ch in str(attempt_id or "") if ch.isalnum() or ch in "-_."
    )[:80]
    suffix = f"-attempt-{safe_attempt}" if safe_attempt else ""
    return (
        d / f"job-{int(job_id)}-{safe_role}{suffix}.out",
        d / f"job-{int(job_id)}-{safe_role}{suffix}.err",
    )


# Ledger data-version. Existing resource ceilings are durable operator state.
# Historical rows may carry the old $25 / unlimited-token / 8h fingerprint,
# but that tuple is indistinguishable from an operator explicitly selecting it.
# Preserve it and mark ambiguity rather than inventing intent.
SCHEMA_DATA_VERSION = 3
_LEGACY_BUDGET_DEFAULT_FINGERPRINT = (25.0, 0, 28800)


def _apply_data_migrations(conn: sqlite3.Connection) -> None:
    """Versioned migrations; ambiguous historical limits are never rewritten."""
    version = int(conn.execute("PRAGMA user_version").fetchone()[0])
    if version < 3:
        conn.execute(
            """UPDATE jobs
               SET legacy_budget_ambiguous=1
               WHERE max_total_cost_usd=? AND max_total_tokens=?
                 AND max_wall_seconds=?""",
            _LEGACY_BUDGET_DEFAULT_FINGERPRINT,
        )
        conn.execute(f"PRAGMA user_version = {SCHEMA_DATA_VERSION}")
        conn.commit()

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
          transient_failures INTEGER NOT NULL DEFAULT 0,
          max_transient_failures INTEGER NOT NULL DEFAULT 8,
          transient_recovery_cycles INTEGER NOT NULL DEFAULT 0,
          max_transient_recovery_cycles INTEGER NOT NULL DEFAULT 2,
          total_cost_usd REAL NOT NULL DEFAULT 0,
          total_input_tokens INTEGER NOT NULL DEFAULT 0,
          total_output_tokens INTEGER NOT NULL DEFAULT 0,
          total_cache_read_tokens INTEGER NOT NULL DEFAULT 0,
          total_cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
          last_error TEXT,
          last_failure_class TEXT,
          last_failure_reason TEXT,
          next_attempt_at REAL NOT NULL DEFAULT 0,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          worker_pid INTEGER,
          worker_started_at REAL,
          worker_role TEXT,
          max_total_cost_usd REAL NOT NULL DEFAULT 0,
          max_total_tokens INTEGER NOT NULL DEFAULT 0,
          max_wall_seconds INTEGER NOT NULL DEFAULT 0,
          execution_started_at REAL,
          worker_stdout_path TEXT,
          worker_stderr_path TEXT,
          runtime_generation TEXT NOT NULL DEFAULT '',
          legacy_budget_ambiguous INTEGER NOT NULL DEFAULT 0,
          UNIQUE(repo, run_id)
        );
        CREATE TABLE IF NOT EXISTS cost_attempts (
          job_id INTEGER NOT NULL,
          attempt_digest TEXT NOT NULL,
          cost_usd REAL NOT NULL,
          recorded_at REAL NOT NULL,
          PRIMARY KEY (job_id, attempt_digest)
        );
        CREATE TABLE IF NOT EXISTS semantic_attempts (
          attempt_id TEXT PRIMARY KEY,
          job_id INTEGER NOT NULL,
          role TEXT NOT NULL,
          status TEXT NOT NULL,
          started_at REAL NOT NULL,
          completed_at REAL,
          worker_pid INTEGER,
          stdout_path TEXT NOT NULL,
          stderr_path TEXT NOT NULL,
          returncode INTEGER,
          cost_usd REAL NOT NULL DEFAULT 0,
          cost_accounted INTEGER NOT NULL DEFAULT 0,
          input_tokens INTEGER NOT NULL DEFAULT 0,
          output_tokens INTEGER NOT NULL DEFAULT 0,
          cache_read_tokens INTEGER NOT NULL DEFAULT 0,
          cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
          tokens_known INTEGER NOT NULL DEFAULT 0,
          failure_class TEXT,
          failure_reason TEXT
        );
        CREATE INDEX IF NOT EXISTS semantic_attempts_job_idx
          ON semantic_attempts(job_id, started_at);
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
        # New columns migrate DISABLED. Existing values are preserved;
        # the ambiguous historical $25 / unlimited-token / 8-hour tuple is
        # flagged, never silently rewritten.
        "max_total_cost_usd": "ALTER TABLE jobs ADD COLUMN max_total_cost_usd REAL NOT NULL DEFAULT 0",
        "max_wall_seconds": "ALTER TABLE jobs ADD COLUMN max_wall_seconds INTEGER NOT NULL DEFAULT 0",
        "execution_started_at": "ALTER TABLE jobs ADD COLUMN execution_started_at REAL",
        "worker_stdout_path": "ALTER TABLE jobs ADD COLUMN worker_stdout_path TEXT",
        "worker_stderr_path": "ALTER TABLE jobs ADD COLUMN worker_stderr_path TEXT",
        "worker_attempt_id": "ALTER TABLE jobs ADD COLUMN worker_attempt_id TEXT",
        "latest_attempt_id": "ALTER TABLE jobs ADD COLUMN latest_attempt_id TEXT",
        "transient_failures": "ALTER TABLE jobs ADD COLUMN transient_failures INTEGER NOT NULL DEFAULT 0",
        "max_transient_failures": "ALTER TABLE jobs ADD COLUMN max_transient_failures INTEGER NOT NULL DEFAULT 8",
        "transient_recovery_cycles": "ALTER TABLE jobs ADD COLUMN transient_recovery_cycles INTEGER NOT NULL DEFAULT 0",
        "max_transient_recovery_cycles": "ALTER TABLE jobs ADD COLUMN max_transient_recovery_cycles INTEGER NOT NULL DEFAULT 2",
        "total_input_tokens": "ALTER TABLE jobs ADD COLUMN total_input_tokens INTEGER NOT NULL DEFAULT 0",
        "total_output_tokens": "ALTER TABLE jobs ADD COLUMN total_output_tokens INTEGER NOT NULL DEFAULT 0",
        "total_cache_read_tokens": "ALTER TABLE jobs ADD COLUMN total_cache_read_tokens INTEGER NOT NULL DEFAULT 0",
        "total_cache_creation_tokens": "ALTER TABLE jobs ADD COLUMN total_cache_creation_tokens INTEGER NOT NULL DEFAULT 0",
        "max_total_tokens": "ALTER TABLE jobs ADD COLUMN max_total_tokens INTEGER NOT NULL DEFAULT 0",
        "last_failure_class": "ALTER TABLE jobs ADD COLUMN last_failure_class TEXT",
        "last_failure_reason": "ALTER TABLE jobs ADD COLUMN last_failure_reason TEXT",
        "runtime_generation": "ALTER TABLE jobs ADD COLUMN runtime_generation TEXT NOT NULL DEFAULT ''",
        "legacy_budget_ambiguous": "ALTER TABLE jobs ADD COLUMN legacy_budget_ambiguous INTEGER NOT NULL DEFAULT 0",
    }
    for name, statement in migrations.items():
        if name not in columns:
            conn.execute(statement)
    _apply_data_migrations(conn)

    attempt_columns = {
        str(row["name"])
        for row in conn.execute("PRAGMA table_info(semantic_attempts)").fetchall()
    }
    attempt_migrations = {
        "input_tokens": "ALTER TABLE semantic_attempts ADD COLUMN input_tokens INTEGER NOT NULL DEFAULT 0",
        "output_tokens": "ALTER TABLE semantic_attempts ADD COLUMN output_tokens INTEGER NOT NULL DEFAULT 0",
        "cache_read_tokens": "ALTER TABLE semantic_attempts ADD COLUMN cache_read_tokens INTEGER NOT NULL DEFAULT 0",
        "cache_creation_tokens": "ALTER TABLE semantic_attempts ADD COLUMN cache_creation_tokens INTEGER NOT NULL DEFAULT 0",
        "tokens_known": "ALTER TABLE semantic_attempts ADD COLUMN tokens_known INTEGER NOT NULL DEFAULT 0",
        "failure_class": "ALTER TABLE semantic_attempts ADD COLUMN failure_class TEXT",
        "failure_reason": "ALTER TABLE semantic_attempts ADD COLUMN failure_reason TEXT",
    }
    for name, statement in attempt_migrations.items():
        if name not in attempt_columns:
            conn.execute(statement)
    conn.commit()
    return conn


def _connect_readonly(path: Path) -> sqlite3.Connection:
    """Open an existing supervisor ledger without schema/data mutation."""
    p = Path(path).expanduser().resolve(strict=False)
    if not p.is_file():
        raise FileNotFoundError(str(p))
    conn = sqlite3.connect(f"file:{p}?mode=ro", uri=True, timeout=5)
    conn.row_factory = sqlite3.Row
    return conn


def _pid_alive(pid: int | None, worker_started_at: float | None = None) -> bool:
    """True iff `pid` is alive AND consistent with our recorded worker.

    Beyond the bare kill(pid, 0) probe, if `worker_started_at` is provided,
    we cross-check that the process start time is within ±10 seconds of the
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
        if abs(start_ts - worker_started_at) > 10:
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
            # We removed fields 1(pid) and 2(comm), so fields[0] is proc
            # stat field 3 (state). Linux starttime is field 22 => index 19.
            if len(fields) < 20:
                return None
            ticks = int(fields[19])
            try:
                clk_tck = os.sysconf("SC_CLK_TCK")
            except Exception:
                clk_tck = 100
            boot = _boot_time_unix()
            if boot is None:
                return None
            return boot + ticks / float(clk_tck)
        # macOS fallback
        r = subprocess.run(
            ["ps", "-o", "etime=", "-p", str(pid)],
            capture_output=True, text=True, check=False, timeout=2,
        )
        if r.returncode != 0 or not r.stdout.strip():
            return None
        etime = r.stdout.strip()
        # Parse [[dd-]hh:]mm:ss without losing hour/day forms.
        parts = etime.split(":")
        try:
            if len(parts) == 2:
                minutes, seconds = (int(parts[0]), int(parts[1]))
                total = minutes * 60 + seconds
            elif len(parts) == 3:
                first, minutes_s, seconds_s = parts
                minutes, seconds = int(minutes_s), int(seconds_s)
                if "-" in first:
                    days_s, hours_s = first.split("-", 1)
                    total = (
                        int(days_s) * 86400
                        + int(hours_s) * 3600
                        + minutes * 60
                        + seconds
                    )
                else:
                    total = int(first) * 3600 + minutes * 60 + seconds
            else:
                return None
        except ValueError:
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


def _parse_cost_from_durable_stdout(path: str | None) -> float | None:
    if not path:
        return None
    p = Path(path)
    if not p.is_file():
        return None
    try:
        payload = json.loads(p.read_text(encoding="utf-8", errors="replace"))
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(payload, dict) or "total_cost_usd" not in payload:
        return None
    try:
        value = float(payload.get("total_cost_usd"))
    except (TypeError, ValueError):
        return None
    return value if math.isfinite(value) and value >= 0 else None


def _parse_token_usage_from_durable_stdout(path: str | None) -> dict[str, int] | None:
    """Recover provider-reported token usage from one durable JSON envelope.

    Token telemetry is operational evidence, not engineering truth. Unknown
    token usage is tolerated unless the operator explicitly enabled a token
    ceiling for the job.
    """
    if not path:
        return None
    p = Path(path)
    if not p.is_file():
        return None
    try:
        payload = json.loads(p.read_text(encoding="utf-8", errors="replace"))
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(payload, dict):
        return None
    usage = payload.get("usage")
    if not isinstance(usage, dict):
        return None

    keys = {
        "input_tokens": "input_tokens",
        "output_tokens": "output_tokens",
        "cache_read_tokens": "cache_read_input_tokens",
        "cache_creation_tokens": "cache_creation_input_tokens",
    }
    recovered: dict[str, int] = {}
    observed = False
    for out_key, source_key in keys.items():
        if source_key not in usage:
            recovered[out_key] = 0
            continue
        try:
            value = int(usage.get(source_key) or 0)
        except (TypeError, ValueError):
            return None
        if value < 0:
            return None
        recovered[out_key] = value
        observed = True
    return recovered if observed else None


def _account_attempt_cost(
    conn: sqlite3.Connection,
    *,
    job_id: int,
    attempt_id: str,
    cost_usd: float,
    returncode: int | None = None,
    status_value: str = "COMPLETED",
    input_tokens: int = 0,
    output_tokens: int = 0,
    cache_read_tokens: int = 0,
    cache_creation_tokens: int = 0,
    tokens_known: bool = False,
) -> float:
    """Account one durable semantic attempt exactly once by attempt identity.

    Cost and token telemetry share the same attempt-identity fence so retries
    can never double-count either resource.
    """
    if not math.isfinite(float(cost_usd)) or float(cost_usd) < 0:
        raise RuntimeError("semantic attempt cost is not a finite non-negative value")
    usage_values = (
        int(input_tokens),
        int(output_tokens),
        int(cache_read_tokens),
        int(cache_creation_tokens),
    )
    if any(value < 0 for value in usage_values):
        raise RuntimeError("semantic attempt token usage must be non-negative")
    conn.execute("BEGIN IMMEDIATE")
    attempt = conn.execute(
        "SELECT * FROM semantic_attempts WHERE attempt_id=? AND job_id=?",
        (attempt_id, int(job_id)),
    ).fetchone()
    if attempt is None:
        conn.rollback()
        raise RuntimeError(f"semantic attempt missing: {attempt_id}")
    already = bool(int(attempt["cost_accounted"] or 0))
    if not already:
        conn.execute(
            """UPDATE semantic_attempts SET status=?, completed_at=?,
               returncode=?, cost_usd=?, cost_accounted=1,
               input_tokens=?, output_tokens=?, cache_read_tokens=?,
               cache_creation_tokens=?, tokens_known=?
               WHERE attempt_id=?""",
            (
                status_value,
                time.time(),
                returncode,
                float(cost_usd),
                *usage_values,
                1 if tokens_known else 0,
                attempt_id,
            ),
        )
        conn.execute(
            """UPDATE jobs SET
               total_cost_usd=total_cost_usd+?,
               total_input_tokens=total_input_tokens+?,
               total_output_tokens=total_output_tokens+?,
               total_cache_read_tokens=total_cache_read_tokens+?,
               total_cache_creation_tokens=total_cache_creation_tokens+?,
               updated_at=?
               WHERE id=?""",
            (
                float(cost_usd),
                *usage_values,
                time.time(),
                int(job_id),
            ),
        )
    else:
        conn.execute(
            """UPDATE semantic_attempts SET status=?,
               completed_at=COALESCE(completed_at, ?),
               returncode=COALESCE(returncode, ?)
               WHERE attempt_id=?""",
            (status_value, time.time(), returncode, attempt_id),
        )
    conn.commit()
    row = conn.execute("SELECT total_cost_usd FROM jobs WHERE id=?", (int(job_id),)).fetchone()
    return float(row[0] or 0.0)


def _recover_stale_running(conn: sqlite3.Connection) -> int:
    """Recover dead RUNNING ownership without losing model-cost evidence."""
    recovered = 0
    rows = conn.execute(
        "SELECT * FROM jobs WHERE status='RUNNING' ORDER BY id"
    ).fetchall()
    for row in rows:
        pid = row["worker_pid"]
        started_at = float(row["worker_started_at"]) if row["worker_started_at"] else None
        if _pid_alive(pid, started_at):
            continue

        attempt_id = str(row["worker_attempt_id"] or "")
        if attempt_id:
            attempt = conn.execute(
                "SELECT * FROM semantic_attempts WHERE attempt_id=? AND job_id=?",
                (attempt_id, int(row["id"])),
            ).fetchone()
            if attempt is None:
                conn.execute(
                    """UPDATE jobs SET status='QUARANTINED', last_error=?,
                       worker_pid=NULL, worker_started_at=NULL, worker_role=NULL,
                       next_attempt_at=0, updated_at=? WHERE id=?""",
                    ("semantic attempt ownership missing during crash recovery",
                     time.time(), row["id"]),
                )
                conn.commit()
                continue
            if not bool(int(attempt["cost_accounted"] or 0)):
                recovered_cost = _parse_cost_from_durable_stdout(attempt["stdout_path"])
                if recovered_cost is None:
                    # Cost telemetry could not be recovered. With an active
                    # operator cost ceiling, continuing could exceed the declared
                    # budget, so fail operationally closed instead of assuming
                    # zero. Without a ceiling the attempt is accounted at zero
                    # (marked COST_UNKNOWN) and the run resumes — telemetry loss
                    # alone must not stop unattended progress.
                    if float(row["max_total_cost_usd"] or 0) > 0:
                        conn.execute(
                            """UPDATE semantic_attempts SET status='COST_UNKNOWN',
                               completed_at=? WHERE attempt_id=?""",
                            (time.time(), attempt_id),
                        )
                        conn.execute(
                            """UPDATE jobs SET status='QUARANTINED', last_error=?,
                               worker_pid=NULL, worker_started_at=NULL, worker_role=NULL,
                               next_attempt_at=0, updated_at=? WHERE id=?""",
                            ("semantic worker died and model cost could not be recovered "
                             "from durable structured output while a cost ceiling is active",
                             time.time(), row["id"]),
                        )
                        conn.commit()
                        continue
                    recovered_cost = 0.0
                recovered_usage = _parse_token_usage_from_durable_stdout(
                    attempt["stdout_path"]
                )
                if int(row["max_total_tokens"] or 0) > 0 and recovered_usage is None:
                    conn.execute(
                        """UPDATE semantic_attempts SET status='TOKENS_UNKNOWN',
                           completed_at=? WHERE attempt_id=?""",
                        (time.time(), attempt_id),
                    )
                    conn.execute(
                        """UPDATE jobs SET status='QUARANTINED',
                           last_error=?, last_failure_class='usage_unknown',
                           last_failure_reason=?,
                           worker_pid=NULL, worker_started_at=NULL,
                           worker_role=NULL, next_attempt_at=0, updated_at=?
                           WHERE id=?""",
                        (
                            "semantic worker died and token usage could not be recovered "
                            "while a token ceiling is enabled",
                            "token_usage_unknown_during_crash_recovery",
                            time.time(),
                            row["id"],
                        ),
                    )
                    conn.commit()
                    continue
                usage = recovered_usage or {}
                _account_attempt_cost(
                    conn,
                    job_id=int(row["id"]),
                    attempt_id=attempt_id,
                    cost_usd=recovered_cost,
                    returncode=None,
                    status_value="RECOVERED",
                    input_tokens=int(usage.get("input_tokens", 0)),
                    output_tokens=int(usage.get("output_tokens", 0)),
                    cache_read_tokens=int(usage.get("cache_read_tokens", 0)),
                    cache_creation_tokens=int(usage.get("cache_creation_tokens", 0)),
                    tokens_known=recovered_usage is not None,
                )

        conn.execute(
            """
            UPDATE jobs SET
              status='QUEUED',
              worker_pid=NULL,
              worker_started_at=NULL,
              worker_role=NULL,
              worker_attempt_id=NULL,
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
    max_infra_failures: int | None = None,
    max_transient_failures: int | None = None,
    max_transient_recovery_cycles: int | None = None,
    max_total_cost_usd: float | None = None,
    max_total_tokens: int | None = None,
    max_wall_seconds: int | None = None,
    runtime_generation: str | None = None,
) -> dict[str, Any]:
    """Create or refresh one enqueued run's operational envelope.

    Runtime-generation binding: every enqueue binds the job to the runtime
    generation performing the enqueue (``runtime_generation()`` unless an
    explicit value is supplied). A re-enqueue is an explicit operator
    re-registration, so it rebinds to the enqueuing generation. Execution
    later refuses to run a job bound to a different generation (see
    ``run_one``); only re-enqueue or ``resume`` migrates a run.

    Envelope values use ``None`` as the "unspecified" sentinel:

      * NEW job row: unspecified fields take the engine defaults
        (failure ceilings 3/8/2; budget ceilings OFF = 0).
      * EXISTING job row: unspecified fields PRESERVE the configured
        values. A repeated enqueue must never widen or remove an already
        configured operational ceiling merely because the caller omitted
        it — default sentinels are not operator intent. Only an explicit
        value (including an explicit <= 0, which disables that ceiling)
        overwrites the configured envelope.

    Budget ceilings are OFF unless deliberately funded: a value <= 0 disables
    that ceiling. Long PROGRAMs must not hit accidental global stop lines;
    protection against stuck execution comes from semantic pass fuses,
    no-progress detection, pass/repair caps, and failure-class retry policy.
    The CLI resolves packet-declared envelopes (risk_budget.max_runtime_seconds
    -> wall clock) before calling this; explicit operator flags win.
    """
    state_mod.validate_run_id(run_id)
    repo = str(Path(canonical_repo).resolve(strict=False))
    db = db_path or default_db_path()
    now = time.time()
    eff_generation = (
        runtime_generation if runtime_generation is not None
        else _current_runtime_generation()
    )
    # Idempotent enqueue: create a new QUEUED row, or update only safe
    # configuration on an existing row. Operational state, backoff and worker
    # ownership are never rewritten by a repeated enqueue.
    with _connect(db) as conn:
        existing = conn.execute(
            "SELECT * FROM jobs WHERE repo=? AND run_id=?", (repo, run_id)
        ).fetchone()
        if existing is not None:
            # Retired enrollments are durable historical evidence and must not
            # be silently reactivated by a re-enqueue; the architecture does
            # not expose a reactivation command by design. Fail closed with an
            # explicit diagnostic so an operator cannot accidentally rewrite
            # a retired historical record through normal enqueue traffic.
            if str(existing["status"] or "") == "RETIRED":
                out = dict(existing)
                out.update({
                    "schema": SCHEMA,
                    "ok": False,
                    "db_path": str(db),
                    "enqueue_refused": True,
                    "reason": "enqueue_refuses_retired_enrollment",
                })
                return out
            if str(existing["status"] or "") == "RUNNING":
                existing_generation = str(existing["runtime_generation"] or "")
                if not existing_generation or str(eff_generation) != existing_generation:
                    out = dict(existing)
                    out.update({
                        "schema": SCHEMA,
                        "ok": False,
                        "db_path": str(db),
                        "enqueue_refused": True,
                        "reason": (
                            "running_job_runtime_generation_unbound"
                            if not existing_generation
                            else "cannot_change_runtime_generation_while_running"
                        ),
                    })
                    return out
            def _keep(field: str, supplied: Any, default: Any) -> Any:
                return supplied if supplied is not None else existing[field]
            eff_infra = _keep("max_infra_failures", max_infra_failures, 3)
            eff_transient = _keep("max_transient_failures", max_transient_failures, 8)
            eff_cycles = _keep(
                "max_transient_recovery_cycles", max_transient_recovery_cycles, 2
            )
            eff_cost = _keep("max_total_cost_usd", max_total_cost_usd, 0.0)
            eff_tokens = _keep("max_total_tokens", max_total_tokens, 0)
            eff_wall = _keep("max_wall_seconds", max_wall_seconds, 0)
            eff_legacy_ambiguous = int(existing["legacy_budget_ambiguous"] or 0)
            if (
                max_total_cost_usd is not None
                and max_total_tokens is not None
                and max_wall_seconds is not None
            ):
                eff_legacy_ambiguous = 0
        else:
            eff_infra = max_infra_failures if max_infra_failures is not None else 3
            eff_transient = max_transient_failures if max_transient_failures is not None else 8
            eff_cycles = (
                max_transient_recovery_cycles
                if max_transient_recovery_cycles is not None else 2
            )
            eff_cost = max_total_cost_usd if max_total_cost_usd is not None else 0.0
            eff_tokens = max_total_tokens if max_total_tokens is not None else 0
            eff_wall = max_wall_seconds if max_wall_seconds is not None else 0
            eff_legacy_ambiguous = 0
        conn.execute(
            """
            INSERT INTO jobs
              (repo, run_id, runner, status, infra_failures,
               max_infra_failures, transient_failures, max_transient_failures,
               transient_recovery_cycles, max_transient_recovery_cycles,
               total_cost_usd, next_attempt_at,
               max_total_cost_usd, max_total_tokens, max_wall_seconds,
               runtime_generation, legacy_budget_ambiguous, created_at, updated_at)
            VALUES (?, ?, ?, 'QUEUED', 0, ?, 0, ?, 0, ?, 0, 0, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(repo, run_id) DO UPDATE SET
              runner=excluded.runner,
              max_infra_failures=excluded.max_infra_failures,
              max_transient_failures=excluded.max_transient_failures,
              max_transient_recovery_cycles=excluded.max_transient_recovery_cycles,
              max_total_cost_usd=excluded.max_total_cost_usd,
              max_total_tokens=excluded.max_total_tokens,
              max_wall_seconds=excluded.max_wall_seconds,
              runtime_generation=excluded.runtime_generation,
              legacy_budget_ambiguous=excluded.legacy_budget_ambiguous,
              updated_at=excluded.updated_at
            """,
            (
                repo,
                run_id,
                runner,
                int(eff_infra),
                int(eff_transient),
                int(eff_cycles),
                float(eff_cost),
                int(eff_tokens),
                int(eff_wall),
                str(eff_generation),
                int(eff_legacy_ambiguous),
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
    state_mod.validate_run_id(run_id)
    repo = str(Path(canonical_repo).resolve(strict=False))
    db = db_path or default_db_path()
    if not Path(db).expanduser().is_file():
        row = None
    else:
        try:
            with _connect_readonly(db) as conn:
                row = conn.execute(
                    "SELECT * FROM jobs WHERE repo=? AND run_id=?", (repo, run_id)
                ).fetchone()
        except sqlite3.Error as exc:
            return {
                "schema": SCHEMA,
                "ok": False,
                "repo": repo,
                "run_id": run_id,
                "status": "LEDGER_UNREADABLE",
                "db_path": str(db),
                "error": type(exc).__name__,
            }
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


def _run_git_readonly(repo: Path, args: list[str], *, timeout: int = 10) -> dict[str, Any]:
    """Run one bounded read-only Git observation for operator visibility."""
    try:
        r = subprocess.run(
            ["git", "-C", str(repo), *args],
            capture_output=True,
            text=True,
            check=False,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {
            "ok": False,
            "returncode": None,
            "stdout": "",
            "stderr": f"{type(exc).__name__}: {exc}",
        }
    return {
        "ok": r.returncode == 0,
        "returncode": int(r.returncode),
        "stdout": r.stdout,
        "stderr": r.stderr,
    }


def _registered_worktree_paths(repo: Path) -> tuple[set[str], str | None]:
    probe = _run_git_readonly(repo, ["worktree", "list", "--porcelain"])
    if not probe["ok"]:
        return set(), (
            f"git_worktree_list_failed:rc={probe['returncode']}:"
            f"{str(probe['stderr']).strip()[:500]}"
        )
    paths: set[str] = set()
    for raw in str(probe["stdout"]).splitlines():
        if raw.startswith("worktree "):
            paths.add(
                str(Path(raw[len("worktree "):].strip()).resolve(strict=False))
            )
    return paths, None


def _worktree_visibility(
    canonical_repo: Path,
    path: Path,
    *,
    registered_paths: set[str],
    registry_error: str | None,
) -> dict[str, Any]:
    """Return read-only identity/cleanliness evidence for one Loop worktree."""
    resolved = Path(path).resolve(strict=False)
    out: dict[str, Any] = {
        "path": str(resolved),
        "exists": resolved.is_dir(),
        "registered": False,
        "head": None,
        "branch": None,
        "cleanliness": "missing" if not resolved.is_dir() else "unknown",
    }
    if registry_error:
        out["registry_error"] = registry_error
    if not resolved.is_dir():
        return out
    out["registered"] = str(resolved) in registered_paths
    if not out["registered"]:
        return out

    head = _run_git_readonly(resolved, ["rev-parse", "HEAD"])
    if head["ok"]:
        out["head"] = str(head["stdout"]).strip() or None

    branch = _run_git_readonly(resolved, ["branch", "--show-current"])
    if branch["ok"]:
        out["branch"] = str(branch["stdout"]).strip() or None

    status = _run_git_readonly(resolved, ["status", "--porcelain"])
    if status["ok"]:
        out["cleanliness"] = (
            "dirty" if str(status["stdout"]).strip() else "clean"
        )
    return out


def _candidate_diff_visibility(
    canonical_repo: Path,
    *,
    baseline_sha: str,
    candidate_sha: str,
    max_paths: int = 100,
) -> dict[str, Any]:
    """Summarize the exact local candidate diff without publishing or mutating it."""
    out: dict[str, Any] = {
        "available": False,
        "baseline_sha": baseline_sha or None,
        "candidate_sha": candidate_sha or None,
        "files_changed": None,
        "added_lines": None,
        "removed_lines": None,
        "binary_files": None,
        "changed_paths": [],
        "changed_paths_truncated": False,
    }
    if not baseline_sha or not candidate_sha:
        out["reason"] = "baseline_or_candidate_missing"
        return out

    paths_probe = _run_git_readonly(
        canonical_repo,
        ["diff", "--name-only", "--no-renames", baseline_sha, candidate_sha],
        timeout=20,
    )
    if not paths_probe["ok"]:
        out["reason"] = "git_diff_name_only_failed"
        out["error"] = str(paths_probe["stderr"]).strip()[-1000:]
        return out

    paths = [
        line.strip()
        for line in str(paths_probe["stdout"]).splitlines()
        if line.strip()
    ]
    out["files_changed"] = len(paths)
    out["changed_paths"] = paths[:max_paths]
    out["changed_paths_truncated"] = len(paths) > max_paths

    numstat = _run_git_readonly(
        canonical_repo,
        ["diff", "--numstat", "--no-renames", baseline_sha, candidate_sha],
        timeout=20,
    )
    if not numstat["ok"]:
        out["reason"] = "git_diff_numstat_failed"
        out["error"] = str(numstat["stderr"]).strip()[-1000:]
        return out

    added = 0
    removed = 0
    binary_files = 0
    for line in str(numstat["stdout"]).splitlines():
        parts = line.split("\t", 2)
        if len(parts) < 3:
            continue
        if parts[0] == "-" or parts[1] == "-":
            binary_files += 1
            continue
        try:
            added += int(parts[0])
            removed += int(parts[1])
        except ValueError:
            continue
    out.update({
        "available": True,
        "added_lines": added,
        "removed_lines": removed,
        "binary_files": binary_files,
    })
    return out


def _core_snapshot(repo: Path, run_id: str) -> dict[str, Any]:
    """Read protocol state plus read-only operator visibility evidence."""
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

    # Approval metadata is optional for visibility because historical status
    # reads must not gain a new authority requirement merely to show paths.
    approval_doc: dict[str, Any] = {}
    approval_path = run_dir / "APPROVAL.json"
    visibility_errors: list[str] = []
    if approval_path.exists():
        try:
            raw_approval = json.loads(approval_path.read_text(encoding="utf-8"))
            if isinstance(raw_approval, dict):
                approval_doc = raw_approval
            else:
                visibility_errors.append("APPROVAL.json:not_object")
        except (OSError, json.JSONDecodeError) as exc:
            visibility_errors.append(
                f"APPROVAL.json:{type(exc).__name__}"
            )

    state = loaded["STATE.json"]
    receipt = loaded["BUILD_RECEIPT.json"]
    verdict = loaded["REVIEW_VERDICT.json"]
    program = state.get("program") or {}

    baseline_sha = str(
        receipt.get("baseline_sha")
        or approval_doc.get("baseline_sha")
        or state.get("spec_baseline_sha")
        or ""
    )
    candidate_sha = str(
        receipt.get("candidate_sha")
        or state.get("last_candidate_sha")
        or ""
    )
    candidate_branch = str(
        receipt.get("candidate_branch")
        or approval_doc.get("candidate_branch")
        or ""
    )

    registered_paths, registry_error = _registered_worktree_paths(repo)
    builder_path = (
        repo / ".worktrees" / "ownframework-loop" / run_id / "builder"
    )
    reviewer_path = (
        repo / ".worktrees" / "ownframework-loop" / run_id / "reviewer"
    )
    builder = _worktree_visibility(
        repo,
        builder_path,
        registered_paths=registered_paths,
        registry_error=registry_error,
    )
    reviewer = _worktree_visibility(
        repo,
        reviewer_path,
        registered_paths=registered_paths,
        registry_error=registry_error,
    )

    canonical_head_probe = _run_git_readonly(repo, ["rev-parse", "HEAD"])
    canonical_branch_probe = _run_git_readonly(repo, ["branch", "--show-current"])
    canonical_head = (
        str(canonical_head_probe["stdout"]).strip()
        if canonical_head_probe["ok"]
        else None
    )
    canonical_branch = (
        str(canonical_branch_probe["stdout"]).strip()
        if canonical_branch_probe["ok"]
        else None
    )

    candidate_diff = _candidate_diff_visibility(
        repo,
        baseline_sha=baseline_sha,
        candidate_sha=candidate_sha,
    )
    if registry_error:
        visibility_errors.append(registry_error)

    return {
        "core_snapshot_ok": not errors,
        "core_snapshot_errors": errors,
        "visibility_errors": visibility_errors,
        "core_state": state.get("state"),
        "last_candidate_sha": state.get("last_candidate_sha"),
        "build_pass_count": state.get("build_pass_count"),
        "review_pass_count": state.get("review_pass_count"),
        "repair_round": state.get("repair_round"),
        "current_checkpoints": program.get("current_checkpoints") or [],
        "last_build_candidate_sha": receipt.get("candidate_sha"),
        "last_review_verdict": verdict.get("verdict"),
        "last_reviewed_candidate_sha": verdict.get("candidate_sha_reviewed"),
        "baseline_sha": baseline_sha or None,
        "candidate_branch": candidate_branch or None,
        "canonical_checkout": {
            "path": str(repo.resolve(strict=False)),
            "head": canonical_head,
            "branch": canonical_branch,
        },
        "candidate_is_canonical_head": bool(
            candidate_sha and canonical_head and candidate_sha == canonical_head
        ),
        "builder_worktree": builder,
        "reviewer_worktree": reviewer,
        "candidate_diff": candidate_diff,
    }

def _job_dict(row: sqlite3.Row, db: Path) -> dict[str, Any]:
    d = dict(row)
    d.update({"schema": SCHEMA, "ok": True, "db_path": str(db)})
    latest_id = str(d.get("latest_attempt_id") or "")
    d["attempt_history"] = []
    try:
        if latest_id:
            with _connect_readonly(db) as attempt_conn:
                attempt_conn.row_factory = sqlite3.Row
                ar = attempt_conn.execute(
                    "SELECT * FROM semantic_attempts WHERE attempt_id=?",
                    (latest_id,),
                ).fetchone()
            if ar is not None:
                d["latest_attempt"] = dict(ar)
        with _connect_readonly(db) as history_conn:
            history_conn.row_factory = sqlite3.Row
            history = history_conn.execute(
                """SELECT attempt_id, role, status, started_at, completed_at,
                          worker_pid, returncode, cost_usd, cost_accounted,
                          input_tokens, output_tokens, cache_read_tokens,
                          cache_creation_tokens, tokens_known,
                          failure_class, failure_reason, stdout_path, stderr_path
                   FROM semantic_attempts
                   WHERE job_id=?
                   ORDER BY started_at DESC
                   LIMIT 5""",
                (int(row["id"]),),
            ).fetchall()
        d["attempt_history"] = [dict(item) for item in history]
    except sqlite3.Error as exc:
        d["attempt_snapshot_error"] = type(exc).__name__
    if int(d.get("legacy_budget_ambiguous") or 0):
        d["legacy_budget_warning"] = (
            "historical $25/8h resource tuple is ambiguous; preserved until "
            "the operator explicitly re-registers all three resource ceilings"
        )
    d["observed_total_tokens"] = (
        int(d.get("total_input_tokens") or 0)
        + int(d.get("total_output_tokens") or 0)
        + int(d.get("total_cache_read_tokens") or 0)
        + int(d.get("total_cache_creation_tokens") or 0)
    )
    if str(d.get("status") or "") == "QUARANTINED":
        d["quarantine_reason"] = (
            d.get("last_failure_reason")
            or d.get("last_failure_class")
            or d.get("last_error")
        )
    if str(d.get("status") or "") == "RETIRED":
        # Retired enrollments preserve their original quarantine context as
        # durable historical evidence; surface the prior failure class for
        # operators auditing a retired enrollment. runtime_generation is
        # preserved verbatim (including legacy empty / UNBOUND).
        d["retired_enrollment"] = {
            "previous_quarantine_reason": (
                d.get("last_failure_reason")
                or d.get("last_failure_class")
                or d.get("last_error")
            ),
            "preserved_runtime_generation": str(d.get("runtime_generation") or ""),
        }
    now = time.time()
    worker_started = float(d.get("worker_started_at") or 0.0)
    execution_started = float(d.get("execution_started_at") or 0.0)
    updated_at = float(d.get("updated_at") or 0.0)
    d["worker_elapsed_seconds"] = (
        max(0.0, now - worker_started)
        if str(d.get("status") or "") == "RUNNING" and worker_started > 0
        else 0.0
    )
    d["execution_elapsed_seconds"] = (
        max(0.0, now - execution_started) if execution_started > 0 else 0.0
    )
    d["seconds_since_job_update"] = (
        max(0.0, now - updated_at) if updated_at > 0 else 0.0
    )
    log_activity: dict[str, Any] = {}
    for label, key in (("stdout", "worker_stdout_path"), ("stderr", "worker_stderr_path")):
        raw_path = str(d.get(key) or "")
        if not raw_path:
            continue
        try:
            st = Path(raw_path).stat()
            log_activity[label] = {
                "path": raw_path,
                "bytes": int(st.st_size),
                "mtime": float(st.st_mtime),
                "seconds_since_write": max(0.0, now - float(st.st_mtime)),
            }
        except OSError:
            log_activity[label] = {"path": raw_path, "unavailable": True}
    d["worker_log_activity"] = log_activity
    try:
        packet_path = state_mod.run_dir(
            Path(str(row["repo"])), str(row["run_id"])
        ) / "WORK_PACKET.md"
        pmeta, _ = packet_mod.parse_packet_file(packet_path)
        rb = pmeta.get("risk_budget") or {}
        d["packet_max_pass_runtime_seconds"] = int(
            rb.get("max_pass_runtime_seconds") or 0
        ) if isinstance(rb, dict) else 0
        d["packet_max_runtime_seconds"] = int(
            rb.get("max_runtime_seconds") or 0
        ) if isinstance(rb, dict) else 0
    except Exception:
        d["packet_max_pass_runtime_seconds"] = 0
        d["packet_max_runtime_seconds"] = 0
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


def _terminate_group(proc: subprocess.Popen[str], grace_seconds: float = 3.0) -> None:
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


@dataclass
class RunnerResult:
    ok: bool
    returncode: int
    cost_usd: float
    stdout: str
    stderr: str
    pid: int | None = None
    cost_known: bool = True
    input_tokens: int = 0
    output_tokens: int = 0
    cache_read_tokens: int = 0
    cache_creation_tokens: int = 0
    tokens_known: bool = False


class ClaudeCodeRunner:
    """One fresh non-interactive Claude Code process per semantic pass."""

    runner_id = "claude-code"

    def preflight(self) -> RunnerReadiness:
        """Check executable availability without starting a semantic attempt."""
        pinned = os.environ.get("OFLOOP_CLAUDE_BIN", "").strip()
        if pinned:
            p = Path(pinned).expanduser().resolve(strict=False)
            if not (p.is_file() and os.access(p, os.X_OK)):
                return RunnerReadiness(
                    False,
                    classification="configuration",
                    reason="pinned_runner_unavailable",
                    detail=f"commissioned Claude binary unavailable: {p}",
                    retry_after_seconds=0.0,
                )
            version = _claude_cli_version(str(p))
            if version is None:
                return RunnerReadiness(
                    False,
                    classification="configuration",
                    reason="runner_version_unproven",
                    detail="commissioned Claude Code version could not be proven",
                    retry_after_seconds=0.0,
                )
            if version < MIN_SECURE_CLAUDE_CODE_VERSION:
                return RunnerReadiness(
                    False,
                    classification="configuration",
                    reason="runner_secure_sandbox_version_too_old",
                    detail=(
                        "Claude Code "
                        + ".".join(str(x) for x in version)
                        + " is older than the required secure unattended-worker baseline "
                        + ".".join(str(x) for x in MIN_SECURE_CLAUDE_CODE_VERSION)
                    ),
                    retry_after_seconds=0.0,
                )
            return RunnerReadiness(True)

        discovered = shutil.which("claude")
        if discovered:
            p = Path(discovered).expanduser().resolve(strict=False)
            if p.is_file() and os.access(p, os.X_OK):
                version = _claude_cli_version(str(p))
                if version is None:
                    return RunnerReadiness(
                        False,
                        classification="configuration",
                        reason="runner_version_unproven",
                        detail="discovered Claude Code version could not be proven",
                        retry_after_seconds=0.0,
                    )
                if version < MIN_SECURE_CLAUDE_CODE_VERSION:
                    return RunnerReadiness(
                        False,
                        classification="configuration",
                        reason="runner_secure_sandbox_version_too_old",
                        detail=(
                            "Claude Code "
                            + ".".join(str(x) for x in version)
                            + " is older than the required secure unattended-worker baseline "
                            + ".".join(str(x) for x in MIN_SECURE_CLAUDE_CODE_VERSION)
                        ),
                        retry_after_seconds=0.0,
                    )
                return RunnerReadiness(True)

        return RunnerReadiness(
            False,
            classification="environment_wait",
            reason="runner_not_discoverable",
            detail="Claude CLI not currently discoverable on service PATH",
            retry_after_seconds=30.0,
        )

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
              "or exact-SHA assessment (reviewer). The supplied semantic artifact may sit "
              "outside restricted built-in file-tool scope; write that artifact with sandboxed "
              "Bash when needed. Do not widen access. Then stop.\n\n"
            + payload
        )

        claude_bin = os.environ.get("OFLOOP_CLAUDE_BIN", "claude")
        extra = shlex.split(os.environ.get("OFLOOP_CLAUDE_EXTRA_ARGS", ""))
        _validate_claude_extra_args(extra)
        # Tool availability is product authority, not an environment-tunable
        # convenience. Reviewers structurally lack Edit/Write/NotebookEdit.
        allowed_tools = (
            CLAUDE_BUILDER_TOOLS if role == "builder" else CLAUDE_REVIEWER_TOOLS
        )
        canonical_repo = Path(
            str(work_order.get("canonical_repo") or "")
        ).resolve(strict=False)
        semantic_path = Path(
            str(work_order.get("semantic_path") or "")
        ).resolve(strict=False)
        secure_settings = _semantic_worker_settings(
            canonical_repo=canonical_repo,
            run_id=str(work_order.get("run_id") or ""),
            role=role,
            worktree=worktree,
            semantic_path=semantic_path,
        )
        # --restricted is the native shared-machine isolation boundary.
        # dontAsk + explicit --allowedTools means there are no human permission
        # prompts: capabilities inside the sealed set run, everything else is
        # denied. The Bash sandbox auto-allows contained commands.
        #
        # Pipe the prompt via stdin. Passing it as an argv string lets Claude
        # CLI mis-parse leading `---` (YAML frontmatter in the role file) as
        # an unknown option. stdin is the supported, robust path.
        cmd = [
            claude_bin,
            "-p",
            "--output-format",
            "json",
            "--restricted",
            "--permission-mode",
            "dontAsk",
            "--no-chrome",
            "--no-session-persistence",
            "--strict-mcp-config",
            "--mcp-config",
            "{}",
            "--plugin-dir",
            str(_source_root()),
            *extra,
            "--settings",
            json.dumps(secure_settings, separators=(",", ":"), sort_keys=True),
            "--tools",
            allowed_tools,
            "--allowedTools",
            allowed_tools,
        ]
        if durable_files is not None:
            out_path, err_path = durable_files
            out_path.parent.mkdir(parents=True, exist_ok=True)
            stdout_fh = out_path.open("w", encoding="utf-8")
            stderr_fh = err_path.open("w", encoding="utf-8")
        else:
            stdout_fh = subprocess.PIPE
            stderr_fh = subprocess.PIPE

        worker_env = runtime_env.hermetic_subprocess_env(
            Path(str(work_order.get("canonical_repo") or "")).resolve(strict=False),
            str(work_order.get("run_id") or ""),
            role,
        )
        # Claude-native subprocess scrub: keep model authentication available to
        # the Claude process itself while stripping Anthropic/cloud credentials
        # from Bash children. This also forces filesystem isolation to remain on.
        worker_env["CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"] = "1"

        proc = subprocess.Popen(
            cmd,
            cwd=str(worktree),
            stdin=subprocess.PIPE,
            stdout=stdout_fh,
            stderr=stderr_fh,
            text=True,
            start_new_session=True,
            env=worker_env,
        )
        # Persist worker ownership BEFORE the child produces any output. If
        # anything between here and a successful communicate() raises, the
        # worker is terminated and reaped so we never leak an unowned Claude
        # process.
        if on_start is not None:
            try:
                on_start(int(proc.pid), role)
            except Exception:
                _terminate_group(proc)
                if durable_files is not None:
                    stdout_fh.close()  # type: ignore[union-attr]
                    stderr_fh.close()  # type: ignore[union-attr]
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
        except BaseException:
            _terminate_group(proc)
            if durable_files is not None:
                stdout_fh.close()  # type: ignore[union-attr]
                stderr_fh.close()  # type: ignore[union-attr]
            raise

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
                cost_known=False,
            )

        cost = 0.0
        cost_known = False
        input_tokens = 0
        output_tokens = 0
        cache_read_tokens = 0
        cache_creation_tokens = 0
        tokens_known = False
        parsed: dict[str, Any] | None = None
        try:
            data = json.loads(stdout_data or "")
            if isinstance(data, dict):
                parsed = data
                if "total_cost_usd" in data:
                    candidate_cost = float(data.get("total_cost_usd"))
                    if math.isfinite(candidate_cost) and candidate_cost >= 0:
                        cost = candidate_cost
                        cost_known = True
                usage = data.get("usage")
                if isinstance(usage, dict):
                    token_keys = (
                        ("input_tokens", "input_tokens"),
                        ("output_tokens", "output_tokens"),
                        ("cache_read_tokens", "cache_read_input_tokens"),
                        ("cache_creation_tokens", "cache_creation_input_tokens"),
                    )
                    values: dict[str, int] = {}
                    usage_valid = False
                    for target, source in token_keys:
                        if source not in usage:
                            values[target] = 0
                            continue
                        candidate = int(usage.get(source) or 0)
                        if candidate < 0:
                            raise ValueError("negative token usage")
                        values[target] = candidate
                        usage_valid = True
                    if usage_valid:
                        input_tokens = values["input_tokens"]
                        output_tokens = values["output_tokens"]
                        cache_read_tokens = values["cache_read_tokens"]
                        cache_creation_tokens = values["cache_creation_tokens"]
                        tokens_known = True
        except (json.JSONDecodeError, TypeError, ValueError):
            parsed = None

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
            ok=bool(claude_ok and (parsed is not None)),
            returncode=int(proc.returncode or 0),
            cost_usd=cost,
            stdout=(stdout_data or "")[-65536:],
            stderr=(stderr_data or "")[-65536:],
            pid=int(proc.pid),
            cost_known=cost_known,
            input_tokens=input_tokens,
            output_tokens=output_tokens,
            cache_read_tokens=cache_read_tokens,
            cache_creation_tokens=cache_creation_tokens,
            tokens_known=tokens_known,
        )


@dataclass(frozen=True)
class RunnerReadiness:
    ready: bool
    classification: str = "ready"
    reason: str = "ready"
    detail: str = ""
    retry_after_seconds: float = 30.0


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


def _runner_preflight(name: str) -> RunnerReadiness:
    runner = _runner(name)
    probe = getattr(runner, "preflight", None)
    if probe is None:
        return RunnerReadiness(True)
    result = probe()
    if isinstance(result, RunnerReadiness):
        return result
    raise RuntimeError(
        f"runner {name!r} returned invalid preflight result: {type(result).__name__}"
    )


def _classify_runner_failure(result: RunnerResult) -> tuple[str, str]:
    """Classify operational runner failure without interpreting engineering truth.

    Classification only selects retry/quarantine policy. It can never alter
    packet authority, candidate identity, checkpoint state, or review verdict.
    """
    text = f"{result.stderr}\n{result.stdout}".lower()
    if result.returncode == 124 or "runner timed out" in text:
        return "timeout", "runner_timeout"

    configuration_markers = (
        "not authenticated",
        "authentication failed",
        "invalid api key",
        "invalid_api_key",
        "unauthorized",
        "forbidden",
        "login required",
        "command not found",
        "no such file or directory",
    )
    if result.returncode in {126, 127} or any(
        marker in text for marker in configuration_markers
    ):
        return "configuration", "runner_configuration_failure"

    transient_markers = (
        "rate limit",
        "rate-limit",
        "too many requests",
        "429",
        "overloaded",
        "capacity",
        "temporarily unavailable",
        "service unavailable",
        "bad gateway",
        "gateway timeout",
        "502",
        "503",
        "504",
        "connection reset",
        "connection refused",
        "network error",
        "network unavailable",
        "econnreset",
        "etimedout",
        "upstream",
    )
    if any(marker in text for marker in transient_markers):
        return "transient", "runner_transient_failure"
    return "runner", "runner_unclassified_failure"


def _classify_exception(exc: BaseException) -> tuple[str, str]:
    if isinstance(exc, dispatch_mod.DispatchError):
        return "invariant", "dispatch_refused"
    if isinstance(exc, (FileNotFoundError, PermissionError)):
        return "configuration", type(exc).__name__
    if isinstance(exc, (TimeoutError, ConnectionError)):
        return "transient", type(exc).__name__
    message = str(exc).lower()
    if (
        "not registered" in message
        or "runner prompt missing" in message
        or "prepared worktree missing" in message
    ):
        return "configuration", type(exc).__name__
    return "supervisor", type(exc).__name__


def _apply_failure_policy(
    conn: sqlite3.Connection,
    *,
    job_id: int,
    failure_class: str,
    failure_reason: str,
    detail: str,
    total_cost_usd: float | None = None,
) -> dict[str, Any]:
    """Apply operational retry policy while leaving engineering state untouched."""
    row = conn.execute("SELECT * FROM jobs WHERE id=?", (int(job_id),)).fetchone()
    if row is None:
        raise RuntimeError(f"supervisor job missing during failure policy: {job_id}")

    immediate = failure_class in {
        "configuration",
        "invariant",
        "usage_unknown",
        "timeout_usage_unknown",
    }
    infra_failures = int(row["infra_failures"] or 0)
    transient_failures = int(row["transient_failures"] or 0)
    transient_recovery_cycles = int(row["transient_recovery_cycles"] or 0)

    if failure_class == "transient":
        transient_failures += 1
        ceiling = int(row["max_transient_failures"] or 0)
        max_cycles = int(row["max_transient_recovery_cycles"] or 0)
        threshold_hit = ceiling > 0 and transient_failures >= ceiling
        if threshold_hit and transient_recovery_cycles < max_cycles:
            # Open a bounded provider circuit instead of requiring an operator
            # resume. Cost/token/wall-clock ledgers are preserved and keep
            # bounding the run; only the transient streak is cooled down.
            transient_recovery_cycles += 1
            transient_failures = 0
            quarantined = False
            backoff = 600.0
        else:
            quarantined = threshold_hit
            streak = transient_failures
            backoff = min(300.0, float(5 * (2 ** max(0, streak - 1))))
    elif immediate:
        # A hard non-transient refusal ends any active transient streak.
        transient_failures = 0
        quarantined = True
        streak = 1
        backoff = 0.0
    else:
        infra_failures += 1
        ceiling = int(row["max_infra_failures"] or 0)
        quarantined = ceiling > 0 and infra_failures >= ceiling
        streak = infra_failures
        backoff = min(300.0, float(5 * (2 ** max(0, streak - 1))))

    status_value = "QUARANTINED" if quarantined else "BACKOFF"
    next_attempt = 0.0 if quarantined else time.time() + backoff
    _update_job(
        conn,
        int(job_id),
        status_value=status_value,
        infra_failures=infra_failures,
        transient_failures=transient_failures,
        transient_recovery_cycles=transient_recovery_cycles,
        total_cost_usd=total_cost_usd,
        last_error=detail[-4000:],
        last_failure_class=failure_class,
        last_failure_reason=failure_reason,
        next_attempt_at=next_attempt,
    )
    return {
        "status": status_value,
        "failure_class": failure_class,
        "failure_reason": failure_reason,
        "infra_failures": infra_failures,
        "transient_failures": transient_failures,
        "transient_recovery_cycles": transient_recovery_cycles,
        "max_transient_recovery_cycles": int(row["max_transient_recovery_cycles"] or 0),
        "circuit_opened": bool(
            failure_class == "transient"
            and not quarantined
            and backoff == 600.0
            and transient_failures == 0
        ),
        "backoff_seconds": 0.0 if quarantined else backoff,
    }


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
          updated_at=?
        WHERE id=?
        """,
        (os.getpid(), now, now, row["id"]),
    )
    conn.commit()
    return conn.execute("SELECT * FROM jobs WHERE id=?", (row["id"],)).fetchone()


def _reserve_semantic_attempt(
    conn: sqlite3.Connection,
    *,
    job: sqlite3.Row,
    role: str,
) -> tuple[str, tuple[Path, Path]]:
    attempt_id = uuid.uuid4().hex
    durable_files = worker_log_paths(
        Path(str(job["repo"])),
        str(job["run_id"]),
        int(job["id"]),
        role,
        attempt_id,
    )
    now = time.time()
    conn.execute(
        """INSERT INTO semantic_attempts
           (attempt_id, job_id, role, status, started_at, stdout_path, stderr_path)
           VALUES (?, ?, ?, 'RESERVED', ?, ?, ?)""",
        (attempt_id, int(job["id"]), role, now,
         str(durable_files[0]), str(durable_files[1])),
    )
    cur = conn.execute(
        """UPDATE jobs SET worker_attempt_id=?, latest_attempt_id=?,
           worker_stdout_path=?, worker_stderr_path=?, updated_at=?
           WHERE id=? AND status='RUNNING'""",
        (attempt_id, attempt_id, str(durable_files[0]), str(durable_files[1]),
         now, int(job["id"])),
    )
    if cur.rowcount != 1:
        conn.rollback()
        raise RuntimeError("semantic attempt reservation lost RUNNING ownership")
    conn.commit()
    return attempt_id, durable_files


def _set_worker_pid(
    conn: sqlite3.Connection,
    job_id: int,
    pid: int,
    role: str,
    *,
    out_path: Path | None = None,
    err_path: Path | None = None,
    attempt_id: str | None = None,
) -> None:
    started = time.time()
    cur = conn.execute(
        """
        UPDATE jobs SET worker_pid=?, worker_started_at=?, worker_role=?,
          worker_stdout_path=?, worker_stderr_path=?,
          worker_attempt_id=COALESCE(?, worker_attempt_id), updated_at=?
        WHERE id=? AND status='RUNNING'
        """,
        (
            int(pid),
            started,
            role,
            str(out_path) if out_path else None,
            str(err_path) if err_path else None,
            attempt_id,
            started,
            job_id,
        ),
    )
    if cur.rowcount != 1:
        conn.rollback()
        raise RuntimeError("worker PID persistence lost RUNNING ownership")
    if attempt_id:
        a = conn.execute(
            """UPDATE semantic_attempts SET status='RUNNING', worker_pid=?,
               started_at=? WHERE attempt_id=? AND job_id=?""",
            (int(pid), started, attempt_id, int(job_id)),
        )
        if a.rowcount != 1:
            conn.rollback()
            raise RuntimeError("semantic attempt row missing during worker start")
    conn.commit()


def _update_job(
    conn: sqlite3.Connection,
    job_id: int,
    *,
    status_value: str,
    infra_failures: int | None = None,
    transient_failures: int | None = None,
    transient_recovery_cycles: int | None = None,
    total_cost_usd: float | None = None,
    last_error: str | None = None,
    last_failure_class: str | None = None,
    last_failure_reason: str | None = None,
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
          transient_failures=?,
          transient_recovery_cycles=?,
          total_cost_usd=?,
          last_error=?,
          last_failure_class=?,
          last_failure_reason=?,
          next_attempt_at=?,
          worker_pid=NULL,
          worker_started_at=NULL,
          worker_role=NULL,
          worker_attempt_id=NULL,
          updated_at=?
        WHERE id=?
        """,
        (
            status_value,
            int(row["infra_failures"] if infra_failures is None else infra_failures),
            int(row["transient_failures"] if transient_failures is None else transient_failures),
            int(row["transient_recovery_cycles"] if transient_recovery_cycles is None else transient_recovery_cycles),
            float(row["total_cost_usd"] if total_cost_usd is None else total_cost_usd),
            last_error,
            last_failure_class,
            last_failure_reason,
            float(row["next_attempt_at"] if next_attempt_at is None else next_attempt_at),
            time.time(),
            job_id,
        ),
    )
    conn.commit()


def _ensure_execution_started(conn: sqlite3.Connection, job_id: int) -> float:
    """Start the operational wall clock only when semantic execution can run."""
    now = time.time()
    conn.execute(
        """UPDATE jobs SET execution_started_at=COALESCE(execution_started_at, ?),
           updated_at=? WHERE id=?""",
        (now, now, int(job_id)),
    )
    conn.commit()
    row = conn.execute(
        "SELECT execution_started_at FROM jobs WHERE id=?", (int(job_id),)
    ).fetchone()
    if row is None or row[0] is None:
        raise RuntimeError("failed to persist execution_started_at")
    return float(row[0])


def run_one(*, db_path: Path | None = None, timeout_seconds: int = 0) -> dict[str, Any]:
    """Execute at most one semantic BUILD/REVIEW action."""
    db = db_path or default_db_path()
    with _connect(db) as conn:
        job = _take_next_job(conn)
        if job is None:
            return {"schema": SCHEMA, "ok": True, "action": "IDLE", "db_path": str(db)}

        # RUNTIME-GENERATION CONTRACT. A job binds the generation that
        # enrolled it; executing it under a different generation is a
        # silent runtime switch of a sealed run and fails closed toward
        # quarantine. Legacy rows with no recorded binding are ambiguous
        # unfinished executions and fail closed; migration to a new generation
        # is an explicit operator act: re-enqueue or resume.
        bound_generation = str(job["runtime_generation"] or "")
        try:
            serving_generation = _current_runtime_generation()
        except Exception as exc:
            _update_job(
                conn,
                job["id"],
                status_value="QUARANTINED",
                last_error=(
                    "serving runtime generation could not be proven; refusing "
                    f"semantic execution: {type(exc).__name__}: {exc}"
                ),
                last_failure_class="runtime_generation_unavailable",
                last_failure_reason="runtime_generation_unavailable",
                next_attempt_at=0,
            )
            return {
                "schema": SCHEMA,
                "ok": False,
                "action": "QUARANTINED",
                "job_id": job["id"],
                "reason": "runtime_generation_unavailable",
                "bound_runtime_generation": bound_generation,
            }
        if bound_generation and bound_generation != serving_generation:
            _update_job(
                conn,
                job["id"],
                status_value="QUARANTINED",
                last_error=(
                    "runtime generation mismatch: job bound to "
                    f"{bound_generation}, serving runtime is "
                    f"{serving_generation}; refusing silent generation "
                    "switch — operator migration required "
                    "(supervisor resume rebinds the run)"
                ),
                last_failure_class="runtime_generation_mismatch",
                last_failure_reason="runtime_generation_mismatch",
                next_attempt_at=0,
            )
            return {
                "schema": SCHEMA,
                "ok": False,
                "action": "QUARANTINED",
                "job_id": job["id"],
                "reason": "runtime_generation_mismatch",
                "bound_runtime_generation": bound_generation,
                "serving_runtime_generation": serving_generation,
            }
        if not bound_generation:
            _update_job(
                conn,
                job["id"],
                status_value="QUARANTINED",
                last_error=(
                    "runtime generation is unbound for an unfinished legacy job; "
                    "refusing implicit adoption under a new serving runtime — "
                    "operator re-enqueue/resume is required"
                ),
                last_failure_class="runtime_generation_unbound",
                last_failure_reason="runtime_generation_unbound",
                next_attempt_at=0,
            )
            return {
                "schema": SCHEMA,
                "ok": False,
                "action": "QUARANTINED",
                "job_id": job["id"],
                "reason": "runtime_generation_unbound",
                "bound_runtime_generation": "",
                "serving_runtime_generation": serving_generation,
            }

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
                    transient_failures=0,
                    transient_recovery_cycles=0,
                    last_error=None,
                    last_failure_class=None,
                    last_failure_reason=None,
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

            readiness = _runner_preflight(str(job["runner"]))
            if not readiness.ready:
                if readiness.classification == "environment_wait":
                    retry_after = max(5.0, float(readiness.retry_after_seconds))
                    _update_job(
                        conn,
                        job["id"],
                        status_value="BACKOFF",
                        last_error=readiness.detail,
                        last_failure_class=readiness.classification,
                        last_failure_reason=readiness.reason,
                        next_attempt_at=time.time() + retry_after,
                    )
                    return {
                        "schema": SCHEMA,
                        "ok": True,
                        "action": "RUNNER_WAIT",
                        "job_id": job["id"],
                        "reason": readiness.reason,
                        "retry_after_seconds": retry_after,
                        "semantic_attempt_created": False,
                        "execution_clock_started": False,
                    }
                policy = _apply_failure_policy(
                    conn,
                    job_id=int(job["id"]),
                    failure_class=readiness.classification,
                    failure_reason=readiness.reason,
                    detail=readiness.detail,
                    total_cost_usd=float(job["total_cost_usd"] or 0.0),
                )
                return {
                    "schema": SCHEMA,
                    "ok": False,
                    "action": policy["status"],
                    "job_id": job["id"],
                    "reason": readiness.reason,
                    "semantic_attempt_created": False,
                    "execution_clock_started": False,
                    **policy,
                }

            started_at = _ensure_execution_started(conn, int(job["id"]))
            elapsed = max(0.0, time.time() - started_at)
            max_wall = int(job["max_wall_seconds"] or 0)
            max_cost = float(job["max_total_cost_usd"] or 0.0)
            spent = float(job["total_cost_usd"] or 0.0)
            max_tokens = int(job["max_total_tokens"] or 0)
            spent_tokens = (
                int(job["total_input_tokens"] or 0)
                + int(job["total_output_tokens"] or 0)
                + int(job["total_cache_read_tokens"] or 0)
                + int(job["total_cache_creation_tokens"] or 0)
            )
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

            if max_tokens > 0 and spent_tokens >= max_tokens:
                _update_job(
                    conn,
                    job["id"],
                    status_value="QUARANTINED",
                    last_error=(
                        f"operational token ceiling reached: "
                        f"{spent_tokens} >= {max_tokens}"
                    ),
                    last_failure_class="usage_ceiling",
                    last_failure_reason="token_ceiling",
                    next_attempt_at=0,
                )
                return {
                    "schema": SCHEMA,
                    "ok": False,
                    "action": "QUARANTINED",
                    "job_id": job["id"],
                    "reason": "token_ceiling",
                    "observed_total_tokens": spent_tokens,
                    "max_total_tokens": max_tokens,
                }

            role = str(work_order.get("role") or "builder")
            attempt_id, durable_files = _reserve_semantic_attempt(
                conn, job=job, role=role
            )

            packet_path = state_mod.run_dir(
                Path(str(job["repo"])), str(job["run_id"])
            ) / "WORK_PACKET.md"
            packet_meta, _ = packet_mod.parse_packet_file(packet_path)
            semantic_timeout_seconds = resolve_semantic_timeout(
                packet_meta, timeout_seconds
            )
            # The whole-run wall ceiling must constrain the pass actually
            # launched, not only the between-pass checks: a pass started
            # with one minute of budget left may not run for its full
            # packet timeout. Clamp the pass timeout to the remaining wall
            # budget whenever a wall ceiling is funded.
            if max_wall > 0:
                remaining_wall = max(0, int(max_wall - elapsed))
                semantic_timeout_seconds = min(
                    semantic_timeout_seconds, remaining_wall
                )

            result = _runner(str(job["runner"])).run(
                work_order,
                timeout_seconds=semantic_timeout_seconds,
                on_start=lambda pid, started_role: _set_worker_pid(
                    conn,
                    int(job["id"]),
                    pid,
                    started_role,
                    out_path=durable_files[0],
                    err_path=durable_files[1],
                    attempt_id=attempt_id,
                ),
                durable_files=durable_files,
            )
            if not result.cost_known:
                # Cost-telemetry fail-closed applies only while an operator
                # cost ceiling is actually active. Without a ceiling, unknown
                # cost cannot breach any declared budget; the attempt is
                # recorded COST_UNKNOWN at zero and execution continues so an
                # unattended PROGRAM is not stopped by telemetry loss.
                conn.execute(
                    """UPDATE semantic_attempts SET status='COST_UNKNOWN',
                       completed_at=?, returncode=? WHERE attempt_id=? AND job_id=?""",
                    (time.time(), int(result.returncode), attempt_id, int(job["id"])),
                )
                conn.commit()
                if float(job["max_total_cost_usd"] or 0) > 0:
                    _update_job(
                        conn,
                        job["id"],
                        status_value="QUARANTINED",
                        last_error=(
                            "semantic worker completed without a trustworthy finite "
                            "total_cost_usd while a cost ceiling is active; refusing "
                            "to assume zero cost"
                        ),
                        last_failure_class=(
                            "timeout_usage_unknown"
                            if int(result.returncode) == 124
                            else "usage_unknown"
                        ),
                        last_failure_reason=(
                            "runner_timeout_cost_unknown"
                            if int(result.returncode) == 124
                            else "model_cost_unknown"
                        ),
                        next_attempt_at=0,
                    )
                    return {
                        "schema": SCHEMA,
                        "ok": False,
                        "action": "QUARANTINED",
                        "job_id": job["id"],
                        "reason": "model_cost_unknown",
                        "attempt_id": attempt_id,
                    }

            if int(job["max_total_tokens"] or 0) > 0 and not result.tokens_known:
                conn.execute(
                    """UPDATE semantic_attempts SET status='TOKENS_UNKNOWN',
                       completed_at=?, returncode=?,
                       failure_class='usage_unknown',
                       failure_reason='token_usage_unknown'
                       WHERE attempt_id=? AND job_id=?""",
                    (
                        time.time(),
                        int(result.returncode),
                        attempt_id,
                        int(job["id"]),
                    ),
                )
                conn.commit()
                _update_job(
                    conn,
                    job["id"],
                    status_value="QUARANTINED",
                    last_error=(
                        "semantic worker completed without trustworthy token usage "
                        "while a token ceiling is enabled"
                    ),
                    last_failure_class="usage_unknown",
                    last_failure_reason="token_usage_unknown",
                    next_attempt_at=0,
                )
                return {
                    "schema": SCHEMA,
                    "ok": False,
                    "action": "QUARANTINED",
                    "job_id": job["id"],
                    "reason": "token_usage_unknown",
                    "attempt_id": attempt_id,
                }

            new_cost = _account_attempt_cost(
                conn,
                job_id=int(job["id"]),
                attempt_id=attempt_id,
                cost_usd=float(result.cost_usd),
                returncode=int(result.returncode),
                status_value="COMPLETED",
                input_tokens=result.input_tokens,
                output_tokens=result.output_tokens,
                cache_read_tokens=result.cache_read_tokens,
                cache_creation_tokens=result.cache_creation_tokens,
                tokens_known=result.tokens_known,
            )
            if not result.ok:
                failure_class, failure_reason = _classify_runner_failure(result)
                detail = (
                    f"runner rc={result.returncode}: "
                    f"{result.stderr or result.stdout}"
                )[-4000:]
                conn.execute(
                    """UPDATE semantic_attempts SET
                       failure_class=?, failure_reason=?
                       WHERE attempt_id=? AND job_id=?""",
                    (
                        failure_class,
                        failure_reason,
                        attempt_id,
                        int(job["id"]),
                    ),
                )
                conn.commit()
                policy = _apply_failure_policy(
                    conn,
                    job_id=int(job["id"]),
                    failure_class=failure_class,
                    failure_reason=failure_reason,
                    detail=detail,
                    total_cost_usd=new_cost,
                )
                return {
                    "schema": SCHEMA,
                    "ok": False,
                    "action": policy["status"],
                    "job_id": job["id"],
                    "returncode": result.returncode,
                    "cost_usd": result.cost_usd,
                    **policy,
                }

            finalizer_timeout: int | None = None
            if max_wall > 0:
                elapsed_after_worker = max(0.0, time.time() - started_at)
                remaining_after_worker = int(max_wall - elapsed_after_worker)
                if remaining_after_worker <= 0:
                    _update_job(
                        conn,
                        job["id"],
                        status_value="QUARANTINED",
                        total_cost_usd=new_cost,
                        last_error=(
                            "operational wall-clock ceiling exhausted after semantic "
                            "worker completed; semantic artifact preserved for "
                            "zero-cost replay after explicit operator action"
                        ),
                        last_failure_class="usage_ceiling",
                        last_failure_reason="wall_clock_ceiling_before_finalization",
                        next_attempt_at=0,
                    )
                    return {
                        "schema": SCHEMA,
                        "ok": False,
                        "action": "QUARANTINED",
                        "job_id": job["id"],
                        "reason": "wall_clock_ceiling_before_finalization",
                        "elapsed_seconds": elapsed_after_worker,
                        "max_wall_seconds": max_wall,
                        "semantic_artifact_preserved": True,
                    }
                finalizer_timeout = remaining_after_worker

            if finalizer_timeout is None:
                # Preserve the stable single-argument dispatch surface for
                # unfunded/unbounded runs and test/adapter implementations.
                finalized = dispatch_mod.finalize_work_order(work_order)
            else:
                finalized = dispatch_mod.finalize_work_order(
                    work_order, timeout_seconds=finalizer_timeout
                )
            _update_job(
                conn,
                job["id"],
                status_value="QUEUED",
                infra_failures=0,
                transient_failures=0,
                transient_recovery_cycles=0,
                total_cost_usd=new_cost,
                last_error=None,
                last_failure_class=None,
                last_failure_reason=None,
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
            # Completed semantic attempts are accounted transactionally by
            # attempt identity. If an exception happened before completion,
            # stale-worker recovery will inspect the durable attempt/output;
            # never synthesize cost from output digests here.
            current_cost_row = conn.execute(
                "SELECT total_cost_usd FROM jobs WHERE id=?", (job["id"],)
            ).fetchone()
            total_attempted_cost = float(
                (current_cost_row[0] if current_cost_row is not None else 0.0) or 0.0
            )
            failure_class, failure_reason = _classify_exception(exc)
            detail = f"{type(exc).__name__}: {exc}"[-4000:]
            policy = _apply_failure_policy(
                conn,
                job_id=int(job["id"]),
                failure_class=failure_class,
                failure_reason=failure_reason,
                detail=detail,
                total_cost_usd=total_attempted_cost,
            )
            return {
                "schema": SCHEMA,
                "ok": False,
                "action": policy["status"],
                "job_id": job["id"],
                "error": str(exc),
                **policy,
            }


def serve(
    *,
    db_path: Path | None = None,
    poll_seconds: float = 2.0,
    timeout_seconds: int = 0,
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
    "RunnerReadiness",
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
    max_transient_failures: int | None = None,
    max_transient_recovery_cycles: int | None = None,
    max_total_cost_usd: float | None = None,
    max_total_tokens: int | None = None,
    max_wall_seconds: int | None = None,
    reset_execution_started_at: bool = False,
) -> dict[str, Any]:
    """Clear operational quarantine and reset operational counters only.

    Does NOT alter STATE.json, packet scope, candidate SHA, review verdict, or
    engineering pass counters. Cumulative observed cost is preserved.

    The wall-clock origin is PRESERVED by default: resuming a run that
    exhausted its funded wall budget must not silently grant a fresh
    budget — the ceiling check would quarantine the run again, and
    silently resetting the clock would make the funded wall ceiling
    unenforceable across resumes. A fresh clock is an explicit budget
    decision: pass ``reset_execution_started_at=True`` (operator
    ``--reset-execution-clock``) — normally together with a widened
    ``max_wall_seconds``.

    Runtime-generation migration: resume is an explicit operator act, so
    it also REBINDS the job to the resuming runtime's generation. This is
    the clean migration path after a deliberate runtime replacement: the
    run was quarantined on the generation mismatch, the operator inspects
    and resumes, and the run continues under the new generation with the
    rebinding recorded. The previous binding is reported in the result.

    Returns the updated job dict (or NOT_ENQUEUED).
    """
    state_mod.validate_run_id(run_id)
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
    # Retired enrollments are durable historical evidence; ``supervisor resume``
    # must not accidentally resurrect them. The architecture intentionally
    # exposes no reactivation command — preserved historical enrollments must
    # stay preserved. Fail closed with a precise retirement diagnostic that
    # operators can grep, distinct from the generic QUARANTINED-required one.
    if str(existing["status"] or "") == "RETIRED":
        result = _job_dict(existing, db)
        result.update({
            "ok": False,
            "resumed": False,
            "reason": "resume_refuses_retired_enrollment",
        })
        return result
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
        "transient_failures=0",
        "transient_recovery_cycles=0",
        "next_attempt_at=0",
        "last_error=NULL",
        "last_failure_class=NULL",
        "last_failure_reason=NULL",
        "worker_pid=NULL",
        "worker_started_at=NULL",
        "worker_role=NULL",
        "updated_at=?",
    ]
    params: list[Any] = [now]
    if max_infra_failures is not None:
        sets.append("max_infra_failures=?")
        params.append(int(max_infra_failures))
    if max_transient_failures is not None:
        sets.append("max_transient_failures=?")
        params.append(int(max_transient_failures))
    if max_transient_recovery_cycles is not None:
        sets.append("max_transient_recovery_cycles=?")
        params.append(int(max_transient_recovery_cycles))
    if max_total_cost_usd is not None:
        sets.append("max_total_cost_usd=?")
        params.append(float(max_total_cost_usd))
    if max_total_tokens is not None:
        sets.append("max_total_tokens=?")
        params.append(int(max_total_tokens))
    if max_wall_seconds is not None:
        sets.append("max_wall_seconds=?")
        params.append(int(max_wall_seconds))
    if (
        max_total_cost_usd is not None
        and max_total_tokens is not None
        and max_wall_seconds is not None
    ):
        sets.append("legacy_budget_ambiguous=0")
    if reset_execution_started_at:
        sets.append("execution_started_at=?")
        params.append(now)
    # Explicit operator migration: rebind the run to the resuming
    # runtime's generation (recorded; previous binding reported back).
    previous_generation = str(existing["runtime_generation"] or "")
    sets.append("runtime_generation=?")
    params.append(_current_runtime_generation())
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
    result["runtime_generation_previous"] = previous_generation
    return result


def retire(
    *,
    canonical_repo: Path,
    run_id: str,
    db_path: Path | None = None,
) -> dict[str, Any]:
    """Non-destructively retire a historical supervisor enrollment.

    Retirement is a SUPERVISOR-LEDGER lifecycle transition only. It MUST NOT
    modify the target repository, .ownframework-loop run artifacts, WORK_PACKET.md,
    STATE.json, EVENTS.log, APPROVAL.json, scratch evidence, candidate refs,
    runtime_generation, semantic-attempt history, or cost/token/retry evidence.

    Supported transition: ``QUARANTINED -> RETIRED`` only. ``QUEUED``,
    ``BACKOFF``, ``RUNNING``, ``DONE``, and ``RETIRED`` are refused because
    retirement is not a reactivation, migration, or completion.

    A live or ambiguous semantic worker / attempt refuses retirement; the
    enrollment must first drain through the normal supervisor lifecycle.

    A retired row's existing ``runtime_generation`` value (including an empty
    legacy ``UNBOUND`` value) is preserved. Retirement never masquerades as
    migration or successful completion. The retired enrollment is excluded
    from runtime-generation dependency checks at install/refresh time, so
    normal future supervisor replacement no longer requires the migration
    override to bypass durable historical evidence.

    ``supervisor resume`` continues to refuse ``RETIRED`` rows because it
    requires the source status to be exactly ``QUARANTINED``. The architecture
    intentionally does not expose a reactivation command — preserved historical
    enrollments must stay preserved.
    """
    state_mod.validate_run_id(run_id)
    repo = str(Path(canonical_repo).resolve(strict=False))
    db = db_path or default_db_path()
    now = time.time()
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
            "retired": False,
            "reason": "not_enqueued",
        }
    current_status = str(existing["status"] or "")
    if current_status != "QUARANTINED":
        result = _job_dict(existing, db)
        result.update({
            "ok": False,
            "retired": False,
            "reason": (
                "retire_requires_quarantined"
                if current_status in ("QUEUED", "BACKOFF", "RUNNING")
                else "retire_refuses_terminal_enrollment"
            ),
        })
        return result
    # An unresolved semantic-attempt row is ambiguous paid/model execution
    # evidence even when the job-level PID is empty or dead. Retirement must
    # not hide it behind a historical status before crash reconciliation has
    # proven the attempt terminal.
    with _connect_readonly(db) as attempt_conn:
        attempt_rows = attempt_conn.execute(
            "SELECT attempt_id,status,worker_pid FROM semantic_attempts "
            "WHERE job_id=? ORDER BY started_at DESC",
            (int(existing["id"]),),
        ).fetchall()
    unresolved_attempts = [
        row for row in attempt_rows
        if str(row["status"] or "") not in TERMINAL_SEMANTIC_ATTEMPT_STATUSES
    ]
    if unresolved_attempts:
        result = _job_dict(existing, db)
        result.update({
            "ok": False,
            "retired": False,
            "reason": "retire_refuses_unresolved_semantic_attempt",
            "unresolved_attempts": [
                {
                    "attempt_id": str(row["attempt_id"] or ""),
                    "status": str(row["status"] or ""),
                    "worker_pid": row["worker_pid"],
                }
                for row in unresolved_attempts[:8]
            ],
        })
        return result

    # Live job ownership also refuses retirement. The operator must wait for
    # the worker to drain through the normal supervisor lifecycle before
    # retiring the enrollment.
    if existing["worker_pid"] and _pid_alive(
        int(existing["worker_pid"]),
        float(existing["worker_started_at"]) if existing["worker_started_at"] else None,
    ):
        result = _job_dict(existing, db)
        result.update({
            "ok": False,
            "retired": False,
            "reason": "quarantined_worker_still_alive",
        })
        return result
    # Preserve runtime_generation verbatim, including legacy empty / UNBOUND.
    preserved_runtime_generation = str(existing["runtime_generation"] or "")
    preserved_cost_usd = float(existing["total_cost_usd"] or 0.0)
    preserved_attempt_id = str(existing["latest_attempt_id"] or "")
    with _connect(db) as conn:
        cur = conn.execute(
            """UPDATE jobs SET
                 status='RETIRED',
                 updated_at=?
               WHERE repo=? AND run_id=? AND status='QUARANTINED'""",
            (now, repo, run_id),
        )
        if cur.rowcount != 1:
            # Concurrent transition lost; refuse without rewriting state.
            row = conn.execute(
                "SELECT * FROM jobs WHERE repo=? AND run_id=?", (repo, run_id)
            ).fetchone()
            result = _job_dict(row, db) if row is not None else {
                "schema": SCHEMA, "ok": False, "status": "NOT_ENQUEUED",
            }
            result.update({
                "ok": False,
                "retired": False,
                "reason": "retire_lost_quarantine_race",
            })
            return result
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
            "retired": False,
        }
    # Defensive: confirm the preservation contract held end-to-end.
    actual_runtime_generation = str(row["runtime_generation"] or "")
    if actual_runtime_generation != preserved_runtime_generation:
        raise RuntimeError(
            "retire must preserve runtime_generation verbatim; "
            f"expected {preserved_runtime_generation!r}, got {actual_runtime_generation!r}"
        )
    if float(row["total_cost_usd"] or 0.0) != preserved_cost_usd:
        raise RuntimeError("retire must preserve total_cost_usd verbatim")
    if str(row["latest_attempt_id"] or "") != preserved_attempt_id:
        raise RuntimeError("retire must preserve latest_attempt_id verbatim")
    result = _job_dict(row, db)
    result["retired"] = True
    result["runtime_generation_preserved"] = preserved_runtime_generation
    return result
