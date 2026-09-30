#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONDONTWRITEBYTECODE=1

PYTHONPATH="$ROOT_DIR/lib" python3 -B <<'PY'
import copy
from ownframework_loop import state

current = {
    "execution_mode": "program",
    "checkpoints": [{
        "id": "CP-13",
        "repair_round_count": 3,
        "last_evidence_sha_by_counter": {"build_pass_count": "a" * 64},
    }],
    "cumulative_counters": {
        "build_pass_count": 8,
        "review_pass_count": 0,
        "repair_round_count": 11,
        "files_changed_unique": 17,
        "diff_lines_total": 1200,
    },
}
funded = copy.deepcopy(current)
funded["checkpoints"][0]["repair_round_count"] += 1
funded["checkpoints"][0]["last_evidence_sha_by_counter"]["repair_round_count"] = "b" * 64
funded["cumulative_counters"]["repair_round_count"] += 1

# This is the pre-transition snapshot passed by build finalization. It carries
# new absolute source accounting but stale checkpoint and repair counters.
source_snapshot = copy.deepcopy(current)
source_snapshot["cumulative_counters"]["files_changed_unique"] = 19
source_snapshot["cumulative_counters"]["diff_lines_total"] = 1300

merged = state._merge_funded_repair_program_block(
    current_program=current,
    funded_program=funded,
    source_program=source_snapshot,
)
cp = merged["checkpoints"][0]
assert cp["repair_round_count"] == 4, cp
assert cp["last_evidence_sha_by_counter"]["repair_round_count"] == "b" * 64, cp
assert merged["cumulative_counters"]["repair_round_count"] == 12, merged
assert merged["cumulative_counters"]["files_changed_unique"] == 19, merged
assert merged["cumulative_counters"]["diff_lines_total"] == 1300, merged
assert current["checkpoints"][0]["repair_round_count"] == 3, "input snapshot mutated"

contradictory = copy.deepcopy(source_snapshot)
contradictory["checkpoints"][0]["review_pass_count"] = 99
try:
    state._merge_funded_repair_program_block(
        current_program=current,
        funded_program=funded,
        source_program=contradictory,
    )
except ValueError as exc:
    assert "changes beyond source accounting" in str(exc), exc
else:
    raise AssertionError("non-source caller mutation was not refused")

print("FUNDED_REPAIR_CP_LOCAL_COUNTER_PRESERVED=PASS")
print("FUNDED_REPAIR_EVIDENCE_BINDING_PRESERVED=PASS")
print("FUNDED_REPAIR_SOURCE_ACCOUNTING_UPDATED=PASS")
print("FUNDED_REPAIR_UNTYPED_OVERWRITE_REFUSED=PASS")
PY
