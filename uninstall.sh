#!/usr/bin/env bash
# OwnFramework Loop V1 — uninstall.
#
# Removes the installed copy at /Users/mr.mrs.london/.claude/skills/of-loop.
# Does NOT remove the source repo, receipts, or backup directories.
# A subsequent install.sh creates a fresh copy.

set -euo pipefail

INSTALL_ROOT="${INSTALL_ROOT:-/Users/mr.mrs.london/.claude/skills/of-loop}"

if [[ ! -e "$INSTALL_ROOT" && ! -L "$INSTALL_ROOT" ]]; then
  echo "[uninstall] nothing to remove at $INSTALL_ROOT"
  exit 0
fi

if [[ -L "$INSTALL_ROOT" ]]; then
  echo "[uninstall] refusing to follow symlink; aborting"
  exit 1
fi

if [[ ! -f "$INSTALL_ROOT/.claude-plugin/plugin.json" ]]; then
  echo "[uninstall] refusing to remove path that does not look like an of-loop install: $INSTALL_ROOT"
  exit 1
fi

echo "[uninstall] removing $INSTALL_ROOT"
rm -rf "$INSTALL_ROOT"
echo "[uninstall] complete"
exit 0
