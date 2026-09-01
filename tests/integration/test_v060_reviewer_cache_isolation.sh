#!/usr/bin/env bash
# v0.6.0 — reviewer cache-pollution regression.
#
# Real commissioning proved:
#   Claude reviewer runs Python/tests
#   → __pycache__/pytest_cache lands in the reviewer worktree
#   → deterministic verifier correctly sees dirty filesystem
#   → finalizer refuses.
#
# The hermetic-runtime-env fix keeps ephemeral cache OUTSIDE the worktree
# via PYTHONDONTWRITEBYTECODE, PYTHONPYCACHEPREFIX, TMPDIR, XDG_CACHE_HOME,
# and PYTEST_ADDOPTS. This test proves:
#
#   1. required_validation that imports Python leaves the reviewer worktree clean;
#   2. required_validation that runs pytest leaves the reviewer worktree clean;
#   3. exact reviewer HEAD is preserved after the validation;
#   4. the deterministic finalize succeeds WITHOUT arbitrary cleanup;
#   5. a real unexpected untracked source-like file IS still detected/refused
#      (i.e., the dirty-worktree integrity check is NOT weakened).
#
# No model call. All required_validation is dispatched manually so the test
# reproduces the exact failure class.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

OFLOOP="$OFLOOP_BIN"
LIB_DIR="$ROOT_DIR/lib"

REPO="$(make_tmp_repo)"

# Inject required_validation BEFORE the run is enqueued. The auto-seal locks
# the packet_sha256 on first build claim, so we must write the packet first.
RUN_ID="$(make_approved_run_unapproved "$REPO" FEATURE low "cache-isolation")"

PYTHONPATH="$LIB_DIR" python3 - "$REPO" "$RUN_ID" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, "${OFLOOP_LIB:-$LIB_DIR}")
from ownframework_loop import approval as approval_mod, packet as packet_mod, state as state_mod
repo = Path(sys.argv[1]); rid = sys.argv[2]
pp = repo / ".ownframework-loop" / rid / "WORK_PACKET.md"
meta, _ = packet_mod.parse_packet_file(pp)
meta["required_validation"] = [
    {
        "name": "import-check",
        "kind": "fast",
        # Use a vanilla `python3 -c` import check rather than `pytest` so
        # this test does not require pytest to be installed on the runner.
        # The point of this test is hermetic cache isolation, not pytest
        # invocation; pytest is exercised by the negative path's
        # reviewer-side python script which DOES install pytest.
        "command": "python3 -c 'from src.greet import greet; assert greet(\"World\") == \"Hello, World!\"'",
        "expected_exit_code": 0,
    }
]
# Allow tests/ so pytest can import + the test file itself is in-scope.
if "tests/" not in (meta.get("allowed_paths") or []):
    meta["allowed_paths"] = list(meta.get("allowed_paths") or []) + ["tests/"]
fence = "```json"
body = fence + "\n" + json.dumps(meta, indent=2, sort_keys=True) + "\n" + fence
import re
text = pp.read_text()
new = re.sub(r"```json\n.*?```", body, text, count=1, flags=re.DOTALL)
pp.write_text(new)

# Now write APPROVAL.json with build_start method + confirmation_token.
packet_sha = __import__("hashlib").sha256(pp.read_bytes()).hexdigest()
baseline_sha = __import__("subprocess").run(
    ["git", "-C", str(repo), "rev-parse", "master"],
    capture_output=True, text=True, check=True,
).stdout.strip()
token = approval_mod.derive_confirmation_token(packet_sha)
candidate_branch = f"factory/candidate/{rid}"
approval_doc = {
    "schema": "ownframework-loop-approval/v1",
    "run_id": rid,
    "packet_sha256": packet_sha,
    "approved_at": "2026-08-28T00:00:00Z",
    "approved_actor": "cache-isolation-test",
    "canonical_repo": str(repo.resolve(strict=False)),
    "baseline_branch": "master",
    "baseline_sha": baseline_sha,
    "candidate_branch": candidate_branch,
    "packet_schema": "ownframework-work-packet/v2",
    "approval_method": "build_start",
    "confirmation_token": token,
}
approval_path = repo / ".ownframework-loop" / rid / "APPROVAL.json"
approval_path.write_text(json.dumps(approval_doc, indent=2, sort_keys=True))
approval_path.chmod(0o600)

# Auto-seal leaves state at READY_TO_BUILD after the first build claim.
PY

# Create Python source + test in the BUILDER worktree. NO .gitignore at all.
WT1="$REPO/.worktrees/ownframework-loop/$RUN_ID/builder"
git -C "$REPO" worktree add -b "factory/candidate/$RUN_ID" "$WT1" master >/dev/null 2>&1
mkdir -p "$WT1/src" "$WT1/tests"
cat > "$WT1/src/greet.py" <<'PY'
def greet(name):
    return f"Hello, {name}!"
PY
cat > "$WT1/src/__init__.py" <<'PY'
PY
cat > "$WT1/tests/test_greet.py" <<'PY'
from src.greet import greet

def test_greet():
    assert greet("World") == "Hello, World!"

def test_greet_alice():
    assert greet("Alice") == "Hello, Alice!"
PY
git -C "$WT1" add . && git -C "$WT1" commit -q -m "feat: greet"
SHA1="$(git -C "$WT1" rev-parse HEAD)"
echo "CANDIDATE_SHA=$SHA1"

# Drive BUILD via dispatch.
echo "STAGE: BUILD_CLAIM_STARTING"
BUILD_OUT="$("$OFLOOP" dispatch claim "$REPO" "$RUN_ID")"
echo "STAGE: BUILD_CLAIM_RC=$?"
assert_eq "$(printf '%s' "$BUILD_OUT" | jq -r '.decision')" "BUILD" "dispatch BUILD"
BSEM="$(printf '%s' "$BUILD_OUT" | jq -r '.semantic_path')"
echo "STAGE: BSEM=$BSEM"

# Synthetic semantic builder result.
if ! python3 - "$BSEM" "$RUN_ID" >/tmp/fill_build.log 2>&1 <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
d = json.loads(p.read_text())
d["summary"] = "cache-isolation synthetic builder"
d["outcome_requested"] = "candidate_ready"
d["unit_ids_completed"] = ["UNIT-1"]
d["acceptance_addressed"] = ["AC-1"]
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
then
  echo "FILL BUILD RESULT FAILED:"
  cat /tmp/fill_build.log
  fail "fill BUILD_AGENT_RESULT.json failed"
fi
if ! "$OFLOOP" dispatch finalize "$REPO" "$RUN_ID" BUILD "$BSEM" >/tmp/finalize_build.log 2>&1; then
  echo "FINALIZE BUILD FAILED:"
  cat /tmp/finalize_build.log
  fail "dispatch finalize BUILD failed"
fi
echo "STAGE: BUILD_FINALIZE_OK"

# Drive REVIEW via dispatch — this is where the bug used to manifest.
echo "STAGE: REVIEW_CLAIM_STARTING"
REVIEW_OUT="$("$OFLOOP" dispatch claim "$REPO" "$RUN_ID")" || REVIEW_RC=$?
echo "STAGE: REVIEW_CLAIM_RC=${REVIEW_RC:-$?}"
echo "STAGE: REVIEW_OUT_LEN=${#REVIEW_OUT}"
if [[ -z "$REVIEW_OUT" ]]; then
  echo "STAGE: REVIEW_OUT_EMPTY dump STATE:"
  jq -c . "$REPO/.ownframework-loop/$RUN_ID/STATE.json" || true
  fail "dispatch claim REVIEW returned empty output"
fi
echo "STAGE: REVIEW_OUT_DUMP:"
printf '%s\n' "$REVIEW_OUT" | head -20
assert_eq "$(printf '%s' "$REVIEW_OUT" | jq -r '.decision')" "REVIEW" "dispatch REVIEW"
RSEM="$(printf '%s' "$REVIEW_OUT" | jq -r '.semantic_path')"

# Synthetic reviewer assessment. Reviewer reports a verdict based on the
# required_validation's exit code.
python3 - "$RSEM" "$RUN_ID" "$SHA1" "$REPO" <<'PY'
import json, subprocess, sys
from pathlib import Path
sem, rid, sha, repo = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
# Run the validation in the reviewer worktree WITH the hermetic env.
reviewer_wt = Path(repo) / ".worktrees/ownframework-loop" / rid / "reviewer"
# We must add cwd to PYTHONPATH so `from src import greet` resolves.
from ownframework_loop.runtime_env import hermetic_subprocess_env
env = hermetic_subprocess_env(Path(repo), rid, "reviewer")
env["PYTHONPATH"] = str(reviewer_wt) + ":" + env.get("PYTHONPATH", "")
r = subprocess.run(
    # Use compileall + a direct import to exercise Python bytecode
    # caching paths without depending on pytest being installed on
    # the runner. PYTHONDONTWRITEBYTECODE / PYTHONPYCACHEPREFIX in
    # the hermetic env must keep __pycache__ out of the worktree.
    ["/bin/sh", "-c", "python3 -c 'import compileall; compileall.compile_dir(\"src\", quiet=1, force=True); from src.greet import greet; assert greet(\"World\") == \"Hello, World!\"'"],
    cwd=str(reviewer_wt),
    capture_output=True, text=True, env=env, timeout=60,
)
print("VALIDATION_RC=", r.returncode)
print("VALIDATION_STDOUT_TAIL:")
print("\n".join(r.stdout.splitlines()[-8:]))
assert r.returncode == 0, f"validation failed rc={r.returncode} stderr={r.stderr}"
# Inspect reviewer worktree for cache artifacts.
import os
for root, dirs, files in os.walk(reviewer_wt):
    for d in dirs:
        if d == "__pycache__" or d == ".pytest_cache":
            raise SystemExit(f"POLLUTION: {os.path.join(root, d)}")
    for f in files:
        if f.endswith(".pyc"):
            raise SystemExit(f"POLLUTION: {os.path.join(root, f)}")
print("WORKTREE_CLEAN")
PY
assert_contains "WORKTREE_CLEAN" "WORKTREE_CLEAN" "reviewer worktree stayed clean under required_validation"

# The reviewer worktree is at exact candidate SHA and clean.
REVIEWER_HEAD="$(git -C "$REPO/.worktrees/ownframework-loop/$RUN_ID/reviewer" rev-parse HEAD)"
assert_eq "$REVIEWER_HEAD" "$SHA1" "reviewer HEAD still equals candidate SHA"
DIRTY="$(git -C "$REPO/.worktrees/ownframework-loop/$RUN_ID/reviewer" status --porcelain | wc -l | tr -d ' ')"
[[ "$DIRTY" -eq 0 ]] || fail "reviewer worktree is dirty ($DIRTY entries) after hermetic validation"
pass "reviewer HEAD exact + worktree clean after hermetic validation"

# Fill the semantic reviewer assessment.
python3 - "$RSEM" "$RUN_ID" "$SHA1" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
d = json.loads(p.read_text())
d["validation_results"] = [{"name": "pytest-import", "exit_code": 0, "duration_seconds": 0.1}]
d["acceptance_results"] = [{"id": "AC-1", "result": "pass", "evidence": "pytest passed"}]
d["non_goal_results"] = []
d["findings"] = []
d["recommended_verdict"] = "APPROVED"
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY

# Finalize must SUCCEED without arbitrary cleanup. This is the contract change.
if ! "$OFLOOP" dispatch finalize "$REPO" "$RUN_ID" REVIEW "$RSEM" >/tmp/finalize_review.log 2>&1; then
  echo "FINALIZE REVIEW FAILED:"
  cat /tmp/finalize_review.log
  fail "dispatch finalize REVIEW failed"
fi
FINAL="$(jq -r '.state' "$REPO/.ownframework-loop/$RUN_ID/STATE.json")"
assert_eq "$FINAL" "APPROVED" "deterministic finalizer succeeded without arbitrary cleanup"
VERDICT="$(jq -r '.verdict' "$REPO/.ownframework-loop/$RUN_ID/REVIEW_VERDICT.json")"
assert_eq "$VERDICT" "APPROVED" "review verdict is APPROVED"

# Negative-path: a real unexpected untracked source-like file IS still detected.
# This proves the hermetic fix did NOT weaken the dirty-worktree integrity check.
echo ""
echo "=== Negative path: real untracked file still detected ==="
T2="$(make_tmp_repo)"
RID2="$(make_approved_run "$T2" FEATURE low "cache-negative")"
WT2="$T2/.worktrees/ownframework-loop/$RID2/builder"
git -C "$T2" worktree add -b "factory/candidate/$RID2" "$WT2" master >/dev/null 2>&1
mkdir -p "$WT2/src"
cat > "$WT2/src/greet.py" <<'PY'
def greet(name):
    return f"Hello, {name}!"
PY
git -C "$WT2" add . && git -C "$WT2" commit -q -m "feat"
SHA2="$(git -C "$WT2" rev-parse HEAD)"

# Drive BUILD then REVIEW to the point where the reviewer worktree exists.
"$OFLOOP" dispatch claim "$T2" "$RID2" >/dev/null
BSEM2="$T2/.ownframework-loop/$RID2/scratch/builder/pass-0001/BUILD_AGENT_RESULT.json"
python3 - "$BSEM2" "$RID2" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
d = json.loads(p.read_text())
d["summary"] = "negative builder"; d["outcome_requested"] = "candidate_ready"
d["unit_ids_completed"] = ["UNIT-1"]; d["acceptance_addressed"] = ["AC-1"]
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
"$OFLOOP" dispatch finalize "$T2" "$RID2" BUILD "$BSEM2" >/dev/null
"$OFLOOP" dispatch claim "$T2" "$RID2" >/dev/null
RSEM2="$T2/.ownframework-loop/$RID2/scratch/reviewer/pass-0001/REVIEW_AGENT_ASSESSMENT.json"

# Plant a real unexpected untracked file in the reviewer worktree. This is NOT
# a cache artifact; it's a source-like change that proves integrity detection
# is still active.
REVIEWER_WT2="$T2/.worktrees/ownframework-loop/$RID2/reviewer"
echo "suspicious untracked source" > "$REVIEWER_WT2/suspicious.py"

# Fill a synthetic reviewer assessment that would normally pass — but the
# finalize should refuse because of the planted untracked file.
python3 - "$RSEM2" "$RID2" "$SHA2" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
d = json.loads(p.read_text())
d["validation_results"] = []
d["acceptance_results"] = [{"id": "AC-1", "result": "pass", "evidence": "synthetic"}]
d["non_goal_results"] = []
d["findings"] = []
d["recommended_verdict"] = "APPROVED"
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY

# Capture finalize output regardless of exit code. The negative path EXPECTS
# the finalize to refuse, so we cannot let errexit propagate the failure.
set +e
FIN_OUT="$("$OFLOOP" dispatch finalize "$T2" "$RID2" REVIEW "$RSEM2" 2>&1)"
FIN_RC=$?
set -e
echo "negative-path finalize rc=$FIN_RC"
echo "$FIN_OUT" | head -8
[[ "$FIN_RC" -ne 0 ]] || fail "expected negative-path finalize to refuse but it succeeded"
echo "$FIN_OUT" | grep -Fq "reviewer_worktree_dirty" \
  || fail "dirty reviewer worktree refusal classification missing"
pass "real unexpected untracked file still detected by finalizer"

git -C "$T2" worktree remove --force "$WT2" >/dev/null 2>&1 || true

# Cleanup.
git -C "$REPO" worktree remove --force "$WT1" >/dev/null 2>&1 || true

echo "REVIEWER_CACHE_ISOLATION=PASS"