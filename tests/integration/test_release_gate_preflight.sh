#!/usr/bin/env bash
# v0.4.0: Release-gate preflight regression test.
#
# Proves the five contracts required by the public-source release gate:
#   1. clean `master` checkout with one normal `origin` remote passes preflight;
#   2. dirty tree fails;
#   3. incorrect branch fails;
#   4. explicit expected-branch override behaves as documented;
#   5. remote presence alone does not fail.
#
# Default-behavior cases deliberately clear OFLOOP_RELEASE_GATE_EXPECTED_BRANCH
# so an outer release-gate invocation cannot contaminate the regression test.

set -euo pipefail
HERE="${OFLOOP_TEST_HERE:-$(cd "$(dirname "$0")" && pwd)}"
ROOT="${OFLOOP_TEST_ROOT:-$(cd "$HERE/../.." && pwd)}"
LIB="$ROOT/lib"
export PYTHONDONTWRITEBYTECODE=1

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d -t ofloop-preflight-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT INT TERM HUP

# Create a standalone test git repo with a remote and on master.
# We copy ONLY the runtime module so _canonical_root resolves to $SRC.
SRC="$WORK/src"
mkdir -p "$SRC/lib/ownframework_loop"
rsync -a --exclude=__pycache__ "$LIB/ownframework_loop"/ "$SRC/lib/ownframework_loop/"
git -C "$SRC" -c init.defaultBranch=master init -q
git -C "$SRC" config user.name "Test"
git -C "$SRC" config user.email "test@test.local"
# Create a "remote" bare repo to give this clone a normal origin
REMOTE="$WORK/remote.git"
git init --bare -q "$REMOTE"
git -C "$SRC" remote add origin "$REMOTE"
git -C "$SRC" add -A
git -C "$SRC" commit -q -m 'init'

# Helper: invoke _preflight from $SRC using its OWN runtime module.
# Clear any outer branch override because these cases prove the default contract.
run_preflight() {
    (cd "$SRC" && env -u OFLOOP_RELEASE_GATE_EXPECTED_BRANCH python3 -c "
import sys
sys.path.insert(0, 'lib')
from ownframework_loop.release_gate_runtime import _preflight
from pathlib import Path
ok, reason, facts = _preflight(Path('.').resolve(), check_resource_pressure=False)
print(repr((ok, reason, facts.get('remotes',''), facts.get('branch',''), facts.get('expected_branch',''), bool(facts.get('dirty')))))
")
}

# Test 1: clean master with one normal origin remote -> PASS
OUT="$(run_preflight)"
if [[ "$OUT" == "(True, '', '1', 'master', 'master', False)" ]]; then
    pass "Test 1: clean master + normal origin remote PASSES preflight"
else
    fail "Test 1: expected (True, '', '1', 'master', 'master', False), got $OUT"
fi

# Test 2: dirty tree -> FAIL
echo "scratch" > "$SRC/SCRATCH.txt"
OUT="$(run_preflight)"
rm -f "$SRC/SCRATCH.txt"
if [[ "$OUT" == "(False, 'PLUGIN_GATE_REPOSITORY_IDENTITY=FAIL', '1', 'master', 'master', True)" ]]; then
    pass "Test 2: dirty tree FAILS preflight with PLUGIN_GATE_REPOSITORY_IDENTITY=FAIL"
else
    fail "Test 2: expected (False, '...FAIL', '1', 'master', 'master', True), got $OUT"
fi

# Test 3: incorrect branch -> FAIL
git -C "$SRC" checkout -q -b not-master
OUT="$(run_preflight)"
git -C "$SRC" checkout -q master
if [[ "$OUT" == "(False, 'PLUGIN_GATE_REPOSITORY_IDENTITY=FAIL', '1', 'not-master', 'master', False)" ]]; then
    pass "Test 3: incorrect branch FAILS preflight"
else
    fail "Test 3: expected (False, '...FAIL', '1', 'not-master', 'master'), got $OUT"
fi

# Test 4: explicit override -> PASS on a different branch
git -C "$SRC" checkout -q not-master
OUT="$(cd "$SRC" && OFLOOP_RELEASE_GATE_EXPECTED_BRANCH=not-master python3 -c "
import sys
sys.path.insert(0, 'lib')
from ownframework_loop.release_gate_runtime import _preflight
from pathlib import Path
ok, reason, facts = _preflight(Path('.').resolve(), check_resource_pressure=False)
print(repr((ok, reason, facts.get('remotes',''), facts.get('branch',''), facts.get('expected_branch',''))))
")"
git -C "$SRC" checkout -q master
if [[ "$OUT" == "(True, '', '1', 'not-master', 'not-master')" ]]; then
    pass "Test 4: OFLOOP_RELEASE_GATE_EXPECTED_BRANCH override enables the named branch"
else
    fail "Test 4: expected (True, '', '1', 'not-master', 'not-master'), got $OUT"
fi

# Test 5: remote presence alone does not fail.
git -C "$SRC" remote add upstream "$REMOTE"
OUT="$(run_preflight)"
git -C "$SRC" remote remove upstream
if [[ "$OUT" == "(True, '', '2', 'master', 'master', False)" ]]; then
    pass "Test 5: multiple remotes do not fail preflight (remotes=2, ok=True)"
else
    fail "Test 5: expected (True, '', '2', 'master', 'master', False), got $OUT"
fi

if [[ "$FAIL" -ne 0 ]]; then
    echo "  RELEASE_GATE_PREFLIGHT_TESTS=FAIL ($FAIL failures)"
    exit 1
fi
echo "  RELEASE_GATE_PREFLIGHT_TESTS=PASS"
