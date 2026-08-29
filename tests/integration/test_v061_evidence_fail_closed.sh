#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$TMP" <<'PY'
import os, sys
from pathlib import Path
from ownframework_loop import secrets_v2

root = Path(sys.argv[1])
small = root / "small.txt"
small.write_text("normal source\n", encoding="utf-8")
assert secrets_v2.scan_path_for_secrets_strict(small) == []

missing = root / "missing.txt"
try:
    secrets_v2.scan_path_for_secrets_strict(missing)
except secrets_v2.SecretScanIncomplete:
    pass
else:
    raise SystemExit("missing authoritative scan did not fail closed")

large = root / "large.txt"
large.write_bytes(b"A" * (secrets_v2.MAX_INPUT_BYTES + 1))
try:
    secrets_v2.scan_path_for_secrets_strict(large)
except secrets_v2.SecretScanIncomplete:
    pass
else:
    raise SystemExit("truncated authoritative scan did not fail closed")

secret = root / "secret.txt"
secret.write_text("token=sk-" + "A" * 24 + "\n", encoding="utf-8")
hits = secrets_v2.scan_path_for_secrets_strict(secret)
assert any(h.get("severity") == "hard" for h in hits)
assert all("match" not in h and "value" not in h for h in hits)
PY

# Static guards pin the authoritative callers to strict evidence.
grep -Fq 'scan_path_for_secrets_strict(abs_path)' "$ROOT_DIR/lib/ownframework_loop/build_finalize.py"
grep -Fq 'scan_path_for_secrets_strict(abs_path)' "$ROOT_DIR/lib/ownframework_loop/review_finalize.py"
grep -Fq 'git diff --name-only failed' "$ROOT_DIR/lib/ownframework_loop/review_finalize.py"
if grep -Fq 'if diff_r.returncode == 0 else []' "$ROOT_DIR/lib/ownframework_loop/review_finalize.py"; then
  fail "review diff failure still collapses to empty evidence"
fi

echo "V061_EVIDENCE_FAIL_CLOSED=PASS"
