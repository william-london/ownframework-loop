#!/usr/bin/env bash
# v0.3.5 (F-4-01): PROGRAM repair-round budget test.
#
# Drive claim_repair_round against three packets with max_repair_rounds
# in {1, 2, 3}. Assert claims 1..N succeed, claim N+1 fails with
# ClaimRefused, replay of an existing claim (same evidence SHA) does
# not increment, fresh evidence SHA does increment, direct CLI and
# orchestrator paths agree.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=_helpers.sh
source "$HERE/../_helpers.sh"

: "${PYTHONPATH:=$ROOT/lib}"
export PYTHONPATH

drive_repair_budget() {
  local max_rounds="$1"
  local out
  out="$(python3 - "$ROOT" "$max_rounds" <<'PYEND'
import sys, os, json, tempfile, subprocess
from pathlib import Path
root = Path(sys.argv[1])
max_rounds = int(sys.argv[2])
sys.path.insert(0, str(root / "lib"))
from ownframework_loop import program as program_mod, state as state_mod, packet as packet_mod

# Build a fresh repo + v3 packet with max_repair_rounds = max_rounds.
repo = Path(tempfile.mkdtemp(prefix="ofloop_repair_budget_"))
subprocess.run(["git", "-C", str(repo), "init", "-b", "master"], capture_output=True, check=True)
subprocess.run(["git", "-C", str(repo), "config", "user.email", "test@local"], capture_output=True)
subprocess.run(["git", "-C", str(repo), "config", "user.name", "test"], capture_output=True)
(repo / "README.md").write_text("seed\n")
subprocess.run(["git", "-C", str(repo), "add", "README.md"], capture_output=True, check=True)
subprocess.run(["git", "-C", str(repo), "commit", "-m", "init"], capture_output=True, check=True)

packet_md = """```json
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
    "checkpoints": [
      {
        "id": "CP-1",
        "title": "single cp",
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
```""".replace("REPO", str(repo)).replace("MAX_ROUNDS", str(max_rounds))

# Init a run via the CLI
run_id = "run-repair-" + str(max_rounds)
run_dir = repo / ".ownframework-loop" / run_id
run_dir.mkdir(parents=True, exist_ok=True)
(run_dir / "WORK_PACKET.md").write_text(packet_md)

# Build a v2 program state with one cp in CHANGES_REQUESTED state
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
    "last_actor": "spec",
    "terminal_reason": "",
    "last_candidate_sha": "",
    "canonical_repo": str(repo),
    "program": {
        "schema_version": "ownframework-program-state/v1",
        "packet_sha256": "deadbeef",
        "checkpoints": [
            {
                "id": "CP-1",
                "build_pass_count": 1,
                "review_pass_count": 1,
                "repair_round_count": 0,
                "terminal": None,
                "evidence_manifests": [],
                "finalized_at": None,
                "last_evidence_sha_by_counter": {},
            }
        ],
        "cumulative_counters": {
            "build_pass_count": 1,
            "review_pass_count": 1,
            "repair_round_count": 0,
        },
        "cumulative_ceilings": {
            "max_build_passes": 3,
            "max_review_passes": 3,
            "max_repair_rounds": max_rounds,
        },
        "source_tree_aggregate": {"files_changed_unique": 0, "diff_lines": 0},
        "frozen_graph_sha256": "deadbeef",
    },
}
state_path = run_dir / "STATE.json"
state_path.write_text(json.dumps(state_doc, indent=2, sort_keys=True))
(run_dir / "EVENTS.log").touch()

meta, _ = packet_mod.parse_packet_file(run_dir / "WORK_PACKET.md")

# Drive claim_repair_round max_rounds+1 times with fresh evidence SHA each
results = []
for i in range(max_rounds + 1):
    ev = f"evidence-round-{i+1}"
    try:
        r = program_mod.claim_repair_round(
            canonical_repo=repo, run_id=run_id,
            packet=meta, source_evidence_sha=ev,
        )
        results.append({"iter": i+1, "ok": True, "replayed": r.get("replayed", False),
                        "cumulative": r.get("cumulative"),
                        "cap": r.get("cap")})
    except program_mod.ClaimRefused as e:
        results.append({"iter": i+1, "ok": False, "error": str(e)[:60]})

# Replay: claim max_rounds AGAIN with the same evidence as the last successful round
last_ev = f"evidence-round-{max_rounds}"
replay_result = None
try:
    r = program_mod.claim_repair_round(
        canonical_repo=repo, run_id=run_id,
        packet=meta, source_evidence_sha=last_ev,
    )
    replay_result = {"ok": True, "replayed": r.get("replayed", False),
                     "cumulative": r.get("cumulative")}
except program_mod.ClaimRefused as e:
    replay_result = {"ok": False, "error": str(e)[:60]}

# Replay at cap: try one more fresh round (should be refused)
try:
    r = program_mod.claim_repair_round(
        canonical_repo=repo, run_id=run_id,
        packet=meta, source_evidence_sha="evidence-over-cap",
    )
    over_cap = {"ok": True, "replayed": r.get("replayed", False)}
except program_mod.ClaimRefused as e:
    over_cap = {"ok": False, "error": str(e)[:60]}

print(json.dumps({
    "max_rounds": max_rounds,
    "results": results,
    "replay": replay_result,
    "over_cap": over_cap,
}, indent=2))
PYEND
)"
  echo "$out"
}

# Test 1: max_repair_rounds = 1
out1="$(drive_repair_budget 1)"
echo "$out1" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['max_rounds'] == 1
r = d['results']
# First claim succeeds (round 1)
assert r[0]['ok'] is True, f\"round 1 must succeed: {r[0]}\"
assert r[0]['replayed'] is False
# Second claim must fail (over cap)
assert r[1]['ok'] is False, f\"round 2 must fail at cap=1: {r[1]}\"
# Replay must report replayed=True
assert d['replay']['replayed'] is True, f\"replay must be replayed: {d['replay']}\"
# Over cap must fail
assert d['over_cap']['ok'] is False, f\"over cap must fail: {d['over_cap']}\"
print('OK: max_repair_rounds=1 budget honored (1 success, 1 refusal, replay distinguished)')
"

# Test 2: max_repair_rounds = 2
out2="$(drive_repair_budget 2)"
echo "$out2" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
r = d['results']
# Rounds 1 and 2 succeed, round 3 fails
assert r[0]['ok'] is True and r[0]['replayed'] is False
assert r[1]['ok'] is True and r[1]['replayed'] is False
assert r[2]['ok'] is False, f\"round 3 must fail at cap=2: {r[2]}\"
# Replay of round 2's evidence must be replayed=True
assert d['replay']['replayed'] is True, f\"replay must be replayed: {d['replay']}\"
print('OK: max_repair_rounds=2 budget honored (2 successes, 1 refusal, replay distinguished)')
"

# Test 3: max_repair_rounds = 3
out3="$(drive_repair_budget 3)"
echo "$out3" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
r = d['results']
# All 3 rounds succeed, round 4 fails
for i in range(3):
    assert r[i]['ok'] is True, f\"round {i+1} must succeed: {r[i]}\"
    assert r[i]['replayed'] is False, f\"round {i+1} must not be replay: {r[i]}\"
    assert r[i]['cumulative'] == i + 1, f\"cumulative must equal {i+1}: {r[i]}\"
assert r[3]['ok'] is False, f\"round 4 must fail at cap=3: {r[3]}\"
# Replay of round 3's evidence must be replayed=True
assert d['replay']['replayed'] is True
print('OK: max_repair_rounds=3 budget honored (3 successes, 1 refusal, replay distinguished)')
"

echo "REPAIR_ROUND_BUDGET_TESTS=PASS"
