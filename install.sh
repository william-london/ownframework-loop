#!/usr/bin/env bash
# OwnFramework Loop V2 — legacy copy installer.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ROOT="$HERE"
INSTALL_ROOT="${INSTALL_ROOT:-/Users/mr.mrs.london/.claude/skills/of-loop}"
INSTALL_PARENT="$(dirname "$INSTALL_ROOT")"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_ROOT="${INSTALL_ROOT}.backup-${TIMESTAMP}"
export PYTHONPATH="$SOURCE_ROOT/lib${PYTHONPATH:+:$PYTHONPATH}"
RECEIPT_DIR="$(python3 -c 'from ownframework_loop.plugin_data import installation_dir; print(installation_dir())')"
STAGING=""
cleanup() { [[ -n "${STAGING:-}" && -d "$STAGING" ]] && rm -rf "$STAGING"; }
trap cleanup EXIT INT TERM HUP
STAGING="$(mktemp -d -t ofloop-install.XXXXXX)"
log() { echo "[install] $*"; }
log "source: $SOURCE_ROOT"
log "install_root: $INSTALL_ROOT"
log "receipt_dir: $RECEIPT_DIR"
log "staging: $STAGING"
log "step 1: source release gate"
bash "$SOURCE_ROOT/release_gate.sh"
log "step 2: stage complete copy"
rsync -a --exclude='.git/' --exclude='__pycache__/' --exclude='.pytest_cache/' \
  --exclude='.ruff_cache/' --exclude='.venv/' --exclude='.DS_Store' --exclude='*.pyc' \
  --exclude='*.tmp' --exclude='.tmp/' --exclude='tests/smoke/' "$SOURCE_ROOT/" "$STAGING/"
log "step 3: verify staged copy"
for f in .claude-plugin/plugin.json skills/spec/SKILL.md skills/build/SKILL.md skills/review/SKILL.md \
  agents/of-builder.md agents/of-reviewer.md hooks/hooks.json bin/ofloop lib/ownframework_loop/__init__.py \
  schemas/work-packet.schema.json schemas/state.schema.json schemas/build-receipt.schema.json \
  schemas/review-verdict.schema.json README.md THIRD_PARTY_NOTICES.md; do
  [[ -e "$STAGING/$f" ]] || { log "missing required file: $f"; exit 1; }
done
mkdir -p "$INSTALL_PARENT"
if [[ -e "$INSTALL_ROOT" && ! -L "$INSTALL_ROOT" ]]; then
  log "step 4: backing up existing copy to $BACKUP_ROOT"
  mv "$INSTALL_ROOT" "$BACKUP_ROOT"
elif [[ -L "$INSTALL_ROOT" ]]; then
  rm "$INSTALL_ROOT"
fi
log "step 5: atomic install to $INSTALL_ROOT"
mkdir -p "$INSTALL_ROOT"
rsync -a --delete "$STAGING/" "$INSTALL_ROOT/"
log "step 6: validate installed copy structurally"
bash "$INSTALL_ROOT/validate.sh" --installed --skip-tests
SOURCE_COMMIT="$(cd "$SOURCE_ROOT" && git rev-parse HEAD 2>/dev/null || echo no-git)"
SOURCE_VERSION="$(python3 -c 'import json; print(json.load(open("'"$SOURCE_ROOT"'/.claude-plugin/plugin.json"))["version"])')"
INSTALL_ROOT="$INSTALL_ROOT" BACKUP_ROOT="$BACKUP_ROOT" SOURCE_ROOT="$SOURCE_ROOT" SOURCE_COMMIT="$SOURCE_COMMIT" SOURCE_VERSION="$SOURCE_VERSION" python3 - <<'PY'
import os
from ownframework_loop import plugin_data
from ownframework_loop.util import utc_now_iso
payload = {
    "schema": plugin_data.SCHEMA_INSTALL_RECEIPT,
    "installed_path": os.environ["INSTALL_ROOT"],
    "backup_path": os.environ["BACKUP_ROOT"] if os.path.exists(os.environ["BACKUP_ROOT"]) else None,
    "source_root": os.environ["SOURCE_ROOT"],
    "source_commit": os.environ["SOURCE_COMMIT"],
    "source_version": os.environ["SOURCE_VERSION"],
    "installed_at_utc": utc_now_iso(), "is_copy": True, "is_symlink": False,
}
print(plugin_data.write_receipt("installation", payload))
PY
log "install complete"
log "rollback: bash $SOURCE_ROOT/rollback.sh"
log "uninstall: bash $SOURCE_ROOT/uninstall.sh"
exit 0
