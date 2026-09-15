#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../_helpers.sh"
export PYTHONPATH="$LIB_DIR${PYTHONPATH:+:$PYTHONPATH}"

python3 -B <<'PY'
from ownframework_loop import program

SHA = "875a7028ebedfd922c6e3be929d08557b220a836"
PACKET = {"checkpoint_graph": {"execution_order": ["CP-0"]}}

def resolve(event, cp="CP-6", state=None):
    return program.checkpoint_entry_candidate_sha(
        packet=PACKET,
        program_state=state or {"checkpoints": [{"id": cp}]},
        cp_id=cp,
        events=[event],
    )

top = {
    "event_type": "program_advanced", "cp_id_finalized": "CP-5",
    "cp_terminal": "APPROVED", "next_checkpoints": ["CP-6"],
    "commit_sha": SHA,
}
assert resolve(top) == SHA
print("R3_TOP_LEVEL_EVENT_ANCHOR_RECOVERY=PASS")

direct = {"checkpoints": [{"id": "CP-6", "checkpoint_entry_candidate_sha": "a" * 40}]}
assert resolve(top, state=direct) == "a" * 40
print("NEW_RUN_CHECKPOINT_ENTRY_ANCHOR=PASS")

nested = {"event_type": "program_advanced", "extras": {"next_checkpoints": ["CP-6"]}, "commit_sha": SHA}
assert resolve(nested) == SHA
print("LEGACY_EVENT_FALLBACK=PASS")

identical = dict(top, extras={"next_checkpoints": ["CP-6"]})
assert resolve(identical) == SHA

conflict = dict(top, extras={"next_checkpoints": ["CP-7"]})
try:
    resolve(conflict)
except program.ProgramStateError:
    pass
else:
    raise AssertionError("contradictory dual event metadata was accepted")
print("CONTRADICTORY_DUAL_SHAPE_FAILS_CLOSED=PASS")

wrong_cp = dict(top, next_checkpoints=["CP-7"])
assert resolve(wrong_cp) is None

malformed = dict(top, commit_sha="not-a-commit")
try:
    resolve(malformed)
except program.ProgramStateError:
    pass
else:
    raise AssertionError("malformed commit SHA was accepted")
print("MALFORMED_COMMIT_FAILS_CLOSED=PASS")

cp0 = {"event_type": "program_advanced", "next_checkpoints": ["CP-1"], "commit_sha": SHA}
assert program.checkpoint_entry_candidate_sha(
    packet=PACKET, program_state={"checkpoints": [{"id": "CP-0"}]}, cp_id="CP-0", events=[cp0]
) is None
print("CP0_BASELINE_FALLBACK_PRESERVED=PASS")
print("NO_BRANCH_HISTORY_GUESSING=PASS")
PY

echo "LEGACY_ANCHOR_EVENT_CONTRACT=PASS"
