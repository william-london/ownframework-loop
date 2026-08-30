#!/usr/bin/env bash
# Remove the per-user OwnFramework Loop systemd supervisor service.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
[[ "$(uname -s)" == "Linux" ]] || { echo "SUPERVISOR_UNINSTALL=REFUSED reason=linux_required" >&2; exit 2; }

SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-$(command -v systemctl || true)}"
[[ -n "$SYSTEMCTL_BIN" && -x "$SYSTEMCTL_BIN" ]] || { echo "SUPERVISOR_UNINSTALL=REFUSED reason=systemctl_missing" >&2; exit 2; }

STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/ownframework-loop"
DB="$STATE_ROOT/supervisor.sqlite3"
UNIT_DIR="${OFLOOP_SYSTEMD_USER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
UNIT_NAME="ownframework-loop-supervisor.service"
UNIT="$UNIT_DIR/$UNIT_NAME"
PROVENANCE="$STATE_ROOT/runtime-provenance.json"

if [[ ! -e "$UNIT" && ! -e "$PROVENANCE" ]]; then
  echo "SUPERVISOR_UNINSTALL=NOOP reason=not_commissioned"
  exit 0
fi

if [[ ! -f "$DB" && "${OFLOOP_ALLOW_SUPERVISOR_SWAP_WITH_ACTIVE_WORK:-0}" != "1" ]]; then
  echo "SUPERVISOR_UNINSTALL=REFUSED reason=ledger_missing_live_work_unverifiable" >&2
  exit 11
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
"$SYSTEMCTL_BIN" --user disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
rm -f "$UNIT"
"$SYSTEMCTL_BIN" --user daemon-reload >/dev/null 2>&1 || true
rm -f "$PROVENANCE"

cat <<EOF
SUPERVISOR_UNINSTALL=PASS
SERVICE_MANAGER=systemd-user
UNIT_NAME=$UNIT_NAME
STATE_PRESERVED=yes
EOF
