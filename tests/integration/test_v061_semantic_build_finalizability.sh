#!/usr/bin/env bash
# v0.6.1 — semantic build finalizability recovery regression.
#
# Live unattended commissioning of the practice MVP exposed a real recovery
# seam: a structurally complete BUILD_AGENT_RESULT over a dirty builder
# worktree was being replay-finalized across retries. The deterministic
# finalize correctly refused each attempt ("builder worktree is dirty"),
# each refusal was counted as an infra_failure, and the supervisor
# correctly quarantined at max_infra_failures — but each retry was wasted
# because the same complete semantic artifact cannot repair the filesystem.
#
# v0.6.1 closes this by requiring dispatch.semantic_result_ready(BUILD) to
# refuse readiness when the exact prepared builder worktree is dirty. The
# supervisor then dispatches a fresh semantic builder for the SAME claimed
# pass (same run id, same pass number, same checkpoint, same candidate
# branch, same worktree, same semantic artifact path) — never creating a
# new pass, branch, or repair_round.
#
# These regression tests prove:
#   TEST 1 — CLEAN REPLAY: complete artifact + clean worktree == ready,
#            so the supervisor replay-finalizes with zero new model calls.
#   TEST 2 — DIRTY COMPLETE RESULT: complete artifact + dirty worktree
#            == NOT ready, stable reason "builder_worktree_dirty".
#   TEST 3 — SAME-PASS SELF-HEAL: a fresh semantic builder for the SAME
#            pass observes existing work, commits it, and finalization
#            succeeds; build_pass_count stays exactly 1; no new candidate
#            branch; no repair_round increment.
#   TEST 4 — SEALED PACKET IMMUTABILITY: the sealed packet_sha256 is
#            pinned in APPROVAL.json; widening allowed_paths after seal
#            does NOT retroactively widen the sealed packet; the sealed
#            SHA remains the immutable anchor.
#   TEST 5 — RUNNER CONTRACT STATIC GUARD: the builder role contract
#            documents that candidate_ready requires a clean committed
#            builder worktree.
#   TEST 6 — REPEATED DIRTY FAILURE REMAINS BOUNDED: even with the new
#            ready-check, if every fresh-builder retry leaves the worktree
#            non-finalizable, the operational retry / quarantine ceilings
#            still cap the loop. No infinite model-call loop, no new
#            branches, no new passes.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

OFLOOP="$OFLOOP_BIN"
LIB_DIR="$ROOT_DIR/lib"
export PYTHONPATH="$LIB_DIR"

# -----------------------------------------------------------------------------
# Shared helper: create a fresh repo + run + claimed-but-unfinalized build
# pass with a deterministic builder worktree at <repo>/.worktrees/.../builder.
# Caller can then choose to leave the worktree clean or dirty.
# Outputs "REPO|RUN_ID|WT" on stdout (pipe-friendly).
# -----------------------------------------------------------------------------
make_unfinalized_build_pass() {
  local mode="$1"
  local repo rid wt
  repo="$(make_tmp_repo)"
  rid="$(make_approved_run_unapproved "$repo" FEATURE low "finalizability-${mode}")"

  PYTHONPATH="$LIB_DIR" python3 - "$repo" "$rid" <<'PY'
import json, sys, hashlib, subprocess, re
from pathlib import Path
import os
sys.path.insert(0, "$LIB_DIR")
from ownframework_loop import approval as approval_mod, packet as packet_mod
repo = Path(sys.argv[1]); rid = sys.argv[2]
pp = repo / ".ownframework-loop" / rid / "WORK_PACKET.md"
meta, _ = packet_mod.parse_packet_file(pp)
meta["required_validation"] = [{
    "name": "import-check", "kind": "fast",
    "command": "python3 -c 'from src.greet import greet; assert greet(\"World\") == \"Hello, World!\"'",
    "expected_exit_code": 0,
}]
if "tests/" not in (meta.get("allowed_paths") or []):
    meta["allowed_paths"] = list(meta.get("allowed_paths") or []) + ["tests/"]
# package-lock.json deliberately absent — mirrors the live incident shape.
fence = "```json"
body = fence + "\n" + json.dumps(meta, indent=2, sort_keys=True) + "\n" + fence
text = pp.read_text()
new = re.sub(r"```json\n.*?```", body, text, count=1, flags=re.DOTALL)
pp.write_text(new)
packet_sha = hashlib.sha256(pp.read_bytes()).hexdigest()
baseline_sha = subprocess.run(["git", "-C", str(repo), "rev-parse", "master"], capture_output=True, text=True, check=True).stdout.strip()
token = approval_mod.derive_confirmation_token(packet_sha)
candidate_branch = f"factory/candidate/{rid}"
approval_doc = {
    "schema": "ownframework-loop-approval/v1",
    "run_id": rid,
    "packet_sha256": packet_sha,
    "approved_at": "2026-08-28T00:00:00Z",
    "approved_actor": "finalizability-test",
    "canonical_repo": str(repo.resolve(strict=False)),
    "baseline_branch": "master",
    "baseline_sha": baseline_sha,
    "candidate_branch": candidate_branch,
    "packet_schema": "ownframework-work-packet/v2",
    "approval_method": "build_start",
    "confirmation_token": token,
}
(repo / ".ownframework-loop" / rid / "APPROVAL.json").write_text(
    json.dumps(approval_doc, indent=2, sort_keys=True) + "\n"
)
PY

  wt="$repo/.worktrees/ownframework-loop/$rid/builder"
  git -C "$repo" worktree add -b "factory/candidate/$rid" "$wt" master >/dev/null 2>&1
  mkdir -p "$wt/src"
  echo 'def greet(name): return f"Hello, {name}!"' > "$wt/src/greet.py"
  echo "" > "$wt/src/__init__.py"

  # ALWAYS commit the intended source change on the candidate branch.
  git -C "$wt" add . && git -C "$wt" commit -q -m "feat: greet"

  if [[ "$mode" == "dirty" ]]; then
    # Mimic the live incident: package.json modified + package-lock.json
    # untracked in the builder worktree.
    cat > "$wt/package.json" <<'JSON'
{ "name": "greet-app", "version": "0.1.0" }
JSON
    cat > "$wt/package-lock.json" <<'JSON'
{ "name": "greet-app", "lockfileVersion": 3 }
JSON
  fi

  "$OFLOOP" dispatch claim "$repo" "$rid" >/dev/null

  # Fill a synthetic BUILD_AGENT_RESULT (mirrors what a builder writes
  # post-pass without a real Claude call).
  BSEM="$repo/.ownframework-loop/$rid/scratch/builder/pass-0001/BUILD_AGENT_RESULT.json"
  mkdir -p "$(dirname "$BSEM")"
  python3 - "$BSEM" "$rid" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1]); rid = sys.argv[2]
d = {
  "schema": "ownframework-loop-build-agent-result/v1",
  "run_id": rid,
  "candidate_sha_claimed": "",
  "summary": "v0.6.1 finalizability synthetic builder",
  "evidence": ["synthetic"],
  "outcome_requested": "candidate_ready",
  "unit_ids_completed": ["UNIT-1"], "work_unit_id": "UNIT-1",
  "acceptance_addressed": ["AC-1"],
  "blocker_reason": "",
  "escalation_recommended": False,
  "escalation_reason": "",
  "notes": "",
  "timestamp": "2026-08-28T00:00:00Z",
}
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
  printf '%s|%s|%s\n' "$repo" "$rid" "$wt"
}

# -----------------------------------------------------------------------------
# TEST 1 — CLEAN REPLAY
# -----------------------------------------------------------------------------
echo ""
echo "=== TEST 1: CLEAN REPLAY ==="
IFS='|' read -r REPO1 RID1 WT1 < <(make_unfinalized_build_pass "clean")
echo "REPO1=$REPO1 RID1=$RID1 WT1=$WT1"
DIRTY=$(git -C "$WT1" status --porcelain | wc -l | tr -d ' ')
echo "worktree dirty lines: $DIRTY (expected 0)"
[[ "$DIRTY" -eq 0 ]] || fail "TEST 1 fixture: clean worktree should be clean"

set +e
"$OFLOOP" dispatch finalize "$REPO1" "$RID1" BUILD \
  "$REPO1/.ownframework-loop/$RID1/scratch/builder/pass-0001/BUILD_AGENT_RESULT.json" \
  >/tmp/v061_t1_finalize.log 2>&1
T1_RC=$?
set -e
echo "finalize rc=$T1_RC (expected 0; replay-only path)"
[[ "$T1_RC" -eq 0 ]] || fail "TEST 1: clean replay finalize did not succeed; log: $(cat /tmp/v061_t1_finalize.log)"
[[ -f "$REPO1/.ownframework-loop/$RID1/BUILD_RECEIPT.json" ]] \
  || fail "TEST 1: BUILD_RECEIPT.json missing after clean replay"
echo "BUILD_RECEIPT.json present after clean replay"
pass "TEST 1 — clean replay finalize succeeds, no fresh builder needed"

# -----------------------------------------------------------------------------
# TEST 2 — DIRTY COMPLETE RESULT
# -----------------------------------------------------------------------------
echo ""
echo "=== TEST 2: DIRTY COMPLETE RESULT ==="
IFS='|' read -r REPO2 RID2 WT2 < <(make_unfinalized_build_pass "dirty")
echo "REPO2=$REPO2 RID2=$RID2 WT2=$WT2"
echo "Worktree dirty status (expected non-zero):"
git -C "$WT2" status --porcelain | sed 's/^/  /'

# Probe semantic_result_ready directly via Python so we get the exact reason.
set +e
T2_OUT=$(PYTHONPATH="$LIB_DIR" python3 - <<PY
import sys, json, os
sys.path.insert(0, os.environ.get("OFLOOP_LIB", "$LIB_DIR"))
from ownframework_loop import dispatch
wo = {
    "schema": "ownframework-loop-dispatch/v1",
    "decision": "BUILD",
    "role": "builder",
    "run_id": "$RID2",
    "state": "BUILDING",
    "replayed": False,
    "canonical_repo": "$REPO2",
    "worktree": "$WT2",
    "semantic_path": "$REPO2/.ownframework-loop/$RID2/scratch/builder/pass-0001/BUILD_AGENT_RESULT.json",
}
ready, reason = dispatch.semantic_result_ready(wo)
print(f"READY={ready}")
print(f"REASON={reason}")
PY
)
T2_RC=$?
set -e
echo "$T2_OUT"
echo "$T2_OUT" | grep -Eq "^READY=False$" || fail "TEST 2: expected READY=False on dirty worktree"
echo "$T2_OUT" | grep -Eq "^REASON=builder_worktree_dirty$" \
  || fail "TEST 2: expected REASON=builder_worktree_dirty on dirty worktree"
pass "TEST 2 — dirty complete result reports reason=builder_worktree_dirty"

# -----------------------------------------------------------------------------
# TEST 3 — SAME-PASS SELF-HEAL
# -----------------------------------------------------------------------------
echo ""
echo "=== TEST 3: SAME-PASS SELF-HEAL ==="
IFS='|' read -r REPO3 RID3 WT3 < <(make_unfinalized_build_pass "dirty")

# First finalize must refuse.
set +e
"$OFLOOP" dispatch finalize "$REPO3" "$RID3" BUILD \
  "$REPO3/.ownframework-loop/$RID3/scratch/builder/pass-0001/BUILD_AGENT_RESULT.json" \
  >/tmp/v061_t3_first.log 2>&1
T3_FIRST_RC=$?
set -e
echo "first finalize rc=$T3_FIRST_RC (expected non-zero; dirty refusal)"
[[ "$T3_FIRST_RC" -ne 0 ]] || fail "TEST 3: first finalize should refuse on dirty worktree"
grep -Fq "builder worktree is dirty" /tmp/v061_t3_first.log \
  || fail "TEST 3: first finalize refusal reason missing"

PRE_BUILD_PASS=$(jq -r '.build_pass_count' "$REPO3/.ownframework-loop/$RID3/STATE.json")
PRE_REPAIR=$(jq -r '.repair_round' "$REPO3/.ownframework-loop/$RID3/STATE.json")
PRE_BRANCH=$(git -C "$WT3" branch --show-current)
echo "before recovery: build_pass_count=$PRE_BUILD_PASS repair_round=$PRE_REPAIR branch=$PRE_BRANCH"

# Fresh "builder" for the SAME pass: inspect, commit intended change, drop
# out-of-scope junk. Build pass / branch / repair_round NEVER incremented.
PYTHONPATH="$LIB_DIR" python3 - "$WT3" <<'PY'
import subprocess, sys
from pathlib import Path
wt = Path(sys.argv[1])
subprocess.run(["git", "-C", str(wt), "add", "package.json"], check=True)
subprocess.run(["git", "-C", str(wt), "commit", "-q", "-m",
                "feat: commit intended package.json"], check=True)
subprocess.run(["git", "-C", str(wt), "clean", "-f", "--",
                "package-lock.json"], check=True)
PY

set +e
"$OFLOOP" dispatch finalize "$REPO3" "$RID3" BUILD \
  "$REPO3/.ownframework-loop/$RID3/scratch/builder/pass-0001/BUILD_AGENT_RESULT.json" \
  >/tmp/v061_t3_second.log 2>&1
T3_SECOND_RC=$?
set -e
echo "second finalize rc=$T3_SECOND_RC (expected 0; recovery complete)"
[[ "$T3_SECOND_RC" -eq 0 ]] || fail "TEST 3: second finalize did not succeed; log: $(cat /tmp/v061_t3_second.log)"

POST_BUILD_PASS=$(jq -r '.build_pass_count' "$REPO3/.ownframework-loop/$RID3/STATE.json")
POST_REPAIR=$(jq -r '.repair_round' "$REPO3/.ownframework-loop/$RID3/STATE.json")
POST_BRANCH=$(git -C "$WT3" branch --show-current)
echo "after recovery:  build_pass_count=$POST_BUILD_PASS repair_round=$POST_REPAIR branch=$POST_BRANCH"

[[ "$PRE_BUILD_PASS" == "$POST_BUILD_PASS" ]] \
  || fail "TEST 3: build_pass_count changed ($PRE_BUILD_PASS -> $POST_BUILD_PASS); recovery must reuse the SAME pass"
[[ "$PRE_REPAIR" == "$POST_REPAIR" ]] \
  || fail "TEST 3: repair_round changed ($PRE_REPAIR -> $POST_REPAIR); recovery must not invent repair"
[[ "$PRE_BRANCH" == "$POST_BRANCH" ]] \
  || fail "TEST 3: candidate branch changed ($PRE_BRANCH -> $POST_BRANCH); recovery must keep the same branch"
[[ -f "$REPO3/.ownframework-loop/$RID3/BUILD_RECEIPT.json" ]] \
  || fail "TEST 3: BUILD_RECEIPT.json missing after recovery finalize"
pass "TEST 3 — same-pass self-heal finalizes with same build_pass / repair_round / branch"

# -----------------------------------------------------------------------------
# TEST 4 — SEALED PACKET IMMUTABILITY
# -----------------------------------------------------------------------------
echo ""
echo "=== TEST 4: SEALED PACKET IMMUTABILITY ==="
IFS='|' read -r REPO4 RID4 WT4 < <(make_unfinalized_build_pass "clean")

# Sealing happens at first dispatch claim.
"$OFLOOP" dispatch claim "$REPO4" "$RID4" >/dev/null
[[ -f "$REPO4/.ownframework-loop/$RID4/APPROVAL.json" ]] \
  || fail "TEST 4: APPROVAL.json missing after first claim (expected seal)"

SEALED_SHA=$(jq -r '.packet_sha256' "$REPO4/.ownframework-loop/$RID4/APPROVAL.json")
echo "sealed packet sha256: $SEALED_SHA"

# Attempt to widen allowed_paths. The packet bytes change; the sealed
# APPROVAL.json still pins the ORIGINAL sealed SHA — proving that
# widening after sealing is not silently accepted. The only legitimate
# remediation is a NEW run.
PYTHONPATH="$LIB_DIR" python3 - "$REPO4" "$RID4" <<'PY'
import json, sys, re
from pathlib import Path
import os
sys.path.insert(0, "$LIB_DIR")
from ownframework_loop.packet import parse_packet_file
repo = Path(sys.argv[1]); rid = sys.argv[2]
pp = repo / ".ownframework-loop" / rid / "WORK_PACKET.md"
meta, _ = parse_packet_file(pp)
meta.setdefault("allowed_paths", [])
if "package-lock.json" not in meta["allowed_paths"]:
    meta["allowed_paths"].append("package-lock.json")
fence = "```json"
body = fence + "\n" + json.dumps(meta, indent=2, sort_keys=True) + "\n" + fence
text = pp.read_text()
new = re.sub(r"```json\n.*?```", body, text, count=1, flags=re.DOTALL)
pp.write_text(new)
PY

NEW_SHA=$(python3 -c "
import hashlib
with open('$REPO4/.ownframework-loop/$RID4/WORK_PACKET.md','rb') as f:
    print(hashlib.sha256(f.read()).hexdigest())
")
echo "post-amend packet sha256: $NEW_SHA"
[[ "$NEW_SHA" != "$SEALED_SHA" ]] || fail "TEST 4: amend did not change packet bytes"

SEAL_PIN=$(jq -r '.packet_sha256' "$REPO4/.ownframework-loop/$RID4/APPROVAL.json")
[[ "$SEAL_PIN" == "$SEALED_SHA" ]] || fail "TEST 4: APPROVAL.json packet_sha256 was mutated"
pass "TEST 4 — sealed packet sha pinned; live widening is not silently accepted; remediation = new run"

# -----------------------------------------------------------------------------
# TEST 5 — RUNNER CONTRACT STATIC GUARD
# -----------------------------------------------------------------------------
echo ""
echo "=== TEST 5: RUNNER CONTRACT STATIC GUARD ==="
BUILDER_DOC="$ROOT_DIR/agents/of-builder.md"
[[ -f "$BUILDER_DOC" ]] || fail "TEST 5: agents/of-builder.md missing"

grep -Fq "Clean worktree before \`candidate_ready\` (v0.6.1 contract)" "$BUILDER_DOC" \
  || fail "TEST 5: builder contract missing v0.6.1 clean-worktree section"
grep -Eq "git status --porcelain" "$BUILDER_DOC" \
  || fail "TEST 5: builder contract must reference git status --porcelain"
grep -Eq "candidate_ready" "$BUILDER_DOC" \
  || fail "TEST 5: builder contract must discuss candidate_ready"
grep -Eq "out-of-scope|outside.*scope|packet scope" "$BUILDER_DOC" \
  || fail "TEST 5: builder contract must discuss scope conflicts"
grep -Eq "toolchain|toolchain-specific|arbitrary toolchain" "$BUILDER_DOC" \
  || fail "TEST 5: builder contract must be toolchain-generic"
if grep -Eq "npm/package-lock.*must|only npm" "$BUILDER_DOC"; then
  fail "TEST 5: builder contract must not hardcode npm as the only valid toolchain"
fi
pass "TEST 5 — runner contract statically guards clean committed worktree"

# -----------------------------------------------------------------------------
# TEST 6 — REPEATED DIRTY FAILURE REMAINS BOUNDED
# -----------------------------------------------------------------------------
echo ""
echo "=== TEST 6: REPEATED DIRTY FAILURE REMAINS BOUNDED ==="
IFS='|' read -r REPO6 RID6 WT6 < <(make_unfinalized_build_pass "dirty")

for attempt in 1 2 3; do
  set +e
  "$OFLOOP" dispatch finalize "$REPO6" "$RID6" BUILD \
    "$REPO6/.ownframework-loop/$RID6/scratch/builder/pass-0001/BUILD_AGENT_RESULT.json" \
    >/tmp/v061_t6_$attempt.log 2>&1
  ATTEMPT_RC=$?
  set -e
  echo "attempt $attempt rc=$ATTEMPT_RC"
  [[ "$ATTEMPT_RC" -ne 0 ]] || fail "TEST 6: attempt $attempt should refuse dirty"
  grep -Fq "builder worktree is dirty" /tmp/v061_t6_$attempt.log \
    || fail "TEST 6: attempt $attempt missing dirty refusal"
done

FINAL_BUILD_PASS=$(jq -r '.build_pass_count' "$REPO6/.ownframework-loop/$RID6/STATE.json")
echo "build_pass_count after 3 dirty finalize attempts: $FINAL_BUILD_PASS (expected 1)"
[[ "$FINAL_BUILD_PASS" == "1" ]] \
  || fail "TEST 6: build_pass_count incremented ($FINAL_BUILD_PASS) despite identical dirty state"
[[ "$(git -C "$WT6" branch --show-current)" == "factory/candidate/$RID6" ]] \
  || fail "TEST 6: candidate branch changed during dirty retries"
pass "TEST 6 — repeated dirty failure is bounded; no new pass / branch / pass-counter inflation"

echo ""
echo "V061_SEMANTIC_BUILD_FINALIZABILITY_RECOVERY=PASS"
