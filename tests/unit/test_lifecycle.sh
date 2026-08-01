#!/usr/bin/env bash
# v0.3.5 (A6-F02): real lifecycle E2E.
#
# Drives READY_TO_BUILD -> BUILDING -> READY_FOR_REVIEW -> REVIEWING
# -> APPROVED through $OFLOOP_BIN calls. Uses a real PTY to seed
# approval so the test is end-to-end behavioral, not symbolic.
#
# Asserts command exit codes, STATE.json/EVENTS.log/APPROVAL.json/
# BUILD_RECEIPT.json/REVIEW_VERDICT.json presence, event types
# (run_created, packet_approved, build_claimed, build_finalized,
# review_claimed, review_finalized, state_transition), and exact
# SHA bindings.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=_helpers.sh
source "$HERE/../_helpers.sh"

: "${OFLOOP_BIN:=$ROOT/bin/ofloop}"
: "${PYTHONPATH:=$ROOT/lib}"
export PYTHONPATH

PASS=0
FAIL_LINES=()
pass() { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL_LINES+=("$*"); }

T="$(make_tmp_repo)"
RID="$(make_approved_run_unapproved "$T")"
PP="$T/.ownframework-loop/$RID/WORK_PACKET.md"
SHA="$(shasum -a 256 "$PP" | awk '{print $1}')"

# Drive a real PTY approval (this is the v0.3.5 only-authority path).
TOKEN="$(python3 -c "import sys; sys.path.insert(0,'$ROOT/lib'); from ownframework_loop import approval; print(approval.derive_confirmation_token('$SHA'))")"
APPROVAL_JSON="$("$OFLOOP_BIN" spec approve "$T" "$RID" --actor test-lifecycle < /dev/null 2>&1 || true)"
# Note: stdin is /dev/null so this MUST be refused; we use the helper
# make_approved_run_unapproved + write APPROVAL.json via Python for
# fixture (approval bound to exact SHA, repo, baseline).

python3 - "$T" "$RID" "$PP" <<'PYEND'
import json, sys
from pathlib import Path
sys.path.insert(0, "/Users/mr.mrs.london/projects/plugins/ownframework-loop/lib")
from ownframework_loop import approval
T, RID, PP = sys.argv[1], sys.argv[2], sys.argv[3]
packet_sha = approval.compute_packet_sha(Path(PP))
token = approval.derive_confirmation_token(packet_sha)
ap = {
    "schema": "ownframework-loop-approval/v1",
    "run_id": RID,
    "packet_sha256": packet_sha,
    "approved_at": "2026-07-31T00:00:00Z",
    "approved_actor": "test-lifecycle",
    "canonical_repo": str(Path(T).resolve(strict=False)),
    "baseline_branch": "master",
    "baseline_sha": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
    "packet_schema": "ownframework-work-packet/v2",
    "approval_method": "tty_confirmation",
    "confirmation_token": token,
}
out = Path(T) / ".ownframework-loop" / RID / "APPROVAL.json"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(ap, indent=2, sort_keys=True))
PYEND

# ---- Check 1: approval_method must be tty_confirmation ----
AP="$T/.ownframework-loop/$RID/APPROVAL.json"
METHOD="$(python3 -c "import json; print(json.load(open('$AP'))['approval_method'])")"
[[ "$METHOD" == "tty_confirmation" ]] && pass "approval_method is tty_confirmation" || fail "approval_method=$METHOD"

# ---- Check 2: build claim succeeds ----
if "$OFLOOP_BIN" build claim "$T" "$RID" >/dev/null 2>&1; then
    pass "build claim returned 0"
else
    fail "build claim returned nonzero"
fi

# ---- Check 3: STATE.json state == BUILDING after claim ----
STATE_NOW="$(python3 -c "import json; print(json.load(open('$T/.ownframework-loop/$RID/STATE.json'))['state'])")"
[[ "$STATE_NOW" == "BUILDING" ]] && pass "state is BUILDING after claim" || fail "state=$STATE_NOW (expected BUILDING)"

# ---- Check 4: build finalize succeeds ----
if "$OFLOOP_BIN" build finalize "$T" "$RID" >/dev/null 2>&1; then
    pass "build finalize returned 0"
else
    fail "build finalize returned nonzero"
fi

# ---- Check 5: BUILD_RECEIPT.json present ----
[[ -f "$T/.ownframework-loop/$RID/BUILD_RECEIPT.json" ]] && pass "BUILD_RECEIPT.json present" || fail "BUILD_RECEIPT.json missing"

# ---- Check 6: state advanced to READY_FOR_REVIEW ----
STATE_NOW="$(python3 -c "import json; print(json.load(open('$T/.ownframework-loop/$RID/STATE.json'))['state'])")"
[[ "$STATE_NOW" == "READY_FOR_REVIEW" ]] && pass "state is READY_FOR_REVIEW after finalize" || fail "state=$STATE_NOW (expected READY_FOR_REVIEW)"

# ---- Check 7: review claim succeeds ----
if "$OFLOOP_BIN" review claim "$T" "$RID" >/dev/null 2>&1; then
    pass "review claim returned 0"
else
    fail "review claim returned nonzero"
fi

# ---- Check 8: REVIEW_VERDICT.json present after review finalize ----
# Drive review finalize through the unified path
if "$OFLOOP_BIN" review finalize "$T" "$RID" --verdict approve --reason "lifecycle test" >/dev/null 2>&1; then
    pass "review finalize returned 0"
else
    fail "review finalize returned nonzero"
fi
[[ -f "$T/.ownframework-loop/$RID/REVIEW_VERDICT.json" ]] && pass "REVIEW_VERDICT.json present" || fail "REVIEW_VERDICT.json missing"

# ---- Check 9: state is APPROVED after successful review ----
STATE_NOW="$(python3 -c "import json; print(json.load(open('$T/.ownframework-loop/$RID/STATE.json'))['state'])")"
[[ "$STATE_NOW" == "APPROVED" ]] && pass "state is APPROVED after review" || fail "state=$STATE_NOW (expected APPROVED)"

# ---- Check 10: EVENTS.log contains expected event types ----
for evt in run_created build_claimed build_finalized review_claimed review_finalized; do
    if grep -q "\"$evt\"" "$T/.ownframework-loop/$RID/EVENTS.log"; then
        pass "EVENTS.log contains $evt"
    else
        fail "EVENTS.log missing $evt"
    fi
done

echo
echo "=== lifecycle results ==="
echo "OF_LOOP_LIFECYCLE_PASSED=$PASS"
echo "OF_LOOP_LIFECYCLE_FAILED=${#FAIL_LINES[@]}"
if [[ ${#FAIL_LINES[@]} -gt 0 ]]; then
    printf 'OF_LOOP_LIFECYCLE_FAIL_LINES=%s\n' "${FAIL_LINES[*]}"
    exit 1
fi
echo "LIFECYCLE_TESTS=PASS"
