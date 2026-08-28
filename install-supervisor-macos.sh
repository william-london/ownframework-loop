#!/usr/bin/env bash
# Install the OwnFramework Loop durable supervisor as a per-user macOS launchd service.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OFLOOP_BIN="${OFLOOP_BIN:-$ROOT/bin/ofloop}"
LABEL="com.ownframework.loop-supervisor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/ownframework-loop"
STDOUT_LOG="$STATE_ROOT/supervisor.stdout.log"
STDERR_LOG="$STATE_ROOT/supervisor.stderr.log"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "SUPERVISOR_INSTALL=REFUSED reason=macos_required" >&2
  exit 2
fi
if [[ ! -x "$OFLOOP_BIN" ]]; then
  echo "SUPERVISOR_INSTALL=REFUSED reason=ofloop_not_executable path=$OFLOOP_BIN" >&2
  exit 2
fi

mkdir -p "$HOME/Library/LaunchAgents" "$STATE_ROOT"

python3 - "$PLIST" "$OFLOOP_BIN" "$LABEL" "$STDOUT_LOG" "$STDERR_LOG" <<'PY'
import plistlib, sys
from pathlib import Path
plist, ofloop, label, stdout_log, stderr_log = sys.argv[1:]
payload = {
    "Label": label,
    "ProgramArguments": [ofloop, "supervisor", "serve"],
    "RunAtLoad": True,
    "KeepAlive": True,
    "ProcessType": "Background",
    "ThrottleInterval": 5,
    "StandardOutPath": stdout_log,
    "StandardErrorPath": stderr_log,
}
path = Path(plist)
with path.open("wb") as f:
    plistlib.dump(payload, f, sort_keys=True)
PY

DOMAIN="gui/$UID"
launchctl bootout "$DOMAIN" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl enable "$DOMAIN/$LABEL" >/dev/null 2>&1 || true

echo "SUPERVISOR_INSTALL=PASS"
echo "LABEL=$LABEL"
echo "PLIST=$PLIST"
echo "OFLOOP_BIN=$OFLOOP_BIN"
echo "STATE_ROOT=$STATE_ROOT"
