#!/usr/bin/env bash
# v0.9.9-c PROGRAM source-budget breach is OWNED by the deterministic
# PROGRAM source-accounting path; it must NOT escape as an opaque
# RuntimeError that the supervisor auto-quarantines.
#
# R3 CP-9 produced candidate 9eb9666dcb19d57a49a8144c8aea088036cbfad4 with
# diff_lines=33521 vs the human-approved frozen envelope of 30000. The
# build finalizer called the early top-level `risk_budget.max_diff_lines`
# check (which is generic across SINGLE and PROGRAM modes) BEFORE running
# the structured PROGRAM source-ceiling check. The early check raised a
# plain RuntimeError that escaped the finalizer, was classified as
# `OF_LOOP_BUILD_FINALIZE_REFUSED`, auto-quarantined the supervisor job,
# and never wrote the BUILD_RECEIPT that would have produced a
# deterministic BLOCKED transition.
#
# These tests pin that the fix:
#   * defers the early top-level source-size check when in PROGRAM mode;
#   * preserves the strict envelope (min of top-level and PROGRAM-global);
#   * routes any source-budget breach through the structured
#     `program_source_ceiling_check` evidence path and the funded autonomous
#     PROGRAM repair path;
#   * leaves SINGLE-mode semantics unchanged (still raises on breach);
#   * allows zero-cost replay of the already-paid semantic result;
#   * preserves zero-cost replay of the already-funded repair decision.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib"
export PYTHONDONTWRITEBYTECODE=1

# Construct a fresh PROGRAM-mode run with the given source envelopes and
# commit a candidate whose diff stats match the request.
# Args: repo run_id [top_level_diff_lines=100] [program_diff_lines=5000]
#       [n_lines=12]
prep_program_run() {
  local repo="$1" rid="$2"
  local top_diff="${3:-100}"
  local prog_diff="${4:-5000}"
  local n_lines="${5:-12}"

  python3 - "$repo" "$rid" "$top_diff" "$prog_diff" "$n_lines" <<'PY'
import json, sys
from pathlib import Path
repo, rid, top_diff, prog_diff, n_lines = sys.argv[1:6]
top_diff = int(top_diff); prog_diff = int(prog_diff); n_lines = int(n_lines)
pp = Path(repo) / ".ownframework-loop" / rid / "WORK_PACKET.md"
packet = {
    "schema": "ownframework-work-packet/v3",
    "packet_id": "p-source-budget",
    "created_at": "2026-09-16T14:00:00Z",
    "work_class": "FEATURE",
    "risk_class": "low",
    "title": "source budget classify",
    "target": {"repo": repo, "branch": "master", "classification": "local_only"},
    "execution_mode": "program",
    "checkpoint_graph": {
        "execution_order": ["CP-1"],
        "global_source_ceilings": {
            "max_unique_changed_files": 25,
            "max_baseline_to_final_diff_lines": prog_diff,
        },
        "checkpoints": [{
            "id": "CP-1",
            "title": "source budget fixture",
            "scope": "src/",
            "depends_on": [],
            "risk_budget": {
                "max_build_passes": 5,
                "max_review_passes": 5,
                "max_repair_rounds": 2,
            },
        }],
    },
    "promotion_policy": "human_gate",
    "acceptance_criteria": [{"id": "AC-1", "text": "ok"}],
    "non_goals": [],
    "allowed_paths": ["src/"],
    "protected_paths": [".ownframework-loop/"],
    "work_units": [{"id": "UNIT-1", "title": "u", "scope": "src/"}],
    "merge_authority": "human_only",
    "deploy_authority": "human_only",
    "push_authority": "human_only",
    "external_action_authority": "none",
    "risk_budget": {
        "max_build_passes": 5,
        "max_review_passes": 5,
        "max_repair_rounds": 2,
        "max_files_changed": 25,
        "max_diff_lines": top_diff,
    },
}
fence = chr(96) * 3
pp.write_text(fence + "json\n" + json.dumps(packet, indent=2, sort_keys=True) + "\n" + fence + "\n")
PY

  ORDER="$("$OFLOOP_BIN" dispatch claim "$repo" "$rid")"
  WT="$(printf '%s' "$ORDER" | jq -r '.worktree')"
  SEM="$(printf '%s' "$ORDER" | jq -r '.semantic_path')"

  mkdir -p "$WT/src"
  python3 - "$WT" "$n_lines" <<'PY'
import sys
from pathlib import Path
wt = Path(sys.argv[1]); n = int(sys.argv[2])
content = "\n".join(f"line_{i}" for i in range(n)) + "\n"
(wt / "src" / "big.py").write_text(content)
PY
  git -C "$WT" add src/big.py >/dev/null
  git -C "$WT" commit -q -m "candidate over the test envelope"

  python3 - "$SEM" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
d = json.loads(p.read_text())
d["summary"] = "synthetic program breach candidate"
d["outcome_requested"] = "candidate_ready"
d["unit_ids_completed"] = ["UNIT-1"]
d["acceptance_addressed"] = ["AC-1"]
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
  printf '%s' "$SEM"
}

assert_repairable_source_breach() {
  local repo="$1" rid="$2"
  local state_json="$repo/.ownframework-loop/$rid/STATE.json"
  local receipt_json="$repo/.ownframework-loop/$rid/BUILD_RECEIPT.json"
  [[ -f "$receipt_json" ]] || fail "expected BUILD_RECEIPT.json at $receipt_json"
  local next_state
  next_state="$(jq -r '.next_state' "$receipt_json")"
  assert_eq "$next_state" "CHANGES_REQUESTED" "next_state = CHANGES_REQUESTED (autonomous repair)"
  local ps_result
  ps_result="$(jq -r '.program_source_ceiling_check.result' "$receipt_json")"
  assert_eq "$ps_result" "fail" "program_source_ceiling_check.result = fail"
  local breach
  breach="$(jq -r '.program_source_ceiling_check.breach' "$receipt_json")"
  [[ -n "$breach" && "$breach" != "null" && "$breach" != "" ]] || fail "breach text missing in receipt"
  local run_state
  run_state="$(jq -r '.state' "$state_json")"
  assert_eq "$run_state" "CHANGES_REQUESTED" "STATE.json.state = CHANGES_REQUESTED"
}

make_program_run() {
  REPO_CURR="$(make_tmp_repo)"
  "$OFLOOP_BIN" spec new "$REPO_CURR" "source-budget-classify-$RANDOM" >/dev/null
  RID_CURR="$(ls -1t "$REPO_CURR/.ownframework-loop" | head -n1)"
}

# ===========================================================================
# TEST A — PROGRAM source breach does NOT raise/quarantine
# ===========================================================================
make_program_run
SEM_A="$(prep_program_run "$REPO_CURR" "$RID_CURR" 50 5000 200)"
OUT_A="$("$OFLOOP_BIN" dispatch finalize "$REPO_CURR" "$RID_CURR" BUILD "$SEM_A" 2>&1)" || true
if echo "$OUT_A" | grep -q 'OF_LOOP_BUILD_FINALIZE_REFUSED'; then
  echo "$OUT_A"
  fail "TEST A: finalizer escaped as opaque RuntimeError (R3 CP-9 defect regression)"
fi
assert_repairable_source_breach "$REPO_CURR" "$RID_CURR"
EFF_TOP_A="$(jq -r '.program_source_ceiling_check.top_level_risk_max_diff_lines' "$REPO_CURR/.ownframework-loop/$RID_CURR/BUILD_RECEIPT.json")"
EFF_PROG_A="$(jq -r '.program_source_ceiling_check.program_max_baseline_to_final_diff_lines' "$REPO_CURR/.ownframework-loop/$RID_CURR/BUILD_RECEIPT.json")"
EFF_FINAL_A="$(jq -r '.program_source_ceiling_check.effective_max_diff_lines' "$REPO_CURR/.ownframework-loop/$RID_CURR/BUILD_RECEIPT.json")"
assert_eq "$EFF_TOP_A" "50" "TEST A: top_level_risk_max_diff_lines = 50"
assert_eq "$EFF_PROG_A" "5000" "TEST A: program_max_baseline_to_final_diff_lines = 5000"
assert_eq "$EFF_FINAL_A" "50" "TEST A: effective_max_diff_lines = min(50, 5000) = 50"
pass "TEST A: PROGRAM source breach produces BUILD_RECEIPT + funded repair, no opaque RuntimeError"

# ===========================================================================
# TEST B — top-level risk limit is strictly stricter
# ===========================================================================
make_program_run
SEM_B="$(prep_program_run "$REPO_CURR" "$RID_CURR" 30 5000 200)"
OUT_B="$("$OFLOOP_BIN" dispatch finalize "$REPO_CURR" "$RID_CURR" BUILD "$SEM_B" 2>&1)" || true
if echo "$OUT_B" | grep -q 'OF_LOOP_BUILD_FINALIZE_REFUSED'; then
  echo "$OUT_B"
  fail "TEST B: opaque RuntimeError escape (top-level must be enforced via program_source_check)"
fi
assert_repairable_source_breach "$REPO_CURR" "$RID_CURR"
EFFB="$(jq -r '.program_source_ceiling_check.effective_max_diff_lines' "$REPO_CURR/.ownframework-loop/$RID_CURR/BUILD_RECEIPT.json")"
assert_eq "$EFFB" "30" "TEST B: effective_max_diff_lines = 30 (top-level wins)"
pass "TEST B: top-level limit is preserved as the stricter limit"

# ===========================================================================
# TEST C — PROGRAM ceiling is strictly stricter
# ===========================================================================
make_program_run
SEM_C="$(prep_program_run "$REPO_CURR" "$RID_CURR" 10000 5 100)"
OUT_C="$("$OFLOOP_BIN" dispatch finalize "$REPO_CURR" "$RID_CURR" BUILD "$SEM_C" 2>&1)" || true
if echo "$OUT_C" | grep -q 'OF_LOOP_BUILD_FINALIZE_REFUSED'; then
  echo "$OUT_C"
  fail "TEST C: opaque RuntimeError escape"
fi
assert_repairable_source_breach "$REPO_CURR" "$RID_CURR"
EFFC="$(jq -r '.program_source_ceiling_check.effective_max_diff_lines' "$REPO_CURR/.ownframework-loop/$RID_CURR/BUILD_RECEIPT.json")"
assert_eq "$EFFC" "5" "TEST C: effective_max_diff_lines = 5 (PROGRAM ceiling wins)"
pass "TEST C: PROGRAM ceiling is preserved as the stricter limit"

# ===========================================================================
# TEST D — exact-boundary success
# ===========================================================================
make_program_run
SEM_D="$(prep_program_run "$REPO_CURR" "$RID_CURR" 100 100 100)"
"$OFLOOP_BIN" dispatch finalize "$REPO_CURR" "$RID_CURR" BUILD "$SEM_D" >/dev/null 2>&1 || true
RESD="$(jq -r '.program_source_ceiling_check.result' "$REPO_CURR/.ownframework-loop/$RID_CURR/BUILD_RECEIPT.json")"
EFFD="$(jq -r '.program_source_ceiling_check.effective_max_diff_lines' "$REPO_CURR/.ownframework-loop/$RID_CURR/BUILD_RECEIPT.json")"
assert_eq "$EFFD" "100" "TEST D: effective_max_diff_lines = 100"
assert_eq "$RESD" "pass" "TEST D: exact-boundary program_source_ceiling_check.result = pass"
BREACHD="$(jq -r '.program_source_ceiling_check.breach' "$REPO_CURR/.ownframework-loop/$RID_CURR/BUILD_RECEIPT.json")"
assert_eq "$BREACHD" "" "TEST D: exact-boundary breach field empty"
pass "TEST D: exact-boundary candidate passes source-budget check"

# ===========================================================================
# TEST E — SINGLE-mode regression unchanged
# ===========================================================================
REPO_E="$(make_tmp_repo)"
RID_E="$(make_approved_run "$REPO_E" BUG low "single-budget-regression")"
ORDER_E="$("$OFLOOP_BIN" dispatch claim "$REPO_E" "$RID_E")"
WTE="$(printf '%s' "$ORDER_E" | jq -r '.worktree')"
SEME="$(printf '%s' "$ORDER_E" | jq -r '.semantic_path')"
mkdir -p "$WTE/src"
python3 - "$WTE" <<'PY'
import sys
from pathlib import Path
wt = Path(sys.argv[1])
content = "\n".join(f"line_{i}" for i in range(1500)) + "\n"
(wt / "src" / "big.py").write_text(content)
PY
git -C "$WTE" add src/big.py >/dev/null
git -C "$WTE" commit -q -m "single-mode overbudget candidate"
python3 - "$SEME" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
d = json.loads(p.read_text())
d["summary"] = "synthetic single-mode candidate"
d["outcome_requested"] = "candidate_ready"
d["unit_ids_completed"] = ["UNIT-1"]
d["acceptance_addressed"] = ["AC-1"]
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY

OUT_E="$("$OFLOOP_BIN" dispatch finalize "$REPO_E" "$RID_E" BUILD "$SEME" 2>&1)" || true
if echo "$OUT_E" | grep -q 'OF_LOOP_BUILD_FINALIZE_REFUSED'; then
  pass "TEST E: SINGLE-mode still refuses via OF_LOOP_BUILD_FINALIZE_REFUSED"
else
  echo "$OUT_E"
  fail "TEST E: SINGLE-mode contract regressed (refused path moved out of generic RuntimeError)"
fi

# ===========================================================================
# TEST F — replay recovery at zero semantic cost
# ===========================================================================
make_program_run
SEM_F="$(prep_program_run "$REPO_CURR" "$RID_CURR" 50 5000 200)"

"$OFLOOP_BIN" dispatch finalize "$REPO_CURR" "$RID_CURR" BUILD "$SEM_F" >/dev/null 2>&1 || true
STATE_BEFORE="$(jq -r '.build_pass_count' "$REPO_CURR/.ownframework-loop/$RID_CURR/STATE.json")"
REPAIR_BEFORE="$(jq -r '.repair_round' "$REPO_CURR/.ownframework-loop/$RID_CURR/STATE.json")"
SHA_BEFORE="$(jq -r '.candidate_sha' "$REPO_CURR/.ownframework-loop/$RID_CURR/BUILD_RECEIPT.json")"

"$OFLOOP_BIN" dispatch finalize "$REPO_CURR" "$RID_CURR" BUILD "$SEM_F" >/dev/null 2>&1 || true
STATE_AFTER="$(jq -r '.build_pass_count' "$REPO_CURR/.ownframework-loop/$RID_CURR/STATE.json")"
REPAIR_AFTER="$(jq -r '.repair_round' "$REPO_CURR/.ownframework-loop/$RID_CURR/STATE.json")"
SHA_AFTER="$(jq -r '.candidate_sha' "$REPO_CURR/.ownframework-loop/$RID_CURR/BUILD_RECEIPT.json")"
NEXT_AFTER="$(jq -r '.next_state' "$REPO_CURR/.ownframework-loop/$RID_CURR/BUILD_RECEIPT.json")"
assert_eq "$STATE_AFTER" "$STATE_BEFORE" "TEST F: build_pass_count unchanged after replay"
assert_eq "$REPAIR_AFTER" "$REPAIR_BEFORE" "TEST F: repair_round unchanged after replay"
assert_eq "$SHA_AFTER" "$SHA_BEFORE" "TEST F: candidate_sha unchanged after replay"
assert_eq "$NEXT_AFTER" "CHANGES_REQUESTED" "TEST F: replay next_state stays CHANGES_REQUESTED (idempotent)"
pass "TEST F: replay preserves the same funded repair at zero semantic cost"

# ===========================================================================
# TEST G — the autonomous source-budget repair needs no continuation ceremony
# ===========================================================================
make_program_run
SEM_G="$(prep_program_run "$REPO_CURR" "$RID_CURR" 50 5000 200)"
"$OFLOOP_BIN" dispatch finalize "$REPO_CURR" "$RID_CURR" BUILD "$SEM_G" >/dev/null 2>&1 || true
STATE_G="$(jq -r '.state' "$REPO_CURR/.ownframework-loop/$RID_CURR/STATE.json")"
REPAIR_G="$(jq -r '.repair_round' "$REPO_CURR/.ownframework-loop/$RID_CURR/STATE.json")"
assert_eq "$STATE_G" "CHANGES_REQUESTED" "TEST G: source-budget breach funds repair directly"
assert_eq "$REPAIR_G" "1" "TEST G: autonomous source-budget repair consumes one round"
pass "TEST G: source-budget repair requires no continue-program ceremony"
