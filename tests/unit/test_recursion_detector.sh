#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PYTHONPATH="$ROOT/lib"
out=$(python3 -m ownframework_loop.static_checks "$ROOT")
printf '%s\n' "$out"
grep -q 'RELEASE_GATE_CALL_GRAPH=acyclic' <<<"$out"
grep -q 'TESTS_CALL_RELEASE_GATE=0' <<<"$out"
grep -q 'TESTS_CALL_VALIDATE=0' <<<"$out"
grep -q 'TESTS_CALL_RUN_ALL=0' <<<"$out"
grep -q 'REVERSE_ORCHESTRATOR_DEPENDENCIES=0' <<<"$out"
echo 'RECURSION_STATIC_DETECTOR=PASS'
