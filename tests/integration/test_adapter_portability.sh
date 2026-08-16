#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

python3 - <<'PY'
from pathlib import Path
import re
root = Path.cwd()
portable = [root / ".agents/skills" / name / "SKILL.md" for name in ("of-loop-spec", "of-loop-build", "of-loop-review", "of-loop-status")]
for path in portable:
    text = path.read_text()
    assert text.startswith("---\n"), path
    assert re.search(r"^name:\s+[a-z0-9-]+$", text, re.MULTILINE), path
    assert re.search(r"^description:\s+.+$", text, re.MULTILINE), path
    assert "ofloop" in text.lower(), path
    assert ".claude-plugin" not in text.lower(), path
    assert "of-loop@ownframework" not in text.lower(), path
for expected in ("spec", "build", "review"):
    text = (root / "skills" / expected / "SKILL.md").read_text()
    assert f"name: {expected}" in text
    assert "user-invocable: true" in text
PY

printf 'ADAPTER_PORTABILITY=PASS\n'
