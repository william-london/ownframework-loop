#!/usr/bin/env bash
# Install one optional OwnFramework Loop agent-host adapter.
# Core runtime ownership remains with install.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER="${1:-}"
case "$ADAPTER" in
  claude-code|codex) ;;
  *)
    echo "ADAPTER_INSTALL=REFUSED reason=unknown_adapter adapter=$ADAPTER" >&2
    echo "Usage: bash install-adapter.sh {claude-code|codex}" >&2
    exit 2
    ;;
esac

# One canonical core install, independent of adapter host. Adapter installation
# is allowed to ensure it exists because the operation is idempotent.
CORE_OUT="$(OFLOOP_SKIP_SUPERVISOR_REFRESH="${OFLOOP_SKIP_SUPERVISOR_REFRESH:-0}" bash "$ROOT/install.sh")"
printf '%s\n' "$CORE_OUT"
CORE_ROOT="$(printf '%s\n' "$CORE_OUT" | sed -n 's/^CORE_ROOT=//p' | tail -n1)"
VERSION="$(printf '%s\n' "$CORE_OUT" | sed -n 's/^VERSION=//p' | tail -n1)"
[[ -n "$CORE_ROOT" && -n "$VERSION" ]] || {
  echo "ADAPTER_INSTALL=REFUSED reason=core_install_identity_missing" >&2
  exit 3
}

if [[ "$ADAPTER" == "claude-code" ]]; then
  command -v claude >/dev/null 2>&1 || {
    echo "ADAPTER_INSTALL=REFUSED reason=claude_cli_missing adapter=claude-code" >&2
    exit 4
  }
  [[ -f "$ROOT/.claude-plugin/plugin.json" && -f "$ROOT/.claude-plugin/marketplace.json" ]] || {
    echo "ADAPTER_INSTALL=REFUSED reason=claude_adapter_manifest_missing" >&2
    exit 4
  }
  PLUGIN_VERSION="$(python3 -B - "$ROOT/.claude-plugin/plugin.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["version"])
PY
)"
  MARKET_VERSION="$(python3 -B - "$ROOT/.claude-plugin/marketplace.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["plugins"][0]["version"])
PY
)"
  if [[ "$PLUGIN_VERSION" != "$VERSION" || "$MARKET_VERSION" != "$VERSION" ]]; then
    echo "ADAPTER_INSTALL=REFUSED reason=version_mismatch core=$VERSION plugin=$PLUGIN_VERSION marketplace=$MARKET_VERSION" >&2
    exit 4
  fi

  SCOPE="${SCOPE:-user}"
  PLUGIN_ID="${PLUGIN_ID:-of-loop@ownframework}"
  MARKETPLACE_NAME="${MARKETPLACE_NAME:-ownframework}"

  # Replace adapter registration so an old checkout/marketplace path can never
  # remain the source of a fresh adapter install. The plugin cache is not core.
  claude plugin uninstall "$PLUGIN_ID" --scope "$SCOPE" >/dev/null 2>&1 || true
  claude plugin marketplace remove "$MARKETPLACE_NAME" >/dev/null 2>&1 || true
  claude plugin marketplace add "$ROOT" >/dev/null
  claude plugin install "$PLUGIN_ID" --scope "$SCOPE" >/dev/null

  claude plugin list | grep -F "$PLUGIN_ID" >/dev/null || {
    echo "ADAPTER_INSTALL=REFUSED reason=claude_plugin_not_visible_after_install" >&2
    exit 4
  }

  cat <<EOF
ADAPTER_INSTALL=PASS
ADAPTER=claude-code
VERSION=$VERSION
CORE_ROOT=$CORE_ROOT
PLUGIN_ID=$PLUGIN_ID
SCOPE=$SCOPE
CORE_OWNERSHIP=independent
EOF
  exit 0
fi

# Codex Agent Skills adapter.
SKILLS_ROOT="${OFLOOP_AGENT_SKILLS_DIR:-$HOME/.agents/skills}"
SKILLS=(of-loop-spec of-loop-build of-loop-review of-loop-status)
mkdir -p "$SKILLS_ROOT"

for skill in "${SKILLS[@]}"; do
  src="$CORE_ROOT/.agents/skills/$skill"
  dest="$SKILLS_ROOT/$skill"
  [[ -f "$src/SKILL.md" ]] || {
    echo "ADAPTER_INSTALL=REFUSED reason=core_skill_missing skill=$skill" >&2
    exit 5
  }
  if [[ -e "$dest" && ! -f "$dest/.ownframework-loop-managed" ]]; then
    echo "ADAPTER_INSTALL=REFUSED reason=unmanaged_agent_skill path=$dest" >&2
    exit 5
  fi
done

for skill in "${SKILLS[@]}"; do
  src="$CORE_ROOT/.agents/skills/$skill"
  dest="$SKILLS_ROOT/$skill"
  [[ -e "$dest" ]] && rm -rf "$dest"
  mkdir -p "$dest"
  cp -R "$src/." "$dest/"
  cat > "$dest/.ownframework-loop-managed" <<EOF
adapter=codex
version=$VERSION
core_root=$CORE_ROOT
EOF
done

"$CORE_ROOT/bin/ofloop" adapter show codex >/dev/null
cat <<EOF
ADAPTER_INSTALL=PASS
ADAPTER=codex
VERSION=$VERSION
CORE_ROOT=$CORE_ROOT
AGENT_SKILLS_ROOT=$SKILLS_ROOT
SKILLS=${SKILLS[*]}
CORE_OWNERSHIP=independent
EOF
if command -v codex >/dev/null 2>&1; then
  echo "CODEX_VERSION=$(codex --version 2>/dev/null | head -n1)"
else
  echo "CODEX_VERSION=not-installed"
fi
