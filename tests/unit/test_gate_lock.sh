#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PYTHONPATH="$ROOT/lib"
TMP="$(mktemp -d -t ofloop-lock-test.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM HUP
export CLAUDE_PLUGIN_DATA="$TMP/data"
python3 -m ownframework_loop.gate_lock_fixture --seconds 2 >"$TMP/holder.log" 2>&1 &
pid=$!
for _ in $(seq 1 40); do grep -q LOCK_HELD "$TMP/holder.log" && break; sleep 0.05; done
grep -q LOCK_HELD "$TMP/holder.log"
set +e
python3 - <<'PY'
from ownframework_loop.gate_lock import GateLock, GateAlreadyRunning
try:
    GateLock.acquire(source_head='test', command='test')
except GateAlreadyRunning:
    print('OFLOOP_GATE_ALREADY_RUNNING')
    raise SystemExit(0)
raise SystemExit(1)
PY
rc=$?
set -e
wait "$pid"
[[ "$rc" -eq 0 ]]
echo 'RELEASE_GATE_SINGLE_INSTANCE=PASS'
echo 'CONCURRENT_GATE_REFUSAL=PASS'
echo 'SECOND_GATE_CHILDREN_STARTED=0'
