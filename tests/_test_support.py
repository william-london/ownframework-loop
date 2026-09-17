"""Test-only support helpers for OwnFramework Loop.

NOT a production module. Imported by integration tests that need to
synthesize a valid pre-seal WORK_PACKET.md before calling
supervisor.enqueue directly (without going through `spec new`).
"""
from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any


_FENCE = "`" * 3


def minimal_valid_packet(
    *,
    run_id: str,
    canonical_repo: Path,
    work_class: str = "FEATURE",
    risk_class: str = "low",
    branch: str = "master",
    title: str | None = None,
) -> dict[str, Any]:
    """Return the smallest valid v3 packet that satisfies
    ``packet.validate_packet_for_approval``.

    Tests that call ``supervisor.enqueue(...)`` directly without
    ``spec new`` must first call ``write_minimal_valid_packet(...)``
    (below) with the dict returned by this helper.
    """
    rid_short = re.sub(r"[^A-Za-z0-9_-]", "", run_id)[:64] or "fixture"
    return {
        "schema": "ownframework-work-packet/v3",
        "packet_id": f"min-{rid_short}",
        "created_at": "2026-09-17T00:00:00Z",
        "work_class": work_class,
        "risk_class": risk_class,
        "title": title or f"minimal valid v3 fixture for {run_id}",
        "target": {
            "repo": str(canonical_repo.resolve(strict=False)),
            "branch": branch,
            "classification": "local_only",
        },
        "execution_mode": "single",
        "acceptance_criteria": [{"id": "AC-1", "text": "ok"}],
        "non_goals": [],
        "allowed_paths": ["a.txt"],
        "protected_paths": [".ownframework-loop/"],
        "work_units": [{"id": "UNIT-1", "title": "u", "scope": "do"}],
        "merge_authority": "human_only",
        "deploy_authority": "human_only",
        "push_authority": "human_only",
        "external_action_authority": "none",
        "risk_budget": {
            "max_build_passes": 5, "max_review_passes": 5, "max_repair_rounds": 1,
            "max_files_changed": 5, "max_diff_lines": 100,
        },
    }


def write_minimal_valid_packet(
    canonical_repo: Path,
    run_id: str,
    *,
    work_class: str = "FEATURE",
    risk_class: str = "low",
    branch: str = "master",
    title: str | None = None,
    packet: dict[str, Any] | None = None,
) -> Path:
    """Write a minimal valid v3 WORK_PACKET.md for ``run_id`` under
    ``canonical_repo``. Returns the written path.

    Tests that bypass ``spec new`` and call ``supervisor.enqueue(...)``
    directly must invoke this first, or the admission backstop will
    refuse with ``pre_seal_packet_missing``.

    Pass ``packet=`` to write a caller-supplied dict (e.g. for
    assertions on specific packet fields). Callers MUST NOT pass
    a packet whose bytes are bound to an APPROVAL.json (the approval
    SHA drift contract would break).
    """
    run_dir = Path(canonical_repo) / ".ownframework-loop" / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    pkt = packet if packet is not None else minimal_valid_packet(
        run_id=run_id, canonical_repo=canonical_repo,
        work_class=work_class, risk_class=risk_class, branch=branch, title=title,
    )
    path = run_dir / "WORK_PACKET.md"
    path.write_text(
        _FENCE + "json\n" + json.dumps(pkt, sort_keys=True) + "\n" + _FENCE + "\n",
        encoding="utf-8",
    )
    return path


def restore_packet_parser(real_parse):
    """Restore ``supervisor.packet_mod.parse_packet_file`` to ``real_parse``.

    Tests that monkey-patch ``parse_packet_file`` to simulate a stale
    or corrupt packet must restore the original after the sub-test
    that needs the patch. Use as a context manager boundary:

        with restore_packet_parser(supervisor.packet_mod.parse_packet_file):
            supervisor.packet_mod.parse_packet_file = lambda p: ({}, "")
            ...sub-test body...

    Or as a try/finally:

        saved = supervisor.packet_mod.parse_packet_file
        try:
            supervisor.packet_mod.parse_packet_file = lambda p: ({}, "")
            ...
        finally:
            supervisor.packet_mod.parse_packet_file = saved
    """
    # The caller is responsible for saving/restoring; this function
    # is documented as a marker. It does NOT install a context manager
    # because tests have heterogeneous patch patterns. We simply return
    # a callable that, when invoked, restores the saved parser.
    def _restore() -> None:
        from ownframework_loop import supervisor as _supervisor  # local import
        _supervisor.packet_mod.parse_packet_file = real_parse
    return _restore
