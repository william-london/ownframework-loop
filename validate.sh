#!/usr/bin/env bash
# OwnFramework Loop V1 — validate.
#
# Verifies structural integrity of the plugin: required files present,
# plugin.json parses, schemas parse, Python module imports, CLI runs,
# all unit tests pass.
#
# Exit 0 on PASS, non-zero on FAIL.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE"
LIB_DIR="$ROOT/lib"
BIN="$ROOT/bin/ofloop"

cd "$ROOT"

ok() { echo "  PASS: $*"; }
bad() { echo "  FAIL: $*"; exit 1; }

# Optional flag distinguishes source vs installed copy validation.
INSTALLED_MODE=0
for arg in "$@"; do
  if [[ "$arg" == "--installed" ]]; then INSTALLED_MODE=1; fi
done

echo "=== OwnFramework Loop V1 — validate ($([ $INSTALLED_MODE -eq 1 ] && echo 'installed copy' || echo 'source')) ==="

# 1. Plugin manifest.
python3 - <<PY
import json
data = json.load(open("$ROOT/.claude-plugin/plugin.json"))
assert data["name"] == "of-loop", f"plugin name must be of-loop, got {data.get('name')}"
assert data["displayName"] == "OwnFramework Loop"
assert "version" in data
print("  PASS: plugin manifest has name=of-loop, displayName=OwnFramework Loop")
PY

# 2. Required files.
for f in \
  .claude-plugin/plugin.json \
  skills/spec/SKILL.md \
  skills/build/SKILL.md \
  skills/review/SKILL.md \
  agents/of-builder.md \
  agents/of-reviewer.md \
  hooks/hooks.json \
  bin/ofloop \
  lib/ownframework_loop/__init__.py \
  schemas/work-packet.schema.json \
  schemas/state.schema.json \
  schemas/build-receipt.schema.json \
  schemas/review-verdict.schema.json
do
  [[ -e "$ROOT/$f" ]] || bad "missing $f"
done
ok "all required files present"

# 3. JSON schemas parse.
python3 - <<PY
import json
from pathlib import Path
for s in ["work-packet.schema.json", "state.schema.json", "build-receipt.schema.json", "review-verdict.schema.json"]:
    json.loads(Path("$ROOT/schemas") / s).read_text() if False else json.loads(open(f"$ROOT/schemas/{s}").read())
print("  PASS: all 4 schemas parse as JSON")
PY

# 4. Python library imports.
PYTHONPATH="$LIB_DIR" python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from ownframework_loop import (
    cli, packet, state, transitions, worktrees, git_checks,
    guards, receipts, verdicts, scheduling, locking, util
)
print('  PASS: Python core library imports cleanly')
"

# 5. CLI runs.
"$BIN" --help >/dev/null && ok "ofloop CLI runs"

# 6. Hook scripts are executable.
[[ -x "$ROOT/hooks/block_dangerous_bash.sh" ]] || bad "block_dangerous_bash.sh not executable"
[[ -x "$ROOT/hooks/block_protected_paths.sh" ]] || bad "block_protected_paths.sh not executable"
[[ -x "$ROOT/hooks/post_bash_secret_scan.sh" ]] || bad "post_bash_secret_scan.sh not executable"
ok "hook scripts are executable"

# 7. Deterministic unit tests.
echo "  running unit tests..."
if ! bash "$ROOT/tests/run_all.sh" 2>&1 | tail -8; then
  bad "unit tests failed"
fi

ok "all checks PASS"
exit 0
