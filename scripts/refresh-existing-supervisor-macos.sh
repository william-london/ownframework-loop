#!/usr/bin/env bash
# Refresh an already-commissioned macOS Loop supervisor to an installed cache.
# This helper never creates a supervisor implicitly. It is safe to call after
# every managed install: non-macOS and never-commissioned hosts are NOOP.
set -euo pipefail

CACHE_ROOT="${1:?installed cache root required}"
SOURCE_ROOT="${2:?source root required}"
LABEL="com.ownframework.loop-supervisor"
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/ownframework-loop"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PROVENANCE="$STATE_ROOT/runtime-provenance.json"

if [[ "${OFLOOP_SKIP_SUPERVISOR_REFRESH:-0}" == "1" ]]; then
  echo "SUPERVISOR_REFRESH=SKIPPED reason=operator_opt_out"
  exit 0
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "SUPERVISOR_REFRESH=NOOP reason=non_macos"
  exit 0
fi

if [[ ! -f "$PLIST" && ! -f "$PROVENANCE" ]]; then
  echo "SUPERVISOR_REFRESH=NOOP reason=not_commissioned"
  exit 0
fi

INSTALLER="$CACHE_ROOT/install-supervisor-macos.sh"
OFLOOP="$CACHE_ROOT/bin/ofloop"
if [[ ! -x "$INSTALLER" || ! -x "$OFLOOP" ]]; then
  echo "SUPERVISOR_REFRESH=REFUSED reason=installed_payload_incomplete" >&2
  exit 9
fi

SOURCE_ROOT_OVERRIDE="$SOURCE_ROOT" OFLOOP_BIN="$OFLOOP" bash "$INSTALLER"
echo "SUPERVISOR_REFRESH=PASS"
