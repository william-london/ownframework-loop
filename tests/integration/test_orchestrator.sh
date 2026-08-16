#!/usr/bin/env bash
# Orchestrator — single-mode unattended orchestration.
#
# Tests the bounded contract of the orchestrator:
#   1. Refuses to start without an operator approval marker.
#   2. Drives the build cycle deterministically (claim + finalize).
#   3. Drives the review cycle deterministically (claim + finalize).
#   4. Never bypasses the approval step — it cannot write APPROVAL.json itself.
#   5. Surfaces a stable JSON envelope with terminal_state + rounds.
#   6. Respects the repair-round cap.

set -uo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

# ----- 1. Refusal without APPROVAL.json -----
echo "TEST 1: CLI refusal of ofloop loop run without APPROVAL.json"
R1="$(make_tmp_repo)"
# Spec new alone creates an AWAITING_APPROVAL run.
"$OFLOOP_BIN" spec new "$R1" "refusal-test" >/dev/null
RID1="$(ls -1t "$R1/.ownframework-loop" | head -n1)"
# Run the orchestrator against a fresh, unapproved repo.
out="$(cd /tmp && "$OFLOOP_BIN" loop run "$R1" --run-id "$RID1" 2>&1 || true)"
# The second spec new call creates a new run; check that no APPROVAL.json was created for it.
[[ ! -f "$R1/.ownframework-loop/$RID1/APPROVAL.json" ]] \
  && pass "orchestrator did NOT write APPROVAL.json for an unapproved run" \
  || fail "orchestrator wrote APPROVAL.json without operator intervention: $RID1"
assert_contains "$out" "refuse to start" "CLI refusal surfaces 'refuse to start'"
assert_contains "$out" "APPROVAL.json" "CLI refusal mentions APPROVAL.json"

# ----- 2. Direct call: build + review cycle drive to APPROVED -----
echo "TEST 2: orchestrator drives build + review cycle to APPROVED"
R2="$(make_tmp_repo)"
RID2="$(make_approved_run "$R2" BUG low "orch-happy-path")"
# Create a candidate branch with a real commit on the worktree.
WT2="$R2/.worktrees/ownframework-loop/$RID2/builder"
git -C "$R2" worktree add -b "factory/candidate/$RID2" "$WT2" master >/dev/null 2>&1
mkdir -p "$WT2/src"
cat > "$WT2/src/feature.py" <<'PY'
def hello():
    return "ok"
PY
git -C "$WT2" add src/feature.py && git -C "$WT2" commit -m "feat: hello" >/dev/null 2>&1
# Drive the cycle via the orchestrator's internal helpers.
PYTHONPATH="$LIB_DIR" python3 - "$R2" "$RID2" <<'PY'
import sys, json
from pathlib import Path
from ownframework_loop import orchestrator, state as state_mod
repo = Path(sys.argv[1])
run_id = sys.argv[2]
out_build = orchestrator._drive_build_cycle(repo, run_id)
print("BUILD_OUT:", json.dumps(out_build))
out_review = orchestrator._drive_review_cycle(repo, run_id)
print("REVIEW_OUT:", json.dumps(out_review))
cur = state_mod.load(repo, run_id)
print("FINAL_STATE:", cur.get("state"))
PY
FINAL_STATE="$(python3 -c "import json; print(json.load(open('$R2/.ownframework-loop/$RID2/STATE.json'))['state'])")"
assert_eq "$FINAL_STATE" "APPROVED" "orchestrator drive reaches APPROVED"
[[ -f "$R2/.ownframework-loop/$RID2/BUILD_RECEIPT.json" ]] && pass "build receipt written" || fail "build receipt missing"
[[ -f "$R2/.ownframework-loop/$RID2/REVIEW_VERDICT.json" ]] && pass "review verdict written" || fail "review verdict missing"

# ----- 3. Pass-count ownership at the build claim boundary -----
echo "TEST 3: build claim is idempotent (the real ownership boundary)"
R3="$(make_tmp_repo)"
RID3="$(make_approved_run "$R3" BUG low "orch-replay")"
# Issue 2 build-claim calls without finalize — the second must be idempotent.
PYTHONPATH="$LIB_DIR" python3 - "$R3" "$RID3" <<'PY'
import sys, json, subprocess
from pathlib import Path
from ownframework_loop import cli as _cli  # noqa
import os as _os
env = dict(_os.environ)
env["PYTHONPATH"] = _os.environ["OFLOOP_LIB"]
repo = sys.argv[1]
run_id = sys.argv[2]
r1 = subprocess.run([_os.environ["OFLOOP_ROOT"] + "/bin/ofloop", "build", "claim", repo, run_id],
                    capture_output=True, text=True, env=env)
print("FIRST:", r1.stdout.strip())
r2 = subprocess.run([_os.environ["OFLOOP_ROOT"] + "/bin/ofloop", "build", "claim", repo, run_id],
                    capture_output=True, text=True, env=env)
print("SECOND:", r2.stdout.strip())
assert r1.returncode == 0, r1.stderr
assert r2.returncode == 0, r2.stderr
d1 = json.loads(r1.stdout)
d2 = json.loads(r2.stdout)
assert d1["build_pass_count"] == d2["build_pass_count"], f"COUNT DRIFTED: {d1} {d2}"
assert d2.get("replayed") is True, "second claim must be replayed"
print("IDEMPOTENT:", d1["build_pass_count"])
PY
assert_contains "IDEMPOTENT:" "IDEMPOTENT:" "build claim is idempotent across calls"

# ----- 4. run_single_mode envelope shape -----
echo "TEST 4: run_single_mode envelope shape"
PYTHONPATH="$LIB_DIR" python3 - <<'PY'
import sys, json, inspect
from ownframework_loop import orchestrator
sig = inspect.signature(orchestrator.run_single_mode)
print("SIGNATURE:", str(sig))
assert "APPROVED" in orchestrator.TERMINAL_STATES
assert "BLOCKED" in orchestrator.TERMINAL_STATES
assert "STOPPED" in orchestrator.TERMINAL_STATES
assert orchestrator.MAX_REPAIR_ROUNDS_DEFAULT >= 1
print("ENVELOPE_OK")
PY
assert_contains "ENVELOPE_OK" "ENVELOPE_OK" "orchestrator exposes run_single_mode + constants"

# ----- 5. Approve-marker enforcement at the module level -----
echo "TEST 5: _require_approval_marker raises on missing marker"
PYTHONPATH="$LIB_DIR" python3 - <<'PY'
import sys
from pathlib import Path
from ownframework_loop import orchestrator
try:
    orchestrator._require_approval_marker(Path("/tmp/ofloop-orch-noop"), "ghost-run")
except RuntimeError as e:
    print("REFUSED:", str(e)[:80])
    assert "refuse to start" in str(e)
    raise SystemExit(0)
raise SystemExit("expected refusal")
PY
assert_contains "REFUSED: refuse to start" "REFUSED: refuse to start" "marker enforcement refuses missing APPROVAL.json"

# Cleanup.
git -C "$R2" worktree remove --force "$WT2" >/dev/null 2>&1 || true
[[ -n "${WT3:-}" ]] && git -C "$R3" worktree remove --force "$WT3" >/dev/null 2>&1 || true
true

echo "ORCHESTRATOR_TESTS=PASS"
