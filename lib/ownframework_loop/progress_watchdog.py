"""No-observable-progress watchdog for durable semantic passes.

A semantic worker can occupy a pass slot for the entire
``max_pass_runtime_seconds`` while producing zero observable durable
progress: 0 input/output tokens, 0 stdout bytes past any startup
banner, no tool-result files, no candidate-branch advance. The wallclock
deadline that Loop already enforces catches the failure at the end of
the budget — but a 30-minute slot consumed by an inert provider turns a
defect into a 30-minute stall per attempt, every retry.

This module is the deterministic detector for that class of stall. It
defines a small, fail-closed observable-progress signature computed
from per-attempt durable IO surfaces, plus a bounded watchdog window
derived from the packet's ``max_pass_runtime_seconds``. The supervisor
consults this module on each tick to force-terminate a worker whose
observable progress has not advanced within the window.

The detector is GENERIC. It makes no claim about which provider model
is "fast" or "responsive"; it only observes the same durable surfaces
that Loop already owns (worker stdout, worker stderr, worktree HEAD,
worktree file mtimes). Long legitimate passes that produce sustained
durable IO advance are NEVER terminated; only passes whose observable
durable IO stops advancing within the bounded window are.

The computation is purely read-only and additive; this module never
mutates durable supervisor state. The supervisor owns the recovery
action.
"""
from __future__ import annotations

import os
import sqlite3
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

SCHEMA = "ownframework-loop-progress-watchdog/v1"

# Watchdog window derivation:
#   window = max(DEFAULT_WATCHDOG_WINDOW_SECONDS, max_pass_runtime_seconds // WATCHDOG_WINDOW_FRACTION)
#
# The window is the bounded no-progress grace period the watchdog grants
# before force-terminating an inflight worker. It MUST stay below the
# packet's max_pass_runtime_seconds (the wallclock deadline already enforces
# that ceiling) and MUST stay well above a provider's natural silent-thinking
# windows. Empirical Claude (MiniMax-M3) thinking pauses in production can
# exceed 5 minutes for non-trivial packets without producing observable IO;
# a 180s window produced false-positive kills of normal healthy workers
# (live canary job 82 attempt 11999c96 was force-terminated at t=361s after
# a legitimate scratch-output advance at t=180s). The window floor is
# therefore raised to 600s, which still gives the watchdog 6+ minutes of
# lead time over a 10-minute budget and 12+ minutes over a 30-minute
# budget while tolerating realistic long thinking phases.
DEFAULT_WATCHDOG_WINDOW_SECONDS = 600
WATCHDOG_WINDOW_FRACTION = 4  # window = max(DEFAULT, budget // FRACTION)
WATCHDOG_MIN_BUDGET_FOR_FRACTION = 60


@dataclass(frozen=True)
class Signature:
    """A compact observable-progress snapshot for one semantic worker.

    Two signatures compare equal iff every observed surface matches; an
    advance in any surface is observable progress. The fields are
    deliberately coarse — millisecond mtime is too noisy across
    filesystems; integer seconds suffice.
    """
    stdout_size: int = -1
    stdout_mtime: int = -1
    stderr_size: int = -1
    stderr_mtime: int = -1
    worktree_head: str = ""
    worktree_max_mtime: int = -1
    worktree_file_count: int = -1

    @classmethod
    def from_row(cls, row: sqlite3.Row | None) -> "Signature":
        if row is None:
            return cls()
        # Production watchdog ticks use the inline construction (with
        # explicit progress_signature_* column names) at the tick site;
        # this helper exists so external callers can reconstruct a
        # Signature from the persisted jobs row without knowing the
        # column-naming convention.  Use the prefixed column names
        # exactly as written in the SELECT/UPDATE statements.
        def _opt_int(value):
            if value is None or value == "":
                return -1
            try:
                return int(value)
            except (TypeError, ValueError):
                return -1

        return cls(
            stdout_size=_opt_int(row["progress_signature_stdout_size"]),
            stdout_mtime=_opt_int(row["progress_signature_stdout_mtime"]),
            stderr_size=_opt_int(row["progress_signature_stderr_size"]),
            stderr_mtime=_opt_int(row["progress_signature_stderr_mtime"]),
            worktree_head=str(row["progress_signature_worktree_head"] or ""),
            worktree_max_mtime=_opt_int(row["progress_signature_worktree_max_mtime"]),
            worktree_file_count=_opt_int(row["progress_signature_worktree_file_count"]),
        )


def signature_advanced(before: Signature, after: Signature) -> bool:
    """True iff at least one observable surface advanced.

    A signature is advanced when ANY of:
      - worker stdout size or mtime moved forward
      - worker stderr size or mtime moved forward
      - worktree HEAD changed
      - worktree max-mtime moved forward OR file-count changed
    """
    if after.stdout_size > before.stdout_size:
        return True
    if after.stdout_mtime > before.stdout_mtime:
        return True
    if after.stderr_size > before.stderr_size:
        return True
    if after.stderr_mtime > before.stderr_mtime:
        return True
    if before.worktree_head and after.worktree_head and after.worktree_head != before.worktree_head:
        return True
    if after.worktree_max_mtime > before.worktree_max_mtime:
        return True
    if before.worktree_file_count >= 0 and after.worktree_file_count >= 0:
        if after.worktree_file_count != before.worktree_file_count:
            return True
    return False


def _stat(path: Path) -> tuple[int, int] | None:
    """Return (size, int_mtime) or None when the file does not exist."""
    try:
        st = path.stat()
    except (FileNotFoundError, OSError):
        return None
    return (int(st.st_size), int(st.st_mtime))


def compute_signature(
    *,
    stdout_path: Path | None,
    stderr_path: Path | None,
    worktree: Path | None,
    worktree_head_resolver=None,
) -> Signature:
    """Compute one Signature for the given surfaces.

    ``worktree_head_resolver`` is an optional callable returning a string
    HEAD SHA for the worktree. It MUST be cheap and side-effect free; the
    supervisor passes a real resolver that calls `git -C worktree rev-parse
    --verify HEAD` or returns "" on any failure.
    """
    out_size = out_mtime = -1
    err_size = err_mtime = -1
    if stdout_path is not None:
        s = _stat(stdout_path)
        if s is not None:
            out_size, out_mtime = s
    if stderr_path is not None:
        s = _stat(stderr_path)
        if s is not None:
            err_size, err_mtime = s

    head = ""
    max_mtime = -1
    file_count = -1
    if worktree is not None and worktree.exists() and worktree.is_dir():
        try:
            if worktree_head_resolver is not None:
                head = str(worktree_head_resolver(worktree) or "")
        except Exception:
            head = ""
        # Sample mtimes: use os.scandir with stat for efficiency.
        # Cap traversal to keep this trivially cheap; the value is
        # monotonic — added files increase count AND the new file's
        # mtime will move max_mtime forward.
        try:
            count = 0
            local_max = -1
            # Bounded walk: 4096 entries should cover any small repo.
            # Bookkeeping that does NOT count as semantic progress:
            #   - .git/               (git internal HEAD/index, etc.)
            #   - .claude/            (Claude session ping/state)
            #   - .worktrees/         (nested worktrees)
            #   - node_modules/, __pycache__/, .venv/, .pytest_cache/,
            #     .ruff_cache/        (runtime caches)
            # Claude progress output is written under
            # ``.ownframework-loop/<run-id>/scratch/<role>/<pass-N>/``
            # — that path is the real semantic-progress signal, and it
            # would be hidden if we filtered all of ``.ownframework-loop``.
            # We therefore descend into the worktree root EXCLUDING the
            # bookkeeping directories above, and ADDITIONALLY walk the
            # scratch paths that contain Claude's actual output.
            SKIP_TOP_LEVEL_DIRS = {
                ".git",
                ".claude",
                ".ownframework-loop",
                ".worktrees",
                "node_modules",
                "__pycache__",
                ".pytest_cache",
                ".venv",
                ".ruff_cache",
            }
            # Bookkeeping filenames under .ownframework-loop/ that move
            # on every supervisor transition and would create false
            # progress if counted.
            BOOKKEEPING_FILE_BASENAMES = {
                "STATE.json",
                "EVENTS.log",
                "DISPATCH_LOCK",
                "LOCK",
                "BUILD_CLAIM_LOCK",
                "REVIEW_CLAIM_LOCK",
                "BINDING_LOCK",
                "START_LOCK",
                "SUPERVISOR_LIFECYCLE.lock",
                "WORK_PACKET.md",
                "APPROVAL.json",
                "BUILDER_WORKSPACE_OWNERSHIP.json",
                "CAPABILITY_BINDING.json",
            }

            def _consume(root: str, max_entries: int) -> None:
                nonlocal count, local_max
                for dirpath, dirnames, filenames in os.walk(root):
                    for name in filenames:
                        p = Path(dirpath) / name
                        # Skip bookkeeping filenames anywhere in the walk.
                        if name in BOOKKEEPING_FILE_BASENAMES:
                            continue
                        try:
                            st = p.stat()
                        except OSError:
                            continue
                        count += 1
                        local_max = max(local_max, int(st.st_mtime))
                        if count >= max_entries:
                            return
                    if count >= max_entries:
                        return

            # Walk the worktree root excluding known bookkeeping top-level dirs.
            for dirpath, dirnames, filenames in os.walk(str(worktree)):
                if dirpath == str(worktree):
                    dirnames[:] = [
                        d for d in dirnames if d not in SKIP_TOP_LEVEL_DIRS
                    ]
                for name in filenames:
                    if name in BOOKKEEPING_FILE_BASENAMES:
                        continue
                    p = Path(dirpath) / name
                    try:
                        st = p.stat()
                    except OSError:
                        continue
                    count += 1
                    local_max = max(local_max, int(st.st_mtime))
                    if count >= 4096:
                        break
                if count >= 4096:
                    break

            # Additionally walk Claude's scratch output under each
            # ``.ownframework-loop/<run-id>/scratch/`` so the watchdog sees
            # the worker's actual progress (BUILD_AGENT_RESULT.json,
            # REVIEW_AGENT_ASSESSMENT.json, etc.).
            ofloop_dir = Path(str(worktree)) / ".ownframework-loop"
            if ofloop_dir.is_dir():
                for run_dir in ofloop_dir.iterdir():
                    scratch_dir = run_dir / "scratch"
                    if scratch_dir.is_dir():
                        # Allow a generous entry budget for scratch; total
                        # walk budget remains capped at 4096.
                        remaining = max(1, 4096 - count)
                        _consume(str(scratch_dir), count + remaining)

            file_count = count
            max_mtime = local_max
        except OSError:
            pass

    return Signature(
        stdout_size=out_size,
        stdout_mtime=out_mtime,
        stderr_size=err_size,
        stderr_mtime=err_mtime,
        worktree_head=head,
        worktree_max_mtime=max_mtime,
        worktree_file_count=file_count,
    )


def watchdog_window_seconds(packet_max_pass_runtime_seconds: int) -> int:
    """Resolve the bounded watchdog window for one packet.

    Window = max(DEFAULT_WATCHDOG_WINDOW_SECONDS, budget // FRACTION).
    Below ``WATCHDOG_MIN_BUDGET_FOR_FRACTION`` the fraction is ignored and
    only the floor applies. Returns 0 to disable the watchdog entirely.
    """
    if packet_max_pass_runtime_seconds is None or packet_max_pass_runtime_seconds <= 0:
        return DEFAULT_WATCHDOG_WINDOW_SECONDS
    if packet_max_pass_runtime_seconds < WATCHDOG_MIN_BUDGET_FOR_FRACTION:
        return DEFAULT_WATCHDOG_WINDOW_SECONDS
    return max(
        DEFAULT_WATCHDOG_WINDOW_SECONDS,
        int(packet_max_pass_runtime_seconds) // WATCHDOG_WINDOW_FRACTION,
    )


def collect_progress_columns(sig: Signature) -> dict[str, Any]:
    """Translate a Signature into the columns we persist on jobs.

    Stored on the ``jobs`` row so the watchdog tick can compare
    against the previous observation without an in-memory cache that
    would be lost across supervisor restarts.
    """
    return {
        "progress_signature_stdout_size": sig.stdout_size,
        "progress_signature_stdout_mtime": sig.stdout_mtime,
        "progress_signature_stderr_size": sig.stderr_size,
        "progress_signature_stderr_mtime": sig.stderr_mtime,
        "progress_signature_worktree_head": sig.worktree_head,
        "progress_signature_worktree_max_mtime": sig.worktree_max_mtime,
        "progress_signature_worktree_file_count": sig.worktree_file_count,
        "progress_signature_at": time.time(),
    }


def collect_no_progress_attempts(
    conn: sqlite3.Connection,
    *,
    now: float | None = None,
    worktree_head_resolver=None,
) -> list[dict[str, Any]]:
    """Return inflight job rows whose observable progress has stalled.

    Each row contains enough context for the caller to force-terminate
    and mark the attempt. The caller MUST verify pid liveness before
    acting — this function only inspects durable data.
    """
    now = float(now if now is not None else time.time())
    try:
        rows = conn.execute(
            """
            SELECT id, run_id, repo,
                   worker_pid, worker_pgid, worker_started_at,
                   worker_role, worker_attempt_id,
                   worker_deadline_at,
                   worker_stdout_path, worker_stderr_path,
                   last_attempt_id, latest_attempt_id,
                   progress_signature_stdout_size,
                   progress_signature_stdout_mtime,
                   progress_signature_stderr_size,
                   progress_signature_stderr_mtime,
                   progress_signature_worktree_head,
                   progress_signature_worktree_max_mtime,
                   progress_signature_worktree_file_count,
                   progress_signature_at,
                   progress_watchdog_window_seconds,
                   max_pass_runtime_seconds
            FROM jobs
            WHERE status='RUNNING'
              AND worker_pid IS NOT NULL
              AND worker_role != 'dispatching'
              AND worker_role = 'builder'
            """
        ).fetchall()
    except sqlite3.Error:
        return []

    stalled: list[dict[str, Any]] = []
    for row in rows:
        deadline_at = float(row["worker_deadline_at"]) if row["worker_deadline_at"] else 0.0
        if not deadline_at or now >= deadline_at:
            # Deadline enforcement already covers this; the watchdog
            # only handles the in-budget no-progress class.
            continue
        budget = int(row["max_pass_runtime_seconds"]) if row["max_pass_runtime_seconds"] else 0
        configured_window = int(row["progress_watchdog_window_seconds"]) if row["progress_watchdog_window_seconds"] else 0
        window = configured_window or watchdog_window_seconds(budget)
        if window <= 0:
            continue
        sig_at = float(row["progress_signature_at"]) if row["progress_signature_at"] else 0.0
        if sig_at <= 0:
            # First observation never stalls; advance the baseline
            # by recording the current signature in the caller.
            continue
        if (now - sig_at) < window:
            continue

        # Compute the current signature and compare against the stored baseline.
        stdout_path = Path(str(row["worker_stdout_path"])) if row["worker_stdout_path"] else None
        stderr_path = Path(str(row["worker_stderr_path"])) if row["worker_stderr_path"] else None
        worktree = _extract_worktree_path(conn, row["run_id"], str(row["repo"]))
        current = compute_signature(
            stdout_path=stdout_path,
            stderr_path=stderr_path,
            worktree=worktree,
            worktree_head_resolver=worktree_head_resolver,
        )
        before = Signature.from_row(row)
        if signature_advanced(before, current):
            continue

        stalled.append({
            "row": dict(row),
            "deadline_at": deadline_at,
            "window_seconds": window,
            "seconds_since_progress": now - sig_at,
            "current_signature": current,
        })

    return stalled


def _extract_worktree_path(conn: sqlite3.Connection, run_id: str, repo_path: str) -> Path | None:
    """Best-effort resolve the builder worktree path for one run."""
    try:
        from . import state as state_mod
        rd = state_mod.run_dir(Path(repo_path), run_id)
        wt = rd.parent.parent / ".worktrees" / "ownframework-loop" / run_id / "builder"
        return wt if wt.exists() else None
    except Exception:
        return None


def as_dict(sig: Signature) -> dict[str, Any]:
    return {
        "stdout_size": sig.stdout_size,
        "stdout_mtime": sig.stdout_mtime,
        "stderr_size": sig.stderr_size,
        "stderr_mtime": sig.stderr_mtime,
        "worktree_head": sig.worktree_head,
        "worktree_max_mtime": sig.worktree_max_mtime,
        "worktree_file_count": sig.worktree_file_count,
    }


def _read_columns(conn: sqlite3.Connection, table: str) -> set[str]:
    return {
        str(row["name"])
        for row in conn.execute(f"PRAGMA table_info({table})").fetchall()
    }


def _worktree_head_resolver():
    """Cheap HEAD resolver used by the watchdog tick."""
    import subprocess as _sp

    def _resolve(wt: Path) -> str:
        try:
            return _sp.check_output(
                ["git", "-C", str(wt), "rev-parse", "--verify", "HEAD"],
                stderr=_sp.DEVNULL,
                timeout=2,
                text=True,
            ).strip()
        except Exception:
            return ""

    return _resolve


def initial_signature_for_dispatch(
    *,
    stdout_path: Path | None,
    stderr_path: Path | None,
    worktree: Path | None,
) -> tuple[dict[str, Any], float]:
    """First-observation signature used when a worker is freshly spawned.

    Returns (column_values, timestamp). The supervisor stores the column
    values on the `jobs` row at dispatch time so the first watchdog tick
    has a baseline rather than treating the freshly spawned worker as
    "stalled" before any work happened.
    """
    now = time.time()
    sig = compute_signature(
        stdout_path=stdout_path,
        stderr_path=stderr_path,
        worktree=worktree,
        worktree_head_resolver=_worktree_head_resolver(),
    )
    cols = collect_progress_columns(sig)
    cols["progress_signature_at"] = now
    return cols, now


def tick(
    conn: sqlite3.Connection,
    *,
    now: float | None = None,
    terminate=None,
) -> dict[str, Any]:
    """Run one watchdog tick against the current inflight set.

    For each inflight attempt:
      1. If liveness unknown or past-deadline, skip (deadline covers it).
      2. Compute current signature. If advanced, update stored baseline.
      3. If unchanged for `window_seconds`, call ``terminate`` (if
         provided) and mark the attempt progress_stalled, advancing the
         job's `progress_stall_count` and pinning `next_attempt_at` to a
         backoff so retry is bounded.

    Returns a small dict with tick counts.
    """
    now = float(now if now is not None else time.time())
    summary = {
        "considered": 0,
        "advanced": 0,
        "terminated": 0,
        "skipped": 0,
    }
    try:
        rows = conn.execute(
            """
            SELECT id, run_id, repo, attempt_id_only, latest_attempt_id,
                   worker_pid, worker_pgid, worker_started_at,
                   worker_role, worker_start_identity,
                   worker_deadline_at,
                   worker_stdout_path, worker_stderr_path,
                   max_pass_runtime_seconds,
                   progress_signature_stdout_size,
                   progress_signature_stdout_mtime,
                   progress_signature_stderr_size,
                   progress_signature_stderr_mtime,
                   progress_signature_worktree_head,
                   progress_signature_worktree_max_mtime,
                   progress_signature_worktree_file_count,
                   progress_signature_at,
                   progress_watchdog_window_seconds,
                   progress_stall_count,
                   transit_loss
            FROM (
                SELECT j.*,
                       (SELECT sa.attempt_id FROM semantic_attempts sa WHERE sa.job_id=j.id ORDER BY sa.started_at DESC LIMIT 1) AS attempt_id_only,
                       CASE WHEN j.transient_failures >= j.max_transient_failures THEN 1 ELSE 0 END AS transit_loss
                FROM jobs j
                WHERE j.status='RUNNING'
                  AND j.worker_pid IS NOT NULL
                  AND j.worker_role != 'dispatching'
                  AND j.worker_role = 'builder'
                  AND COALESCE(j.worker_deadline_at, 0) > 0
                  AND j.worker_deadline_at > ?
            )
            """,
            (now,),
        ).fetchall()
    except sqlite3.Error:
        return summary

    for row in rows:
        summary["considered"] += 1
        deadline_at = float(row["worker_deadline_at"])
        if now >= deadline_at:
            summary["skipped"] += 1
            continue

        budget = int(row["max_pass_runtime_seconds"]) if row["max_pass_runtime_seconds"] else 0
        configured_window = int(row["progress_watchdog_window_seconds"]) if row["progress_watchdog_window_seconds"] else 0
        window = configured_window or watchdog_window_seconds(budget)
        if window <= 0:
            summary["skipped"] += 1
            continue

        sig_at = float(row["progress_signature_at"]) if row["progress_signature_at"] else 0.0
        if sig_at <= 0:
            # Fresh dispatch — initialize baseline rather than stalling.
            stdout_path = Path(str(row["worker_stdout_path"])) if row["worker_stdout_path"] else None
            stderr_path = Path(str(row["worker_stderr_path"])) if row["worker_stderr_path"] else None
            worktree = _extract_worktree_path(conn, str(row["run_id"]), str(row["repo"]))
            current = compute_signature(
                stdout_path=stdout_path, stderr_path=stderr_path,
                worktree=worktree, worktree_head_resolver=_worktree_head_resolver(),
            )
            cols = collect_progress_columns(current)
            try:
                conn.execute(
                    """
                    UPDATE jobs SET
                        progress_signature_stdout_size = :s_out_s,
                        progress_signature_stdout_mtime = :s_out_m,
                        progress_signature_stderr_size = :s_err_s,
                        progress_signature_stderr_mtime = :s_err_m,
                        progress_signature_worktree_head = :s_wt_h,
                        progress_signature_worktree_max_mtime = :s_wt_m,
                        progress_signature_worktree_file_count = :s_wt_c,
                        progress_signature_at = :s_at
                    WHERE id = :job_id AND status = 'RUNNING'
                    """,
                    {
                        "s_out_s": cols["progress_signature_stdout_size"],
                        "s_out_m": cols["progress_signature_stdout_mtime"],
                        "s_err_s": cols["progress_signature_stderr_size"],
                        "s_err_m": cols["progress_signature_stderr_mtime"],
                        "s_wt_h": cols["progress_signature_worktree_head"],
                        "s_wt_m": cols["progress_signature_worktree_max_mtime"],
                        "s_wt_c": cols["progress_signature_worktree_file_count"],
                        "s_at": cols["progress_signature_at"],
                        "job_id": int(row["id"]),
                    },
                )
            except sqlite3.Error:
                pass
            summary["advanced"] += 1
            continue

        if (now - sig_at) < window:
            summary["skipped"] += 1
            continue

        stdout_path = Path(str(row["worker_stdout_path"])) if row["worker_stdout_path"] else None
        stderr_path = Path(str(row["worker_stderr_path"])) if row["worker_stderr_path"] else None
        worktree = _extract_worktree_path(conn, str(row["run_id"]), str(row["repo"]))
        current = compute_signature(
            stdout_path=stdout_path, stderr_path=stderr_path,
            worktree=worktree, worktree_head_resolver=_worktree_head_resolver(),
        )
        before = Signature(
            stdout_size=int(row["progress_signature_stdout_size"]),
            stdout_mtime=int(row["progress_signature_stdout_mtime"]),
            stderr_size=int(row["progress_signature_stderr_size"]),
            stderr_mtime=int(row["progress_signature_stderr_mtime"]),
            worktree_head=str(row["progress_signature_worktree_head"] or ""),
            worktree_max_mtime=int(row["progress_signature_worktree_max_mtime"]),
            worktree_file_count=int(row["progress_signature_worktree_file_count"]),
        )
        if signature_advanced(before, current):
            # Progress IS happening within the window — advance baseline.
            cols = collect_progress_columns(current)
            try:
                conn.execute(
                    """
                    UPDATE jobs SET
                        progress_signature_stdout_size = :s_out_s,
                        progress_signature_stdout_mtime = :s_out_m,
                        progress_signature_stderr_size = :s_err_s,
                        progress_signature_stderr_mtime = :s_err_m,
                        progress_signature_worktree_head = :s_wt_h,
                        progress_signature_worktree_max_mtime = :s_wt_m,
                        progress_signature_worktree_file_count = :s_wt_c,
                        progress_signature_at = :s_at
                    WHERE id = :job_id AND status = 'RUNNING'
                    """,
                    {
                        "s_out_s": cols["progress_signature_stdout_size"],
                        "s_out_m": cols["progress_signature_stdout_mtime"],
                        "s_err_s": cols["progress_signature_stderr_size"],
                        "s_err_m": cols["progress_signature_stderr_mtime"],
                        "s_wt_h": cols["progress_signature_worktree_head"],
                        "s_wt_m": cols["progress_signature_worktree_max_mtime"],
                        "s_wt_c": cols["progress_signature_worktree_file_count"],
                        "s_at": cols["progress_signature_at"],
                        "job_id": int(row["id"]),
                    },
                )
            except sqlite3.Error:
                pass
            summary["advanced"] += 1
            continue

        # Stalled — force terminate and route to retry.
        worker_pid = int(row["worker_pid"]) if row["worker_pid"] else 0
        worker_pgid = int(row["worker_pgid"]) if row["worker_pgid"] else None
        worker_started_at = float(row["worker_started_at"]) if row["worker_started_at"] else None
        try:
            if terminate is not None:
                ok = terminate(
                    int(worker_pid), worker_pgid,
                    str(row["worker_start_identity"] or "") or None,
                    worker_started_at,
                )
                if not ok:
                    summary["skipped"] += 1
                    continue
        except Exception:
            summary["skipped"] += 1
            continue

        # Mark stalled attempt and request retry.
        # v1.0.0 race fix: do not constrain by status='RUNNING' alone.
        # The dispatcher's exit handler runs under BEGIN IMMEDIATE and
        # may have already moved status to BACKOFF before this UPDATE
        # acquires the lock; constraining by status='RUNNING' would
        # silently no-op and let the dispatcher's runner-classifier
        # overwrite the watchdog's authoritative progress_stalled
        # classification. We accept BOTH RUNNING and BACKOFF as the
        # watchdog's expected target states (BACKOFF only arises when
        # the dispatcher raced the watchdog, in which case the
        # watchdog's authoritative kill still applies).
        # Operator-driven terminal states (DONE, RETIRED, QUARANTINED,
        # CANCELED) are NEVER resurrected by the watchdog.
        try:
            cur = conn.execute(
                """
                UPDATE jobs SET
                    status = 'QUEUED',
                    worker_pid = NULL,
                    worker_started_at = NULL,
                    worker_pgid = NULL,
                    worker_deadline_at = NULL,
                    worker_start_identity = NULL,
                    worker_role = NULL,
                    worker_attempt_id = NULL,
                    last_error = 'no observable progress within watchdog window',
                    last_failure_class = 'progress_stalled',
                    last_failure_reason = ?,
                    progress_stall_count = progress_stall_count + 1,
                    transient_failures = transient_failures + 1,
                    next_attempt_at = MAX(next_attempt_at, ?),
                    updated_at = ?
                WHERE id = ? AND status IN ('RUNNING', 'BACKOFF')
                """,
                (
                    f"watchdog_no_progress_window={int(window)}",
                    now + min(60.0, max(5.0, float(window))),
                    now,
                    int(row["id"]),
                ),
            )
            if cur.rowcount != 1:
                # Operator transitioned the row to a terminal state
                # between the SELECT and the UPDATE. The watchdog
                # must never resurrect terminal state; just count and
                # move on.
                summary["skipped"] += 1
                continue
            # Append a FAILED attempt row bound to the latest attempt so
            # callers watching semantic_attempts see the watchdog kill.
            # v1.0.0 race fix: do not constrain by status='RUNNING'
            # alone (same reason as the jobs UPDATE above); the
            # dispatcher may have already set the attempt to a
            # transition state.
            latest_attempt = str(row["latest_attempt_id"] or "")
            if latest_attempt:
                conn.execute(
                    """
                    UPDATE semantic_attempts SET
                        status='FAILED', completed_at=?, returncode=NULL,
                        cost_usd=0, cost_accounted=1, cost_known=0,
                        input_tokens=0, output_tokens=0,
                        cache_read_tokens=0, cache_creation_tokens=0,
                        tokens_known=0,
                        failure_class='progress_stalled',
                        failure_reason=?
                    WHERE attempt_id=? AND job_id=?
                      AND status IN ('RUNNING', 'RESERVED')
                    """,
                    (
                        float(now),
                        f"watchdog_no_progress_window={int(window)}",
                        latest_attempt,
                        int(row["id"]),
                    ),
                )
        except sqlite3.Error:
            continue
        summary["terminated"] += 1

    try:
        conn.commit()
    except sqlite3.Error:
        pass
    return summary
