#!/usr/bin/env bash
# Review E2E — V2 deterministic finalizers.

set -uo pipefail
. "$(dirname "$0")/../_helpers.sh"

REPO="$(make_tmp_repo)"
RUN_DIR="$(make_approved_run "$REPO" BUG low "review-e2e")"
echo "  REPO=$REPO RUN_DIR=$RUN_DIR"

# Build candidate.
BRANCH="factory/candidate/$RUN_DIR"
git -C "$REPO" worktree add "$REPO/.worktrees/ownframework-loop/$RUN_DIR/builder" -b "$BRANCH" master >/dev/null 2>&1
WT="$REPO/.worktrees/ownframework-loop/$RUN_DIR/builder"
mkdir -p "$WT/src"
echo "x" > "$WT/src/feature.txt"
git -C "$WT" add src/feature.txt && git -C "$WT" commit -m "loop-v2: candidate" >/dev/null 2>&1
SHA=$(git -C "$WT" rev-parse HEAD)
BASE=$(git -C "$WT" rev-parse master)

"$OFLOOP_BIN" build claim "$REPO" "$RUN_DIR" >/dev/null
"$OFLOOP_BIN" build finalize "$REPO" "$RUN_DIR" >/dev/null 2>&1

# Verify receipt exists.
[[ -f "$REPO/.ownframework-loop/$RUN_DIR/BUILD_RECEIPT.json" ]] && pass "build receipt present" || fail "build receipt missing"

# Transition to REVIEWING (required by transition table).
python3 - <<PY
import sys
sys.path.insert(0, "/Users/mr.mrs.london/projects/plugins/ownframework-loop/lib")
from ownframework_loop import state
from pathlib import Path
state.transition(Path("$REPO"), "$RUN_DIR", to_state="REVIEWING", actor="test", reason="claim")
PY

# Now create the assessment.
ASSESS=$(mktemp)
cat > "$ASSESS" <<JSON
{
  "schema": "ownframework-loop-review-agent-assessment/v1",
  "run_id": "$RUN_DIR",
  "candidate_sha_claimed": "$SHA",
  "acceptance_results": [{"id": "AC-1", "result": "pass"}],
  "non_goal_results": [],
  "findings": [],
  "recommended_verdict": "APPROVED"
}
JSON

# Finalize review.
"$OFLOOP_BIN" review finalize "$REPO" "$RUN_DIR" "$ASSESS" >/dev/null 2>&1
VERDICT_FILE="$REPO/.ownframework-loop/$RUN_DIR/REVIEW_VERDICT.json"
[[ -f "$VERDICT_FILE" ]] && pass "review verdict written by finalizer" || fail "review verdict missing"

V=$(python3 -c "import json; print(json.load(open('$VERDICT_FILE'))['verdict'])")
assert_eq "$V" "APPROVED" "verdict is APPROVED"

# State after approved verdict.
STATE=$(python3 -c "import json; print(json.load(open('$REPO/.ownframework-loop/$RUN_DIR/STATE.json'))['state'])")
assert_eq "$STATE" "APPROVED" "state after approved verdict"

# Stale candidate: new run with mismatched SHA.
"$OFLOOP_BIN" spec new "$REPO" "second mission" >/dev/null
RUN2=$(ls -1t "$REPO/.ownframework-loop" | head -n1)
# Approve RUN2 by writing packet + approval.
PP2="$REPO/.ownframework-loop/$RUN2/WORK_PACKET.md"
cat > "$PP2" <<EOF
\`\`\`json
{
  "schema": "ownframework-work-packet/v2",
  "packet_id": "rev-002",
  "created_at": "2026-07-23T00:00:00Z",
  "work_class": "BUG",
  "risk_class": "low",
  "title": "stale-test",
  "target": {"repo": "$REPO", "branch": "master", "classification": "local_only"},
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
\`\`\`
body
EOF
# Now use Python to write a proper approval.
python3 - "$REPO" "$RUN2" <<'PY'
import sys, json, subprocess
from pathlib import Path
sys.path.insert(0, "/Users/mr.mrs.london/projects/plugins/ownframework-loop/lib")
from ownframework_loop import approval, state as state_mod
canonical_repo = Path(sys.argv[1])
run_id = sys.argv[2]
pp = canonical_repo / ".ownframework-loop" / run_id / "WORK_PACKET.md"
sha = __import__("hashlib").sha256(pp.read_bytes()).hexdigest()
baseline = subprocess.run(
    ["git", "-C", str(canonical_repo), "rev-parse", "master"],
    capture_output=True, text=True, check=True,
).stdout.strip()
doc = {
    "schema": "ownframework-loop-approval/v1",
    "run_id": run_id,
    "packet_sha256": sha,
    "approved_at": "2026-07-23T00:00:00Z",
    "approved_actor": "test",
    "canonical_repo": str(canonical_repo.resolve(strict=False)),
    "baseline_branch": "master",
    "baseline_sha": baseline,
    "packet_schema": "ownframework-work-packet/v2",
    "approval_method": "operator_marker",
    "confirmation_token": approval.derive_confirmation_token(sha),
}
Path(canonical_repo, ".ownframework-loop", run_id, "APPROVAL.json").write_text(
    json.dumps(doc, indent=2, sort_keys=True))
state_mod.transition(canonical_repo, run_id, to_state="READY_TO_BUILD", actor="test", reason="x")
PY

# Build candidate for RUN2.
WT2="$REPO/.worktrees/ownframework-loop/$RUN2/builder"
git -C "$REPO" worktree add "$WT2" -b "factory/candidate/$RUN2" master >/dev/null 2>&1
mkdir -p "$WT2/src"
echo y > "$WT2/src/y.py"
git -C "$WT2" add src/y.py && git -C "$WT2" commit -m y >/dev/null 2>&1
SHA2=$(git -C "$WT2" rev-parse HEAD)

"$OFLOOP_BIN" build claim "$REPO" "$RUN2" >/dev/null
"$OFLOOP_BIN" build finalize "$REPO" "$RUN2" >/dev/null 2>&1

# Transition RUN2 to REVIEWING.
python3 - <<PY
import sys
sys.path.insert(0, "/Users/mr.mrs.london/projects/plugins/ownframework-loop/lib")
from ownframework_loop import state
from pathlib import Path
state.transition(Path("$REPO"), "$RUN2", to_state="REVIEWING", actor="test", reason="claim")
PY

# Stale SHA in assessment.
STALE_ASSESS=$(mktemp)
FAKE_SHA="0000000000000000000000000000000000000000"
cat > "$STALE_ASSESS" <<JSON
{
  "schema": "ownframework-loop-review-agent-assessment/v1",
  "run_id": "$RUN2",
  "candidate_sha_claimed": "$FAKE_SHA",
  "acceptance_results": [{"id": "AC-1", "result": "pass"}],
  "non_goal_results": [],
  "findings": [],
  "recommended_verdict": "APPROVED"
}
JSON
out="$("$OFLOOP_BIN" review finalize "$REPO" "$RUN2" "$STALE_ASSESS" 2>&1 || true)"
assert_contains "$out" "OF_LOOP_REVIEW_FINALIZE_REFUSED" "stale SHA refused by review finalizer"

# Cleanup.
rm -f "$ASSESS" "$STALE_ASSESS"
git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
git -C "$REPO" worktree remove --force "$WT2" >/dev/null 2>&1

echo "ALL PASS"
