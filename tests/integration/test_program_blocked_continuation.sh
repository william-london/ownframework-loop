#!/usr/bin/env bash
# PROGRAM continuation: one explicit repair entitlement plus DONE->QUEUED,
# with crash-safe/idempotent retries and no accounting reset.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"

REPO="$(make_tmp_repo)"
DB="$(mktemp -t ofloop-continuation.XXXXXX.sqlite3)"
RUN="$("$OFLOOP_BIN" spec new "$REPO" "blocked continuation" | jq -r '.run_id')"
PP="$REPO/.ownframework-loop/$RUN/WORK_PACKET.md"

python3 -B - "$PP" "$REPO" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1]); repo = sys.argv[2]
packet = {
    "schema": "ownframework-work-packet/v3",
    "packet_id": "continuation-test",
    "created_at": "2026-09-14T00:00:00Z",
    "work_class": "HARDENING", "risk_class": "low",
    "title": "blocked continuation",
    "target": {"repo": repo, "branch": "master", "classification": "local_only"},
    "execution_mode": "program",
    "checkpoint_graph": {
        "execution_order": ["CP-1", "CP-2"],
        "checkpoints": [
            {"id": "CP-1", "title": "one", "scope": "src/", "depends_on": [],
             "acceptance_criterion_ids": ["AC-1"],
             "risk_budget": {"max_build_passes": 3, "max_review_passes": 3, "max_repair_rounds": 1}},
            {"id": "CP-2", "title": "two", "scope": "src/", "depends_on": ["CP-1"],
             "acceptance_criterion_ids": ["AC-2"],
             "risk_budget": {"max_build_passes": 3, "max_review_passes": 3, "max_repair_rounds": 1}},
        ],
    },
    "promotion_policy": "human_gate",
    "acceptance_criteria": [{"id": "AC-1", "text": "one"}, {"id": "AC-2", "text": "two"}],
    "non_goals": [], "network_read_allowlist": [], "allowed_paths": ["src/"],
    "protected_paths": [".ownframework-loop/"],
    "work_units": [{"id": "UNIT-1", "title": "one", "scope": "src/"}],
    "merge_authority": "human_only", "deploy_authority": "human_only",
    "push_authority": "human_only", "external_action_authority": "none",
    "risk_budget": {"max_build_passes": 6, "max_review_passes": 6,
                    "max_repair_rounds": 2, "max_files_changed": 25,
                    "max_diff_lines": 1000},
}
p.write_text("```json\n" + json.dumps(packet, indent=2, sort_keys=True) + "\n```\n", encoding="utf-8")
PY

ORDER="$($OFLOOP_BIN dispatch claim "$REPO" "$RUN")"
WT="$(printf '%s' "$ORDER" | jq -r '.worktree')"
mkdir -p "$WT/src"
printf '%s\n' 'continuation candidate' > "$WT/src/candidate.py"
git -C "$WT" add src/candidate.py
git -C "$WT" -c user.name=test -c user.email=test@local commit -m 'test: blocked continuation candidate' >/dev/null
CANDIDATE="$(git -C "$WT" rev-parse HEAD)"

PYTHONDONTWRITEBYTECODE=1 python3 -B - "$REPO" "$RUN" "$CANDIDATE" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import state
repo = Path(sys.argv[1]); run = sys.argv[2]; candidate = sys.argv[3]
state.transition(repo, run, to_state="BLOCKED", actor="test", reason="synthetic terminal blocker", commit_sha=candidate)
PY

ENQ="$($OFLOOP_BIN supervisor enqueue "$REPO" "$RUN" --runner claude-code --db "$DB")"
assert_eq "$(printf '%s' "$ENQ" | jq -r '.status')" "QUEUED" "continuation test enrollment"
BEFORE="$($OFLOOP_BIN supervisor status "$REPO" "$RUN" --db "$DB")"
STARTED="$(printf '%s' "$BEFORE" | jq -r '.execution_started_at')"

PYTHONPATH="$OFLOOP_LIB" python3 -B - "$REPO" "$RUN" "$CANDIDATE" "$DB" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import supervisor
repo = Path(sys.argv[1]); run = sys.argv[2]; candidate = sys.argv[3]; db = Path(sys.argv[4])
real = supervisor._continuation_write
calls = {"n": 0}
def crash_after_state(path, payload):
    calls["n"] += 1
    if calls["n"] == 2:
        raise RuntimeError("simulated crash after protocol transition")
    return real(path, payload)
supervisor._continuation_write = crash_after_state
try:
    try:
        supervisor.continue_program(
            canonical_repo=repo, run_id=run,
            reason="bounded operator continuation test",
            expected_candidate_sha=candidate, db_path=db,
        )
    except RuntimeError as exc:
        assert "simulated crash" in str(exc), exc
    else:
        raise AssertionError("continuation crash injection did not fire")
finally:
    supervisor._continuation_write = real
state = supervisor.state_mod.load_verified(repo, run)
assert state["state"] == "READY_TO_BUILD", state
assert state["repair_round"] == 1, state
with supervisor._managed_connect_readonly(db) as conn:
    row, _ = supervisor._logical_job_row(conn, repo, run)
    assert row["status"] == "QUEUED", dict(row)
print("CONTINUATION_CRASH_WINDOW=PASS")
PY

# The supported command completes the second half of the interrupted operation.
FIRST="$($OFLOOP_BIN supervisor continue-program "$REPO" "$RUN" --reason 'bounded operator continuation test' --expected-candidate-sha "$CANDIDATE" --db "$DB")"
assert_eq "$(printf '%s' "$FIRST" | jq -r '.status')" "QUEUED" "blocked PROGRAM requeued"
STATE="$REPO/.ownframework-loop/$RUN/STATE.json"
assert_eq "$(jq -r '.state' "$STATE")" "READY_TO_BUILD" "blocked state reopened through FSM"
assert_eq "$(jq -r '.repair_round' "$STATE")" "1" "one repair entitlement consumed"
assert_eq "$(printf '%s' "$FIRST" | jq -r '.build_pass_count')" "1" "build counter preserved"
assert_eq "$(printf '%s' "$FIRST" | jq -r '.review_pass_count')" "0" "review counter preserved"
assert_eq "$(printf '%s' "$FIRST" | jq -r '.execution_started_at')" "$STARTED" "execution clock preserved"

RECEIPT="$(printf '%s' "$FIRST" | jq -r '.continuation.receipt')"
assert_file_exists "$RECEIPT" "continuation receipt exists"
assert_eq "$(python3 -c 'import os,sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "o"))' "$RECEIPT")" "600" "continuation receipt is private"

SECOND="$($OFLOOP_BIN supervisor continue-program "$REPO" "$RUN" --reason 'bounded operator continuation test' --expected-candidate-sha "$CANDIDATE" --db "$DB")"
assert_eq "$(printf '%s' "$SECOND" | jq -r '.continuation.state.idempotent')" "true" "repeat continuation is idempotent"
assert_eq "$(jq -r '.repair_round' "$STATE")" "1" "repeat does not double-fund repair"
assert_eq "$(printf '%s' "$SECOND" | jq -r '.build_pass_count')" "1" "repeat preserves build count"

if "$OFLOOP_BIN" supervisor continue-program "$REPO" "$RUN" \
  --reason 'contradictory second operator intent' \
  --expected-candidate-sha "$CANDIDATE" --db "$DB" >/dev/null 2>&1; then
  fail "contradictory continuation unexpectedly succeeded"
fi
assert_eq "$(jq -r '.repair_round' "$STATE")" "1" "contradictory retry cannot spend repair"
assert_eq "$(git -C "$WT" rev-parse HEAD)" "$CANDIDATE" "candidate source preserved"

echo "PROGRAM_BLOCKED_CONTINUATION=PASS"
