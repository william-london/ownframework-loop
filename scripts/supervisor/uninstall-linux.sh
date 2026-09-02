#!/usr/bin/env bash
# Remove the per-user OwnFramework Loop systemd supervisor service.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
[[ "$(uname -s)" == "Linux" ]] || { echo "SUPERVISOR_UNINSTALL=REFUSED reason=linux_required" >&2; exit 2; }

SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-$(command -v systemctl || true)}"

STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/ownframework-loop"
DB="$STATE_ROOT/supervisor.sqlite3"
UNIT_DIR="${OFLOOP_SYSTEMD_USER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
UNIT_NAME="ownframework-loop-supervisor.service"
UNIT="$UNIT_DIR/$UNIT_NAME"
PROVENANCE="$STATE_ROOT/runtime-provenance.json"
SERVICE_ENV="$STATE_ROOT/service-env.json"
LEDGER_MARKER="$STATE_ROOT/ledger-incarnation.json"

if [[ ! -f "$DB" && ( -e "$UNIT" || -e "$PROVENANCE" || -e "$LEDGER_MARKER" ) ]]; then
  echo "SUPERVISOR_UNINSTALL=REFUSED reason=ledger_missing_runtime_dependency_unverifiable" >&2
  exit 13
fi
if [[ -f "$DB" && "${OFLOOP_ALLOW_SUPERVISOR_SWAP_WITH_ACTIVE_WORK:-0}" != "1" ]]; then
  set +e
  PROBE_OUT="$(PYTHONDONTWRITEBYTECODE=1 python3 -B "$ROOT/scripts/probe-supervisor-runtime-dependencies.py" "$DB" uninstall --allow-generation-migration 2>&1)"
  PROBE_RC=$?
  set -e
  if [[ "$PROBE_RC" -ne 0 ]]; then
    echo "SUPERVISOR_UNINSTALL=REFUSED $PROBE_OUT" >&2
    exit "$PROBE_RC"
  fi
fi
[[ -n "$SYSTEMCTL_BIN" && -x "$SYSTEMCTL_BIN" ]] || { echo "SUPERVISOR_UNINSTALL=REFUSED reason=systemctl_missing" >&2; exit 2; }
set +e
"$SYSTEMCTL_BIN" --user is-active --quiet "$UNIT_NAME" >/dev/null 2>&1
ACTIVE_RC=$?
set -e
case "$ACTIVE_RC" in
  0)
    if ! "$SYSTEMCTL_BIN" --user disable --now "$UNIT_NAME" >/dev/null 2>&1; then
      echo "SUPERVISOR_UNINSTALL=REFUSED reason=service_stop_failed" >&2
      exit 14
    fi
    ;;
  3|4)
    # rc=3 is inactive; rc=4 is manager-confirmed unknown/not-found. Both
    # prove there is no active process owned by this unit. If a unit artifact
    # still exists, disablement must also succeed before removal.
    if [[ -e "$UNIT" ]] && ! "$SYSTEMCTL_BIN" --user disable "$UNIT_NAME" >/dev/null 2>&1; then
      echo "SUPERVISOR_UNINSTALL=REFUSED reason=service_disable_failed" >&2
      exit 14
    fi
    ;;
  *)
    echo "SUPERVISOR_UNINSTALL=REFUSED reason=service_state_unknown status_rc=$ACTIVE_RC" >&2
    exit 14
    ;;
esac
if [[ ! -e "$UNIT" && ! -e "$PROVENANCE" ]]; then
  echo "SUPERVISOR_UNINSTALL=NOOP reason=service_artifacts_absent"
  echo "STATE_PRESERVED=yes"
  exit 0
fi
UNIT_BACKUP=""
if [[ -f "$UNIT" ]]; then
  UNIT_BACKUP="$(mktemp "$STATE_ROOT/.uninstall-unit-XXXXXX")"
  cp "$UNIT" "$UNIT_BACKUP"
  chmod 0600 "$UNIT_BACKUP"
fi
rm -f "$UNIT"
if ! "$SYSTEMCTL_BIN" --user daemon-reload >/dev/null 2>&1; then
  if [[ -n "$UNIT_BACKUP" ]]; then cp "$UNIT_BACKUP" "$UNIT"; chmod 0600 "$UNIT"; fi
  rm -f "$UNIT_BACKUP"
  echo "SUPERVISOR_UNINSTALL=REFUSED reason=daemon_reload_failed" >&2
  exit 14
fi
rm -f "$UNIT_BACKUP"
rm -f "$PROVENANCE" "$SERVICE_ENV"

cat <<EOF
SUPERVISOR_UNINSTALL=PASS
SERVICE_MANAGER=systemd-user
UNIT_NAME=$UNIT_NAME
STATE_PRESERVED=yes
EOF
