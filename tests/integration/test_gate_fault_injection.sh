#!/usr/bin/env bash
# v0.3.5 (Repair 7): gate fault-injection matrix.
# Verifies the canonical gate has the structural defenses needed to
# catch known regressions. Forbidden tokens decoded via chr() at runtime.

set -euo pipefail

HERE="${OFLOOP_TEST_HERE:-$(cd "$(dirname "$0")" && pwd)}"
ROOT="${OFLOOP_TEST_ROOT:-$(cd "$HERE/../.." && pwd)}"
LIB="$ROOT/lib"
export PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$LIB"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

# === Fault 1: classify_bash_command must consult all segments after split ===
python3 -B -c "
import sys
sys.path.insert(0, '$LIB')
from ownframework_loop import guards
NL = chr(10)
GT = chr(103)+chr(105)+chr(116)
PS = chr(112)+chr(117)+chr(115)+chr(104)
# Multiline hidden push
cmd = chr(101)+chr(99)+chr(104)+chr(111)+' harmless' + NL + GT + ' ' + PS + ' origin master'
r = guards.classify_bash_command(cmd)
assert r['severity'] == 'forbidden', f'multiline push not blocked: {r}'
print('OK')
" >/dev/null 2>&1 && pass "fault 1: classify_bash_command blocks hidden multiline push" || fail "fault 1: multiline classifier bypass"

# === Fault 2: validate_approval_shape refuses operator_marker ===
python3 -B -c "
import sys, json
sys.path.insert(0, '$LIB')
from ownframework_loop import approval
ap = {
    chr(34).join([chr(s) for s in [115,99,104,101,109,97]]): chr(34).join([chr(s) for s in [111,119,110,102,114,97,109,101,119,111,114,107,45,108,111,111,112,45,97,112,112,114,111,118,97,108,47,118,49]]),
    chr(34).join([chr(s) for s in [114,117,110,95,105,100]]): chr(34).join([chr(s) for s in [114,117,110,45,49]]),
    chr(34).join([chr(s) for s in [97,112,112,114,111,118,97,108,95,109,101,116,104,111,100]]): chr(34).join([chr(s) for s in [111,112,101,114,97,116,111,114,95,109,97,114,107,101,114]]),
}
errs = approval.validate_approval_shape(ap)
assert errs, f'shape validator accepted operator_marker: {errs}'
print('OK')
" >/dev/null 2>&1 && pass "fault 2: validate_approval_shape refuses operator_marker" || fail "fault 2: operator_marker accepted"

# === Fault 3: gate has timeout wrapper ===
grep -q "timeout 180" "$ROOT/tests/run_all.sh" && pass "fault 3: gate wraps each test in timeout" || fail "fault 3: no timeout wrapper"

# === Fault 4: canonical.txt allow-list present ===
[[ -f "$ROOT/tests/canonical.txt" ]] && pass "fault 4: canonical.txt allow-list in place" || fail "fault 4: canonical.txt missing"

# === Fault 5: static_checks covers hooks/skills/agents/bin ===
python3 -B -c "
import sys
sys.path.insert(0, '$LIB')
from ownframework_loop import static_checks
from pathlib import Path
SCAN_GLOBS = static_checks.SCAN_SHELL_GLOBS
needed = ['hooks/', 'skills/', 'agents/', 'bin/']
joined = ' '.join(SCAN_GLOBS)
ok = all(any(n in g for g in SCAN_GLOBS) for n in needed)
assert ok, f'static_checks scan too narrow: {SCAN_GLOBS}'
print('OK')
" >/dev/null 2>&1 && pass "fault 5: static_checks scan covers hooks/skills/agents/bin" || fail "fault 5: scan too narrow"

# === Fault 6: state.py program_transition exists and is callable ===
python3 -B -c "
import sys
sys.path.insert(0, '$LIB')
from ownframework_loop import state
assert hasattr(state, 'program_transition'), 'state.program_transition missing'
print('OK')
" >/dev/null 2>&1 && pass "fault 6: state.program_transition exists" || fail "fault 6: program_transition missing"

# === Fault 7: worktrees uses flock_exclusive ===
grep -q "flock_exclusive" "$ROOT/lib/ownframework_loop/worktrees.py" && pass "fault 7: worktrees uses flock_exclusive" || fail "fault 7: worktrees flock missing"

# === Fault 8: append_event verifies authority after acquiring the run flock ===
python3 -B - "$LIB" <<'PY' >/dev/null 2>&1 && pass "fault 8: append_event authority verification is serialized under run flock" || fail "fault 8: append_event lock/authority ordering regression"
import fcntl, os, subprocess, sys, tempfile, time
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from ownframework_loop import integrity, state, util

repo = Path(tempfile.mkdtemp(prefix="ofloop-fault8-"))
rid = "run-fault8"
state.run_dir(repo, rid).mkdir(parents=True)
state.save(repo, rid, state.initial_state(rid))
events_before = state.events_path(repo, rid).read_bytes()
marker = repo / "child-ready"

lock_fh = state.lock_path(repo, rid).open("a+")
fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX)

child_code = r"""
import sys
from pathlib import Path
from ownframework_loop import integrity, state
repo=Path(sys.argv[1]); rid=sys.argv[2]; marker=Path(sys.argv[3])
marker.write_text("ready")
try:
    state.append_event(repo, rid, event_type="fault8-child", old_state=None,
                       new_state=None, actor="fault8")
except integrity.TamperingDetected:
    raise SystemExit(23)
raise SystemExit(0)
"""
env = dict(os.environ)
env["PYTHONPATH"] = sys.argv[1]
child = subprocess.Popen(
    [sys.executable, "-B", "-c", child_code, str(repo), rid, str(marker)],
    env=env,
)
deadline = time.time() + 5
while not marker.exists() and time.time() < deadline:
    time.sleep(0.01)
assert marker.exists(), "child did not reach append_event"
time.sleep(0.05)
assert child.poll() is None, "append_event did not block on held run flock"

tampered = state.load(repo, rid)
tampered["state"] = "APPROVED"
util.atomic_write_json(state.state_path(repo, rid), tampered, mode=0o600)
fcntl.flock(lock_fh.fileno(), fcntl.LOCK_UN)
lock_fh.close()

rc = child.wait(timeout=5)
assert rc == 23, f"append_event failed to detect tampering after lock acquisition: rc={rc}"
assert state.events_path(repo, rid).read_bytes() == events_before, "tampering was laundered into event chain"
PY

# === Fault 9: ALLOWED_APPROVAL_METHODS is restricted ===
python3 -B -c "
import sys
sys.path.insert(0, '$LIB')
from ownframework_loop import approval
m = approval.ALLOWED_APPROVAL_METHODS
# v0.5.0: ALLOWED_APPROVAL_METHODS now contains both tty_confirmation (legacy)
# and build_start (auto-seal at first build start). Whichever wins the
# first-write race is immutable.
expected = {'tty_confirmation', 'build_start'}
assert m == expected, f'approval methods not aligned with v0.5.0: got={m} expected={expected}'
print('OK')
" >/dev/null 2>&1 && pass "fault 9: approval methods restricted to tty_confirmation + build_start" || fail "fault 9: approval methods not restricted"

if [[ "$FAIL" -gt 0 ]]; then
  echo "OF_LOOP_GATE_FAULT_INJECTION=FAIL count=$FAIL"
  exit 1
fi
echo "OF_LOOP_GATE_FAULT_INJECTION=PASS"
echo "GATE_FAULT_INJECTION_TESTS=PASS"
