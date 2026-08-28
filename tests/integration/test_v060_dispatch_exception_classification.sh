#!/usr/bin/env bash
# v0.6 — dispatch packet-authority exception classification.
#
# Proves the three distinct classifications dispatch.py must surface:
#
#   1. MALFORMED / UNREADABLE PACKET → "packet unreadable:"
#      (missing file, unreadable file, unparseable JSON block)
#
#   2. VALID BUT NON-EXECUTABLE AUTHORITY → "packet not executable under current authority:"
#      (syntactically valid packet carrying a forbidden authority shape,
#      e.g. external_action_authority=delegated or promotion_policy=merge_on_approved)
#
#   3. UNEXPECTED INTERNAL EXCEPTION in the authority evaluator →
#      propagates unchanged as a real fault, NOT mislabeled "packet unreadable"
#      (monkeypatch packet_is_executable_under_current_authority with a
#      sentinel RuntimeError and prove it surfaces verbatim).
#
# No model call. All three classifications are exercised deterministically
# against a freshly created run in AWAITING_APPROVAL state — dispatch must
# refuse with the right error string and consume zero engineering passes.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

OFLOOP="$OFLOOP_BIN"
LIB_DIR="$ROOT_DIR/lib"
export PYTHONPATH="$LIB_DIR"

# -----------------------------------------------------------------------------
# Helper: create a fresh run with a custom WORK_PACKET.md and verify the
# dispatch claim refuses with the expected classification. The packet bytes
# are produced directly on disk (not via `ofloop spec new`) so we can shape
# authority fields and (for test #3) inject a sentinel via monkeypatch.
# -----------------------------------------------------------------------------
fresh_repo() {
  local repo
  repo="$(make_tmp_repo)"
  echo "$repo"
}

create_run_with_packet() {
  # Args: repo packet_body
  local repo="$1"
  local body="$2"
  "$OFLOOP" spec new "$repo" "classification-test" >/dev/null
  local rid
  rid="$(ls -1t "$repo/.ownframework-loop" | head -n1)"
  local pp="$repo/.ownframework-loop/$rid/WORK_PACKET.md"
  printf '%s' "$body" > "$pp"
  echo "$rid"
}

# Capture dispatch claim output without errexit interfering.
dispatch_claim_capture() {
  # Args: repo run_id
  set +e
  "$OFLOOP" dispatch claim "$1" "$2" >/tmp/dispatch_claim.out 2>/tmp/dispatch_claim.err
  local rc=$?
  set -e
  cat /tmp/dispatch_claim.out /tmp/dispatch_claim.err
  return $rc
}

# -----------------------------------------------------------------------------
# 1. MALFORMED / UNREADABLE PACKET → "packet unreadable:"
# -----------------------------------------------------------------------------
echo ""
echo "=== TEST 1: malformed/unreadable packet ==="
REPO1="$(fresh_repo)"
RID1="$(create_run_with_packet "$REPO1" 'not even a fenced json block
this is not a valid packet
')"
# Sanity: confirm the packet is missing the ```json fence
grep -q '```json' "$REPO1/.ownframework-loop/$RID1/WORK_PACKET.md" \
  && fail "test fixture unexpectedly contains a json fence"

OUT1="$(dispatch_claim_capture "$REPO1" "$RID1" || true)"
echo "  dispatch output: $(printf '%s' "$OUT1" | head -3)"
echo "$OUT1" | grep -Fq "packet unreadable:" \
  || fail "expected 'packet unreadable:' but got: $OUT1"
echo "$OUT1" | grep -Fq "packet not executable under current authority:" \
  && fail "unreadable packet must NOT be classified as 'packet not executable under current authority'"
# Confirm no engineering pass was consumed
PASS_COUNT="$(jq -r '.build_pass_count // 0' "$REPO1/.ownframework-loop/$RID1/STATE.json" 2>/dev/null || echo 0)"
[[ "$PASS_COUNT" == "0" ]] || fail "expected zero build passes after refusal, got $PASS_COUNT"
pass "TEST 1 — malformed packet classified as 'packet unreadable:' with zero passes"

# -----------------------------------------------------------------------------
# 2. VALID BUT NON-EXECUTABLE AUTHORITY → "packet not executable under current authority:"
# -----------------------------------------------------------------------------
echo ""
echo "=== TEST 2: valid but non-executable authority ==="

# 2a. external_action_authority=delegated
REPO2A="$(fresh_repo)"
RID2A="$(create_run_with_packet "$REPO2A" '```json
{
  "schema": "ownframework-work-packet/v2",
  "packet_id": "p-2a",
  "created_at": "2026-08-28T00:00:00Z",
  "work_class": "FEATURE",
  "risk_class": "low",
  "title": "non-exec delegated",
  "target": {"repo": "'"$REPO2A"'", "branch": "master", "classification": "local_only"},
  "acceptance_criteria": [{"id": "AC-1", "text": "ok"}],
  "non_goals": [],
  "allowed_paths": ["src/"],
  "protected_paths": [".ownframework-loop/"],
  "work_units": [{"id": "UNIT-1", "title": "u", "scope": "s"}],
  "merge_authority": "human_only",
  "deploy_authority": "human_only",
  "push_authority": "human_only",
  "external_action_authority": "delegated",
  "risk_budget": {"max_files_changed": 25, "max_diff_lines": 1000, "max_repair_rounds": 3}
}
```')"
OUT2A="$(dispatch_claim_capture "$REPO2A" "$RID2A" || true)"
echo "  dispatch output: $(printf '%s' "$OUT2A" | head -3)"
echo "$OUT2A" | grep -Fq "packet not executable under current authority:" \
  || fail "expected 'packet not executable under current authority:' for delegated external_action_authority, got: $OUT2A"
echo "$OUT2A" | grep -Fq "packet unreadable:" \
  && fail "non-executable packet must NOT be classified as 'packet unreadable'"
PASS_COUNT="$(jq -r '.build_pass_count // 0' "$REPO2A/.ownframework-loop/$RID2A/STATE.json" 2>/dev/null || echo 0)"
[[ "$PASS_COUNT" == "0" ]] || fail "expected zero build passes after refusal, got $PASS_COUNT"
pass "TEST 2a — external_action_authority=delegated classified correctly with zero passes"

# 2b. promotion_policy=merge_on_approved
REPO2B="$(fresh_repo)"
RID2B="$(create_run_with_packet "$REPO2B" '```json
{
  "schema": "ownframework-work-packet/v2",
  "packet_id": "p-2b",
  "created_at": "2026-08-28T00:00:00Z",
  "work_class": "FEATURE",
  "risk_class": "low",
  "title": "non-exec merge_on_approved",
  "target": {"repo": "'"$REPO2B"'", "branch": "master", "classification": "local_only"},
  "acceptance_criteria": [{"id": "AC-1", "text": "ok"}],
  "non_goals": [],
  "allowed_paths": ["src/"],
  "protected_paths": [".ownframework-loop/"],
  "work_units": [{"id": "UNIT-1", "title": "u", "scope": "s"}],
  "merge_authority": "human_only",
  "deploy_authority": "human_only",
  "push_authority": "human_only",
  "external_action_authority": "none",
  "promotion_policy": "merge_on_approved",
  "risk_budget": {"max_files_changed": 25, "max_diff_lines": 1000, "max_repair_rounds": 3}
}
```')"
OUT2B="$(dispatch_claim_capture "$REPO2B" "$RID2B" || true)"
echo "  dispatch output: $(printf '%s' "$OUT2B" | head -3)"
echo "$OUT2B" | grep -Fq "packet not executable under current authority:" \
  || fail "expected 'packet not executable under current authority:' for promotion_policy=merge_on_approved, got: $OUT2B"
echo "$OUT2B" | grep -Fq "packet unreadable:" \
  && fail "non-executable packet must NOT be classified as 'packet unreadable'"
PASS_COUNT="$(jq -r '.build_pass_count // 0' "$REPO2B/.ownframework-loop/$RID2B/STATE.json" 2>/dev/null || echo 0)"
[[ "$PASS_COUNT" == "0" ]] || fail "expected zero build passes after refusal, got $PASS_COUNT"
pass "TEST 2b — promotion_policy=merge_on_approved classified correctly with zero passes"

# -----------------------------------------------------------------------------
# 3. UNEXPECTED INTERNAL EXCEPTION from authority evaluator propagates unchanged
# -----------------------------------------------------------------------------
echo ""
echo "=== TEST 3: unexpected internal exception propagates ==="
REPO3="$(fresh_repo)"
RID3="$(create_run_with_packet "$REPO3" '```json
{
  "schema": "ownframework-work-packet/v2",
  "packet_id": "p-3",
  "created_at": "2026-08-28T00:00:00Z",
  "work_class": "FEATURE",
  "risk_class": "low",
  "title": "unexpected-internal-exception",
  "target": {"repo": "'"$REPO3"'", "branch": "master", "classification": "local_only"},
  "acceptance_criteria": [{"id": "AC-1", "text": "ok"}],
  "non_goals": [],
  "allowed_paths": ["src/"],
  "protected_paths": [".ownframework-loop/"],
  "work_units": [{"id": "UNIT-1", "title": "u", "scope": "s"}],
  "merge_authority": "human_only",
  "deploy_authority": "human_only",
  "push_authority": "human_only",
  "external_action_authority": "none",
  "risk_budget": {"max_files_changed": 25, "max_diff_lines": 1000, "max_repair_rounds": 3}
}
```')"

# Drive `ofloop dispatch claim` with PYTHONPATH prepended to a temp
# directory that ships a sitecustomize.py. The sitecustomize is loaded
# by Python before any user module, so it monkeypatches
# `packet_is_executable_under_current_authority` to raise a sentinel
# RuntimeError BEFORE dispatch.claim_next gets a chance to call it.
# This proves that an unexpected internal exception from the authority
# path is NOT mislabeled as "packet unreadable" by any broad-except.
SITECUSTOMIZE_DIR="$(mktemp -d -t ofloop-sc.XXXXXX)"
cat > "$SITECUSTOMIZE_DIR/sitecustomize.py" <<'PY'
# Site customization that monkeypatches the packet authority evaluator
# to raise a sentinel RuntimeError when imported. This proves that an
# unexpected internal exception from the authority path is NOT
# mislabeled as "packet unreadable" by any broad-except block.
import ownframework_loop.packet as _p
SENTINEL = "OF_LOOP_SENTINEL_RUNTIME_ERROR"
def _boom(meta):
    raise RuntimeError(SENTINEL)
_p.packet_is_executable_under_current_authority = _boom
PY

set +e
PYTHONPATH="$SITECUSTOMIZE_DIR:$LIB_DIR${PYTHONPATH:+:$PYTHONPATH}" \
  "$OFLOOP" dispatch claim "$REPO3" "$RID3" >/tmp/dispatch_test3.out 2>/tmp/dispatch_test3.err
RC_PATCHED=$?
set -e

OUT3="$(cat /tmp/dispatch_test3.out /tmp/dispatch_test3.err)"
echo "  dispatch rc=$RC_PATCHED"
echo "  output: $(printf '%s' "$OUT3" | head -5)"

# The sentinel must appear verbatim. If it appears, the unexpected
# exception propagated unchanged. If it is missing, check whether the
# output was silently mislabeled as "packet unreadable:" — that is the
# exact regression the fix is meant to prevent.
if echo "$OUT3" | grep -Fq "OF_LOOP_SENTINEL_RUNTIME_ERROR"; then
  SENTINEL_PRESENT=yes
else
  SENTINEL_PRESENT=no
fi

# Hard assertion: the output must NOT be mislabeled as "packet unreadable:"
echo "$OUT3" | grep -Fq "packet unreadable:" \
  && fail "TEST 3 FAILED: sentinel RuntimeError was relabeled as 'packet unreadable:' — this is the regression the fix is meant to prevent. Output: $OUT3"

# The sentinel must appear somewhere in the output (stderr/stdout).
[[ "$SENTINEL_PRESENT" == "yes" ]] \
  || fail "TEST 3 FAILED: sentinel RuntimeError did not propagate as a visible fault; output: $OUT3"

pass "TEST 3 — unexpected internal exception propagates unchanged (sentinel present=$SENTINEL_PRESENT, not mislabeled)"

# Cleanup the sitecustomize directory
rm -rf "$SITECUSTOMIZE_DIR"

echo ""
echo "DISPATCH_EXCEPTION_CLASSIFICATION=PASS"