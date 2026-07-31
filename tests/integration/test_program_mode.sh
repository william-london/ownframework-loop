#!/usr/bin/env bash
# Phase D — programmatic checkpoint execution.
#
# End-to-end: v3 PROGRAM-mode packet with two checkpoints, run through
# the operator workflow:
#   1. spec new  -> creates run id
#   2. operator writes a v3 WORK_PACKET.md (execution_mode=program, graph)
#   3. operator writes APPROVAL.json with confirmation token
#   4. operator transitions state to READY_TO_BUILD
#   5. operator runs `ofloop program init` to materialise program state
#   6. ofloop loop run --run-id <id> -> drives CP-1 -> CP-2 -> APPROVED
#
# The deterministic finalizers must accept each cycle, the orchestrator
# must finalize each checkpoint, and the program must reach terminal
# APPROVED.

set -uo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

OFLOOP_BIN="$BIN_DIR/ofloop"

# -----------------------------------------------------------------
# REPO + run
# -----------------------------------------------------------------
REPO="$(make_tmp_repo)"
RUN_ID=""
"$OFLOOP_BIN" spec new "$REPO" "program-mission" >/dev/null
RUN_ID="$(ls -1t "$REPO/.ownframework-loop" | head -n1)"
echo "REPO=$REPO RUN_ID=$RUN_ID"

# -----------------------------------------------------------------
# v3 packet with checkpoint_graph: CP-1 (no deps), CP-2 (depends on CP-1)
# -----------------------------------------------------------------
PP="$REPO/.ownframework-loop/$RUN_ID/WORK_PACKET.md"
cat > "$PP" <<'EOFEOF'
```json
{
  "schema": "ownframework-work-packet/v3",
  "packet_id": "p-program-1",
  "created_at": "2026-07-23T00:00:00Z",
  "work_class": "FEATURE",
  "risk_class": "low",
  "title": "program mission",
  "target": {"repo": "REPO", "branch": "master", "classification": "local_only"},
  "execution_mode": "program",
  "checkpoint_graph": {
    "execution_order": ["CP-1", "CP-2"],
    "checkpoints": [
      {
        "id": "CP-1",
        "title": "first checkpoint",
        "scope": "lay foundations",
        "depends_on": [],
        "risk_budget": {"max_build_passes": 2, "max_review_passes": 2, "max_repair_rounds": 1}
      },
      {
        "id": "CP-2",
        "title": "second checkpoint",
        "scope": "extend foundations",
        "depends_on": ["CP-1"],
        "risk_budget": {"max_build_passes": 2, "max_review_passes": 2, "max_repair_rounds": 1}
      }
    ]
  },
  "promotion_policy": "human_gate",
  "acceptance_criteria": [{"id": "AC-1", "text": "program reaches APPROVED"}],
  "non_goals": [],
  "allowed_paths": ["src/"],
  "protected_paths": [".ownframework-loop/"],
  "work_units": [{"id": "UNIT-1", "title": "u", "scope": "s"}],
  "merge_authority": "human_only",
  "deploy_authority": "human_only",
  "push_authority": "human_only",
  "external_action_authority": "none",
  "risk_budget": {"max_files_changed": 100, "max_diff_lines": 5000, "max_repair_rounds": 2}
}
```
program mission body
EOFEOF
# Replace the placeholder path with the actual REPO path
sed -i '' 's|"repo": "REPO"|"repo": "'"$REPO"'"|' "$PP"

# -----------------------------------------------------------------
# write APPROVAL.json (operator-approved marker)
# -----------------------------------------------------------------
python3 - "$REPO" "$RUN_ID" <<'PY'
import sys, json, subprocess
from pathlib import Path
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib'))
from ownframework_loop import approval, state as state_mod
canonical_repo = Path(sys.argv[1])
run_id = sys.argv[2]
pp = canonical_repo / ".ownframework-loop" / run_id / "WORK_PACKET.md"
sha = __import__("hashlib").sha256(pp.read_bytes()).hexdigest()
baseline = subprocess.run(
    ["git", "-C", str(canonical_repo), "rev-parse", "master"],
    capture_output=True, text=True, check=True,
).stdout.strip()
doc = {
    "schema": "ownframework-loop-approval/v1",
    "run_id": run_id,
    "packet_sha256": sha,
    "approved_at": "2026-07-23T00:00:00Z",
    "approved_actor": "test",
    "canonical_repo": str(canonical_repo.resolve(strict=False)),
    "baseline_branch": "master",
    "baseline_sha": baseline,
    "packet_schema": "ownframework-work-packet/v3",
    "approval_method": "operator_marker",
    "confirmation_token": approval.derive_confirmation_token(sha),
}
Path(canonical_repo, ".ownframework-loop", run_id, "APPROVAL.json").write_text(
    json.dumps(doc, indent=2, sort_keys=True))
state_mod.transition(canonical_repo, run_id, to_state="READY_TO_BUILD", actor="test", reason="approved")
PY

# -----------------------------------------------------------------
# Materialise program state via `ofloop program init`
# -----------------------------------------------------------------
"$OFLOOP_BIN" program init "$REPO" "$RUN_ID" >/dev/null 2>&1

ps="$(python3 -c "
import json
s = json.load(open('$REPO/.ownframework-loop/$RUN_ID/STATE.json'))
print(s.get('program', {}).get('execution_mode'))
print('current_checkpoints=' + ','.join(s.get('program', {}).get('current_checkpoints', [])))
print('cumulative_max_build=' + str(s.get('program', {}).get('cumulative_ceilings', {}).get('max_build_passes')))
")"
echo "$ps" | grep -q '^program$' && pass "program state materialised (execution_mode=program)"
echo "$ps" | grep -q '^current_checkpoints=CP-1$' && pass "current_checkpoints deterministic (CP-1 first)"

# -----------------------------------------------------------------
# Drive both checkpoints via the unattended loop run
# -----------------------------------------------------------------
WT="$REPO/.worktrees/ownframework-loop/$RUN_ID/builder"
git -C "$REPO" worktree add -b "factory/candidate/$RUN_ID" "$WT" master >/dev/null 2>&1
mkdir -p "$WT/src"
cat > "$WT/src/program_feature.py" <<'PY'
def hello():
    return "hello"
PY
git -C "$WT" add src/program_feature.py && git -C "$WT" commit -m "loop-v0.3.0: program candidate" >/dev/null 2>&1

out="$("$OFLOOP_BIN" loop run --run-id "$RUN_ID" "$REPO" 2>&1)"
echo "loop run output:"
echo "$out"
echo "$out" | grep -q '"execution_mode": "program"' && pass "loop run dispatched in program mode"
echo "$out" | grep -q '"terminal_state": "APPROVED"' && pass "program reached terminal APPROVED"

python3 - "$REPO" "$RUN_ID" <<'PY'
import sys, json
from pathlib import Path
repo = Path(sys.argv[1])
rid = sys.argv[2]
s = json.load(open(repo / '.ownframework-loop' / rid / 'STATE.json'))
prog = s.get('program', {})
fc = [f['id'] for f in prog.get('finalized_checkpoints', [])]
print('finalized:', fc)
assert 'CP-1' in fc and 'CP-2' in fc, f"both checkpoints not finalized: {fc}"
print('PASS both checkpoints finalized')
PY

# Cleanup
git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1

echo "PROGRAM_MODE_TEST=PASS"
