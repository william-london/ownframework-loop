#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$TMP" <<'PY'
import json
import os
import sys
from pathlib import Path

from ownframework_loop import integrity, secrets_v2, state

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

# Once STATE has been durably event-bound, deletion is tampering rather than a
# return to the pre-creation state. This specifically exercises load_verified,
# the authoritative read used by semantic/execution decisions.
repo = root / "state-delete-repo"
repo.mkdir()
run_id = "run-state-delete"
state.run_dir(repo, run_id).mkdir(parents=True)
state.save(repo, run_id, state.initial_state(run_id))
assert integrity.last_recorded_state_sha(state.events_path(repo, run_id))
state.state_path(repo, run_id).unlink()
try:
    state.load_verified(repo, run_id)
except integrity.TamperingDetected as exc:
    assert "missing but recorded sha exists" in str(exc), exc
else:
    raise SystemExit("deleted event-bound STATE.json did not fail closed")

# The generic artifact verifier preserves optional-before-publication behavior,
# but a missing artifact becomes an integrity failure once its digest exists in
# EVENTS. Use a synthetic chain with no event_chain_sha256 field so this unit is
# focused strictly on artifact-presence semantics.
artifact = root / "BUILD_RECEIPT.json"
artifact.write_text('{"ok":true}\n', encoding="utf-8")
events = root / "artifact-events.log"
digest = integrity.sha256_file(artifact)
events.write_text(
    json.dumps({"BUILD_RECEIPT.json_sha256": digest}) + "\n",
    encoding="utf-8",
)
ok, failures = integrity.verify_all_artifacts(
    {"BUILD_RECEIPT.json": artifact}, events
)
assert ok and not failures, failures
artifact.unlink()
ok, failures = integrity.verify_all_artifacts(
    {"BUILD_RECEIPT.json": artifact}, events
)
assert not ok and any("missing but recorded sha exists" in row for row in failures), failures

never_published = root / "REVIEW_VERDICT.json"
ok, failures = integrity.verify_all_artifacts(
    {"REVIEW_VERDICT.json": never_published}, events
)
assert ok and not failures, failures
PY

# Static guards pin the authoritative callers to strict evidence.
grep -Fq 'scan_path_for_secrets_strict(abs_path)' "$ROOT_DIR/lib/ownframework_loop/build_finalize.py"
grep -Fq 'scan_path_for_secrets_strict(abs_path)' "$ROOT_DIR/lib/ownframework_loop/review_finalize.py"
grep -Fq 'git diff --name-only failed' "$ROOT_DIR/lib/ownframework_loop/review_finalize.py"
if grep -Fq 'if diff_r.returncode == 0 else []' "$ROOT_DIR/lib/ownframework_loop/review_finalize.py"; then
  fail "review diff failure still collapses to empty evidence"
fi

echo "V061_EVIDENCE_FAIL_CLOSED=PASS"
