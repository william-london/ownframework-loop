#!/usr/bin/env bash
# v0.3.3 Repair C: structural manifest count truth.
# 5 connected tests prove the new manifest_count_check.py reports
# PAYLOAD_MANIFEST_HEADER_LINES, PAYLOAD_MANIFEST_FILE_ENTRIES,
# INSTALLED_ACTIVE_FILES and asserts file_entries == active_files.
set -uo pipefail
ROOT="/Users/mr.mrs.london/projects/plugins/ownframework-loop"
TEST_ROOT="/tmp/v033_count_$$"
mkdir -p "$TEST_ROOT"
trap 'rm -rf "$TEST_ROOT"' EXIT

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; exit 1; }

make_cache() {
  local r="$1"
  mkdir -p "$r/lib" "$r/lib/ownframework_loop" "$r/lib/ownframework_loop/__pycache__" "$r/logs"
  echo "src1" > "$r/lib/ownframework_loop/a.py"
  echo "src2" > "$r/lib/ownframework_loop/b.py"
  echo "{}" > "$r/lib/ownframework_loop/config.json"
  echo "bc" > "$r/lib/ownframework_loop/__pycache__/a.cpython-312.pyc"
  echo "log" > "$r/logs/run.log"
}

write_manifest() {
  local r="$1" declared="$2"
  > "$r/.payload.manifest"
  {
    echo "# OwnFramework Loop payload manifest"
    echo "# generated_at_utc=2026-07-31T16:00:00Z"
    echo "# cache_root=$r"
    echo "# source_branch=test"
    echo "# source_sha=testsha"
    echo "# installed_version=0.3.3"
    echo "# file_count=$declared"
  } >> "$r/.payload.manifest"
  (cd "$r" && find . -type f \
    -not -path './logs/*' \
    -not -path './.git/*' \
    -not -path './.ownframework-loop/*' \
    -not -path '*/__pycache__/*' \
    -not -name '*.pyc' \
    -not -name '*.pyo' \
    -not -name '*.pyd' \
    -not -name '.payload.manifest' \
    -not -name '.payload.manifest.tmp' \
    | LC_ALL=C sort | while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      rel="${f#./}"
      sha="$(shasum -a 256 "$r/$rel" 2>/dev/null | awk '{print $1}')"
      echo "sha256  $sha  $rel" >> "$r/.payload.manifest"
    done)
}

# 1. Reports all three counts on a clean cache.
echo "Test 1: clean cache reports header_lines, file_entries, active_files"
make_cache "$TEST_ROOT/c1"
write_manifest "$TEST_ROOT/c1" 3
PYTHONDONTWRITEBYTECODE=1 python3 -B "$ROOT/scripts/manifest_count_check.py" --root "$TEST_ROOT/c1" --manifest "$TEST_ROOT/c1/.payload.manifest" > "$TEST_ROOT/out1" 2>&1
echo "  out1:"
cat "$TEST_ROOT/out1" | sed 's/^/    /'
grep -q "PAYLOAD_MANIFEST_HEADER_LINES=" "$TEST_ROOT/out1" || fail "Test 1: missing HEADER_LINES"
grep -q "PAYLOAD_MANIFEST_FILE_ENTRIES=3" "$TEST_ROOT/out1" || fail "Test 1: missing FILE_ENTRIES=3"
grep -q "INSTALLED_ACTIVE_FILES=3" "$TEST_ROOT/out1" || fail "Test 1: missing ACTIVE_FILES=3"
grep -q "PASS: manifest count truth" "$TEST_ROOT/out1" || fail "Test 1: did not pass: $(cat $TEST_ROOT/out1)"
pass "Test 1: counts reported and equal"

# 2. Declared file_count header must match actual entries.
echo "Test 2: declared file_count header must match actual entries"
make_cache "$TEST_ROOT/c2"
# Mismatch: declared=5 but only 3 active files
> "$TEST_ROOT/c2/.payload.manifest"
{
  echo "# header"
  echo "# file_count=5"
} >> "$TEST_ROOT/c2/.payload.manifest"
(cd "$TEST_ROOT/c2" && find . -type f \
  -not -path './logs/*' -not -path './.git/*' -not -path './.ownframework-loop/*' \
  -not -path '*/__pycache__/*' -not -name '*.pyc' -not -name '*.pyo' -not -name '*.pyd' \
  -not -name '.payload.manifest' -not -name '.payload.manifest.tmp' \
  | LC_ALL=C sort | while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    rel="${f#./}"
    sha="$(shasum -a 256 "$TEST_ROOT/c2/$rel" 2>/dev/null | awk '{print $1}')"
    echo "sha256  $sha  $rel" >> "$TEST_ROOT/c2/.payload.manifest"
  done)
out=$(PYTHONDONTWRITEBYTECODE=1 python3 -B "$ROOT/scripts/manifest_count_check.py" --root "$TEST_ROOT/c2" --manifest "$TEST_ROOT/c2/.payload.manifest" 2>&1)
echo "  out2: $out"
echo "$out" | grep -q "FAIL" || fail "Test 2: should have failed"
echo "$out" | grep -q "declared file_count header 5 != actual file entries 3" || fail "Test 2: wrong reason: $out"
pass "Test 2: declared mismatch detected"

# 3. Manifest with extra entry fails (entry not in active payload).
echo "Test 3: extra manifest entry fails (entry not on disk)"
make_cache "$TEST_ROOT/c3"
write_manifest "$TEST_ROOT/c3" 3
# Append a fake entry for a file that doesn't exist
echo "sha256  0000000000000000000000000000000000000000000000000000000000000000  lib/ownframework_loop/ghost.py" >> "$TEST_ROOT/c3/.payload.manifest"
out=$(PYTHONDONTWRITEBYTECODE=1 python3 -B "$ROOT/scripts/manifest_count_check.py" --root "$TEST_ROOT/c3" --manifest "$TEST_ROOT/c3/.payload.manifest" 2>&1)
echo "  out3: $out"
echo "$out" | grep -q "PAYLOAD_MANIFEST_FILE_ENTRIES=4" || fail "Test 3: wrong file entry count: $out"
echo "$out" | grep -q "INSTALLED_ACTIVE_FILES=3" || fail "Test 3: wrong active count: $out"
echo "$out" | grep -q "FAIL" || fail "Test 3: should have failed"
pass "Test 3: extra manifest entry detected"

# 4. Extra active file (no manifest entry) fails.
echo "Test 4: extra active file (no manifest entry) fails"
make_cache "$TEST_ROOT/c4"
write_manifest "$TEST_ROOT/c4" 3
echo "extra" > "$TEST_ROOT/c4/lib/ownframework_loop/injected.py"
out=$(PYTHONDONTWRITEBYTECODE=1 python3 -B "$ROOT/scripts/manifest_count_check.py" --root "$TEST_ROOT/c4" --manifest "$TEST_ROOT/c4/.payload.manifest" 2>&1)
echo "  out4: $out"
echo "$out" | grep -q "PAYLOAD_MANIFEST_FILE_ENTRIES=3" || fail "Test 4: wrong file entry count: $out"
echo "$out" | grep -q "INSTALLED_ACTIVE_FILES=4" || fail "Test 4: wrong active count: $out"
echo "$out" | grep -q "FAIL" || fail "Test 4: should have failed"
pass "Test 4: extra active file detected"

# 5. Bytecode and runtime cache are EXCLUDED from active count.
echo "Test 5: bytecode and logs are excluded from active count"
make_cache "$TEST_ROOT/c5"
write_manifest "$TEST_ROOT/c5" 3
out=$(PYTHONDONTWRITEBYTECODE=1 python3 -B "$ROOT/scripts/manifest_count_check.py" --root "$TEST_ROOT/c5" --manifest "$TEST_ROOT/c5/.payload.manifest" 2>&1)
echo "  out5: $out"
echo "$out" | grep -q "INSTALLED_ACTIVE_FILES=3" || fail "Test 5: bytecode/logs leaked into active count: $out"
echo "$out" | grep -q "PASS" || fail "Test 5: should pass with bytecode excluded: $out"
pass "Test 5: bytecode excluded from active count"

echo "ALL V0.3.3 MANIFEST-COUNT TESTS PASS"
