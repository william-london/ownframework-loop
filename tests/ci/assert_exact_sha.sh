#!/usr/bin/env bash
# CI provenance boundary: prove the exact immutable event bytes before any gate.
set -euo pipefail

EXPECTED="${OFLOOP_CI_EXPECTED_SHA:?OFLOOP_CI_EXPECTED_SHA is required}"
BRANCH="${OFLOOP_CI_EXPECTED_BRANCH:?OFLOOP_CI_EXPECTED_BRANCH is required}"
ACTUAL="$(git rev-parse HEAD)"

if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  echo "CI_EXACT_SHA=FAIL expected=$EXPECTED actual=$ACTUAL" >&2
  exit 1
fi

# release_gate.sh verifies a branch identity rather than detached HEAD. Restore
# only the local branch name at the already-proven immutable SHA; never resolve
# or fetch a mutable remote branch here.
git checkout -q -B "$BRANCH" "$EXPECTED"

AFTER="$(git rev-parse HEAD)"
[[ "$AFTER" == "$EXPECTED" ]] || {
  echo "CI_EXACT_SHA=FAIL after_branch_restore=$AFTER expected=$EXPECTED" >&2
  exit 1
}
[[ -z "$(git status --porcelain)" ]] || {
  echo "CI_EXACT_SHA=FAIL worktree_dirty_after_branch_restore" >&2
  exit 1
}

echo "CI_EXACT_SHA=PASS sha=$EXPECTED branch=$BRANCH"
