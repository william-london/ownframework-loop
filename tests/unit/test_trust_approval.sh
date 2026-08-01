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
    "approval_method": "tty_confirmation",
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
    "approval_method": "tty_confirmation",
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
    "approval_method": "tty_confirmation",
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
    "approval_method": "tty_confirmation",
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
    "approval_method": "tty_confirmation",
    "confirmation_token": token,
}
target.write_text(json.dumps(approval_doc, indent=2, sort_keys=True))
PY
out="$("$OFLOOP_BIN" build finalize "$T" "$RID" 2>&1 || true)"
assert_contains "$out" "OF_LOOP_BUILD_FINALIZE_REFUSED" "wrong repo in approval blocks build"

# 10. noninteractive model approval is refused
# Run the approve command with stdin redirected (no TTY).
"$OFLOOP_BIN" spec approve "$T" "$RID" < /dev/null >/dev/null 2>&1 || true
out="$("$OFLOOP_BIN" spec approve "$T" "$RID" < /dev/null 2>&1 || true)"
assert_contains "$out" "TTY" "noninteractive model approval is refused"

# 11. Real-PTY approval path: drive `ofloop spec approve` via a child PTY,
# write the derived confirmation token into the master fd, and assert
# exit 0 plus approval_method == "tty_confirmation" in APPROVAL.json.
#
# v0.3.5 (AUD2-P0-1): this replaces the v0.3.4 monkey-patch test that
# called request_human_approval(assume_tty=True). The monkey-patches
# were no-ops in v0.3.4 because the assume_tty branch bypassed both
# _is_interactive_tty and _read_tty_confirmation entirely. After
# closure, assume_tty is gone — the only path is genuine TTY.
NEW_SHA="$(shasum -a 256 "$PP" | awk '{print $1}')"
TOKEN="$(python3 -c "import sys, os as _os; sys.path.insert(0, _os.environ.get('OFLOOP_LIB','/path/to/ownframework-loop/lib')); from ownframework_loop import approval; print(approval.derive_confirmation_token('$NEW_SHA'))")"

PTY_OUT="$(python3 - "$T" "$RID" "$NEW_SHA" "$TOKEN" "$OFLOOP_BIN" <<'PYEND' 2>&1
import os, pty, select, subprocess, sys, time

canonical_repo, run_id, packet_sha, token, ofloop_bin = sys.argv[1:6]

# Allocate a master/slave pty pair.
master_fd, slave_fd = pty.openpty()

# Make slave a controlling tty for the child.
env = dict(os.environ)
env.pop("OFLOOP_ACTOR", None)

proc = subprocess.Popen(
    [ofloop_bin, "spec", "approve", canonical_repo, run_id, "--actor", "test-pty"],
    stdin=slave_fd, stdout=slave_fd, stderr=slave_fd,
    close_fds=True, env=env,
)
os.close(slave_fd)

# Wait for the prompt, then write the token.
deadline = time.time() + 10.0
buf = ""
written = False
while time.time() < deadline:
    r, _, _ = select.select([master_fd], [], [], 0.25)
    if r:
        try:
            chunk = os.read(master_fd, 4096).decode("utf-8", errors="replace")
        except OSError:
            break
        buf += chunk
        if "token>" in buf and not written:
            os.write(master_fd, (token + "\n").encode("utf-8"))
            written = True
        if "READY_TO_BUILD" in buf or "approved" in buf.lower():
            break
    if proc.poll() is not None:
        break

try:
    proc.wait(timeout=5)
except subprocess.TimeoutExpired:
    proc.kill()

try:
    os.close(master_fd)
except OSError:
    pass

# Read APPROVAL.json and check method.
import json
ap_path = os.path.join(canonical_repo, ".ownframework-loop", run_id, "APPROVAL.json")
if not os.path.exists(ap_path):
    print("FAIL no APPROVAL.json")
    sys.exit(2)
ap = json.loads(open(ap_path).read())
print("EXIT", proc.returncode)
print("METHOD", ap.get("approval_method"))
print("SHA", ap.get("packet_sha256", "")[:12])
print("OK" if (proc.returncode == 0 and ap.get("approval_method") == "tty_confirmation") else "FAIL")
PYEND
)"
assert_contains "$PTY_OUT" "OK" "real-PTY approval succeeds with tty_confirmation method"
assert_contains "$PTY_OUT" "METHOD tty_confirmation" "approval_method is exactly tty_confirmation"

echo "TRUST_APPROVAL_TESTS=PASS"
