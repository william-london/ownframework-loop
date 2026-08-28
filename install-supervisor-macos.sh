#!/usr/bin/env bash
# Install the OwnFramework Loop durable supervisor as a per-user macOS launchd service.
#
# Resolves and persists exact runtime executables (Python, ofloop, Claude)
# so the supervisor never accidentally pins to a disposable feature checkout.
# Captures PATH needed by the noninteractive service.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
OFLOOP_BIN="${OFLOOP_BIN:-$ROOT/bin/ofloop}"
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || true)}"
LABEL="com.ownframework.loop-supervisor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/ownframework-loop"
STDOUT_LOG="$STATE_ROOT/supervisor.stdout.log"
STDERR_LOG="$STATE_ROOT/supervisor.stderr.log"
RUNTIME_PROVENANCE="$STATE_ROOT/runtime-provenance.json"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "SUPERVISOR_INSTALL=REFUSED reason=macos_required" >&2
  exit 2
fi
if [[ -z "$PYTHON_BIN" || ! -x "$PYTHON_BIN" ]]; then
  echo "SUPERVISOR_INSTALL=REFUSED reason=python3_not_executable path=$PYTHON_BIN" >&2
  exit 2
fi
if [[ ! -x "$OFLOOP_BIN" ]]; then
  echo "SUPERVISOR_INSTALL=REFUSED reason=ofloop_not_executable path=$OFLOOP_BIN" >&2
  exit 2
fi
if [[ -z "$CLAUDE_BIN" ]]; then
  echo "SUPERVISOR_INSTALL=WARN reason=claude_binary_missing service_can_run_idle_only" >&2
fi

# Build a minimal PATH for the noninteractive service so it can find
# ofloop, claude, git, jq, and Python. Persisted so a future operator can
# reproduce the environment exactly.
SERVICE_PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
[[ -d "/opt/homebrew/bin" ]] && SERVICE_PATH="/opt/homebrew/bin:$SERVICE_PATH"
[[ -d "$HOME/.local/bin" ]] && SERVICE_PATH="$HOME/.local/bin:$SERVICE_PATH"

mkdir -p "$HOME/Library/LaunchAgents" "$STATE_ROOT"

PYTHON_BIN="$PYTHON_BIN" OFLOOP_BIN="$OFLOOP_BIN" CLAUDE_BIN="$CLAUDE_BIN" SERVICE_PATH="$SERVICE_PATH" python3 - "$PLIST" "$RUNTIME_PROVENANCE" <<'PY'
import json, os, plistlib, sys
from pathlib import Path

plist, provenance_path = Path(sys.argv[1]), Path(sys.argv[2])

python_bin = os.environ["PYTHON_BIN"]
ofloop_bin = os.environ["OFLOOP_BIN"]
claude_bin = os.environ.get("CLAUDE_BIN") or None
service_path = os.environ["SERVICE_PATH"]

payload = {
    "Label": "com.ownframework.loop-supervisor",
    "ProgramArguments": [ofloop_bin, "supervisor", "serve"],
    "EnvironmentVariables": {
        "PATH": service_path,
        "PYTHONUNBUFFERED": "1",
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHON_BIN": python_bin,
        "OFLOOP_BIN": ofloop_bin,
        "OFLOOP_PLUGIN_ROOT": str(Path(ofloop_bin).resolve(strict=False).parent.parent),
    },
    "RunAtLoad": True,
    "KeepAlive": True,
    "ProcessType": "Background",
    "ThrottleInterval": 5,
    "StandardOutPath": str(Path.home() / ".local" / "state" / "ownframework-loop" / "supervisor.stdout.log"),
    "StandardErrorPath": str(Path.home() / ".local" / "state" / "ownframework-loop" / "supervisor.stderr.log"),
    "WorkingDirectory": str(Path.home()),
}
plist.parent.mkdir(parents=True, exist_ok=True)
with plist.open("wb") as f:
    plistlib.dump(payload, f, sort_keys=True)

provenance = {
    "schema": "ownframework-loop-supervisor-runtime-provenance/v1",
    "python_bin": python_bin,
    "ofloop_bin": ofloop_bin,
    "claude_bin": claude_bin,
    "service_path": service_path,
    "plist": str(plist),
}
provenance_path.parent.mkdir(parents=True, exist_ok=True)
provenance_path.write_text(json.dumps(provenance, indent=2, sort_keys=True))
PY

DOMAIN="gui/$UID"
launchctl bootout "$DOMAIN" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl enable "$DOMAIN/$LABEL" >/dev/null 2>&1 || true

echo "SUPERVISOR_INSTALL=PASS"
echo "LABEL=$LABEL"
echo "PLIST=$PLIST"
echo "PYTHON_BIN=$PYTHON_BIN"
echo "OFLOOP_BIN=$OFLOOP_BIN"
echo "CLAUDE_BIN=${CLAUDE_BIN:-(none)}"
echo "STATE_ROOT=$STATE_ROOT"
echo "RUNTIME_PROVENANCE=$RUNTIME_PROVENANCE"