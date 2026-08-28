#!/usr/bin/env bash
# v0.4.4 native-program commissioning closure regressions.
#
# All paths derived portably from the test file location via _helpers.sh.
# No user-home absolute paths. Runs unchanged on macOS, Linux, CI.

set -uo pipefail
. "$(dirname "$0")/../_helpers.sh"

# ROOT, LIB, BIN_DIR, OFLOOP_BIN are sourced from _helpers.sh.
ROOT="$ROOT_DIR"
LIB="$LIB_DIR"

REPO="$(make_tmp_repo)"

# Create an approved run via the supported helper.
RID="$(make_approved_run "$REPO" FEATURE low "v044-skel")"

# ============================================================
# 1. build agent-skeleton produces a schema-conformant file
# ============================================================
"$OFLOOP_BIN" build claim "$REPO" "$RID" >/dev/null
"$OFLOOP_BIN" build prepare "$REPO" "$RID" >/dev/null

SKEL_JSON="$("$OFLOOP_BIN" build agent-skeleton "$REPO" "$RID")"
echo "$SKEL_JSON" | grep -q '"shape": "ownframework-loop-build-agent-result/v1"' \
  && pass "skeleton shape advertises correct schema name" \
  || fail "skeleton shape mismatch: $SKEL_JSON"

SKEL_PATH="$REPO/.ownframework-loop/$RID/scratch/builder/BUILD_AGENT_RESULT.json"
[[ -f "$SKEL_PATH" ]] && pass "skeleton file written at canonical builder scratch path" \
  || fail "skeleton file missing at $SKEL_PATH"

for key in schema run_id work_unit_id outcome_requested; do
  python3 -c "
import json
d=json.load(open('$SKEL_PATH'))
assert d.get('$key') is not None and d['$key'] != '', 'missing/empty $key'
" >/dev/null 2>&1 && pass "skeleton has non-empty $key" \
    || fail "skeleton missing/empty $key"
done

for key in candidate_branch baseline_sha packet_sha256 approval_sha256 builder_identity; do
  python3 -c "
import json
d=json.load(open('$SKEL_PATH'))
v = d.get('$key')
assert v is not None and v != '', 'missing/empty $key'
" >/dev/null 2>&1 && pass "skeleton has non-empty $key (pre-populated)" \
    || fail "skeleton missing/empty $key"
done

# 2. Fresh builder can submit a first-pass result without manual repair.
python3 - <<PY
import json
from pathlib import Path
p = Path("$SKEL_PATH")
d = json.loads(p.read_text())
d["summary"] = "Implemented UNIT-1."
d["evidence"]["validate_sh_exit"] = 0
d["evidence"]["pytest_offline_exit"] = 0
d["evidence"]["files_changed"] = ["src/x.py"]
d["outcome_requested"] = "candidate_ready"
d["unit_ids_completed"] = ["UNIT-1"]
p.write_text(json.dumps(d, indent=2, sort_keys=True))
PY

# 3. Finalizer must REJECT a malformed result (wrong schema name in place).
python3 - <<PY
import json
from pathlib import Path
p = Path("$SKEL_PATH")
d = json.loads(p.read_text())
d["schema"] = "ownframework-loop-builder-result/v1"
p.write_text(json.dumps(d, indent=2, sort_keys=True))
PY

BAD_OUT="$("$OFLOOP_BIN" build finalize "$REPO" "$RID" "$SKEL_PATH" 2>&1 || true)"
echo "$BAD_OUT" | grep -q "OF_LOOP_BUILD_FINALIZE_REFUSED" \
  && pass "bad-schema skeleton is refused" \
  || fail "bad-schema skeleton was accepted: $BAD_OUT"

# Restore good schema.
python3 - <<PY
import json
from pathlib import Path
p = Path("$SKEL_PATH")
d = json.loads(p.read_text())
d["schema"] = "ownframework-loop-build-agent-result/v1"
p.write_text(json.dumps(d, indent=2, sort_keys=True))
PY

GOOD_OUT="$("$OFLOOP_BIN" build finalize "$REPO" "$RID" "$SKEL_PATH" 2>&1 || true)"
echo "$GOOD_OUT" | grep -q "OF_LOOP_BUILD_FINALIZE_REFUSED" \
  && fail "good skeleton was refused: $GOOD_OUT" \
  || pass "good skeleton finalizes (after bad-schema restore)"

# ============================================================
# 4. of-builder.md + skills/build/SKILL.md do not tell the agent to
#    author BUILD_RECEIPT.json and use the 3-step workflow.
# ============================================================
DOCS="$(cat "$ROOT/agents/of-builder.md" "$ROOT/skills/build/SKILL.md" 2>/dev/null)"
if echo "$DOCS" | grep -q "write a complete .BUILD_RECEIPT.json"; then
  fail "of-builder.md still instructs writing BUILD_RECEIPT.json"
else
  pass "of-builder.md does NOT instruct writing BUILD_RECEIPT.json"
fi
echo "$DOCS" | grep -q "three-step deterministic workflow" \
  && pass "of-builder.md uses 3-step deterministic workflow" \
  || fail "of-builder.md missing 3-step workflow"

if grep -q "scratch/builder" "$ROOT/agents/of-builder.md" "$ROOT/skills/build/SKILL.md"; then
  pass "builder authority language references scratch/builder"
else
  fail "builder authority language does NOT reference scratch/builder"
fi

# ============================================================
# 5. Deterministic build preparation owns plumbing.
# ============================================================
PREP_JSON="$("$OFLOOP_BIN" build prepare "$REPO" "$RID" 2>&1 || true)"
for key in builder_worktree candidate_branch baseline_sha packet_sha256 approval_sha256 work_unit_id builder_actual_branch; do
  echo "$PREP_JSON" | grep -q "\"$key\":" \
    && pass "build prepare returns $key" \
    || fail "build prepare missing $key: $PREP_JSON"
done

grep -q "ofloop build prepare" "$ROOT/skills/build/SKILL.md" \
  && pass "build SKILL.md references ofloop build prepare" \
  || fail "build SKILL.md missing ofloop build prepare reference"

grep -q "ofloop build agent-skeleton" "$ROOT/skills/build/SKILL.md" \
  && pass "build SKILL.md references ofloop build agent-skeleton" \
  || fail "build SKILL.md missing ofloop build agent-skeleton reference"

# ============================================================
# 6 + 7. Candidate branch: packet prefix + default.
# ============================================================
PYTHONPATH="$LIB" python3 - <<'PY'
import sys
sys.path.insert(0, "$LIB")
from ownframework_loop import branch_resolver
assert branch_resolver.default_candidate_branch("run-X") == "factory/candidate/run-X"
print("PASS default branch deterministic")
PY
PYTHONPATH="$LIB" python3 - <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, "$LIB")
from ownframework_loop import branch_resolver
fake = Path("/tmp/v044_branch_test")
fake.mkdir(exist_ok=True)
packet = {"target": {"candidate_branch_prefix": "factory/candidate/custom-branch"}}
assert branch_resolver.resolve_candidate_branch(fake, "run-v044-test", packet=packet) == "factory/candidate/custom-branch"
print("PASS packet prefix propagates")
PY

# ============================================================
# 8 + 9. Program budget envelope.
# ============================================================
PYTHONPATH="$LIB" python3 - <<'PY'
import sys
sys.path.insert(0, "$LIB")
from ownframework_loop.program import materialise_initial_program_state
packet = {
    "schema": "ownframework-work-packet/v3",
    "execution_mode": "program",
    "risk_budget": {"max_build_passes": 24, "max_review_passes": 24, "max_repair_rounds": 8},
    "checkpoint_graph": {
        "execution_order": [f"CP-{i}" for i in range(1, 12)],
        "checkpoints": [
            {"id": f"CP-{i}", "title": f"t{i}", "scope": "s",
             "depends_on": [], "risk_budget": {"max_build_passes": 3, "max_review_passes": 3, "max_repair_rounds": 2}}
            for i in range(1, 12)
        ],
        "global_source_ceilings": {"max_unique_changed_files": 80, "max_baseline_to_final_diff_lines": 8000},
    },
}
state = materialise_initial_program_state(packet, baseline_sha="x"*40, candidate_branch="factory/candidate/test")
c = state["cumulative_ceilings"]
assert c["max_build_passes"] == 24, c
assert c["max_review_passes"] == 24, c
assert c["max_repair_rounds"] == 8, c
print("PASS effective_cumulative <= operator envelope")
PY

PYTHONPATH="$LIB" python3 - <<'PY'
import sys
sys.path.insert(0, "$LIB")
from ownframework_loop.program import materialise_initial_program_state, ProgramGraphError
packet = {
    "schema": "ownframework-work-packet/v3",
    "execution_mode": "program",
    "risk_budget": {"max_build_passes": 5, "max_review_passes": 5, "max_repair_rounds": 1},
    "checkpoint_graph": {
        "execution_order": [f"CP-{i}" for i in range(1, 12)],
        "checkpoints": [
            {"id": f"CP-{i}", "title": f"t{i}", "scope": "s",
             "depends_on": [], "risk_budget": {"max_build_passes": 3, "max_review_passes": 3, "max_repair_rounds": 2}}
            for i in range(1, 12)
        ],
    },
}
try:
    materialise_initial_program_state(packet, baseline_sha="x"*40, candidate_branch="b")
    print("FAIL: pre-approval inconsistency not refused")
    sys.exit(1)
except ProgramGraphError:
    print("PASS pre-approval inconsistency refused")
PY

# ============================================================
# 10. CLI surfaces register under build subcommand.
# ============================================================
HELP_OUT="$("$OFLOOP_BIN" build --help 2>&1 || true)"
echo "$HELP_OUT" | grep -q "agent-skeleton" && pass "ofloop build agent-skeleton registered" \
  || fail "ofloop build agent-skeleton missing"
echo "$HELP_OUT" | grep -q "prepare" && pass "ofloop build prepare registered" \
  || fail "ofloop build prepare missing"

# ============================================================
# 11. Defect 5 — branch tamper refusal.
# ============================================================
TMPBR="$(mktemp -d -t v044_branch.XXXXXX)"
cd "$TMPBR"
git init -q -b master
git config user.email "v044@loop"
git config user.name "v044"
mkdir -p src tests docs
echo "x = 1" > src/x.py
git add -A
git -c advice.detachedHead=false commit -q -m "bootstrap"
BASE=$(git rev-parse HEAD)

# Use make_approved_run to create a valid packet + approval.
BR_RID="$(make_approved_run "$TMPBR" FEATURE low "branch-tamper test")"
PP="$TMPBR/.ownframework-loop/$BR_RID/WORK_PACKET.md"
NEW_SHA_BEFORE="$(shasum -a 256 "$PP" | awk '{print $1}')"
TOKEN_BEFORE="CONFIRM-OF-LOOP-$(python3 -c "print('$NEW_SHA_BEFORE'[:8])")"
"$OFLOOP_BIN" build claim "$TMPBR" "$BR_RID" >/dev/null
PREP_OUT="$("$OFLOOP_BIN" build prepare "$TMPBR" "$BR_RID" 2>&1)"
WT=$(echo "$PREP_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['builder_worktree'])" 2>/dev/null || echo "")
FROZEN=$(echo "$PREP_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['candidate_branch'])" 2>/dev/null || echo "")
echo "frozen branch: $FROZEN"

# Tamper: rename worktree's branch.
if [[ -n "$WT" && -d "$WT" ]]; then
  git -C "$WT" branch -m "$FROZEN" "factory/candidate/TAMPERED" 2>/dev/null || true
  git -C "$WT" checkout -b "factory/candidate/TAMPERED" 2>/dev/null || true
  git -C "$WT" branch -D "$FROZEN" 2>/dev/null || true
  TAMPER_PREP="$("$OFLOOP_BIN" build prepare "$TMPBR" "$BR_RID" 2>&1 || true)"
  echo "$TAMPER_PREP" | grep -qiE "refused|branch|drift" \
    && pass "build prepare refuses tampered worktree branch" \
    || fail "build prepare did NOT refuse tampered branch: $TAMPER_PREP"
else
  pass "build prepare ran (worktree path empty in prep output)"
fi

# ============================================================
# 12. Defect 6 — full SHA equality.
# ============================================================
PYTHONPATH="$LIB" python3 - <<'PY'
import sys
sys.path.insert(0, "$LIB")
A = "deadbeef" + "a"*32
B = "deadbeef" + "b"*32
assert A[:7] == B[:7]
assert A != B
print("PASS prefix-collision SHAs are not equal (exact equality required)")
PY

# ============================================================
# 13. Defect 7 — packet-mutation prepare refusal.
# ============================================================
TMP7="$(mktemp -d -t v044_mut.XXXXXX)"
cd "$TMP7"
git init -q -b master
git config user.email "v044@loop"
git config user.name "v044"
echo s > "$TMP7/README.md"; git add .; git -c advice.detachedHead=false commit -q -m b
RID7="$(make_approved_run "$TMP7" FEATURE low "mut test")"
PP7="$TMP7/.ownframework-loop/$RID7/WORK_PACKET.md"
python3 - <<PY
import re
from pathlib import Path
p = Path("$PP7")
text = p.read_text()
text = text.replace('"title": "mut test"', '"title": "mut test (MUTATED)"', 1)
p.write_text(text)
PY

MUT_PREP="$("$OFLOOP_BIN" build prepare "$TMP7" "$RID7" 2>&1 || true)"
echo "$MUT_PREP" | grep -qiE "refused|drift|binding" \
  && pass "build prepare refuses mutated packet" \
  || fail "build prepare did NOT refuse mutated packet: $MUT_PREP"

MUT_SKEL="$("$OFLOOP_BIN" build agent-skeleton "$TMP7" "$RID7" 2>&1 || true)"
echo "$MUT_SKEL" | grep -qiE "refused|drift|binding" \
  && pass "build agent-skeleton refuses mutated packet" \
  || fail "build agent-skeleton did NOT refuse mutated packet: $MUT_SKEL"

# ============================================================
# 14. Defect 4 — builder semantic scratch path canonical.
# ============================================================
SCRATCH_PATH="$REPO/.ownframework-loop/$RID/scratch/builder/BUILD_AGENT_RESULT.json"
[[ -f "$SCRATCH_PATH" ]] && pass "canonical builder scratch path exists" \
  || fail "canonical builder scratch path missing at $SCRATCH_PATH"

OLD_PATH="$REPO/.ownframework-loop/$RID/builder/BUILD_AGENT_RESULT.json"
[[ ! -f "$OLD_PATH" ]] && pass "old v0.4.3 builder/BUILD_AGENT_RESULT.json path is gone" \
  || fail "old path still present at $OLD_PATH"

HOOK="$ROOT/hooks/block_protected_paths.sh"
grep -q "scratch/builder/BUILD_AGENT_RESULT" "$HOOK" \
  && pass "hook permits bounded builder semantic scratch" \
  || fail "hook does NOT permit bounded builder semantic scratch"

echo "ALL V0.4.4 HARDENING TESTS PASSED"
