#!/usr/bin/env bash
# Refresh an already-commissioned supervisor to a newly installed core payload.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
case "$(uname -s)" in
  Darwin) exec "$ROOT/scripts/supervisor/refresh-macos.sh" "$@" ;;
  Linux) exec "$ROOT/scripts/supervisor/refresh-linux.sh" "$@" ;;
  *) echo "SUPERVISOR_REFRESH=NOOP reason=unsupported_platform platform=$(uname -s)"; exit 0 ;;
esac
