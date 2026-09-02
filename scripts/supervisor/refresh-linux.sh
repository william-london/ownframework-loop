#!/usr/bin/env bash
# Refresh an already-commissioned Linux systemd-user supervisor to core payload.
set -euo pipefail
CORE_ROOT="${1:?installed core root required}"
SOURCE_ROOT="${2:?source root required}"
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/ownframework-loop"
UNIT_DIR="${OFLOOP_SYSTEMD_USER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
UNIT="$UNIT_DIR/ownframework-loop-supervisor.service"
PROVENANCE="$STATE_ROOT/runtime-provenance.json"

if [[ "${OFLOOP_SKIP_SUPERVISOR_REFRESH:-0}" == "1" ]]; then
  echo "SUPERVISOR_REFRESH=SKIPPED reason=operator_opt_out"
  exit 0
fi
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "SUPERVISOR_REFRESH=NOOP reason=non_linux"
  exit 0
fi
if [[ ! -f "$UNIT" && ! -f "$PROVENANCE" ]]; then
  echo "SUPERVISOR_REFRESH=NOOP reason=not_commissioned"
  exit 0
fi
INSTALLER="$CORE_ROOT/scripts/supervisor/install-linux.sh"
OFLOOP="$CORE_ROOT/bin/ofloop"
[[ -x "$INSTALLER" && -x "$OFLOOP" ]] || {
  echo "SUPERVISOR_REFRESH=REFUSED reason=installed_payload_incomplete" >&2
  exit 9
}
SOURCE_ROOT_OVERRIDE="$SOURCE_ROOT" OFLOOP_BIN="$OFLOOP" bash "$INSTALLER"
echo "SUPERVISOR_REFRESH=PASS"
