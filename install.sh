#!/usr/bin/env bash
# OwnFramework Loop V2 — managed marketplace installer.
#
# Installs the plugin through Claude's official plugin manager using the
# local marketplace catalog at:
#   <source-root>/../.claude-plugin/marketplace.json
# Plugin identity after install:
#   of-loop@ownframework-local  -> ~/.claude/plugins/cache/ownframework-local/of-loop/<version>
#
# This installer does NOT copy into ~/.claude/skills/of-loop. That path is
# a legacy copy artifact retained only as a warm rollback target under
# ~/.claude/ownframework-loop-mgmt-backup-<UTC>/.
#
# Pre-requisites:
#   - `claude` CLI on PATH
#   - Marketplace catalog pinned to the expected version
#   - Source clean
#
# Atomicity:
#   - We never partially install. The legacy skills-dir archive (if any)
#     happens FIRST, so rollback material is reserved before the managed
#     install mutates the marketplace payload.
#   - The managed install runs immediately after the archive, and we
#     capture its full output to .install.log / .uninstall.log.
#   - If the managed install fails, we attempt to restore the archived
#     legacy copy to its original path before exiting non-zero.
#
# Provenance:
#   - We record SOURCE_BRANCH from the current branch in $SOURCE_BRANCH
#     (default: `git branch --show-current`). No branch is hardcoded.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ROOT="$HERE"
MARKETPLACE_ROOT="$(cd "$SOURCE_ROOT/.." && pwd)"
PLUGIN_DIR_NAME="$(basename "$SOURCE_ROOT")"
SOURCE_BRANCH="${SOURCE_BRANCH:-$(git -C "$SOURCE_ROOT" branch --show-current 2>/dev/null || echo unknown)}"
EXPECTED_VERSION="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['version'])" "$SOURCE_ROOT/.claude-plugin/plugin.json")"
MARKET_VERSION="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['plugins'][0]['version'])" "$MARKETPLACE_ROOT/.claude-plugin/marketplace.json")"
log() { echo "[install] $*"; }

log "source: $SOURCE_ROOT (branch=${SOURCE_BRANCH})"
log "expected version: $EXPECTED_VERSION"
log "marketplace version: $MARKET_VERSION"

if [[ "$EXPECTED_VERSION" != "$MARKET_VERSION" ]]; then
  log "version mismatch between source and marketplace; refusing"
  exit 2
fi

# Archive any legacy skills-dir copy BEFORE managed install (preserves rollback target).
LEGACY_DIR="$HOME/.claude/skills/of-loop"
LEGACY_BACKUP=""
if [[ -d "$LEGACY_DIR" ]]; then
  TS="$(date -u +%Y%m%dT%H%M%SZ)"
  LEGACY_BACKUP="$HOME/.claude/ownframework-loop-mgmt-backup-$TS"
  log "archiving legacy skills-dir copy -> $LEGACY_BACKUP"
  mkdir -p "$(dirname "$LEGACY_BACKUP")"
  mv "$LEGACY_DIR" "$LEGACY_BACKUP"
fi

# Run the managed install.
log "step 1: managed install of of-loop@ownframework-local@$EXPECTED_VERSION"
if ! command -v claude >/dev/null 2>&1; then
  log "claude CLI not on PATH; aborting"
  # Restore the archived legacy copy since we did not mutate state successfully.
  if [[ -n "$LEGACY_BACKUP" && -d "$LEGACY_BACKUP" ]]; then
    mv "$LEGACY_BACKUP" "$LEGACY_DIR"
    log "rolled back legacy archive -> $LEGACY_DIR"
  fi
  exit 3
fi

restore_legacy() {
  if [[ -n "$LEGACY_BACKUP" && -d "$LEGACY_BACKUP" && ! -e "$LEGACY_DIR" ]]; then
    mv "$LEGACY_BACKUP" "$LEGACY_DIR"
    log "rolled back legacy archive -> $LEGACY_DIR"
  fi
}

# Uninstall any pre-existing managed install of the same plugin name.
# The marketplace installer refuses to upgrade when an old version is
# already installed. This is the documented install choreography.
log "step 1a: removing any pre-existing of-loop@ownframework-local managed install"
if ! claude plugin uninstall of-loop@ownframework-local --scope user >"$SOURCE_ROOT/.uninstall.log" 2>&1; then
  log "warning: uninstall step returned non-zero; continuing (see $SOURCE_ROOT/.uninstall.log)"
fi

# The official command is: claude plugin install of-loop@ownframework-local --scope user
log "step 1b: claude plugin install of-loop@ownframework-local --scope user"
if ! claude plugin install "of-loop@ownframework-local" --scope user >"$SOURCE_ROOT/.install.log" 2>&1; then
  log "managed install FAILED; see $SOURCE_ROOT/.install.log"
  restore_legacy
  exit 4
fi

# Parity check: the cache tree for this version must now exist.
EXPECTED_CACHE="$HOME/.claude/plugins/cache/ownframework-local/of-loop/$EXPECTED_VERSION"
if [[ ! -d "$EXPECTED_CACHE" ]]; then
  log "parity check FAILED: expected cache tree missing at $EXPECTED_CACHE"
  restore_legacy
  exit 5
fi

log "managed install complete; cache=$EXPECTED_CACHE; reload with: claude /reload-plugins"
exit 0
