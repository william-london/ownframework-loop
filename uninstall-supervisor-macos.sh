#!/usr/bin/env bash
# Remove the per-user OwnFramework Loop macOS supervisor service.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

LABEL="com.ownframework.loop-supervisor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/ownframework-loop"
SUPERVISOR_DB="$STATE_ROOT/supervisor.sqlite3"
RUNTIME_PROVENANCE="$STATE_ROOT/runtime-provenance.json"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "SUPERVISOR_UNINSTALL=REFUSED reason=macos_required" >&2
  exit 2
fi

if [[ ! -f "$SUPERVISOR_DB" && -f "$PLIST" && "${OFLOOP_ALLOW_SUPERVISOR_SWAP_WITH_ACTIVE_WORK:-0}" != "1" ]]; then
  echo "SUPERVISOR_UNINSTALL=REFUSED reason=ledger is missing; cannot verify unfinished runtime dependency" >&2
  echo "unsafe recovery override: OFLOOP_ALLOW_SUPERVISOR_SWAP_WITH_ACTIVE_WORK=1" >&2
  exit 13
fi
if [[ -f "$SUPERVISOR_DB" && "${OFLOOP_ALLOW_SUPERVISOR_SWAP_WITH_ACTIVE_WORK:-0}" != "1" ]]; then
  set +e
  PROBE_OUT="$(PYTHONDONTWRITEBYTECODE=1 python3 -B "$ROOT/scripts/probe-supervisor-runtime-dependencies.py" "$SUPERVISOR_DB" uninstall --allow-generation-migration 2>&1)"
  PROBE_RC=$?
  set -e
  if [[ "$PROBE_RC" -ne 0 ]]; then
    echo "SUPERVISOR_UNINSTALL=REFUSED $PROBE_OUT" >&2
    exit "$PROBE_RC"
  fi
fi
DOMAIN="gui/$UID"
launchctl bootout "$DOMAIN" "$PLIST" >/dev/null 2>&1 || true
rm -f "$PLIST" "$RUNTIME_PROVENANCE"

echo "SUPERVISOR_UNINSTALL=PASS"
echo "SERVICE_MANAGER=launchd"
echo "LABEL=$LABEL"
echo "STATE_PRESERVED=yes"
