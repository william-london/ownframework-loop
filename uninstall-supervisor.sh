#!/usr/bin/env bash
# Platform-neutral durable supervisor uninstaller.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IF_COMMISSIONED=0
if [[ "${1:-}" == "--if-commissioned" ]]; then IF_COMMISSIONED=1; shift; fi
case "$(uname -s)" in
  Darwin)
    SIGNAL_A="$HOME/Library/LaunchAgents/com.ownframework.loop-supervisor.plist"
    SIGNAL_B="${XDG_STATE_HOME:-$HOME/.local/state}/ownframework-loop/runtime-provenance.json"
    if [[ "$IF_COMMISSIONED" == "1" && ! -e "$SIGNAL_A" && ! -e "$SIGNAL_B" ]]; then
      echo "SUPERVISOR_UNINSTALL=NOOP reason=not_commissioned"
      exit 0
    fi
    exec bash "$ROOT/uninstall-supervisor-macos.sh" "$@"
    ;;
  Linux)
    UNIT_DIR="${OFLOOP_SYSTEMD_USER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
    SIGNAL_A="$UNIT_DIR/ownframework-loop-supervisor.service"
    SIGNAL_B="${XDG_STATE_HOME:-$HOME/.local/state}/ownframework-loop/runtime-provenance.json"
    if [[ "$IF_COMMISSIONED" == "1" && ! -e "$SIGNAL_A" && ! -e "$SIGNAL_B" ]]; then
      echo "SUPERVISOR_UNINSTALL=NOOP reason=not_commissioned"
      exit 0
    fi
    exec bash "$ROOT/uninstall-supervisor-linux.sh" "$@"
    ;;
  *) echo "SUPERVISOR_UNINSTALL=REFUSED reason=unsupported_platform platform=$(uname -s)" >&2; exit 2 ;;
esac
