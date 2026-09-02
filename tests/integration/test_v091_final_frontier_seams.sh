#!/usr/bin/env bash
# v0.9.1 final-frontier seam regressions:
#   S-01 authoritative secret scan never follows symlinks; a changed
#        symlink is scanned as its candidate bytes (the target path text)
#   S-02 a vanished/unreadable capability binding fails closed as
#        CapabilityBindingError, and read_resolution_receipt translates
#        binding failures into CapabilityResolutionError for callers
#   S-03 external_action_guard honors the OFLOOP_PLUGIN_ROOT fallback
#        exactly like its sibling guards
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib"
export PYTHONDONTWRITEBYTECODE=1

python3 -B - "$ROOT_DIR" <<'PY'
import json
import os
import sys
import tempfile
from pathlib import Path

from ownframework_loop import secrets_v2
from ownframework_loop import capabilities
from ownframework_loop import capability_binding

root = Path(sys.argv[1])
tmp = Path(tempfile.mkdtemp(prefix="ofloop-final-frontier-"))

# ------------------------------------------------------------------
# S-01: symlinked changed paths are scanned as their candidate bytes.
# ------------------------------------------------------------------
secret_store = tmp / "host-secrets"
secret_store.mkdir()
pem_target = secret_store / "id_rsa"
private_key_label = "OPENSSH " + "PRIVATE KEY"
pem_target.write_text(
    "-----BEGIN " + private_key_label + "-----\nabcdef\n"
    "-----END " + private_key_label + "-----\n",
    encoding="utf-8",
)

scan_dir = tmp / "candidate"
scan_dir.mkdir()

# A symlink to an external PEM must NOT be scanned through to the target:
# the candidate bytes are the link target path, which carries no key material.
link = scan_dir / "data.bin"
os.symlink(str(pem_target), str(link))
findings = secrets_v2.scan_path_for_secrets_strict(link)
assert not any(
    f.get("pattern_id") == "pem_private_key" for f in findings
), findings
findings_r = secrets_v2.scan_path_for_secrets_redacted(link)
assert not any(
    f.get("pattern_id") == "pem_private_key" for f in findings_r
), findings_r

# The symlink's candidate bytes (the target text) ARE scanned: a target
# path containing a hard pattern is detected.
aws_access_id = "AKIA" + "0123456789ABCDEF"
token_dir = tmp / (aws_access_id + "-store")
token_dir.mkdir()
token_link = scan_dir / "lookup"
os.symlink(str(token_dir / (aws_access_id + ".txt")), str(token_link))
token_findings = secrets_v2.scan_path_for_secrets_strict(token_link)
assert any(
    f.get("pattern_id") == "aws_access_key" for f in token_findings
), token_findings

# POSIX symlink targets are arbitrary filesystem bytes, not necessarily
# UTF-8. The candidate-byte reader must round-trip those bytes exactly
# instead of leaking UnicodeEncodeError on surrogate-escaped target text.
if os.name == "posix":
    raw_link = os.fsencode(scan_dir / "raw-link")
    raw_target = b"raw-\xff-target"
    os.symlink(raw_target, raw_link)
    raw_path = Path(os.fsdecode(raw_link))
    assert secrets_v2._read_candidate_bytes(raw_path) == raw_target

# Plain secret-bearing files still block.
plain = scan_dir / "creds.txt"
plain.write_text("key = sk-" + "ant-api03-" + "a" * 24 + "\n", encoding="utf-8")
plain_findings = secrets_v2.scan_path_for_secrets_strict(plain)
assert any(
    f.get("pattern_id") == "anthropic_api_key" for f in plain_findings
), plain_findings
print("S01_SECRET_SCAN_SYMLINK_CANDIDATE_BYTES=yes")

# ------------------------------------------------------------------
# S-02: vanished capability binding fails closed with the module's own
# error type, and receipt reads translate it for supervisor callers.
# ------------------------------------------------------------------
repo = tmp / "binding-repo"
run_id = "run-binding-missing"
run_dir = repo / ".ownframework-loop" / run_id
run_dir.mkdir(parents=True)

try:
    capability_binding._read(capability_binding.binding_path(repo, run_id))
    raise AssertionError("missing binding must fail closed")
except capability_binding.CapabilityBindingError:
    pass
except Exception as exc:  # noqa: BLE001
    raise AssertionError(
        f"missing binding escaped as {type(exc).__name__} instead of CapabilityBindingError"
    ) from exc

receipt_path = capabilities.resolution_receipt_path(repo, run_id, "builder", "attempt-x")
receipt_path.parent.mkdir(parents=True, exist_ok=True)
receipt_path.write_text(
    json.dumps({
        "run_id": run_id,
        "role": "builder",
        "attempt_id": "attempt-x",
        "requested_runner_profile": {"name": "default", "provider": "claude-code"},
    }),
    encoding="utf-8",
)
os.chmod(receipt_path, 0o600)
try:
    capabilities.read_resolution_receipt(repo, run_id, "builder", "attempt-x")
    raise AssertionError("receipt with missing binding must fail closed")
except capabilities.CapabilityResolutionError as exc:
    assert "run binding" in str(exc), str(exc)
except Exception as exc:  # noqa: BLE001
    raise AssertionError(
        f"receipt binding failure escaped as {type(exc).__name__} instead of CapabilityResolutionError"
    ) from exc
print("S02_BINDING_FAILURE_CONTRACT_CLOSED=yes")
PY

# ------------------------------------------------------------------
# S-03: external_action_guard fallback root. With ONLY OFLOOP_PLUGIN_ROOT
# set, the guard must reach its classifier stage (structured exit-0
# decision), not the exit-2 missing-root refusal its siblings avoid.
# ------------------------------------------------------------------
SANDBOX="$(mktemp -d)"
cleanup_sandbox() { rm -rf "$SANDBOX"; }
trap cleanup_sandbox EXIT

ACTIVE_ROOT="$SANDBOX/active-loop"
mkdir -p "$ACTIVE_ROOT/.ownframework-loop/run-FRONTIER"
echo '{"state":"BUILDING"}' > "$ACTIVE_ROOT/.ownframework-loop/run-FRONTIER/STATE.json"
OFLOOP_LIB="$LIB_DIR" python3 -B - "$ACTIVE_ROOT" <<'PYMK' >/dev/null
import os, sys
sys.path.insert(0, os.environ["OFLOOP_LIB"])
from ownframework_loop import role_context
role_context.enter_semantic_role(
    canonical_repo=sys.argv[1],
    run_id="run-FRONTIER",
    role="builder",
)
PYMK

HOOK="$ROOT_DIR/hooks/external_action_guard.sh"
PAYLOAD="$(python3 -B -c 'import json; print(json.dumps({"tool_name":"WebFetch","tool_input":{"url":"https://example.invalid"},"cwd":"'"$ACTIVE_ROOT"'"}))')"

set +e
OUT="$(env -u CLAUDE_PLUGIN_ROOT OFLOOP_PLUGIN_ROOT="$ROOT_DIR" bash "$HOOK" <<<"$PAYLOAD" 2>"$SANDBOX/stderr.txt")"
RC=$?
set -e
if [[ "$RC" -eq 2 ]] && grep -q "not provided" "$SANDBOX/stderr.txt"; then
  echo "  FAIL: external_action_guard ignored OFLOOP_PLUGIN_ROOT fallback (exit 2 missing-root refusal)" >&2
  exit 1
fi
if [[ "$RC" -ne 0 ]]; then
  echo "  FAIL: external_action_guard exited $RC under OFLOOP_PLUGIN_ROOT fallback" >&2
  exit 1
fi
echo "S03_EXTERNAL_GUARD_PLUGIN_ROOT_FALLBACK=yes"

echo "OK: test_v091_final_frontier_seams.sh"
