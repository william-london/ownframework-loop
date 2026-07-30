#!/usr/bin/env bash
# OwnFramework Loop V2 — validate.
#
# Two distinct code paths:
#
#   bash validate.sh                   # validate the source tree at <repo>
#   bash validate.sh --installed       # validate the installed copy at the
#                                       # actual install root (the copy you
#                                       # get from install.sh)
#
# Both paths verify structural integrity: required files present, plugin.json
# parses, schemas parse, Python module imports, CLI runs, hook scripts are
# executable, all unit tests pass. The --installed path additionally verifies
# the install root is a copy (not a symlink), that there is no .git/ directory
# inside it, and that the CLI invoked through the installed paths actually
# works end-to-end.
#
# Honor:
#   OFLOOP_VALIDATE_SOURCE_ROOT  - default source root (when not passing as arg)
#   OFLOOP_VALIDATE_INSTALL_ROOT - default installed root for --installed

set -uo pipefail

INSTALLED_MODE=0
SKIP_TESTS=0
ROOT=""
for arg in "$@"; do
  case "$arg" in
    --installed) INSTALLED_MODE=1 ;;
    --installed=*) INSTALLED_MODE=1 ;;
    --skip-tests) SKIP_TESTS=1 ;;
    --help|-h)
      cat <<USAGE
Usage:
  bash validate.sh                    # validate the SOURCE tree
  bash validate.sh --installed        # validate the INSTALLED copy

Source root : OFLOOP_VALIDATE_SOURCE_ROOT (or repo of this script)
Install root: OFLOOP_VALIDATE_INSTALL_ROOT (or \$HOME/.claude/skills/of-loop)
USAGE
      exit 0 ;;
    *) ROOT="$arg" ;;
  esac
done

ok() { echo "  PASS: $*"; }
bad() { echo "  FAIL: $*"; exit 1; }

if [[ "$INSTALLED_MODE" -eq 1 ]]; then
  echo "=== OwnFramework Loop V2 — validate (INSTALLED COPY) ==="
  : "${OFLOOP_VALIDATE_INSTALL_ROOT:=$HOME/.claude/skills/of-loop}"
  DEFAULT_ROOT="$OFLOOP_VALIDATE_INSTALL_ROOT"
  ROOT="${ROOT:-$DEFAULT_ROOT}"
else
  echo "=== OwnFramework Loop V2 — validate (SOURCE TREE) ==="
  HERE="$(cd "$(dirname "$0")" && pwd)"
  : "${OFLOOP_VALIDATE_SOURCE_ROOT:=$HERE}"
  ROOT="${ROOT:-$OFLOOP_VALIDATE_SOURCE_ROOT}"
fi

if [[ ! -d "$ROOT" ]]; then
  bad "root path does not exist: $ROOT"
fi

# 1. Plugin manifest.
python3 - "$ROOT" <<'PY'
import json, sys
root = sys.argv[1]
data = json.load(open(f"{root}/.claude-plugin/plugin.json"))
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
  lib/ownframework_loop/limits.py \
  lib/ownframework_loop/integrity.py \
  schemas/work-packet.schema.json \
  schemas/state.schema.json \
  schemas/build-receipt.schema.json \
  schemas/review-verdict.schema.json
do
  [[ -e "$ROOT/$f" ]] || bad "missing $ROOT/$f"
done
ok "all required files present at $ROOT"

# 3. Installed-only checks.
if [[ "$INSTALLED_MODE" -eq 1 ]]; then
  if [[ -L "$ROOT" ]]; then
    bad "installed copy is a symlink — install.sh produces a COPY"
  fi
  if [[ -e "$ROOT/.git" ]]; then
    bad "installed copy contains .git/ — install.sh excludes it"
  fi
  # Harmless __pycache__ directory may exist (regenerated on import); document
  # and allow. install.sh excludes it on initial copy, but validate may have
  # populated it. We do not fail here; we report.
  if [[ -d "$ROOT/lib/ownframework_loop/__pycache__" ]]; then
    echo "  NOTE: __pycache__ exists (post-import artifact, not blocked)"
  fi
  ok "installed copy layout: not a symlink, no .git, structures intact"
fi

# 4. JSON schemas parse.
python3 - "$ROOT" <<'PY'
import json, sys
root = sys.argv[1]
for s in ["work-packet.schema.json", "state.schema.json", "build-receipt.schema.json", "review-verdict.schema.json"]:
    json.load(open(f"{root}/schemas/{s}"))
print("  PASS: all 4 schemas parse as JSON")
PY

# 5. Python library imports.
LIB_DIR="$ROOT/lib"
PYTHONPATH="$LIB_DIR" python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from ownframework_loop import (
    cli, packet, state, transitions, worktrees, git_checks,
    guards, receipts, verdicts, scheduling, locking, util,
    integrity, limits,
)
print('  PASS: Python core library imports cleanly')
"

# 6. CLI runs (against this root, regardless of source/installed).
cd "$ROOT"
if [[ "$INSTALLED_MODE" -eq 1 ]]; then
  # Installed copy: invoke via the install's CLI path.
  python3 bin/ofloop --help >/dev/null && ok "installed ofloop CLI runs (python3 bin/ofloop)"
  ./bin/ofloop --help >/dev/null && ok "installed ofloop CLI runs (./bin/ofloop)"
else
  python3 bin/ofloop --help >/dev/null && ok "source ofloop CLI runs"
fi

# 7. Hook scripts are executable.
for h in block_dangerous_bash.sh block_protected_paths.sh post_bash_secret_scan.sh; do
  [[ -x "$ROOT/hooks/$h" ]] || bad "$h not executable"
done
ok "hook scripts are executable"

# 8. Deterministic unit tests. The top-level release gate runs the source
# suite once; installed-copy validation is structural-only when requested.
TEST_RC=0
if [[ "$SKIP_TESTS" -eq 1 ]]; then
  ok "deterministic unit tests skipped by explicit structural validation mode"
else
  echo "  running unit tests..."
  bash "$ROOT/tests/run_all.sh" || TEST_RC=$?
fi

# Propagate run_all.sh's exit code. run_all.sh already prints
# OF_LOOP_TOTAL / OF_LOOP_PASSED / OF_LOOP_FAILED / OF_LOOP_RELEASE_GATE_RESULT;
# validate.sh must NOT paper over a failing test suite with a PASS line.
if [[ "$TEST_RC" -ne 0 ]]; then
  bad "test suite reported failures; refusing to validate"
fi

ok "all checks PASS for $ROOT"
exit 0
