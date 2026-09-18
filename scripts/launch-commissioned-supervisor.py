#!/usr/bin/env python3
"""Fail-closed commissioned supervisor launcher.

The platform service manager invokes this script with the exact commissioned
Python interpreter. It proves the durable ledger still exists and is readable
before writing a per-activation receipt that the installer verifies before
declaring PASS.  The receipt is the load-bearing active-identity proof:
- written atomically by THIS process;
- bound to a fresh ``OFLOOP_ACTIVATION_ID`` the installer minted for this
  commissioning attempt;
- containing values derived from THIS process's argv/env/pid (not
  parsed back from a service-manager text dump);
- recorded BEFORE the ``os.execv`` so the post-exec supervisor inherits a
  proof on disk that the installer can verify.

A stale receipt from a previous activation cannot satisfy a new activation
because the activation id is freshly minted per install.
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

# Make the helper module importable regardless of how the launcher was
# invoked (direct PYTHONPATH vs installed-via-ofloop).
_HERE = Path(__file__).resolve(strict=False).parent
_REPO_LIB = _HERE.parent / "lib"
if str(_REPO_LIB) not in sys.path:
    sys.path.insert(0, str(_REPO_LIB))

from ownframework_loop import service_identity  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--ledger-marker", required=True)
    ap.add_argument("--probe", required=True)
    ap.add_argument("--ofloop", required=True)
    ap.add_argument("--activation-id", required=True)
    ap.add_argument("--receipt-path", required=True)
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

    # Pass activation id + receipt path through argv to the post-exec
    # supervisor too, so the supervisor can refresh its own runtime
    # identity record if it chooses.  This is intentionally additive:
    # the durable supervisor remains free to ignore these flags.
    derived = service_identity.derive_active_identity(
        launcher_argv=[
            sys.executable,
            "-B",
            str(_HERE / "launch-commissioned-supervisor.py"),
            "--db", str(db),
            "--ledger-marker", str(marker),
            "--probe", str(args.probe),
            "--ofloop", str(args.ofloop),
            "--activation-id", str(args.activation_id),
            "--receipt-path", str(args.receipt_path),
        ],
        launcher_env=os.environ,
        launcher_pid=os.getpid(),
    )
    try:
        service_identity.write_receipt_atomic(derived, Path(args.receipt_path))
    except OSError as exc:
        print(
            f"SUPERVISOR_START=REFUSED reason=activation_receipt_write_failed detail={exc}",
            file=sys.stderr,
        )
        return 79

    print(
        "SUPERVISOR_START=ATTESTED",
        f"activation_id={derived['activation_id']}",
        f"pid={derived['pid']}",
        f"receipt={args.receipt_path}",
    )
    os.execv(
        sys.executable,
        [
            sys.executable,
            "-B",
            args.ofloop,
            "supervisor", "serve",
            "--ofloop-activation-id", str(args.activation_id),
            "--ofloop-receipt-path", str(args.receipt_path),
        ],
    )
    return 127


if __name__ == "__main__":
    raise SystemExit(main())
