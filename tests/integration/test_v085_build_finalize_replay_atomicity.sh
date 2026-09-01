#!/usr/bin/env bash
# v0.8.5 — A-09 full build-finalizer crash/replay idempotence.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"

OFLOOP="$OFLOOP_BIN"

prepare_case() {
  local label="$1"
  local repo rid pp order wt semantic sha
  repo="$(make_tmp_repo)"
  "$OFLOOP" spec new "$repo" "build-finalizer-replay-$label" >/dev/null
  rid="$(ls -1t "$repo/.ownframework-loop" | head -n1)"
  pp="$repo/.ownframework-loop/$rid/WORK_PACKET.md"
  python3 -B - "$pp" "$repo" "$label" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); repo=sys.argv[2]; label=sys.argv[3]
meta={
 "schema":"ownframework-work-packet/v2",
 "packet_id":"v085-build-replay-"+label,
 "created_at":"2026-08-30T00:00:00Z",
 "work_class":"HARDENING","risk_class":"low",
 "title":"build finalizer replay "+label,
 "target":{"repo":repo,"branch":"master","classification":"local_only"},
 "acceptance_criteria":[{"id":"AC-1","text":"candidate finalizes once"}],
 "non_goals":[],
 "network_read_allowlist":[],
 "allowed_paths":["src/"],"protected_paths":[".ownframework-loop/"],
 "work_units":[{"id":"UNIT-1","title":"replay proof","scope":"src/"}],
 "merge_authority":"human_only","deploy_authority":"human_only",
 "push_authority":"human_only","external_action_authority":"none",
 "risk_budget":{
   "max_files_changed":10,"max_diff_lines":500,"max_repair_rounds":1,
   "max_consecutive_no_progress_passes":1
 }
}
fence="```"
p.write_text(fence+"json\n"+json.dumps(meta,indent=2,sort_keys=True)+"\n"+fence+"\n",encoding="utf-8")
PY
  PYTHONDONTWRITEBYTECODE=1 python3 -B - "$repo" "$rid" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import execution_start
execution_start.ensure_executable(
    canonical_repo=Path(sys.argv[1]), run_id=sys.argv[2],
    actor="a09-test", binding_method="build_start",
)
PY
  order="$("$OFLOOP" dispatch claim "$repo" "$rid")"
  [[ "$(printf '%s' "$order" | jq -r '.decision')" == "BUILD" ]] || fail "A09 fixture did not claim BUILD"
  wt="$(printf '%s' "$order" | jq -r '.worktree')"
  semantic="$(printf '%s' "$order" | jq -r '.semantic_path')"
  mkdir -p "$wt/src"
  cat >"$wt/src/a09.py" <<PY
def candidate():
    return "$label"
PY
  git -C "$wt" add src/a09.py
  git -C "$wt" commit -m "a09 candidate $label" >/dev/null
  sha="$(git -C "$wt" rev-parse HEAD)"
  python3 -B - "$semantic" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); d=json.loads(p.read_text())
d["summary"]="A09 actual build finalizer candidate"
d["outcome_requested"]="candidate_ready"
d["unit_ids_completed"]=["UNIT-1"]
d["acceptance_addressed"]=["AC-1"]
d["notes"]="same-pass crash/replay proof"
p.write_text(json.dumps(d,indent=2,sort_keys=True)+"\n")
PY
  printf '%s|%s|%s|%s|%s\n' "$repo" "$rid" "$wt" "$semantic" "$sha"
}

IFS='|' read -r REPO RID WT BSEM CANDIDATE_SHA < <(prepare_case crash)

# This fault is exactly where the old finalizer had already saved derived
# last_candidate_sha/no_progress_streak while top-level state remained BUILDING.
# The repaired finalizer has no pre-transition derived-state save, so faulting
# its transition call proves nothing from this pass was partially applied.
PYTHONDONTWRITEBYTECODE=1 python3 -B - "$REPO" "$RID" "$BSEM" "$CANDIDATE_SHA" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import build_finalize, state
repo=Path(sys.argv[1]); rid=sys.argv[2]; semantic=Path(sys.argv[3]); candidate=sys.argv[4]
before=state.load_verified(repo,rid)
assert before["state"]=="BUILDING", before
assert int(before.get("build_pass_count",0))==1, before
original_last=str(before.get("last_candidate_sha") or "")
original_streak=int(before.get("no_progress_streak",0) or 0)

real_transition=state.transition
fired={"v":False}
def crash_transition(canonical_repo, run_id, *, to_state, **owner_kwargs):
    if to_state=="READY_FOR_REVIEW" and not fired["v"]:
        fired["v"]=True
        raise RuntimeError("A09 injected before atomic finalizer-state publication")
    return real_transition(
        canonical_repo, run_id, to_state=to_state, **owner_kwargs,
    )
state.transition=crash_transition
try:
    try:
        build_finalize.finalize_build(
            canonical_repo=repo, run_id=rid, agent_result_path=semantic,
            actor="a09-crash-test",
        )
    except RuntimeError as exc:
        assert "A09 injected before atomic finalizer-state publication" in str(exc), exc
    else:
        raise AssertionError("A09 crash injection did not fire")
finally:
    state.transition=real_transition
assert fired["v"]
after_crash=state.load_verified(repo,rid)
assert after_crash["state"]=="BUILDING", after_crash
assert str(after_crash.get("last_candidate_sha") or "")==original_last, after_crash
assert int(after_crash.get("no_progress_streak",0) or 0)==original_streak, after_crash
assert int(after_crash.get("build_pass_count",0))==1, after_crash

# Restart/replay the SAME exact claimed BUILD pass through the actual finalizer.
receipt=build_finalize.finalize_build(
    canonical_repo=repo, run_id=rid, agent_result_path=semantic,
    actor="a09-replay-test",
)
healed=state.load_verified(repo,rid)
assert healed["state"]=="READY_FOR_REVIEW", healed
assert healed["last_candidate_sha"]==candidate, healed
assert int(healed["build_pass_count"])==1, healed
assert int(healed["no_progress_streak"])==0, healed
snapshot={
 "state":healed["state"],
 "build_pass_count":int(healed["build_pass_count"]),
 "no_progress_streak":int(healed["no_progress_streak"]),
 "last_candidate_sha":healed["last_candidate_sha"],
}

# A further delivery of the same semantic result cannot apply the pass twice.
try:
    build_finalize.finalize_build(
        canonical_repo=repo, run_id=rid, agent_result_path=semantic,
        actor="a09-duplicate-delivery",
    )
except RuntimeError as exc:
    assert "build finalize requires BUILDING state" in str(exc), exc
else:
    raise AssertionError("A09 duplicate finalizer delivery unexpectedly succeeded")
unchanged=state.load_verified(repo,rid)
assert {
 "state":unchanged["state"],
 "build_pass_count":int(unchanged["build_pass_count"]),
 "no_progress_streak":int(unchanged["no_progress_streak"]),
 "last_candidate_sha":unchanged["last_candidate_sha"],
}==snapshot
assert receipt["next_state"]=="READY_FOR_REVIEW", receipt
print("BUILD_PASS_IDENTITY=same")
print("CANDIDATE_SHA=same")
print("NO_PROGRESS_STREAK_AFTER_RECOVERY=expected_once")
print("NO_PROGRESS_STREAK_AFTER_REPLAY=unchanged")
print("SECOND_APPLICATION=no")
print("SPURIOUS_BLOCKED=no")
PY

# Independent uninterrupted actual-finalizer control must reach the same state.
IFS='|' read -r CTRL_REPO CTRL_RID CTRL_WT CTRL_BSEM CTRL_SHA < <(prepare_case control)
"$OFLOOP" dispatch finalize "$CTRL_REPO" "$CTRL_RID" BUILD "$CTRL_BSEM" >/dev/null
python3 -B - "$REPO" "$RID" "$CTRL_REPO" "$CTRL_RID" <<'PY'
import json,sys
from pathlib import Path
r1=Path(sys.argv[1])/".ownframework-loop"/sys.argv[2]/"STATE.json"
r2=Path(sys.argv[3])/".ownframework-loop"/sys.argv[4]/"STATE.json"
a=json.loads(r1.read_text()); b=json.loads(r2.read_text())
assert a["state"]==b["state"]=="READY_FOR_REVIEW", (a["state"],b["state"])
assert int(a["no_progress_streak"])==int(b["no_progress_streak"])==0
assert int(a["build_pass_count"])==int(b["build_pass_count"])==1
print("FINAL_NEXT_STATE=identical_to_uninterrupted_finalization")
print("A09_FULL_FINALIZER_REPLAY_PROOF=PASS")
PY
