#!/usr/bin/env bash
# Case 32: STOP handling.

set -uo pipefail
. "$(dirname "$0")/../_helpers.sh"

REPO="$(make_tmp_repo)"
RUN_DIR="$(make_tmp_run "$REPO")"

# Approve a packet so we are not in AWAITING_APPROVAL.
PACKET_MD='```json
{
  "schema": "ownframework-work-packet/v1",
  "packet_id": "stop-001",
  "created_at": "2026-07-23T05:00:00Z",
  "work_class": "FEATURE",
  "risk_class": "medium",
  "title": "Stop test",
  "target": {"repo": "'"$REPO"'", "branch": "master", "classification": "local_only"},
  "acceptance_criteria": [{"id": "AC-1", "text": "x"}],
  "non_goals": [{"id": "NG-1", "text": "y"}],
  "allowed_paths": ["src/"],
  "protected_paths": [".ownframework-loop/"],
  "work_units": [{"id": "UNIT-1", "title": "u", "scope": "s"}],
  "merge_authority": "human_only",
  "deploy_authority": "human_only",
  "push_authority": "human_only",
  "external_action_authority": "none"
}
```
# Mission
stop test.'
write_packet "$REPO" "$RUN_DIR" "$PACKET_MD" >/dev/null
"$OFLOOP_BIN" spec approve "$REPO" "$RUN_DIR" >/dev/null

# Run is in READY_TO_BUILD. Issue a stop.
"$OFLOOP_BIN" spec stop "$REPO" "$RUN_DIR" --reason "test stop" >/dev/null
assert_file_exists "$REPO/.ownframework-loop/$RUN_DIR/STOP" "STOP file created"
STATE=$(python3 -c "import json; print(json.load(open('$REPO/.ownframework-loop/$RUN_DIR/STATE.json'))['state'])")
assert_eq "$STATE" "STOPPED" "state STOPPED after stop"

# Marker should be STOP.
MARKER=$("$OFLOOP_BIN" build marker "$REPO" "$RUN_DIR")
assert_contains "$MARKER" "OF_LOOP_ACTION=STOP" "builder marker stops on terminal"

# Cleanup
rm -rf "$REPO/.ownframework-loop" "$REPO/.worktrees"
echo "ALL PASS"
