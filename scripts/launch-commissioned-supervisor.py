#!/usr/bin/env python3
"""Fail-closed commissioned supervisor launcher.

The platform service manager invokes this script with the exact commissioned
Python interpreter. It proves the durable ledger still exists and is readable
before replacing itself with the normal exact-interpreter supervisor process.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import sys


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--ledger-marker", required=True)
    ap.add_argument("--probe", required=True)
    ap.add_argument("--ofloop", required=True)
    args = ap.parse_args()

    db = Path(args.db)
    marker = Path(args.ledger_marker)
    if not marker.is_file():
        print("SUPERVISOR_START=REFUSED reason=ledger_incarnation_marker_missing", file=sys.stderr)
        return 78
    if not db.is_file():
        print("SUPERVISOR_START=REFUSED reason=commissioned_ledger_missing", file=sys.stderr)
        return 78
    proc = subprocess.run(
        [
            sys.executable,
            "-B",
            args.probe,
            str(db),
            "startup",
            "--allow-active",
            "--allow-generation-migration",
        ],
        env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        check=False,
    )
    if proc.returncode != 0:
        print(
            f"SUPERVISOR_START=REFUSED reason=commissioned_ledger_unusable probe_rc={proc.returncode}",
            file=sys.stderr,
        )
        return proc.returncode
    os.execv(
        sys.executable,
        [sys.executable, "-B", args.ofloop, "supervisor", "serve"],
    )
    return 127


if __name__ == "__main__":
    raise SystemExit(main())
