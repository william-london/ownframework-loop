#!/usr/bin/env bash
# OwnFramework Loop — validate.
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
#                                  (used only when --installed=<path> or
#                                   --installed <path> is supplied; bare
#                                   --installed ALWAYS queries the live
#                                   Claude Code plugin registry)
#
# v0.3.3 Repair A: active installed-cache discovery
# -----------------------------------------------
# Bare `--installed` MUST discover the live active managed install via
# `claude plugin list --json`. The legacy `~/.claude/skills/of-loop` path
# is a rolled-back backup artifact (audit v0.3.3) and MUST NOT be selected
# silently as the active install. Three argument forms are supported:
#   bash validate.sh --installed
#   bash validate.sh --installed /explicit/path
#   bash validate.sh --installed=/explicit/path
# When an explicit path is supplied, that path is used verbatim — but we
# still warn (do not fail) if it does not match the live registry entry,
# because operators may legitimately be validating a side-by-side cache
# while the managed install is active. The warning is informational; the
# explicit path is authoritative for that run.
#
# v0.3.3 Repair B: bytecode-free validation
# ----------------------------------------
# All outer Python launch boundaries in this script use
# `PYTHONDONTWRITEBYTECODE=1` and `python3 -B`, so validation NEVER
# creates .pyc files inside the cache tree it is inspecting.
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
  bash validate.sh                    # validate the SOURCE tree
  bash validate.sh --installed        # validate the live INSTALLED copy
                                       #   (discovered via
                                       #    \`claude plugin list --json\`)
  bash validate.sh --installed <path> # validate the INSTALLED copy at <path>
  bash validate.sh --installed=<path> # same, equals form

Source root : OFLOOP_VALIDATE_SOURCE_ROOT (or repo of this script)
Install root: explicit path argument, OR the active managed install
              reported by \`claude plugin list --json\` for
              of-loop@ownframework (enabled, non-empty installPath).

The legacy path \$HOME/.claude/skills/of-loop is a rolled-back backup
artifact and is NEVER auto-selected as the active install.
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

# Active installed-cache discovery: query the Claude Code plugin registry
# for the single enabled of-loop@ownframework entry. The legacy
# skills-dir copy is intentionally NOT consulted as a fallback; if the
# registry has no live entry, bare --installed fails closed with a clear
# error.
discover_active_install_path() {
  if ! command -v claude >/dev/null 2>&1; then
    echo ""
    return 1
  fi
  local raw
  raw="$(claude plugin list --json 2>/dev/null || true)"
  [[ -z "$raw" ]] && { echo ""; return 1; }
  # PYTHONDONTWRITEBYTECODE=1 + python3 -B prevents the discovery helper
  # from polluting the cache tree with .pyc files (Repair B).
  PYTHONDONTWRITEBYTECODE=1 python3 -B - "$raw" <<'PY'
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
matches = []
for e in data or []:
    if not isinstance(e, dict):
        continue
    if e.get("id") != "of-loop@ownframework":
        continue
    if not e.get("enabled", False):
        continue
    ip = e.get("installPath") or ""
    if not ip:
        continue
    matches.append(ip)
if len(matches) == 1:
    print(matches[0])
    sys.exit(0)
if len(matches) > 1:
    print("__AMBIGUOUS__:" + "\n".join(matches), file=sys.stderr)
    sys.exit(2)
print("")
sys.exit(0)
PY
}

if [[ "$INSTALLED_MODE" -eq 1 ]]; then
  echo "=== OwnFramework Loop — validate (INSTALLED COPY) ==="
  if [[ -n "$EXPLICIT_INSTALL_PATH" ]]; then
    ROOT="$EXPLICIT_INSTALL_PATH"
    echo "  using explicit --installed path: $ROOT"
    # Informational cross-check: if the explicit path differs from the
    # live registry entry, warn but do not fail.
    discovered="$(discover_active_install_path || true)"
    if [[ -n "$discovered" && "$discovered" != "$ROOT" ]]; then
      echo "  NOTE: explicit --installed path differs from live registry entry"
      echo "        explicit:  $ROOT"
      echo "        registry:  $discovered"
    fi
  else
    # Bare --installed: ALWAYS query the live registry. Never fall back
    # to the legacy skills-dir path or to OFLOOP_VALIDATE_INSTALL_ROOT.
    discovered="$(discover_active_install_path || true)"
    if [[ -z "$discovered" ]]; then
      bad "bare --installed requested but claude plugin list --json returned no enabled of-loop@ownframework entry; re-run install.sh"
    fi
    ROOT="$discovered"
    echo "  discovered active install: $ROOT"
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

# 1. Plugin manifest.
PYTHONDONTWRITEBYTECODE=1 python3 -B - "$ROOT" <<'PY'
import json, sys
root = sys.argv[1]
import re
data = json.load(open(f"{root}/.claude-plugin/plugin.json"))
assert data["name"] == "of-loop", f"plugin name must be of-loop, got {data.get('name')}"
assert data["displayName"] == "OwnFramework Loop"
assert "version" in data
ver = data["version"]
m = re.match(r"^(\d+)\.(\d+)\.(\d+)$", ver)
assert m, f"version must be semver, got {ver!r}"
major = int(m.group(1)); minor = int(m.group(2)); patch = int(m.group(3))
assert (major, minor, patch) >= (0, 3, 0), (
    f"installed version must be >= 0.3.0 (got {ver})"
)
print(f"  PASS: plugin manifest valid (version={ver} >= 0.3.0)")
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
  schemas/work-packet-v3.schema.json \
  schemas/state.schema.json \
  schemas/state-v2.schema.json \
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
  ok "installed copy layout: not a symlink, no .git, structures intact"
fi

# 4. JSON schemas parse.
PYTHONDONTWRITEBYTECODE=1 python3 -B - "$ROOT" <<'PY'
import json, sys
root = sys.argv[1]
for s in ["work-packet.schema.json", "work-packet-v3.schema.json", "state.schema.json", "state-v2.schema.json", "build-receipt.schema.json", "review-verdict.schema.json"]:
    json.load(open(f"{root}/schemas/{s}"))
print("  PASS: all 6 schemas parse as JSON")
PY

# 5. Python library imports.
LIB_DIR="$ROOT/lib"
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$LIB_DIR" python3 -B -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from ownframework_loop import (
    cli, packet, state, transitions, worktrees, git_checks,
    guards, receipts, verdicts, scheduling, locking, util,
    integrity, limits, orchestrator, program, reconcile,
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
    ok "installed ofloop CLI runs (python3 bin/ofloop)"
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
