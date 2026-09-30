#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONDONTWRITEBYTECODE=1

PYTHONPATH="$ROOT_DIR/lib" python3 -B <<'PY'
from __future__ import annotations

import copy

from ownframework_loop import program
from ownframework_loop.program_mission import _historical_repair_reconciliation_allocations

mission_id = "mission-0123456789abcdef01234567"
policy = {
    "schema": "ownframework-loop-semantic-budget-policy/v1",
    "reclaim_approved_checkpoint_capacity": True,
    "use_cumulative_slack": True,
}
meta = {
    "schema": "ownframework-work-packet/v4",
    "mission_budget": {"semantic_budget_policy": copy.deepcopy(policy)},
    "risk_budget": {
        "max_build_passes": 8,
        "max_review_passes": 8,
        "max_repair_rounds": 6,
        "max_consecutive_no_progress_passes": 8,
        "max_identical_finding_repeats": 8,
    },
    "checkpoint_graph": {
        "execution_order": ["CP-01", "CP-02", "CP-03", "CP-04"],
        "checkpoints": [
            {"id": cp_id, "risk_budget": {
                "max_build_passes": 2,
                "max_review_passes": 2,
                "max_repair_rounds": 1,
            }}
            for cp_id in ("CP-01", "CP-02", "CP-03", "CP-04")
        ],
    },
}

def claim(run, cp_id, used_before, cumulative_before, approved, event_no):
    return {
        "run_id": run,
        "checkpoint_id": cp_id,
        "timestamp": f"2026-09-30T00:00:{event_no:02d}Z",
        "candidate_sha": f"{event_no:040x}",
        "source_event_sha256": f"{event_no:064x}",
        "reason": "repair entitlement claimed atomically",
        "checkpoint_used_before": used_before,
        "cumulative_used_before": cumulative_before,
        "approved_checkpoints_before": approved,
    }

history = {
    "counts_by_checkpoint": {"CP-01": 2, "CP-02": 0, "CP-03": 2, "CP-04": 0},
    "claims": [
        claim("source-a", "CP-01", 0, 0, [], 1),
        claim("source-a", "CP-01", 1, 1, [], 2),
        claim("source-b", "CP-03", 0, 2, ["CP-01", "CP-02"], 3),
        claim("source-b", "CP-03", 1, 3, ["CP-01", "CP-02"], 4),
    ],
}
program_state = {
    "mission_segment": {"mission_id": mission_id},
    "semantic_budget_allocations": [],
}
allocations = _historical_repair_reconciliation_allocations(
    meta=meta, program_state=program_state, history=history,
)
assert len(allocations) == 2
assert allocations[0]["checkpoint_id"] == "CP-01"
assert allocations[0]["source_kind"] == "mission_cumulative_slack"
assert allocations[0]["source_event_sha256"] == history["claims"][1]["source_event_sha256"]
assert allocations[1]["checkpoint_id"] == "CP-03"
assert allocations[1]["source_kind"] == "approved_checkpoint_capacity"
assert allocations[1]["source_checkpoint_id"] == "CP-02"
assert allocations[1]["source_event_sha256"] == history["claims"][3]["source_event_sha256"]

bounded_meta = copy.deepcopy(meta)
reconciled = {
    "checkpoint_graph_sha256": program.checkpoint_graph_sha256(bounded_meta),
    "semantic_budget_policy_sha256": program.semantic_budget_policy_sha256(bounded_meta),
    "semantic_budget_allocations": allocations,
    "mission_segment": {"mission_id": mission_id},
    "finalized_checkpoints": [
        {"id": "CP-01", "terminal_state": "APPROVED"},
        {"id": "CP-02", "terminal_state": "APPROVED"},
    ],
    "checkpoints": [
        {"id": cp_id, "repair_round_count": history["counts_by_checkpoint"][cp_id]}
        for cp_id in bounded_meta["checkpoint_graph"]["execution_order"]
    ],
    "cumulative_counters": {"repair_round_count": 4},
    "cumulative_ceilings": {"max_repair_rounds": 6},
}
assert program.verify_frozen_graph(bounded_meta, reconciled) == (True, "ok")
assert reconciled["cumulative_ceilings"]["max_repair_rounds"] == 6
print("HISTORICAL_OVERAGE_BINDS_TO_EXACT_FUNDED_EVENTS=PASS")
print("CUMULATIVE_SLACK_AND_APPROVED_DONOR_RECONCILED=PASS")
print("FUTURE_AND_FINAL_ACCEPTANCE_RESERVE_PRESERVED=PASS")
print("NO_CUMULATIVE_CEILING_INCREASE=PASS")

exhausted_meta = copy.deepcopy(meta)
exhausted_meta["risk_budget"]["max_repair_rounds"] = 4
try:
    _historical_repair_reconciliation_allocations(
        meta=exhausted_meta, program_state=program_state, history=history,
    )
except Exception as exc:
    assert "reserve" in str(exc) or "authority" in str(exc), exc
else:
    raise AssertionError("historical overage borrowed beyond mission/future authority")
print("EXHAUSTED_MISSION_AUTHORITY_REFUSED=PASS")
PY
