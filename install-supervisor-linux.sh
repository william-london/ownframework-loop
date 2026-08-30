#!/usr/bin/env bash
# Install OwnFramework Loop supervisor as a per-user systemd service on Linux.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
[[ "$(uname -s)" == "Linux" ]] || { echo "SUPERVISOR_INSTALL=REFUSED reason=linux_required" >&2; exit 2; }

PYTHON_BIN_RAW="${PYTHON_BIN:-$(command -v python3 || true)}"
OFLOOP_BIN_RAW="${OFLOOP_BIN:-$(command -v ofloop || true)}"
CLAUDE_BIN_RAW="${CLAUDE_BIN:-$(command -v claude || true)}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-$(command -v systemctl || true)}"

[[ -n "$PYTHON_BIN_RAW" && -x "$PYTHON_BIN_RAW" ]] || { echo "SUPERVISOR_INSTALL=REFUSED reason=python3_missing" >&2; exit 2; }
[[ -n "$OFLOOP_BIN_RAW" ]] || { echo "SUPERVISOR_INSTALL=REFUSED reason=core_not_installed" >&2; echo "hint: run 'bash install.sh' first or set OFLOOP_BIN explicitly for development/testing" >&2; exit 2; }
[[ -n "$SYSTEMCTL_BIN" && -x "$SYSTEMCTL_BIN" ]] || { echo "SUPERVISOR_INSTALL=REFUSED reason=systemctl_missing" >&2; exit 2; }

canon_path() {
  "$PYTHON_BIN_RAW" - "$1" <<'PY'
import sys
from pathlib import Path
print(Path(sys.argv[1]).expanduser().resolve(strict=False))
PY
}

PYTHON_BIN="$(canon_path "$PYTHON_BIN_RAW")"
OFLOOP_BIN="$(canon_path "$OFLOOP_BIN_RAW")"
[[ -x "$OFLOOP_BIN" ]] || { echo "SUPERVISOR_INSTALL=REFUSED reason=ofloop_not_executable path=$OFLOOP_BIN" >&2; exit 2; }

CLAUDE_BIN=""
if [[ -n "$CLAUDE_BIN_RAW" ]]; then
  CLAUDE_BIN="$(canon_path "$CLAUDE_BIN_RAW")"
  [[ -x "$CLAUDE_BIN" ]] || { echo "SUPERVISOR_INSTALL=REFUSED reason=claude_not_executable path=$CLAUDE_BIN" >&2; exit 2; }

  CLAUDE_VERSION="$("$CLAUDE_BIN" --version 2>/dev/null | head -n1 || true)"
  if ! "$PYTHON_BIN" - "$CLAUDE_VERSION" <<'PY'
import re,sys
m=re.search(r'(\d+)\.(\d+)\.(\d+)', sys.argv[1])
raise SystemExit(0 if m and tuple(map(int,m.groups())) >= (2,1,248) else 1)
PY
  then
    echo "SUPERVISOR_INSTALL=REFUSED reason=claude_version_unsupported minimum=2.1.248 actual=$CLAUDE_VERSION" >&2
    exit 6
  fi

  for dep in bwrap socat; do
    command -v "$dep" >/dev/null 2>&1 || {
      echo "SUPERVISOR_INSTALL=REFUSED reason=linux_sandbox_dependency_missing dependency=$dep" >&2
      echo "hint: install bubblewrap and socat before commissioning the Claude runner" >&2
      exit 6
    }
  done
  if ! bwrap --ro-bind / / true >/dev/null 2>&1; then
    echo "SUPERVISOR_INSTALL=REFUSED reason=bubblewrap_unusable" >&2
    echo "hint: on Ubuntu 24.04+ check kernel.apparmor_restrict_unprivileged_userns and configure the documented bwrap AppArmor profile" >&2
    exit 6
  fi
fi

INSTALL_ROOT="$("$PYTHON_BIN" - "$OFLOOP_BIN" <<'PY'
import sys
from pathlib import Path
print(Path(sys.argv[1]).resolve(strict=False).parents[1])
PY
)"
INSTALL_VERSION="$(PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$INSTALL_ROOT/lib" "$PYTHON_BIN" -B - <<'PY'
from ownframework_loop import __version__
print(__version__)
PY
)" || INSTALL_VERSION=""
[[ -n "$INSTALL_VERSION" ]] || { echo "SUPERVISOR_INSTALL=REFUSED reason=runtime_version_undetermined" >&2; exit 12; }

RUNTIME_GENERATION="$(PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$INSTALL_ROOT/lib" INSTALL_ROOT="$INSTALL_ROOT" INSTALL_VERSION="$INSTALL_VERSION" "$PYTHON_BIN" -B - <<'PY'
import os
from pathlib import Path
from ownframework_loop.runtime_identity import runtime_generation_for_root
print(runtime_generation_for_root(Path(os.environ["INSTALL_ROOT"]), os.environ["INSTALL_VERSION"]))
PY
)" || RUNTIME_GENERATION=""
[[ -n "$RUNTIME_GENERATION" ]] || { echo "SUPERVISOR_INSTALL=REFUSED reason=runtime_generation_undetermined" >&2; exit 12; }

SOURCE_ROOT_RAW="${SOURCE_ROOT_OVERRIDE:-$ROOT}"
SOURCE_ROOT="$(canon_path "$SOURCE_ROOT_RAW")"
SOURCE_HEAD=""
if git -C "$SOURCE_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  SOURCE_HEAD="$(git -C "$SOURCE_ROOT" rev-parse HEAD 2>/dev/null || true)"
fi

STATE_BASE="${XDG_STATE_HOME:-$HOME/.local/state}"
STATE_ROOT="$STATE_BASE/ownframework-loop"
DB="$STATE_ROOT/supervisor.sqlite3"
UNIT_DIR="${OFLOOP_SYSTEMD_USER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
UNIT_NAME="ownframework-loop-supervisor.service"
UNIT="$UNIT_DIR/$UNIT_NAME"
PROVENANCE="$STATE_ROOT/runtime-provenance.json"

if [[ ( -f "$UNIT" || -f "$PROVENANCE" ) && ! -f "$DB" && "${OFLOOP_ALLOW_RUNTIME_GENERATION_MIGRATION:-0}" != "1" ]]; then
  echo "SUPERVISOR_INSTALL=REFUSED reason=runtime_dependency_ledger_missing" >&2
  exit 13
fi

if [[ -f "$DB" ]]; then
  PROBE_ARGS=("$DB" "$RUNTIME_GENERATION")
  [[ "${OFLOOP_ALLOW_SUPERVISOR_SWAP_WITH_ACTIVE_WORK:-0}" == "1" ]] && PROBE_ARGS+=(--allow-active)
  [[ "${OFLOOP_ALLOW_RUNTIME_GENERATION_MIGRATION:-0}" == "1" ]] && PROBE_ARGS+=(--allow-generation-migration)
  set +e
  PROBE_OUT="$(PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$INSTALL_ROOT/lib" "$PYTHON_BIN" -B "$INSTALL_ROOT/scripts/probe-supervisor-runtime-dependencies.py" "${PROBE_ARGS[@]}" 2>&1)"
  PROBE_RC=$?
  set -e
  if [[ "$PROBE_RC" -ne 0 ]]; then
    echo "SUPERVISOR_INSTALL=REFUSED $PROBE_OUT" >&2
    exit "$PROBE_RC"
  fi
fi
SERVICE_PATH="/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin"
mkdir -p "$STATE_ROOT" "$UNIT_DIR"
TMP_UNIT="$UNIT.tmp.$$"
TMP_PROV="$PROVENANCE.tmp.$$"
OLD_UNIT="$STATE_ROOT/.systemd-unit.preinstall.$$"
OLD_PROV="$STATE_ROOT/.runtime-provenance.preinstall.$$"
HAD_UNIT=0; HAD_PROV=0
[[ -f "$UNIT" ]] && { cp "$UNIT" "$OLD_UNIT"; HAD_UNIT=1; }
[[ -f "$PROVENANCE" ]] && { cp "$PROVENANCE" "$OLD_PROV"; HAD_PROV=1; }

UNIT="$TMP_UNIT" PROVENANCE="$TMP_PROV" STATE_ROOT="$STATE_ROOT" STATE_BASE="$STATE_BASE" \
UNIT_NAME="$UNIT_NAME" PYTHON_BIN="$PYTHON_BIN" OFLOOP_BIN="$OFLOOP_BIN" CLAUDE_BIN="$CLAUDE_BIN" \
SERVICE_PATH="$SERVICE_PATH" INSTALL_ROOT="$INSTALL_ROOT" SOURCE_ROOT="$SOURCE_ROOT" SOURCE_HEAD="$SOURCE_HEAD" \
INSTALL_VERSION="$INSTALL_VERSION" RUNTIME_GENERATION="$RUNTIME_GENERATION" "$PYTHON_BIN" -B - <<'PY'
import json,os
from pathlib import Path

def q(value:str)->str:
    return '"' + value.replace("\\","\\\\").replace('"','\\"') + '"'

unit=Path(os.environ["UNIT"])
prov=Path(os.environ["PROVENANCE"])
env={
    "PATH":os.environ["SERVICE_PATH"],
    "PYTHONUNBUFFERED":"1",
    "PYTHONDONTWRITEBYTECODE":"1",
    "PYTHON_BIN":os.environ["PYTHON_BIN"],
    "OFLOOP_BIN":os.environ["OFLOOP_BIN"],
    "OFLOOP_RUNTIME_ROOT":os.environ["INSTALL_ROOT"],
}
state_base=os.environ.get("STATE_BASE","")
if state_base:
    env["XDG_STATE_HOME"]=state_base
claude=os.environ.get("CLAUDE_BIN") or None
if claude:
    env["OFLOOP_CLAUDE_BIN"]=claude
lines=[
    "[Unit]",
    "Description=OwnFramework Loop durable supervisor",
    "After=default.target",
    "",
    "[Service]",
    "Type=simple",
    f"ExecStart={q(os.environ['OFLOOP_BIN'])} supervisor serve",
    "Restart=always",
    "RestartSec=2",
    f"WorkingDirectory={q(str(Path.home()))}",
]
for k,v in sorted(env.items()):
    lines.append(f"Environment={q(k+'='+v)}")
lines += ["StandardOutput=journal","StandardError=journal","","[Install]","WantedBy=default.target",""]
unit.write_text("\n".join(lines),encoding="utf-8")
prov.write_text(json.dumps({
    "schema":"ownframework-loop-supervisor-runtime-provenance/v1",
    "service_manager":"systemd-user",
    "service_label":os.environ["UNIT_NAME"],
    "python_bin":os.environ["PYTHON_BIN"],
    "ofloop_bin":os.environ["OFLOOP_BIN"],
    "claude_bin":claude,
    "runtime_root":os.environ["INSTALL_ROOT"],
    "state_root":os.environ["STATE_ROOT"],
    "source_root":os.environ.get("SOURCE_ROOT") or None,
    "source_head":os.environ.get("SOURCE_HEAD") or None,
    "ofloop_version":os.environ["INSTALL_VERSION"],
    "runtime_generation":os.environ["RUNTIME_GENERATION"],
    "journal_unit":os.environ["UNIT_NAME"],
},indent=2,sort_keys=True)+"\n",encoding="utf-8")
PY

mv "$TMP_UNIT" "$UNIT"
mv "$TMP_PROV" "$PROVENANCE"
chmod 0600 "$PROVENANCE"

rollback(){
  "$SYSTEMCTL_BIN" --user disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
  if [[ "$HAD_UNIT" == "1" ]]; then mv "$OLD_UNIT" "$UNIT"; else rm -f "$UNIT"; fi
  if [[ "$HAD_PROV" == "1" ]]; then mv "$OLD_PROV" "$PROVENANCE"; else rm -f "$PROVENANCE"; fi
  "$SYSTEMCTL_BIN" --user daemon-reload >/dev/null 2>&1 || true
}
if ! "$SYSTEMCTL_BIN" --user daemon-reload ||
   ! "$SYSTEMCTL_BIN" --user enable --now "$UNIT_NAME"; then
  rollback
  rm -f "$OLD_UNIT" "$OLD_PROV" "$TMP_UNIT" "$TMP_PROV"
  echo "SUPERVISOR_INSTALL=REFUSED reason=systemd_start_failed" >&2
  exit 14
fi
rm -f "$OLD_UNIT" "$OLD_PROV"

cat <<EOF
SUPERVISOR_INSTALL=PASS
SERVICE_MANAGER=systemd-user
UNIT=$UNIT
UNIT_NAME=$UNIT_NAME
OFLOOP_BIN=$OFLOOP_BIN
CLAUDE_BIN=${CLAUDE_BIN:-(none-idle-only)}
STATE_ROOT=$STATE_ROOT
RUNTIME_PROVENANCE=$PROVENANCE
SOURCE_HEAD=${SOURCE_HEAD:-(not-a-git-checkout)}
OFLOOP_VERSION=$INSTALL_VERSION
RUNTIME_GENERATION=$RUNTIME_GENERATION
EOF
