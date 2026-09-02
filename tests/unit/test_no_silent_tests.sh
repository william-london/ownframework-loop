#!/usr/bin/env bash
# OwnFramework Loop — no-silent-tests gate.
#
# Fails if any test_*.sh script exists outside both tests/canonical.txt
# (the maintained, CI-authoritative list) and tests/non_canonical.txt
# (the documented-exclusion list).
#
# Run as part of validate.sh / release_gate.sh.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

ROOT="$(cd "$TESTS_DIR/.." && pwd)"

CANONICAL="$ROOT/tests/canonical.txt"
NONCANONICAL="$ROOT/tests/non_canonical.txt"

# Build the set of declared paths. Use awk to strip blanks/comments inline
# so the join is robust to a missing $NONCANONICAL.
declared="$(awk 'NR==FNR || 1' "$CANONICAL" "$NONCANONICAL" 2>/dev/null | awk '/^tests\//' | sort -u)"

# All test_*.sh scripts that exist on disk.
on_disk="$(find tests -name 'test_*.sh' -type f 2>/dev/null | sort -u)"

missing=""
for f in $on_disk; do
  # comm-style check is SIGPIPE-safe under set -euo pipefail
  if ! printf '%s\n' "$declared" | grep -F -x -- "$f" >/dev/null; then
    missing="$missing $f"
  fi
done

if [[ -n "$missing" ]]; then
  echo "FAIL: silent tests exist outside canonical+non-canonical manifests:"
  for m in $missing; do
    echo "  - $m"
  done
  echo "Add to tests/canonical.txt (with reason in canonical.txt header) or"
  echo "to tests/non_canonical.txt (with documented exclusion reason)."
  exit 1
fi

# Also: every entry in non_canonical.txt must reference an existing file.
undeclared=""
for f in $(cat "$NONCANONICAL" 2>/dev/null | grep -E '^tests/' || true); do
  if [[ ! -f "$f" ]]; then
    undeclared="$undeclared $f"
  fi
done
if [[ -n "$undeclared" ]]; then
  echo "FAIL: non_canonical.txt references missing files:"
  for u in $undeclared; do
    echo "  - $u"
  done
  exit 1
fi

echo "NO_SILENT_TESTS=PASS canonical=$(grep -cE '^tests/' "$CANONICAL") non_canonical=$(grep -cE '^tests/' "$NONCANONICAL") on_disk=$(printf '%s\n' "$on_disk" | wc -l | tr -d ' ')"