#!/usr/bin/env bash
# OwnFramework Loop V2 — managed marketplace installer.
#
# Installs the plugin through Claude's official plugin manager using the
# local marketplace catalog at:
#   /Users/mr.mrs.london/projects/plugins/.claude-plugin/marketplace.json
# Plugin identity after install:
#   of-loop@ownframework-local  →  ~/.claude/plugins/cache/ownframework-local/of-loop/<version>
#
# This installer does NOT copy into ~/.claude/skills/of-loop. That path is
# a legacy copy artifact retained only as a warm rollback target under
# ~/.claude/ownframework-loop-mgmt-backup-<UTC>/.
#
# Pre-requisites:
#   - `claude` CLI on PATH
#   - Marketplace catalog pinned to the expected version
#   - Source clean
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ROOT="$HERE"
MARKETPLACE_ROOT="$(cd "$SOURCE_ROOT/.." && pwd)"
PLUGIN_DIR_NAME="$(basename "$SOURCE_ROOT")"
EXPECTED_VERSION="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['version'])" "$SOURCE_ROOT/.claude-plugin/plugin.json")"
MARKET_VERSION="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['plugins'][0]['version'])" "$MARKETPLACE_ROOT/.claude-plugin/marketplace.json")"
log() { echo "[install] $*"; }

log "source: $SOURCE_ROOT (branch=${SOURCE_BRANCH:-master})"
log "expected version: $EXPECTED_VERSION"
log "marketplace version: $MARKET_VERSION"

if [[ "$EXPECTED_VERSION" != "$MARKET_VERSION" ]]; then
  log "version mismatch between source and marketplace; refusing"
  exit 2
fi

# Archive any legacy skills-dir copy BEFORE managed install (preserves rollback target).
if [[ -d "$HOME/.claude/skills/of-loop" ]]; then
  TS="$(date -u +%Y%m%dT%H%M%SZ)"
  BACKUP="$HOME/.claude/ownframework-loop-mgmt-backup-$TS"
  log "archiving legacy skills-dir copy → $BACKUP"
  mkdir -p "$(dirname "$BACKUP")"
  mv "$HOME/.claude/skills/of-loop" "$BACKUP"
fi

# Run the managed install.
log "step 1: managed install of of-loop@ownframework-local@$EXPECTED_VERSION"
if ! command -v claude >/dev/null 2>&1; then
  log "claude CLI not on PATH; aborting"
  exit 3
fi

# Uninstall any pre-existing managed install of the same plugin name.
# The marketplace installer refuses to upgrade when an old version is
# already installed. This is the documented install choreography.
log "step 1a: removing any pre-existing of-loop@ownframework-local managed install"
claude plugin uninstall of-loop@ownframework-local --scope user 2>&1 | tee "$SOURCE_ROOT/.uninstall.log" || true

# The official command is: claude plugin install of-loop@ownframework-local --scope user
log "step 1b: claude plugin install of-loop@ownframework-local --scope user"
claude plugin install "of-loop@ownframework-local" --scope user 2>&1 | tee "$SOURCE_ROOT/.install.log"

log "managed install complete; reload with: claude /reload-plugins"
exit 0
