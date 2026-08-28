#!/usr/bin/env bash
# Remove the per-user OwnFramework Loop macOS supervisor service.
set -euo pipefail

LABEL="com.ownframework.loop-supervisor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "SUPERVISOR_UNINSTALL=REFUSED reason=macos_required" >&2
  exit 2
fi

DOMAIN="gui/$UID"
launchctl bootout "$DOMAIN" "$PLIST" >/dev/null 2>&1 || true
rm -f "$PLIST"

echo "SUPERVISOR_UNINSTALL=PASS"
echo "LABEL=$LABEL"
