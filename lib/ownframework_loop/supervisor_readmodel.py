"""Supervisor read-model — operator-facing read-only projections.

Canonical body owner of the supervisor's read-only operator
surface.  The implementations live here; supervisor.py exposes
thin delegating wrappers for backward compatibility.

This module is strictly read-only — no durable mutation.  Hold
mutation (release/cancel) and persisted-config mutation
(supervisor_config_set) live in their respective authorities
(supervisor_holds, supervisor_operator); this module exposes
only the read projections and the diagnostic view helpers.

Hierarchy:

    domain authorities (holds, operator, claims, attempts, recovery)
        ↓
    supervisor_readmodel (THIS MODULE — read-only projections)
        ↓
    supervisor_db + supervisor_holds (read-side primitives)

Dependency direction: this module imports from supervisor_db
and supervisor_holds.  It does NOT import supervisor.
"""
from __future__ import annotations

import json
import sqlite3
import subprocess
import time
from pathlib import Path
from typing import Any

from . import state as state_mod
from . import packet as packet_mod
from . import supervisor_db as _db_mod
from . import supervisor_holds as _holds_mod


def _logical_job_row(
    conn: sqlite3.Connection,
    canonical_repo: Path,
    run_id: str,
) -> tuple[sqlite3.Row | None, str | None]:
    """Thin delegate to ``supervisor_db._logical_job_row``."""
    return _db_mod._logical_job_row(conn, canonical_repo, run_id)



def status(
    *,
    canonical_repo: Path,
    run_id: str,
    db_path: Path | None = None,
) -> dict[str, Any]:
    state_mod.validate_run_id(run_id)
    repo = str(Path(canonical_repo).resolve(strict=False))
    db = db_path or _db_mod.default_db_path()
    if not Path(db).expanduser().is_file():
        row, lookup_reason = None, "not_enqueued"
    else:
        try:
            with _db_mod._managed_connect_readonly(db) as conn:
                row, lookup_reason = _logical_job_row(conn, canonical_repo, run_id)
        except sqlite3.Error as exc:
            return {
                "schema": _db_mod.SCHEMA,
                "ok": False,
                "repo": repo,
                "run_id": run_id,
                "status": "LEDGER_UNREADABLE",
                "db_path": str(db),
                "error": type(exc).__name__,
            }
    if row is None:
        return {
            "schema": _db_mod.SCHEMA,
            "ok": False,
            "repo": repo,
            "run_id": run_id,
            "status": (
                "LEDGER_AMBIGUOUS"
                if lookup_reason == "logical_job_ambiguous"
                else "NOT_ENQUEUED"
            ),
            "reason": lookup_reason,
            "db_path": str(db),
        }
    return _job_dict(row, db)




def _readonly_columns(conn: sqlite3.Connection, table: str) -> set[str]:
    try:
        return {str(row["name"]) for row in conn.execute(f"PRAGMA table_info({table})").fetchall()}
    except sqlite3.Error:
        return set()




def _legacy_readonly_fleet_projection(
    conn: sqlite3.Connection, db: Path
) -> dict[str, Any]:
    """Safe serial projection for a pre-v0.9 ledger; never migrates it."""
    job_columns = _readonly_columns(conn, "jobs")
    if not {"id", "repo", "run_id", "status"}.issubset(job_columns):
        return {
            "schema": _db_mod.SCHEMA, "ok": False, "db_path": str(db),
            "reason": "legacy_ledger_schema_unreadable",
            "schema_migration_required": True,
            "legacy_serial_projection": True,
        }
    rows = conn.execute("SELECT * FROM jobs ORDER BY id").fetchall()
    projected = []
    for row in rows:
        item = dict(row)
        item.update({
            "effective_schedulability": False,
            "workspace_blocked": False,
            "repository_peer_running": False,
            "dispatch_hold_claim_decision": "legacy_projection_unavailable",
            "dispatch_hold_blocked": False,
            "held": False,
            "active_slot": str(row["status"] or "") == "RUNNING",
            "scheduler_class": "SINGLE",
            "legacy_projection": True,
        })
        projected.append(item)
    active = sum(1 for row in rows if str(row["status"] or "") == "RUNNING")
    counts = {name: sum(1 for row in rows if str(row["status"] or "") == name)
              for name in ("QUEUED", "BACKOFF", "QUARANTINED", "DONE", "RETIRED")}
    return {
        "schema": _db_mod.SCHEMA, "ok": True, "db_path": str(db),
        "schema_migration_required": True,
        "legacy_serial_projection": True,
        "configured_max_concurrency": 1,
        "active_running": active, "active_slots": active,
        "free_slots": max(0, 1 - active),
        "capacity_draining": active > 1,
        "running_jobs": active, "queued_jobs": counts["QUEUED"],
        "workspace_blocked_jobs": 0, "held_jobs": 0,
        "backoff_jobs": counts["BACKOFF"],
        "quarantined_jobs": counts["QUARANTINED"],
        "done_jobs": counts["DONE"], "retired_jobs": counts["RETIRED"],
        "jobs": projected,
    }



def supervisor_config_get(*, db_path: Path | None = None) -> dict[str, Any]:
    """Read persistent operational supervisor configuration."""
    db = db_path or _db_mod.default_db_path()
    if not Path(db).expanduser().is_file():
        return {"schema": _db_mod.SCHEMA, "ok": True, "max_concurrency": _db_mod.DEFAULT_MAX_CONCURRENCY,
                "db_path": str(db)}
    with _db_mod._managed_connect_readonly(db) as conn:
        if not _readonly_columns(conn, "supervisor_config"):
            return {
                "schema": _db_mod.SCHEMA, "ok": True,
                "max_concurrency": _db_mod.DEFAULT_MAX_CONCURRENCY,
                "db_path": str(db),
                "schema_migration_required": True,
                "legacy_serial_projection": True,
            }
        row = conn.execute(
            "SELECT value FROM supervisor_config WHERE key=?",
            (_db_mod._CONFIG_MAX_CONCURRENCY,),
        ).fetchone()
    value = _db_mod._validate_max_concurrency(row[0] if row is not None else _db_mod.DEFAULT_MAX_CONCURRENCY)
    return {"schema": _db_mod.SCHEMA, "ok": True, "max_concurrency": value, "db_path": str(db)}




def _hold_decision_blocks_claim(decision: str) -> bool:
    """Mirror the claim owner's fail-closed hold decisions for read projections."""
    return (
        decision in {
            "HELD",
            "MATCH",
            "invalid_hold_state",
            "unsupported_hold_kind",
        }
        or decision.startswith("engineering_state_unavailable")
    )



def fleet_status(*, db_path: Path | None = None) -> dict[str, Any]:
    """Project fleet-wide operational truth without claims or mutations."""
    db = db_path or _db_mod.default_db_path()
    if not Path(db).expanduser().is_file():
        return {"schema": _db_mod.SCHEMA, "ok": True, "db_path": str(db),
                "configured_max_concurrency": _db_mod.DEFAULT_MAX_CONCURRENCY,
                "active_running": 0, "active_slots": 0, "free_slots": _db_mod.DEFAULT_MAX_CONCURRENCY,
                "capacity_draining": False, "jobs": []}
    with _db_mod._managed_connect_readonly(db) as conn:
        job_columns = _readonly_columns(conn, "jobs")
        required_v09 = {
            "repository_scheduling_key", "repository_identity_proven",
            "workspace_scheduling_key", "workspace_identity_proven",
            "execution_mode",
        }
        if (
            not required_v09.issubset(job_columns)
            or not _readonly_columns(conn, "supervisor_config")
            or not _readonly_columns(conn, "dispatch_holds")
        ):
            return _legacy_readonly_fleet_projection(conn, Path(db))
        cfg = conn.execute(
            "SELECT value FROM supervisor_config WHERE key=?", (_db_mod._CONFIG_MAX_CONCURRENCY,)
        ).fetchone()
        configured = _db_mod._validate_max_concurrency(cfg[0] if cfg is not None else _db_mod.DEFAULT_MAX_CONCURRENCY)
        rows = conn.execute(
            """SELECT j.*, h.state AS hold_state, h.hold_id, h.kind AS hold_kind,
                      h.previous_checkpoint_id, h.next_checkpoint_id
               FROM jobs j LEFT JOIN dispatch_holds h ON h.job_id=j.id
               ORDER BY j.id"""
        ).fetchall()
        running_repository_keys = {str(r["repository_scheduling_key"] or "") for r in rows if r["status"] == "RUNNING"}
        running_workspace_keys = {str(r["workspace_scheduling_key"] or "") for r in rows if r["status"] == "RUNNING"}
        active = sum(1 for r in rows if r["status"] == "RUNNING")
        projected: list[dict[str, Any]] = []
        for row in rows:
            hold_state = str(row["hold_state"] or "")
            status_value = str(row["status"])
            _hold, hold_decision = _holds_mod._hold_matches_before_claim(conn, row)
            dispatch_hold_blocked = (
                status_value in {"QUEUED", "BACKOFF"}
                and _hold_decision_blocks_claim(hold_decision)
            )
            workspace_blocked = (
                status_value in {"QUEUED", "BACKOFF"}
                and str(row["workspace_scheduling_key"] or "") in running_workspace_keys
            )
            repository_peer_running = (
                status_value in {"QUEUED", "BACKOFF"}
                and str(row["repository_scheduling_key"] or "") in running_repository_keys
            )
            blocked = dispatch_hold_blocked or workspace_blocked
            due = float(row["next_attempt_at"] or 0) <= time.time()
            identity_proven = int(row["repository_identity_proven"] or 0) == 1
            workspace_proven = int(row["workspace_identity_proven"] or 0) == 1
            effective = (
                status_value in {"QUEUED", "BACKOFF"}
                and not blocked
                and due
                and identity_proven
                and workspace_proven
                and active < configured
            )
            item = dict(row)
            item.update({
                "effective_schedulability": bool(effective),
                "workspace_blocked": bool(workspace_blocked),
                "repository_peer_running": bool(repository_peer_running),
                "dispatch_hold_claim_decision": hold_decision,
                "dispatch_hold_blocked": bool(dispatch_hold_blocked),
                "held": hold_state == "HELD",
                "active_slot": status_value == "RUNNING",
                "scheduler_class": str(row["execution_mode"] or "SINGLE"),
            })
            projected.append(item)
        counts = {name: sum(1 for r in rows if r["status"] == name) for name in
                  ("QUEUED", "BACKOFF", "QUARANTINED", "DONE", "RETIRED")}
        held = sum(1 for r in rows if r["hold_state"] == "HELD")
        return {
            "schema": _db_mod.SCHEMA, "ok": True, "db_path": str(db),
            "configured_max_concurrency": configured,
            "active_running": active, "active_slots": active,
            "free_slots": max(0, configured - active),
            "capacity_draining": active > configured,
            "running_jobs": active, "queued_jobs": counts["QUEUED"],
            "workspace_blocked_jobs": sum(1 for r in projected if r["workspace_blocked"]),
            "held_jobs": held, "backoff_jobs": counts["BACKOFF"],
            "quarantined_jobs": counts["QUARANTINED"], "done_jobs": counts["DONE"],
            "retired_jobs": counts["RETIRED"], "jobs": projected,
        }




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
    d.update({"schema": _db_mod.SCHEMA, "ok": True, "db_path": str(db)})
    latest_id = str(d.get("latest_attempt_id") or "")
    d["attempt_history"] = []
    try:
        if latest_id:
            with _db_mod._managed_connect_readonly(db) as attempt_conn:
                attempt_conn.row_factory = sqlite3.Row
                ar = attempt_conn.execute(
                    "SELECT * FROM semantic_attempts WHERE attempt_id=?",
                    (latest_id,),
                ).fetchone()
            if ar is not None:
                d["latest_attempt"] = dict(ar)
        with _db_mod._managed_connect_readonly(db) as history_conn:
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
        with _db_mod._managed_connect_readonly(db) as hold_conn:
            hold, hold_decision = _holds_mod._hold_matches_before_claim(
                hold_conn, row
            )
        d["dispatch_hold"] = _holds_mod._hold_dict(hold)
        d["dispatch_hold_claim_decision"] = hold_decision
        d["dispatch_hold_blocked"] = (
            str(d.get("status") or "") in {"QUEUED", "BACKOFF"}
            and _hold_decision_blocks_claim(hold_decision)
        )
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
    durable_candidate_branch = str(d.get("candidate_branch") or "")
    try:
        snapshot = _core_snapshot(Path(str(row["repo"])), str(row["run_id"]))
        if not snapshot.get("candidate_branch") and durable_candidate_branch:
            snapshot["candidate_branch"] = durable_candidate_branch
        d.update(snapshot)
    except Exception as exc:
        d.update({
            "core_snapshot_ok": False,
            "core_snapshot_errors": [f"snapshot_error:{type(exc).__name__}"],
        })
        if durable_candidate_branch:
            d["candidate_branch"] = durable_candidate_branch
    return d






# -----------------------------------------------------------------------------
# Hold read projection.
#
# The hold lifecycle mutations (release/cancel) live in supervisor_holds.
# The READ projection is exposed here because operators commonly look up
# "where is my hold?" while running read-model queries; supervisor_holds
# remains the canonical mutation owner.
# -----------------------------------------------------------------------------

from .supervisor_holds import dispatch_hold_status  # noqa: E402,F401  (read projection)


__all__ = [
    # Canonical read-model bodies (this module):
    "status",
    "supervisor_config_get",
    "fleet_status",
    "_logical_job_row",
    "_readonly_columns",
    "_legacy_readonly_fleet_projection",
    "_run_git_readonly",
    "_registered_worktree_paths",
    "_worktree_visibility",
    "_candidate_diff_visibility",
    "_core_snapshot",
    "_job_dict",
    # Hold read projection (re-exported from supervisor_holds):
    "dispatch_hold_status",
]
