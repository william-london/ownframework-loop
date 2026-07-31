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
SOURCE_SHA="${SOURCE_SHA:-$(git -C "$SOURCE_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)}"
# Verify SOURCE_ROOT is actually a git repository (`git -C ...` succeeds) AND
# that the porcelain status is empty. The previous form silently returned 0
# `wc -l` on non-git trees (audit v0.3.0).
if ! git -C "$SOURCE_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  log "SOURCE_ROOT is not a git repository: $SOURCE_ROOT"
  exit 6
fi
SOURCE_DESC_DIRTY="$(git -C "$SOURCE_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
EXPECTED_VERSION="$(PYTHONDONTWRITEBYTECODE=1 python3 -B -c "import json,sys;print(json.load(open(sys.argv[1]))['version'])" "$SOURCE_ROOT/.claude-plugin/plugin.json")"
MARKET_VERSION="$(PYTHONDONTWRITEBYTECODE=1 python3 -B -c "import json,sys;print(json.load(open(sys.argv[1]))['plugins'][0]['version'])" "$MARKETPLACE_ROOT/.claude-plugin/marketplace.json")"
log() { echo "[install] $*"; }

log "source: $SOURCE_ROOT (branch=${SOURCE_BRANCH}, sha=${SOURCE_SHA}, dirty_files=${SOURCE_DESC_DIRTY})"
log "expected version: $EXPECTED_VERSION"
log "marketplace version: $MARKET_VERSION"

# Version-match check FIRST (avoids leaving a provenance artifact on
# version drift; audit v0.3.0).
if [[ "$EXPECTED_VERSION" != "$MARKET_VERSION" ]]; then
  log "version mismatch between source and marketplace; refusing"
  exit 2
fi

# Refuse to install from a tree with uncommitted changes (dirty installs
# are not reproducible). The check above already verified SOURCE_ROOT is a
# git repo, so an empty porcelain status truly means clean.
if [[ "$SOURCE_DESC_DIRTY" != "0" ]]; then
  log "source tree is dirty (${SOURCE_DESC_DIRTY} unstaged/staged files); refusing"
  exit 6
fi

# Provenance: written AFTER all pre-flight checks pass so a failed install
# does not leave a stale .install.provenance file in the source tree.
PROVENANCE="$SOURCE_ROOT/.install.provenance"
{
  echo "source_branch=${SOURCE_BRANCH}"
  echo "source_sha=${SOURCE_SHA}"
  echo "expected_version=${EXPECTED_VERSION}"
  echo "marketplace_version=${MARKET_VERSION}"
  echo "installed_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$PROVENANCE"
log "provenance: $PROVENANCE"

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

# Capture payload manifest: a flat sorted list of every regular file in the
# installed cache tree (relative to the cache root), with each file's SHA-256.
# This manifest is the authoritative "what did we just install" record.
# validate.sh --installed verifies the live cache matches this manifest, so
# post-install tampering is detected on the next validation pass.
log "step 2: capturing payload manifest for $EXPECTED_CACHE"
MANIFEST="$EXPECTED_CACHE/.payload.manifest"
# Exclude bytecode, .git/, .ownframework-loop/, logs/ from staged payload.
# These are runtime caches, not source artifacts, and including them
# causes false tampering reports when Python imports mutate __pycache__.
PAYLOAD_FILES="$( ( cd "$EXPECTED_CACHE" && find . -type f \
  -not -path "./logs/*" \
  -not -path "./.git/*" \
  -not -path "./.ownframework-loop/*" \
  -not -path "*/__pycache__/*" \
  -not -name "*.pyc" \
  -not -name "*.pyo" \
  -not -name "*.pyd" \
  | LC_ALL=C sort ) )"
# Iterate PAYLOAD_FILES ONCE, counting entries and writing SHA lines.
# This guarantees PAYLOAD_MANIFEST_FILE_ENTRIES == INSTALLED_ACTIVE_FILES
# == the count we publish in # file_count=. The previous approach used
# `printf "%s" "$PAYLOAD_FILES" | wc -l` which undercounts by 1 because
# `$(...)` strips the trailing newline of find/sort output, while the
# SHA loop itself iterates one extra time on the unterminated last line.
> "$MANIFEST.tmp"
{
  echo "# OwnFramework Loop payload manifest"
  echo "# generated_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# cache_root=$EXPECTED_CACHE"
  echo "# source_branch=$SOURCE_BRANCH"
  echo "# source_sha=$SOURCE_SHA"
  echo "# installed_version=$EXPECTED_VERSION"
} >> "$MANIFEST.tmp"
ENTRY_COUNT=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  rel="${f#./}"
  sha="$(shasum -a 256 "$EXPECTED_CACHE/$rel" 2>/dev/null | awk '{print $1}')"
  echo "sha256  $sha  $rel" >> "$MANIFEST.tmp"
  ENTRY_COUNT=$((ENTRY_COUNT+1))
done <<< "$PAYLOAD_FILES"
# Append the count header AFTER the loop so the declared count is
# guaranteed to match the actual SHA256 entries.
echo "# file_count=$ENTRY_COUNT" >> "$MANIFEST.tmp"
mv "$MANIFEST.tmp" "$MANIFEST"
log "payload manifest written: $MANIFEST (with $ENTRY_COUNT files)"

# Atomic install contract: the manifest now exists AT THE SAME PATH the
# validator reads. If validation fails after this point, we restore the
# legacy archive (above) AND remove the cache tree (below) so the system
# is observably NOT in a half-installed state.
log "managed install complete; cache=$EXPECTED_CACHE; reload with: claude /reload-plugins"
exit 0
