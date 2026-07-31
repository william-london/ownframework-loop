#!/usr/bin/env bash
# Capability Matrix — 4 end-to-end missions on disposable repos.
#
# M1. ordinary bug fix
# M2. repository doctrine change (sensitive path)
# M3. web research task
# M4. malicious proof (a packet whose finalizer must refuse)

set -uo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

# Shared helper: finalize build, transition to REVIEWING, then run review.
# Args: repo rid
matrix_finalize() {
  local repo="$1" rid="$2"

  # Builder claim and finalize.
  "$OFLOOP_BIN" build claim "$repo" "$rid" >/dev/null 2>&1
  out="$("$OFLOOP_BIN" build finalize "$repo" "$rid" 2>&1)" || true
  if [[ ! -f "$repo/.ownframework-loop/$rid/BUILD_RECEIPT.json" ]]; then
    echo "build finalize failed: $out"
  fi

  # Claim the review pass: this is the single durable owner of
  # review_pass_count and moves the state to REVIEWING. The finalizer
  # refuses to stamp when the count is 0.
  "$OFLOOP_BIN" review claim "$repo" "$rid" >/dev/null 2>&1 || true

  # Get the candidate SHA from the receipt.
  local sha
  sha="$(python3 -c "import json; print(json.load(open('$repo/.ownframework-loop/$rid/BUILD_RECEIPT.json'))['candidate_sha'])")"

  # Reviewer assessment and finalize.
  local assess
  assess="$(mktemp)"
  cat > "$assess" <<JSON
{
  "schema": "ownframework-loop-review-agent-assessment/v1",
  "run_id": "$rid",
  "candidate_sha_claimed": "$sha",
  "acceptance_results": [{"id": "AC-1", "result": "pass"}],
  "non_goal_results": [],
  "findings": [],
  "recommended_verdict": "APPROVED"
}
JSON

  "$OFLOOP_BIN" review finalize "$repo" "$rid" "$assess" >/dev/null 2>&1

  # Read final state.
  python3 -c "import json; print(json.load(open('$repo/.ownframework-loop/$rid/STATE.json'))['state'])"
}

# ---------- M1. ordinary bug fix ----------
M1="$(make_tmp_repo)"
M1_RID="$(make_approved_run "$M1" BUG low "bug-fix-mission")"
echo "M1=$M1 M1_RID=$M1_RID"
echo "M1 master=$(git -C "$M1" rev-parse master)"
echo "M1 baseline=$(python3 -c "import json; print(json.load(open(\"$M1/.ownframework-loop/$M1_RID/APPROVAL.json\"))[\"baseline_sha\"])")"
# Add a real file change to the candidate on a NEW branch via worktree.
WT1="$M1/.worktrees/ownframework-loop/$M1_RID/builder"
git -C "$M1" worktree add -b "factory/candidate/$M1_RID" "$WT1" master >/dev/null 2>&1
mkdir -p "$WT1/src"
cat > "$WT1/src/bug.py" <<'PY'
def add(a, b):
    return a + b
PY
git -C "$WT1" add src/bug.py && git -C "$WT1" commit -m "fix: add" >/dev/null 2>&1
echo "M1 after commit master=$(git -C "$M1" rev-parse master) HEAD=$(git -C "$M1" rev-parse HEAD)"
out1="$(matrix_finalize "$M1" "$M1_RID")"
assert_eq "$out1" "APPROVED" "M1: ordinary bug fix reaches APPROVED"

# ---------- M2. repository doctrine change (sensitive path) ----------
M2="$(make_tmp_repo)"
M2_RID="$(make_approved_run "$M2" REFACTOR medium "doctrine-change")"
# Edit packet to declare elevated_allowed_paths.
M2_PP="$M2/.ownframework-loop/$M2_RID/WORK_PACKET.md"
python3 - "$M2_PP" <<'PY'
import sys, json, re
from pathlib import Path
pp = Path(sys.argv[1])
text = pp.read_text()
m = re.search(r"```json\n(.*?)\n```", text, re.DOTALL)
meta = json.loads(m.group(1))
meta["elevated_allowed_paths"] = ["AGENTS.md"]
meta["sensitive_paths"] = ["AGENTS.md"]
meta["sensitive_path_reason"] = "M2 doctrine change requires AGENTS.md update"
pp.write_text(re.sub(r"```json\n.*?\n```", "```json\n" + json.dumps(meta, indent=2) + "\n```", text, count=1, flags=re.DOTALL))
PY
# Re-approve after packet mutation.
python3 - "$M2" "$M2_RID" <<'PY'
import sys, json, subprocess
from pathlib import Path
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib'))
from ownframework_loop import approval
canonical_repo = Path(sys.argv[1])
run_id = sys.argv[2]
pp = canonical_repo / ".ownframework-loop" / run_id / "WORK_PACKET.md"
sha = __import__("hashlib").sha256(pp.read_bytes()).hexdigest()
baseline = subprocess.run(
    ["git", "-C", str(canonical_repo), "rev-parse", "master"],
    capture_output=True, text=True, check=True,
).stdout.strip()
doc = {
    "schema": "ownframework-loop-approval/v1",
    "run_id": run_id,
    "packet_sha256": sha,
    "approved_at": "2026-07-23T00:00:00Z",
    "approved_actor": "test",
    "canonical_repo": str(canonical_repo.resolve(strict=False)),
    "baseline_branch": "master",
    "baseline_sha": baseline,
    "packet_schema": "ownframework-work-packet/v2",
    "approval_method": "operator_marker",
    "confirmation_token": approval.derive_confirmation_token(sha),
}
Path(canonical_repo, ".ownframework-loop", run_id, "APPROVAL.json").write_text(
    json.dumps(doc, indent=2, sort_keys=True))
PY

# Now the candidate touches AGENTS.md.
WT2="$M2/.worktrees/ownframework-loop/$M2_RID/builder"
git -C "$M2" worktree add -b "factory/candidate/$M2_RID" "$WT2" master >/dev/null 2>&1
echo "# doctrine" > "$WT2/AGENTS.md"
git -C "$WT2" add AGENTS.md && git -C "$WT2" commit -m "doctrine" >/dev/null 2>&1
out2="$(matrix_finalize "$M2" "$M2_RID")"
assert_eq "$out2" "APPROVED" "M2: doctrine change (sensitive path) reaches APPROVED"

# ---------- M3. web research ----------
M3="$(make_tmp_repo)"
M3_RID="$(make_approved_run "$M3" RESEARCH_SPIKE low "web-research")"
# Extend the packet to allow docs/ since research produces notes outside src/.
python3 - "$M3/.ownframework-loop/$M3_RID/WORK_PACKET.md" <<'PY'
import sys, json, re
from pathlib import Path
pp = Path(sys.argv[1])
text = pp.read_text()
m = re.search(r"```json\n(.*?)\n```", text, re.DOTALL)
meta = json.loads(m.group(1))
meta["allowed_paths"] = sorted(set(meta["allowed_paths"]) | {"docs/"})
pp.write_text(re.sub(r"```json\n.*?\n```", "```json\n" + json.dumps(meta, indent=2, sort_keys=True) + "\n```", text, count=1, flags=re.DOTALL))
PY
# Re-approve after packet mutation (the SHA has drifted).
python3 - "$M3" "$M3_RID" <<'PY'
import sys, json, subprocess
from pathlib import Path
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib'))
from ownframework_loop import approval, state as state_mod
canonical_repo = Path(sys.argv[1])
run_id = sys.argv[2]
pp = canonical_repo / ".ownframework-loop" / run_id / "WORK_PACKET.md"
sha = __import__("hashlib").sha256(pp.read_bytes()).hexdigest()
baseline = subprocess.run(
    ["git", "-C", str(canonical_repo), "rev-parse", "master"],
    capture_output=True, text=True, check=True,
).stdout.strip()
doc = {
    "schema": "ownframework-loop-approval/v1",
    "run_id": run_id,
    "packet_sha256": sha,
    "approved_at": "2026-07-23T00:00:00Z",
    "approved_actor": "test",
    "canonical_repo": str(canonical_repo.resolve(strict=False)),
    "baseline_branch": "master",
    "baseline_sha": baseline,
    "packet_schema": "ownframework-work-packet/v2",
    "approval_method": "operator_marker",
    "confirmation_token": approval.derive_confirmation_token(sha),
}
Path(canonical_repo, ".ownframework-loop", run_id, "APPROVAL.json").write_text(
    json.dumps(doc, indent=2, sort_keys=True))
# Don't transition state — just refresh approval; state stays READY_TO_BUILD.
cur = state_mod.load(canonical_repo, run_id)
print("post-mutation approval state:", cur.get("state"))
PY
WT3="$M3/.worktrees/ownframework-loop/$M3_RID/builder"
git -C "$M3" worktree add -b "factory/candidate/$M3_RID" "$WT3" master >/dev/null 2>&1
mkdir -p "$WT3/docs"
cat > "$WT3/docs/research.md" <<'MD'
# Web research notes
- See: https://example.com
MD
git -C "$WT3" add docs/research.md && git -C "$WT3" commit -m "research" >/dev/null 2>&1
out3="$(matrix_finalize "$M3" "$M3_RID")"
assert_eq "$out3" "APPROVED" "M3: web research mission reaches APPROVED"

# ---------- M4. malicious proof (hard secret in candidate) ----------
M4="$(make_tmp_repo)"
M4_RID="$(make_approved_run "$M4" BUG low "malicious-proof")"
WT4="$M4/.worktrees/ownframework-loop/$M4_RID/builder"
git -C "$M4" worktree add -b "factory/candidate/$M4_RID" "$WT4" master >/dev/null 2>&1
mkdir -p "$WT4/src"
echo 'AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE' > "$WT4/src/leak.py"
git -C "$WT4" add src/leak.py && git -C "$WT4" commit -m "leak" >/dev/null 2>&1
"$OFLOOP_BIN" build claim "$M4" "$M4_RID" >/dev/null 2>&1
# Hard-secret pre-receipt refusal: capture stderr and verify refusal marker.
m4_out="$("$OFLOOP_BIN" build finalize "$M4" "$M4_RID" 2>&1 || true)"
echo "$m4_out" | grep -q "OF_LOOP_BUILD_FINALIZE_REFUSED" \
  && pass "M4: malicious proof (hard secret) refused by build finalizer" \
  || fail "M4: build finalizer did NOT refuse hard secret: $m4_out"
echo "$m4_out" | grep -q "AKIAIOSFODNN7EXAMPLE" \
  && fail "M4: literal secret leaked into finalizer output" \
  || pass "M4: literal secret redacted from finalizer output"
# Also verify literal secret not in any artifact under the run directory.
if grep -rqF "AKIAIOSFODNN7EXAMPLE" "$M4/.ownframework-loop/$M4_RID" 2>/dev/null; then
  fail "M4: literal secret leaked into run artifacts"
else
  pass "M4: literal secret did not leak into run artifacts"
fi
# Build finalize refused ⇒ no BUILD_RECEIPT.json was written.
[[ ! -f "$M4/.ownframework-loop/$M4_RID/BUILD_RECEIPT.json" ]] \
  && pass "M4: BUILD_RECEIPT.json not written on hard-secret refusal" \
  || fail "M4: BUILD_RECEIPT.json was written on hard-secret refusal"

echo "CAPABILITY_MATRIX=PASS"
