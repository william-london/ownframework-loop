#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER="${1:-}"

if [[ "$ADAPTER" != "codex" ]]; then
  echo "Usage: bash uninstall-adapter.sh codex" >&2
  echo "Claude Code users should continue using: bash uninstall.sh" >&2
  exit 2
fi

VERSION="$(PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$ROOT/lib" python3 - <<'PY'
from ownframework_loop import __version__
print(__version__)
PY
)"
DATA_BASE="${OFLOOP_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/ownframework-loop}"
INSTALL_ROOT="$DATA_BASE/$VERSION"
BIN_DIR="${OFLOOP_BIN_DIR:-$HOME/.local/bin}"
SKILLS_ROOT="${OFLOOP_AGENT_SKILLS_DIR:-$HOME/.agents/skills}"
LAUNCHER="$BIN_DIR/ofloop"
SKILLS=(of-loop-spec of-loop-build of-loop-review of-loop-status)

for skill in "${SKILLS[@]}"; do
  dest="$SKILLS_ROOT/$skill"
  if [[ -e "$dest" ]]; then
    if [[ ! -f "$dest/.ownframework-loop-managed" ]]; then
      echo "ERROR: refusing to remove unmanaged Agent Skill: $dest" >&2
      exit 1
    fi
  fi
done

if [[ -e "$INSTALL_ROOT" && ! -f "$INSTALL_ROOT/.ownframework-loop-managed" ]]; then
  echo "ERROR: refusing to remove unmanaged install root: $INSTALL_ROOT" >&2
  exit 1
fi

for skill in "${SKILLS[@]}"; do
  dest="$SKILLS_ROOT/$skill"
  [[ -e "$dest" ]] && rm -rf "$dest"
done

if [[ -e "$LAUNCHER" ]]; then
  if grep -q 'OWNFRAMEWORK_LOOP_MANAGED_LAUNCHER' "$LAUNCHER" 2>/dev/null; then
    rm -f "$LAUNCHER"
  else
    echo "ERROR: refusing to remove unmanaged launcher: $LAUNCHER" >&2
    exit 1
  fi
fi

[[ -e "$INSTALL_ROOT" ]] && rm -rf "$INSTALL_ROOT"

cat <<EOF
ADAPTER_UNINSTALL=PASS
ADAPTER=codex
VERSION=$VERSION
EOF
