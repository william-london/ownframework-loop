#!/usr/bin/env bash
# OwnFramework Loop V1 — install.
#
# Stages the source tree in a temp directory, verifies it, backs up any
# existing installed copy under a timestamped directory, then atomically
# replaces /Users/mr.mrs.london/.claude/skills/of-loop.
#
# Idempotent. Safe to re-run. Creates an installation receipt.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ROOT="$HERE"
INSTALL_ROOT="${INSTALL_ROOT:-/Users/mr.mrs.london/.claude/skills/of-loop}"
INSTALL_PARENT="$(dirname "$INSTALL_ROOT")"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_ROOT="${INSTALL_ROOT}.backup-${TIMESTAMP}"
RECEIPT_DIR="${OFLOOP_RECEIPT_DIR:-}"
# Prefer Claude-managed persistent plugin data when available.
if [[ -z "$RECEIPT_DIR" && -n "${CLAUDE_PLUGIN_DATA:-}" ]]; then
  RECEIPT_DIR="${CLAUDE_PLUGIN_DATA}/installation"
  mkdir -p "$RECEIPT_DIR"
fi
if [[ -z "$RECEIPT_DIR" ]]; then
  RECEIPT_DIR="/Users/mr.mrs.london/.claude/ownframework-loop-receipts"
fi
RECEIPT_PATH="$RECEIPT_DIR/install-${TIMESTAMP}.json"
STAGING="$(mktemp -d -t ofloop_install.XXXXXX)"

log() { echo "[install] $*"; }

log "source: $SOURCE_ROOT"
log "install_root: $INSTALL_ROOT"
log "staging: $STAGING"

# 1. Run the source release gate first. Abort on failure.
log "step 1: source release gate"
if ! bash "$SOURCE_ROOT/release_gate.sh"; then
  log "source release gate FAILED — aborting install"
  rm -rf "$STAGING"
  exit 1
fi

# 2. Stage a complete copy in the temp directory.
log "step 2: stage complete copy"
# Copy everything except .git, test caches, fixtures runtime artifacts.
rsync -a --exclude='.git/' \
  --exclude='__pycache__/' \
  --exclude='.pytest_cache/' \
  --exclude='.ruff_cache/' \
  --exclude='.venv/' \
  --exclude='.DS_Store' \
  --exclude='*.pyc' \
  --exclude='*.tmp' \
  --exclude='.tmp/' \
  --exclude='tests/smoke/' \
  "$SOURCE_ROOT/" "$STAGING/"

# 3. Verify the staged copy.
log "step 3: verify staged copy"
REQUIRED_FILES=(
  ".claude-plugin/plugin.json"
  "skills/spec/SKILL.md"
  "skills/build/SKILL.md"
  "skills/review/SKILL.md"
  "agents/of-builder.md"
  "agents/of-reviewer.md"
  "hooks/hooks.json"
  "bin/ofloop"
  "lib/ownframework_loop/__init__.py"
  "schemas/work-packet.schema.json"
  "schemas/state.schema.json"
  "schemas/build-receipt.schema.json"
  "schemas/review-verdict.schema.json"
  "README.md"
  "THIRD_PARTY_NOTICES.md"
)
for f in "${REQUIRED_FILES[@]}"; do
  if [[ ! -e "$STAGING/$f" ]]; then
    log "missing required file: $f"
    rm -rf "$STAGING"
    exit 1
  fi
done

# 4. Back up any existing installed copy.
mkdir -p "$INSTALL_PARENT"
if [[ -e "$INSTALL_ROOT" && ! -L "$INSTALL_ROOT" ]]; then
  log "step 4: backing up existing copy to $BACKUP_ROOT"
  mv "$INSTALL_ROOT" "$BACKUP_ROOT"
elif [[ -L "$INSTALL_ROOT" ]]; then
  log "step 4: removing existing symlink (refusing to follow symlinks)"
  rm "$INSTALL_ROOT"
fi

# 5. Atomic copy into place.
log "step 5: atomic install to $INSTALL_ROOT"
mkdir -p "$INSTALL_ROOT"
# Use rsync into a clean target.
rsync -a --delete "$STAGING/" "$INSTALL_ROOT/"

# 6. Validate the installed copy.
log "step 6: validate installed copy"
if ! bash "$INSTALL_ROOT/validate.sh" --installed; then
  log "installed copy validation FAILED — restoring backup"
  rm -rf "$INSTALL_ROOT"
  if [[ -d "$BACKUP_ROOT" ]]; then
    mv "$BACKUP_ROOT" "$INSTALL_ROOT"
  fi
  rm -rf "$STAGING"
  exit 1
fi

# 7. Write the installation receipt.
mkdir -p "$RECEIPT_DIR"
SOURCE_COMMIT="$(cd "$SOURCE_ROOT" && git rev-parse HEAD 2>/dev/null || echo 'no-git')"
SOURCE_VERSION="$(python3 -c 'import json; print(json.load(open("'"$SOURCE_ROOT"'/.claude-plugin/plugin.json"))["version"])')"
python3 - <<PY > "$RECEIPT_PATH"
import json, os
receipt = {
    "schema": "ownframework-loop-install-receipt/v1",
    "installed_path": "$INSTALL_ROOT",
    "backup_path": "$BACKUP_ROOT" if os.path.exists("$BACKUP_ROOT") else None,
    "source_root": "$SOURCE_ROOT",
    "source_commit": "$SOURCE_COMMIT",
    "source_version": "$SOURCE_VERSION",
    "installed_at_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "is_copy": True,
    "is_symlink": False,
}
print(json.dumps(receipt, indent=2, sort_keys=True))
PY

log "install complete"
log "receipt: $RECEIPT_PATH"
log "rollback: bash $SOURCE_ROOT/rollback.sh"
log "uninstall: bash $SOURCE_ROOT/uninstall.sh"

# Cleanup staging.
rm -rf "$STAGING"
exit 0
