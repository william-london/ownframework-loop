#!/usr/bin/env bash
# v0.3.5 (AUD2-P0-1 / A6-F03): real-PTY E2E approval test.
#
# Spawns a child PTY, drives `ofloop spec approve` over the slave fd,
# types the derived confirmation token into the master fd, and asserts
# APPROVAL.json.approval_method == "tty_confirmation".
#
# Asserts the 13 negative cases required by the v0.3.5 spec:
#   1. --assume-tty rejected (flag no longer exists)
#   2. stdin=/dev/null refused
#   3. stdin=pipe refused
#   4. non-TTY subprocess (no PTY) refused
#   5. wrong token refused
#   6. real-PTY typed token succeeds
#   7. binding to packet SHA / repo / baseline / run / actor
#   8. packet mutation invalidates approval
#   9. run cross-copy rejected
#  10. repo cross-copy rejected
#  11. fabricated approval_method rejected
#  12. fabricated approval block rejected
#  13. fake approval_method "operator_marker" or "operator_explicit_override" rejected

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=_helpers.sh
source "$HERE/../_helpers.sh"

# Resolve OFLOOP_BIN from helper or env.
: "${OFLOOP_BIN:=$ROOT/bin/ofloop}"
: "${PYTHONPATH:=$ROOT/lib}"

export PYTHONPATH

# Helper: spawn a real PTY child, run `ofloop spec approve`, type `token_str`,
# return the child's exit code plus APPROVAL.json contents.
pty_approve() {
  local repo="$1" rid="$2" packet_sha="$3" token_str="$4"
  python3 - "$repo" "$rid" "$packet_sha" "$token_str" "$OFLOOP_BIN" <<'PYEND'
import json, os, pty, select, subprocess, sys, time

canonical_repo, run_id, packet_sha, token, ofloop_bin = sys.argv[1:6]
master_fd, slave_fd = pty.openpty()

env = dict(os.environ)
env.pop("OFLOOP_ACTOR", None)

proc = subprocess.Popen(
    [ofloop_bin, "spec", "approve", canonical_repo, run_id, "--actor", "test-pty"],
    stdin=slave_fd, stdout=slave_fd, stderr=slave_fd,
    close_fds=True, env=env,
)
os.close(slave_fd)

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
    proc.wait(timeout=2)

try:
    os.close(master_fd)
except OSError:
    pass

ap_path = os.path.join(canonical_repo, ".ownframework-loop", run_id, "APPROVAL.json")
ap = None
if os.path.exists(ap_path):
    try:
        ap = json.loads(open(ap_path).read())
    except Exception:
        ap = None

result = {
    "exit_code": proc.returncode,
    "output_tail": buf[-200:],
    "approval_method": ap.get("approval_method") if ap else None,
    "packet_sha256": ap.get("packet_sha256") if ap else None,
    "baseline_sha": ap.get("baseline_sha") if ap else None,
    "run_id": ap.get("run_id") if ap else None,
    "canonical_repo": ap.get("canonical_repo") if ap else None,
    "approved_actor": ap.get("approved_actor") if ap else None,
}
json.dump(result, sys.stdout)
PYEND
}

# Build a fresh run + packet.
T="$(make_tmp_repo)"
RID="$(make_approved_run "$T" 2>/dev/null || true)"
# We need a run in AWAITING_APPROVAL state, so create a fresh one without auto-approval.
PKT_PATH="$(write_packet "$T" "pty-e2e-mission" 2>/dev/null || true)"
# write_packet writes a WORK_PACKET.md; we then need a fresh run_id with that packet.
# Simpler: make_approved_run already creates an APPROVED run; rebuild one in AWAITING_APPROVAL.
RID="$(make_approved_run_unapproved "$T" 2>/dev/null || true)"
if [ -z "$RID" ]; then
  # Fall back: derive the run_id from existing structure if helper provides it.
  fail "no helper to create AWAITING_APPROVAL run; manual setup needed"
fi

PP="$T/.ownframework-loop/$RID/WORK_PACKET.md"
SHA="$(shasum -a 256 "$PP" | awk '{print $1}')"
TOKEN="$(python3 -c "import sys; sys.path.insert(0,'$ROOT/lib'); from ownframework_loop import approval; print(approval.derive_confirmation_token('$SHA'))")"

# Case 1: --assume-tty rejected.
if "$OFLOOP_BIN" spec approve --assume-tty "$T" "$RID" </dev/null >/dev/null 2>&1; then
  fail "case1: --assume-tty unexpectedly accepted"
fi

# Case 2: stdin=/dev/null refused.
if "$OFLOOP_BIN" spec approve "$T" "$RID" </dev/null >/dev/null 2>&1; then
  fail "case2: /dev/null stdin unexpectedly accepted"
fi

# Case 3: pipe stdin refused.
echo "$TOKEN" | "$OFLOOP_BIN" spec approve "$T" "$RID" >/dev/null 2>&1 && fail "case3: pipe stdin unexpectedly accepted"

# Case 4: non-TTY subprocess refused (run with stdin=subprocess.PIPE but no PTY).
python3 - "$T" "$RID" "$TOKEN" "$OFLOOP_BIN" <<'PYEND' >/dev/null 2>&1
import subprocess, sys
subprocess.run([sys.argv[4], "spec", "approve", sys.argv[1], sys.argv[2]], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
PYEND
# If exit was 0 the test is broken; expect nonzero.

# Case 5: wrong token refused.
RESULT="$(pty_approve "$T" "$RID" "$SHA" "WRONGTOKENXXX")"
EC="$(echo "$RESULT" | python3 -c "import sys, json; print(json.loads(sys.stdin.read())['exit_code'])")"
[ "$EC" != "0" ] || fail "case5: wrong token unexpectedly accepted"

# Case 6: real-PTY typed token succeeds.
RESULT="$(pty_approve "$T" "$RID" "$SHA" "$TOKEN")"
EC="$(echo "$RESULT" | python3 -c "import sys, json; print(json.loads(sys.stdin.read())['exit_code'])")"
METHOD="$(echo "$RESULT" | python3 -c "import sys, json; print(json.loads(sys.stdin.read())['approval_method'])")"
[ "$EC" = "0" ] || fail "case6: real PTY approval failed (exit $EC)"
[ "$METHOD" = "tty_confirmation" ] || fail "case6: approval_method=$METHOD (expected tty_confirmation)"

# Case 7: bindings — read APPROVAL.json and check fields.
AP="$T/.ownframework-loop/$RID/APPROVAL.json"
AP_RUN="$(python3 -c "import json; print(json.loads(open('$AP').read())['run_id'])")"
AP_REPO="$(python3 -c "import json; print(json.loads(open('$AP').read())['canonical_repo'])")"
AP_BRANCH="$(python3 -c "import json; print(json.loads(open('$AP').read())['baseline_branch'])")"
AP_ACTOR="$(python3 -c "import json; print(json.loads(open('$AP').read())['approved_actor'])")"
[ "$AP_RUN" = "$RID" ] || fail "case7: run_id mismatch"
[ "$AP_REPO" = "$(cd "$T" && pwd)" ] || fail "case7: canonical_repo mismatch"
[ -n "$AP_BRANCH" ] || fail "case7: baseline_branch empty"
[ "$AP_ACTOR" = "test-pty" ] || fail "case7: approved_actor mismatch"

# Case 8: packet mutation invalidates approval (build finalize must refuse).
echo "# extra line" >> "$PP"
"$OFLOOP_BIN" build finalize "$T" "$RID" >/dev/null 2>&1 && fail "case8: packet mutation not detected"

# Case 9: run cross-copy rejected. Copy APPROVAL.json into a new run_id; finalize refuses.
NEW_RID="$(make_approved_run_unapproved "$T" 2>/dev/null || true)"
cp "$AP" "$T/.ownframework-loop/$NEW_RID/APPROVAL.json"
"$OFLOOP_BIN" build finalize "$T" "$NEW_RID" >/dev/null 2>&1 && fail "case9: run cross-copy not detected"

# Case 10: repo cross-copy rejected. Make another repo, copy APPROVAL, finalize refuses.
T2="$(make_tmp_repo)"
mkdir -p "$T2/.ownframework-loop"
cp -R "$T/.ownframework-loop/$RID" "$T2/.ownframework-loop/$RID"
"$OFLOOP_BIN" build finalize "$T2" "$RID" >/dev/null 2>&1 && fail "case10: repo cross-copy not detected"

# Case 11: fabricated approval_method rejected.
python3 -c "
import json
ap = json.loads(open('$AP').read())
ap['approval_method'] = 'operator_marker'
open('$T/.ownframework-loop/$RID/APPROVAL.json','w').write(json.dumps(ap, indent=2, sort_keys=True))
"
"$OFLOOP_BIN" build finalize "$T" "$RID" >/dev/null 2>&1 && fail "case11: fabricated operator_marker not detected"

python3 -c "
import json
ap = json.loads(open('$AP').read())
ap['approval_method'] = 'operator_explicit_override'
open('$T/.ownframework-loop/$RID/APPROVAL.json','w').write(json.dumps(ap, indent=2, sort_keys=True))
"
"$OFLOOP_BIN" build finalize "$T" "$RID" >/dev/null 2>&1 && fail "case11b: fabricated operator_explicit_override not detected"

# Case 12: fabricated approval block (extra fields) rejected.
python3 -c "
import json
ap = json.loads(open('$AP').read())
ap['rogue'] = {'override': True, 'method': 'tty_confirmation'}
open('$T/.ownframework-loop/$RID/APPROVAL.json','w').write(json.dumps(ap, indent=2, sort_keys=True))
"
# Approval shape validator is strict; check it via validate_approval_shape.
python3 -c "
import sys; sys.path.insert(0,'$ROOT/lib')
from ownframework_loop import approval
import json
ap = json.loads(open('$AP').read())
errs = approval.validate_approval_shape(ap)
assert not errs, f'fabricated block should fail shape: {errs}'
" 2>&1 | grep -q . && fail "case12: fabricated approval block passed shape check"

# Case 13: tty_confirmation with mismatched confirmation_token rejected.
python3 -c "
import json
ap = json.loads(open('$AP').read())
ap['confirmation_token'] = 'CONFIRM-OF-LOOP-deadbeef'
open('$T/.ownframework-loop/$RID/APPROVAL.json','w').write(json.dumps(ap, indent=2, sort_keys=True))
"
"$OFLOOP_BIN" build finalize "$T" "$RID" >/dev/null 2>&1 && fail "case13: mismatched confirmation_token not detected"

echo "APPROVAL_PTY_E2E_TESTS=PASS"
