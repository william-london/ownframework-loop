#!/usr/bin/env bash
# OwnFramework Loop — validate.
#
#   bash validate.sh                    # validate this source tree
#   bash validate.sh --installed        # validate the active managed core
#   bash validate.sh --installed <path> # validate an explicit core payload
#
# Bare --installed resolves the vendor-neutral core from the active `ofloop`
# executable and its .ownframework-loop-managed marker. Agent/plugin registries
# are adapter-specific and are never used to decide what "OwnFramework Loop is
# installed" means.
#
# All outer Python launch boundaries suppress bytecode so validation does not
# mutate the payload it is inspecting.
set -uo pipefail

INSTALLED_MODE=0
SKIP_TESTS=0
ROOT=""
EXPLICIT_INSTALL_PATH=""
for arg in "$@"; do
  case "$arg" in
    --installed)
      INSTALLED_MODE=1
      ;;
    --installed=*)
      INSTALLED_MODE=1
      EXPLICIT_INSTALL_PATH="${arg#--installed=}"
      ;;
    --skip-tests) SKIP_TESTS=1 ;;
    --help|-h)
      cat <<USAGE
Usage:
  bash validate.sh
  bash validate.sh --installed
  bash validate.sh --installed <path>
  bash validate.sh --installed=<path>

Source root : OFLOOP_VALIDATE_SOURCE_ROOT (or repo of this script)
Install root: explicit path, or the managed core resolved from `command -v ofloop`.
USAGE
      exit 0 ;;
    *)
      if [[ "$INSTALLED_MODE" -eq 1 && -z "$EXPLICIT_INSTALL_PATH" && -z "$ROOT" ]]; then
        EXPLICIT_INSTALL_PATH="$arg"
      else
        ROOT="$arg"
      fi
      ;;
  esac
done

ok() { echo "  PASS: $*"; }
bad() { echo "  FAIL: $*"; exit 1; }

# Active managed-core discovery. The PATH entry may be the canonical symlink
# created by install.sh; Path.resolve() lands inside the versioned core payload.
discover_active_install_path() {
  local launcher
  launcher="$(command -v ofloop 2>/dev/null || true)"
  [[ -n "$launcher" ]] || { echo ""; return 1; }
  PYTHONDONTWRITEBYTECODE=1 python3 -B - "$launcher" <<'PY'
import sys
from pathlib import Path
p=Path(sys.argv[1]).expanduser().resolve(strict=False)
root=p.parent.parent
marker=root/".ownframework-loop-managed"
if not marker.is_file():
    raise SystemExit(1)
text=marker.read_text(encoding="utf-8",errors="replace")
if "kind=core" not in text:
    raise SystemExit(1)
print(root)
PY
}

if [[ "$INSTALLED_MODE" -eq 1 ]]; then
  echo "=== OwnFramework Loop — validate (INSTALLED CORE) ==="
  discovered="$(discover_active_install_path || true)"
  if [[ -n "$EXPLICIT_INSTALL_PATH" ]]; then
    ROOT="$EXPLICIT_INSTALL_PATH"
    echo "  using explicit --installed path: $ROOT"
    if [[ -n "$discovered" && "$(cd "$ROOT" 2>/dev/null && pwd -P || true)" != "$(cd "$discovered" 2>/dev/null && pwd -P || true)" ]]; then
      echo "  NOTE: explicit installed path differs from active managed core"
      echo "        explicit: $ROOT"
      echo "        active:   $discovered"
    fi
  else
    [[ -n "$discovered" ]] || bad "bare --installed requested but no managed core was resolved from 'ofloop'; run bash install.sh"
    ROOT="$discovered"
    echo "  discovered active core: $ROOT"
  fi
else
  echo "=== OwnFramework Loop — validate (SOURCE TREE) ==="
  HERE="$(cd "$(dirname "$0")" && pwd)"
  : "${OFLOOP_VALIDATE_SOURCE_ROOT:=$HERE}"
  ROOT="${ROOT:-$OFLOOP_VALIDATE_SOURCE_ROOT}"
fi

if [[ ! -d "$ROOT" ]]; then
  bad "root path does not exist: $ROOT"
fi

# 1. Core version truth.
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$ROOT/lib" python3 -B - <<'PY'
import re
from ownframework_loop import __version__
m=re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", __version__)
assert m, f"core version must be semver, got {__version__!r}"
print(f"  PASS: core version valid ({__version__})")
PY

# 2. Required core/portability files.
for f in \
  bin/ofloop \
  lib/ownframework_loop/__init__.py \
  lib/ownframework_loop/cli.py \
  lib/ownframework_loop/supervisor.py \
  lib/ownframework_loop/dispatch.py \
  lib/ownframework_loop/adapters.py \
  schemas/work-packet.schema.json \
  schemas/work-packet-v3.schema.json \
  schemas/approval.schema.json \
  schemas/state.schema.json \
  schemas/state-v2.schema.json \
  schemas/build-receipt.schema.json \
  schemas/review-verdict.schema.json \
  adapters/README.md \
  adapters/generic-cli/README.md \
  docs/architecture/ADAPTER_CONTRACT.md \
  install-supervisor.sh \
  uninstall-supervisor.sh
do
  [[ -e "$ROOT/$f" ]] || bad "missing $ROOT/$f"
done
ok "vendor-neutral core and adapter contract surfaces present at $ROOT"

# 3. Installed-only checks.
if [[ "$INSTALLED_MODE" -eq 1 ]]; then
  [[ -f "$ROOT/.ownframework-loop-managed" ]] || bad "installed core marker missing"
  grep -Fq 'kind=core' "$ROOT/.ownframework-loop-managed" || bad "installed marker is not a core runtime"
  if [[ -L "$ROOT" ]]; then
    bad "versioned installed core root must be a real directory, not a symlink"
  fi
  if [[ -e "$ROOT/.git" ]]; then
    bad "installed copy contains .git/ — install.sh excludes it"
  fi

  # Payload manifest verification (atomic-install contract).
  MANIFEST="$ROOT/.payload.manifest"
  if [[ ! -f "$MANIFEST" ]]; then
    bad "installed copy is missing payload manifest at $MANIFEST — re-run install.sh"
  fi
  if ! PYTHONDONTWRITEBYTECODE=1 python3 -B "$ROOT/scripts/verify_payload_manifest.py" --root "$ROOT" --manifest "$MANIFEST"; then
    bad "payload manifest verification FAILED — installed payload has drifted from manifest"
  fi

  # v0.3.3 Repair C: structural manifest count truth.
  # Require header/file-entry count + active-file count to be reported
  # and assert equality so a partial / over-large manifest is detected.
  if ! PYTHONDONTWRITEBYTECODE=1 python3 -B "$ROOT/scripts/manifest_count_check.py" --root "$ROOT" --manifest "$MANIFEST"; then
    bad "manifest count check FAILED — manifest header or active-file count inconsistent"
  fi

  # Harmless __pycache__ directory may exist (regenerated on import); document
  # and allow. install.sh excludes it on initial copy, but validate may have
  # populated it. We do not fail here; we report.
  if [[ -d "$ROOT/lib/ownframework_loop/__pycache__" ]]; then
    echo "  NOTE: __pycache__ exists (post-import artifact, not blocked)"
  fi
  ok "installed core layout: managed real directory, no .git, manifest intact"
fi

# 4. Current machine-schema inventory is complete and every schema parses.
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$ROOT/lib" python3 -B - "$ROOT" <<'PY'
import json, sys
from pathlib import Path
from ownframework_loop import schema_validate
root = Path(sys.argv[1])
expected = set(schema_validate.CURRENT_SCHEMA_FILES)
actual = {p.name for p in (root / "schemas").glob("*.schema.json")}
if actual != expected:
    raise SystemExit("current schema inventory mismatch: " f"missing={sorted(expected-actual)} undeclared={sorted(actual-expected)}")
for name in sorted(expected):
    json.loads((root / "schemas" / name).read_text(encoding="utf-8"))
print(f"  PASS: all {len(expected)} current schemas are inventoried and parse as JSON")
PY

# 5. Python library imports.
LIB_DIR="$ROOT/lib"
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$LIB_DIR" python3 -B -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from ownframework_loop import (
    cli, packet, state, transitions, worktrees, git_checks,
    guards, receipts, verdicts, scheduling, locking, util,
    integrity, limits, program, reconcile, schema_validate,
)
print('  PASS: Python core library imports cleanly')
"

# 6. CLI runs (against this root, regardless of source/installed). Audit v0.3.0
# fixed: the previous `cmd && ok "..."` pattern silently continued past a
# non-zero exit (with `set -uo pipefail` and no `-e`, the failure was masked
# and the script eventually reported PASS).
cd "$ROOT"
if [[ "$INSTALLED_MODE" -eq 1 ]]; then
  if PYTHONDONTWRITEBYTECODE=1 python3 -B bin/ofloop --help >/dev/null 2>&1; then
    ok "installed core ofloop CLI runs (python3 bin/ofloop)"
  else
    bad "installed ofloop CLI failed (python3 bin/ofloop)"
  fi
  if PYTHONDONTWRITEBYTECODE=1 ./bin/ofloop --help >/dev/null 2>&1; then
    ok "installed ofloop CLI runs (./bin/ofloop)"
  else
    bad "installed ofloop CLI failed (./bin/ofloop)"
  fi
else
  if PYTHONDONTWRITEBYTECODE=1 python3 -B bin/ofloop --help >/dev/null 2>&1; then
    ok "source ofloop CLI runs"
  else
    bad "source ofloop CLI failed"
  fi
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
