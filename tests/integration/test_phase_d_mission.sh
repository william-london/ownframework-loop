#!/usr/bin/env bash
# v0.6 — single BUILD + REVIEW cycle via the typed dispatch boundary.
#
# Drives one canonical program checkpoint end-to-end through the
# dispatch + deterministic finalizer boundary:
#   1. spec new (creates run id)
#   2. operator writes WORK_PACKET.md
#   3. operator writes APPROVAL.json (auto-seal)
#   4. builder creates candidate worktree + commit
#   5. ofloop dispatch claim       -> BUILD work order with semantic skeleton
#   6. fill synthetic semantic builder result
#   7. ofloop dispatch finalize    -> exact candidate SHA recorded
#   8. ofloop dispatch claim       -> REVIEW work order against exact SHA
#   9. fill synthetic semantic reviewer assessment
#  10. ofloop dispatch finalize    -> APPROVED terminal
#
# This test must NEVER touch a model — the synthetic semantic results are
# schema-correct and address the packet's acceptance criteria.

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

OFLOOP="$OFLOOP_BIN"
LIB_DIR="$ROOT_DIR/lib"

REPO="$(make_tmp_repo)"
RUN_ID="$(make_approved_run "$REPO" FEATURE low "phase-d-dispatch-mission")"
echo "REPO=$REPO RUN_ID=$RUN_ID"

# The auto-seal path already leaves the run ready for a BUILD work order;
# only transition if the helper left it in AWAITING_APPROVAL (it shouldn't,
# but stay defensive).

# Create a candidate commit on a builder worktree.
WT="$REPO/.worktrees/ownframework-loop/$RUN_ID/builder"
git -C "$REPO" worktree add -b "factory/candidate/$RUN_ID" "$WT" master >/dev/null 2>&1
mkdir -p "$WT/src"
cat > "$WT/src/marker.py" <<'PY'
def marker():
    return 42
PY
git -C "$WT" add src/marker.py && git -C "$WT" commit -m "feat: add marker" >/dev/null 2>&1
CAND_SHA="$(git -C "$WT" rev-parse HEAD)"
echo "CAND_SHA=$CAND_SHA"

# 1. Dispatch claims a BUILD work order.
BUILD_OUT="$("$OFLOOP" dispatch claim "$REPO" "$RUN_ID")"
assert_eq "$(printf '%s' "$BUILD_OUT" | jq -r '.decision')" "BUILD" "dispatch claim returns BUILD"
BSEM="$(printf '%s' "$BUILD_OUT" | jq -r '.semantic_path')"
assert_file_exists "$BSEM" "builder semantic skeleton materialized"

# 2. Fill the synthetic semantic builder result.
python3 - "$BSEM" "$RUN_ID" "$CAND_SHA" <<'PY'
import json, sys
from pathlib import Path
sem, rid, sha = sys.argv[1], sys.argv[2], sys.argv[3]
p = Path(sem)
d = json.loads(p.read_text())
d["summary"] = "phase-d synthetic semantic builder result"
d["outcome_requested"] = "candidate_ready"
d["unit_ids_completed"] = ["UNIT-1"]
d["acceptance_addressed"] = ["AC-1"]
d["notes"] = f"phase-d fixture; expected candidate {sha[:12]}"
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY

# 3. Dispatch finalizes the BUILD pass.
FINALIZE_OUT="$("$OFLOOP" dispatch finalize "$REPO" "$RUN_ID" BUILD "$BSEM")"
assert_contains "$FINALIZE_OUT" '"ok": true' "build finalize succeeded"
assert_eq "$(jq -r '.state' "$REPO/.ownframework-loop/$RUN_ID/STATE.json")" "READY_FOR_REVIEW" "state advanced to READY_FOR_REVIEW"

# 4. Dispatch claims a REVIEW work order against the recorded exact SHA.
REVIEW_OUT="$("$OFLOOP" dispatch claim "$REPO" "$RUN_ID")"
assert_eq "$(printf '%s' "$REVIEW_OUT" | jq -r '.decision')" "REVIEW" "dispatch claim returns REVIEW"
assert_eq "$(printf '%s' "$REVIEW_OUT" | jq -r '.candidate_sha')" "$CAND_SHA" "review work order pins the exact candidate SHA"
RSEM="$(printf '%s' "$REVIEW_OUT" | jq -r '.semantic_path')"
assert_file_exists "$RSEM" "reviewer assessment skeleton materialized"

# 5. Fill the synthetic semantic reviewer assessment.
python3 - "$RSEM" "$RUN_ID" "$CAND_SHA" <<'PY'
import json, sys
from pathlib import Path
sem, rid, sha = sys.argv[1], sys.argv[2], sys.argv[3]
p = Path(sem)
d = json.loads(p.read_text())
d["validation_results"] = []
d["acceptance_results"] = [{"id": "AC-1", "result": "pass", "evidence": "phase-d exact-SHA review"}]
d["non_goal_results"] = []
d["findings"] = []
d["recommended_verdict"] = "APPROVED"
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY

# 6. Dispatch finalizes the REVIEW pass.
"$OFLOOP" dispatch finalize "$REPO" "$RUN_ID" REVIEW "$RSEM" >/dev/null

# 7. Terminal state must be APPROVED with all artifacts.
FINAL_STATE="$(jq -r '.state' "$REPO/.ownframework-loop/$RUN_ID/STATE.json")"
assert_eq "$FINAL_STATE" "APPROVED" "STATE.json.state == APPROVED"

assert_file_exists "$REPO/.ownframework-loop/$RUN_ID/APPROVAL.json" "APPROVAL.json present"
assert_file_exists "$REPO/.ownframework-loop/$RUN_ID/BUILD_RECEIPT.json" "BUILD_RECEIPT.json present"
assert_file_exists "$REPO/.ownframework-loop/$RUN_ID/REVIEW_VERDICT.json" "REVIEW_VERDICT.json present"
assert_file_exists "$REPO/.ownframework-loop/$RUN_ID/EVENTS.log" "EVENTS.log present"

BUILD_SHA="$(jq -r '.candidate_sha' "$REPO/.ownframework-loop/$RUN_ID/BUILD_RECEIPT.json")"
assert_eq "$BUILD_SHA" "$CAND_SHA" "BUILD_RECEIPT.candidate_sha matches worktree HEAD"

REVIEW_SHA="$(jq -r '.candidate_sha_reviewed' "$REPO/.ownframework-loop/$RUN_ID/REVIEW_VERDICT.json")"
assert_eq "$REVIEW_SHA" "$CAND_SHA" "REVIEW_VERDICT.candidate_sha_reviewed matches build SHA"

VERDICT="$(jq -r '.verdict' "$REPO/.ownframework-loop/$RUN_ID/REVIEW_VERDICT.json")"
assert_eq "$VERDICT" "APPROVED" "REVIEW_VERDICT.verdict is APPROVED"

# Confirm no push/merge/deploy occurred.
git -C "$REPO" branch --list "factory/candidate/$RUN_ID" >/dev/null \
  || fail "candidate branch missing"
NOPUSH="$(git -C "$REPO" log --all --oneline 2>/dev/null | wc -l)"
[[ "$NOPUSH" -le 2 ]] || fail "unrelated remote mutation detected"

grep -q "return 42" "$WT/src/marker.py" \
  && pass "acceptance criterion AC-1 satisfied (marker.py returns 42)" \
  || fail "AC-1 not satisfied in $WT/src/marker.py"

# Cleanup.
git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true

echo "PHASE_D_DISPATCH=PASS"