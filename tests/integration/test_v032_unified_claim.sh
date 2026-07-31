#!/usr/bin/env bash
set -uo pipefail
ROOT="/Users/mr.mrs.london/projects/plugins/ownframework-loop"
LIB="$ROOT/lib"
export PYTHONPATH="$LIB${PYTHONPATH:+:$PYTHONPATH}"
TEST_ROOT="/tmp/v032_tests/v032_$$"
mkdir -p "$TEST_ROOT"
trap 'rm -rf "$TEST_ROOT"' EXIT

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; exit 1; }

make_repo() {
  local repo="$1"
  mkdir -p "$repo"
  (cd "$repo" && git init -q -b main && git config user.email t@t && git config user.name t && echo x > README.md && git add README.md && git commit -q -m init)
}

setup_run() {
  python3 /tmp/v031_setup_run.py "$@" >/dev/null
}

run_test() {
  local repo="$1" rid="$2" script="$3"
  REPO="$repo" RID="$rid" python3 -c "$script"
}

# SCENARIO: 1 CP, per-cp cap=8, cumulative cap=4
# 4 cumulative claims succeed; 5th hits cumulative cap.

# 1. 4 build claims succeed (cumulative cap is 4).
echo "Test 1: 4 PROGRAM build claims succeed when cumulative cap >= 4"
REPO="$TEST_ROOT/repo1"; make_repo "$REPO"
RID="run-20260101T000000Z-v032001"
setup_run "$REPO" "$RID" 1 4 4 1 8 8 3
out=$(run_test "$REPO" "$RID" '
import sys, json, os
from pathlib import Path
sys.path.insert(0, "lib")
from ownframework_loop import cli, state as state_mod, packet as packet_mod
import argparse
repo = Path(os.environ["REPO"]); rid = os.environ["RID"]
pkt_path = repo / ".ownframework-loop" / rid / "WORK_PACKET.md"
meta, _ = packet_mod.parse_packet_file(pkt_path)
successes = 0
for i in range(4):
    s = state_mod.load(repo, rid)
    s["program"]["current_checkpoints"] = ["CP-1"]
    s["state"] = "READY_TO_BUILD"
    state_mod.save(repo, rid, s)
    cur = state_mod.load(repo, rid)
    cur["program"]["checkpoints"][0]["build_pass_count"] = i
    state_mod.save(repo, rid, cur)
    try:
        cli.cmd_build_claim(argparse.Namespace(repo=str(repo), run_id=rid, actor="test"))
        successes += 1
    except SystemExit:
        pass
final = state_mod.load(repo, rid)
print(json.dumps({"successes": successes, "top": final["build_pass_count"], "cum": final["program"]["cumulative_counters"]["build_pass_count"], "per_cp": [c["build_pass_count"] for c in final["program"]["checkpoints"]]}))
')
echo "$out" | grep -q '"successes": 4' || fail "Test 1: $out"
echo "$out" | grep -q '"cum": 4' || fail "Test 1 cumulative: $out"
pass "Test 1: 4 cumulative build claims succeeded"

# 2. Cumulative cap enforces via _unified_claim_pass helper.
echo "Test 2: cumulative cap refuses via _unified_claim_pass"
out=$(PYTHONPATH="$LIB" python3 -c '
import sys
sys.path.insert(0, "lib")
from ownframework_loop import program as pm
prog = {"checkpoints": [{"id": "CP-1", "build_pass_count": 4, "review_pass_count": 0, "repair_round_count": 0}],
        "cumulative_counters": {"build_pass_count": 4, "review_pass_count": 0, "repair_round_count": 0},
        "cumulative_ceilings": {"max_build_passes": 4, "max_review_passes": 8, "max_repair_rounds": 3}}
packet_cp = {"risk_budget": {"max_build_passes": 8, "max_review_passes": 8, "max_repair_rounds": 3}}
try:
    pm._bump_counter_one(prog, cp_id="CP-1", counter="build_pass_count", packet_cp=packet_cp)
    print("UNEXPECTED_ACCEPTED")
except pm.ProgramStateError as e:
    print("REFUSED:", str(e)[:80])
')
echo "$out" | grep -q "REFUSED: cumulative cap reached" || fail "Test 2: $out"
pass "Test 2: cumulative cap refuses"

# 3. 4 review claims succeed.
echo "Test 3: 4 PROGRAM review claims succeed"
REPO="$TEST_ROOT/repo3"; make_repo "$REPO"
RID="run-20260101T000000Z-v032003"
setup_run "$REPO" "$RID" 1 4 4 1 8 8 3
out=$(run_test "$REPO" "$RID" '
import sys, json, os
from pathlib import Path
sys.path.insert(0, "lib")
from ownframework_loop import cli, state as state_mod, packet as packet_mod
import argparse
repo = Path(os.environ["REPO"]); rid = os.environ["RID"]
pkt_path = repo / ".ownframework-loop" / rid / "WORK_PACKET.md"
meta, _ = packet_mod.parse_packet_file(pkt_path)
for i in range(4):
    s = state_mod.load(repo, rid)
    s["program"]["current_checkpoints"] = ["CP-1"]
    s["state"] = "READY_FOR_REVIEW"
    state_mod.save(repo, rid, s)
    cur = state_mod.load(repo, rid)
    cur["program"]["checkpoints"][0]["review_pass_count"] = i
    state_mod.save(repo, rid, cur)
    cli.cmd_review_claim(argparse.Namespace(repo=str(repo), run_id=rid, actor="test"))
final = state_mod.load(repo, rid)
print(json.dumps({"cum": final["program"]["cumulative_counters"]["review_pass_count"], "per_cp": [c["review_pass_count"] for c in final["program"]["checkpoints"]]}))
')
echo "$out" | grep -q '"cum": 4' || fail "Test 3: $out"
pass "Test 3: 4 cumulative review claims succeeded"

# 4. Cumulative review cap refuses via _unified_claim_pass.
echo "Test 4: cumulative review cap refuses via _unified_claim_pass"
out=$(PYTHONPATH="$LIB" python3 -c '
import sys
sys.path.insert(0, "lib")
from ownframework_loop import program as pm
prog = {"checkpoints": [{"id": "CP-1", "build_pass_count": 0, "review_pass_count": 4, "repair_round_count": 0}],
        "cumulative_counters": {"build_pass_count": 0, "review_pass_count": 4, "repair_round_count": 0},
        "cumulative_ceilings": {"max_build_passes": 8, "max_review_passes": 4, "max_repair_rounds": 3}}
packet_cp = {"risk_budget": {"max_build_passes": 8, "max_review_passes": 8, "max_repair_rounds": 3}}
try:
    pm._bump_counter_one(prog, cp_id="CP-1", counter="review_pass_count", packet_cp=packet_cp)
    print("UNEXPECTED_ACCEPTED")
except pm.ProgramStateError as e:
    print("REFUSED:", str(e)[:80])
')
echo "$out" | grep -q "REFUSED: cumulative cap reached" || fail "Test 4: $out"
pass "Test 4: cumulative review cap refuses"

# 5. Per-cp build cap refuses before program cap.
echo "Test 5: per-cp build cap refuses before program cap"
out=$(PYTHONPATH="$LIB" python3 -c '
import sys
sys.path.insert(0, "lib")
from ownframework_loop import program as pm
prog = {"checkpoints": [{"id": "CP-1", "build_pass_count": 1, "review_pass_count": 0, "repair_round_count": 0}],
        "cumulative_counters": {"build_pass_count": 1, "review_pass_count": 0, "repair_round_count": 0},
        "cumulative_ceilings": {"max_build_passes": 8, "max_review_passes": 8, "max_repair_rounds": 3}}
packet_cp = {"risk_budget": {"max_build_passes": 1, "max_review_passes": 8, "max_repair_rounds": 3}}
try:
    pm._bump_counter_one(prog, cp_id="CP-1", counter="build_pass_count", packet_cp=packet_cp)
    print("UNEXPECTED_ACCEPTED")
except pm.ProgramStateError as e:
    print("REFUSED:", str(e)[:50])
')
echo "$out" | grep -q 'REFUSED:' || fail "Test 5: $out"
pass "Test 5: per-cp build cap enforced"

# 6. Per-cp review cap refuses before program cap.
echo "Test 6: per-cp review cap refuses before program cap"
out=$(PYTHONPATH="$LIB" python3 -c '
import sys
sys.path.insert(0, "lib")
from ownframework_loop import program as pm
prog = {"checkpoints": [{"id": "CP-1", "build_pass_count": 0, "review_pass_count": 2, "repair_round_count": 0}],
        "cumulative_counters": {"build_pass_count": 0, "review_pass_count": 2, "repair_round_count": 0},
        "cumulative_ceilings": {"max_build_passes": 8, "max_review_passes": 8, "max_repair_rounds": 3}}
packet_cp = {"risk_budget": {"max_build_passes": 8, "max_review_passes": 2, "max_repair_rounds": 3}}
try:
    pm._bump_counter_one(prog, cp_id="CP-1", counter="review_pass_count", packet_cp=packet_cp)
    print("UNEXPECTED_ACCEPTED")
except pm.ProgramStateError as e:
    print("REFUSED:", str(e)[:50])
')
echo "$out" | grep -q 'REFUSED:' || fail "Test 6: $out"
pass "Test 6: per-cp review cap enforced"

# 7. Repair-local and repair-cumulative caps work.
echo "Test 7: repair caps enforced"
out=$(PYTHONPATH="$LIB" python3 -c '
import sys
sys.path.insert(0, "lib")
from ownframework_loop import program as pm
prog_local = {"checkpoints": [{"id": "CP-1", "build_pass_count": 0, "review_pass_count": 0, "repair_round_count": 1}],
              "cumulative_counters": {"build_pass_count": 0, "review_pass_count": 0, "repair_round_count": 1},
              "cumulative_ceilings": {"max_build_passes": 8, "max_review_passes": 8, "max_repair_rounds": 5}}
prog_cum = {"checkpoints": [{"id": "CP-1", "build_pass_count": 0, "review_pass_count": 0, "repair_round_count": 0}],
            "cumulative_counters": {"build_pass_count": 0, "review_pass_count": 0, "repair_round_count": 5},
            "cumulative_ceilings": {"max_build_passes": 8, "max_review_passes": 8, "max_repair_rounds": 5}}
packet_cp = {"risk_budget": {"max_build_passes": 8, "max_review_passes": 8, "max_repair_rounds": 1}}
try:
    pm._bump_counter_one(prog_local, cp_id="CP-1", counter="repair_round_count", packet_cp=packet_cp)
    print("LOCAL_ACCEPTED_UNEXPECTED")
except pm.ProgramStateError as e:
    print("LOCAL REFUSED:", str(e)[:50])
try:
    pm._bump_counter_one(prog_cum, cp_id="CP-1", counter="repair_round_count", packet_cp=packet_cp)
    print("CUM_ACCEPTED_UNEXPECTED")
except pm.ProgramStateError as e:
    print("CUM REFUSED:", str(e)[:50])
')
echo "$out" | grep -q 'LOCAL REFUSED:' || fail "Test 7: local: $out"
echo "$out" | grep -q 'CUM REFUSED:' || fail "Test 7: cum: $out"
pass "Test 7: repair caps enforced"

# 8. Direct CLI claim and orchestrator execution produce identical counters.
echo "Test 8: CLI claim and program.claim_build_pass produce same counters"
REPO="$TEST_ROOT/repo8"; make_repo "$REPO"
RID="run-20260101T000000Z-v032008"
setup_run "$REPO" "$RID" 1 4 4 1 8 8 3
out=$(run_test "$REPO" "$RID" '
import sys, json, os
from pathlib import Path
sys.path.insert(0, "lib")
from ownframework_loop import cli, program, state as state_mod, packet as packet_mod
import argparse
repo = Path(os.environ["REPO"]); rid = os.environ["RID"]
pkt_path = repo / ".ownframework-loop" / rid / "WORK_PACKET.md"
meta, _ = packet_mod.parse_packet_file(pkt_path)
s = state_mod.load(repo, rid); s["state"] = "READY_TO_BUILD"; state_mod.save(repo, rid, s)
program.claim_build_pass(canonical_repo=repo, run_id=rid, packet=meta)
after_a = state_mod.load(repo, rid)
counters_a = {"top_build": after_a["build_pass_count"], "prog_cum": after_a["program"]["cumulative_counters"]["build_pass_count"], "cp_build": after_a["program"]["checkpoints"][0]["build_pass_count"], "state": after_a["state"]}
s = state_mod.load(repo, rid); s["state"] = "READY_TO_BUILD"; s["build_pass_count"] = 0
s["program"]["cumulative_counters"]["build_pass_count"] = 0
s["program"]["checkpoints"][0]["build_pass_count"] = 0
state_mod.save(repo, rid, s)
cli.cmd_build_claim(argparse.Namespace(repo=str(repo), run_id=rid, actor="test"))
after_b = state_mod.load(repo, rid)
counters_b = {"top_build": after_b["build_pass_count"], "prog_cum": after_b["program"]["cumulative_counters"]["build_pass_count"], "cp_build": after_b["program"]["checkpoints"][0]["build_pass_count"], "state": after_b["state"]}
print("A:", json.dumps(counters_a))
print("B:", json.dumps(counters_b))
print("MATCH:", counters_a == counters_b)
')
echo "$out" | grep -q 'MATCH: True' || fail "Test 8: $out"
pass "Test 8: CLI and direct path produce identical counters"

# 9. Orchestrator does NOT double-increment.
echo "Test 9: orchestrator path no double-increment"
n=$(grep -c 'increment_cp_counter' "$LIB/ownframework_loop/orchestrator.py" || true)
echo "orchestrator increment_cp_counter calls remaining: $n"
if [[ "$n" -eq 0 ]]; then
    pass "Test 9: orchestrator no longer calls increment_cp_counter"
else
    fail "Test 9: orchestrator still has $n increment_cp_counter calls"
fi

# 10. Replay of same claimed pass does not increment.
echo "Test 10: replay is idempotent"
REPO="$TEST_ROOT/repo10"; make_repo "$REPO"
RID="run-20260101T000000Z-v032010"
setup_run "$REPO" "$RID" 1 4 4 1 8 8 3
out=$(run_test "$REPO" "$RID" '
import sys, json, os
from pathlib import Path
sys.path.insert(0, "lib")
from ownframework_loop import cli, state as state_mod
import argparse
repo = Path(os.environ["REPO"]); rid = os.environ["RID"]
cli.cmd_build_claim(argparse.Namespace(repo=str(repo), run_id=rid, actor="test"))
after1 = state_mod.load(repo, rid)
prog1 = after1["program"]["cumulative_counters"]["build_pass_count"]
ret1 = after1["build_pass_count"]
cli.cmd_build_claim(argparse.Namespace(repo=str(repo), run_id=rid, actor="test"))
after2 = state_mod.load(repo, rid)
prog2 = after2["program"]["cumulative_counters"]["build_pass_count"]
ret2 = after2["build_pass_count"]
print(json.dumps({"ret1": ret1, "ret2": ret2, "prog1": prog1, "prog2": prog2, "no_double": ret1 == prog2 and prog1 == prog2}))
')
echo "$out" | grep -q '"no_double": true' || fail "Test 10: $out"
pass "Test 10: replay does not double-increment"

# 11. Invalid state rejected before any counter mutation.
echo "Test 11: invalid state rejected before any counter mutation"
out=$(PYTHONPATH="$LIB" python3 -c '
import sys
sys.path.insert(0, "lib")
from ownframework_loop import program
import tempfile
from pathlib import Path
repo = Path(tempfile.mkdtemp())
rid = "run-20260101T000000Z-missing"
try:
    program.claim_build_pass(canonical_repo=repo, run_id=rid, packet={"checkpoint_graph": {"checkpoints": []}})
    print("UNEXPECTED_ACCEPTED")
except program.ClaimRefused as e:
    print("REFUSED:", str(e))
')
echo "$out" | grep -q 'REFUSED:' || fail "Test 11: $out"
pass "Test 11: invalid state rejected before mutation"

# 12. Single-mode limits unchanged.
echo "Test 12: single-mode V1 cap still enforced"
out=$(PYTHONPATH="$LIB" python3 -c '
import sys
sys.path.insert(0, "lib")
from ownframework_loop.limits import enforce
for n in range(1, 9):
    enforce("build_pass_count", n - 1, None)
print("1..8_ALLOWED")
try:
    enforce("build_pass_count", 8, None)
    print("UNEXPECTED_8_ALLOWED")
except Exception as e:
    print("8_REFUSED:", str(e)[:50])
')
echo "$out" | grep -q '1..8_ALLOWED' || fail "Test 12: $out"
echo "$out" | grep -q '8_REFUSED' || fail "Test 12 8-refused: $out"
pass "Test 12: single-mode V1 cap unchanged"

# 13. Graph drift after approval fails closed.
echo "Test 13: post-approval graph drift refused"
out=$(PYTHONPATH="$LIB" python3 -c '
import sys
sys.path.insert(0, "lib")
from ownframework_loop import program
packet = {"checkpoint_graph": {"checkpoints": [{"id": "CP-1", "risk_budget": {}}], "execution_order": ["CP-1"], "global_source_ceilings": {}}}
prog_state = {"checkpoint_graph_sha256": "tampered-sha"}
ok, reason = program.verify_frozen_graph(packet, prog_state)
print(f"ok={ok} reason={reason}")
')
echo "$out" | grep -q 'reason=post-approval_graph_drift' || fail "Test 13: $out"
pass "Test 13: graph drift refused"

# 14. Repair claim → next build claim interaction (Issue A regression).
# Sequence: build_claim → CHANGES_REQUESTED → repair_claim → build_claim.
# The next build_claim after repair MUST advance (not replay) because
# review_finalize.py:544 returns CHANGES_REQUESTED and claim_repair_round
# leaves state in CHANGES_REQUESTED (not BUILDING), so the next build
# claim hits the cap path instead of the replay guard.
echo "Test 14: repair_round → next build claim interact correctly"
REPO="$TEST_ROOT/repo14"; make_repo "$REPO"
RID="run-20260101T000000Z-v032014"
setup_run "$REPO" "$RID" 1 4 4 1 3 3 3
out=$(run_test "$REPO" "$RID" '
import sys, json, os
from pathlib import Path
sys.path.insert(0, "lib")
from ownframework_loop import cli, program, state as state_mod, packet as packet_mod
import argparse
repo = Path(os.environ["REPO"]); rid = os.environ["RID"]
pkt_path = repo / ".ownframework-loop" / rid / "WORK_PACKET.md"
meta, _ = packet_mod.parse_packet_file(pkt_path)
# 1. claim build pass (state goes to BUILDING)
cli.cmd_build_claim(argparse.Namespace(repo=str(repo), run_id=rid, actor="test"))
s1 = state_mod.load(repo, rid)
b1 = s1["build_pass_count"]
c1 = s1["program"]["cumulative_counters"]["build_pass_count"]
# 2. simulate review_finalize returning CHANGES_REQUESTED
s1["state"] = "CHANGES_REQUESTED"
state_mod.save(repo, rid, s1)
# 3. claim repair round (state stays CHANGES_REQUESTED, repair_round_count bumps)
program.claim_repair_round(canonical_repo=repo, run_id=rid, packet=meta)
s2 = state_mod.load(repo, rid)
r_per_cp = s2["program"]["checkpoints"][0]["repair_round_count"]
r_cum = s2["program"]["cumulative_counters"]["repair_round_count"]
r_top = s2.get("repair_round", 0)
state_after_repair = s2["state"]
# 4. claim next build pass (must NOT replay)
res = program.claim_build_pass(canonical_repo=repo, run_id=rid, packet=meta)
s3 = state_mod.load(repo, rid)
b2 = s3["build_pass_count"]
c2 = s3["program"]["cumulative_counters"]["build_pass_count"]
print(json.dumps({
    "b1": b1, "b2": b2, "c1": c1, "c2": c2,
    "r_per_cp": r_per_cp, "r_cum": r_cum, "r_top": r_top,
    "state_after_repair": state_after_repair,
    "replayed": res["replayed"],
    "build_advanced": b2 == b1 + 1 and c2 == c1 + 1,
    "repair_advanced": r_per_cp == 1 and r_cum == 1 and r_top == 1,
    "state_not_build_collision": state_after_repair == "CHANGES_REQUESTED",
}))
')
echo "$out" | grep -q '"build_advanced": true' || fail "Test 14: build did not advance: $out"
echo "$out" | grep -q '"repair_advanced": true' || fail "Test 14: repair did not advance: $out"
echo "$out" | grep -q '"replayed": false' || fail "Test 14: build was replayed: $out"
echo "$out" | grep -q '"state_not_build_collision": true' || fail "Test 14: state collided with BUILDING: $out"
pass "Test 14: repair_round → build claim interact correctly"

# 15. cmd_build_transition --to CHANGES_REQUESTED in program mode routes through unified claim.
echo "Test 15: cmd_build_transition --to CHANGES_REQUESTED routes through unified claim in program mode"
REPO="$TEST_ROOT/repo15"; make_repo "$REPO"
RID="run-20260101T000000Z-v032015"
setup_run "$REPO" "$RID" 1 4 4 1 3 3 3
out=$(run_test "$REPO" "$RID" '
import sys, json, os
from pathlib import Path
sys.path.insert(0, "lib")
from ownframework_loop import cli, state as state_mod, packet as packet_mod
import argparse
repo = Path(os.environ["REPO"]); rid = os.environ["RID"]
pkt_path = repo / ".ownframework-loop" / rid / "WORK_PACKET.md"
meta, _ = packet_mod.parse_packet_file(pkt_path)
# Set state to BUILDING so V1 FSM allows BUILDING → CHANGES_REQUESTED
s = state_mod.load(repo, rid); s["state"] = "BUILDING"; state_mod.save(repo, rid, s)
# First estimate the initial repair count
before = state_mod.load(repo, rid)
print("BEFORE:", json.dumps({"repair_round": before.get("repair_round", 0), "prog_cum_repair": before["program"]["cumulative_counters"]["repair_round_count"], "cp_repair": before["program"]["checkpoints"][0]["repair_round_count"]}))
# Run cmd_build_transition --to CHANGES_REQUESTED
cli.cmd_build_transition(argparse.Namespace(repo=str(repo), run_id=rid, actor="t", to="CHANGES_REQUESTED", reason="test", commit_sha=None))
after = state_mod.load(repo, rid)
print("AFTER:", json.dumps({"repair_round": after.get("repair_round", 0), "prog_cum_repair": after["program"]["cumulative_counters"]["repair_round_count"], "cp_repair": after["program"]["checkpoints"][0]["repair_round_count"]}))
diff = {"repair_round": after.get("repair_round", 0) - before.get("repair_round", 0),
        "prog_cum_repair": after["program"]["cumulative_counters"]["repair_round_count"] - before["program"]["cumulative_counters"]["repair_round_count"],
        "cp_repair": after["program"]["checkpoints"][0]["repair_round_count"] - before["program"]["checkpoints"][0]["repair_round_count"]}
print("DIFF:", json.dumps(diff))
print("IN_SYNC:", diff["repair_round"] == diff["prog_cum_repair"] == diff["cp_repair"] == 1)
')
echo "$out" | grep -q 'IN_SYNC_IS: true' || fail "Test 15: cmd_build_transition desync: $out"
pass "Test 15: cmd_build_transition routes through unified claim"

echo "ALL V0.3.2 UNIFIED-CLAIM TESTS PASS"
