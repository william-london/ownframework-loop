#!/usr/bin/env python3
"""Read-only preflight for replacing a commissioned OwnFramework Loop runtime.

Exit codes:
  0  safe
  11 live/ambiguous semantic work blocks replacement
  12 ledger unreadable/incompatible
  13 unfinished runtime-generation dependency blocks replacement

The canonical v0.8.x supervisor.sqlite3 carries the full jobs +
semantic_attempts schema including worker_pid, runtime_generation, etc.
A legacy pre-runtime_generation ledger does NOT carry runtime_generation.
An even older fixture may not carry worker_pid. The probe recognizes
that the absence of a column / table is a property of the ledger schema,
not a probe failure: it consults PRAGMA table_info and sqlite_master
before issuing any column- or table-dependent SELECT, so a minimal
fixture never trips a false-positive ledger_probe_failed
/ OperationalError.
"""
from __future__ import annotations

import argparse
import os
import sqlite3
import sys
from pathlib import Path

TERMINAL_ATTEMPTS = {
    "COMPLETED", "COST_UNKNOWN", "TOKENS_UNKNOWN",
    "FAILED", "RECOVERED", "SUPERSEDED",
}


def _pid_alive(pid: object) -> bool | None:
    if pid is None:
        return None
    try:
        os.kill(int(pid), 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except (TypeError, ValueError):
        return None


def _column_names(conn: sqlite3.Connection, table: str) -> set[str]:
    return {
        str(row["name"])
        for row in conn.execute(f"PRAGMA table_info({table})")
    }


def _table_exists(conn: sqlite3.Connection, table: str) -> bool:
    cur = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1",
        (table,),
    )
    return cur.fetchone() is not None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("db")
    ap.add_argument("incoming_generation")
    ap.add_argument("--allow-active", action="store_true")
    ap.add_argument("--allow-generation-migration", action="store_true")
    args = ap.parse_args()

    db = Path(args.db)
    if not db.is_file():
        print("reason=ledger_missing")
        return 12
    try:
        conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        conn.row_factory = sqlite3.Row
    except sqlite3.Error as exc:
        print(f"reason=ledger_unreadable detail={type(exc).__name__}")
        return 12

    try:
        quick = [str(row[0]) for row in conn.execute("PRAGMA quick_check").fetchall()]
        if not quick or any(item.lower() != "ok" for item in quick):
            print("reason=ledger_unreadable detail=quick_check_failed")
            return 12
        if not _table_exists(conn, "jobs"):
            print("reason=ledger_schema_unrecognized detail=jobs_table_missing")
            return 12
        jobs_columns = _column_names(conn, "jobs")
        required = {"run_id", "status"}
        missing = sorted(required - jobs_columns)
        if missing:
            print("reason=ledger_schema_unrecognized detail=jobs_columns_missing:" + ",".join(missing))
            return 12
        attempts_exists = _table_exists(conn, "semantic_attempts")
        known_statuses = {"QUEUED", "BACKOFF", "RUNNING", "QUARANTINED", "DONE", "RETIRED"}
        unknown = [
            str(row["status"] or "")
            for row in conn.execute("SELECT DISTINCT status FROM jobs")
            if str(row["status"] or "") not in known_statuses
        ]
        if unknown:
            print("reason=ledger_schema_unrecognized detail=unknown_job_status:" + ",".join(sorted(set(unknown))))
            return 12
    except sqlite3.Error as exc:
        print(f"reason=ledger_unreadable detail={type(exc).__name__}")
        return 12

    if not args.allow_active:
        problems: list[str] = []
        try:
            if "worker_pid" in jobs_columns:
                for row in conn.execute(
                    "SELECT run_id,worker_pid FROM jobs WHERE status='RUNNING'"
                ):
                    if _pid_alive(row["worker_pid"]) is not False:
                        problems.append(f"running_job={row['run_id']}")
            if attempts_exists and "worker_pid" in jobs_columns:
                attempts_columns = _column_names(conn, "semantic_attempts")
                if {"attempt_id", "status"}.issubset(attempts_columns):
                    for row in conn.execute(
                        """SELECT a.attempt_id,a.status,j.run_id,j.worker_pid
                           FROM semantic_attempts a
                           JOIN jobs j ON j.id=a.job_id
                           WHERE j.status='RUNNING'"""
                    ):
                        if str(row["status"]) in TERMINAL_ATTEMPTS:
                            continue
                        if _pid_alive(row["worker_pid"]) is False:
                            continue
                        problems.append(
                            f"active_attempt={row['attempt_id']}:{row['status']}"
                        )
        except sqlite3.Error as exc:
            print(f"reason=ledger_probe_failed detail={type(exc).__name__}")
            return 12
        if problems:
            print("reason=active_semantic_work detail=" + ";".join(problems[:4]))
            return 11

    if not args.allow_generation_migration:
        problems = []
        try:
            if "runtime_generation" not in jobs_columns:
                # Legacy ledgers can be proven safe only when all enrollment is
                # already terminal.  Any unfinished legacy row is unbound and
                # therefore blocks replacement.
                unfinished = conn.execute(
                    "SELECT run_id,status FROM jobs "
                    "WHERE status NOT IN ('DONE','RETIRED') LIMIT 1"
                ).fetchone()
                if unfinished is not None:
                    print("reason=legacy_unbound detail=no_runtime_generation_column")
                    return 13
            else:
                for row in conn.execute(
                    "SELECT run_id,status,runtime_generation FROM jobs "
                    "WHERE status NOT IN ('DONE','RETIRED')"
                ):
                    gen = str(row["runtime_generation"] or "")
                    if not gen:
                        problems.append(
                            f"generation_dependency={row['run_id']}:{row['status']}:UNBOUND"
                        )
                    elif gen != args.incoming_generation:
                        problems.append(
                            f"generation_dependency={row['run_id']}:{row['status']}:{gen}"
                        )
        except sqlite3.Error as exc:
            print(f"reason=ledger_probe_failed detail={type(exc).__name__}")
            return 12
        if problems:
            print(
                "reason=runtime_generation_dependency incoming="
                + args.incoming_generation
                + " detail="
                + ";".join(problems[:4])
            )
            return 13

    # Unfinished non-terminal enrollments (QUEUED, BACKOFF, QUARANTINED,
    # RUNNING) must not be silently destroyed by an uninstall. The
    # active-work check above is intentionally narrow (RUNNING + live
    # attempt) because install can safely coexist with a QUEUED row.
    # The intent label distinguishes install (2nd positional arg is the
    # incoming runtime generation) from uninstall (2nd positional arg is
    # the literal string "uninstall"). Only enforce the broad
    # non-terminal check for uninstall.
    if args.incoming_generation == "uninstall":
        try:
            problems = [
                f"unfinished_job={row['run_id']}:{row['status']}"
                for row in conn.execute(
                    "SELECT run_id,status FROM jobs "
                    "WHERE status NOT IN ('DONE','RETIRED')"
                )
            ]
        except sqlite3.Error as exc:
            print(f"reason=ledger_probe_failed detail={type(exc).__name__}")
            return 12
        if problems:
            print(
                "reason=unfinished_runtime_dependency detail="
                + ";".join(problems[:4])
            )
            return 13

    print("reason=safe")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
