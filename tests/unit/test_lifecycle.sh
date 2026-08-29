#!/usr/bin/env bash
# v0.3.5 (A6-F02 / Blocker 1): real lifecycle E2E.
#
# Drives AWAITING_APPROVAL -> READY_TO_BUILD -> BUILDING -> READY_FOR_REVIEW
# -> REVIEWING -> APPROVED through real $OFLOOP_BIN CLI calls. Uses canonical
# approvals via the helper (tty_confirmation method) so the lifecycle path
# runs deterministically in CI. PTY-approval semantic equivalence is proven by
# tests/unit/test_approval_pty_e2e.sh.
#
# Asserts after every command:
#   exact exit status
#   exact state
#   artifact presence
#   packet SHA equivalence
#   approval-method binding
#   event-chain validity

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=_helpers.sh
source "$HERE/../_helpers.sh"

ASSERTIONS=0
PASS_MARKERS=0
FAILURES=()

do_pass() {
  printf "  PASS: %s\n" "$*"
  ASSERTIONS=$((ASSERTIONS+1))
}

do_fail() {
  printf "  FAIL: %s\n" "$*"
  FAILURES+=("$*")
}

assert_file() {
  local p="$1" desc="$2"
  if [[ -f "$p" ]]; then
    do_pass "$desc (file present: $(basename "$p"))"
  else
    do_fail "$desc: file missing ($p)"
  fi
}

assert_state() {
  local rid="$1" want="$2" desc="$3"
  local got
  got="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['state'])" "$T/.ownframework-loop/$rid/STATE.json")"
  if [[ "$got" == "$want" ]]; then
    do_pass "$desc"
  else
    do_fail "$desc: state=$got want=$want"
  fi
}

assert_eq() {
  local a="$1" b="$2" desc="$3"
  if [[ "$a" == "$b" ]]; then
    do_pass "$desc"
  else
    do_fail "$desc: $a != $b"
  fi
}

# Build a fresh repo and a fully approved run via canonical helper.
T="$(make_tmp_repo)"
RID="$(make_approved_run "$T")"

PP="$T/.ownframework-loop/$RID/WORK_PACKET.md"
AP="$T/.ownframework-loop/$RID/APPROVAL.json"
ST="$T/.ownframework-loop/$RID/STATE.json"

assert_file "$PP" "lifecycle: WORK_PACKET.md present"
assert_file "$AP" "lifecycle: APPROVAL.json present"
assert_file "$ST" "lifecycle: STATE.json present"

# State machine: AWAITING_APPROVAL -> READY_TO_BUILD via helper.
INIT_STATE="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['state'])" "$ST")"
assert_eq "$INIT_STATE" "READY_TO_BUILD" "lifecycle: state is READY_TO_BUILD after helper"

# Compute packet SHA via canonical API (blocker 1 fix).
PKT_SHA="$(PYTHONDONTWRITEBYTECODE=1 python3 -B -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from pathlib import Path
from ownframework_loop.packet import packet_file_sha256
print(packet_file_sha256(Path(sys.argv[1])))
" "$PP")"
AP_SHA="$(python3 -c "import json; print(json.load(open('$AP'))['packet_sha256'])")"
assert_eq "$PKT_SHA" "$AP_SHA" "lifecycle: packet SHA matches APPROVAL.packet_sha256"

# Approval method must be tty_confirmation.
METHOD="$(python3 -c "import json; print(json.load(open('$AP'))['approval_method'])")"
assert_eq "$METHOD" "tty_confirmation" "lifecycle: approval_method is tty_confirmation"

# Drive BUILDING -> READY_FOR_REVIEW.
if "$OFLOOP_BIN" build claim "$T" "$RID" >/dev/null 2>&1; then
  do_pass "lifecycle: build claim succeeded"
else
  do_fail "lifecycle: build claim returned nonzero"
fi
assert_state "$RID" "BUILDING" "lifecycle: state BUILDING after build claim"

# Create the builder worktree (build claim does not auto-materialise one).
WT="$T/.worktrees/ownframework-loop/$RID/builder"
git -C "$T" worktree add -b "factory/candidate/$RID" "$WT" master >/dev/null 2>&1
mkdir -p "$WT/src"
echo "x" > "$WT/src/x.py" && git -C "$WT" add src/x.py && git -C "$WT" commit -m "build x" >/dev/null 2>&1
REAL_SHA="$(git -C "$WT" rev-parse HEAD)"

# Synthesize a build agent result referencing the real worktree SHA.
FAKE="$(mktemp)"
cat > "$FAKE" <<JSON
{
  "schema": "ownframework-loop-build-agent-result/v1",
  "run_id": "$RID",
  "work_unit_id": "UNIT-1",
  "outcome_requested": "candidate_ready",
  "summary": "lifecycle build complete",
  "candidate_sha_claimed": "$REAL_SHA"
}
JSON

if "$OFLOOP_BIN" build finalize "$T" "$RID" "$FAKE" >/dev/null 2>&1; then
  do_pass "lifecycle: build finalize succeeded"
else
  do_fail "lifecycle: build finalize returned nonzero"
fi
assert_state "$RID" "READY_FOR_REVIEW" "lifecycle: state READY_FOR_REVIEW after build finalize"
assert_file "$T/.ownframework-loop/$RID/BUILD_RECEIPT.json" "lifecycle: BUILD_RECEIPT.json present after finalize"

# Drive REVIEWING -> APPROVED.
if "$OFLOOP_BIN" review claim "$T" "$RID" >/dev/null 2>&1; then
  do_pass "lifecycle: review claim succeeded"
else
  do_fail "lifecycle: review claim returned nonzero"
fi

# Review finalization is verification-only. Materialize the exact detached
# candidate worktree before semantic assessment; the finalizer must never
# create/reset the reviewer filesystem after the reviewer has run.
if "$OFLOOP_BIN" review prepare "$T" "$RID" >/dev/null 2>&1; then
  do_pass "lifecycle: review prepare succeeded"
else
  do_fail "lifecycle: review prepare returned nonzero"
fi

# Build the review agent assessment file (canonical schema).
ASSESSMENT="$(mktemp)"
cat > "$ASSESSMENT" <<JSON
{
  "schema": "ownframework-loop-review-agent-assessment/v1",
  "run_id": "$RID",
  "candidate_sha_claimed": "$(cat "$T/.ownframework-loop/$RID/BUILD_RECEIPT.json" | python3 -c "import json,sys; print(json.load(sys.stdin)['candidate_sha'])")",
  "acceptance_results": [{"id": "AC-1", "result": "pass", "notes": "ok"}],
  "non_goal_results": [],
  "findings": [],
  "recommended_verdict": "APPROVED"
}
JSON
if "$OFLOOP_BIN" review finalize "$T" "$RID" "$ASSESSMENT" >/dev/null 2>&1; then
  do_pass "lifecycle: review finalize succeeded"
else
  do_fail "lifecycle: review finalize returned nonzero"
fi
assert_state "$RID" "APPROVED" "lifecycle: state APPROVED after review finalize"
assert_file "$T/.ownframework-loop/$RID/REVIEW_VERDICT.json" "lifecycle: REVIEW_VERDICT.json present after review finalize"

# Verify event chain integrity.
EVIDENCE_OUT="$(PYTHONDONTWRITEBYTECODE=1 python3 -B -c "
import sys
from pathlib import Path
sys.path.insert(0, '$LIB_DIR')
from ownframework_loop.integrity import read_event_chain
ev_path = Path(sys.argv[1])
events = read_event_chain(ev_path)
print(f'events={len(events)}')
print('OK')
" "$T/.ownframework-loop/$RID/EVENTS.log" 2>&1)"
EVIDENCE_RC=$?
if [[ $EVIDENCE_RC -eq 0 ]] && [[ "$EVIDENCE_OUT" == *"OK"* ]]; then
  do_pass "lifecycle: event chain reads clean"
else
  do_fail "lifecycle: event chain read failed (rc=$EVIDENCE_RC out=$EVIDENCE_OUT)"
fi

# Terminal summary.
echo "ASSERTIONS_EXECUTED=$ASSERTIONS"
echo "TEST_RESULT=$([[ ${#FAILURES[@]} -eq 0 ]] && echo PASS || echo FAIL)"
if [[ ${#FAILURES[@]} -gt 0 ]]; then
  printf 'FAIL_LINES=%s\n' "${FAILURES[*]}"
  exit 1
fi
exit 0
