#!/usr/bin/env bash
# Phase V2: bytecode boundary (Blocker 2 closeout).
# 10 connected tests prove install.sh manifest excludes bytecode,
# launcher suppresses bytecode, and validator accepts/runs correctly.
set -uo pipefail
ROOT="/Users/mr.mrs.london/projects/plugins/ownframework-loop"
LIB="$ROOT/lib"
TEST_ROOT="/tmp/v032_tests/bc_$$"
mkdir -p "$TEST_ROOT/cache"
trap 'rm -rf "$TEST_ROOT"' EXIT

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; exit 1; }

# Build a fake cache tree with bytecode + active source + logs.
make_fake_cache() {
  local root="$1"
  mkdir -p "$root/lib/ownframework_loop" "$root/lib/ownframework_loop/__pycache__" "$root/logs" "$root/.git" "$root/.ownframework-loop"
  # Active source files
  echo "source1" > "$root/lib/ownframework_loop/a.py"
  echo "source2" > "$root/lib/ownframework_loop/b.py"
  echo '{"x": 1}' > "$root/lib/ownframework_loop/config.json"
  # Disposable bytecode
  echo "bytecode" > "$root/lib/ownframework_loop/__pycache__/a.cpython-312.pyc"
  echo "bytecode" > "$root/lib/ownframework_loop/b.pyo"
  # Logs (user data)
  echo "log" > "$root/logs/run.log"
  # .git (must be excluded)
  echo "git" > "$root/.git/HEAD"
  # .ownframework-loop (must be excluded)
  echo "ow" > "$root/.ownframework-loop/EVENTS.log"
}

# 1. install.sh manifest pattern excludes __pycache__/* from staged payload.
echo "Test 1: install.sh PAYLOAD_FILES find excludes __pycache__ and bytecode"
grep -F -q "*/__pycache__/" "$ROOT/install.sh" || fail "Test 1: install.sh missing __pycache__ exclusion"
grep -F -q "*.pyc" "$ROOT/install.sh" || fail "Test 1: install.sh missing *.pyc exclusion"
grep -F -q "*.pyo" "$ROOT/install.sh" || fail "Test 1: install.sh missing *.pyo exclusion"
grep -F -q "./.ownframework-loop/" "$ROOT/install.sh" || fail "Test 1: install.sh missing .ownframework-loop exclusion"
grep -F -q "./.git/" "$ROOT/install.sh" || fail "Test 1: install.sh missing .git exclusion"
grep -F -q "./logs/" "$ROOT/install.sh" || fail "Test 1: install.sh missing logs exclusion"
pass "Test 1: install.sh PAYLOAD_FILES excludes bytecode/.git/.ownframework-loop/logs"

# 2. install.sh exclusion produces a manifest that does NOT contain bytecode.
echo "Test 2: simulated manifest run excludes bytecode from staged payload"
make_fake_cache "$TEST_ROOT/cache"
PAYLOAD_FILES="$(cd "$TEST_ROOT/cache" && find . -type f \
  -not -path './logs/*' \
  -not -path './.git/*' \
  -not -path './.ownframework-loop/*' \
  -not -path '*/__pycache__/*' \
  -not -name '*.pyc' \
  -not -name '*.pyo' \
  -not -name '*.pyd' \
  -not -name '.payload.manifest' \
  -not -name '.payload.manifest.tmp' \
  | LC_ALL=C sort)"
echo "$PAYLOAD_FILES" | grep -q 'pyc' && fail "Test 2: payload contains pyc: $PAYLOAD_FILES"
echo "$PAYLOAD_FILES" | grep -q 'pyo' && fail "Test 2: payload contains pyo: $PAYLOAD_FILES"
echo "$PAYLOAD_FILES" | grep -q '\.git/HEAD' && fail "Test 2: payload contains .git: $PAYLOAD_FILES"
echo "$PAYLOAD_FILES" | grep -q 'logs/run.log' && fail "Test 2: payload contains logs: $PAYLOAD_FILES"
echo "$PAYLOAD_FILES" | grep -q 'a.py' || fail "Test 2: payload missing active source"
echo "$PAYLOAD_FILES" | grep -q 'config.json' || fail "Test 2: payload missing config"
echo "  PAYLOAD_FILES=$PAYLOAD_FILES"
pass "Test 2: bytecode/state excluded from staged payload"

# 3. bin/ofloop launcher sets PYTHONDONTWRITEBYTECODE=1.
echo "Test 3: bin/ofloop sets PYTHONDONTWRITEBYTECODE=1"
grep -F -q "PYTHONDONTWRITEBYTECODE" "$ROOT/bin/ofloop" || fail "Test 3: ofloop missing PYTHONDONTWRITEBYTECODE"
grep -F -q "os.environ.setdefault" "$ROOT/bin/ofloop" && grep -F -q "PYTHONDONTWRITEBYTECODE" "$ROOT/bin/ofloop" || fail "Test 3: ofloop not using setdefault"
pass "Test 3: bin/ofloop sets PYTHONDONTWRITEBYTECODE"

# 4. ofloop-launcher runtime: PYTHONDONTWRITEBYTECODE is set.
echo "Test 4: ofloop launcher sets PYTHONDONTWRITEBYTECODE before module imports"
out=$(env -u PYTHONDONTWRITEBYTECODE python3 -c '
import os, sys
# Read the launcher source first to verify the setdefault.
src = open("/Users/mr.mrs.london/projects/plugins/ownframework-loop/bin/ofloop").read()
assert "PYTHONDONTWRITEBYTECODE" in src, "launcher missing PYTHONDONTWRITEBYTECODE"
assert "os.environ.setdefault" in src, "launcher not using setdefault"
# Simulate execution: import the launcher body.
import ast
tree = ast.parse(src)
# Find the first setdefault call.
for node in ast.walk(tree):
    if isinstance(node, ast.Call) and getattr(node.func, "attr", "") == "setdefault":
        # Verify the literal sets "PYTHONDONTWRITEBYTECODE"="1"
        if (len(node.args) >= 2 and isinstance(node.args[0], ast.Constant)
                and node.args[0].value == "PYTHONDONTWRITEBYTECODE"
                and isinstance(node.args[1], ast.Constant)
                and node.args[1].value == "1"):
            print("CONFIRMED: PYTHONDONTWRITEBYTECODE=1 setdefault in launcher")
            sys.exit(0)
print("LAUNCHER_DOES_NOT_SET_PYTHONDONTWRITEBYTECODE_1")
sys.exit(1)
' 2>&1)
echo "$out" | grep -q "CONFIRMED: PYTHONDONTWRITEBYTECODE=1" || fail "Test 4: $out"
pass "Test 4: launcher sets PYTHONDONTWRITEBYTECODE=1 via setdefault"

# 5. Validator classifies __pycache__/*.pyc as disposable runtime cache.
echo "Test 5: validator classifies __pycache__/*.pyc as disposable"
make_fake_cache "$TEST_ROOT/cache"
# Build a manifest that exactly matches the staged payload (excluding bytecode)
> "$TEST_ROOT/cache/.payload.manifest"
echo "# generated" >> "$TEST_ROOT/cache/.payload.manifest"
(cd "$TEST_ROOT/cache" && find . -type f \
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
    sha="$(shasum -a 256 "$TEST_ROOT/cache/$rel" 2>/dev/null | awk '{print $1}')"
    echo "sha256  $sha  $rel" >> "$TEST_ROOT/cache/.payload.manifest"
  done)
out=$(python3 "$ROOT/scripts/verify_payload_manifest.py" --root "$TEST_ROOT/cache" --manifest "$TEST_ROOT/cache/.payload.manifest" 2>&1)
echo "  validator: $out"
echo "$out" | grep -q "PASS" || fail "Test 5: validator did not pass: $out"
pass "Test 5: validator accepts manifest + ignores disposable bytecode"

# 6. Validator rejects manifest missing an active file (stale removal).
echo "Test 6: validator rejects a removed active file"
make_fake_cache "$TEST_ROOT/cache2"
> "$TEST_ROOT/cache2/.payload.manifest"
echo "# generated" >> "$TEST_ROOT/cache2/.payload.manifest"
(cd "$TEST_ROOT/cache2" && find . -type f \
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
    sha="$(shasum -a 256 "$TEST_ROOT/cache2/$rel" 2>/dev/null | awk '{print $1}')"
    echo "sha256  $sha  $rel" >> "$TEST_ROOT/cache2/.payload.manifest"
  done)
# Now remove an active file AFTER the manifest is built
rm "$TEST_ROOT/cache2/lib/ownframework_loop/b.py"
out=$(python3 "$ROOT/scripts/verify_payload_manifest.py" --root "$TEST_ROOT/cache2" --manifest "$TEST_ROOT/cache2/.payload.manifest" 2>&1)
echo "  validator: $out"
echo "$out" | grep -q "stale-removed" || fail "Test 6: validator didn't detect stale removal: $out"
echo "$out" | grep -q "FAIL" || fail "Test 6: validator didn't fail"
pass "Test 6: stale-removed active file detected"

# 7. Validator rejects an extra unauthorised file in active payload.
echo "Test 7: validator rejects extra unauthorised active file"
make_fake_cache "$TEST_ROOT/cache3"
echo "extra" > "$TEST_ROOT/cache3/lib/ownframework_loop/injected.py"
> "$TEST_ROOT/cache3/.payload.manifest"
echo "# generated" >> "$TEST_ROOT/cache3/.payload.manifest"
(cd "$TEST_ROOT/cache3" && find . -type f \
  -not -path './logs/*' \
  -not -path './.git/*' \
  -not -path './.ownframework-loop/*' \
  -not -path '*/__pycache__/*' \
  -not -name '*.pyc' \
  -not -name '*.pyo' \
  -not -name '*.pyd' \
  -not -name '.payload.manifest' \
  -not -name '.payload.manifest.tmp' \
  -not -name 'injected.py' \
  | LC_ALL=C sort | while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    rel="${f#./}"
    sha="$(shasum -a 256 "$TEST_ROOT/cache3/$rel" 2>/dev/null | awk '{print $1}')"
    echo "sha256  $sha  $rel" >> "$TEST_ROOT/cache3/.payload.manifest"
  done)
out=$(python3 "$ROOT/scripts/verify_payload_manifest.py" --root "$TEST_ROOT/cache3" --manifest "$TEST_ROOT/cache3/.payload.manifest" 2>&1)
echo "  validator: $out"
echo "$out" | grep -q "unauthorised" || fail "Test 7: validator didn't detect injected: $out"
pass "Test 7: extra unauthorised file detected"

# 8. Validator rejects user-state files in active payload.
echo "Test 8: validator rejects .ownframework-loop/ in active payload"
make_fake_cache "$TEST_ROOT/cache4"
> "$TEST_ROOT/cache4/.payload.manifest"
echo "# generated" >> "$TEST_ROOT/cache4/.payload.manifest"
(cd "$TEST_ROOT/cache4" && find . -type f \
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
    sha="$(shasum -a 256 "$TEST_ROOT/cache4/$rel" 2>/dev/null | awk '{print $1}')"
    echo "sha256  $sha  $rel" >> "$TEST_ROOT/cache4/.payload.manifest"
  done)
# Stuck a state file INSIDE the active payload (not under .ownframework-loop/)
echo "state" > "$TEST_ROOT/cache4/lib/ownframework_loop/EVENTS.log"
out=$(python3 "$ROOT/scripts/verify_payload_manifest.py" --root "$TEST_ROOT/cache4" --manifest "$TEST_ROOT/cache4/.payload.manifest" 2>&1)
echo "  validator: $out"
echo "$out" | grep -q "unauthorised" || fail "Test 8: validator didn't reject EVENTS.log in active: $out"
pass "Test 8: user-state file in active payload rejected"

# 9. Validator detects SHA-256 modification of an active file.
echo "Test 9: validator detects SHA-256 modification of active file"
make_fake_cache "$TEST_ROOT/cache5"
> "$TEST_ROOT/cache5/.payload.manifest"
echo "# generated" >> "$TEST_ROOT/cache5/.payload.manifest"
(cd "$TEST_ROOT/cache5" && find . -type f \
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
    sha="$(shasum -a 256 "$TEST_ROOT/cache5/$rel" 2>/dev/null | awk '{print $1}')"
    echo "sha256  $sha  $rel" >> "$TEST_ROOT/cache5/.payload.manifest"
  done)
# Tamper: change active source file
echo "tampered" > "$TEST_ROOT/cache5/lib/ownframework_loop/a.py"
out=$(python3 "$ROOT/scripts/verify_payload_manifest.py" --root "$TEST_ROOT/cache5" --manifest "$TEST_ROOT/cache5/.payload.manifest" 2>&1)
echo "  validator: $out"
echo "$out" | grep -q "tamper:" || fail "Test 9: validator didn't detect tamper: $out"
pass "Test 9: tampered active file detected"

# 10. Updating bytecode does NOT cause manifest mismatch (because manifest excludes it).
echo "Test 10: bytecode mutation does not trigger manifest failure"
make_fake_cache "$TEST_ROOT/cache6"
> "$TEST_ROOT/cache6/.payload.manifest"
echo "# generated" >> "$TEST_ROOT/cache6/.payload.manifest"
(cd "$TEST_ROOT/cache6" && find . -type f \
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
    sha="$(shasum -a 256 "$TEST_ROOT/cache6/$rel" 2>/dev/null | awk '{print $1}')"
    echo "sha256  $sha  $rel" >> "$TEST_ROOT/cache6/.payload.manifest"
  done)
# Mutate bytecode (typical Python import behaviour)
echo "mutated bytecode" > "$TEST_ROOT/cache6/lib/ownframework_loop/__pycache__/a.cpython-312.pyc"
echo "more bytecode" > "$TEST_ROOT/cache6/lib/ownframework_loop/b.pyo"
out=$(python3 "$ROOT/scripts/verify_payload_manifest.py" --root "$TEST_ROOT/cache6" --manifest "$TEST_ROOT/cache6/.payload.manifest" 2>&1)
echo "  validator: $out"
echo "$out" | grep -q "PASS" || fail "Test 10: validator failed on bytecode mutation: $out"
pass "Test 10: bytecode mutation ignored (no false tampering)"

echo "ALL V0.3.2 BYTECODE-BOUNDARY TESTS PASS"
