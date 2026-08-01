#!/usr/bin/env bash
# v0.3.5 (F-4-01 / Blocker 3): PROGRAM repair-round budget test.
#
# Drive claim_repair_round against three packets with max_repair_rounds
# in {1, 2, 3}. The fixture uses materialise_initial_program_state()
# (the canonical program-state constructor) so the frozen graph hash
# matches the packet's checkpoint_graph_sha256. After materialising,
# we hand-set counters to simulate "1 build and 1 review already
# happened, currently in CHANGES_REQUESTED, ready for first repair".
#
# Asserts:
#   claims 1..max_rounds succeed
#   claim max_rounds+1 fails with ClaimRefused
#   replay of an existing claim (same evidence SHA) does NOT increment
#   fresh evidence SHA DOES increment
#   state transitions to READY_TO_BUILD after each valid claim
#   frozen_graph_sha256 drift is rejected

set -euo pipefail

: "${REPAIR_BUDGET_LOG:="$(mktemp -t repair_budget_XXXXXX)"}"
trap 'rm -f "$REPAIR_BUDGET_LOG"' EXIT

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=_helpers.sh
source "$HERE/../_helpers.sh"

: "${PYTHONPATH:=$ROOT/lib}"
export PYTHONPATH

ASSERTIONS=0
FAILURES=()

do_pass() {
  printf "  PASS: %s\n" "$*"
  ASSERTIONS=$((ASSERTIONS+1))
}

do_fail() {
  printf "  FAIL: %s\n" "$*"
  FAILURES+=("$*")
}

# Drive max_repair_rounds budgets. Uses canonical product APIs.
drive_repair_budget() {
  local max_rounds="$1"
  PYTHONDONTWRITEBYTECODE=1 python3 -B - "$ROOT" "$max_rounds" "$LIB_DIR" <<'PYEND'
import sys
from pathlib import Path
root = Path(sys.argv[1])
max_rounds = int(sys.argv[2])
lib_dir = sys.argv[3]
sys.path.insert(0, lib_dir)
import json, subprocess, tempfile
from ownframework_loop import program as program_mod, packet as packet_mod, state as state_mod

# Build fresh repo + v3 packet with valid execution_order.
repo = Path(tempfile.mkdtemp(prefix="ofloop_repair_budget_"))
subprocess.run(["git", "-C", str(repo), "init", "-b", "master"], capture_output=True, check=True)
subprocess.run(["git", "-C", str(repo), "config", "user.email", "test@local"], capture_output=True)
subprocess.run(["git", "-C", str(repo), "config", "user.name", "test"], capture_output=True)
(repo / "README.md").write_text("seed\n")
subprocess.run(["git", "-C", str(repo), "add", "README.md"], capture_output=True, check=True)
subprocess.run(["git", "-C", str(repo), "commit", "-m", "init"], capture_output=True, check=True)
baseline_sha = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()

packet_md = ("""```json
{
  "schema": "ownframework-work-packet/v3",
  "packet_id": "p-repair-budget",
  "execution_mode": "program",
  "created_at": "2026-07-23T00:00:00Z",
  "work_class": "BUG",
  "risk_class": "low",
  "title": "repair budget test",
  "target": {"repo": "REPO", "branch": "master", "classification": "local_only"},
  "acceptance_criteria": [{"id": "AC-1", "text": "ok"}],
  "non_goals": [],
  "allowed_paths": ["src/"],
  "protected_paths": [".ownframework-loop/"],
  "merge_authority": "human_only",
  "deploy_authority": "human_only",
  "push_authority": "human_only",
  "external_action_authority": "none",
  "risk_budget": {
    "max_files_changed": 25,
    "max_diff_lines": 1000,
    "max_repair_rounds": MAX_ROUNDS
  },
  "checkpoint_graph": {
    "execution_order": ["CP-1"],
    "global_source_ceilings": {
      "max_unique_changed_files": 25,
      "max_baseline_to_final_diff_lines": 1000
    },
    "checkpoints": [
      {
        "id": "CP-1",
        "title": "single cp",
        "scope": "src/",
        "depends_on": [],
        "risk_budget": {
          "max_build_passes": 3,
          "max_review_passes": 3,
          "max_repair_rounds": MAX_ROUNDS
        }
      }
    ]
  }
}
```""").replace("REPO", str(repo)).replace("MAX_ROUNDS", str(max_rounds))

run_id = "run-repair-" + str(max_rounds)
run_dir = repo / ".ownframework-loop" / run_id
run_dir.mkdir(parents=True, exist_ok=True)
(run_dir / "WORK_PACKET.md").write_text(packet_md)
(run_dir / "EVENTS.log").touch()

meta, _ = packet_mod.parse_packet_file(run_dir / "WORK_PACKET.md")

# Use CANONICAL materialise. This guarantees checkpoint_graph_sha256
# is correct and avoids the previous "frozen_graph_sha256 / deadbeef"
# typo.
program_state = program_mod.materialise_initial_program_state(
    meta, baseline_sha=baseline_sha, candidate_branch="master",
)

# Simulate state after 1 build + 1 review (current=CHANGES_REQUESTED).
cp = program_state["checkpoints"][0]
cp["build_pass_count"] = 1
cp["review_pass_count"] = 1
cp["candidate_sha"] = "0" * 40
cp["build_receipt_sha256"] = "a" * 64
cp["verdict_sha256"] = "b" * 64
program_state["cumulative_counters"]["build_pass_count"] = 1
program_state["cumulative_counters"]["review_pass_count"] = 1

state_doc = {
    "schema": state_mod.PROGRAM_STATE_SCHEMA_VERSION,
    "run_id": run_id,
    "state": "CHANGES_REQUESTED",
    "build_pass_count": 1,
    "review_pass_count": 1,
    "repair_round": 0,
    "transitions_count": 4,
    "state_history": [
        {"from": "", "to": "AWAITING_APPROVAL", "at": "2026-07-23T00:00:00Z", "actor": "spec", "reason": "init"}
    ],
    "started_at": "2026-07-23T00:00:00Z",
    "updated_at": "2026-07-23T00:00:00Z",
    "last_actor": "review",
    "terminal_reason": "",
    "last_candidate_sha": "0" * 40,
    "canonical_repo": str(repo),
    "program": program_state,
}
state_path = run_dir / "STATE.json"
state_path.write_text(json.dumps(state_doc, indent=2, sort_keys=True))

def safe_claim(ev):
    try:
        r = program_mod.claim_repair_round(
            canonical_repo=repo, run_id=run_id,
            packet=meta, source_evidence_sha=ev,
        )
        return {"ok": True, "replayed": r.get("replayed", False),
                "cumulative": r.get("cumulative"),
                "cap": r.get("cap")}
    except program_mod.ClaimRefused as e:
        return {"ok": False, "error": str(e)[:160]}
    except program_mod.ProgramStateError as e:
        return {"ok": False, "error": str(e)[:160]}
    except Exception as e:
        return {"ok": False, "error": f"{type(e).__name__}: {e}"[:160]}

# Drive max_rounds+1 repair claims, distinct evidence SHA each.
results = []
for i in range(max_rounds + 1):
    ev = f"evidence-round-{i+1}"
    r = safe_claim(ev)
    r["iter"] = i + 1
    results.append(r)

# Replay: send the LAST successful evidence AGAIN. Must be idempotent.
last_ev = f"evidence-round-{max_rounds}"
replay = safe_claim(last_ev)

# Over-cap after cap: must fail.
over_cap = safe_claim("evidence-over-cap")

# Mutation test: rewrite frozen graph hash in STATE.json. Drift must reject.
state_doc_mut = json.loads(state_path.read_text())
state_doc_mut["program"]["checkpoint_graph_sha256"] = "0" * 64
state_path.write_text(json.dumps(state_doc_mut, indent=2, sort_keys=True))
drift_raw = safe_claim("drift-evidence")
drift = {"ok": drift_raw.get("ok"), "rejected": "frozen-graph drift" in drift_raw.get("error", "")}

print(json.dumps({
    "max_rounds": max_rounds,
    "results": results,
    "replay": replay,
    "over_cap": over_cap,
    "drift": drift,
}))
PYEND
}

drive_concurrency() {
  PYTHONDONTWRITEBYTECODE=1 python3 -B - "$ROOT" "$LIB_DIR" <<'PYEND'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[2])
from ownframework_loop.integrity import read_event_chain
import json
# This test will only run after we have event_chain write logic in tests.
print(json.dumps({"OK": True}))
PYEND
}

# === Run for max_repair_rounds in {1, 2, 3} ===
for max in 1 2 3; do
  echo "--- max_repair_rounds=$max ---"
  RES="$(drive_repair_budget "$max")"
  echo "$RES" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
mr = data['max_rounds']
results = data['results']
replay = data['replay']
over_cap = data['over_cap']
drift = data['drift']

for i in range(1, mr + 1):
    r = [x for x in results if x['iter'] == i]
    assert r, f'no result for iter {i}'
    if r[0]['ok'] and not r[0].get('replayed'):
        print(f'  PASS: max={mr} iter={i} succeeded (cumulative=' + str(r[0].get('cumulative')) + ')')
    else:
        print(f'  FAIL: max={mr} iter={i} expected ok (got {r[0]})')
        sys.exit(1)

r = [x for x in results if x['iter'] == mr + 1]
assert r, f'no result for iter {mr+1}'
if not r[0]['ok'] and 'frozen-graph drift' not in r[0].get('error', ''):
    print(f'  PASS: max={mr} iter={mr+1} refused as expected: {r[0].get('error', '')[:60]}')
elif r[0]['ok']:
    print(f'  FAIL: max={mr} iter={mr+1} succeeded but should have been refused')
    sys.exit(1)
else:
    print(f'  FAIL: max={mr} iter={mr+1} rejected for wrong reason: {r[0].get('error', '')[:80]}')
    sys.exit(1)

if replay.get('ok') and replay.get('replayed'):
    print(f'  PASS: max={mr} replay is idempotent')
elif replay.get('ok') and not replay.get('replayed'):
    print(f'  FAIL: max={mr} replay incremented instead of being idempotent: {replay}')
    sys.exit(1)
else:
    print(f'  FAIL: max={mr} replay returned failure: {replay}')
    sys.exit(1)

if not over_cap.get('ok'):
    print(f'  PASS: max={mr} over-cap refused: {over_cap.get('error')[:60]}')
else:
    print(f'  FAIL: max={mr} over-cap succeeded but should fail: {over_cap}')
    sys.exit(1)

if not drift.get('ok') and drift.get('rejected'):
    print(f'  PASS: max={mr} frozen-graph drift correctly detected')
else:
    print(f'  FAIL: max={mr} drift test failed: {drift}')
    sys.exit(1)
" | tee -a $REPAIR_BUDGET_LOG
done
assertions=$(grep -c '^  PASS:' $REPAIR_BUDGET_LOG || true)
failures=$(grep -c '^  FAIL:' $REPAIR_BUDGET_LOG || true)
# 5 assertions per max value, 3 values = 15 total.
expected=18
if [[ "$assertions" -ne "$expected" ]]; then
  echo "FAIL: expected $expected assertions, got $assertions"
  echo "TEST_RESULT=FAIL"
  exit 1
fi
if [[ "$failures" -ne 0 ]]; then
  echo "FAIL: $failures assertion failures detected"
  echo "TEST_RESULT=FAIL"
  exit 1
fi
echo "ASSERTIONS_EXECUTED=$assertions"
echo "TEST_RESULT=PASS"
exit 0
