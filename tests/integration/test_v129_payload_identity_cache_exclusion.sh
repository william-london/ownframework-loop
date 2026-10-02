#!/usr/bin/env bash
# Runtime payload identity must ignore the gitignored Ruff linter cache.
#
# Defect: `.ruff_cache/` is gitignored, and several canonical tests invoke
# ruff, which regenerates it on every suite run. Because it was absent from
# runtime_identity.IGNORED_DIR_NAMES, a gitignored tool cache silently joined
# the payload digest. The same source commit then produced a DIFFERENT digest
# before and after a test run, and `release_gate.sh` reported
# OF_LOOP_INSTALL_PARITY=MISMATCH for an unmodified tree (observed 2026-10-02).
#
# Required invariant:
#   digest_without_ruff_cache == digest_with_ruff_cache
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONDONTWRITEBYTECODE=1
TMP="$(mktemp -d -t ofloop-v129-payload-cache.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

python3 -B - "$TMP" <<'PY'
import os
import shutil
import sys
from pathlib import Path

root = Path(sys.argv[1])
os.environ["XDG_STATE_HOME"] = str(root / "state")

from ownframework_loop import runtime_identity

assert ".ruff_cache" in runtime_identity.IGNORED_DIR_NAMES, \
    "the gitignored ruff cache must be excluded from payload identity"

payload = root / "payload"
(payload / "lib").mkdir(parents=True)
(payload / "lib" / "core.py").write_text("VALUE = 1\n", encoding="utf-8")
baseline = runtime_identity.payload_tree_digest(payload)

# A generated, gitignored linter cache must not move payload identity.
cache = payload / ".ruff_cache"
(cache / "0.16.1").mkdir(parents=True)
(cache / ".gitignore").write_text("# ruff cache\n", encoding="utf-8")
(cache / "0.16.1" / "deadbeef").write_bytes(bytes(range(256)) * 4)
with_cache = runtime_identity.payload_tree_digest(payload)
assert with_cache == baseline, (
    f"ruff cache changed payload identity: {baseline} != {with_cache}"
)

# Pin non-vacuity: a real payload file MUST still change identity, and must
# still be seen (the exclusion is a directory exclusion, not a blanket skip).
(payload / "lib" / "extra.py").write_text("VALUE = 2\n", encoding="utf-8")
changed = runtime_identity.payload_tree_digest(payload)
assert changed != baseline, "a real payload change must alter identity"
shutil.rmtree(cache)
assert runtime_identity.payload_tree_digest(payload) == changed

# The cache must not be enumerated as payload at all.
seen = {p.relative_to(payload).as_posix()
        for p in runtime_identity._iter_payload_files(payload)}
assert not any(p.startswith(".ruff_cache") for p in seen), sorted(seen)

print("RUFF_CACHE_EXCLUDED_FROM_PAYLOAD=PASS")
print("PAYLOAD_IDENTITY_STILL_CONTENT_SENSITIVE=PASS")
print("PAYLOAD_IDENTITY_CACHE_EXCLUSION=PASS")
PY

echo "test_v129_payload_identity_cache_exclusion:PASS"
