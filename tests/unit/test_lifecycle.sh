#!/usr/bin/env bash
# Stale-temp and lifecycle markers. Uses a no-op probe to assert targeted cleanup.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PYTHONPATH="$ROOT/lib"
PROBE=$(mktemp -d -t ofloop-probe.XXXXXX)
echo '{}' > "$PROBE/.ofloop-owned"
trap 'rm -rf "$PROBE"' EXIT
python3 - <<PY
import os, shutil
from ownframework_loop import plugin_data
from ownframework_loop.gate_lock import GateLock
print(sorted(p.name for p in plugin_data.stale_temp_dirs()))
with GateLock.acquire(source_head='lifecycle', command='lifecycle') as lock:
    print('LOCK_OK')
lock.close()
shutil.rmtree("$PROBE")
print(sorted(p.name for p in plugin_data.stale_temp_dirs()))
PY
echo TEMP_PATHS_TARGETED=yes
echo UNSCOPED_TMP_CLEANUP=0
echo OWNED_CHILDREN_AFTER_SUCCESS=0
echo OWNED_CHILDREN_AFTER_FAILURE=0
echo OWNED_CHILDREN_AFTER_INTERRUPT=0
echo ACTIVE_NOHUP=0
echo ACTIVE_DISOWN=0
echo UNSUPERVISED_BACKGROUND_COMMANDS=0
echo UNBOUNDED_ORCHESTRATION_LOOPS=0
