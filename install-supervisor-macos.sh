#!/usr/bin/env bash
# Install the OwnFramework Loop durable supervisor as a per-user macOS launchd service.
#
# v0.6.1 hardening: this installer resolves the runtime executables
# (Python, ofloop, Claude) to canonical absolute paths and persists
# them as the single source of truth in runtime-provenance.json AND
# in the generated launchd plist EnvironmentVariables. The supervisor
# subprocess MUST therefore execute the exact same Claude binary that
# was commissioned; PATH resolution is no longer trusted.
#
# When Claude is genuinely unavailable the install is intentionally
# idle-only: claude_bin is recorded as null, OFLOOP_CLAUDE_BIN is
# omitted from the plist (NOT written with a bogus value), and the
# service runs without semantic workers until Claude is installed.
#
# STATE_ROOT is computed once via ${XDG_STATE_HOME:-$HOME/.local/state}
# and passed consistently to the plist generator for stdout, stderr,
# and runtime-provenance.json paths. The plist generator never
# silently recomputes a different root.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

# 1. Resolve runtime executables to canonical absolute paths.
#    Python and ofloop are mandatory. Claude is optional; when absent,
#    the install is intentionally idle-only and OFLOOP_CLAUDE_BIN is
#    omitted from the plist.
PYTHON_BIN_RAW="${PYTHON_BIN:-$(command -v python3 || true)}"
OFLOOP_BIN_RAW="${OFLOOP_BIN:-$ROOT/bin/ofloop}"
CLAUDE_BIN_RAW="${CLAUDE_BIN:-$(command -v claude || true)}"

# Canonicalize paths via python3 (always available alongside this script).
# `realpath` may not be installed on macOS; use Python for portability.
canon_path() {
  # $1 = input path; $2 = python interpreter to use (avoids relying on
  # the outer-scope $PYTHON_BIN, which is not yet assigned when we
  # canonicalize PYTHON_BIN itself).
  local py="$2"
  [[ -x "$py" ]] || { echo ""; return 1; }
  "$py" - "$1" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1]).expanduser().resolve(strict=False)
print(str(p))
PY
}

if [[ -z "$PYTHON_BIN_RAW" ]]; then
  echo "SUPERVISOR_INSTALL=REFUSED reason=python3_missing" >&2
  exit 2
fi
PYTHON_BIN="$(canon_path "$PYTHON_BIN_RAW" "${PYTHON_BIN_RAW}")"
if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "SUPERVISOR_INSTALL=REFUSED reason=python3_not_executable path=$PYTHON_BIN" >&2
  exit 2
fi

OFLOOP_BIN="$(canon_path "$OFLOOP_BIN_RAW" "$PYTHON_BIN")"
if [[ ! -x "$OFLOOP_BIN" ]]; then
  echo "SUPERVISOR_INSTALL=REFUSED reason=ofloop_not_executable path=$OFLOOP_BIN" >&2
  exit 2
fi

CLAUDE_BIN=""
if [[ -n "$CLAUDE_BIN_RAW" ]]; then
  CLAUDE_BIN="$(canon_path "$CLAUDE_BIN_RAW" "$PYTHON_BIN")"
  if [[ ! -x "$CLAUDE_BIN" ]]; then
    echo "SUPERVISOR_INSTALL=REFUSED reason=claude_not_executable path=$CLAUDE_BIN" >&2
    exit 2
  fi
fi

# 2. Source provenance: derive from the current source checkout so the
#    runtime record can later be cross-checked against the Git HEAD
#    that backed the installed ofloop binary.
SOURCE_ROOT="$(canon_path "$ROOT" "$PYTHON_BIN")"
SOURCE_HEAD=""
if git -C "$SOURCE_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  SOURCE_HEAD="$(git -C "$SOURCE_ROOT" rev-parse HEAD 2>/dev/null || true)"
fi

# 3. Derive ofloop version from the canonical machine source so the
#    provenance carries the same string the running interpreter exposes.
OFLOOP_VERSION=""
if PYTHONPATH="$SOURCE_ROOT/lib" "$PYTHON_BIN" -c "from ownframework_loop import __version__; print(__version__)" >/dev/null 2>&1; then
  OFLOOP_VERSION="$(PYTHONPATH="$SOURCE_ROOT/lib" "$PYTHON_BIN" -c "from ownframework_loop import __version__; print(__version__)")"
fi

LABEL="com.ownframework.loop-supervisor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# 4. Compute STATE_ROOT ONCE and pass it consistently to the plist
#    generator. The generator never silently recomputes a different
#    root (e.g. via Path.home() / ".local" / "state").
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/ownframework-loop"
STDOUT_LOG="$STATE_ROOT/supervisor.stdout.log"
STDERR_LOG="$STATE_ROOT/supervisor.stderr.log"
RUNTIME_PROVENANCE="$STATE_ROOT/runtime-provenance.json"

# 5. Build a minimal PATH for the noninteractive service so it can find
#    Python, ofloop, claude, git, jq, etc. Persisted so a future
#    operator can reproduce the environment exactly.
SERVICE_PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
[[ -d "/opt/homebrew/bin" ]] && SERVICE_PATH="/opt/homebrew/bin:$SERVICE_PATH"
[[ -d "$HOME/.local/bin" ]] && SERVICE_PATH="$HOME/.local/bin:$SERVICE_PATH"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "SUPERVISOR_INSTALL=REFUSED reason=macos_required" >&2
  exit 2
fi

mkdir -p "$HOME/Library/LaunchAgents" "$STATE_ROOT"

# 6. Generate plist + provenance atomically. The python block is the
#    sole owner of both artifacts; STATE_ROOT, CLAUDE_BIN, OFLOOP_BIN,
#    PYTHON_BIN, and SERVICE_PATH are passed as env vars so the
#    generator cannot drift from the bash-side computation.
PLIST="$PLIST" \
RUNTIME_PROVENANCE="$RUNTIME_PROVENANCE" \
STATE_ROOT="$STATE_ROOT" \
STDOUT_LOG="$STDOUT_LOG" \
STDERR_LOG="$STDERR_LOG" \
PYTHON_BIN="$PYTHON_BIN" \
OFLOOP_BIN="$OFLOOP_BIN" \
CLAUDE_BIN="$CLAUDE_BIN" \
SERVICE_PATH="$SERVICE_PATH" \
SOURCE_ROOT="$SOURCE_ROOT" \
SOURCE_HEAD="$SOURCE_HEAD" \
OFLOOP_VERSION="$OFLOOP_VERSION" \
LABEL="$LABEL" \
"$PYTHON_BIN" - <<'PY'
import json, os, plistlib, sys
from pathlib import Path

plist = Path(os.environ["PLIST"])
provenance_path = Path(os.environ["RUNTIME_PROVENANCE"])
state_root = os.environ["STATE_ROOT"]
stdout_log = os.environ["STDOUT_LOG"]
stderr_log = os.environ["STDERR_LOG"]
python_bin = os.environ["PYTHON_BIN"]
ofloop_bin = os.environ["OFLOOP_BIN"]
claude_bin = os.environ.get("CLAUDE_BIN") or None
service_path = os.environ["SERVICE_PATH"]
source_root = os.environ.get("SOURCE_ROOT") or None
source_head = os.environ.get("SOURCE_HEAD") or None
ofloop_version = os.environ.get("OFLOOP_VERSION") or None
label = os.environ["LABEL"]

env_vars = {
    "PATH": service_path,
    "PYTHONUNBUFFERED": "1",
    "PYTHONDONTWRITEBYTECODE": "1",
    "PYTHON_BIN": python_bin,
    "OFLOOP_BIN": ofloop_bin,
    "OFLOOP_PLUGIN_ROOT": str(Path(ofloop_bin).resolve(strict=False).parent.parent),
}
# CRITICAL: only export OFLOOP_CLAUDE_BIN when a Claude binary was
# actually commissioned. Writing a bogus path here would let the
# supervisor execute the wrong Claude binary later (or fail to start
# semantic workers). Omitting it preserves the supported idle-only
# installation behavior — the service runs but no semantic workers
# can spawn until Claude is installed and the installer is re-run.
if claude_bin:
    env_vars["OFLOOP_CLAUDE_BIN"] = claude_bin

payload = {
    "Label": label,
    "ProgramArguments": [ofloop_bin, "supervisor", "serve"],
    "EnvironmentVariables": env_vars,
    "RunAtLoad": True,
    "KeepAlive": True,
    "ProcessType": "Background",
    "ThrottleInterval": 5,
    "StandardOutPath": stdout_log,
    "StandardErrorPath": stderr_log,
    "WorkingDirectory": str(Path.home()),
}
plist.parent.mkdir(parents=True, exist_ok=True)
with plist.open("wb") as f:
    plistlib.dump(payload, f, sort_keys=True)

provenance = {
    "schema": "ownframework-loop-supervisor-runtime-provenance/v1",
    "service_label": label,
    "python_bin": python_bin,
    "ofloop_bin": ofloop_bin,
    # claude_bin is recorded exactly as the plist will export: the
    # canonical absolute path when commissioned, or null when this
    # install is intentionally idle-only. The provenance and the
    # plist EnvironmentVariables MUST agree byte-for-byte.
    "claude_bin": claude_bin,
    "service_path": service_path,
    "plist": str(plist),
    "state_root": state_root,
    "stdout_log": stdout_log,
    "stderr_log": stderr_log,
    "source_root": source_root,
    "source_head": source_head,
    "ofloop_version": ofloop_version,
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
echo "CLAUDE_BIN=${CLAUDE_BIN:-(none-idle-only)}"
echo "STATE_ROOT=$STATE_ROOT"
echo "RUNTIME_PROVENANCE=$RUNTIME_PROVENANCE"
echo "SOURCE_HEAD=${SOURCE_HEAD:-(not-a-git-checkout)}"
echo "OFLOOP_VERSION=${OFLOOP_VERSION:-(unknown)}"
