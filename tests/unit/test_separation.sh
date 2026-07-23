#!/usr/bin/env bash
# Normal /of-loop:build and /of-loop:review skills must never invoke the
# plugin release gate. The shared CLI surface is the only contract.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
for skill in build review; do
  for forbidden in release_gate\.sh tests/run_all\.sh; do
    hits=$(grep -nE "$forbidden" "$ROOT/skills/$skill/SKILL.md" || true)
    if [[ -n "$hits" ]]; then
      echo "FAIL: $skill references plugin release orchestrator: $hits" >&2
      exit 1
    fi
  done
done
echo FULL_PLUGIN_GATE_FROM_NORMAL_BUILD=0
echo FULL_PLUGIN_GATE_FROM_NORMAL_REVIEW=0
