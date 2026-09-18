#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"

REPO="$(make_tmp_repo)"
DB="$(mktemp -t ofloop-protected-continuation.XXXXXX.sqlite3)"
mkdir -p "$REPO/src" "$REPO/docs"
printf '%s\n' 'safe' > "$REPO/src/safe.py"
printf '%s\n' 'approved' > "$REPO/docs/protected.md"
git -C "$REPO" add .
git -C "$REPO" -c user.name=test -c user.email=test@local commit -qm baseline

RUN="$($OFLOOP_BIN spec new "$REPO" 'blocked protected continuation' | jq -r '.run_id')"
PP="$REPO/.ownframework-loop/$RUN/WORK_PACKET.md"
python3 - "$PP" "$REPO" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1]); repo = sys.argv[2]
packet = {
    "schema": "ownframework-work-packet/v3", "packet_id": "protected-continuation",
    "created_at": "2026-09-15T00:00:00Z", "work_class": "HARDENING", "risk_class": "low",
    "title": "protected continuation", "target": {"repo": repo, "branch": "master", "classification": "local_only"},
    "execution_mode": "program", "checkpoint_graph": {
        "execution_order": ["CP-5", "CP-6"],
        "checkpoints": [
            {"id": "CP-5", "title": "safe predecessor", "scope": "src/", "depends_on": [],
             "acceptance_criterion_ids": ["AC-5"],
             "risk_budget": {"max_build_passes": 3, "max_review_passes": 3, "max_repair_rounds": 2}},
            {"id": "CP-6", "title": "protected repair", "scope": "src/", "depends_on": ["CP-5"],
             "acceptance_criterion_ids": ["AC-6"],
             "risk_budget": {"max_build_passes": 3, "max_review_passes": 3, "max_repair_rounds": 2}},
        ]},
    "promotion_policy": "human_gate", "acceptance_criteria": [
        {"id": "AC-5", "text": "predecessor"}, {"id": "AC-6", "text": "repair"}],
    "non_goals": [], "allowed_paths": ["src/"], "protected_paths": ["docs/protected.md", ".ownframework-loop/"],
    "work_units": [{"id": "UNIT-5", "title": "predecessor", "scope": "src/", "acceptance": ["AC-5"]},
                    {"id": "UNIT-6", "title": "repair", "scope": "src/", "acceptance": ["AC-6"]}],
    "merge_authority": "human_only", "deploy_authority": "human_only", "push_authority": "human_only",
    "external_action_authority": "none", "risk_budget": {"max_build_passes": 7, "max_review_passes": 7,
    "max_repair_rounds": 4, "max_files_changed": 20, "max_diff_lines": 1000}}
p.write_text("```json\n" + json.dumps(packet, sort_keys=True) + "\n```\n")
PY

ORDER="$($OFLOOP_BIN dispatch claim "$REPO" "$RUN")"
WT="$(printf '%s' "$ORDER" | jq -r '.worktree')"
git -C "$WT" config user.name test
git -C "$WT" config user.email test@local
printf '%s\n' 'cp5' > "$WT/src/cp5.py"
git -C "$WT" add src/cp5.py
git -C "$WT" commit -qm 'synthetic CP-5 approved source'
SAFE="$(git -C "$WT" rev-parse HEAD)"
printf '%s\n' 'bad protected drift' > "$WT/docs/protected.md"
printf '%s\n' 'discarded model source' > "$WT/src/model-only.py"
git -C "$WT" add .
git -C "$WT" commit -qm 'synthetic CP-6 protected drift'
BAD="$(git -C "$WT" rev-parse HEAD)"

PYTHONPATH="$OFLOOP_LIB:$HERE/../helpers" python3 - "$REPO" "$RUN" "$SAFE" "$BAD" <<'PY'
import json, sys
from pathlib import Path
from ownframework_loop import state
from state_seed import seed_state
repo = Path(sys.argv[1]); run = sys.argv[2]; safe = sys.argv[3]; bad = sys.argv[4]
run_dir = repo / ".ownframework-loop" / run
packet = json.loads(__import__('re').search(r"```json\s*\n(.*?)\n```", (run_dir / "WORK_PACKET.md").read_text(), __import__('re').S).group(1))
current = state.load(repo, run)
prog = current["program"]
prog["current_checkpoints"] = ["CP-6"]
prog["finalized_checkpoints"] = [{"id": "CP-5", "terminal": "APPROVED", "candidate_sha": safe}]
for cp in prog["checkpoints"]:
    if cp["id"] == "CP-5":
        cp["terminal"] = "APPROVED"; cp["candidate_sha"] = safe
    if cp["id"] == "CP-6":
        cp.pop("checkpoint_entry_candidate_sha", None)
current["state"] = "BLOCKED"
current["last_candidate_sha"] = bad
current["terminal_reason"] = "protected candidate drift"
current["build_pass_count"] = 1
current["repair_round"] = 0
run_dir.joinpath("BUILD_RECEIPT.json").write_text(json.dumps({
    "schema": "ownframework-loop-build-receipt/v2", "run_id": run,
    "packet_sha256": __import__('hashlib').sha256((run_dir / "WORK_PACKET.md").read_bytes()).hexdigest(),
    "next_state": "BLOCKED", "candidate_sha": bad,
    "scope_check": {"result": "pass"}, "secret_scan_check": {"result": "pass", "findings": []},
    "program_source_check": {"result": "pass"},
    "protected_path_check": {"result": "fail", "offending_paths": ["docs/protected.md"]}}, indent=2) + "\n")
seed_state(repo, run, current, reason="synthetic blocked CP-6 protected drift")
state.append_event(
    repo, run, event_type="program_advanced", old_state="REVIEWING",
    new_state="READY_TO_BUILD", actor="of-reviewer", commit_sha=safe,
    extras={"cp_id_finalized": "CP-5", "cp_terminal": "APPROVED", "next_checkpoints": ["CP-6"]},
)
PY

ENQ="$($OFLOOP_BIN supervisor enqueue "$REPO" "$RUN" --runner claude-code --db "$DB")"
assert_eq "$(printf '%s' "$ENQ" | jq -r '.status')" "QUEUED" "protected continuation enrollment"
CONT="$($OFLOOP_BIN supervisor continue-program "$REPO" "$RUN" --reason 'legacy blocked protected drift recovery' --expected-candidate-sha "$BAD" --db "$DB")"
assert_eq "$(printf '%s' "$CONT" | jq -r '.status')" "QUEUED" "protected continuation requeued"
assert_eq "$(printf '%s' "$CONT" | jq -r '.continuation.repair_round_after')" "1" "one repair funded"

RECOVERED="$(git -C "$WT" rev-parse HEAD)"
if [[ "$RECOVERED" == "$BAD" ]]; then fail "recovery reused violating candidate SHA"; fi
assert_eq "$(git -C "$REPO" rev-parse "${RECOVERED}^{tree}")" "$(git -C "$REPO" rev-parse "${SAFE}^{tree}")" "full safe tree restored"
git -C "$REPO" merge-base --is-ancestor "$BAD" "$RECOVERED"
assert_eq "$(git -C "$WT" show HEAD:docs/protected.md)" "approved" "protected source restored"
if git -C "$WT" cat-file -e HEAD:src/model-only.py 2>/dev/null; then fail "discarded model file survived"; fi

NEXT="$($OFLOOP_BIN dispatch claim "$REPO" "$RUN")"
assert_eq "$(printf '%s' "$NEXT" | jq -r '.decision')" "BUILD" "fresh builder dispatched"
assert_eq "$(printf '%s' "$NEXT" | jq -r '.prepare.builder_worktree')" "$WT" "fresh builder uses restored worktree"

echo "LEGACY_BLOCKED_R3_WHOLE_DISCARD_RECOVERY=PASS"
echo "WHOLE_ATTEMPT_DISCARD=PASS"
echo "FRESH_BUILDER_AFTER_DISCARD=PASS"
