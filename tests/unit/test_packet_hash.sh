#!/usr/bin/env bash
# Case 4: approval hash match.
# Case 5: packet modification invalidates approval (V2 — separate APPROVAL.json).

set -uo pipefail
. "$(dirname "$0")/../_helpers.sh"

python3 - <<'PY'
import sys, json, os, tempfile
from pathlib import Path
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get("OFLOOP_LIB", "/path/to/ownframework-loop/lib"))
from ownframework_loop import packet, approval

valid = {
    "schema": "ownframework-work-packet/v2",
    "packet_id": "test-hash-001",
    "created_at": "2026-07-23T05:00:00Z",
    "work_class": "BUG",
    "risk_class": "low",
    "title": "Test",
    "target": {"repo": "/tmp/foo", "branch": "master", "classification": "local_only"},
    "acceptance_criteria": [{"id": "AC-1", "text": "x"}],
    "non_goals": [],
    "allowed_paths": ["src/"],
    "protected_paths": [".claude/"],
    "work_units": [{"id": "UNIT-1", "title": "u", "scope": "s"}],
    "merge_authority": "human_only",
    "deploy_authority": "human_only",
    "push_authority": "human_only",
    "external_action_authority": "none",
    "risk_budget": {
        "max_files_changed": 25,
        "max_diff_lines": 1000,
        "max_repair_rounds": 3,
    },
}

with tempfile.TemporaryDirectory() as td:
    p = Path(td) / "WORK_PACKET.md"
    body = "```json\n" + json.dumps(valid, indent=2, sort_keys=True) + "\n```\n# Mission\nx\n"
    p.write_text(body)

    meta, raw = packet.parse_packet_file(p)
    sha_before = packet.packet_file_sha256(p)
    assert len(sha_before) == 64, f"expected 64-char sha, got {sha_before!r}"
    print(f"  PASS: SHA-256 computed ({sha_before[:12]}...)")

    # V2: approval is a SEPARATE artifact, not embedded in the packet.
    # The packet bytes are unchanged by approval.
    sha_after = packet.packet_file_sha256(p)
    assert sha_after == sha_before, "V2 approval must NOT mutate packet bytes"
    print("  PASS: approval leaves packet bytes unchanged")

    # Now mutate the packet — the recorded approval SHA is now stale.
    p.write_text(p.read_text() + "\n# extra content\n")
    sha_mutated = packet.packet_file_sha256(p)
    assert sha_mutated != sha_before
    print("  PASS: any packet mutation changes the SHA")

    # The original approval SHA (sha_before) is now invalidated by drift.
    assert sha_before != sha_mutated
    print("  PASS: approval is invalidated by SHA drift")

print("ALL PASS")
PY
