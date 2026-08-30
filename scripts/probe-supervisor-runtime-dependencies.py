#!/usr/bin/env python3
"""Read-only preflight for replacing a commissioned OwnFramework Loop runtime.

Exit codes:
  0  safe
  11 live/ambiguous semantic work blocks replacement
  12 ledger unreadable/incompatible
  13 unfinished runtime-generation dependency blocks replacement
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

    if not args.allow_active:
        problems: list[str] = []
        try:
            for row in conn.execute(
                "SELECT run_id,worker_pid FROM jobs WHERE status='RUNNING'"
            ):
                if _pid_alive(row["worker_pid"]) is not False:
                    problems.append(f"running_job={row['run_id']}")
            for row in conn.execute(
                """SELECT a.attempt_id,a.status,j.run_id,j.worker_pid
                   FROM semantic_attempts a
                   JOIN jobs j ON j.id=a.job_id
                   WHERE j.status='RUNNING'"""
            ):
                if str(row["status"]) in TERMINAL_ATTEMPTS:
                    continue
                if _pid_alive(row["worker_pid"]) is not False:
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

    print("reason=safe")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
