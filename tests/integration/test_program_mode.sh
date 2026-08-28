#!/usr/bin/env bash
# v0.6 PROGRAM mode through the typed dispatch boundary.
#
# No provider/model is required. The test supplies deterministic synthetic
# semantic artifacts at the exact pass-scoped paths that a real runner would
# fill, then proves CP-1 -> CP-2 -> terminal APPROVED.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

OFLOOP="$OFLOOP_BIN"
REPO="$(make_tmp_repo)"

"$OFLOOP" spec new "$REPO" "program-dispatch-mission" >/dev/null
RUN_ID="$(ls -1t "$REPO/.ownframework-loop" | head -n1)"
PP="$REPO/.ownframework-loop/$RUN_ID/WORK_PACKET.md"

python3 - "$PP" "$REPO" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
repo = sys.argv[2]
packet = {
    "schema": "ownframework-work-packet/v3",
    "packet_id": "v060-program-dispatch",
    "created_at": "2026-08-28T00:00:00Z",
    "work_class": "FEATURE",
    "risk_class": "low",
    "title": "program dispatch mission",
    "target": {"repo": repo, "branch": "master", "classification": "local_only"},
    "execution_mode": "program",
    "checkpoint_graph": {
        "execution_order": ["CP-1", "CP-2"],
        "checkpoints": [
            {"id": "CP-1", "title": "foundation", "scope": "create first feature slice",
             "depends_on": [], "risk_budget": {"max_build_passes": 2, "max_review_passes": 2, "max_repair_rounds": 1}},
            {"id": "CP-2", "title": "extension", "scope": "extend same candidate",
             "depends_on": ["CP-1"], "risk_budget": {"max_build_passes": 2, "max_review_passes": 2, "max_repair_rounds": 1}}
        ]
    },
    "promotion_policy": "human_gate",
    "acceptance_criteria": [{"id": "AC-1", "text": "program reaches APPROVED"}],
    "non_goals": [],
    "allowed_paths": ["src/"],
    "protected_paths": [".ownframework-loop/"],
    "work_units": [{"id": "UNIT-1", "title": "program unit", "scope": "src/"}],
    "merge_authority": "human_only",
    "deploy_authority": "human_only",
    "push_authority": "human_only",
    "external_action_authority": "none",
    "risk_budget": {
        "max_build_passes": 4,
        "max_review_passes": 4,
        "max_repair_rounds": 2,
        "max_files_changed": 25,
        "max_diff_lines": 1000
    }
}
fence = chr(96) * 3
p.write_text(fence + "json\n" + json.dumps(packet, sort_keys=True) + "\n" + fence + "\n")
PY

fill_build_semantic() {
  local semantic="$1" label="$2"
  python3 - "$semantic" "$label" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
label = sys.argv[2]
d = json.loads(p.read_text())
d["summary"] = f"synthetic semantic builder completed {label}"
d["outcome_requested"] = "candidate_ready"
d["unit_ids_completed"] = ["UNIT-1"]
d["acceptance_addressed"] = ["AC-1"]
d["notes"] = "provider-free PROGRAM dispatch integration proof"
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
}

fill_review_semantic() {
  local semantic="$1" label="$2"
  python3 - "$semantic" "$label" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
label = sys.argv[2]
d = json.loads(p.read_text())
d["validation_results"] = []
d["acceptance_results"] = [{"id": "AC-1", "result": "pass", "evidence": f"{label} exact-SHA review"}]
d["non_goal_results"] = []
d["findings"] = []
d["recommended_verdict"] = "APPROVED"
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
}

run_checkpoint() {
  local cp="$1" value="$2"

  BUILD_ORDER="$("$OFLOOP" dispatch claim "$REPO" "$RUN_ID")"
  assert_eq "$(printf '%s' "$BUILD_ORDER" | jq -r '.decision')" "BUILD" "$cp dispatch BUILD"
  assert_eq "$(printf '%s' "$BUILD_ORDER" | jq -r '.prepare.cp_id')" "$cp" "$cp build identity"

  WT="$(printf '%s' "$BUILD_ORDER" | jq -r '.worktree')"
  BSEM="$(printf '%s' "$BUILD_ORDER" | jq -r '.semantic_path')"
  assert_dir_exists "$WT" "$cp builder worktree exists"
  assert_file_exists "$BSEM" "$cp builder semantic skeleton exists"

  mkdir -p "$WT/src"
  cat > "$WT/src/program_feature.py" <<PY
def program_value():
    return "$value"
PY
  git -C "$WT" add src/program_feature.py
  git -C "$WT" commit -m "test: $cp program candidate" >/dev/null

  fill_build_semantic "$BSEM" "$cp"
  "$OFLOOP" dispatch finalize "$REPO" "$RUN_ID" BUILD "$BSEM" >/dev/null
  assert_eq "$(jq -r '.state' "$REPO/.ownframework-loop/$RUN_ID/STATE.json")" "READY_FOR_REVIEW" "$cp ready for review"

  REVIEW_ORDER="$("$OFLOOP" dispatch claim "$REPO" "$RUN_ID")"
  assert_eq "$(printf '%s' "$REVIEW_ORDER" | jq -r '.decision')" "REVIEW" "$cp dispatch REVIEW"
  RSEM="$(printf '%s' "$REVIEW_ORDER" | jq -r '.semantic_path')"
  assert_file_exists "$RSEM" "$cp reviewer semantic skeleton exists"
  fill_review_semantic "$RSEM" "$cp"
  "$OFLOOP" dispatch finalize "$REPO" "$RUN_ID" REVIEW "$RSEM" >/dev/null
}

run_checkpoint "CP-1" "one"
python3 - "$REPO" "$RUN_ID" <<'PY'
import json, sys
from pathlib import Path
s = json.load(open(Path(sys.argv[1]) / ".ownframework-loop" / sys.argv[2] / "STATE.json"))
assert s["state"] == "READY_TO_BUILD", s
assert s["program"]["current_checkpoints"] == ["CP-2"], s["program"]
assert [x["id"] for x in s["program"]["finalized_checkpoints"]] == ["CP-1"], s["program"]
print("PASS CP-1 advanced deterministically to CP-2")
PY

run_checkpoint "CP-2" "two"
TERMINAL="$("$OFLOOP" dispatch claim "$REPO" "$RUN_ID")"
assert_eq "$(printf '%s' "$TERMINAL" | jq -r '.decision')" "TERMINAL" "PROGRAM dispatch terminal"
assert_eq "$(printf '%s' "$TERMINAL" | jq -r '.state')" "APPROVED" "PROGRAM terminal APPROVED"

python3 - "$REPO" "$RUN_ID" <<'PY'
import json, sys
from pathlib import Path
s = json.load(open(Path(sys.argv[1]) / ".ownframework-loop" / sys.argv[2] / "STATE.json"))
prog = s["program"]
assert s["state"] == "APPROVED", s
assert prog["current_checkpoints"] == [], prog
assert [x["id"] for x in prog["finalized_checkpoints"]] == ["CP-1", "CP-2"], prog
assert prog["cumulative_counters"]["build_pass_count"] == 2, prog
assert prog["cumulative_counters"]["review_pass_count"] == 2, prog
print("PASS PROGRAM finalized CP-1 and CP-2 exactly once")
PY

echo "PROGRAM_MODE_DISPATCH_TEST=PASS"
