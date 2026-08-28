#!/usr/bin/env bash
# v0.5.4 — execution-start and claim-concurrency hardening.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

# ---------------------------------------------------------------------------
# 1. Activation failure is explicit; durable seal is reused on retry.
# ---------------------------------------------------------------------------
T1="$(make_tmp_repo)"
RID1="$(make_approved_run_unapproved "$T1" FEATURE low "v054-activation-fault")"

python3 - "$T1" "$RID1" <<'PY'
import hashlib
import sys
from pathlib import Path
from ownframework_loop import execution_start, state as state_mod

repo = Path(sys.argv[1])
rid = sys.argv[2]
run = repo / ".ownframework-loop" / rid
seal_path = run / "APPROVAL.json"

orig_transition = state_mod.transition

def injected_failure(*args, **kwargs):
    raise RuntimeError("V054_INJECTED_ACTIVATION_FAILURE")

state_mod.transition = injected_failure
try:
    execution_start.ensure_executable(
        canonical_repo=repo,
        run_id=rid,
        actor="v054-test",
    )
except RuntimeError as exc:
    assert "V054_INJECTED_ACTIVATION_FAILURE" in str(exc), exc
else:
    raise AssertionError("execution start swallowed activation failure")
finally:
    state_mod.transition = orig_transition

assert seal_path.exists(), "seal should be durable before activation"
state = state_mod.load(repo, rid)
assert state["state"] == "AWAITING_APPROVAL", state
before = hashlib.sha256(seal_path.read_bytes()).hexdigest()

execution_start.ensure_executable(
    canonical_repo=repo,
    run_id=rid,
    actor="v054-test",
)

after = hashlib.sha256(seal_path.read_bytes()).hexdigest()
state = state_mod.load(repo, rid)
assert state["state"] == "READY_TO_BUILD", state
assert before == after, "retry rewrote immutable execution seal"
print("PASS activation fault propagates and retry reuses exact seal")
PY

# ---------------------------------------------------------------------------
# 2. Concurrent first start: both commands succeed, one fresh + one replay.
# ---------------------------------------------------------------------------
T2="$(make_tmp_repo)"
RID2="$(make_approved_run_unapproved "$T2" FEATURE low "v054-first-start")"
O21="$(mktemp -t ofloop-v054-first-1.XXXXXX)"
O22="$(mktemp -t ofloop-v054-first-2.XXXXXX)"

set +e
"$OFLOOP_BIN" build claim "$T2" "$RID2" --actor builder >"$O21" 2>&1 & P21=$!
"$OFLOOP_BIN" build claim "$T2" "$RID2" --actor builder >"$O22" 2>&1 & P22=$!
wait "$P21"; RC21=$?
wait "$P22"; RC22=$?
set -e

assert_eq "$RC21" "0" "first-start claimant 1 exits zero"
assert_eq "$RC22" "0" "first-start claimant 2 exits zero"

R21="$(jq -r '.replayed' "$O21")"
R22="$(jq -r '.replayed' "$O22")"
SORTED_REPLAY="$(printf '%s\n%s\n' "$R21" "$R22" | sort | tr '\n' ' ')"
assert_eq "$SORTED_REPLAY" "false true " "first-start has one fresh and one replay"
assert_eq "$(jq -r '.build_pass_count' "$T2/.ownframework-loop/$RID2/STATE.json")" "1" "first-start consumes one build pass"
assert_file_exists "$T2/.ownframework-loop/$RID2/APPROVAL.json" "first-start creates execution seal"
assert_eq "$(jq -r '.approval_method' "$T2/.ownframework-loop/$RID2/APPROVAL.json")" "build_start" "first-start binding method"
assert_eq "$(jq -r '.binding_kind' "$T2/.ownframework-loop/$RID2/APPROVAL.json")" "execution_seal" "first-start binding kind"
rm -f "$O21" "$O22"

# ---------------------------------------------------------------------------
# 3. Single-mode build claims serialize to one pass.
# ---------------------------------------------------------------------------
T3="$(make_tmp_repo)"
RID3="$(make_approved_run "$T3" FEATURE low "v054-single-build")"
O31="$(mktemp -t ofloop-v054-build-1.XXXXXX)"
O32="$(mktemp -t ofloop-v054-build-2.XXXXXX)"

set +e
"$OFLOOP_BIN" build claim "$T3" "$RID3" --actor builder >"$O31" 2>&1 & P31=$!
"$OFLOOP_BIN" build claim "$T3" "$RID3" --actor builder >"$O32" 2>&1 & P32=$!
wait "$P31"; RC31=$?
wait "$P32"; RC32=$?
set -e

assert_eq "$RC31" "0" "single build claimant 1 exits zero"
assert_eq "$RC32" "0" "single build claimant 2 exits zero"
R31="$(jq -r '.replayed' "$O31")"
R32="$(jq -r '.replayed' "$O32")"
SORTED_BUILD_REPLAY="$(printf '%s\n%s\n' "$R31" "$R32" | sort | tr '\n' ' ')"
assert_eq "$SORTED_BUILD_REPLAY" "false true " "single build has one fresh and one replay"
assert_eq "$(jq -r '.build_pass_count' "$T3/.ownframework-loop/$RID3/STATE.json")" "1" "single build consumes one pass"
rm -f "$O31" "$O32"

# ---------------------------------------------------------------------------
# 4. Single-mode review claims serialize to one pass from a legal review state.
# ---------------------------------------------------------------------------
T4="$(make_tmp_repo)"
RID4="$(make_approved_run "$T4" FEATURE low "v054-single-review")"
python3 - "$T4" "$RID4" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import state as state_mod
repo = Path(sys.argv[1]); rid = sys.argv[2]
state_mod.transition(repo, rid, to_state="BUILDING", actor="v054-test", reason="review concurrency fixture")
state_mod.transition(repo, rid, to_state="READY_FOR_REVIEW", actor="v054-test", reason="review concurrency fixture")
PY
O41="$(mktemp -t ofloop-v054-review-1.XXXXXX)"
O42="$(mktemp -t ofloop-v054-review-2.XXXXXX)"

set +e
"$OFLOOP_BIN" review claim "$T4" "$RID4" --actor reviewer >"$O41" 2>&1 & P41=$!
"$OFLOOP_BIN" review claim "$T4" "$RID4" --actor reviewer >"$O42" 2>&1 & P42=$!
wait "$P41"; RC41=$?
wait "$P42"; RC42=$?
set -e

assert_eq "$RC41" "0" "single review claimant 1 exits zero"
assert_eq "$RC42" "0" "single review claimant 2 exits zero"
R41="$(jq -r '.replayed' "$O41")"
R42="$(jq -r '.replayed' "$O42")"
SORTED_REVIEW_REPLAY="$(printf '%s\n%s\n' "$R41" "$R42" | sort | tr '\n' ' ')"
assert_eq "$SORTED_REVIEW_REPLAY" "false true " "single review has one fresh and one replay"
assert_eq "$(jq -r '.review_pass_count' "$T4/.ownframework-loop/$RID4/STATE.json")" "1" "single review consumes one pass"
rm -f "$O41" "$O42"

echo "V054_EXECUTION_START_HARDENING=PASS"
