#!/usr/bin/env bash
# OwnFramework Loop V2 — rollback.
#
# Restores the most recent timestamped backup directory. Accepts the legacy
# `of-loop.backup-*` naming and the current `ownframework-loop-mgmt-backup-*`
# naming produced by install.sh. Lists available backups if no fresh backup is
# found.
#
# Honors:
#   INSTALL_ROOT  - path of the installed copy (default: see below)
#   INSTALL_PARENT - directory under which to look for backups (derived
#                    from INSTALL_ROOT when unset)

set -euo pipefail

: "${INSTALL_ROOT:=$HOME/.claude/skills/of-loop}"
: "${INSTALL_PARENT:=$(dirname "$INSTALL_ROOT")}"

# Find candidate backups in time order (newest first). Accept both naming
# conventions produced by historical versions of install.sh. Use a bash 3.2
# compatible read loop instead of `mapfile` (mapfile requires bash 4+).
BACKUPS=()
TMP="$(mktemp -t ofloop_rollback.XXXXXX)"
trap "rm -f \"$TMP\"" EXIT
{
  ls -1dt "$INSTALL_PARENT"/of-loop.backup-*               2>/dev/null || true
  ls -1dt "$INSTALL_PARENT"/ownframework-loop-mgmt-backup-* 2>/dev/null || true
} | awk '!seen[$0]++' > "$TMP"
while IFS= read -r line; do
  [[ -n "$line" ]] && BACKUPS+=("$line")
done < "$TMP"

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
    # Move current to a "rolled-back" tag so the previous install is preserved.
    RB="${INSTALL_ROOT}.rolled-back-$(date -u +%Y%m%dT%H%M%SZ)"
    mv "$INSTALL_ROOT" "$RB"
    echo "[rollback] moved current install to $RB"
  fi
fi

mv "$LATEST" "$INSTALL_ROOT"
echo "[rollback] restored $LATEST to $INSTALL_ROOT"
echo "[rollback] complete"
exit 0
