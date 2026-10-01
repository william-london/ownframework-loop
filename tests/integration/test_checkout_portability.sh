#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail() {
  printf 'CHECKOUT_PORTABILITY=FAIL\n' >&2
  printf 'DETAIL=%s\n' "$1" >&2
  exit 1
}

SELF='tests/integration/test_checkout_portability.sh'

# Inspect tracked files in a source checkout and payload files in an installed
# runtime. Git errors in a checkout are failures, never an empty search result.
python3 -B - "$ROOT" "$SELF" <<'PY'
import fnmatch
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
self_path = sys.argv[2]
needles = (
    b"/Users/mr.mrs.london",
    b"/Users/mr.mrs.london/projects/plugins/ownframework-loop",
    b"/tmp/v031_setup_run.py",
)

if (root / ".git").exists():
    probe = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "--is-inside-work-tree"],
        capture_output=True,
        text=True,
    )
    if probe.returncode or probe.stdout.strip() != "true":
        raise SystemExit(f"FAIL: source checkout Git metadata is unusable: {probe.stderr.strip()}")
    listing = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z"],
        check=True,
        capture_output=True,
    )
    paths = [Path(name.decode()) for name in listing.stdout.split(b"\0") if name]
    source_kind = "source checkout"
else:
    paths = [p.relative_to(root) for p in root.rglob("*") if p.is_file() and not p.is_symlink()]
    source_kind = "installed payload"

def excluded(rel: Path) -> bool:
    value = rel.as_posix()
    return (
        value == self_path
        or value.startswith("docs/history/")
        or ".git" in rel.parts
        or ".worktrees" in rel.parts
        or "__pycache__" in rel.parts
        or ".ruff_cache" in rel.parts
        or ".pytest_cache" in rel.parts
        or ".mypy_cache" in rel.parts
        or "logs" in rel.parts
    )

failures = 0
for rel in paths:
    if excluded(rel):
        continue
    path = root / rel
    if path.is_symlink() or not path.is_file():
        continue
    try:
        content = path.read_bytes()
    except OSError as exc:
        print(f"FAIL: cannot inspect {rel}: {exc}", file=sys.stderr)
        failures += 1
        continue
    if b"\0" in content:
        continue
    lines = content.splitlines()
    for number, line in enumerate(lines, 1):
        for needle in needles:
            if needle in line:
                print(f"{rel}:{number}: {line.decode(errors='replace')}", file=sys.stderr)
                failures += 1

if failures:
    raise SystemExit(f"FAIL: {failures} portability violation(s) in {source_kind}")

for rel in paths:
    value = rel.as_posix()
    if rel.parent.as_posix() != ".github/workflows":
        continue
    if any(fnmatch.fnmatch(rel.name, pattern) for pattern in (
        "*v040*fix*.yml", "*v040*fix*.yaml", "*v040*autofix*.yml", "*v040*autofix*.yaml"
    )):
        raise SystemExit(f"FAIL: temporary repair workflow still present: {value}")

print(f"PORTABILITY_FILE_SET={source_kind}")
PY

# The tracked PROGRAM fixture helper that replaced the historical /tmp dependency
# must remain part of the checkout.
test -f tests/helpers/setup_program_run.py || fail 'tracked PROGRAM fixture helper missing'

printf 'CHECKOUT_PORTABILITY=PASS\n'
