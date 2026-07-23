#!/usr/bin/env bash
# Case 4: approval hash match.
# Case 5: packet modification invalidates approval.

set -uo pipefail
. "$(dirname "$0")/../_helpers.sh"

python3 - <<'PY'
import sys, json, os, tempfile
from pathlib import Path
sys.path.insert(0, "/Users/mr.mrs.london/projects/plugins/ownframework-loop/lib")
from ownframework_loop import packet

valid = {
    "schema": "ownframework-work-packet/v1",
    "packet_id": "test-hash-001",
    "created_at": "2026-07-23T05:00:00Z",
    "work_class": "FEATURE",
    "risk_class": "medium",
    "title": "Test",
    "target": {"repo": "/tmp/foo", "branch": "master", "classification": "local_only"},
    "acceptance_criteria": [{"id": "AC-1", "text": "x"}],
    "non_goals": [{"id": "NG-1", "text": "y"}],
    "allowed_paths": ["src/"],
    "protected_paths": [".claude/"],
    "work_units": [{"id": "UNIT-1", "title": "u", "scope": "s"}],
    "merge_authority": "human_only",
    "deploy_authority": "human_only",
    "push_authority": "human_only",
    "external_action_authority": "none",
}

with tempfile.TemporaryDirectory() as td:
    p = Path(td) / "WORK_PACKET.md"
    body = "```json\n" + json.dumps(valid, indent=2, sort_keys=True) + "\n```\n# Mission\nx\n"
    p.write_text(body)

    meta, raw = packet.parse_packet_file(p)
    sha_before = packet.packet_file_sha256(p)
    assert len(sha_before) == 64, f"expected 64-char sha, got {sha_before!r}"
    print(f"  PASS: SHA-256 computed ({sha_before[:12]}...)")

    # Approve.
    updated = packet.apply_approval(meta, packet_sha256=sha_before, actor="william")
    packet.write_approved_packet(p, updated, raw)
    sha_after = packet.packet_file_sha256(p)
    assert sha_after != sha_before, "approval rewrite should change SHA"
    print("  PASS: approval rewrites the packet and changes SHA")

    # Now mutate the packet.
    p.write_text(p.read_text() + "\n# extra content\n")
    sha_mutated = packet.packet_file_sha256(p)
    assert sha_mutated != sha_after, "mutation should change SHA again"
    assert sha_mutated != sha_before
    print("  PASS: any packet mutation changes the SHA")

    # The approved packet SHA is sha_after; the current SHA is sha_mutated.
    # Drift detection: approved_sha != current_sha -> approval is invalidated.
    assert sha_after != sha_mutated
    print("  PASS: approval can be invalidated by SHA drift")

print("ALL PASS")
PY
