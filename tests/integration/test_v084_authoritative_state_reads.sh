#!/usr/bin/env bash
# v0.8.4 authority regression: semantic/execution decisions must not consume
# raw STATE.json bytes once a run has integrity evidence.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib"

python3 -B - "$ROOT_DIR" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
critical = [
    "lib/ownframework_loop/dispatch.py",
    "lib/ownframework_loop/build_prepare.py",
    "lib/ownframework_loop/review_prepare.py",
    "lib/ownframework_loop/branch_resolver.py",
    "lib/ownframework_loop/build_agent.py",
    "lib/ownframework_loop/assessment.py",
    "lib/ownframework_loop/program.py",
    "lib/ownframework_loop/build_finalize.py",
    "lib/ownframework_loop/review_finalize.py",
    "lib/ownframework_loop/execution_start.py",
]
for rel in critical:
    text = (root / rel).read_text(encoding="utf-8")
    assert "state_mod.load(" not in text, f"raw authoritative state read remains: {rel}"
print("V084_AUTHORITATIVE_STATE_READS=PASS")
PY

pass "critical semantic/execution paths use verified state reads"
echo "V084_AUTHORITATIVE_STATE_READS=PASS"
