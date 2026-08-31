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

# ---------------------------------------------------------------------------
# 5. Same Git repo, distinct frozen baseline refs, checkout parked elsewhere.
# ---------------------------------------------------------------------------
T5="$(make_tmp_repo)"
git -C "$T5" branch website
git -C "$T5" branch webhooks

git -C "$T5" checkout -q website
mkdir -p "$T5/src"
printf 'website\n' > "$T5/src/website.txt"
git -C "$T5" add src/website.txt
git -C "$T5" commit -qm "website baseline"
WEBSITE_SHA="$(git -C "$T5" rev-parse HEAD)"
RID51="$(make_approved_run_unapproved "$T5" FEATURE low "v090-multibaseline-website" website)"

git -C "$T5" checkout -q webhooks
mkdir -p "$T5/src"
printf 'webhooks\n' > "$T5/src/webhooks.txt"
git -C "$T5" add src/webhooks.txt
git -C "$T5" commit -qm "webhooks baseline"
WEBHOOKS_SHA="$(git -C "$T5" rev-parse HEAD)"
RID52="$(make_approved_run_unapproved "$T5" FEATURE low "v090-multibaseline-webhooks" webhooks)"

# The visible checkout is deliberately neither run's baseline.
git -C "$T5" checkout -q master

python3 - "$T5" "$RID51" "$RID52" "$WEBSITE_SHA" "$WEBHOOKS_SHA" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import build_prepare, execution_start, git_checks

repo = Path(sys.argv[1])
rid_website, rid_webhooks = sys.argv[2], sys.argv[3]
sha_website, sha_webhooks = sys.argv[4], sys.argv[5]

assert git_checks.current_branch(repo) == "master"
execution_start.ensure_executable(
    canonical_repo=repo, run_id=rid_website,
    actor="v090-multibaseline", binding_method="build_start",
)
execution_start.ensure_executable(
    canonical_repo=repo, run_id=rid_webhooks,
    actor="v090-multibaseline", binding_method="build_start",
)
website = build_prepare.prepare(canonical_repo=repo, run_id=rid_website)
webhooks = build_prepare.prepare(canonical_repo=repo, run_id=rid_webhooks)

assert website["baseline_sha"] == sha_website, website
assert webhooks["baseline_sha"] == sha_webhooks, webhooks
assert website["candidate_branch"] != webhooks["candidate_branch"], (website, webhooks)
assert website["builder_worktree"] != webhooks["builder_worktree"], (website, webhooks)
assert git_checks.current_branch(repo) == "master"
print("MULTI_BASELINE_SAME_REPO=PASS")
print("CANONICAL_CHECKOUT_POSITION_NOT_GLOBAL_MUTEX=PASS")
print("CANDIDATE_ANCESTRY_PRESERVED=PASS")
PY

# Moving the frozen website branch ref must still be detected even though the
# visible checkout remains on master.
git -C "$T5" branch -f website master >/dev/null
python3 - "$T5" "$RID51" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import build_prepare

try:
    build_prepare.prepare(canonical_repo=Path(sys.argv[1]), run_id=sys.argv[2])
except Exception as exc:
    text = str(exc)
    assert "baseline" in text and ("drift" in text or "invalid" in text), text
else:
    raise AssertionError("baseline ref drift was not refused")
print("BASELINE_REF_DRIFT_STILL_REFUSED=PASS")
PY

echo "V054_EXECUTION_START_HARDENING=PASS"
