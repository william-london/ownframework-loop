#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail() {
  printf 'CHECKOUT_PORTABILITY=FAIL\n' >&2
  printf 'DETAIL=%s\n' "$1" >&2
  exit 1
}

SELF='tests/integration/test_checkout_portability.sh'

# Public source/tests must never depend on William's historical developer checkout.
# Exclude this test itself because it contains the sentinel strings by design.
for needle in \
  '/Users/mr.mrs.london' \
  '/Users/mr.mrs.london/projects/plugins/ownframework-loop' \
  '/tmp/v031_setup_run.py'
do
  if git grep -n -F -- "$needle" -- ':!docs/history/**' ":!$SELF" >/tmp/ofloop-portability-hits.txt 2>/dev/null; then
    cat /tmp/ofloop-portability-hits.txt >&2
    fail "tracked source depends on developer-machine path: $needle"
  fi
done

# One-shot repair/autofix workflows must not survive onto the reviewable branch.
while IFS= read -r workflow; do
  case "$workflow" in
    *v040*fix*.yml|*v040*fix*.yaml|*v040*autofix*.yml|*v040*autofix*.yaml)
      fail "temporary repair workflow still tracked: $workflow"
      ;;
  esac
done < <(git ls-files '.github/workflows/*')

# The tracked PROGRAM fixture helper that replaced the historical /tmp dependency
# must remain part of the checkout.
test -f tests/helpers/setup_program_run.py || fail 'tracked PROGRAM fixture helper missing'

printf 'CHECKOUT_PORTABILITY=PASS\n'
