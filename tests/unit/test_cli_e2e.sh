#!/usr/bin/env bash
# CLI E2E — V2 packet, deterministic finalizer, build claim/finalize.

set -uo pipefail
. "$(dirname "$0")/../_helpers.sh"

# End-to-end CLI exercise on a fresh temp repo.
REPO="$(make_tmp_repo)"
RUN_DIR="$(make_approved_run "$REPO" BUG low "cli-e2e")"
echo "  REPO=$REPO RUN_DIR=$RUN_DIR"

STATE_FILE="$REPO/.ownframework-loop/$RUN_DIR/STATE.json"
STATE=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['state'])")
assert_eq "$STATE" "READY_TO_BUILD" "state after approve"

# Build claim.
"$OFLOOP_BIN" build claim "$REPO" "$RUN_DIR" >/dev/null
STATE=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['state'])")
assert_eq "$STATE" "BUILDING" "state after claim"

# Make a candidate commit on a worktree-like branch.
BRANCH="factory/candidate/$RUN_DIR"
git -C "$REPO" worktree add "$REPO/.worktrees/ownframework-loop/$RUN_DIR/builder" -b "$BRANCH" master >/dev/null 2>&1
WT="$REPO/.worktrees/ownframework-loop/$RUN_DIR/builder"
mkdir -p "$WT/src"
echo "candidate content" > "$WT/src/feature.txt"
git -C "$WT" add src/feature.txt
git -C "$WT" commit -m "loop-v2: candidate" >/dev/null 2>&1
SHA=$(git -C "$WT" rev-parse HEAD)
assert_eq "${#SHA}" 40 "candidate SHA is 40 hex chars"

# Finalize build (deterministic).
"$OFLOOP_BIN" build finalize "$REPO" "$RUN_DIR" >/dev/null
assert_file_exists "$REPO/.ownframework-loop/$RUN_DIR/BUILD_RECEIPT.json" "build receipt exists"

# Verify the receipt SHA matches the worktree SHA.
R_SHA=$(python3 -c "import json; print(json.load(open('$REPO/.ownframework-loop/$RUN_DIR/BUILD_RECEIPT.json'))['candidate_sha'])")
assert_eq "$R_SHA" "$SHA" "receipt references real SHA"

STATE=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['state'])")
assert_eq "$STATE" "READY_FOR_REVIEW" "state after receipt write"

# Verify the SHA really exists in the repo.
git -C "$REPO" cat-file -e "$SHA" && pass "candidate SHA exists in repo" || fail "candidate SHA missing"

# Cleanup
git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1

echo "ALL PASS"
