#!/usr/bin/env bash
# OwnFramework Loop — rollback helper (legacy skills-dir backups only).
#
# SCOPE:
#   This script only restores timestamped backup directories created by
#   historical versions of install.sh. It does NOT roll back a managed
#   marketplace install \u2014 the canonical way to do that is to install a
#   different version through the marketplace, e.g.:
#
#       claude plugin update of-loop@ownframework
#       claude plugin install of-loop@ownframework@<previous-version>
#
# If you have no skills-dir backups (the typical state for a fresh public
# install), this script will report that no backups were found and exit 1.
# That is correct behaviour, not a bug.
#
# Honors:
#   INSTALL_ROOT  - the legacy skills-dir path (default: ~/.claude/skills/of-loop)
#   INSTALL_PARENT - directory under which to look for backups (derived from
#                    INSTALL_ROOT when unset)

set -euo pipefail

: "${INSTALL_ROOT:=$HOME/.claude/skills/of-loop}"
: "${INSTALL_PARENT:=$HOME/.claude}"

echo "[rollback] looking for skills-dir backups under $INSTALL_PARENT"

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
    echo "[rollback] no legacy skills-dir backups found under $INSTALL_PARENT"
    echo "[rollback] for a managed install, use 'claude plugin install of-loop@ownframework@<version>' instead"
    exit 1
fi

LATEST="${BACKUPS[0]}"
echo "[rollback] latest backup: $LATEST"

if [[ ! -f "$LATEST/.claude-plugin/plugin.json" ]]; then
    echo "[rollback] latest backup does not look like an of-loop install; aborting"
    exit 1
fi

if [[ -e "$INSTALL_ROOT" || -L "$INSTALL_ROOT" ]]; then
  if [[ -L "$INSTALL_ROOT" ]]; then
    rm "$INSTALL_ROOT"
  else
    RB="${INSTALL_ROOT}.rolled-back-$(date -u +%Y%m%dT%H%M%SZ)"
    mv "$INSTALL_ROOT" "$RB"
    echo "[rollback] moved current install to $RB"
  fi
fi

mv "$LATEST" "$INSTALL_ROOT"
echo "[rollback] restored $LATEST to $INSTALL_ROOT"
echo "[rollback] complete"
exit 0
