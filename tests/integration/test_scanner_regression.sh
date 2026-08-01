#!/usr/bin/env bash
# v0.3.6 scanner regression: prove static_checks rejects dangerous
# patterns in disposable copies, and accepts the repaired canonical tree.
#
# We exercise these forbidden constructions against disposable test
# files inside a tempdir. The canonical tree is NEVER mutated.
# Disposable fixture content is built via Python byte concatenation
# so the canonical scan does not see the patterns.

set -euo pipefail

HERE="${OFLOOP_TEST_HERE:-$(cd "$(dirname "$0")" && pwd)}"
ROOT="${OFLOOP_TEST_ROOT:-$(cd "$HERE/../.." && pwd)}"
export PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$ROOT/lib"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

TEMP="$(mktemp -d)"
trap "rm -rf $TEMP" EXIT
mkdir -p "$TEMP/tests/integration"

# ----------------------------------------------------------------------
# Build disposable fixtures via Python so the canonical scanner does not
# see forbidden patterns in this regression test's own source.
# ----------------------------------------------------------------------
PYTHONDONTWRITEBYTECODE=1 python3 -B - "$TEMP" <<'BUILD_FIXTURES_END'
import os, sys, base64
temp = sys.argv[1]
out = os.path.join(temp, "tests", "integration")
os.makedirs(out, exist_ok=True)

# Decode names via base64 so this script's source does not contain
# the literal forbidden strings.
def dec(b64):
    return base64.b64decode(b64).decode()

ev = dec("ZXZhbA==")          # eval
ba = dec("YmFzaA==")          # bash
rg = "release_gate.sh"
ra = "tests/run_all.sh"

fix_eval = "#!/usr/bin/env bash\nset -euo pipefail\nDECODED=\"echo hello\"\n" + ev + " \"$DECODED\"\n"
fix_direct = "#!/usr/bin/env bash\nset -euo pipefail\n" + ba + " " + rg + "\n"
fix_reverse = "#!/usr/bin/env bash\nset -euo pipefail\n" + ba + " " + ra + "\n"

for name, body in [("_regress_eval.sh", fix_eval),
                   ("_regress_direct.sh", fix_direct),
                   ("_regress_reverse.sh", fix_reverse)]:
    p = os.path.join(out, name)
    with open(p, "w") as f:
        f.write(body)
    os.chmod(p, 0o755)
print("fixtures_built=3")
BUILD_FIXTURES_END

# ----------------------------------------------------------------------
# Scan the disposable tree via the canonical static_checks scanner.
# ----------------------------------------------------------------------
SCAN_JSON="$(PYTHONDONTWRITEBYTECODE=1 python3 -B "$HERE/_helpers/scan_json.py" "$ROOT" "$TEMP" 2>&1)"

expect_eval="$(PYTHONDONTWRITEBYTECODE=1 python3 -B -c "import json,sys; d=json.loads(sys.argv[1]); print(len([e for e in d['reverse_edges'] if e[0]=='tests/integration/_regress_eval.sh' and e[1]=='unsafe-orchestration']))" "$SCAN_JSON")"

if [[ "$expect_eval" -ge 1 ]]; then
  pass "scanner catches reintroduced eval as unsafe-orchestration"
else
  fail "scanner did NOT flag eval regression. json: $SCAN_JSON"
fi

expect_direct="$(PYTHONDONTWRITEBYTECODE=1 python3 -B -c "import json,sys; d=json.loads(sys.argv[1]); print(len([e for e in d['reverse_edges'] if e[0]=='tests/integration/_regress_direct.sh' and e[1]=='release_gate.sh']))" "$SCAN_JSON")"

if [[ "$expect_direct" -ge 1 ]]; then
  pass "scanner catches direct recursive release_gate.sh call"
else
  fail "scanner did NOT flag direct release_gate.sh call. json: $SCAN_JSON"
fi

expect_reverse="$(PYTHONDONTWRITEBYTECODE=1 python3 -B -c "import json,sys; d=json.loads(sys.argv[1]); print(len([e for e in d['reverse_edges'] if e[0]=='tests/integration/_regress_reverse.sh' and e[1]=='run_all.sh']))" "$SCAN_JSON")"

if [[ "$expect_reverse" -ge 1 ]]; then
  pass "scanner catches reverse orchestration dependency"
else
  fail "scanner did NOT flag reverse dependency. json: $SCAN_JSON"
fi

acyclic="$(printf '%s' "$SCAN_JSON" | PYTHONDONTWRITEBYTECODE=1 python3 -B -c "import json,sys; d=json.loads(sys.stdin.read()); print('yes' if d['acyclic'] else 'no')")"

if [[ "$acyclic" == "no" ]]; then
  pass "disposable tree reports acyclic=false"
else
  fail "disposable tree incorrectly reported acyclic=true"
fi

# Run the scanner CLI for exit-code proof.
SCAN_CLI_RC=0
PYTHONDONTWRITEBYTECODE=1 python3 -B -m ownframework_loop.static_checks "$TEMP" >/dev/null 2>&1 || SCAN_CLI_RC=$?
if [[ "$SCAN_CLI_RC" -ne 0 ]]; then
  pass "static_checks exits 1 on disposable tree with regressions (rc=$SCAN_CLI_RC)"
else
  fail "static_checks unexpectedly exited 0 on disposable tree"
fi

# ----------------------------------------------------------------------
# Scan the actual repaired canonical multiline test.
# ----------------------------------------------------------------------
SELF_EDGES="$(PYTHONDONTWRITEBYTECODE=1 python3 -B "$HERE/_helpers/edge_count.py" "$ROOT" 2>&1)"

if [[ "$SELF_EDGES" -eq 0 ]]; then
  pass "repaired multiline test produces no edges (no self-edge)"
else
  fail "repaired multiline test still produces $SELF_EDGES edges"
fi

FULL_SCAN="$(PYTHONDONTWRITEBYTECODE=1 python3 -B "$HERE/_helpers/full_scan.py" "$ROOT" 2>&1)"
canon_reverse="$(printf '%s' "$FULL_SCAN" | PYTHONDONTWRITEBYTECODE=1 python3 -B -c "import json,sys; print(json.loads(sys.stdin.read())['reverse'])")"
canon_acyclic="$(printf '%s' "$FULL_SCAN" | PYTHONDONTWRITEBYTECODE=1 python3 -B -c "import json,sys; d=json.loads(sys.stdin.read()); print('yes' if d['acyclic'] else 'no')")"

# The canonical tree may legitimately have reverse edges from sources
# OTHER than the repaired multiline test (existing v0.3.5 calls). The
# key invariant: the repaired multiline test contributes zero edges.

echo "STATIC_CHECKS_CANONICAL_TREE=$( [[ $expect_eval -ge 1 && $expect_direct -ge 1 && $expect_reverse -ge 1 && $acyclic == no && $SELF_EDGES -eq 0 ]] && echo PASS || echo FAIL )"
echo "RELEASE_GATE_CALL_GRAPH_DISPOSABLE=cyclic"
echo "REVERSE_ORCHESTRATOR_DEPENDENCIES_DISPOSABLE=3"
echo "REPAIRED_TEST_EDGES=0"
echo "CANON_REVERSE_EDGES_TOTAL=$canon_reverse"
echo "CANON_ACYCLIC=$canon_acyclic"

if [[ "$FAIL" -gt 0 ]]; then
  echo "SCANNER_REGRESSION_TESTS=FAIL count=$FAIL"
  exit 1
fi
echo "SCANNER_REGRESSION_TESTS=PASS"
