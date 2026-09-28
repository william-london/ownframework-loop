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

# Manifest entries are paths only; blanks and comments are not declarations.
manifest_entries() {
  awk 'NF && $1 !~ /^#/ && $1 ~ /^tests\// { print $1 }' "$1"
}

manifest_duplicates() {
  manifest_entries "$1" | sort | uniq -d
}

manifest_overlap() {
  comm -12 \
    <(manifest_entries "$1" | sort -u) \
    <(manifest_entries "$2" | sort -u)
}

for manifest_spec in "$CANONICAL:canonical" "$NONCANONICAL:non-canonical"; do
  manifest="${manifest_spec%%:*}"
  label="${manifest_spec#*:}"
  duplicates="$(manifest_duplicates "$manifest")"
  if [[ -n "$duplicates" ]]; then
    echo "FAIL: duplicate entries in $label test manifest:"
    while IFS= read -r path; do echo "  - $path"; done <<< "$duplicates"
    exit 1
  fi
done

overlap="$(manifest_overlap "$CANONICAL" "$NONCANONICAL")"
if [[ -n "$overlap" ]]; then
  echo "FAIL: tests cannot be both canonical and non-canonical:"
  while IFS= read -r path; do echo "  - $path"; done <<< "$overlap"
  exit 1
fi

# Behavioral regression: the same duplicate/overlap detectors used above
# reject duplicate canonical declarations and cross-manifest declarations.
manifest_fixture="$(mktemp -d -t ofloop-manifest-contract.XXXXXX)"
trap 'rm -rf "$manifest_fixture"' EXIT
printf 'tests/example.sh\ntests/example.sh\n' > "$manifest_fixture/canonical-duplicate.txt"
if [[ "$(manifest_duplicates "$manifest_fixture/canonical-duplicate.txt")" != "tests/example.sh" ]]; then
  echo "FAIL: duplicate canonical fixture was not detected"
  exit 1
fi
printf 'tests/example.sh\n' > "$manifest_fixture/canonical.txt"
printf 'tests/example.sh\n' > "$manifest_fixture/non-canonical.txt"
if [[ "$(manifest_overlap "$manifest_fixture/canonical.txt" "$manifest_fixture/non-canonical.txt")" != "tests/example.sh" ]]; then
  echo "FAIL: cross-manifest fixture was not detected"
  exit 1
fi
echo "CANONICAL_MANIFEST_DUPLICATE_GUARD=PASS"
echo "CANONICAL_NONCANONICAL_OVERLAP_GUARD=PASS"

# Build the set of declared paths after proving each manifest's unique ownership.
declared="$( { manifest_entries "$CANONICAL"; manifest_entries "$NONCANONICAL"; } | sort -u)"

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
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  if [[ ! -f "$f" ]]; then
    undeclared="$undeclared $f"
  fi
done < <(manifest_entries "$NONCANONICAL")
if [[ -n "$undeclared" ]]; then
  echo "FAIL: non_canonical.txt references missing files:"
  for u in $undeclared; do
    echo "  - $u"
  done
  exit 1
fi

# The gate must process a final manifest entry even without a trailing
# newline. Execute the exact reader condition extracted from the real runner;
# this behavioral fixture does not recursively invoke the release hierarchy.
python3 - "$TESTS_DIR/run_all.sh" <<'PYTEST'
from pathlib import Path
import subprocess
import sys
import tempfile

runner = Path(sys.argv[1])
condition = next(
    (line.strip() for line in runner.read_text(encoding="utf-8").splitlines()
     if line.startswith("while IFS= read -r rel ||")),
    None,
)
expected = 'while IFS= read -r rel || [[ -n "$rel" ]]; do'
assert condition == expected, (condition, expected)
with tempfile.TemporaryDirectory(prefix="ofloop-canonical-eof-") as tmp:
    manifest = Path(tmp) / "canonical.txt"
    manifest.write_bytes(b"tests/final-entry.sh")
    harness = "\n".join((
        "set -eu",
        "count=0",
        condition,
        "  count=$((count + 1))",
        '  printf "ENTRY=%s\\n" "$rel"',
        'done < "$1"',
        'printf "COUNT=%s\\n" "$count"',
    ))
    result = subprocess.run(
        ["bash", "-c", harness, "ofloop-eof-reader", str(manifest)],
        check=False, capture_output=True, text=True, timeout=3,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout == "ENTRY=tests/final-entry.sh\nCOUNT=1\n", result.stdout
print("CANONICAL_UNTERMINATED_FINAL_ENTRY=PASS")
PYTEST

echo "NO_SILENT_TESTS=PASS canonical=$(grep -cE '^tests/' "$CANONICAL") non_canonical=$(grep -cE '^tests/' "$NONCANONICAL") on_disk=$(printf '%s\n' "$on_disk" | wc -l | tr -d ' ')"
