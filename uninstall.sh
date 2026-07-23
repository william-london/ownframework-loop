#!/usr/bin/env bash
# OwnFramework Loop V2 — managed uninstall.
#
# Removes the managed plugin via Claude's official plugin manager:
#   claude plugin uninstall of-loop@ownframework-local --scope user
#
# Preserves:
#   - persistent plugin data at ~/.claude/plugins/data/of-loop-ownframework-local
#   - archived legacy skills-dir at ~/.claude/ownframework-loop-mgmt-backup-*
#   - source repo at /Users/mr.mrs.london/projects/plugins/ownframework-loop

set -euo pipefail

if ! command -v claude >/dev/null 2>&1; then
  echo "[uninstall] claude CLI not on PATH; cannot run managed uninstall"
  exit 2
fi

echo "[uninstall] running: claude plugin uninstall of-loop@ownframework-local --scope user"
claude plugin uninstall of-loop@ownframework-local --scope user 2>&1
echo "[uninstall] complete; plugin data and backup dir retained"
exit 0
