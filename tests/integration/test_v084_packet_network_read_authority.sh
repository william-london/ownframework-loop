#!/usr/bin/env bash
# v0.8.4 frozen SPEC network-read authority -> dispatch -> Claude native sandbox.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

TMP_REPO="$(make_tmp_repo)"
trap 'rm -rf "$TMP_REPO"' EXIT
RID="$(make_approved_run_unapproved "$TMP_REPO" FEATURE low network-authority master)"
PACKET="$TMP_REPO/.ownframework-loop/$RID/WORK_PACKET.md"

python3 -B - "$PACKET" "$TMP_REPO" "$RID" <<'PY'
import json
import pathlib
import re
import sys

from ownframework_loop import execution_start, packet, schema_validate

packet_path = pathlib.Path(sys.argv[1])
repo = pathlib.Path(sys.argv[2])
run_id = sys.argv[3]
text = packet_path.read_text(encoding="utf-8")
match = re.search(r"\x60\x60\x60json\s*\n(.*?)\n\x60\x60\x60", text, re.S)
assert match, "packet metadata block missing"
meta = json.loads(match.group(1))
domains = ["files.pythonhosted.org", "pypi.org"]
meta["network_read_allowlist"] = domains
fence = chr(96) * 3
packet_path.write_text(
    fence + "json\n" + json.dumps(meta, indent=2) + "\n" + fence + "\n",
    encoding="utf-8",
)

assert packet.validate_packet_metadata(meta) == [], packet.validate_packet_metadata(meta)
if schema_validate.jsonschema is not None:
    assert schema_validate.validate_packet(meta) == [], schema_validate.validate_packet(meta)

for bad in (
    ["https://pypi.org"],
    ["pypi.org:443"],
    ["PyPI.org"],
    ["*.pypi.org"],
    ["pypi.org/path"],
    ["pypi.org", "pypi.org"],
):
    probe = dict(meta)
    probe["network_read_allowlist"] = bad
    handwritten = packet.validate_packet_metadata(probe)
    assert handwritten, (bad, handwritten)
    if schema_validate.jsonschema is not None:
        schema = schema_validate.validate_packet(probe)
        assert schema, (bad, schema)

execution_start.ensure_executable(
    canonical_repo=repo,
    run_id=run_id,
    actor="network-authority-test",
    binding_method="build_start",
)
print("PACKET_NETWORK_AUTHORITY=PASS")
PY

python3 -B - "$TMP_REPO" "$RID" <<'PY'
import pathlib
import sys

from ownframework_loop import dispatch, supervisor

repo = pathlib.Path(sys.argv[1])
run_id = sys.argv[2]
order = dispatch.claim_next(canonical_repo=repo, run_id=run_id)
assert order["decision"] == "BUILD", order
assert order["network_read_allowlist"] == [
    "files.pythonhosted.org",
    "pypi.org",
], order

settings = supervisor._semantic_worker_settings(
    canonical_repo=repo,
    run_id=run_id,
    role="builder",
    worktree=pathlib.Path(order["worktree"]),
    semantic_path=pathlib.Path(order["semantic_path"]),
    network_read_allowlist=order["network_read_allowlist"],
)
network = settings["sandbox"]["network"]
assert network["strictAllowlist"] is True, network
assert network["allowedDomains"] == [
    "files.pythonhosted.org",
    "pypi.org",
], network

empty = supervisor._semantic_worker_settings(
    canonical_repo=repo,
    run_id=run_id,
    role="builder",
    worktree=pathlib.Path(order["worktree"]),
    semantic_path=pathlib.Path(order["semantic_path"]),
)
assert empty["sandbox"]["network"]["allowedDomains"] == [], empty

print("DISPATCH_NATIVE_NETWORK_MAPPING=PASS")
PY

pass "frozen packet network authority maps exactly to native sandbox"
echo "V084_PACKET_NETWORK_READ_AUTHORITY=PASS"
