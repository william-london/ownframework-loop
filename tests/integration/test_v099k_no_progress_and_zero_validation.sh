#!/usr/bin/env bash
# v0.9.9-k: candidate-convergence fuse and explicit zero-validation authority.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$LIB_DIR"
export PYTHONDONTWRITEBYTECODE=1
OFLOOP="$OFLOOP_BIN"

assert_in() {
  local haystack="$1" needle="$2" message="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$message: $needle"
  pass "$message"
}

OUT="$(python3 <<'PYEOF'
from ownframework_loop import build_finalize, limits, receipts

packet = {"risk_budget": {"max_consecutive_no_progress_passes": 3}}

# A -> B is real progress; B -> B is not, independent of the eventual state.
assert build_finalize._compute_no_progress_streak("A", "B", 7) == 0
assert build_finalize._compute_no_progress_streak("B", "B", 0) == 1
assert build_finalize._compute_no_progress_streak("B", "B", 2) == 3
assert build_finalize._compute_no_progress_streak("B", "B", 2) == 3
print("NO_PROGRESS_STREAK_MATRIX=PASS")

# A repair-required finalization at the cap blocks before the funded-repair
# owner can consume another entitlement or launch another provider.
assert build_finalize._repair_blocked_by_no_progress(2, packet, True) is False
assert build_finalize._repair_blocked_by_no_progress(3, packet, True) is True
assert build_finalize._repair_blocked_by_no_progress(3, packet, False) is False
assert limits.effective_cap("no_progress_streak", packet) == 3
print("NO_PROGRESS_CAP_PRE_PROVIDER=PASS")

# Missing/malformed evidence remains UNKNOWN; an explicit [] means zero
# declared gates and is vacuously satisfied.
assert receipts.compute_validation_status(None) == "UNKNOWN"
assert receipts.compute_validation_status({}) == "UNKNOWN"
assert receipts.compute_validation_status([]) == "PASS"
assert receipts.compute_validation_status([
    {"passed": True, "exit_code": 0, "expected_exit_code": 0}
]) == "PASS"
assert receipts.compute_validation_status([
    {"passed": False, "exit_code": 1, "expected_exit_code": 0}
]) == "FAIL"
print("ZERO_VALIDATION_STATUS=PASS")
PYEOF
)"
assert_in "$OUT" "NO_PROGRESS_STREAK_MATRIX=PASS" "candidate progress resets and identical candidates increment"
assert_in "$OUT" "NO_PROGRESS_CAP_PRE_PROVIDER=PASS" "no-progress cap blocks repair before provider work"
assert_in "$OUT" "ZERO_VALIDATION_STATUS=PASS" "empty validation authority is explicit and fail-closed"

# The funded-repair owner preserves the already-computed streak while
# incrementing exactly one repair entitlement, in one state transaction.
T="$(make_tmp_repo)"
echo "1" > "$T/src.py"
git -C "$T" add src.py && git -C "$T" commit -m src >/dev/null
"$OFLOOP" spec new "$T" "no-progress-owner" >/dev/null
RID="$(ls -1t "$T/.ownframework-loop" | head -n1)"
python3 - "$T" "$RID" <<'PY'
import sys
from pathlib import Path
repo, rid = Path(sys.argv[1]), sys.argv[2]
(repo / ".ownframework-loop" / rid / "WORK_PACKET.md").write_text(
    f'''```json
{{
  "schema": "ownframework-work-packet/v2",
  "packet_id": "no-progress-owner",
  "created_at": "2026-09-17T00:00:00Z",
  "work_class": "BUG",
  "risk_class": "low",
  "title": "no-progress-owner",
  "target": {{"repo": "{repo}", "branch": "master", "classification": "local_only"}},
  "acceptance_criteria": [{{"id": "AC-1", "text": "ok"}}],
  "non_goals": [],
  "allowed_paths": ["src.py"],
  "protected_paths": [".ownframework-loop/"],
  "work_units": [{{"id": "UNIT-1", "title": "u", "scope": "s"}}],
  "merge_authority": "human_only",
  "deploy_authority": "human_only",
  "push_authority": "human_only",
  "external_action_authority": "none",
  "risk_budget": {{"max_files_changed": 25, "max_diff_lines": 1000, "max_repair_rounds": 3}}
}}
```
''', encoding="utf-8"
)
PY
python3 - "$T" "$RID" <<'PY'
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ["OFLOOP_LIB"])
from ownframework_loop import execution_start, packet, state
repo, rid = Path(sys.argv[1]), sys.argv[2]
execution_start.ensure_executable(canonical_repo=repo, run_id=rid, actor="test", binding_method="build_start")
state.transition(repo, rid, to_state="BUILDING", actor="test", reason="claim")
meta, _ = packet.parse_packet_file(state.run_dir(repo, rid) / "WORK_PACKET.md")
result = state.transition_funded_repair(
    repo, rid, packet=meta, actor="test", commit_sha="",
    no_progress_streak=2,
    allowed_sources=frozenset({"BUILDING"}),
    claimed_reason="preserve convergence streak",
)
assert result["repair_claimed"] is True, result
current = state.load_verified(repo, rid)
assert int(current["repair_round"]) == 1, current
assert int(current["no_progress_streak"]) == 2, current
print("ATOMIC_STREAK_PRESERVATION=PASS")
PY
pass "funded repair preserves no-progress streak atomically"

echo "OF_LOOP_V099K_NO_PROGRESS_ZERO_VALIDATION=PASS"
