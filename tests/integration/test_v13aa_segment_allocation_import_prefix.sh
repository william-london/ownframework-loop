#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONDONTWRITEBYTECODE=1

PYTHONPATH="$ROOT_DIR/lib" python3 -B <<'PY'
from __future__ import annotations

import copy
import hashlib

from ownframework_loop import integrity, state


def allocation(number: int) -> dict[str, object]:
    body: dict[str, object] = {
        "schema": "ownframework-loop-semantic-budget-allocation/v1",
        "mission_id": "mission-0123456789abcdef01234567",
        "run_id": "segment-02",
        "checkpoint_id": "CP-13",
        "counter_kind": "build_pass_count",
        "allocation_number_for_checkpoint_counter": number,
        "declared_local_cap": 8,
        "local_used_before": 8,
        "cumulative_used_before": 39 + number - 1,
        "cumulative_cap": 127,
        "reserved_remaining_authority": 17,
        "reclaimable_pool_before": 72 - number + 1,
        "reclaimable_pool_after": 72 - number,
        "amount_borrowed": 1,
        "reason": "checkpoint_local_allocation_exhausted_with_safe_sealed_mission_capacity",
        "source_authority_sha256": "a" * 64,
        "source_checkpoint_id": "CP-02",
        "source_event_sha256": None,
        "source_kind": "approved_checkpoint_capacity",
        "created_at": "2026-09-30T15:55:18Z",
    }
    body["allocation_id"] = hashlib.sha256(
        integrity.canonical_json_dumps(body).encode("utf-8")
    ).hexdigest()
    return body


def digest(value: object) -> str:
    return hashlib.sha256(
        integrity.canonical_json_dumps(value).encode("utf-8")
    ).hexdigest()


imported = [allocation(1), allocation(2)]
claimed = allocation(3)
current = [*imported, claimed]
import_event = {
    "event_type": "mission_segment_materialized",
    "semantic_budget_import_sha256": digest(imported),
    "semantic_budget_import_count": len(imported),
}
claim_event = {
    "event_type": "state_saved",
    "semantic_budget_allocation_id": claimed["allocation_id"],
    "semantic_budget_allocation_sha256": digest(claimed),
}

# Exact production shape: the materialization event binds the imported prefix;
# the first new adaptive claim appends a separately claim-bound entry.
state._verify_semantic_budget_allocation_bindings(
    {"program": {"semantic_budget_allocations": current}},
    [import_event, claim_event],
)
print("IMPORTED_PREFIX_SURVIVES_LATER_CLAIM=PASS")

# Backward compatibility: existing materialization events lack an explicit
# count, so their digest must still identify the original prefix.
legacy_import_event = {
    "event_type": "mission_segment_materialized",
    "semantic_budget_import_sha256": digest(imported),
}
state._verify_semantic_budget_allocation_bindings(
    {"program": {"semantic_budget_allocations": current}},
    [legacy_import_event, claim_event],
)
print("LEGACY_IMPORT_EVENT_PREFIX_RECOGNIZED=PASS")

# Rehashing a changed imported record does not make it part of the sealed
# import prefix; the original import digest still refuses the mutation.
tampered_import = copy.deepcopy(imported)
tampered_import[0]["reason"] = "changed"
tampered_body = dict(tampered_import[0])
tampered_body.pop("allocation_id")
tampered_import[0]["allocation_id"] = digest(tampered_body)
try:
    state._verify_semantic_budget_allocation_bindings(
        {"program": {"semantic_budget_allocations": [*tampered_import, claimed]}},
        [import_event, claim_event],
    )
except integrity.TamperingDetected:
    print("IMPORTED_PREFIX_MUTATION_REFUSED=PASS")
else:
    raise AssertionError("changed imported allocation was accepted")

# Appended authority remains fail-closed unless a claim event binds that exact
# allocation identity and digest.
unbound = allocation(4)
try:
    state._verify_semantic_budget_allocation_bindings(
        {"program": {"semantic_budget_allocations": [*current, unbound]}},
        [import_event, claim_event],
    )
except integrity.TamperingDetected:
    print("UNBOUND_APPENDED_ALLOCATION_REFUSED=PASS")
else:
    raise AssertionError("unbound appended allocation was accepted")
PY
