#!/usr/bin/env bash
# v0.7.0 final autonomy architecture regression gate.
#
# Covers the v0.7.0 pass:
#   T1  supervisor enqueue envelope resolution (packet max_runtime_seconds ->
#       wall ceiling; cost/token ceilings disabled by default; explicit flags win)
#   T2  semantic pass timeout model (3600 fallback fuse; packet
#       max_pass_runtime_seconds is authority up to 28800; operational narrowing)
#   T3  repair context continuity (verdict-sourced, receipt-sourced after a
#       build-validation failure, and no hard stop on a stale verdict)
#   T4  build-cap exhaustion seals BLOCKED and dispatch returns TERMINAL
#       (no quarantine/resume loop)
#   T5  identical-finding repetition fuse BLOCKs a non-converging repair loop
#   T6  authority boundary: registry publish forbidden, local orchestration and
#       reviewer validation toolchain allowed
#   T7  foreground scheduling immediacy (no idle gap between passes; pre-start
#       is STARTABLE for the builder lane, WAIT for the reviewer lane)
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export XDG_STATE_HOME="$TMP/xdg"

# =====================================================================
# T1: enqueue envelope resolution
# =====================================================================
REPO1="$(make_tmp_repo)"
"$OFLOOP_BIN" spec new "$REPO1" "program envelope" >/dev/null
RID1="$(ls -1t "$REPO1/.ownframework-loop" | head -n1)"
cat > "$REPO1/.ownframework-loop/$RID1/WORK_PACKET.md" <<EOF
\`\`\`json
{
  "schema": "ownframework-work-packet/v3",
  "execution_mode": "program",
  "packet_id": "p-v070-envelope",
  "created_at": "2026-08-29T00:00:00Z",
  "work_class": "FEATURE",
  "risk_class": "medium",
  "title": "envelope",
  "target": {"repo": "$REPO1", "branch": "master", "classification": "local_only"},
  "acceptance_criteria": [{"id": "AC-1", "text": "ok"}],
  "non_goals": [],
  "allowed_paths": ["src/"],
  "protected_paths": [".ownframework-loop/"],
  "work_units": [{"id": "UNIT-1", "title": "u", "scope": "s"}],
  "merge_authority": "human_only",
  "deploy_authority": "human_only",
  "push_authority": "human_only",
  "external_action_authority": "none",
  "risk_budget": {
    "max_files_changed": 60,
    "max_diff_lines": 3000,
    "max_repair_rounds": 6,
    "max_build_passes": 8,
    "max_review_passes": 8,
    "max_runtime_seconds": 123456,
    "max_pass_runtime_seconds": 7200
  },
  "checkpoint_graph": {
    "execution_order": ["CP-1"],
    "checkpoints": [{
      "id": "CP-1", "title": "one", "scope": "src", "depends_on": [],
      "work_units": ["UNIT-1"],
      "risk_budget": {"max_build_passes": 4, "max_review_passes": 4, "max_repair_rounds": 3}
    }]
  }
}
\`\`\`
body
EOF
"$OFLOOP_BIN" supervisor enqueue "$REPO1" "$RID1" >/dev/null
S1="$("$OFLOOP_BIN" supervisor status "$REPO1" "$RID1")"
python3 - "$S1" <<'PY'
import json, sys
s = json.loads(sys.argv[1])
assert s["max_wall_seconds"] == 123456, s
assert s["max_total_cost_usd"] == 0, s
assert s["max_total_tokens"] == 0, s
assert s["packet_max_runtime_seconds"] == 123456, s
assert s["packet_max_pass_runtime_seconds"] == 7200, s
print("  PASS: T1 packet max_runtime_seconds consumed as wall ceiling; cost/token ceilings off")
PY
"$OFLOOP_BIN" supervisor enqueue "$REPO1" "$RID1" --max-wall-seconds 500 --max-cost-usd 7 >/dev/null
S2="$("$OFLOOP_BIN" supervisor status "$REPO1" "$RID1")"
python3 - "$S2" <<'PY'
import json, sys
s = json.loads(sys.argv[1])
assert s["max_wall_seconds"] == 500, s
assert s["max_total_cost_usd"] == 7, s
print("  PASS: T1 explicit enqueue flags win over packet envelope")
PY

# Undeclared envelope -> no wall ceiling (0 = disabled), not an accidental fixed cap.
REPO1B="$(make_tmp_repo)"
RID1B="$(make_approved_run "$REPO1B")"
"$OFLOOP_BIN" supervisor enqueue "$REPO1B" "$RID1B" >/dev/null
S3="$("$OFLOOP_BIN" supervisor status "$REPO1B" "$RID1B")"
python3 - "$S3" <<'PY'
import json, sys
s = json.loads(sys.argv[1])
assert s["max_wall_seconds"] == 0, s
assert s["max_total_cost_usd"] == 0, s
print("  PASS: T1 undeclared envelope disables wall/cost ceilings")
PY

# =====================================================================
# T2: mode-aware semantic pass timeout fallbacks
# =====================================================================
python3 -B <<'PY'
import os, sys
sys.path.insert(0, os.environ["OFLOOP_LIB"])
from ownframework_loop import supervisor
# One-hour runaway fuse is the fallback for BOTH modes; a PROGRAM funds wider
# passes deliberately through its packet budget (authority), which the
# supervisor can only narrow.
assert supervisor.resolve_semantic_timeout({}, 0) == 3600
assert supervisor.resolve_semantic_timeout({"execution_mode": "single"}, 0) == 3600
assert supervisor.resolve_semantic_timeout({"execution_mode": "program"}, 0) == 3600
assert supervisor.resolve_semantic_timeout(
    {"execution_mode": "program", "risk_budget": {"max_pass_runtime_seconds": 28800}}, 0
) == 28800
assert supervisor.resolve_semantic_timeout(
    {"execution_mode": "program", "risk_budget": {"max_pass_runtime_seconds": 28800}}, 1000
) == 1000
print("  PASS: T2 3600 fallback fuse preserved; packet max_pass_runtime_seconds is authority (up to 28800), operational timeout only narrows")
PY

# =====================================================================
# T3: repair context continuity
# =====================================================================
REPO3="$(make_tmp_repo)"
RID3="$(make_approved_run "$REPO3")"
python3 -B - "$REPO3" "$RID3" <<'PY'
import json, os, sys
from pathlib import Path
sys.path.insert(0, os.environ["OFLOOP_LIB"])
from ownframework_loop import dispatch, state as state_mod

repo = Path(sys.argv[1]); rid = sys.argv[2]
run_d = state_mod.run_dir(repo, rid)
X = "x" * 40
Y = "y" * 40

# --- case A: stale CHANGES_REQUESTED verdict + fresh failed build receipt.
# v0.6.3 raised a dispatch invariant error here (hard quarantine). v0.7.0
# must fall through to the receipt-sourced repair context.
state = state_mod.load(repo, rid)
state["state"] = "CHANGES_REQUESTED"
state["repair_round"] = 1
state["last_candidate_sha"] = Y
state_mod.save(repo, rid, state)
(run_d / "REVIEW_VERDICT.json").write_text(json.dumps({
    "schema": "ownframework-loop-review-verdict/v2",
    "run_id": rid,
    "verdict": "CHANGES_REQUESTED",
    "candidate_sha_reviewed": X,
    "review_pass_number": 1,
    "failure_reason": "must_fix_finding",
    "acceptance_results": [], "non_goal_results": [],
    "findings": [], "validation_results": [],
}), encoding="utf-8")
(run_d / "BUILD_RECEIPT.json").write_text(json.dumps({
    "schema": "ownframework-loop-build-receipt/v2",
    "run_id": rid,
    "candidate_sha": Y,
    "next_state": "CHANGES_REQUESTED",
    "validation": [
        {"name": "pytest", "command": "pytest -q", "exit_code": 1,
         "expected_exit_code": 0, "passed": False, "timed_out": False,
         "stdout": "FAILED test_a.py", "stderr": "", "duration_seconds": 1.0},
        {"name": "lint", "command": "ruff check", "exit_code": 0,
         "expected_exit_code": 0, "passed": True, "timed_out": False,
         "stdout": "", "stderr": "", "duration_seconds": 0.5},
    ],
}), encoding="utf-8")
state = state_mod.load(repo, rid)
ctx = dispatch._repair_context_for_build(canonical_repo=repo, run_id=rid, state_doc=state)
assert ctx is not None, "receipt-sourced repair context missing"
assert ctx["source_kind"] == "build_receipt", ctx
assert ctx["candidate_sha_reviewed"] == Y, ctx
failed = ctx["failed_validation_results"]
assert len(failed) == 1 and failed[0]["name"] == "pytest", ctx
assert "FAILED test_a.py" in failed[0]["stdout"], ctx
print("  PASS: T3 stale verdict + failed build receipt -> receipt-sourced repair context (no hard stop)")

# --- case B: fresh CHANGES_REQUESTED verdict is the primary source.
(run_d / "REVIEW_VERDICT.json").write_text(json.dumps({
    "schema": "ownframework-loop-review-verdict/v2",
    "run_id": rid,
    "verdict": "CHANGES_REQUESTED",
    "candidate_sha_reviewed": Y,
    "review_pass_number": 2,
    "failure_reason": "acceptance_criterion_failed",
    "acceptance_results": [{"id": "AC-1", "result": "fail", "evidence": "no"}],
    "non_goal_results": [],
    "findings": [{"classification": "must_fix", "title": "broken"}],
    "validation_results": [],
}), encoding="utf-8")
ctx2 = dispatch._repair_context_for_build(canonical_repo=repo, run_id=rid, state_doc=state)
assert ctx2 is not None and ctx2["source_kind"] == "review_verdict", ctx2
assert ctx2["failed_acceptance_results"], ctx2
print("  PASS: T3 fresh CHANGES_REQUESTED verdict -> verdict-sourced repair context")

# --- case C: no fresh source -> None (builder proceeds on direct evidence).
(run_d / "BUILD_RECEIPT.json").write_text(json.dumps({
    "schema": "ownframework-loop-build-receipt/v2",
    "run_id": rid,
    "candidate_sha": Y,
    "next_state": "READY_FOR_REVIEW",
    "validation": [],
}), encoding="utf-8")
(run_d / "REVIEW_VERDICT.json").write_text(json.dumps({
    "schema": "ownframework-loop-review-verdict/v2",
    "run_id": rid,
    "verdict": "APPROVED",
    "candidate_sha_reviewed": Y,
}), encoding="utf-8")
ctx3 = dispatch._repair_context_for_build(canonical_repo=repo, run_id=rid, state_doc=state)
assert ctx3 is None, ctx3
print("  PASS: T3 no fresh repair evidence -> None (no fabricated context)")
PY

# =====================================================================
# T4: build-cap exhaustion seals BLOCKED; dispatch returns TERMINAL
# =====================================================================
REPO4="$(make_tmp_repo)"
"$OFLOOP_BIN" spec new "$REPO4" "cap exhaustion" >/dev/null
RID4="$(ls -1t "$REPO4/.ownframework-loop" | head -n1)"
cat > "$REPO4/.ownframework-loop/$RID4/WORK_PACKET.md" <<EOF
\`\`\`json
{
  "schema": "ownframework-work-packet/v2",
  "packet_id": "p-v070-cap",
  "created_at": "2026-08-29T00:00:00Z",
  "work_class": "BUG",
  "risk_class": "low",
  "title": "cap",
  "target": {"repo": "$REPO4", "branch": "master", "classification": "local_only"},
  "acceptance_criteria": [{"id": "AC-1", "text": "ok"}],
  "non_goals": [],
  "allowed_paths": ["src/"],
  "protected_paths": [".ownframework-loop/"],
  "work_units": [{"id": "UNIT-1", "title": "u", "scope": "s"}],
  "merge_authority": "human_only",
  "deploy_authority": "human_only",
  "push_authority": "human_only",
  "external_action_authority": "none",
  "risk_budget": {
    "max_files_changed": 25,
    "max_diff_lines": 1000,
    "max_repair_rounds": 4,
    "max_build_passes": 1,
    "max_review_passes": 4
  }
}
\`\`\`
body
EOF
"$OFLOOP_BIN" build claim "$REPO4" "$RID4" --actor test >/dev/null
"$OFLOOP_BIN" build prepare "$REPO4" "$RID4" >/dev/null
WT4="$REPO4/.worktrees/ownframework-loop/$RID4/builder"
[[ -d "$WT4" ]] || fail "T4 builder worktree missing after prepare"
mkdir -p "$WT4/src" && echo "x" > "$WT4/src/x.py"
git -C "$WT4" add src/x.py && git -C "$WT4" commit -m "cap candidate" >/dev/null
SEM4="$("$OFLOOP_BIN" build agent-skeleton "$REPO4" "$RID4" | jq -r '.agent_result_path')"
python3 - "$SEM4" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1]); d = json.loads(p.read_text())
d["summary"] = "cap fixture"
d["outcome_requested"] = "candidate_ready"
d["unit_ids_completed"] = ["UNIT-1"]
d["acceptance_addressed"] = ["AC-1"]
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
"$OFLOOP_BIN" build finalize "$REPO4" "$RID4" "$SEM4" >/dev/null
"$OFLOOP_BIN" review claim "$REPO4" "$RID4" --actor test >/dev/null
"$OFLOOP_BIN" review prepare "$REPO4" "$RID4" >/dev/null
AS4="$("$OFLOOP_BIN" review assessment-skeleton "$REPO4" "$RID4" | jq -r '.assessment_path')"
python3 - "$AS4" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1]); d = json.loads(p.read_text())
d["acceptance_results"] = [{"id": "AC-1", "result": "pass", "evidence": "ok"}]
d["non_goal_results"] = []
d["findings"] = [{"classification": "must_fix", "title": "needs repair"}]
d["recommended_verdict"] = "CHANGES_REQUESTED"
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
"$OFLOOP_BIN" review finalize "$REPO4" "$RID4" "$AS4" >/dev/null
ST4="$(jq -r '.state' "$REPO4/.ownframework-loop/$RID4/STATE.json")"
assert_eq "$ST4" "READY_TO_BUILD" "T4 review changes-requested returns to buildable state"

# The second build claim exceeds max_build_passes=1. Dispatch must surface a
# TERMINAL result (cap-gate seals BLOCKED inside the claim owner).
T4_OUT="$(python3 -B - "$REPO4" "$RID4" <<'PY'
import json, os, sys
from pathlib import Path
sys.path.insert(0, os.environ["OFLOOP_LIB"])
from ownframework_loop import dispatch
order = dispatch.claim_next(canonical_repo=Path(sys.argv[1]), run_id=sys.argv[2])
print(json.dumps(order))
PY
)"
assert_contains "$T4_OUT" '"decision": "TERMINAL"' "T4 dispatch returns TERMINAL after cap exhaustion"
assert_contains "$T4_OUT" '"state": "BLOCKED"' "T4 cap exhaustion seals legitimate BLOCKED terminal"
ST4B="$(jq -r '.state' "$REPO4/.ownframework-loop/$RID4/STATE.json")"
assert_eq "$ST4B" "BLOCKED" "T4 run state BLOCKED after cap exhaustion"

# =====================================================================
# T5: identical-finding repetition fuse
# =====================================================================
REPO5="$(make_tmp_repo)"
"$OFLOOP_BIN" spec new "$REPO5" "identical findings" >/dev/null
RID5="$(ls -1t "$REPO5/.ownframework-loop" | head -n1)"
cat > "$REPO5/.ownframework-loop/$RID5/WORK_PACKET.md" <<EOF
\`\`\`json
{
  "schema": "ownframework-work-packet/v2",
  "packet_id": "p-v070-fuse",
  "created_at": "2026-08-29T00:00:00Z",
  "work_class": "BUG",
  "risk_class": "low",
  "title": "fuse",
  "target": {"repo": "$REPO5", "branch": "master", "classification": "local_only"},
  "acceptance_criteria": [{"id": "AC-1", "text": "ok"}],
  "non_goals": [],
  "allowed_paths": ["src/"],
  "protected_paths": [".ownframework-loop/"],
  "work_units": [{"id": "UNIT-1", "title": "u", "scope": "s"}],
  "merge_authority": "human_only",
  "deploy_authority": "human_only",
  "push_authority": "human_only",
  "external_action_authority": "none",
  "risk_budget": {
    "max_files_changed": 25,
    "max_diff_lines": 1000,
    "max_repair_rounds": 6,
    "max_build_passes": 6,
    "max_review_passes": 6,
    "max_identical_finding_repeats": 2
  }
}
\`\`\`
body
EOF

build_cycle() {
  local marker="$1"
  "$OFLOOP_BIN" build claim "$REPO5" "$RID5" --actor test >/dev/null
  "$OFLOOP_BIN" build prepare "$REPO5" "$RID5" >/dev/null
  local wt="$REPO5/.worktrees/ownframework-loop/$RID5/builder"
  mkdir -p "$wt/src" && echo "$marker" > "$wt/src/marker.txt"
  git -C "$wt" add src/marker.txt && git -C "$wt" commit -m "candidate $marker" >/dev/null
  local sem
  sem="$("$OFLOOP_BIN" build agent-skeleton "$REPO5" "$RID5" | jq -r '.agent_result_path')"
  python3 - "$sem" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1]); d = json.loads(p.read_text())
d["summary"] = "fuse fixture"
d["outcome_requested"] = "candidate_ready"
d["unit_ids_completed"] = ["UNIT-1"]
d["acceptance_addressed"] = ["AC-1"]
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
  "$OFLOOP_BIN" build finalize "$REPO5" "$RID5" "$sem" >/dev/null
}

review_cycle_with_finding() {
  "$OFLOOP_BIN" review claim "$REPO5" "$RID5" --actor test >/dev/null
  "$OFLOOP_BIN" review prepare "$REPO5" "$RID5" >/dev/null
  local as
  as="$("$OFLOOP_BIN" review assessment-skeleton "$REPO5" "$RID5" | jq -r '.assessment_path')"
  python3 - "$as" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1]); d = json.loads(p.read_text())
d["acceptance_results"] = [{"id": "AC-1", "result": "pass", "evidence": "ok"}]
d["non_goal_results"] = []
d["findings"] = [{
    "classification": "must_fix",
    "title": "identical structural finding",
    "detail": "the same must-fix finding, repeated verbatim",
}]
d["recommended_verdict"] = "CHANGES_REQUESTED"
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
  "$OFLOOP_BIN" review finalize "$REPO5" "$RID5" "$as" >/dev/null
}

build_cycle "one"
review_cycle_with_finding
ST5A="$(jq -r '.state' "$REPO5/.ownframework-loop/$RID5/STATE.json")"
assert_eq "$ST5A" "READY_TO_BUILD" "T5 first identical finding -> repairable CHANGES_REQUESTED cycle"
STREAK5A="$(jq -r '.identical_finding_streak' "$REPO5/.ownframework-loop/$RID5/STATE.json")"
assert_eq "$STREAK5A" "1" "T5 first occurrence sets streak 1"

build_cycle "two"
review_cycle_with_finding
V5="$(jq -r '.verdict' "$REPO5/.ownframework-loop/$RID5/REVIEW_VERDICT.json")"
assert_eq "$V5" "BLOCKED" "T5 verbatim-repeated must-fix set trips the fuse -> BLOCKED"
FR5="$(jq -r '.failure_reason' "$REPO5/.ownframework-loop/$RID5/REVIEW_VERDICT.json")"
assert_eq "$FR5" "identical_finding_repeats" "T5 fuse failure reason recorded"
EX5="$(jq -r '.identical_finding_check.exhausted' "$REPO5/.ownframework-loop/$RID5/REVIEW_VERDICT.json")"
assert_eq "$EX5" "true" "T5 verdict carries identical_finding_check evidence"
ST5B="$(jq -r '.state' "$REPO5/.ownframework-loop/$RID5/STATE.json")"
assert_eq "$ST5B" "BLOCKED" "T5 run sealed BLOCKED by the fuse"

# Fingerprint stability: order-insensitive, change-sensitive.
python3 -B <<'PY'
import os, sys
sys.path.insert(0, os.environ["OFLOOP_LIB"])
from ownframework_loop.review_finalize import _must_fix_fingerprint
a = {"classification": "must_fix", "title": "t", "detail": "d"}
b = {"classification": "must_fix", "title": "u", "detail": "e"}
assert _must_fix_fingerprint([]) == ""
assert _must_fix_fingerprint([a, b]) == _must_fix_fingerprint([b, a])
assert _must_fix_fingerprint([a]) != _must_fix_fingerprint([b])
print("  PASS: T5 must-fix fingerprint is order-insensitive and change-sensitive")
PY

# =====================================================================
# T6: authority boundary — publish forbidden, local toolchain allowed
# =====================================================================
python3 -B <<'PY'
import os, sys
sys.path.insert(0, os.environ["OFLOOP_LIB"])
from ownframework_loop import guards

def sev(cmd, role=None):
    return guards.classify_bash_command(cmd, role=role)["severity"]

# Registry publish/deploy joins the forbidden list for every lane.
for cmd in [
    "docker push registry.example.com/app:1",
    "docker compose push",
    "docker-compose push",
    "npm publish",
    "pnpm publish",
    "yarn publish",
    "cargo publish",
    "twine upload dist/*",
]:
    assert sev(cmd) == "forbidden", cmd
    assert sev(cmd, role="builder") == "forbidden", cmd

# Local engineering stays legitimate for the builder.
for cmd in [
    "docker compose up -d",
    "docker compose down",
    "docker build -t app .",
    "npm install",
    "pytest -q",
    "curl -s http://127.0.0.1:8000/health",
]:
    assert sev(cmd, role="builder") == "allowed", cmd

# Reviewer lane: project validation toolchain allowed, source mutation not.
for cmd in [
    "pytest -q",
    "npm test",
    "make test",
    "just test",
    "cargo test",
    "go test ./...",
    "docker compose up -d",
    "curl -s http://127.0.0.1:54321/status",
]:
    assert sev(cmd, role="reviewer") == "allowed", cmd
for cmd in [
    "git commit -m x",
    "git push origin master",
    "docker push foo/bar",
    "npm publish",
    "rm -rf src",
]:
    assert sev(cmd, role="reviewer") == "forbidden", cmd
print("  PASS: T6 registry publish forbidden; local orchestration and reviewer validation allowed")
PY

# =====================================================================
# T7: foreground scheduling immediacy
# =====================================================================
python3 -B <<'PY'
import os, sys
sys.path.insert(0, os.environ["OFLOOP_LIB"])
from ownframework_loop import scheduling

r = scheduling.recommend_next_delay_minutes
# The next semantic action is available -> zero idle delay.
assert r(role="builder", state="READY_FOR_REVIEW") == ("RESCHEDULE", 0)
assert r(role="reviewer", state="READY_TO_BUILD") == ("RESCHEDULE", 0)
assert r(role="reviewer", state="CHANGES_REQUESTED") == ("RESCHEDULE", 0)
# Pre-start is STARTABLE for the builder (first claim auto-seals), WAIT for
# the reviewer — never STOP.
assert r(role="builder", state="AWAITING_APPROVAL") == ("RESCHEDULE", 0)
act, delay = r(role="reviewer", state="AWAITING_APPROVAL")
assert act == "RESCHEDULE" and delay > 0, (act, delay)
# Terminal states stop both lanes.
for st in ("APPROVED", "BLOCKED", "STOPPED"):
    assert r(role="builder", state=st) == ("STOP", 0)
    assert r(role="reviewer", state=st) == ("STOP", 0)
print("  PASS: T7 no idle gap between passes; pre-start STARTABLE/WAIT, terminal STOP")
PY

echo "V070_AUTONOMY_ENVELOPE=PASS"
