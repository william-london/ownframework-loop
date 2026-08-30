#!/usr/bin/env bash
# Static CI provenance guard. Runtime equality is enforced by assert_exact_sha.sh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"

WF="$ROOT_DIR/.github/workflows/ci.yml"
ASSERT="$ROOT_DIR/tests/ci/assert_exact_sha.sh"

grep -Fq 'OFLOOP_CI_EXPECTED_SHA: ${{ github.event.pull_request.head.sha || github.sha }}' "$WF" \
  || fail "workflow does not derive immutable expected event SHA"
grep -Fq 'ref: ${{ github.event.pull_request.head.sha || github.sha }}' "$WF" \
  || fail "workflow checkout is not pinned to event SHA"
if grep -Fq 'ref: ${{ github.head_ref || github.ref_name }}' "$WF"; then
  fail "mutable branch-ref checkout returned"
fi

CHECKOUTS="$(grep -c 'uses: actions/checkout@v6' "$WF")"
ASSERTS="$(grep -c 'run: bash tests/ci/assert_exact_sha.sh' "$WF")"
[[ "$CHECKOUTS" -eq "$ASSERTS" ]] \
  || fail "every checkout needs exact-SHA proof: checkouts=$CHECKOUTS assertions=$ASSERTS"

grep -Fq 'ACTUAL="$(git rev-parse HEAD)"' "$ASSERT" || fail "exact-SHA script does not read HEAD"
grep -Fq 'if [[ "$ACTUAL" != "$EXPECTED" ]]' "$ASSERT" || fail "exact-SHA script does not compare HEAD to event SHA"
grep -Fq 'git checkout -q -B "$BRANCH" "$EXPECTED"' "$ASSERT" || fail "branch restoration is not pinned to expected SHA"
grep -Fq 'CI_EXACT_SHA=PASS' "$ASSERT" || fail "exact-SHA proof marker missing"
grep -Fq "'hardening/**'" "$WF" || fail "hardening branches are not hosted-CI eligible"
grep -Fq 'bash tests/external_runtime/claude_cli_surface.sh' "$WF" \
  || fail "current Claude invocation compatibility proof is not wired into hosted CI"

pass "CI checkout and release-gate branch restoration are exact-event-SHA pinned"
echo "V085_CI_EXACT_SHA=PASS"
