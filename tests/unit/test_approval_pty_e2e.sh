#!/usr/bin/env bash
# v0.3.5 (AUD2-P0-1 / A6-F03): real-PTY E2E approval test.
#
# Spawns a child PTY, drives `ofloop spec approve` over the slave fd,
# types the derived confirmation token into the master fd, and asserts
# APPROVAL.json.approval_method == "tty_confirmation".
#
# Coverage (7 cases):
#   1. --assume-tty rejected (flag no longer exists)
#   2. stdin=/dev/null refused
#   3. stdin=pipe refused
#   4. non-TTY subprocess refused
#   5. wrong token refused
#   6. real-PTY typed token succeeds
#   7. binding to packet SHA / repo / baseline / run / actor

set -uo pipefail  # NOTE: no -e so do_fail can accumulate failures

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=_helpers.sh
source "$HERE/../_helpers.sh"

: "${OFLOOP_BIN:=$ROOT/bin/ofloop}"
: "${PYTHONPATH:=$ROOT/lib}"
export PYTHONPATH
export PYTHONDONTWRITEBYTECODE=1

ASSERTIONS=0
FAILURES=()
TEST_FAILED=0

do_pass() {
  printf "  PASS: %s\n" "$*"
  ASSERTIONS=$((ASSERTIONS+1))
}

do_fail() {
  printf "  FAIL: %s\n" "$*"
  FAILURES+=("$*")
  TEST_FAILED=1
}

# Spawn a real PTY child, run `ofloop spec approve`, type `token_str`,
# return the child exit code plus APPROVAL.json contents as JSON on stdout.
pty_approve() {
  local repo="$1" rid="$2" token_str="$3"
  PYTHONDONTWRITEBYTECODE=1 python3 -B - "$repo" "$rid" "$token_str" "$OFLOOP_BIN" <<'PYEND'
import json, os, pty, select, subprocess, sys, time

canonical_repo, run_id, token, ofloop_bin = sys.argv[1:5]
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

# === Setup ===
T="$(make_tmp_repo)"
RID="$(make_approved_run_unapproved "$T")"
if [ -z "$RID" ] || [ ! -f "$T/.ownframework-loop/$RID/WORK_PACKET.md" ]; then
  do_fail "setup: failed to create AWAITING_APPROVAL run"
  echo "TEST_RESULT=FAIL"
  exit 1
fi
PP="$T/.ownframework-loop/$RID/WORK_PACKET.md"
SHA="$(shasum -a 256 "$PP" | awk '{print $1}')"
TOKEN="$(PYTHONDONTWRITEBYTECODE=1 python3 -B -c "
import sys
sys.path.insert(0, '$ROOT/lib')
from ownframework_loop import approval
print(approval.derive_confirmation_token('$SHA'))
")"

# === Case 1: --assume-tty rejected ===
if "$OFLOOP_BIN" spec approve --assume-tty "$T" "$RID" </dev/null >/dev/null 2>&1; then
  do_fail "case1: --assume-tty unexpectedly accepted"
else
  do_pass "case1: --assume-tty rejected"
fi

# === Case 2: stdin=/dev/null refused ===
if "$OFLOOP_BIN" spec approve "$T" "$RID" </dev/null >/dev/null 2>&1; then
  do_fail "case2: /dev/null stdin unexpectedly accepted"
else
  do_pass "case2: /dev/null stdin refused"
fi

# === Case 3: pipe stdin refused ===
if echo "$TOKEN" | "$OFLOOP_BIN" spec approve "$T" "$RID" >/dev/null 2>&1; then
  do_fail "case3: pipe stdin unexpectedly accepted"
else
  do_pass "case3: pipe stdin refused"
fi

# === Case 4: non-TTY subprocess refused ===
PTY4_RC="$(PYTHONDONTWRITEBYTECODE=1 python3 -B - "$T" "$RID" "$OFLOOP_BIN" <<'PYEND'
import subprocess, sys
repo, rid, ofloop_bin = sys.argv[1], sys.argv[2], sys.argv[3]
rc = subprocess.run(
    [ofloop_bin, "spec", "approve", repo, rid],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
).returncode
print("NONZERO" if rc != 0 else "ZERO")
PYEND
)"
if [[ "$PTY4_RC" == "NONZERO" ]]; then
  do_pass "case4: non-TTY subprocess refused"
else
  do_fail "case4: non-TTY subprocess accepted (rc=$PTY4_RC)"
fi

# === Case 5: wrong token refused ===
WRONG_RESULT="$(pty_approve "$T" "$RID" "WRONGTOKENXXX")"
WRONG_EC="$(echo "$WRONG_RESULT" | python3 -c "import sys, json; print(json.loads(sys.stdin.read())['exit_code'])")"
if [[ "$WRONG_EC" == "0" ]]; then
  do_fail "case5: wrong token unexpectedly accepted (exit=$WRONG_EC)"
else
  do_pass "case5: wrong token refused (exit=$WRONG_EC)"
fi

# === Case 6: real-PTY typed token succeeds ===
GOOD_RESULT="$(pty_approve "$T" "$RID" "$TOKEN")"
GOOD_EC="$(echo "$GOOD_RESULT" | python3 -c "import sys, json; print(json.loads(sys.stdin.read())['exit_code'])")"
GOOD_METHOD="$(echo "$GOOD_RESULT" | python3 -c "import sys, json; print(json.loads(sys.stdin.read())['approval_method'])")"
if [[ "$GOOD_EC" == "0" ]]; then
  do_pass "case6: real-PTY exit=0"
else
  do_fail "case6: real-PTY exit=$GOOD_EC"
fi
if [[ "$GOOD_METHOD" == "tty_confirmation" ]]; then
  do_pass "case6: approval_method=tty_confirmation"
else
  do_fail "case6: approval_method=$GOOD_METHOD (expected tty_confirmation)"
fi

# === Case 7: bindings ===
AP="$T/.ownframework-loop/$RID/APPROVAL.json"
AP_DATA="$(PYTHONDONTWRITEBYTECODE=1 python3 -B -c "
import json
ap = json.loads(open('$AP').read())
import json
print(json.dumps({
    'run_id': ap.get('run_id'),
    'canonical_repo': ap.get('canonical_repo'),
    'baseline_branch': ap.get('baseline_branch'),
    'approved_actor': ap.get('approved_actor'),
    'packet_sha256': ap.get('packet_sha256'),
}))
")"
AP_RUN="$(echo "$AP_DATA" | python3 -c "import sys, json; print(json.loads(sys.stdin.read())['run_id'])")"
AP_REPO="$(echo "$AP_DATA" | python3 -c "import sys, json; print(json.loads(sys.stdin.read())['canonical_repo'])")"
AP_BRANCH="$(echo "$AP_DATA" | python3 -c "import sys, json; print(json.loads(sys.stdin.read())['baseline_branch'])")"
AP_ACTOR="$(echo "$AP_DATA" | python3 -c "import sys, json; print(json.loads(sys.stdin.read())['approved_actor'])")"
AP_PKT="$(echo "$AP_DATA" | python3 -c "import sys, json; print(json.loads(sys.stdin.read())['packet_sha256'])")"

EXPECTED_REPO="$(cd "$T" && pwd -P)"  # resolve symlinks (macOS /var -> /private/var)
[[ "$AP_RUN" == "$RID" ]] && do_pass "case7: run_id binding" || do_fail "case7: run_id mismatch ($AP_RUN vs $RID)"
[[ "$AP_REPO" == "$EXPECTED_REPO" ]] && do_pass "case7: canonical_repo binding" || do_fail "case7: canonical_repo mismatch ($AP_REPO vs $EXPECTED_REPO)"
[[ -n "$AP_BRANCH" ]] && do_pass "case7: baseline_branch populated" || do_fail "case7: baseline_branch empty"
[[ "$AP_ACTOR" == "test-pty" ]] && do_pass "case7: approved_actor binding" || do_fail "case7: approved_actor=$AP_ACTOR"
[[ "$AP_PKT" == "$SHA" ]] && do_pass "case7: packet_sha256 binding" || do_fail "case7: packet_sha256 mismatch"

# === Summary ===
echo "ASSERTIONS_EXECUTED=$ASSERTIONS"
if [[ "$TEST_FAILED" == "1" ]]; then
  echo "APPROVAL_PTY_E2E_TESTS=FAIL"
  echo "TEST_RESULT=FAIL"
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
echo "APPROVAL_PTY_E2E_TESTS=PASS"
echo "TEST_RESULT=PASS"
exit 0
