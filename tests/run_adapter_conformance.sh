#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PYTHONPATH="$ROOT/lib${PYTHONPATH:+:$PYTHONPATH}"

python3 - <<'PY'
from pathlib import Path
from ownframework_loop.adapters import doctor_adapter, get_adapter, list_adapters

root = Path.cwd()
adapters = {a.adapter_id: a for a in list_adapters()}
assert set(adapters) == {"claude-code", "codex"}
assert adapters["claude-code"].maturity == "stable"
assert adapters["claude-code"].protocol_compatible is True
assert adapters["claude-code"].hardened is True
assert adapters["claude-code"].live_verified is True
assert adapters["codex"].maturity == "experimental"
assert adapters["codex"].protocol_compatible is True
assert adapters["codex"].hardened is False
assert adapters["codex"].live_verified is False
for adapter_id in ("claude-code", "codex"):
    failures = doctor_adapter(root, adapter_id)
    assert failures == [], (adapter_id, failures)

from ownframework_loop import guards
for command in (
    "ofloop spec approve /tmp/repo run-1",
    "./bin/ofloop spec approve /tmp/repo run-1",
    "python3 bin/ofloop spec approve /tmp/repo run-1",
    "python3 -m ownframework_loop.cli spec approve /tmp/repo run-1",
):
    result = guards.classify_bash_command(command)
    assert result["severity"] == "forbidden", (command, result)
PY

if grep -RInE '^\s*(from|import)\s+(anthropic|claude|openai|codex)(\.|\s|$)' lib/ownframework_loop --include='*.py'; then
  echo 'ADAPTER_CONFORMANCE=FAIL: vendor import found in deterministic core' >&2
  exit 1
fi

for skill in skills/spec/SKILL.md skills/build/SKILL.md skills/review/SKILL.md; do
  test -f "$skill"
done
for skill in .agents/skills/of-loop-{spec,build,review,status}/SKILL.md; do
  test -f "$skill"
done

printf 'ADAPTER_CONFORMANCE=PASS\n'
printf 'CLAUDE_ADAPTER=stable\n'
printf 'CODEX_ADAPTER=experimental_static_contract\n'
printf 'CODEX_LIVE_VERIFIED=no\n'
