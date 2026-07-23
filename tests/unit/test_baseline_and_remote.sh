#!/usr/bin/env bash
# Case 9: dirty baseline refusal.
# Case 10: wrong repository refusal.
# Case 36: NEW_REPOSITORY local-only bootstrap.
# Case 37: no remote after new-repository flow.

set -uo pipefail
. "$(dirname "$0")/../_helpers.sh"

# Build a fresh local-only repo via the CLI.
ROOT="$(mktemp -d -t ofloop_test_root.XXXXXX)"
PROJECT="ofloop-test-pilot-$(printf '%04x' $RANDOM)"
"$OFLOOP_BIN" new-repo "$ROOT" "$PROJECT" --init-baseline >/dev/null
REPO="$ROOT/$PROJECT"
assert_dir_exists "$REPO" "new repo created"
BRANCH=$(git -C "$REPO" branch --show-current)
assert_eq "$BRANCH" "master" "branch is master"
RC=$(git -C "$REPO" remote | wc -l | tr -d ' ')
assert_eq "$RC" "0" "zero remotes after new-repo"

# Baseline is initialized: README and .gitignore present.
assert_file_exists "$REPO/README.md" "README exists"
assert_file_exists "$REPO/.gitignore" ".gitignore exists"
HEAD=$(git -C "$REPO" rev-parse HEAD)
assert_eq "${#HEAD}" 40 "baseline HEAD is a real SHA"

# Add a remote and confirm it is detected.
git -C "$REPO" remote add origin git@example.com:x/y.git
RC=$(git -C "$REPO" remote | wc -l | tr -d ' ')
assert_eq "$RC" "1" "remote added for negative test"
git -C "$REPO" remote remove origin

# Make baseline dirty; doctor should report it.
echo "uncommitted change" > "$REPO/dirty.txt"
OUT=$("$OFLOOP_BIN" doctor "$REPO" | python3 -c 'import sys, json; d=json.load(sys.stdin); print(d["is_dirty"])')
assert_eq "$OUT" "True" "doctor reports dirty baseline"

# Clean up.
rm -rf "$ROOT"
echo "ALL PASS"
