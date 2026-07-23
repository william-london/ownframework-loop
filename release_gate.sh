#!/usr/bin/env bash
# Stable OwnFramework Loop release-gate entry point.
# The Python runtime owns the lock, children, timeouts, receipts, and cleanup.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export PYTHONPATH="$HERE/lib${PYTHONPATH:+:$PYTHONPATH}"
exec python3 -m ownframework_loop.release_gate_runtime "$@"
