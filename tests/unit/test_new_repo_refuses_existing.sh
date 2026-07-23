#!/usr/bin/env bash
# Case 10: wrong repository refusal — refuse existing non-empty target.

set -uo pipefail
. "$(dirname "$0")/../_helpers.sh"

ROOT="$(mktemp -d -t ofloop_test_root.XXXXXX)"
TARGET="$ROOT/existing-project"
mkdir -p "$TARGET"
echo "preexisting" > "$TARGET/important.md"

# The CLI refuses a non-empty target.
set +e
"$OFLOOP_BIN" new-repo "$ROOT" "existing-project" >/dev/null 2>&1
RC=$?
set -e
if [[ "$RC" -ne 0 && "$RC" -ne 2 ]]; then
  fail "non-empty target must refuse (got RC=$RC, expected non-zero)"
fi
pass "non-empty target refuses (RC=$RC)"

# But a fresh empty target succeeds.
"$OFLOOP_BIN" new-repo "$ROOT" "fresh-project" --init-baseline >/dev/null
assert_dir_exists "$ROOT/fresh-project" "fresh project created"

rm -rf "$ROOT"
echo "ALL PASS"
