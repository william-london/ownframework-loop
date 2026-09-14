#!/usr/bin/env bash
# v0.9.2 — checkpoint-local validation and bounded ordinary scope repair.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"

python3 - "$ROOT_DIR" <<'PY'
import copy
import inspect
import sys
from pathlib import Path

root = Path(sys.argv[1])
from ownframework_loop import build_finalize, packet, program, review_finalize, schema_validate

validation = lambda name, command: {"name": name, "command": command, "kind": "fast"}
cp0 = {
    "id": "CP-0", "title": "first", "scope": "first", "depends_on": [],
    "acceptance_criterion_ids": ["AC-1"],
    "required_validation": [validation("cp0", "printf CP0")],
    "risk_budget": {"max_build_passes": 2, "max_review_passes": 2, "max_repair_rounds": 1},
}
cp1 = {
    "id": "CP-1", "title": "second", "scope": "second", "depends_on": ["CP-0"],
    "acceptance_criterion_ids": ["AC-2"],
    "required_validation": [validation("cp1", "printf CP1")],
    "risk_budget": {"max_build_passes": 2, "max_review_passes": 2, "max_repair_rounds": 1},
}
base = {
    "schema": "ownframework-work-packet/v3", "packet_id": "checkpoint-validation",
    "created_at": "2026-09-14T00:00:00Z", "work_class": "TESTING", "risk_class": "low",
    "title": "checkpoint validation", "target": {"repo": "/tmp/repo", "branch": "master", "classification": "local_only"},
    "execution_mode": "program", "checkpoint_graph": {
        "execution_order": ["CP-0", "CP-1"], "checkpoints": [cp0, cp1],
    },
    "acceptance_criteria": [{"id": "AC-1", "text": "one"}, {"id": "AC-2", "text": "two"}],
    "non_goals": [], "allowed_paths": ["src/"], "protected_paths": [".ownframework-loop/"],
    "work_units": [{"id": "UNIT-1", "title": "unit", "scope": "src/"}],
    "merge_authority": "human_only", "deploy_authority": "human_only",
    "push_authority": "human_only", "external_action_authority": "none",
    "required_validation": [validation("global", "printf GLOBAL")],
    "risk_budget": {"max_build_passes": 4, "max_review_passes": 4, "max_repair_rounds": 2,
                     "max_files_changed": 25, "max_diff_lines": 1000},
}
state0 = {"program": {"current_checkpoints": ["CP-0"]}}
state1 = {"program": {"current_checkpoints": ["CP-1"]}}
assert [x["name"] for x in program.resolve_effective_required_validation(base, state0)] == ["global", "cp0"]
assert [x["name"] for x in program.resolve_effective_required_validation(base, state1)] == ["global", "cp1"]
assert [x["name"] for x in program.resolve_effective_required_validation({"required_validation": base["required_validation"]}, {})] == ["global"]
assert not schema_validate.validate_packet(base)
budget_bad = copy.deepcopy(base)
budget_bad["checkpoint_graph"]["checkpoints"][0]["risk_budget"]["max_build_passes"] = 1
budget_errors = packet.validate_packet_metadata(budget_bad)
assert any("CP-0" in error and "cannot realize max_repair_rounds=1" in error for error in budget_errors), budget_errors
bad = copy.deepcopy(base)
bad["checkpoint_graph"]["checkpoints"][0]["required_validation"][0]["kind"] = "not-a-kind"
assert schema_validate.validate_packet(bad), "malformed checkpoint validation must fail admission"
assert build_finalize.program_mod.resolve_effective_required_validation is program.resolve_effective_required_validation
assert review_finalize.program_mod.resolve_effective_required_validation is program.resolve_effective_required_validation
assert "resolve_effective_required_validation(meta, state)" in inspect.getsource(build_finalize)
assert "resolve_effective_required_validation(meta, active_state)" in inspect.getsource(review_finalize)

spec_text = (root / "skills/spec/SKILL.md").read_text()
spec_agent_text = (root / ".agents/skills/of-loop-spec/SKILL.md").read_text()
for text in (spec_text, spec_agent_text):
    assert "MUST be satisfiable from the first checkpoint onward" in text
    assert "checkpoint_graph.checkpoints[N].required_validation" in text
build_text = (root / "skills/build/SKILL.md").read_text()
build_agent_text = (root / ".agents/skills/of-loop-build/SKILL.md").read_text()
for text in (build_text, build_agent_text):
    assert "exact baseline-to-candidate" in text and "changed-path set" in text
    assert "never knowingly" in text
print("CHECKPOINT_VALIDATION_RESOLUTION=PASS")
print("CHECKPOINT_SCHEMA_CONTRACT=PASS")
print("BUILD_REVIEW_VALIDATION_PARITY=PASS")
print("FUTURE_CHECKPOINT_ISOLATION=PASS")
print("PER_CHECKPOINT_REALIZABILITY=PASS")
print("SPEC_AND_BUILDER_CONTRACTS=PASS")
PY

fill_builder_result() {
  local semantic="$1"
  python3 - "$semantic" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
d = json.loads(p.read_text())
d.update({"summary": "scope repair synthetic builder", "outcome_requested": "candidate_ready",
          "unit_ids_completed": ["UNIT-1"], "acceptance_addressed": ["AC-1"]})
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
}

# Ordinary scope drift must become a funded, non-reviewable repair state and
# expose the exact unauthorized path to the next builder.
REPO="$(make_tmp_repo)"
RUN="$(make_approved_run "$REPO" FEATURE low "ordinary-scope-repair")"
WT="$REPO/.worktrees/ownframework-loop/$RUN/builder"
git -C "$REPO" worktree add -b "factory/candidate/$RUN" "$WT" master >/dev/null 2>&1
mkdir -p "$WT/src" "$WT/docs"
printf '%s\n' 'in scope' > "$WT/src/kept.py"
printf '%s\n' 'remove me' > "$WT/docs/unauthorized.md"
git -C "$WT" add src/kept.py docs/unauthorized.md
git -C "$WT" commit -m "test: ordinary scope drift" >/dev/null
ORDER="$("$OFLOOP_BIN" dispatch claim "$REPO" "$RUN")"
SEM="$(printf '%s' "$ORDER" | jq -r '.semantic_path')"
fill_builder_result "$SEM"
"$OFLOOP_BIN" dispatch finalize "$REPO" "$RUN" BUILD "$SEM" >/dev/null
RUNDIR="$REPO/.ownframework-loop/$RUN"
assert_eq "$(jq -r '.scope_check.result' "$RUNDIR/BUILD_RECEIPT.json")" "fail" "ordinary scope receipt fails scope check"
assert_eq "$(jq -r '.next_state' "$RUNDIR/BUILD_RECEIPT.json")" "CHANGES_REQUESTED" "ordinary scope enters repair state"
assert_eq "$(jq -r '.state' "$RUNDIR/STATE.json")" "READY_TO_BUILD" "ordinary scope does not reach review"
assert_eq "$(jq -r '.repair_round' "$RUNDIR/STATE.json")" "1" "ordinary scope repair round is funded"

ORDER2="$("$OFLOOP_BIN" dispatch claim "$REPO" "$RUN")"
assert_eq "$(printf '%s' "$ORDER2" | jq -r '.repair_context.scope_findings[0].path')" "docs/unauthorized.md" "repair context names unauthorized path"
SEM2="$(printf '%s' "$ORDER2" | jq -r '.semantic_path')"
python3 - "$WT/docs/unauthorized.md" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).unlink()
PY
git -C "$WT" add -u docs/unauthorized.md
git -C "$WT" commit -m "test: remove ordinary scope drift" >/dev/null
fill_builder_result "$SEM2"
"$OFLOOP_BIN" dispatch finalize "$REPO" "$RUN" BUILD "$SEM2" >/dev/null
assert_eq "$(jq -r '.scope_check.result' "$RUNDIR/BUILD_RECEIPT.json")" "pass" "repaired candidate is back in scope"
assert_eq "$(jq -r '.next_state' "$RUNDIR/BUILD_RECEIPT.json")" "READY_FOR_REVIEW" "repaired candidate reaches review boundary"
assert_eq "$(jq -r '.state' "$RUNDIR/STATE.json")" "READY_FOR_REVIEW" "repaired candidate is reviewable only after scope passes"
python3 - "$RUNDIR/BUILD_RECEIPT.json" <<'PY'
import json, sys
from pathlib import Path
from ownframework_loop import schema_validate
doc = json.loads(Path(sys.argv[1]).read_text())
assert not schema_validate.validate_receipt(doc), schema_validate.validate_receipt(doc)
PY
echo "ORDINARY_SCOPE_REPAIR=PASS"

# Protected paths remain terminal even though ordinary scope drift is
# repairable.
PROTECTED_REPO="$(make_tmp_repo)"
PROTECTED_RUN="$(make_approved_run "$PROTECTED_REPO" FEATURE low "protected-path")"
PROTECTED_WT="$PROTECTED_REPO/.worktrees/ownframework-loop/$PROTECTED_RUN/builder"
git -C "$PROTECTED_REPO" worktree add -b "factory/candidate/$PROTECTED_RUN" "$PROTECTED_WT" master >/dev/null 2>&1
mkdir -p "$PROTECTED_WT/.ownframework-loop"
printf '%s\n' 'blocked' > "$PROTECTED_WT/.ownframework-loop/forbidden.txt"
git -C "$PROTECTED_WT" add .ownframework-loop/forbidden.txt
git -C "$PROTECTED_WT" commit -m "test: protected path" >/dev/null
PROTECTED_ORDER="$("$OFLOOP_BIN" dispatch claim "$PROTECTED_REPO" "$PROTECTED_RUN")"
PROTECTED_SEM="$(printf '%s' "$PROTECTED_ORDER" | jq -r '.semantic_path')"
fill_builder_result "$PROTECTED_SEM"
"$OFLOOP_BIN" dispatch finalize "$PROTECTED_REPO" "$PROTECTED_RUN" BUILD "$PROTECTED_SEM" >/dev/null
PROTECTED_DIR="$PROTECTED_REPO/.ownframework-loop/$PROTECTED_RUN"
assert_eq "$(jq -r '.protected_path_check.result' "$PROTECTED_DIR/BUILD_RECEIPT.json")" "fail" "protected path receipt fails"
assert_eq "$(jq -r '.next_state' "$PROTECTED_DIR/BUILD_RECEIPT.json")" "BLOCKED" "protected path remains terminal"
assert_eq "$(jq -r '.state' "$PROTECTED_DIR/STATE.json")" "BLOCKED" "protected path blocks state"
echo "PROTECTED_SCOPE_TERMINAL=PASS"

echo "PROGRAM_AUTONOMY_SEAMS=PASS"
