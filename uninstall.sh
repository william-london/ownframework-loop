#!/usr/bin/env bash
# Remove the current OwnFramework Loop core runtime managed by install.sh.
# Adapter installs and durable state/evidence are intentionally separate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "CORE_UNINSTALL=REFUSED reason=python3_missing" >&2; exit 2; }
VERSION="$(PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$ROOT/lib" python3 -B - <<'PY'
from ownframework_loop import __version__
print(__version__)
PY
)"
DATA_BASE="${OFLOOP_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/ownframework-loop}"
INSTALL_ROOT="$DATA_BASE/$VERSION"
BIN_DIR="${OFLOOP_BIN_DIR:-$HOME/.local/bin}"
LAUNCHER="$BIN_DIR/ofloop"
MARKER="$INSTALL_ROOT/.ownframework-loop-managed"
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/ownframework-loop"
SUPERVISOR_DB="$STATE_ROOT/supervisor.sqlite3"
LEDGER_MARKER="$STATE_ROOT/ledger-incarnation.json"

if [[ -e "$INSTALL_ROOT" && ! -f "$MARKER" ]]; then
  echo "CORE_UNINSTALL=REFUSED reason=unmanaged_install_root path=$INSTALL_ROOT" >&2
  exit 3
fi

# The ledger is an independent runtime-dependency signal even if outward
# service-manager artifacts were lost. Unknown/corrupt truth fails closed.
if [[ -f "$LEDGER_MARKER" && ! -f "$SUPERVISOR_DB" ]]; then
  echo "CORE_UNINSTALL=REFUSED reason=commissioned_ledger_missing" >&2
  exit 13
fi
if [[ -f "$SUPERVISOR_DB" && "${OFLOOP_ALLOW_SUPERVISOR_SWAP_WITH_ACTIVE_WORK:-0}" != "1" ]]; then
  set +e
  PROBE_OUT="$(PYTHONDONTWRITEBYTECODE=1 python3 -B "$ROOT/scripts/probe-supervisor-runtime-dependencies.py" "$SUPERVISOR_DB" uninstall --allow-generation-migration 2>&1)"
  PROBE_RC=$?
  set -e
  if [[ "$PROBE_RC" -ne 0 ]]; then
    echo "CORE_UNINSTALL=REFUSED $PROBE_OUT" >&2
    exit "$PROBE_RC"
  fi
fi

# Remove only an already-commissioned service; durable state/ledger/evidence are
# intentionally preserved.
if [[ -x "$ROOT/bin/uninstall-supervisor" ]]; then
  TMP_OUT="${TMPDIR:-/tmp}/ofloop-supervisor-uninstall.$$"
  if "$ROOT/bin/uninstall-supervisor" --if-commissioned >"$TMP_OUT" 2>&1; then
    cat "$TMP_OUT"
  else
    rc=$?
    cat "$TMP_OUT" >&2
    rm -f "$TMP_OUT"
    echo "CORE_UNINSTALL=REFUSED reason=supervisor_uninstall_refused" >&2
    exit "$rc"
  fi
  rm -f "$TMP_OUT"
fi

if [[ -L "$LAUNCHER" || -f "$LAUNCHER" ]]; then
  MANAGED=0
  if [[ -L "$LAUNCHER" ]]; then
    # Resolve both the symlink target and the expected core launcher
    # through the same path resolver so platform-specific normalization
    # (e.g. macOS /var -> /private/var) does not make an obviously-managed
    # launcher look unmanaged.
    TARGET="$(python3 -B - "$LAUNCHER" "$INSTALL_ROOT/bin/ofloop" <<'PY'
import sys
from pathlib import Path
print(Path(sys.argv[1]).resolve(strict=False))
print(Path(sys.argv[2]).resolve(strict=False))
PY
)"
    EXPECTED="$(printf '%s\n' "$TARGET" | tail -n1)"
    ACTUAL="$(printf '%s\n' "$TARGET" | head -n1)"
    [[ "$ACTUAL" == "$EXPECTED" ]] && MANAGED=1
  elif grep -q 'OWNFRAMEWORK_LOOP_MANAGED_LAUNCHER' "$LAUNCHER" 2>/dev/null; then
    MANAGED=1
  fi
  [[ "$MANAGED" == "1" ]] || {
    echo "CORE_UNINSTALL=REFUSED reason=unmanaged_launcher path=$LAUNCHER" >&2
    exit 3
  }
  rm -f "$LAUNCHER"
fi
[[ -e "$INSTALL_ROOT" ]] && rm -rf "$INSTALL_ROOT"

cat <<EOF
CORE_UNINSTALL=PASS
VERSION=$VERSION
CORE_ROOT=$INSTALL_ROOT
STATE_PRESERVED=yes
ADAPTERS_PRESERVED=yes
EOF
