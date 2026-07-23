#!/usr/bin/env bash
# OwnFramework Loop V1 — rollback.
#
# Restores the most recent timestamped backup directory. Lists available
# backups if no fresh backup is found.

set -euo pipefail

INSTALL_ROOT="${INSTALL_ROOT:-/Users/mr.mrs.london/.claude/skills/of-loop}"
INSTALL_PARENT="$(dirname "$INSTALL_ROOT")"

# Find candidate backups in time order (newest first).
mapfile -t BACKUPS < <(ls -1dt "$INSTALL_PARENT"/of-loop.backup-* 2>/dev/null || true)

if [[ ${#BACKUPS[@]} -eq 0 ]]; then
  echo "[rollback] no backups found under $INSTALL_PARENT"
  exit 1
fi

LATEST="${BACKUPS[0]}"
echo "[rollback] latest backup: $LATEST"

if [[ ! -f "$LATEST/.claude-plugin/plugin.json" ]]; then
  echo "[rollback] latest backup does not look like an of-loop install; aborting"
  exit 1
fi

# Move the current install aside (or remove it) and put the backup in place.
if [[ -e "$INSTALL_ROOT" || -L "$INSTALL_ROOT" ]]; then
  if [[ -L "$INSTALL_ROOT" ]]; then
    rm "$INSTALL_ROOT"
  else
    # Move current to a "rolled-back" tag.
    RB="${INSTALL_ROOT}.rolled-back-$(date -u +%Y%m%dT%H%M%SZ)"
    mv "$INSTALL_ROOT" "$RB"
    echo "[rollback] moved current install to $RB"
  fi
fi

mv "$LATEST" "$INSTALL_ROOT"
echo "[rollback] restored $LATEST to $INSTALL_ROOT"
echo "[rollback] complete"
exit 0
