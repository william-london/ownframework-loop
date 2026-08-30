#!/usr/bin/env bash
# v0.7.2 architecture closure — execution-semantics regression tests.
#
# Covers the independent source-review findings:
#   F2  PROGRAM global source ceilings wired into real execution with
#       absolute baseline-to-candidate accounting (not additive deltas)
#   F3  the final funded repair round reaches its review; exhaustion then
#       fails closed at repair-claim time
#   F4  build finalization re-proves candidate identity AFTER validation
#       and terminalizes BLOCKED when validation mutated the candidate
#   F8  a funded wall ceiling constrains the launched pass timeout
#   F11/F13 schema maxima, executable envelope, and default fuses agree
#
# No model is called; synthetic semantic artifacts are schema-correct.

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

OFLOOP="$OFLOOP_BIN"

# An approved single-mode run whose risk budget we control exactly.
make_budget_run() {
  local repo="$1" max_repair="$2"
  "$OFLOOP" spec new "$repo" "closure-budget-mission" >/dev/null
  local rid
  rid="$(ls -1t "$repo/.ownframework-loop" | head -n1)"
  local pp="$repo/.ownframework-loop/$rid/WORK_PACKET.md"
  cat > "$pp" <<EOF
\`\`\`json
{
  "schema": "ownframework-work-packet/v2",
  "packet_id": "p-closure",
  "created_at": "2026-08-29T00:00:00Z",
  "work_class": "FEATURE",
  "risk_class": "low",
  "title": "closure budget run",
  "target": {"repo": "$repo", "branch": "master", "classification": "local_only"},
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
    "max_build_passes": 8,
    "max_review_passes": 8,
    "max_repair_rounds": $max_repair,
    "max_files_changed": 25,
    "max_diff_lines": 1000
  }
}
\`\`\`
body
EOF
  python3 - "$repo" "$rid" <<'PY'
import sys
from pathlib import Path
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get("OFLOOP_LIB"))
from ownframework_loop import execution_start
execution_start.ensure_executable(
    canonical_repo=Path(sys.argv[1]),
    run_id=sys.argv[2],
    actor="test",
    binding_method="build_start",
)
PY
  echo "$rid"
}

build_round() {
  # claim BUILD, write/commit one file, fill semantic result, finalize.
  local repo="$1" rid="$2" filename="$3" content="$4"
  local order wt sem
  order="$("$OFLOOP" dispatch claim "$repo" "$rid")"
  assert_eq "$(printf '%s' "$order" | jq -r '.decision')" "BUILD" "dispatch BUILD claim"
  wt="$(printf '%s' "$order" | jq -r '.worktree')"
  sem="$(printf '%s' "$order" | jq -r '.semantic_path')"
  mkdir -p "$wt/src"
  printf '%s\n' "$content" > "$wt/src/$filename"
  git -C "$wt" add "src/$filename"
  git -C "$wt" commit -m "closure candidate" >/dev/null
  python3 - "$sem" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
d = json.loads(p.read_text())
d["summary"] = "synthetic closure builder result"
d["outcome_requested"] = "candidate_ready"
d["unit_ids_completed"] = ["UNIT-1"]
d["acceptance_addressed"] = ["AC-1"]
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
  "$OFLOOP" dispatch finalize "$repo" "$rid" BUILD "$sem" >/dev/null
}

review_round() {
  # claim REVIEW, fill verdict recommendation, finalize.
  local repo="$1" rid="$2" verdict="$3"
  local order sem
  order="$("$OFLOOP" dispatch claim "$repo" "$rid")"
  assert_eq "$(printf '%s' "$order" | jq -r '.decision')" "REVIEW" "dispatch REVIEW claim"
  sem="$(printf '%s' "$order" | jq -r '.semantic_path')"
  python3 - "$sem" "$verdict" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
verdict = sys.argv[2]
d = json.loads(p.read_text())
d["validation_results"] = []
if verdict == "APPROVED":
    d["acceptance_results"] = [{"id": "AC-1", "result": "pass", "evidence": "ok"}]
    d["findings"] = []
else:
    d["acceptance_results"] = [{"id": "AC-1", "result": "fail", "evidence": "needs repair"}]
    d["findings"] = [{"id": "F-1", "severity": "must_fix", "summary": "needs repair"}]
d["non_goal_results"] = []
d["recommended_verdict"] = verdict
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
  "$OFLOOP" dispatch finalize "$repo" "$rid" REVIEW "$sem" >/dev/null
}

# ---------------------------------------------------------------------------
# T1 (F3): the FINAL funded repair must reach its review.
# max_repair_rounds=1: reject the first review (funds repair round 1), then
# the repaired candidate MUST get review #2 and may be APPROVED. The legacy
# build-finalize block-on-repair-cap starved exactly this review.
# ---------------------------------------------------------------------------
REP1="$(make_tmp_repo)"
RUN1="$(make_budget_run "$REP1" 1)"
build_round "$REP1" "$RUN1" "v1.py" 'def v1(): return "first"'
review_round "$REP1" "$RUN1" "CHANGES_REQUESTED"
assert_eq "$(jq -r '.repair_round' "$REP1/.ownframework-loop/$RUN1/STATE.json")" "1" \
  "repair round 1 funded at first rejection"
build_round "$REP1" "$RUN1" "v2.py" 'def v2(): return "repaired"'
assert_eq "$(jq -r '.state' "$REP1/.ownframework-loop/$RUN1/STATE.json")" "READY_FOR_REVIEW" \
  "final funded repair reaches review (no starvation at build finalize)"
review_round "$REP1" "$RUN1" "APPROVED"
assert_eq "$(jq -r '.state' "$REP1/.ownframework-loop/$RUN1/STATE.json")" "APPROVED" \
  "final repaired candidate approved through its earned review"

# Negative half: when the final funded repair is ALSO rejected, the NEXT
# repair claim fails closed and seals BLOCKED — no unfunded builder pass.
REP2="$(make_tmp_repo)"
RUN2="$(make_budget_run "$REP2" 1)"
build_round "$REP2" "$RUN2" "v1.py" 'def v1(): return "first"'
review_round "$REP2" "$RUN2" "CHANGES_REQUESTED"
build_round "$REP2" "$RUN2" "v2.py" 'def v2(): return "still broken"'
review_round "$REP2" "$RUN2" "CHANGES_REQUESTED"
assert_eq "$(jq -r '.state' "$REP2/.ownframework-loop/$RUN2/STATE.json")" "BLOCKED" \
  "repair envelope exhausted -> sealed BLOCKED at claim time"
TERM_ORDER="$("$OFLOOP" dispatch claim "$REP2" "$RUN2")"
assert_eq "$(printf '%s' "$TERM_ORDER" | jq -r '.decision')" "TERMINAL" \
  "dispatch reports TERMINAL after repair exhaustion"

# An approved single-mode run whose packet declares one required validation
# command from the start (the execution seal binds these packet bytes).
make_validation_run() {
  local repo="$1" vname="$2" vcmd="$3"
  "$OFLOOP" spec new "$repo" "closure-validation-mission" >/dev/null
  local rid
  rid="$(ls -1t "$repo/.ownframework-loop" | head -n1)"
  local pp="$repo/.ownframework-loop/$rid/WORK_PACKET.md"
  cat > "$pp" <<EOF
\`\`\`json
{
  "schema": "ownframework-work-packet/v2",
  "packet_id": "p-validation",
  "created_at": "2026-08-29T00:00:00Z",
  "work_class": "FEATURE",
  "risk_class": "low",
  "title": "closure validation run",
  "target": {"repo": "$repo", "branch": "master", "classification": "local_only"},
  "acceptance_criteria": [{"id": "AC-1", "text": "ok"}],
  "non_goals": [],
  "allowed_paths": ["src/"],
  "protected_paths": [".ownframework-loop/"],
  "work_units": [{"id": "UNIT-1", "title": "u", "scope": "s"}],
  "required_validation": [
    {"name": "$vname", "command": "$vcmd", "kind": "fast"}
  ],
  "merge_authority": "human_only",
  "deploy_authority": "human_only",
  "push_authority": "human_only",
  "external_action_authority": "none",
  "risk_budget": {
    "max_build_passes": 8,
    "max_review_passes": 8,
    "max_repair_rounds": 2,
    "max_files_changed": 25,
    "max_diff_lines": 1000
  }
}
\`\`\`
body
EOF
  python3 - "$repo" "$rid" <<'PY'
import sys
from pathlib import Path
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get("OFLOOP_LIB"))
from ownframework_loop import execution_start
execution_start.ensure_executable(
    canonical_repo=Path(sys.argv[1]),
    run_id=sys.argv[2],
    actor="test",
    binding_method="build_start",
)
PY
  echo "$rid"
}

# ---------------------------------------------------------------------------
# T2 (F4): validation that mutates the candidate worktree must fail closed.
# The packet-declared validation command `touch MUTATION_MARKER` exits 0 but
# dirties the builder worktree; the identity re-proof must terminalize
# BLOCKED with the evidence in the receipt.
# ---------------------------------------------------------------------------
REP3="$(make_tmp_repo)"
RUN3="$(make_validation_run "$REP3" "mutating_validation" "touch MUTATION_MARKER")"
build_round "$REP3" "$RUN3" "v1.py" 'def v1(): return "first"'
STATE3="$(jq -r '.state' "$REP3/.ownframework-loop/$RUN3/STATE.json")"
assert_eq "$STATE3" "BLOCKED" "validation-mutated candidate fails closed to BLOCKED"
REPROOF3="$(jq -r '.candidate_identity_reproof.result' "$REP3/.ownframework-loop/$RUN3/BUILD_RECEIPT.json")"
assert_eq "$REPROOF3" "fail" "receipt records the failed identity re-proof"
PROGCHK3="$(jq -r '.program_source_ceiling_check.result' "$REP3/.ownframework-loop/$RUN3/BUILD_RECEIPT.json")"
assert_eq "$PROGCHK3" "not_applicable" "single run carries not_applicable program ceiling check"

# Positive control: identical run shape with a non-mutating validation.
REP4="$(make_tmp_repo)"
RUN4="$(make_validation_run "$REP4" "clean_validation" "true")"
build_round "$REP4" "$RUN4" "v1.py" 'def v1(): return "first"'
assert_eq "$(jq -r '.state' "$REP4/.ownframework-loop/$RUN4/STATE.json")" "READY_FOR_REVIEW" \
  "clean validation passes the identity re-proof"
assert_eq "$(jq -r '.candidate_identity_reproof.result' "$REP4/.ownframework-loop/$RUN4/BUILD_RECEIPT.json")" \
  "pass" "receipt records a passing identity re-proof"

# ---------------------------------------------------------------------------
# T3 (F2): PROGRAM source ceilings — absolute accounting + live enforcement.
# ---------------------------------------------------------------------------
python3 - "$LIB_DIR" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from ownframework_loop import program

packet = {
    "schema": program.PROGRAM_SCHEMA_VERSION,
    "execution_mode": "program",
    "checkpoint_graph": {
        "execution_order": ["CP-1"],
        "global_source_ceilings": {
            "max_unique_changed_files": 3,
            "max_baseline_to_final_diff_lines": 50,
        },
        "checkpoints": [{
            "id": "CP-1", "title": "t", "scope": "s", "depends_on": [],
            "risk_budget": {"max_build_passes": 2, "max_review_passes": 2,
                            "max_repair_rounds": 1},
        }],
    },
    "risk_budget": {"max_build_passes": 2, "max_review_passes": 2,
                    "max_repair_rounds": 1},
}
ps = program.materialise_initial_program_state(
    packet, baseline_sha="0" * 40, candidate_branch="factory/candidate/x",
)
# Absolute (baseline-to-candidate) semantics: a second measurement may
# legitimately go DOWN. Additive accounting could never do this.
ps = program.record_source_accounting(ps, files_changed_unique=3, diff_lines_total=40)
assert ps["cumulative_counters"]["files_changed_unique"] == 3
assert ps["cumulative_counters"]["diff_lines_total"] == 40
ps = program.record_source_accounting(ps, files_changed_unique=1, diff_lines_total=10)
assert ps["cumulative_counters"]["files_changed_unique"] == 1, ps["cumulative_counters"]
assert ps["cumulative_counters"]["diff_lines_total"] == 10, ps["cumulative_counters"]
# Breach fails closed.
try:
    program.record_source_accounting(ps, files_changed_unique=4, diff_lines_total=10)
    raise AssertionError("file ceiling breach must raise")
except program.ProgramStateError as e:
    assert "global file cap reached" in str(e), e
try:
    program.record_source_accounting(ps, files_changed_unique=1, diff_lines_total=51)
    raise AssertionError("diff ceiling breach must raise")
except program.ProgramStateError as e:
    assert "global diff-lines cap reached" in str(e), e
print("PROGRAM_SOURCE_ACCOUNTING=OK")
PY
pass "PROGRAM source ceilings use absolute baseline-to-candidate accounting and fail closed"

# End-to-end PROGRAM enforcement: a candidate exceeding the packet's
# max_baseline_to_final_diff_lines must BLOCK at build finalize.
REP5="$(make_tmp_repo)"
"$OFLOOP" spec new "$REP5" "program-ceiling-mission" >/dev/null
RUN5="$(ls -1t "$REP5/.ownframework-loop" | head -n1)"
PP5="$REP5/.ownframework-loop/$RUN5/WORK_PACKET.md"
python3 - "$PP5" "$REP5" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
repo = sys.argv[2]
packet = {
    "schema": "ownframework-work-packet/v3",
    "packet_id": "p-ceiling",
    "created_at": "2026-08-29T00:00:00Z",
    "work_class": "FEATURE",
    "risk_class": "low",
    "title": "program ceiling mission",
    "target": {"repo": repo, "branch": "master", "classification": "local_only"},
    "execution_mode": "program",
    "checkpoint_graph": {
        "execution_order": ["CP-1"],
        "global_source_ceilings": {
            "max_unique_changed_files": 500,
            "max_baseline_to_final_diff_lines": 3
        },
        "checkpoints": [{
            "id": "CP-1", "title": "t", "scope": "src/", "depends_on": [],
            "risk_budget": {"max_build_passes": 2, "max_review_passes": 2,
                            "max_repair_rounds": 1}
        }]
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
    "risk_budget": {"max_build_passes": 2, "max_review_passes": 2,
                    "max_repair_rounds": 1, "max_files_changed": 25,
                    "max_diff_lines": 1000}
}
fence = chr(96) * 3
p.write_text(fence + "json\n" + json.dumps(packet, sort_keys=True) + "\n" + fence + "\n")
PY
ORDER5="$("$OFLOOP" dispatch claim "$REP5" "$RUN5")"
assert_eq "$(printf '%s' "$ORDER5" | jq -r '.decision')" "BUILD" "program BUILD claim"
WT5="$(printf '%s' "$ORDER5" | jq -r '.worktree')"
SEM5="$(printf '%s' "$ORDER5" | jq -r '.semantic_path')"
mkdir -p "$WT5/src"
printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n' > "$WT5/src/big.py"
git -C "$WT5" add src/big.py
git -C "$WT5" commit -m "oversized candidate" >/dev/null
python3 - "$SEM5" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
d = json.loads(p.read_text())
d["summary"] = "synthetic program builder"
d["outcome_requested"] = "candidate_ready"
d["unit_ids_completed"] = ["UNIT-1"]
d["acceptance_addressed"] = ["AC-1"]
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
"$OFLOOP" dispatch finalize "$REP5" "$RUN5" BUILD "$SEM5" >/dev/null
assert_eq "$(jq -r '.state' "$REP5/.ownframework-loop/$RUN5/STATE.json")" "BLOCKED" \
  "PROGRAM diff-lines ceiling breach blocks at build finalize"
assert_eq "$(jq -r '.program_source_ceiling_check.result' "$REP5/.ownframework-loop/$RUN5/BUILD_RECEIPT.json")" \
  "fail" "receipt records the ceiling breach"
python3 - "$REP5" "$RUN5" <<'PY'
import json, sys
from pathlib import Path
s = json.load(open(Path(sys.argv[1]) / ".ownframework-loop" / sys.argv[2] / "STATE.json"))
counters = s["program"]["cumulative_counters"]
# 10 lines added, 1 unique file — absolute measurement, wired into state.
assert counters["files_changed_unique"] == 1, counters
assert counters["diff_lines_total"] == 10, counters
print("PROGRAM_CEILING_COUNTERS=OK")
PY
pass "PROGRAM ceilings are wired into live execution with real accounting"

# ---------------------------------------------------------------------------
# T4 (F8): a funded wall ceiling clamps the launched pass timeout.
# ---------------------------------------------------------------------------
TMP_WALL="$(mktemp -d -t ofloop_v072_wall.XXXXXX)"
python3 - "$LIB_DIR" "$TMP_WALL" <<'PY'
import json, os, sys, time
sys.path.insert(0, sys.argv[1])
from pathlib import Path
from ownframework_loop import supervisor

root = Path(sys.argv[2])
repo = root / "repo-wall"
repo.mkdir(parents=True, exist_ok=True)
rd = repo / ".ownframework-loop" / "run-wall"
rd.mkdir(parents=True)
(rd / "STATE.json").write_text(json.dumps({"state": "BUILDING"}), encoding="utf-8")
(rd / "WORK_PACKET.md").write_text(
    "```json\n" + json.dumps({"schema": "ownframework-work-packet/v2",
                              "execution_mode": "single", "risk_budget": {}})
    + "\n```\n", encoding="utf-8")
semantic = rd / "BUILD_AGENT_RESULT.json"
semantic.write_text("{}", encoding="utf-8")
db = root / "wall.sqlite3"

class RecordingRunner:
    runner_id = "recording-runner"
    recorded_timeout = None

    def preflight(self):
        return supervisor.RunnerReadiness(True)

    def run(self, work_order, **kwargs):
        type(self).recorded_timeout = kwargs.get("timeout_seconds")
        return supervisor.RunnerResult(
            ok=True, returncode=0, cost_usd=0.1, cost_known=True,
            tokens_known=True, input_tokens=10, output_tokens=5,
            stdout='{"is_error":false,"total_cost_usd":0.1}', stderr="",
        )

supervisor.register_runner(RecordingRunner)

order = {
    "schema": supervisor.dispatch_mod.SCHEMA,
    "decision": "BUILD",
    "role": "builder",
    "run_id": "run-wall",
    "state": "BUILDING",
    "replayed": False,
    "canonical_repo": str(repo),
    "worktree": str(repo),
    "semantic_path": str(semantic),
}
supervisor.dispatch_mod.claim_next = lambda **kwargs: dict(order)
# Not replay-ready: force the real runner launch path under test.
supervisor.dispatch_mod.semantic_result_ready = lambda work_order: (False, "builder_summary_empty")
finalizer_timeouts = []
def fake_finalize(work_order, **kwargs):
    finalizer_timeouts.append(kwargs.get("timeout_seconds"))
    return {"ok": True}
supervisor.dispatch_mod.finalize_work_order = fake_finalize

supervisor.enqueue(
    canonical_repo=repo, run_id="run-wall", runner="recording-runner",
    db_path=db, max_wall_seconds=120,
)
# The run has already consumed 60s of its 120s wall budget.
import sqlite3
conn = sqlite3.connect(str(db))
conn.execute(
    "UPDATE jobs SET execution_started_at=? WHERE run_id='run-wall'",
    (time.time() - 60.0,),
)
conn.commit()
conn.close()

result = supervisor.run_one(db_path=db)
assert result["action"] == "BUILD", result
t = RecordingRunner.recorded_timeout
assert t is not None and t <= 60, f"pass timeout not clamped to remaining wall: {t}"
assert len(finalizer_timeouts) == 1, finalizer_timeouts
ft = finalizer_timeouts[0]
assert ft is not None and 0 < ft <= 60, f"finalizer timeout not clamped to remaining wall: {ft}"
print(f"WALL_CLAMP_OK runner_timeout={t} finalizer_timeout={ft}")
PY
rm -rf "$TMP_WALL"
pass "funded wall ceiling clamps the launched pass to remaining wall time"

# ---------------------------------------------------------------------------
# T5 (F11/F13): schema maxima == executable envelope == default fuses.
# ---------------------------------------------------------------------------
python3 - "$LIB_DIR" "$ROOT_DIR" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
from pathlib import Path
from ownframework_loop import limits, packet as packet_mod, util

root = Path(sys.argv[2])
v2 = json.loads((root / "schemas" / "work-packet.schema.json").read_text())
v3 = json.loads((root / "schemas" / "work-packet-v3.schema.json").read_text())

# F13: the no-progress fuse must agree across default, absolute envelope,
# and both packet schemas.
np_default = limits.MAX_CONSECUTIVE_NO_PROGRESS_PASSES
np_absolute = util.ABSOLUTE_BUDGET_CEILING["max_consecutive_no_progress_passes"]
np_v2 = v2["properties"]["risk_budget"]["properties"]["max_consecutive_no_progress_passes"]["maximum"]
np_v3 = v3["properties"]["risk_budget"]["properties"]["max_consecutive_no_progress_passes"]["maximum"]
assert np_default == np_absolute == np_v2 == np_v3 == 8, (np_default, np_absolute, np_v2, np_v3)

# F11: every schema risk_budget maximum must be exactly honored AND exactly
# refused by the executable envelope validator (probe with maximum+1).
def probe(schema_id, key, value):
    rb = {"max_files_changed": 25, "max_diff_lines": 100, "max_repair_rounds": 2}
    rb[key] = value  # the key under test must win, not a filler default
    meta = {
        "schema": schema_id, "packet_id": "p", "created_at": "2026-08-29T00:00:00Z",
        "work_class": "BUG", "risk_class": "low", "title": "t",
        "target": {"repo": "/r", "branch": "master", "classification": "local_only"},
        "acceptance_criteria": [{"id": "AC-1", "text": "ok"}],
        "non_goals": [], "allowed_paths": ["src/"], "protected_paths": ["x/"],
        "work_units": [{"id": "UNIT-1", "title": "u", "scope": "s"}],
        "merge_authority": "human_only", "deploy_authority": "human_only",
        "push_authority": "human_only", "external_action_authority": "none",
        "risk_budget": rb,
    }
    return packet_mod.validate_packet_metadata(meta)

for schema_id, schema in (("ownframework-work-packet/v2", v2),
                          ("ownframework-work-packet/v3", v3)):
    rb = schema["properties"]["risk_budget"]["properties"]
    for key, spec in rb.items():
        maximum = spec.get("maximum")
        if maximum is None:
            continue
        # value == maximum must pass the envelope; maximum+1 must be refused.
        errs_at = [e for e in probe(schema_id, key, maximum) if "exceeds executable ceiling" in e]
        assert not errs_at, f"{schema_id}.{key}={maximum} refused by runtime: {errs_at}"
        errs_over = [e for e in probe(schema_id, key, maximum + 1) if "exceeds executable ceiling" in e]
        assert errs_over, f"{schema_id}.{key}={maximum + 1} accepted by runtime (schema/runtime drift)"
print("SCHEMA_ENVELOPE_AGREEMENT=OK")
PY
pass "schema maxima, executable envelope, and default fuses all agree"

echo "V072_EXECUTION_CLOSURE=PASS"
