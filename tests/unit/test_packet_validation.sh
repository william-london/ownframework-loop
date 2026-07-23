#!/usr/bin/env bash
# Case 1: valid work-packet creation.
# Case 2: invalid packet rejection.

set -uo pipefail
. "$(dirname "$0")/../_helpers.sh"

python3 - <<'PY'
import sys, json
sys.path.insert(0, "/Users/mr.mrs.london/projects/plugins/ownframework-loop/lib")
from ownframework_loop import packet

# Valid packet.
valid = {
    "schema": "ownframework-work-packet/v1",
    "packet_id": "test-001",
    "created_at": "2026-07-23T05:00:00Z",
    "work_class": "FEATURE",
    "risk_class": "medium",
    "title": "Test feature",
    "target": {"repo": "/tmp/foo", "branch": "master", "classification": "local_only"},
    "acceptance_criteria": [{"id": "AC-1", "text": "AC1"}],
    "non_goals": [{"id": "NG-1", "text": "NG1"}],
    "allowed_paths": ["src/"],
    "protected_paths": [".claude/"],
    "work_units": [{"id": "UNIT-1", "title": "u1", "scope": "s1"}],
    "merge_authority": "human_only",
    "deploy_authority": "human_only",
    "push_authority": "human_only",
    "external_action_authority": "none",
}
errors = packet.validate_packet_metadata(valid)
assert errors == [], f"expected no errors, got {errors}"
print("  PASS: valid packet has zero validation errors")

# Missing required field.
bad = dict(valid)
del bad["title"]
errors = packet.validate_packet_metadata(bad)
assert any("title" in e for e in errors), f"expected title error, got {errors}"
print("  PASS: missing required field detected")

# Invalid work_class.
bad = dict(valid)
bad["work_class"] = "INVALID"
errors = packet.validate_packet_metadata(bad)
assert any("work_class" in e for e in errors), f"expected work_class error, got {errors}"
print("  PASS: invalid work_class detected")

# Bad authority.
bad = dict(valid)
bad["merge_authority"] = "auto"
errors = packet.validate_packet_metadata(bad)
assert any("merge_authority" in e for e in errors), f"expected merge_authority error, got {errors}"
print("  PASS: invalid merge_authority detected")

# Non-absolute repo path.
bad = dict(valid)
bad["target"] = {"repo": "relative/path", "branch": "master", "classification": "local_only"}
errors = packet.validate_packet_metadata(bad)
assert any("absolute" in e for e in errors), f"expected absolute path error, got {errors}"
print("  PASS: non-absolute repo path rejected")

# Empty allowed_paths.
bad = dict(valid)
bad["allowed_paths"] = []
errors = packet.validate_packet_metadata(bad)
assert any("allowed_paths" in e for e in errors), f"expected allowed_paths error, got {errors}"
print("  PASS: empty allowed_paths rejected")

# Bad classification.
bad = dict(valid)
bad["target"]["classification"] = "evil"
errors = packet.validate_packet_metadata(bad)
assert any("classification" in e for e in errors), f"expected classification error, got {errors}"
print("  PASS: invalid classification rejected")

print("ALL PASS")
PY
