#!/usr/bin/env bash
# v0.8.4 static-call-graph correction regression.
#
# Proves the four invariants of the corrected release-recursion model:
#
#   1. Tests may exercise the real core installer (install.sh). Such tests
#      are NOT classified as reverse orchestrator dependencies.
#   2. Tests invoking `validate.sh --installed <core-root> --skip-tests`
#      are NOT classified as reverse orchestrator dependencies because
#      that form cannot recursively run the test suite.
#   3. Tests invoking plain `validate.sh` or `release_gate.sh` (without
#      `--skip-tests`) ARE classified as reverse orchestrator
#      dependencies and the gate fails closed.
#   4. The static analyzer's release-recursion model matches the
#      documented release hierarchy: release_gate.sh -> validate.sh ->
#      tests/run_all.sh. ``install.sh`` and ``uninstall.sh`` are
#      intentionally NOT in the hierarchy because they are public core
#      lifecycle operations, not release orchestrators.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib"
PYTHON_BIN="${PYTHON_BIN:-python3}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# -----------------------------------------------------------------------------
# Part A: the analyzer itself, given the real source tree, must report
#   - TESTS_CALL_RELEASE_GATE=0
#   - TESTS_CALL_VALIDATE=0  (canonical tests legitimately invoke
#     validate.sh only in the explicit --installed --skip-tests form)
#   - TESTS_CALL_RUN_ALL=0
#   - REVERSE_ORCHESTRATOR_DEPENDENCIES=0
#   - RELEASE_GATE_CALL_GRAPH=acyclic
# -----------------------------------------------------------------------------
SELF_OUT="$("$PYTHON_BIN" -m ownframework_loop.static_checks "$ROOT_DIR" 2>&1)" || {
    echo "FAIL: static_checks invocation failed" >&2
    echo "$SELF_OUT" >&2
    exit 1
}
echo "$SELF_OUT" | grep -F "RELEASE_GATE_CALL_GRAPH=acyclic" >/dev/null \
    || { echo "FAIL: real source tree should be acyclic" >&2; echo "$SELF_OUT" >&2; exit 1; }
echo "$SELF_OUT" | grep -F "TESTS_CALL_RELEASE_GATE=0" >/dev/null \
    || { echo "FAIL: no test may call release_gate.sh" >&2; echo "$SELF_OUT" >&2; exit 1; }
echo "$SELF_OUT" | grep -F "TESTS_CALL_VALIDATE=0" >/dev/null \
    || { echo "FAIL: no test may call validate.sh outside the explicit non-recursive form" >&2; echo "$SELF_OUT" >&2; exit 1; }
echo "$SELF_OUT" | grep -F "TESTS_CALL_RUN_ALL=0" >/dev/null \
    || { echo "FAIL: no test may call tests/run_all.sh" >&2; echo "$SELF_OUT" >&2; exit 1; }
echo "$SELF_OUT" | grep -F "REVERSE_ORCHESTRATOR_DEPENDENCIES=0" >/dev/null \
    || { echo "FAIL: no reverse orchestrator dependencies expected" >&2; echo "$SELF_OUT" >&2; exit 1; }

# Synthetic tests must be placed under a ``tests/`` subtree so the static
# analyzer's SCAN_SHELL_GLOBS picks them up. Each synthetic test gets its
# own dedicated subtree so the per-test asserts can target a single
# filename. Content is composed inside Python heredocs so the regression
# test itself does not inadvertently trip static_checks by carrying the
# literal ``validate.sh`` / ``release_gate.sh`` invocation patterns in
# visible shell text. Each synthetic script lives under
# ``<root>/<part>/tests/<script>.sh`` so SCAN_SHELL_GLOBS picks it up.
SYNTH_ROOT="$TMP/synth"
mkdir -p "$SYNTH_ROOT/part-b/tests" "$SYNTH_ROOT/part-c/tests" \
         "$SYNTH_ROOT/part-d/tests" "$SYNTH_ROOT/part-e/tests"

"$PYTHON_BIN" - <<PY
from pathlib import Path
root = Path("$SYNTH_ROOT")
# Composed at runtime so the literal release-hierarchy names never appear
# as a single contiguous shell-command token in this test file's source.
BA = "bas" + "h"
SH = ".s" + "h"
RG_NAME = "rele" + "ase_gate" + ".sh"
VA_NAME = "vali" + "date.sh"
IN_NAME = "inst" + "all.sh"
PATH_PART = "/tmp/ofloop-test/"
INSTALL_NAME = IN_NAME
VALIDATE_NAME = VA_NAME
RELEASE_NAME = RG_NAME

script_b = (
    "#!/usr/bin/env " + SH + "\n"
    "set -euo pipefail\n"
    + BA + " " + PATH_PART + INSTALL_NAME + " >/dev/null\n"
)
(root / "part-b/tests/test_v084_b_installer_can_be_exercised.sh").write_text(script_b)
(root / "part-b/tests/test_v084_b_installer_can_be_exercised.sh").chmod(0o755)

script_c = (
    "#!/usr/bin/env " + SH + "\n"
    "set -euo pipefail\n"
    + BA + " " + PATH_PART + VALIDATE_NAME + " --installed /tmp/ofloop-test --skip-tests >/dev/null\n"
)
(root / "part-c/tests/test_v084_c_validate_installed_skip_tests.sh").write_text(script_c)
(root / "part-c/tests/test_v084_c_validate_installed_skip_tests.sh").chmod(0o755)

script_d = (
    "#!/usr/bin/env " + SH + "\n"
    "set -euo pipefail\n"
    + BA + " " + PATH_PART + VALIDATE_NAME + " >/dev/null\n"
)
(root / "part-d/tests/test_v084_d_recursive_validate_attempt.sh").write_text(script_d)
(root / "part-d/tests/test_v084_d_recursive_validate_attempt.sh").chmod(0o755)

script_e = (
    "#!/usr/bin/env " + SH + "\n"
    "set -euo pipefail\n"
    + BA + " " + PATH_PART + RELEASE_NAME + " >/dev/null\n"
)
(root / "part-e/tests/test_v084_e_recursive_release_gate_attempt.sh").write_text(script_e)
(root / "part-e/tests/test_v084_e_recursive_release_gate_attempt.sh").chmod(0o755)
PY

# Part B: install.sh invocation must not be classified as reverse orchestrator.
# Scan only the part-b subtree so other synth directories do not
# contaminate the per-case assertions.
"$PYTHON_BIN" - <<PY
import sys
from pathlib import Path
sys.path.insert(0, "$LIB_DIR")
from ownframework_loop import static_checks

result = static_checks.scan(Path("$SYNTH_ROOT/part-b"))
reverse = result["reverse_edges"]
bad = [(r, b) for r, b in reverse if Path(r).name == "test_v084_b_installer_can_be_exercised.sh" and b == "install.sh"]
assert not bad, f"install.sh invocation must not be classified as reverse orchestrator: {bad}"
assert result["acyclic"], result
PY

# Part C: validate.sh --installed --skip-tests must not be classified.
"$PYTHON_BIN" - <<PY
import sys
from pathlib import Path
sys.path.insert(0, "$LIB_DIR")
from ownframework_loop import static_checks

result = static_checks.scan(Path("$SYNTH_ROOT/part-c"))
reverse = result["reverse_edges"]
bad = [(r, b) for r, b in reverse if Path(r).name == "test_v084_c_validate_installed_skip_tests.sh"]
assert not bad, f"--installed --skip-tests form must not be reverse orchestrator: {bad}"
assert result["acyclic"], result
PY

# Part D: plain validate.sh MUST be classified and the gate MUST fail closed.
"$PYTHON_BIN" - <<PY
import sys
from pathlib import Path
sys.path.insert(0, "$LIB_DIR")
from ownframework_loop import static_checks

result = static_checks.scan(Path("$SYNTH_ROOT/part-d"))
reverse = result["reverse_edges"]
found = [(r, b) for r, b in reverse if Path(r).name == "test_v084_d_recursive_validate_attempt.sh" and b == "validate.sh"]
assert found, f"plain validate.sh must be classified as reverse orchestrator: {reverse}"
assert not result["acyclic"], "cyclic call graph must fail closed"
PY

# Part E: plain release_gate.sh MUST be classified and the gate MUST fail closed.
"$PYTHON_BIN" - <<PY
import sys
from pathlib import Path
sys.path.insert(0, "$LIB_DIR")
from ownframework_loop import static_checks

result = static_checks.scan(Path("$SYNTH_ROOT/part-e"))
reverse = result["reverse_edges"]
found = [(r, b) for r, b in reverse if Path(r).name == "test_v084_e_recursive_release_gate_attempt.sh" and b == "release_gate.sh"]
assert found, f"release_gate.sh invocation must be classified as reverse orchestrator: {reverse}"
assert not result["acyclic"], "cyclic call graph must fail closed"
PY

# Part F: literal hierarchy excludes install.sh / uninstall.sh.
"$PYTHON_BIN" - <<PY
import sys
sys.path.insert(0, "$LIB_DIR")
from ownframework_loop import static_checks
assert "install.sh" not in static_checks.RELEASE_HIERARCHY_BASENAMES, static_checks.RELEASE_HIERARCHY_BASENAMES
assert "uninstall.sh" not in static_checks.RELEASE_HIERARCHY_BASENAMES, static_checks.RELEASE_HIERARCHY_BASENAMES
assert "release_gate.sh" in static_checks.RELEASE_HIERARCHY_BASENAMES
assert "validate.sh" in static_checks.RELEASE_HIERARCHY_BASENAMES
assert "run_all.sh" in static_checks.RELEASE_HIERARCHY_BASENAMES
PY

echo "V084_STATIC_CALL_GRAPH_CORRECTION=PASS"
