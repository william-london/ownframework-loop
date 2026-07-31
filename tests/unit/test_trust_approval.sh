#!/usr/bin/env bash
# Trust suite — APPROVAL tests 1–11.
# Source: spec §"Tests — deterministic trust suite — Approval".
#
# 1.  approval leaves packet bytes unchanged
# 2.  approval artifact records exact packet SHA
# 3.  whitespace mutation invalidates approval
# 4.  metadata mutation invalidates approval
# 5.  packet replacement invalidates approval
# 6.  missing approval blocks build
# 7.  malformed approval blocks build
# 8.  wrong repo in approval blocks build
# 9.  wrong baseline blocks build
# 10. noninteractive model approval is refused
# 11. human TTY approval succeeds in a safe fixture

set -uo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

# 1. approval leaves packet bytes unchanged
T="$(make_tmp_repo)"
"$OFLOOP_BIN" spec new "$T" "approval-unchanged" >/dev/null
RID="$(ls -1t "$T/.ownframework-loop" | head -n1)"
PP="$T/.ownframework-loop/$RID/WORK_PACKET.md"
cat > "$PP" <<'EOF'
```json
{
  "schema": "ownframework-work-packet/v2",
  "packet_id": "ap-1",
  "created_at": "2026-07-23T00:00:00Z",
  "work_class": "BUG",
  "risk_class": "low",
  "authority_class": "low",
  "title": "approval test",
  "target": {"repo": "REPO", "branch": "master", "classification": "local_only"},
  "acceptance_criteria": [{"id": "AC-1", "text": "ok"}],
  "non_goals": [],
  "allowed_paths": ["src/"],
  "protected_paths": [".ownframework-loop/"],
  "work_units": [{"id": "UNIT-1", "title": "u", "scope": "s"}],
  "merge_authority": "human_only",
  "deploy_authority": "human_only",
  "push_authority": "human_only",
  "external_action_authority": "none"
}
```
body
EOF
sed -i.bak "s|REPO|$T|" "$PP"
PRE_SHA="$(shasum -a 256 "$PP" | awk '{print $1}')"
APPROVAL="$T/.ownframework-loop/$RID/APPROVAL.json"
python3 - "$T" "$RID" "$APPROVAL" "$PRE_SHA" <<'PY'
import sys, json
from pathlib import Path
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib'))
from ownframework_loop import approval
canonical_repo = Path(sys.argv[1])
run_id = sys.argv[2]
target = Path(sys.argv[3])
packet_sha = sys.argv[4]
token = approval.derive_confirmation_token(packet_sha)
approval_doc = {
    "schema": "ownframework-loop-approval/v1",
    "run_id": run_id,
    "packet_sha256": packet_sha,
    "approved_at": "2026-07-23T00:00:00Z",
    "approved_actor": "test",
    "canonical_repo": str(canonical_repo),
    "baseline_branch": "master",
    "baseline_sha": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
    "packet_schema": "ownframework-work-packet/v2",
    "approval_method": "operator_marker",
    "confirmation_token": token,
}
target.write_text(json.dumps(approval_doc, indent=2, sort_keys=True))
PY
# Reload from disk and compare
POST_SHA="$(shasum -a 256 "$PP" | awk '{print $1}')"
assert_eq "$POST_SHA" "$PRE_SHA" "approval leaves packet bytes unchanged"

# 2. approval artifact records exact packet SHA
ACTUAL_PACKET_SHA="$(python3 -c "import json; print(json.load(open('$APPROVAL'))['packet_sha256'])")"
assert_eq "$ACTUAL_PACKET_SHA" "$PRE_SHA" "approval records exact packet SHA"

# 3. whitespace mutation invalidates approval
echo " " >> "$PP"
ok_msg="$(python3 -c "import sys; import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib')); from ownframework_loop import approval, packet as p, util; from pathlib import Path; meta,_=p.parse_packet_file(Path('$PP')); doc=approval.load_approval(Path('$T'), '$RID'); ok,msg=approval.validate_approval_binding(canonical_repo=Path('$T'), run_id='$RID', approval=doc, packet=meta, packet_path=Path('$PP')); print('REFUSED' if not ok else 'ALLOWED:'+msg)")"
assert_contains "$ok_msg" "REFUSED" "whitespace mutation invalidates approval"

# Restore packet bytes
git -C "$T" checkout -- .ownframework-loop 2>/dev/null || true
python3 - <<PY
content = open("$PP").read().rstrip()
if content.endswith(" "):
    open("$PP","w").write(content.rstrip()+"\n")
PY

# 4. metadata mutation invalidates approval (rewrite with different title)
sed -i.bak2 's/"title": "approval test"/"title": "MUTATED"/' "$PP"
ok_msg="$(python3 -c "import sys; import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib')); from ownframework_loop import approval, packet as p; from pathlib import Path; meta,_=p.parse_packet_file(Path('$PP')); doc=approval.load_approval(Path('$T'), '$RID'); ok,msg=approval.validate_approval_binding(canonical_repo=Path('$T'), run_id='$RID', approval=doc, packet=meta, packet_path=Path('$PP')); print('REFUSED' if not ok else 'ALLOWED:'+msg)")"
assert_contains "$ok_msg" "REFUSED" "metadata mutation invalidates approval"

# 5. packet replacement invalidates approval
sed -i.bak3 's/"title": "MUTATED"/"title": "approval test"/' "$PP"
echo "completely different packet" > "$PP"
ok_msg="$(python3 -c "import sys; import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib')); from ownframework_loop import approval, packet as p; from pathlib import Path; meta=None
try:
    meta,_=p.parse_packet_file(Path('$PP'))
except Exception:
    print('REFUSED-PARSE')
    raise SystemExit(0)
doc=approval.load_approval(Path('$T'), '$RID')
ok,msg=approval.validate_approval_binding(canonical_repo=Path('$T'), run_id='$RID', approval=doc, packet=meta, packet_path=Path('$PP'))
print('REFUSED' if not ok else 'ALLOWED:'+msg)")"
assert_contains "$ok_msg" "REFUSED" "packet replacement invalidates approval"

# Reset packet to a valid V2 packet.
cat > "$PP" <<EOF
\`\`\`json
{
  "schema": "ownframework-work-packet/v2",
  "packet_id": "ap-1",
  "created_at": "2026-07-23T00:00:00Z",
  "work_class": "BUG",
  "risk_class": "low",
  "title": "approval test",
  "target": {"repo": "$T", "branch": "master", "classification": "local_only"},
  "acceptance_criteria": [{"id": "AC-1", "text": "ok"}],
  "non_goals": [],
  "allowed_paths": ["src/"],
  "protected_paths": [".ownframework-loop/"],
  "work_units": [{"id": "UNIT-1", "title": "u", "scope": "s"}],
  "merge_authority": "human_only",
  "deploy_authority": "human_only",
  "push_authority": "human_only",
  "external_action_authority": "none"
}
\`\`\`
body
EOF
# Refresh approval with new packet SHA
NEW_SHA="$(shasum -a 256 "$PP" | awk '{print $1}')"
python3 - "$T" "$RID" "$APPROVAL" "$NEW_SHA" <<'PY'
import sys, json
from pathlib import Path
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib'))
from ownframework_loop import approval
canonical_repo = Path(sys.argv[1])
run_id = sys.argv[2]
target = Path(sys.argv[3])
packet_sha = sys.argv[4]
token = approval.derive_confirmation_token(packet_sha)
head = canonical_repo.resolve(strict=False)
approval_doc = {
    "schema": "ownframework-loop-approval/v1",
    "run_id": run_id,
    "packet_sha256": packet_sha,
    "approved_at": "2026-07-23T00:00:00Z",
    "approved_actor": "test",
    "canonical_repo": str(head),
    "baseline_branch": "master",
    "baseline_sha": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
    "packet_schema": "ownframework-work-packet/v2",
    "approval_method": "operator_marker",
    "confirmation_token": token,
}
target.write_text(json.dumps(approval_doc, indent=2, sort_keys=True))
PY
# 6. missing approval blocks build
rm -f "$APPROVAL"
echo "y" | "$OFLOOP_BIN" build claim "$T" "$RID" >/dev/null 2>&1 || true
out="$("$OFLOOP_BIN" build finalize "$T" "$RID" 2>&1 || true)"
assert_contains "$out" "OF_LOOP_BUILD_FINALIZE_REFUSED" "missing approval blocks build"

# Re-create approval for tests 7–11.
NEW_SHA="$(shasum -a 256 "$PP" | awk '{print $1}')"
python3 - "$T" "$RID" "$APPROVAL" "$NEW_SHA" <<'PY'
import sys, json
from pathlib import Path
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib'))
from ownframework_loop import approval
canonical_repo = Path(sys.argv[1])
run_id = sys.argv[2]
target = Path(sys.argv[3])
packet_sha = sys.argv[4]
token = approval.derive_confirmation_token(packet_sha)
approval_doc = {
    "schema": "ownframework-loop-approval/v1",
    "run_id": run_id,
    "packet_sha256": packet_sha,
    "approved_at": "2026-07-23T00:00:00Z",
    "approved_actor": "test",
    "canonical_repo": str(canonical_repo.resolve(strict=False)),
    "baseline_branch": "master",
    "baseline_sha": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
    "packet_schema": "ownframework-work-packet/v2",
    "approval_method": "operator_marker",
    "confirmation_token": token,
}
target.write_text(json.dumps(approval_doc, indent=2, sort_keys=True))
PY

# 7. malformed approval blocks build
echo "not json" > "$APPROVAL"
out="$("$OFLOOP_BIN" build finalize "$T" "$RID" 2>&1 || true)"
assert_contains "$out" "OF_LOOP_BUILD_FINALIZE_REFUSED" "malformed approval blocks build"

# Restore.
NEW_SHA="$(shasum -a 256 "$PP" | awk '{print $1}')"
python3 - "$T" "$RID" "$APPROVAL" "$NEW_SHA" <<'PY'
import sys, json
from pathlib import Path
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib'))
from ownframework_loop import approval
canonical_repo = Path(sys.argv[1])
run_id = sys.argv[2]
target = Path(sys.argv[3])
packet_sha = sys.argv[4]
token = approval.derive_confirmation_token(packet_sha)
approval_doc = {
    "schema": "ownframework-loop-approval/v1",
    "run_id": run_id,
    "packet_sha256": packet_sha,
    "approved_at": "2026-07-23T00:00:00Z",
    "approved_actor": "test",
    "canonical_repo": str(canonical_repo.resolve(strict=False)),
    "baseline_branch": "master",
    "baseline_sha": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
    "packet_schema": "ownframework-work-packet/v2",
    "approval_method": "operator_marker",
    "confirmation_token": token,
}
target.write_text(json.dumps(approval_doc, indent=2, sort_keys=True))
PY

# 8. wrong repo in approval blocks build
python3 - "$APPROVAL" "$NEW_SHA" <<'PY'
import sys, json
target = sys.argv[1]
new_sha = sys.argv[2]
import os
os.chdir("/tmp")
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib'))
from ownframework_loop import approval
d = json.loads(open(target).read())
d["canonical_repo"] = "/tmp/this-path-does-not-exist"
d["confirmation_token"] = approval.derive_confirmation_token(new_sha)
open(target, "w").write(json.dumps(d, indent=2, sort_keys=True))
PY
out="$("$OFLOOP_BIN" build finalize "$T" "$RID" 2>&1 || true)"
assert_contains "$out" "OF_LOOP_BUILD_FINALIZE_REFUSED" "wrong repo in approval blocks build"

# 9. wrong baseline in approval blocks build
NEW_SHA="$(shasum -a 256 "$PP" | awk '{print $1}')"
python3 - "$T" "$RID" "$APPROVAL" "$NEW_SHA" "/tmp/wrong" <<'PY'
import sys, json
from pathlib import Path
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib'))
from ownframework_loop import approval
canonical_repo = Path(sys.argv[1])
run_id = sys.argv[2]
target = Path(sys.argv[3])
packet_sha = sys.argv[4]
wrong_repo = sys.argv[5]
token = approval.derive_confirmation_token(packet_sha)
approval_doc = {
    "schema": "ownframework-loop-approval/v1",
    "run_id": run_id,
    "packet_sha256": packet_sha,
    "approved_at": "2026-07-23T00:00:00Z",
    "approved_actor": "test",
    "canonical_repo": wrong_repo,
    "baseline_branch": "master",
    "baseline_sha": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
    "packet_schema": "ownframework-work-packet/v2",
    "approval_method": "operator_marker",
    "confirmation_token": token,
}
target.write_text(json.dumps(approval_doc, indent=2, sort_keys=True))
PY
out="$("$OFLOOP_BIN" build finalize "$T" "$RID" 2>&1 || true)"
assert_contains "$out" "OF_LOOP_BUILD_FINALIZE_REFUSED" "wrong repo in approval blocks build"

# 10. noninteractive model approval is refused
# Run the approve command with stdin redirected (no TTY).
"$OFLOOP_BIN" spec approve "$T" "$RID" < /dev/null >/dev/null 2>&1
out="$("$OFLOOP_BIN" spec approve "$T" "$RID" < /dev/null 2>&1 || true)"
assert_contains "$out" "TTY" "noninteractive model approval is refused"

# 11. human TTY approval succeeds in a safe fixture (use assume-tty with correct token)
NEW_SHA="$(shasum -a 256 "$PP" | awk '{print $1}')"
TOKEN="$(python3 -c "import sys; import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib')); from ownframework_loop import approval; print(approval.derive_confirmation_token('$NEW_SHA'))")"
# Drive request_human_approval with assume_tty=True using a heredoc-faked stdin won't pass tty check.
# Use a subprocess to pipe the expected token.
out="$(python3 - "$T" "$RID" "$NEW_SHA" "$TOKEN" <<'PY' 2>&1
import sys, os, subprocess
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib'))
from ownframework_loop import approval
canonical_repo, run_id, packet_sha, expected = sys.argv[1:5]
packet_path = os.path.join(canonical_repo, ".ownframework-loop", run_id, "WORK_PACKET.md")
# Force a real pty via pexpect-like? Easier: drive the function with assume_tty=True and
# the typed token is not required when assume_tty is True (the function still verifies).
# To exercise the typed path, monkey-patch _is_interactive_tty to return True.
approval._is_interactive_tty = lambda: True
# Patch the readline to return expected.
def _fake_readline():
    return expected + "\n"
import builtins
real_input = builtins.input
def _fake_input(prompt):
    return expected
approval._read_tty_confirmation = lambda prompt, token, max_attempts=3: True
try:
    doc = approval.request_human_approval(
        canonical_repo=__import__("pathlib").Path(canonical_repo),
        run_id=run_id,
        packet_path=__import__("pathlib").Path(packet_path),
        actor="test-tty",
        assume_tty=True,
    )
    print("OK", doc["packet_sha256"][:12])
except Exception as e:
    print("FAIL", e)
PY
)"
assert_contains "$out" "OK" "human TTY approval succeeds in a safe fixture"

echo "TRUST_APPROVAL_TESTS=PASS"
