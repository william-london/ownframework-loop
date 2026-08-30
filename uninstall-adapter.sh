#!/usr/bin/env bash
# Remove one optional OwnFramework Loop host adapter. Core runtime is preserved.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER="${1:-}"
case "$ADAPTER" in
  claude-code|codex) ;;
  *)
    echo "ADAPTER_UNINSTALL=REFUSED reason=unknown_adapter adapter=$ADAPTER" >&2
    echo "Usage: bash uninstall-adapter.sh {claude-code|codex}" >&2
    exit 2
    ;;
esac

VERSION="$(PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$ROOT/lib" python3 -B - <<'PY'
from ownframework_loop import __version__
print(__version__)
PY
)"

if [[ "$ADAPTER" == "claude-code" ]]; then
  command -v claude >/dev/null 2>&1 || {
    echo "ADAPTER_UNINSTALL=REFUSED reason=claude_cli_missing" >&2
    exit 3
  }
  SCOPE="${SCOPE:-user}"
  PLUGIN_ID="${PLUGIN_ID:-of-loop@ownframework}"
  MARKETPLACE_NAME="${MARKETPLACE_NAME:-ownframework}"
  claude plugin uninstall "$PLUGIN_ID" --scope "$SCOPE" >/dev/null 2>&1 || true
  if [[ "${REMOVE_MARKETPLACE:-0}" == "1" ]]; then
    claude plugin marketplace remove "$MARKETPLACE_NAME" >/dev/null 2>&1 || true
  fi
  cat <<EOF
ADAPTER_UNINSTALL=PASS
ADAPTER=claude-code
VERSION=$VERSION
CORE_PRESERVED=yes
EOF
  exit 0
fi

SKILLS_ROOT="${OFLOOP_AGENT_SKILLS_DIR:-$HOME/.agents/skills}"
SKILLS=(of-loop-spec of-loop-build of-loop-review of-loop-status)
for skill in "${SKILLS[@]}"; do
  dest="$SKILLS_ROOT/$skill"
  if [[ -e "$dest" && ! -f "$dest/.ownframework-loop-managed" ]]; then
    echo "ADAPTER_UNINSTALL=REFUSED reason=unmanaged_agent_skill path=$dest" >&2
    exit 3
  fi
done
for skill in "${SKILLS[@]}"; do
  dest="$SKILLS_ROOT/$skill"
  [[ -e "$dest" ]] && rm -rf "$dest"
done

cat <<EOF
ADAPTER_UNINSTALL=PASS
ADAPTER=codex
VERSION=$VERSION
CORE_PRESERVED=yes
EOF
