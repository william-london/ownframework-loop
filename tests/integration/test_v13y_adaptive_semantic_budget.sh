#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONDONTWRITEBYTECODE=1

PYTHONPATH="$ROOT_DIR/lib" python3 -B <<'PY'
import copy
from ownframework_loop import packet as packet_module, program

POLICY = {
    "schema": "ownframework-loop-semantic-budget-policy/v1",
    "reclaim_approved_checkpoint_capacity": True,
    "use_cumulative_slack": True,
}
CAPS = {"max_build_passes": 1, "max_review_passes": 1, "max_repair_rounds": 1}

def packet(policy=True):
    budget = {
        "schema": "ownframework-loop-mission-budget/v1",
        "auto_segment": True,
        "segment_max_diff_lines": 10,
        "mission_max_diff_lines": 100,
        "max_segments": 2,
        "segment_boundary_policy": "last_approved_checkpoint",
    }
    if policy:
        budget["semantic_budget_policy"] = copy.deepcopy(POLICY)
    cps = []
    for cp_id in ("CP-01", "CP-02", "CP-03"):
        cps.append({
            "id": cp_id,
            "risk_budget": copy.deepcopy(CAPS),
        })
    return {
        "schema": "ownframework-work-packet/v4",
        "mission_budget": budget,
        "checkpoint_graph": {
            "execution_order": ["CP-01", "CP-02", "CP-03"],
            "checkpoints": cps,
        },
        "risk_budget": {
            "max_build_passes": 7,
            "max_review_passes": 7,
            "max_repair_rounds": 7,
            "max_consecutive_no_progress_passes": 8,
            "max_identical_finding_repeats": 8,
        },
    }

def program_state(meta):
    state = {
        "checkpoint_graph_sha256": program.checkpoint_graph_sha256(meta),
        "cumulative_counters": {
            "build_pass_count": 1,
            "review_pass_count": 1,
            "repair_round_count": 1,
        },
        "cumulative_ceilings": {
            "max_build_passes": 7,
            "max_review_passes": 7,
            "max_repair_rounds": 7,
        },
        "checkpoints": [
            {"id": "CP-01", "build_pass_count": 0, "review_pass_count": 0,
             "repair_round_count": 0, "no_progress_streak": 0, "terminal": "APPROVED"},
            {"id": "CP-02", "build_pass_count": 1, "review_pass_count": 1,
             "repair_round_count": 1, "no_progress_streak": 0, "terminal": ""},
            {"id": "CP-03", "build_pass_count": 0, "review_pass_count": 0,
             "repair_round_count": 0, "no_progress_streak": 0, "terminal": ""},
        ],
        "finalized_checkpoints": [{"id": "CP-01", "terminal_state": "APPROVED"}],
        "mission_segment": {"mission_id": "mission-0123456789abcdef01234567"},
        "semantic_budget_allocations": [],
    }
    if "semantic_budget_policy" in meta["mission_budget"]:
        state["semantic_budget_policy_sha256"] = program.semantic_budget_policy_sha256(meta)
    return state

meta = packet()
meta["execution_mode"] = "program"
meta["risk_budget"]["max_diff_lines"] = 10
meta["checkpoint_graph"]["global_source_ceilings"] = {
    "max_baseline_to_final_diff_lines": 10,
}
assert packet_module.validate_mission_budget(meta) == []
invalid_policy = copy.deepcopy(meta)
invalid_policy["mission_budget"]["semantic_budget_policy"]["unrecognized"] = True
assert any(
    "must contain exactly" in error
    for error in packet_module.validate_mission_budget(invalid_policy)
)
disabled_policy = copy.deepcopy(meta)
disabled_policy["mission_budget"]["semantic_budget_policy"] = {
    "schema": "ownframework-loop-semantic-budget-policy/v1",
    "reclaim_approved_checkpoint_capacity": False,
    "use_cumulative_slack": False,
}
assert any(
    "must enable at least one" in error
    for error in packet_module.validate_mission_budget(disabled_policy)
)
print("V4_POLICY_MUST_BE_EXPLICIT_TYPED_AND_NONEMPTY=PASS")
ps = program_state(meta)
state_doc = {"state": "READY_TO_BUILD", "run_id": "fixture-run", "no_progress_streak": 0}
assert program.minimum_one_repair_final_acceptance_reserve("build_pass_count") == 1
assert program.minimum_one_repair_final_acceptance_reserve("repair_round_count") == 1
assert program.minimum_one_repair_final_acceptance_reserve("review_pass_count") == 2
print("FINAL_REVIEW_BUILD_RESERVE=1 PASS")
print("FINAL_REVIEW_REPAIR_RESERVE=1 PASS")
print("FINAL_REVIEW_REVIEW_RESERVE=2 PASS")
plan = program.semantic_budget_allocation_plan(
    ps, packet=meta, cp_id="CP-02", counter="build_pass_count", state_doc=state_doc,
    run_id="fixture-run",
)
assert plan["eligible"] is True, plan
assert plan["allocation"]["amount_borrowed"] == 1
assert plan["allocation"]["source_kind"] == "approved_checkpoint_capacity"
assert plan["allocation"]["source_checkpoint_id"] == "CP-01"
assert plan["allocation"]["reclaimable_pool_after"] == plan["allocation"]["reclaimable_pool_before"] - 1
assert plan["allocation"]["final_acceptance_reserve"] == 1
claimed = program._bump_counter_one(
    ps, cp_id="CP-02", counter="build_pass_count",
    packet_cp=meta["checkpoint_graph"]["checkpoints"][1], packet=meta,
    state_doc=state_doc, run_id="fixture-run",
)
assert claimed["cumulative_ceilings"]["max_build_passes"] == 7
assert claimed["cumulative_counters"]["build_pass_count"] == 2
assert claimed["checkpoints"][1]["build_pass_count"] == 2
assert len(claimed["semantic_budget_allocations"]) == 1
assert len(ps["semantic_budget_allocations"]) == 0, "allocation mutated caller snapshot"
print("ONE_CLAIM_APPROVED_UNUSED_RECLAIM_WITHOUT_CEILING_CHANGE=PASS")

# Borrowing the only approved local reserve is not enough to steal the future
# checkpoint or mandatory final-repair floor.
near_ceiling = copy.deepcopy(ps)
near_ceiling["cumulative_counters"]["build_pass_count"] = 5
blocked = program.semantic_budget_allocation_plan(
    near_ceiling, packet=meta, cp_id="CP-02", counter="build_pass_count",
    state_doc=state_doc, run_id="fixture-run",
)
assert blocked["eligible"] is False
assert blocked["reason"] == "allocation_would_consume_future_or_final_acceptance_reserve", blocked
print("FUTURE_CHECKPOINT_AND_FINAL_ACCEPTANCE_FLOOR_PRESERVED=PASS")

# REVIEW borrowing must preserve two whole-product final-review attempts, not
# merely one. CP-03 still requires its declared review, so a claim that would
# leave only one additional review is refused before allocation.
review_near_ceiling = copy.deepcopy(ps)
review_near_ceiling["cumulative_counters"]["review_pass_count"] = 4
review_blocked = program.semantic_budget_allocation_plan(
    review_near_ceiling, packet=meta, cp_id="CP-02",
    counter="review_pass_count",
    state_doc={**state_doc, "state": "READY_FOR_REVIEW"}, run_id="fixture-run",
)
assert review_blocked["eligible"] is False, review_blocked
assert review_blocked["reason"] == "allocation_would_consume_future_or_final_acceptance_reserve"
assert review_blocked["reserved_remaining_authority"] == 3
print("ADAPTIVE_REVIEW_CANNOT_STARVE_REREVIEW=PASS")

global_exhausted = copy.deepcopy(ps)
global_exhausted["cumulative_counters"]["build_pass_count"] = 7
assert program.semantic_budget_allocation_plan(
    global_exhausted, packet=meta, cp_id="CP-02", counter="build_pass_count",
    state_doc=state_doc, run_id="fixture-run",
)["reason"] == "mission_cumulative_authority_exhausted"
assert program.semantic_budget_allocation_plan(
    ps, packet=meta, cp_id="CP-02", counter="build_pass_count",
    state_doc={**state_doc, "state": "STOPPED"}, run_id="fixture-run",
)["eligible"] is False
assert program.semantic_budget_allocation_plan(
    ps, packet=meta, cp_id="CP-02", counter="build_pass_count",
    state_doc={**state_doc, "no_progress_streak": 8}, run_id="fixture-run",
)["reason"] == "no_progress_fuse_reached"
print("CUMULATIVE_STOPPED_AND_NO_PROGRESS_GATES=PASS")

# The same typed allocator applies to REVIEW and REPAIR claims.
for counter, phase in (("review_pass_count", "READY_FOR_REVIEW"),
                       ("repair_round_count", "REVIEWING")):
    trial = program_state(meta)
    proof = program.semantic_budget_allocation_plan(
        trial, packet=meta, cp_id="CP-02", counter=counter,
        state_doc={"state": phase, "run_id": "fixture-run", "no_progress_streak": 0},
        run_id="fixture-run",
    )
    assert proof["eligible"] is True, (counter, proof)
    assert proof["allocation"]["final_acceptance_reserve"] == (
        2 if counter == "review_pass_count" else 1
    )
    claimed = program._bump_counter_one(
        trial, cp_id="CP-02", counter=counter,
        packet_cp=meta["checkpoint_graph"]["checkpoints"][1], packet=meta,
        state_doc={"state": phase, "run_id": "fixture-run", "no_progress_streak": 0},
        run_id="fixture-run",
    )
    assert claimed["cumulative_counters"][counter] == 2
    assert claimed["checkpoints"][1][counter] == 2
    assert claimed["semantic_budget_allocations"][-1]["counter_kind"] == counter
print("REVIEW_AND_REPAIR_TYPED_ALLOCATION=PASS")

# Historical v1-v3 and v4 packets without an explicit policy retain hard local
# caps: no new authority can be inferred from cumulative slack alone.
legacy = packet(policy=False)
legacy_state = program_state(legacy)
assert program.semantic_budget_allocation_plan(
    legacy_state, packet=legacy, cp_id="CP-02", counter="build_pass_count",
    state_doc=state_doc, run_id="fixture-run",
)["reason"] == "adaptive_policy_not_sealed"
try:
    program._bump_counter_one(
        legacy_state, cp_id="CP-02", counter="build_pass_count",
        packet_cp=legacy["checkpoint_graph"]["checkpoints"][1], packet=legacy,
        state_doc=state_doc, run_id="fixture-run",
    )
except program.ProgramStateError as exc:
    assert "per-checkpoint cap reached" in str(exc)
else:
    raise AssertionError("unopted mission borrowed authority")
assert program.verify_frozen_graph(legacy, legacy_state) == (True, "ok")
print("HISTORICAL_AND_UNOPTED_LOCAL_CAP_SEMANTICS=PASS")

# Repeated allocations remain bounded by the same cumulative ceiling and the
# approved donor can never be overdrawn.
allocated = program._bump_counter_one(
    ps, cp_id="CP-02", counter="build_pass_count",
    packet_cp=meta["checkpoint_graph"]["checkpoints"][1], packet=meta,
    state_doc=state_doc, run_id="fixture-run",
)
assert allocated["semantic_budget_allocations"][0]["source_checkpoint_id"] == "CP-01"
donor_remaining = 1 - sum(
    item["amount_borrowed"] for item in allocated["semantic_budget_allocations"]
    if item["source_checkpoint_id"] == "CP-01"
)
assert donor_remaining == 0
print("NO_DUPLICATE_DONOR_ALLOCATION=PASS")
PY
