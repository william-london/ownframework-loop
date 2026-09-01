#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PYTHONPATH="$ROOT/lib${PYTHONPATH:+:$PYTHONPATH}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

XDG_STATE_HOME="$tmp/state" python3 -m ownframework_loop.cli capabilities fingerprint >"$tmp/fp.json"
python3 - "$tmp/fp.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    doc=json.load(fh)
assert doc["ok"] is True
assert len(doc["runtime_fingerprint"]) == 64
PY

XDG_STATE_HOME="$tmp/state" python3 -m ownframework_loop.cli capabilities probe >"$tmp/probe.json"
python3 - "$tmp/probe.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    doc=json.load(fh)
assert doc["ok"] is True
assert doc["schema"] == "ownframework-loop-host-capability-inventory/v1"
names={x["name"] for x in doc["capabilities"]}
assert "toolchain.python" in names
assert "container.docker" in names
PY

echo "OF_LOOP_V091_CAPABILITY_CLI=PASS"
