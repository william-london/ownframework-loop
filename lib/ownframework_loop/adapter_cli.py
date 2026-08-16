"""Deterministic adapter inspection sub-CLI for ``ofloop adapter``."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from .adapters import doctor_adapter, get_adapter, list_adapters


def _emit(payload: object) -> None:
    print(json.dumps(payload, indent=2, sort_keys=True))


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="ofloop adapter")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("list", help="list known agent adapters")
    show = sub.add_parser("show", help="show one adapter capability declaration")
    show.add_argument("adapter_id")
    doctor = sub.add_parser("doctor", help="validate one adapter contract in this checkout")
    doctor.add_argument("adapter_id")
    doctor.add_argument("--allow-unverified", action="store_true", help="allow static doctor PASS while live host verification is pending")
    return parser


def main(argv: list[str] | None = None, *, repo_root: Path | None = None) -> int:
    args = _parser().parse_args(argv)
    root = repo_root or Path(__file__).resolve().parents[2]

    if args.command == "list":
        _emit({"ok": True, "adapters": [adapter.to_dict() for adapter in list_adapters()]})
        return 0

    try:
        adapter = get_adapter(args.adapter_id)
    except KeyError:
        _emit({"ok": False, "error": "unknown adapter", "adapter_id": args.adapter_id})
        return 2

    if args.command == "show":
        _emit({"ok": True, "adapter": adapter.to_dict()})
        return 0

    failures = doctor_adapter(root, adapter.adapter_id)
    if not adapter.live_verified and not args.allow_unverified:
        failures.append("adapter is not live verified; use --allow-unverified for static contract doctor")
    _emit({"ok": not failures, "adapter": adapter.to_dict(), "doctor": "PASS" if not failures else "FAIL", "failures": failures})
    return 0 if not failures else 1
