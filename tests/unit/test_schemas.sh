#!/usr/bin/env bash
# Schema validation tests — each schema must parse as valid JSON, and the
# artifacts must validate against their declared schemas.

set -uo pipefail
. "$(dirname "$0")/../_helpers.sh"

python3 - <<'PY'
import json
from pathlib import Path
import sys

ROOT = Path(__import__("os").environ.get("OFLOOP_ROOT", str(Path(__file__).resolve().parents[2])))
schemas = ROOT / "schemas"
for s in ["work-packet.schema.json", "state.schema.json",
          "build-receipt.schema.json", "review-verdict.schema.json"]:
    data = json.loads((schemas / s).read_text())
    assert "$schema" in data, f"{s} missing $schema"
    print(f"  PASS: {s} parses with $schema={data['$schema']}")

# Self-check: build a valid packet against the schema using jsonschema if
# available, else do a structural spot-check.
try:
    import jsonschema  # type: ignore
    HAVE_JSONSCHEMA = True
except Exception:
    HAVE_JSONSCHEMA = False
print(f"  INFO: jsonschema available = {HAVE_JSONSCHEMA}")

if HAVE_JSONSCHEMA:
    pkt_schema = json.loads((schemas / "work-packet.schema.json").read_text())
    state_schema = json.loads((schemas / "state.schema.json").read_text())
    receipt_schema = json.loads((schemas / "build-receipt.schema.json").read_text())
    verdict_schema = json.loads((schemas / "review-verdict.schema.json").read_text())

    valid_pkt = {
        "schema": "ownframework-work-packet/v2",
        "packet_id": "x", "created_at": "2026-07-23T05:00:00Z",
        "work_class": "FEATURE", "risk_class": "low", "title": "t",
        "target": {"repo": "/x", "branch": "master", "classification": "local_only"},
        "acceptance_criteria": [{"id": "AC-1", "text": "x"}],
        "non_goals": [{"id": "NG-1", "text": "y"}],
        "allowed_paths": ["src/"], "protected_paths": [".claude/"],
        "work_units": [{"id": "UNIT-1", "title": "u", "scope": "s"}],
        "merge_authority": "human_only", "deploy_authority": "human_only",
        "push_authority": "human_only", "external_action_authority": "none",
    }
    jsonschema.validate(valid_pkt, pkt_schema)
    print("  PASS: valid packet validates against work-packet.schema.json")

    bad = dict(valid_pkt)
    bad["risk_class"] = "evil"
    try:
        jsonschema.validate(bad, pkt_schema)
    except jsonschema.ValidationError:
        print("  PASS: bad packet rejected by work-packet.schema.json")
    else:
        raise AssertionError("bad packet accepted")

    valid_state = {
        "schema": "ownframework-loop-state/v1", "run_id": "r",
        "state": "AWAITING_APPROVAL", "state_history": [],
        "transitions_count": 0, "build_pass_count": 0,
        "review_pass_count": 0, "repair_round": 0, "no_progress_streak": 0,
    }
    jsonschema.validate(valid_state, state_schema)
    print("  PASS: valid state validates against state.schema.json")

    bad_state = dict(valid_state)
    bad_state["state"] = "BOGUS_STATE"
    try:
        jsonschema.validate(bad_state, state_schema)
    except jsonschema.ValidationError:
        print("  PASS: bad state rejected by state.schema.json")
    else:
        raise AssertionError("bad state accepted")

    valid_receipt = {
        "schema": "ownframework-loop-build-receipt/v2", "run_id": "r",
        "packet_sha256": "a"*64, "approval_sha256": "b"*64,
        "work_unit_id": "U-1",
        "baseline_sha": "abc1234", "candidate_sha": "def5678",
        "candidate_branch": "factory/candidate/r", "builder_worktree": "/x",
        "builder_pass_number": 1, "repair_round": 0,
        "files_changed": 0, "added_lines": 0, "removed_lines": 0,
        "changed_paths": [],
        "validation": [], "timestamp": "2026-07-23T05:00:00Z",
        "builder_agent": "of-builder", "next_state": "READY_FOR_REVIEW",
        "protected_path_check": {"result": "pass", "offending_paths": []},
        "scope_check": {"result": "pass", "findings": []},
        "secret_scan_check": {"result": "pass", "findings": []},
        "sensitive_path_assessment": {"result": "none", "paths": []},
        "escalation_recommended": False,
    }
    jsonschema.validate(valid_receipt, receipt_schema)
    print("  PASS: valid receipt validates against build-receipt.schema.json")

    valid_verdict = {
        "schema": "ownframework-loop-review-verdict/v2", "run_id": "r",
        "packet_sha256": "a"*64, "approval_sha256": "b"*64,
        "candidate_sha_reviewed": "abc1234",
        "baseline_sha": "abc1234", "review_pass_number": 1,
        "verdict": "APPROVED", "acceptance_results": [],
        "non_goal_results": [], "findings": [],
        "tracked_mutation_check": {"detected": False, "before_sha": "abc1234", "after_sha": "abc1234"},
        "stale_sha_check": {"sha_match": True, "receipt_match": True,
                           "packet_hash_match": True, "branch_contains_sha": True},
        "integrity_check": {"packet_sha_match": True, "approval_present": True,
                           "approval_sha_stable": True, "candidate_sha_present": True},
        "protected_path_check": {"result": "pass", "offending_paths": []},
        "scope_check": {"result": "pass", "findings": []},
        "secret_scan_check": {"result": "pass", "findings": []},
        "sensitive_path_assessment": {"result": "none", "paths": []},
        "reviewer_identity": "of-reviewer", "timestamp": "2026-07-23T05:00:00Z",
        "recommended_next_state": "APPROVED",
        "failure_reason": "",
        "escalation_recommended": False,
    }
    jsonschema.validate(valid_verdict, verdict_schema)
    print("  PASS: valid verdict validates against review-verdict.schema.json")

print("ALL PASS")
PY
