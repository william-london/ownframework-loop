#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONDONTWRITEBYTECODE=1
TMP="$(mktemp -d -t ofloop-v13z-budget-crash.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

PYTHONPATH="$ROOT_DIR/lib" python3 -B - "$TMP" <<'PY'
from __future__ import annotations

import copy
import json
import sys
from pathlib import Path

from ownframework_loop import program, schema_validate, state

repo = Path(sys.argv[1]) / "repo"
repo.mkdir()
run_id = "budget-crash-0001"
run_root = state.run_dir(repo, run_id)
run_root.mkdir(parents=True)
policy = {
    "schema": "ownframework-loop-semantic-budget-policy/v1",
    "reclaim_approved_checkpoint_capacity": False,
    "use_cumulative_slack": True,
}
meta = {
    "schema": "ownframework-work-packet/v4",
    "mission_budget": {"semantic_budget_policy": policy},
    "risk_budget": {
        "max_build_passes": 4,
        "max_review_passes": 4,
        "max_repair_rounds": 4,
        "max_consecutive_no_progress_passes": 8,
        "max_identical_finding_repeats": 8,
    },
    "checkpoint_graph": {
        "execution_order": ["CP-01", "CP-02"],
        "checkpoints": [
            {"id": "CP-01", "depends_on": [], "risk_budget": {
                "max_build_passes": 1, "max_review_passes": 1,
                "max_repair_rounds": 1,
            }},
            {"id": "CP-02", "depends_on": ["CP-01"], "risk_budget": {
                "max_build_passes": 1, "max_review_passes": 1,
                "max_repair_rounds": 1,
            }},
        ],
    },
}
(run_root / "WORK_PACKET.md").write_text(
    "```json\n" + json.dumps(meta, sort_keys=True, indent=2) + "\n```\n",
    encoding="utf-8",
)
initial = state.initial_state(run_id)
initial.update({
    "spec_baseline_branch": "master",
    "spec_baseline_sha": "a" * 40,
    "spec_snapshot_at": initial["updated_at"],
})
state.save(repo, run_id, initial)
program_state = {
    "execution_mode": "program",
    "checkpoint_graph_sha256": program.checkpoint_graph_sha256(meta),
    "promotion_policy": "human_gate",
    "review_scope": None,
    "current_checkpoints": ["CP-01"],
    "finalized_checkpoints": [],
    "cumulative_counters": {
        "build_pass_count": 0, "review_pass_count": 0,
        "repair_round_count": 0, "files_changed_unique": 0,
        "diff_lines_total": 0,
    },
    "cumulative_ceilings": {
        "max_build_passes": 4, "max_review_passes": 4,
        "max_repair_rounds": 4,
        "max_unique_changed_files": 500,
        "max_baseline_to_final_diff_lines": 1000,
    },
    "checkpoints": [
        {"id": cp_id, "build_pass_count": 0, "review_pass_count": 0,
         "repair_round_count": 0, "no_progress_streak": 0,
         "candidate_sha": None, "build_receipt_sha256": None,
         "verdict_sha256": None, "terminal": "",
         "checkpoint_entry_candidate_sha": "a" * 40}
        for cp_id in ("CP-01", "CP-02")
    ],
    "blocked": False,
    "source_sha_provenance": {
        "baseline_sha": "a" * 40,
        "candidate_branch": "candidate",
        "captured_at": initial["updated_at"],
        "envelope_source": "fixture",
        "packet_global_cap": {
            "max_build_passes": 4, "max_review_passes": 4,
            "max_repair_rounds": 4,
        },
        "checkpoint_sum_cap": {
            "max_build_passes": 2, "max_review_passes": 2,
            "max_repair_rounds": 2,
        },
    },
    "mission_segment": {
        "schema": "ownframework-loop-mission-segment-state/v1",
        "mission_id": "mission-0123456789abcdef01234567",
        "segment_number": 1,
        "predecessor_run_id": None,
        "mission_authority_sha256": "b" * 64,
        "segment_authority_sha256": "c" * 64,
        "mission_original_baseline_sha": "a" * 40,
        "segment_baseline_sha": "a" * 40,
        "mission_source_lines_at_start": 0,
    },
    "semantic_budget_policy_sha256": program.semantic_budget_policy_sha256(meta),
    "semantic_budget_allocations": [],
}
state.program_transition(
    repo, run_id, to_state="READY_TO_BUILD", actor="test",
    reason="prepare claim fixture", program_block=program_state,
    schema_version=state.PROGRAM_STATE_SCHEMA_VERSION,
)

# Simulate the first local claim having been used, while the next checkpoint
# remains the current claim owner and the sealed cumulative slack is intact.
with state._locked_state(repo, run_id) as current:
    seeded = copy.deepcopy(current)
    seeded["build_pass_count"] = 1
    seeded["program"]["cumulative_counters"]["build_pass_count"] = 1
    seeded["program"]["checkpoints"][0]["build_pass_count"] = 1
    state._write_state_locked(repo, run_id, seeded)

original_plan = program.semantic_budget_allocation_plan
program.semantic_budget_allocation_plan = lambda *args, **kwargs: (_ for _ in ()).throw(
    RuntimeError("simulated crash before allocation publication")
)
try:
    try:
        program.claim_build_pass(canonical_repo=repo, run_id=run_id, packet=meta)
    except RuntimeError as exc:
        assert "before allocation publication" in str(exc)
    else:
        raise AssertionError("fault injection did not interrupt the pre-publication claim")
finally:
    program.semantic_budget_allocation_plan = original_plan
before = state.load_verified(repo, run_id)
assert before["build_pass_count"] == 1
assert before["program"]["semantic_budget_allocations"] == []
assert before["program"]["cumulative_counters"]["build_pass_count"] == 1
print("CRASH_BEFORE_PUBLICATION_LEAVES_NO_AUTHORITY=PASS")

# Fail after STATE replacement but before the event append. The write-ahead
# transaction must recover both the one-claim allocation and its event bind.
original_append = state._append_event_locked
state._append_event_locked = lambda *args, **kwargs: (_ for _ in ()).throw(
    OSError("simulated crash after state publication")
)
try:
    try:
        program.claim_build_pass(canonical_repo=repo, run_id=run_id, packet=meta)
    except OSError as exc:
        assert "after state publication" in str(exc)
    else:
        raise AssertionError("fault injection did not interrupt the transaction")
finally:
    state._append_event_locked = original_append

recovered = state.load_verified(repo, run_id)
assert schema_validate.validate_state(recovered) == [], schema_validate.validate_state(recovered)
assert recovered["state"] == "BUILDING"
assert recovered["build_pass_count"] == 2
assert recovered["program"]["cumulative_counters"]["build_pass_count"] == 2
assert recovered["program"]["checkpoints"][0]["build_pass_count"] == 2
assert len(recovered["program"]["semantic_budget_allocations"]) == 1
allocation = recovered["program"]["semantic_budget_allocations"][0]
events = __import__("ownframework_loop.integrity", fromlist=["read_event_chain"]).read_event_chain(
    state.events_path(repo, run_id)
)
assert any(
    event.get("semantic_budget_allocation_id") == allocation["allocation_id"]
    for event in events
)
replay = program.claim_build_pass(canonical_repo=repo, run_id=run_id, packet=meta)
after = state.load_verified(repo, run_id)
assert replay["replayed"] is True, replay
assert after["build_pass_count"] == 2
assert len(after["program"]["semantic_budget_allocations"]) == 1
print("CRASH_AFTER_PUBLICATION_RECOVERS_ONE_CLAIM=PASS")
print("REPLAY_DOES_NOT_DUPLICATE_ALLOCATION_OR_COUNTER=PASS")
print("ALLOCATION_CLAIM_EVENT_BINDING_DURABLE=PASS")
PY
