#!/usr/bin/env bash
# Install OwnFramework Loop supervisor as a per-user systemd service on Linux.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
[[ "$(uname -s)" == "Linux" ]] || { echo "SUPERVISOR_INSTALL=REFUSED reason=linux_required" >&2; exit 2; }

PYTHON_BIN_RAW="${PYTHON_BIN:-$(command -v python3 || true)}"
OFLOOP_BIN_RAW="${OFLOOP_BIN:-$(command -v ofloop || true)}"
CLAUDE_BIN_RAW="${CLAUDE_BIN:-$(command -v claude || true)}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-$(command -v systemctl || true)}"

[[ -n "$PYTHON_BIN_RAW" && -x "$PYTHON_BIN_RAW" ]] || { echo "SUPERVISOR_INSTALL=REFUSED reason=python3_missing" >&2; exit 2; }
[[ -n "$OFLOOP_BIN_RAW" ]] || { echo "SUPERVISOR_INSTALL=REFUSED reason=core_not_installed" >&2; echo "hint: run './install.sh' first or set OFLOOP_BIN explicitly for development/testing" >&2; exit 2; }
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
SERVICE_ENTRYPOINT="$INSTALL_ROOT/scripts/launch-commissioned-supervisor.py"
DEPENDENCY_PROBE="$INSTALL_ROOT/scripts/probe-supervisor-runtime-dependencies.py"
[[ -x "$SERVICE_ENTRYPOINT" && -f "$DEPENDENCY_PROBE" ]] || {
  echo "SUPERVISOR_INSTALL=REFUSED reason=installed_payload_incomplete component=commissioned_service_entrypoint_or_probe" >&2
  exit 12
}

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
SERVICE_ENV="$STATE_ROOT/service-env.json"
LEDGER_MARKER="$STATE_ROOT/ledger-incarnation.json"
TXN_DIR="$STATE_ROOT/.supervisor-install-transaction"
SERVICE_PATH="/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin"
mkdir -p "$STATE_ROOT" "$UNIT_DIR"
chmod 0700 "$STATE_ROOT"

recover_pending_transaction() {
  [[ -d "$TXN_DIR" ]] || return 0
  echo "SUPERVISOR_INSTALL_RECOVERY=pending_transaction"
  if ! "$SYSTEMCTL_BIN" --user show-environment >/dev/null 2>&1; then
    echo "SUPERVISOR_INSTALL=REFUSED reason=transaction_recovery_manager_unavailable" >&2
    return 15
  fi
  set +e
  "$SYSTEMCTL_BIN" --user is-active --quiet "$UNIT_NAME" >/dev/null 2>&1
  local active_rc=$?
  set -e
  case "$active_rc" in
    0)
      if ! "$SYSTEMCTL_BIN" --user stop "$UNIT_NAME" >/dev/null 2>&1; then
        echo "SUPERVISOR_INSTALL=REFUSED reason=transaction_recovery_stop_failed" >&2
        return 15
      fi
      ;;
    3|4) ;;
    *)
      echo "SUPERVISOR_INSTALL=REFUSED reason=transaction_recovery_state_unknown status_rc=$active_rc" >&2
      return 15
      ;;
  esac
  if [[ -f "$TXN_DIR/had-unit" ]]; then
    cp "$TXN_DIR/old.unit" "$UNIT"; chmod 0600 "$UNIT"
  else
    rm -f "$UNIT"
  fi
  if [[ -f "$TXN_DIR/had-provenance" ]]; then
    cp "$TXN_DIR/old.provenance.json" "$PROVENANCE"; chmod 0600 "$PROVENANCE"
  else
    rm -f "$PROVENANCE"
  fi
  if [[ -f "$TXN_DIR/had-service-env" ]]; then
    cp "$TXN_DIR/old.service-env.json" "$SERVICE_ENV"; chmod 0600 "$SERVICE_ENV"
  else
    rm -f "$SERVICE_ENV"
  fi
  if ! "$SYSTEMCTL_BIN" --user daemon-reload >/dev/null 2>&1; then
    echo "SUPERVISOR_INSTALL=REFUSED reason=transaction_recovery_daemon_reload_failed" >&2
    return 15
  fi
  if [[ -f "$TXN_DIR/had-unit" ]]; then
    if ! "$SYSTEMCTL_BIN" --user enable --now "$UNIT_NAME" >/dev/null 2>&1; then
      echo "SUPERVISOR_INSTALL=REFUSED reason=transaction_recovery_start_failed" >&2
      return 15
    fi
  fi
  rm -rf "$TXN_DIR"
  echo "SUPERVISOR_INSTALL_RECOVERY=recovered_incomplete_transaction"
}
recover_pending_transaction

if [[ ( -f "$UNIT" || -f "$PROVENANCE" || -f "$LEDGER_MARKER" ) && ! -f "$DB" ]]; then
  echo "SUPERVISOR_INSTALL=REFUSED reason=runtime_dependency_ledger_missing" >&2
  exit 13
fi
if [[ ! -f "$DB" ]]; then
  PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$INSTALL_ROOT/lib" "$PYTHON_BIN" -B - "$DB" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import supervisor
with supervisor._connect(Path(sys.argv[1])):
    pass
PY
fi
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
if [[ ! -f "$LEDGER_MARKER" ]]; then
  LEDGER_MARKER="$LEDGER_MARKER" RUNTIME_GENERATION="$RUNTIME_GENERATION" "$PYTHON_BIN" -B - <<'PY'
import json, os
from pathlib import Path
path=Path(os.environ["LEDGER_MARKER"])
fd=os.open(path, os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o600)
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8", closefd=False) as fh:
        json.dump({
            "schema":"ownframework-loop-ledger-incarnation/v1",
            "created_runtime_generation":os.environ["RUNTIME_GENERATION"],
        }, fh, indent=2, sort_keys=True)
        fh.write("\n"); fh.flush(); os.fsync(fh.fileno())
finally:
    os.close(fd)
PY
fi
chmod 0600 "$LEDGER_MARKER"

IS_WSL=0
if [[ -r /proc/sys/kernel/osrelease ]] && grep -qi microsoft /proc/sys/kernel/osrelease; then IS_WSL=1; fi
USER_MANAGER_PERSISTENCE="unknown"
if [[ "$IS_WSL" == "1" ]]; then
  USER_MANAGER_PERSISTENCE="wsl-instance-bound"
elif command -v loginctl >/dev/null 2>&1; then
  LINGER="$(loginctl show-user "$UID" -p Linger --value 2>/dev/null || true)"
  if [[ "$LINGER" == "yes" ]]; then
    USER_MANAGER_PERSISTENCE="linger-enabled"
  elif [[ "$LINGER" == "no" ]]; then
    USER_MANAGER_PERSISTENCE="login-session-only"
  fi
fi

TMP_UNIT="$UNIT.tmp.$$"
TMP_PROV="$PROVENANCE.tmp.$$"
TMP_SERVICE_ENV="$SERVICE_ENV.tmp.$$"
rm -rf "$TXN_DIR"
mkdir -p "$TXN_DIR"
chmod 0700 "$TXN_DIR"
OLD_UNIT="$TXN_DIR/old.unit"
OLD_PROV="$TXN_DIR/old.provenance.json"
OLD_SERVICE_ENV="$TXN_DIR/old.service-env.json"
HAD_UNIT=0; HAD_PROV=0; HAD_SERVICE_ENV=0
[[ -f "$UNIT" ]] && { cp "$UNIT" "$OLD_UNIT"; chmod 0600 "$OLD_UNIT"; touch "$TXN_DIR/had-unit"; chmod 0600 "$TXN_DIR/had-unit"; HAD_UNIT=1; }
[[ -f "$PROVENANCE" ]] && { cp "$PROVENANCE" "$OLD_PROV"; chmod 0600 "$OLD_PROV"; touch "$TXN_DIR/had-provenance"; chmod 0600 "$TXN_DIR/had-provenance"; HAD_PROV=1; }
[[ -f "$SERVICE_ENV" ]] && { cp "$SERVICE_ENV" "$OLD_SERVICE_ENV"; chmod 0600 "$OLD_SERVICE_ENV"; touch "$TXN_DIR/had-service-env"; chmod 0600 "$TXN_DIR/had-service-env"; HAD_SERVICE_ENV=1; }
printf 'prepared\n' > "$TXN_DIR/state"
chmod 0600 "$TXN_DIR/state"

UNIT="$TMP_UNIT" PROVENANCE="$TMP_PROV" SERVICE_ENV="$TMP_SERVICE_ENV" STATE_ROOT="$STATE_ROOT" STATE_BASE="$STATE_BASE" \
DB="$DB" LEDGER_MARKER="$LEDGER_MARKER" SERVICE_ENTRYPOINT="$SERVICE_ENTRYPOINT" \
UNIT_NAME="$UNIT_NAME" PYTHON_BIN="$PYTHON_BIN" OFLOOP_BIN="$OFLOOP_BIN" CLAUDE_BIN="$CLAUDE_BIN" \
SERVICE_PATH="$SERVICE_PATH" INSTALL_ROOT="$INSTALL_ROOT" SOURCE_ROOT="$SOURCE_ROOT" SOURCE_HEAD="$SOURCE_HEAD" \
INSTALL_VERSION="$INSTALL_VERSION" RUNTIME_GENERATION="$RUNTIME_GENERATION" USER_MANAGER_PERSISTENCE="$USER_MANAGER_PERSISTENCE" IS_WSL="$IS_WSL" "$PYTHON_BIN" -B - <<'PY'
import json,os
from pathlib import Path

def q(value:str)->str:
    return '"' + value.replace("\\","\\\\").replace('"','\\"') + '"'

unit=Path(os.environ["UNIT"])
prov=Path(os.environ["PROVENANCE"])
service_env_path=Path(os.environ["SERVICE_ENV"])
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
service_env={}
if claude:
    env["OFLOOP_CLAUDE_BIN"]=claude
    env["OFLOOP_SERVICE_ENV_FILE"]=str(Path(os.environ["STATE_ROOT"]) / "service-env.json")
    # Linux Claude OAuth credentials are stored in one private credentials file
    # (or beneath CLAUDE_CONFIG_DIR). Re-open that exact file only; never the
    # entire ~/.claude configuration/session tree.
    config_dir = Path(os.environ.get("CLAUDE_CONFIG_DIR") or (Path.home() / ".claude"))
    credential_file = config_dir / ".credentials.json"
    if credential_file.is_file():
        env["OFLOOP_ADAPTER_AUTH_READ_PATHS"] = str(credential_file.resolve())
    for auth_var in (
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_OAUTH_REFRESH_TOKEN",
        "CLAUDE_CODE_OAUTH_SCOPES",
        "CLAUDE_CONFIG_DIR",
    ):
        value = os.environ.get(auth_var)
        if value:
            service_env[auth_var]=value
lines=[
    "[Unit]",
    "Description=OwnFramework Loop durable supervisor",
    "After=default.target",
    "",
    "[Service]",
    "Type=simple",
    "ExecStart=" + " ".join([
        q(os.environ["PYTHON_BIN"]), "-B", q(os.environ["SERVICE_ENTRYPOINT"]),
        "--db", q(os.environ["DB"]),
        "--ledger-marker", q(os.environ["LEDGER_MARKER"]),
        "--probe", q(str(Path(os.environ["INSTALL_ROOT"]) / "scripts" / "probe-supervisor-runtime-dependencies.py")),
        "--ofloop", q(os.environ["OFLOOP_BIN"]),
    ]),
    "Restart=always",
    "RestartSec=2",
    f"WorkingDirectory={str(Path.home())}",
]
for k,v in sorted(env.items()):
    lines.append(f"Environment={q(k+'='+v)}")
lines += ["StandardOutput=journal","StandardError=journal","","[Install]","WantedBy=default.target",""]

def write_private_text(path: Path, text: str) -> None:
    fd=os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8", closefd=False) as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
    finally:
        os.close(fd)

write_private_text(unit, "\n".join(lines))
write_private_text(service_env_path, json.dumps(service_env, indent=2, sort_keys=True)+"\n")
write_private_text(prov, json.dumps({
    "schema":"ownframework-loop-supervisor-runtime-provenance/v1",
    "service_manager":"systemd-user",
    "service_label":os.environ["UNIT_NAME"],
    "python_bin":os.environ["PYTHON_BIN"],
    "ofloop_bin":os.environ["OFLOOP_BIN"],
    "claude_bin":claude,
    "runtime_root":os.environ["INSTALL_ROOT"],
    "state_base":os.environ["STATE_BASE"],
    "state_root":os.environ["STATE_ROOT"],
    "ledger_incarnation_file":os.environ["LEDGER_MARKER"],
    "service_entrypoint":os.environ["SERVICE_ENTRYPOINT"],
    "source_root":os.environ.get("SOURCE_ROOT") or None,
    "source_head":os.environ.get("SOURCE_HEAD") or None,
    "ofloop_version":os.environ["INSTALL_VERSION"],
    "runtime_generation":os.environ["RUNTIME_GENERATION"],
    "journal_unit":os.environ["UNIT_NAME"],
    "service_env_file":str(Path(os.environ["STATE_ROOT"]) / "service-env.json") if claude else None,
    "user_manager_persistence":os.environ["USER_MANAGER_PERSISTENCE"],
    "wsl2":os.environ["IS_WSL"] == "1",
},indent=2,sort_keys=True)+"\n")
PY

if command -v systemd-analyze >/dev/null 2>&1; then
  VERIFY_UNIT="$TXN_DIR/$UNIT_NAME"
  cp "$TMP_UNIT" "$VERIFY_UNIT"
  chmod 0600 "$VERIFY_UNIT"
  if ! systemd-analyze verify "$VERIFY_UNIT" >/dev/null 2>&1; then
    rm -f "$TMP_UNIT" "$TMP_PROV" "$TMP_SERVICE_ENV" "$VERIFY_UNIT"
    rm -rf "$TXN_DIR"
    echo "SUPERVISOR_INSTALL=REFUSED reason=systemd_unit_invalid" >&2
    exit 14
  fi
  rm -f "$VERIFY_UNIT"
fi
test_abort_after_publication() {
  local stage="$1"
  if [[ "${OFLOOP_TEST_ABORT_AFTER_PUBLICATION:-}" == "$stage" ]]; then
    exit 97
  fi
}
mv "$TMP_UNIT" "$UNIT"
test_abort_after_publication "unit"
mv "$TMP_PROV" "$PROVENANCE"
test_abort_after_publication "provenance"
mv "$TMP_SERVICE_ENV" "$SERVICE_ENV"
test_abort_after_publication "service-env"
chmod 0600 "$UNIT" "$PROVENANCE" "$SERVICE_ENV"

rollback(){
  "$SYSTEMCTL_BIN" --user disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
  if [[ "$HAD_UNIT" == "1" ]]; then cp "$OLD_UNIT" "$UNIT"; chmod 0600 "$UNIT"; else rm -f "$UNIT"; fi
  if [[ "$HAD_PROV" == "1" ]]; then cp "$OLD_PROV" "$PROVENANCE"; chmod 0600 "$PROVENANCE"; else rm -f "$PROVENANCE"; fi
  if [[ "$HAD_SERVICE_ENV" == "1" ]]; then cp "$OLD_SERVICE_ENV" "$SERVICE_ENV"; chmod 0600 "$SERVICE_ENV"; else rm -f "$SERVICE_ENV"; fi
  "$SYSTEMCTL_BIN" --user daemon-reload >/dev/null 2>&1 || return 1
  if [[ "$HAD_UNIT" == "1" ]]; then
    "$SYSTEMCTL_BIN" --user enable --now "$UNIT_NAME" >/dev/null 2>&1 || return 1
  fi
  return 0
}
if ! "$SYSTEMCTL_BIN" --user daemon-reload ||
   ! "$SYSTEMCTL_BIN" --user enable --now "$UNIT_NAME"; then
  if rollback; then
    rm -rf "$TXN_DIR"
    rollback_state="restored_previous_service"
  else
    rollback_state="previous_service_restore_failed"
  fi
  rm -f "$TMP_UNIT" "$TMP_PROV" "$TMP_SERVICE_ENV"
  echo "SUPERVISOR_INSTALL=REFUSED reason=systemd_start_failed rollback=$rollback_state" >&2
  exit 14
fi
rm -rf "$TXN_DIR"

cat <<EOF
SUPERVISOR_INSTALL=PASS
SERVICE_MANAGER=systemd-user
UNIT=$UNIT
UNIT_NAME=$UNIT_NAME
OFLOOP_BIN=$OFLOOP_BIN
CLAUDE_BIN=${CLAUDE_BIN:-(none-idle-only)}
STATE_ROOT=$STATE_ROOT
RUNTIME_PROVENANCE=$PROVENANCE
SERVICE_ENV=$SERVICE_ENV
SOURCE_HEAD=${SOURCE_HEAD:-(not-a-git-checkout)}
OFLOOP_VERSION=$INSTALL_VERSION
RUNTIME_GENERATION=$RUNTIME_GENERATION
USER_MANAGER_PERSISTENCE=$USER_MANAGER_PERSISTENCE
WSL2=$IS_WSL
EOF
if [[ "$USER_MANAGER_PERSISTENCE" == "login-session-only" ]]; then
  echo "SUPERVISOR_INSTALL_WARNING=user_manager_linger_disabled_post_logout_persistence_unproven"
elif [[ "$USER_MANAGER_PERSISTENCE" == "unknown" ]]; then
  echo "SUPERVISOR_INSTALL_WARNING=user_manager_persistence_unproven"
elif [[ "$USER_MANAGER_PERSISTENCE" == "wsl-instance-bound" ]]; then
  echo "WSL_INSTANCE_LIFETIME=external_host_boundary"
fi
