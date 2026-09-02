#!/usr/bin/env bash
# v0.8.5 — model-free distinction between build-validation retry and
# reviewer-funded repair in PROGRAM mode.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"
OFLOOP="$OFLOOP_BIN"

make_program_packet() {
  local repo="$1" title="$2" validation="$3"
  "$OFLOOP" spec new "$repo" "$title" >/dev/null
  local rid
  rid="$(ls -1t "$repo/.ownframework-loop" | head -n1)"
  python3 -B - "$repo/.ownframework-loop/$rid/WORK_PACKET.md" "$repo" "$title" "$validation" <<'PY'
import json, sys
from pathlib import Path
packet_path = Path(sys.argv[1]); repo, title, validation = sys.argv[2:]
meta = {
    "schema": "ownframework-work-packet/v3", "packet_id": "v085-routing-" + title,
    "created_at": "2026-08-30T00:00:00Z", "work_class": "HARDENING",
    "risk_class": "low", "title": title,
    "target": {"repo": repo, "branch": "master", "classification": "local_only"},
    "execution_mode": "program",
    "checkpoint_graph": {"execution_order": ["CP-1"], "checkpoints": [{
        "id": "CP-1", "title": title, "scope": "model-free routing proof",
        "depends_on": [], "acceptance_criterion_ids": ["AC-1"],
        "risk_budget": {"max_build_passes": 3, "max_review_passes": 3,
                         "max_repair_rounds": 1}}]},
    "promotion_policy": "human_gate",
    "acceptance_criteria": [{"id": "AC-1", "text": "routing proof"}],
    "non_goals": [], "network_read_allowlist": [], "allowed_paths": ["src/"],
    "protected_paths": [".ownframework-loop/"],
    "work_units": [{"id": "UNIT-1", "title": "routing proof", "scope": "src/"}],
    "required_validation": [{"name": "routing-validation", "command": validation,
                              "kind": "fast", "expected_exit_code": 0}],
    "merge_authority": "human_only", "deploy_authority": "human_only",
    "push_authority": "human_only", "external_action_authority": "none",
    "risk_budget": {"max_build_passes": 3, "max_review_passes": 3,
                     "max_repair_rounds": 1, "max_files_changed": 10,
                     "max_diff_lines": 500},
}
packet_path.write_text("```json\n" + json.dumps(meta, indent=2, sort_keys=True)
                       + "\n```\n", encoding="utf-8")
PY
  echo "$rid"
}

fill_build() {
  local semantic="$1" rid="$2" label="$3"
  python3 -B - "$semantic" "$rid" "$label" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1]); rid, label = sys.argv[2:]; d = json.loads(p.read_text())
d.update({"run_id": rid, "summary": "synthetic builder " + label,
          "outcome_requested": "candidate_ready", "unit_ids_completed": ["UNIT-1"],
          "acceptance_addressed": ["AC-1"], "notes": "provider-free routing regression"})
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
}

fill_review() {
  local semantic="$1" rid="$2" verdict="$3"
  python3 -B - "$semantic" "$rid" "$verdict" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1]); rid, verdict = sys.argv[2:]; d = json.loads(p.read_text())
d.update({"run_id": rid, "validation_results": [],
          "acceptance_results": [{"id": "AC-1", "result": "pass",
                                   "evidence": "synthetic review"}],
          "non_goal_results": [], "findings": [] if verdict == "APPROVED" else [{
              "finding_id": "F-CANARY-REPAIR", "severity": "medium",
              "classification": "must_fix", "title": "repair sentinel",
              "description": "remove CANARY_REPAIR_REQUIRED"}],
          "recommended_verdict": verdict})
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
}

claim_build() {
  local repo="$1" rid="$2" label="$3" order wt semantic
  order="$($OFLOOP dispatch claim "$repo" "$rid")"
  assert_eq "$(printf '%s' "$order" | jq -r '.decision')" "BUILD" "$label BUILD claim" >&2
  wt="$(printf '%s' "$order" | jq -r '.worktree')"
  semantic="$(printf '%s' "$order" | jq -r '.semantic_path')"
  printf '%s|%s\n' "$wt" "$semantic"
}

claim_review() {
  local repo="$1" rid="$2" label="$3" order semantic
  order="$($OFLOOP dispatch claim "$repo" "$rid")"
  assert_eq "$(printf '%s' "$order" | jq -r '.decision')" "REVIEW" "$label REVIEW claim" >&2
  semantic="$(printf '%s' "$order" | jq -r '.semantic_path')"
  printf '%s\n' "$semantic"
}

# BUILD_VALIDATION_RETRY: validation fails before REVIEW is possible. The next
# BUILD is eligible without a reviewer and without a repair round.
REPO_BUILD="$(make_tmp_repo)"
RID_BUILD="$(make_program_packet "$REPO_BUILD" build-validation-retry 'test -f src/validation.ok')"
IFS='|' read -r WT BSEM < <(claim_build "$REPO_BUILD" "$RID_BUILD" validation-retry)
mkdir -p "$WT/src"
printf 'candidate\n' > "$WT/src/candidate.py"
git -C "$WT" add src/candidate.py && git -C "$WT" commit -q -m "test: validation retry candidate"
fill_build "$BSEM" "$RID_BUILD" initial-validation-failure
"$OFLOOP" dispatch finalize "$REPO_BUILD" "$RID_BUILD" BUILD "$BSEM" >/dev/null
STATE_BUILD="$REPO_BUILD/.ownframework-loop/$RID_BUILD/STATE.json"
assert_eq "$(jq -r '.state' "$STATE_BUILD")" "CHANGES_REQUESTED" "BUILD_VALIDATION_RETRY next state"
assert_eq "$(jq -r '.review_pass_count' "$STATE_BUILD")" "0" "BUILD_VALIDATION_RETRY review count"
assert_eq "$(jq -r '.repair_round' "$STATE_BUILD")" "0" "BUILD_VALIDATION_RETRY repair count"
IFS='|' read -r WT2 BSEM2 < <(claim_build "$REPO_BUILD" "$RID_BUILD" validation-retry-repair)
assert_eq "$WT2" "$WT" "BUILD_VALIDATION_RETRY reuses candidate worktree"
printf 'ok\n' > "$WT2/src/validation.ok"
git -C "$WT2" add src/validation.ok && git -C "$WT2" commit -q -m "test: repair validation candidate"
fill_build "$BSEM2" "$RID_BUILD" validation-retry-success
"$OFLOOP" dispatch finalize "$REPO_BUILD" "$RID_BUILD" BUILD "$BSEM2" >/dev/null
assert_eq "$(jq -r '.state' "$STATE_BUILD")" "READY_FOR_REVIEW" "BUILD_VALIDATION_RETRY recovered state"
assert_eq "$(jq -r '.build_pass_count' "$STATE_BUILD")" "2" "BUILD_VALIDATION_RETRY build count"
assert_eq "$(jq -r '.review_pass_count' "$STATE_BUILD")" "0" "BUILD_VALIDATION_RETRY no reviewer"
assert_eq "$(jq -r '.repair_round' "$STATE_BUILD")" "0" "BUILD_VALIDATION_RETRY no funded repair"
echo "BUILD_VALIDATION_RETRY=PASS"

# REVIEW_FUNDED_REPAIR: a passing build reaches REVIEW, whose rejection
# atomically funds one repair; the repaired candidate is then approved.
REPO_REVIEW="$(make_tmp_repo)"
RID_REVIEW="$(make_program_packet "$REPO_REVIEW" review-funded-repair true)"
IFS='|' read -r WT3 BSEM3 < <(claim_build "$REPO_REVIEW" "$RID_REVIEW" review-funded-repair-1)
mkdir -p "$WT3/src"
printf 'sentinel\n' > "$WT3/src/CANARY_REPAIR_REQUIRED"
git -C "$WT3" add src/CANARY_REPAIR_REQUIRED && git -C "$WT3" commit -q -m "test: reviewer-visible sentinel"
fill_build "$BSEM3" "$RID_REVIEW" reviewer-visible-first-candidate
"$OFLOOP" dispatch finalize "$REPO_REVIEW" "$RID_REVIEW" BUILD "$BSEM3" >/dev/null
STATE_REVIEW="$REPO_REVIEW/.ownframework-loop/$RID_REVIEW/STATE.json"
assert_eq "$(jq -r '.state' "$STATE_REVIEW")" "READY_FOR_REVIEW" "REVIEW_FUNDED_REPAIR build reaches review"
assert_eq "$(jq -r '.repair_round' "$STATE_REVIEW")" "0" "REVIEW_FUNDED_REPAIR pre-review repair count"
RSEM1="$(claim_review "$REPO_REVIEW" "$RID_REVIEW" review-funded-repair-1)"
fill_review "$RSEM1" "$RID_REVIEW" CHANGES_REQUESTED
"$OFLOOP" dispatch finalize "$REPO_REVIEW" "$RID_REVIEW" REVIEW "$RSEM1" >/dev/null
assert_eq "$(jq -r '.verdict' "$REPO_REVIEW/.ownframework-loop/$RID_REVIEW/REVIEW_VERDICT.json")" "CHANGES_REQUESTED" "REVIEW_FUNDED_REPAIR finalizer verdict"
assert_eq "$(jq -r '.state' "$STATE_REVIEW")" "CHANGES_REQUESTED" "REVIEW_FUNDED_REPAIR post-rejection state"
assert_eq "$(jq -r '.review_pass_count' "$STATE_REVIEW")" "1" "REVIEW_FUNDED_REPAIR review count"
assert_eq "$(jq -r '.repair_round' "$STATE_REVIEW")" "1" "REVIEW_FUNDED_REPAIR repair count"
IFS='|' read -r WT4 BSEM4 < <(claim_build "$REPO_REVIEW" "$RID_REVIEW" review-funded-repair-2)
printf 'repaired\n' > "$WT4/src/repaired.py"
rm -f "$WT4/src/CANARY_REPAIR_REQUIRED"
git -C "$WT4" add -A && git -C "$WT4" commit -q -m "test: funded reviewer repair"
fill_build "$BSEM4" "$RID_REVIEW" repaired-candidate
"$OFLOOP" dispatch finalize "$REPO_REVIEW" "$RID_REVIEW" BUILD "$BSEM4" >/dev/null
RSEM2="$(claim_review "$REPO_REVIEW" "$RID_REVIEW" review-funded-repair-2)"
fill_review "$RSEM2" "$RID_REVIEW" APPROVED
"$OFLOOP" dispatch finalize "$REPO_REVIEW" "$RID_REVIEW" REVIEW "$RSEM2" >/dev/null
assert_eq "$(jq -r '.state' "$STATE_REVIEW")" "APPROVED" "REVIEW_FUNDED_REPAIR terminal state"
assert_eq "$(jq -r '.build_pass_count' "$STATE_REVIEW")" "2" "REVIEW_FUNDED_REPAIR build count"
assert_eq "$(jq -r '.review_pass_count' "$STATE_REVIEW")" "2" "REVIEW_FUNDED_REPAIR review count"
assert_eq "$(jq -r '.repair_round' "$STATE_REVIEW")" "1" "REVIEW_FUNDED_REPAIR repair count remains exact"
echo "REVIEW_FUNDED_REPAIR=PASS"
echo "PROGRAM_ROUTING_SEMANTICS=PASS"
