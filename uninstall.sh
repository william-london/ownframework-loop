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

if [[ -e "$INSTALL_ROOT" && ! -f "$MARKER" ]]; then
  echo "CORE_UNINSTALL=REFUSED reason=unmanaged_install_root path=$INSTALL_ROOT" >&2
  exit 3
fi

# Remove only an already-commissioned service; durable state/ledger/evidence are
# intentionally preserved.
if [[ -x "$ROOT/uninstall-supervisor.sh" ]]; then
  TMP_OUT="${TMPDIR:-/tmp}/ofloop-supervisor-uninstall.$$"
  if "$ROOT/uninstall-supervisor.sh" --if-commissioned >"$TMP_OUT" 2>&1; then
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
    TARGET="$(python3 -B - "$LAUNCHER" <<'PY'
import sys
from pathlib import Path
print(Path(sys.argv[1]).resolve(strict=False))
PY
)"
    [[ "$TARGET" == "$INSTALL_ROOT/bin/ofloop" ]] && MANAGED=1
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
