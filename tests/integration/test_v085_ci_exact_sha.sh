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

# Hardening eligibility is a HEAD-branch property. GitHub pull_request.branches
# filters the PR BASE branch, so merely finding the string hardening/** is not
# sufficient. Prove the workflow has a push->branches hardening trigger and
# does not pretend a PR base filter makes hardening head branches eligible.
python3 - "$WF" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
expected = "  push:\n    branches:\n      - 'hardening/**'\n"
if expected not in text:
    raise SystemExit("hardening branches are not hosted-CI eligible by push head ref")
if "  pull_request:\n    branches:\n      - 'hardening/**'\n" in text:
    raise SystemExit("hardening eligibility incorrectly uses pull_request base-branch filter")
PY
pass "hardening head branches trigger hosted CI on push, not PR base filtering"

grep -Fq 'bash tests/external_runtime/claude_cli_surface.sh' "$WF" \
  || fail "current Claude invocation compatibility proof is not wired into hosted CI"

pass "CI checkout and release-gate branch restoration are exact-event-SHA pinned"
echo "V085_CI_EXACT_SHA=PASS"
