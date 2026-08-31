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
             "depends_on": [], "acceptance_criterion_ids": ["AC-1"],
             "risk_budget": {"max_build_passes": 2, "max_review_passes": 2, "max_repair_rounds": 1}},
            {"id": "CP-2", "title": "extension", "scope": "extend same candidate",
             "depends_on": ["CP-1"], "acceptance_criterion_ids": ["AC-2"],
             "risk_budget": {"max_build_passes": 2, "max_review_passes": 2, "max_repair_rounds": 1}}
        ]
    },
    "promotion_policy": "human_gate",
    "acceptance_criteria": [
        {"id": "AC-1", "text": "foundation checkpoint is correct"},
        {"id": "AC-2", "text": "extension checkpoint is correct"}
    ],
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
  local semantic="$1" label="$2" ac_id="$3"
  python3 - "$semantic" "$label" "$ac_id" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
label = sys.argv[2]
ac_id = sys.argv[3]
d = json.loads(p.read_text())
d["summary"] = f"synthetic semantic builder completed {label}"
d["outcome_requested"] = "candidate_ready"
d["unit_ids_completed"] = ["UNIT-1"]
d["acceptance_addressed"] = [ac_id]
d["notes"] = "provider-free PROGRAM dispatch integration proof"
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
}

fill_review_semantic() {
  local semantic="$1" label="$2" ac_id="$3"
  python3 - "$semantic" "$label" "$ac_id" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
label = sys.argv[2]
ac_id = sys.argv[3]
d = json.loads(p.read_text())
d["validation_results"] = []
d["acceptance_results"] = [{"id": ac_id, "result": "pass", "evidence": f"{label} exact-SHA review"}]
d["non_goal_results"] = []
d["findings"] = []
d["recommended_verdict"] = "APPROVED"
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
}

run_checkpoint() {
  local cp="$1" value="$2" ac_id="$3"

  set +e
  BUILD_ORDER="$("$OFLOOP" dispatch claim "$REPO" "$RUN_ID" 2>&1)"
  BUILD_RC=$?
  set -e
  [[ "$BUILD_RC" -eq 0 ]] || fail "$cp dispatch BUILD command failed rc=$BUILD_RC output=$BUILD_ORDER"
  assert_eq "$(printf '%s' "$BUILD_ORDER" | jq -r '.decision')" "BUILD" "$cp dispatch BUILD"
  assert_eq "$(printf '%s' "$BUILD_ORDER" | jq -r '.prepare.cp_id')" "$cp" "$cp build identity"
  assert_eq "$(printf '%s' "$BUILD_ORDER" | jq -r '.acceptance_criterion_ids[0]')" "$ac_id" "$cp BUILD scoped AC"

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

  fill_build_semantic "$BSEM" "$cp" "$ac_id"
  set +e
  BUILD_FINALIZE_OUT="$("$OFLOOP" dispatch finalize "$REPO" "$RUN_ID" BUILD "$BSEM" 2>&1)"
  BUILD_FINALIZE_RC=$?
  set -e
  [[ "$BUILD_FINALIZE_RC" -eq 0 ]] || fail "$cp dispatch BUILD finalize failed rc=$BUILD_FINALIZE_RC output=$BUILD_FINALIZE_OUT"
  assert_eq "$(jq -r '.state' "$REPO/.ownframework-loop/$RUN_ID/STATE.json")" "READY_FOR_REVIEW" "$cp ready for review"

  REVIEW_ORDER="$("$OFLOOP" dispatch claim "$REPO" "$RUN_ID")"
  assert_eq "$(printf '%s' "$REVIEW_ORDER" | jq -r '.decision')" "REVIEW" "$cp dispatch REVIEW"
  assert_eq "$(printf '%s' "$REVIEW_ORDER" | jq -r '.checkpoint_id')" "$cp" "$cp REVIEW checkpoint identity"
  assert_eq "$(printf '%s' "$REVIEW_ORDER" | jq -r '.acceptance_criterion_ids[0]')" "$ac_id" "$cp REVIEW scoped AC"
  RSEM="$(printf '%s' "$REVIEW_ORDER" | jq -r '.semantic_path')"
  assert_file_exists "$RSEM" "$cp reviewer semantic skeleton exists"
  fill_review_semantic "$RSEM" "$cp" "$ac_id"
  "$OFLOOP" dispatch finalize "$REPO" "$RUN_ID" REVIEW "$RSEM" >/dev/null
  assert_eq "$(jq -r '.checkpoint_id' "$REPO/.ownframework-loop/$RUN_ID/REVIEW_VERDICT.json")" "$cp" "$cp verdict checkpoint"
  assert_eq "$(jq -r '.expected_acceptance_criterion_ids[0]' "$REPO/.ownframework-loop/$RUN_ID/REVIEW_VERDICT.json")" "$ac_id" "$cp verdict scoped AC"
}

run_checkpoint "CP-1" "one" "AC-1"
python3 - "$REPO" "$RUN_ID" <<'PY'
import json, sys
from pathlib import Path
s = json.load(open(Path(sys.argv[1]) / ".ownframework-loop" / sys.argv[2] / "STATE.json"))
assert s["state"] == "READY_TO_BUILD", s
assert s["program"]["current_checkpoints"] == ["CP-2"], s["program"]
assert [x["id"] for x in s["program"]["finalized_checkpoints"]] == ["CP-1"], s["program"]
print("PASS CP-1 advanced deterministically to CP-2")
PY

run_checkpoint "CP-2" "two" "AC-2"
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

python3 - "$REPO/.ownframework-loop/$RUN_ID/WORK_PACKET.md" <<'PY'
import copy, json, re, sys
from pathlib import Path
from ownframework_loop import program
text = Path(sys.argv[1]).read_text()
meta = json.loads(re.search(r"```json\s*\n(.*?)\n```", text, re.S).group(1))
assert program.validate_checkpoint_graph(meta) == [], program.validate_checkpoint_graph(meta)

legacy = copy.deepcopy(meta)
for cp in legacy["checkpoint_graph"]["checkpoints"]:
    cp.pop("acceptance_criterion_ids", None)
assert program.validate_checkpoint_graph(legacy) == [], program.validate_checkpoint_graph(legacy)

partial = copy.deepcopy(meta)
partial["checkpoint_graph"]["checkpoints"][1].pop("acceptance_criterion_ids")
errs = program.validate_checkpoint_graph(partial)
assert any("every checkpoint must declare" in e for e in errs), errs

unknown = copy.deepcopy(meta)
unknown["checkpoint_graph"]["checkpoints"][1]["acceptance_criterion_ids"] = ["AC-NOT-REAL"]
errs = program.validate_checkpoint_graph(unknown)
assert any("unknown ids" in e for e in errs), errs
assert any("do not cover packet AC ids" in e for e in errs), errs
print("PASS PROGRAM checkpoint acceptance scoping validation")
PY

echo "PROGRAM_MODE_DISPATCH_TEST=PASS"
