#!/usr/bin/env bash
# Remove the per-user OwnFramework Loop macOS supervisor service.
set -euo pipefail

LABEL="com.ownframework.loop-supervisor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/ownframework-loop"
SUPERVISOR_DB="$STATE_ROOT/supervisor.sqlite3"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "SUPERVISOR_UNINSTALL=REFUSED reason=macos_required" >&2
  exit 2
fi

if [[ -f "$SUPERVISOR_DB" && "${OFLOOP_ALLOW_SUPERVISOR_SWAP_WITH_ACTIVE_WORK:-0}" != "1" ]]; then
  RUNNING_REPORT="$(python3 -B - "$SUPERVISOR_DB" <<'PY'
import sqlite3,sys
try:
    c=sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
    rows=c.execute("SELECT run_id FROM jobs WHERE status='RUNNING' ORDER BY id").fetchall()
except sqlite3.Error:
    print("ledger_probe_failed")
    raise SystemExit(0)
print(";".join(str(r[0]) for r in rows[:8]))
PY
  )" || RUNNING_REPORT="ledger_probe_failed"
  if [[ -n "$RUNNING_REPORT" ]]; then
    echo "SUPERVISOR_UNINSTALL=REFUSED reason=active_or_unverifiable_running_work detail=$RUNNING_REPORT" >&2
    exit 11
  fi
fi

DOMAIN="gui/$UID"
launchctl bootout "$DOMAIN" "$PLIST" >/dev/null 2>&1 || true
rm -f "$PLIST"

echo "SUPERVISOR_UNINSTALL=PASS"
echo "LABEL=$LABEL"
