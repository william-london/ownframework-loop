#!/usr/bin/env bash
# Remove the per-user OwnFramework Loop macOS supervisor service.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

LABEL="com.ownframework.loop-supervisor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/ownframework-loop"
SUPERVISOR_DB="$STATE_ROOT/supervisor.sqlite3"
RUNTIME_PROVENANCE="$STATE_ROOT/runtime-provenance.json"
SERVICE_ENV="$STATE_ROOT/service-env.json"
LEDGER_MARKER="$STATE_ROOT/ledger-incarnation.json"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "SUPERVISOR_UNINSTALL=REFUSED reason=macos_required" >&2
  exit 2
fi

if [[ ! -f "$SUPERVISOR_DB" && ( -f "$PLIST" || -f "$RUNTIME_PROVENANCE" || -f "$LEDGER_MARKER" ) ]]; then
  echo "SUPERVISOR_UNINSTALL=REFUSED reason=ledger_missing_runtime_dependency_unverifiable" >&2
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
# Prove the user launchd domain itself is reachable.  Only then can a missing
# label be treated as benign absence rather than manager-state ambiguity.
if ! launchctl print "$DOMAIN" >/dev/null 2>&1; then
  echo "SUPERVISOR_UNINSTALL=REFUSED reason=launchd_manager_unavailable" >&2
  exit 14
fi
set +e
launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1
PRINT_RC=$?
set -e
if [[ "$PRINT_RC" -eq 0 ]]; then
  if [[ -f "$PLIST" ]]; then
    if ! launchctl bootout "$DOMAIN" "$PLIST" >/dev/null 2>&1; then
      echo "SUPERVISOR_UNINSTALL=REFUSED reason=service_stop_failed" >&2
      exit 14
    fi
  elif ! launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    echo "SUPERVISOR_UNINSTALL=REFUSED reason=service_stop_failed" >&2
    exit 14
  fi
fi
if [[ ! -e "$PLIST" && ! -e "$RUNTIME_PROVENANCE" ]]; then
  echo "SUPERVISOR_UNINSTALL=NOOP reason=service_artifacts_absent"
  echo "STATE_PRESERVED=yes"
  exit 0
fi
rm -f "$PLIST" "$RUNTIME_PROVENANCE" "$SERVICE_ENV"

echo "SUPERVISOR_UNINSTALL=PASS"
echo "SERVICE_MANAGER=launchd"
echo "LABEL=$LABEL"
echo "STATE_PRESERVED=yes"
