#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

./bin/ofloop adapter list >/tmp/ofloop-adapters.json
grep -F '"adapter_id": "claude-code"' /tmp/ofloop-adapters.json >/dev/null
grep -F '"maturity": "stable"' /tmp/ofloop-adapters.json >/dev/null
grep -F '"adapter_id": "generic-cli"' /tmp/ofloop-adapters.json >/dev/null
grep -F '"maturity": "portable"' /tmp/ofloop-adapters.json >/dev/null
grep -F '"adapter_id": "codex"' /tmp/ofloop-adapters.json >/dev/null
grep -F '"maturity": "experimental"' /tmp/ofloop-adapters.json >/dev/null

./bin/ofloop adapter doctor claude-code | grep -F '"doctor": "PASS"'
./bin/ofloop adapter doctor generic-cli | tee /tmp/generic-doctor.json | grep -F '"doctor": "PASS"'
grep -F '"protocol_compatible": true' /tmp/generic-doctor.json >/dev/null
grep -F '"hardened": false' /tmp/generic-doctor.json >/dev/null

if ./bin/ofloop adapter doctor codex >/tmp/codex-doctor.json 2>&1; then
  echo 'FAIL: unverified Codex doctor must require explicit override' >&2
  exit 1
fi
grep -F 'not live verified' /tmp/codex-doctor.json >/dev/null
./bin/ofloop adapter doctor codex --allow-unverified | grep -F '"doctor": "PASS"'

if ./bin/ofloop adapter show unknown >/tmp/unknown-adapter.json 2>&1; then
  echo 'FAIL: unknown adapter should be rejected' >&2
  exit 1
fi
grep -F '"error": "unknown adapter"' /tmp/unknown-adapter.json >/dev/null

printf 'ADAPTER_CLI=PASS\n'
