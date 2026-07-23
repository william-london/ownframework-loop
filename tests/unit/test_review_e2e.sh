#!/usr/bin/env bash
# Case 19: reviewer detached at exact SHA.
# Case 20: stale candidate detection.
# Case 21: review verdict validation.

set -uo pipefail
. "$(dirname "$0")/../_helpers.sh"

REPO="$(make_tmp_repo)"
RUN_DIR="$(make_tmp_run "$REPO")"
echo "  REPO=$REPO RUN_DIR=$RUN_DIR"

# Bootstrap packet + approve.
PACKET_MD='```json
{
  "schema": "ownframework-work-packet/v1",
  "packet_id": "rev-001",
  "created_at": "2026-07-23T05:00:00Z",
  "work_class": "FEATURE",
  "risk_class": "medium",
  "title": "Review E2E",
  "target": {"repo": "'"$REPO"'", "branch": "master", "classification": "local_only"},
  "acceptance_criteria": [{"id": "AC-1", "text": "x"}],
  "non_goals": [{"id": "NG-1", "text": "y"}],
  "allowed_paths": ["src/"],
  "protected_paths": [".ownframework-loop/"],
  "work_units": [{"id": "UNIT-1", "title": "u", "scope": "s"}],
  "merge_authority": "human_only",
  "deploy_authority": "human_only",
  "push_authority": "human_only",
  "external_action_authority": "none"
}
```
# Mission
review test.'
write_packet "$REPO" "$RUN_DIR" "$PACKET_MD" >/dev/null
"$OFLOOP_BIN" spec approve "$REPO" "$RUN_DIR" >/dev/null

# Build a candidate commit.
BRANCH="factory/candidate/$RUN_DIR"
git -C "$REPO" worktree add "$REPO/.worktrees/ownframework-loop/$RUN_DIR/builder" -b "$BRANCH" master >/dev/null 2>&1
WT="$REPO/.worktrees/ownframework-loop/$RUN_DIR/builder"
echo "x" > "$WT/feature.txt"
git -C "$WT" add feature.txt
git -C "$WT" commit -m "loop-v1: candidate" >/dev/null 2>&1
SHA=$(git -C "$WT" rev-parse HEAD)
BASE=$(git -C "$WT" rev-parse master)

"$OFLOOP_BIN" build claim "$REPO" "$RUN_DIR" >/dev/null

RECEIPT=$(mktemp)
cat > "$RECEIPT" <<JSON
{
  "schema": "ownframework-loop-build-receipt/v1",
  "run_id": "$RUN_DIR",
  "packet_sha256": "$(python3 -c 'import hashlib;print(hashlib.sha256(open("'"$REPO"'/.ownframework-loop/'"$RUN_DIR"'/WORK_PACKET.md","rb").read()).hexdigest())')",
  "work_unit_id": "UNIT-1",
  "baseline_sha": "$BASE",
  "candidate_sha": "$SHA",
  "candidate_branch": "$BRANCH",
  "builder_pass_number": 1,
  "repair_round": 0,
  "files_changed": 1,
  "added_lines": 1,
  "removed_lines": 0,
  "validation": [{"name": "fast", "command": "true", "exit_code": 0, "duration_seconds": 0}],
  "timestamp": "2026-07-23T05:30:00Z",
  "builder_agent": "of-builder",
  "next_state": "READY_FOR_REVIEW"
}
JSON
"$OFLOOP_BIN" build write-receipt "$REPO" "$RUN_DIR" "$RECEIPT" >/dev/null

# Now write a verdict for the correct SHA.
VERDICT=$(mktemp)
cat > "$VERDICT" <<JSON
{
  "schema": "ownframework-loop-review-verdict/v1",
  "run_id": "$RUN_DIR",
  "packet_sha256": "$(python3 -c 'import hashlib;print(hashlib.sha256(open("'"$REPO"'/.ownframework-loop/'"$RUN_DIR"'/WORK_PACKET.md","rb").read()).hexdigest())')",
  "candidate_sha_reviewed": "$SHA",
  "baseline_sha": "$BASE",
  "review_pass_number": 1,
  "verdict": "APPROVED",
  "acceptance_results": [{"id": "AC-1", "result": "pass", "evidence": "feature.txt exists"}],
  "non_goal_results": [{"id": "NG-1", "result": "preserved"}],
  "findings": [],
  "tracked_mutation_check": {"detected": false, "before_sha": "$SHA", "after_sha": "$SHA", "changed_paths": []},
  "stale_sha_check": {"sha_match": true, "receipt_match": true, "packet_hash_match": true},
  "reviewer_identity": "of-reviewer",
  "timestamp": "2026-07-23T05:31:00Z",
  "recommended_next_state": "APPROVED"
}
JSON

# Review pass: transition to REVIEWING.
python3 - <<PY
import sys
sys.path.insert(0, "/Users/mr.mrs.london/projects/plugins/ownframework-loop/lib")
from ownframework_loop import state
state.transition("$REPO", "$RUN_DIR", to_state="REVIEWING", actor="of-reviewer", reason="claim")
PY

"$OFLOOP_BIN" review write-verdict "$REPO" "$RUN_DIR" "$VERDICT" >/dev/null
STATE=$(python3 -c "import json; print(json.load(open('$REPO/.ownframework-loop/$RUN_DIR/STATE.json'))['state'])")
assert_eq "$STATE" "APPROVED" "state after approved verdict"
pass "APPROVED transition recorded"

# Stale candidate detection: write a verdict for a fake SHA.
"$OFLOOP_BIN" spec new "$REPO" "second mission" >/dev/null
RUN2=$(ls -1t "$REPO/.ownframework-loop" | head -n1)
PACKET_MD2=$(echo "$PACKET_MD" | sed "s/$RUN_DIR/$RUN2/g")
write_packet "$REPO" "$RUN2" "$PACKET_MD2" >/dev/null
"$OFLOOP_BIN" spec approve "$REPO" "$RUN2" >/dev/null
"$OFLOOP_BIN" build claim "$REPO" "$RUN2" >/dev/null
RECEIPT2=$(mktemp)
cat > "$RECEIPT2" <<JSON
{
  "schema": "ownframework-loop-build-receipt/v1",
  "run_id": "$RUN2",
  "packet_sha256": "$(python3 -c 'import hashlib;print(hashlib.sha256(open("'"$REPO"'/.ownframework-loop/'"$RUN2"'/WORK_PACKET.md","rb").read()).hexdigest())')",
  "work_unit_id": "UNIT-1",
  "baseline_sha": "$BASE",
  "candidate_sha": "$SHA",
  "candidate_branch": "factory/candidate/$RUN2",
  "builder_pass_number": 1,
  "repair_round": 0,
  "files_changed": 1, "added_lines": 1, "removed_lines": 0,
  "validation": [{"name": "fast", "command": "true", "exit_code": 0, "duration_seconds": 0}],
  "timestamp": "2026-07-23T05:30:00Z",
  "builder_agent": "of-builder",
  "next_state": "READY_FOR_REVIEW"
}
JSON
"$OFLOOP_BIN" build write-receipt "$REPO" "$RUN2" "$RECEIPT2" >/dev/null

# Write verdict with WRONG candidate SHA.
STALE_VERDICT=$(mktemp)
FAKE_SHA="0000000000000000000000000000000000000000"
cat > "$STALE_VERDICT" <<JSON
{
  "schema": "ownframework-loop-review-verdict/v1",
  "run_id": "$RUN2",
  "packet_sha256": "$(python3 -c 'import hashlib;print(hashlib.sha256(open("'"$REPO"'/.ownframework-loop/'"$RUN2"'/WORK_PACKET.md","rb").read()).hexdigest())')",
  "candidate_sha_reviewed": "$FAKE_SHA",
  "baseline_sha": "$BASE",
  "review_pass_number": 1,
  "verdict": "APPROVED",
  "acceptance_results": [], "non_goal_results": [], "findings": [],
  "tracked_mutation_check": {"detected": false, "before_sha": "$FAKE_SHA", "after_sha": "$FAKE_SHA", "changed_paths": []},
  "stale_sha_check": {"sha_match": true, "receipt_match": true, "packet_hash_match": true},
  "reviewer_identity": "of-reviewer",
  "timestamp": "2026-07-23T05:32:00Z",
  "recommended_next_state": "APPROVED"
}
JSON
python3 - <<PY
import sys
sys.path.insert(0, "/Users/mr.mrs.london/projects/plugins/ownframework-loop/lib")
from ownframework_loop import state
state.transition("$REPO", "$RUN2", to_state="REVIEWING", actor="of-reviewer", reason="claim")
PY
"$OFLOOP_BIN" review write-verdict "$REPO" "$RUN2" "$STALE_VERDICT" >/dev/null
STATE2=$(python3 -c "import json; print(json.load(open('$REPO/.ownframework-loop/$RUN2/STATE.json'))['state'])")
assert_eq "$STATE2" "READY_FOR_REVIEW" "stale SHA blocks APPROVED and reverts to READY_FOR_REVIEW"

rm -f "$RECEIPT" "$RECEIPT2" "$VERDICT" "$STALE_VERDICT"
git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1

echo "ALL PASS"
