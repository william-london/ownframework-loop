#!/usr/bin/env bash
# v0.9.2 — single-mode repair continuity + guard classifier regressions.
#
# 1. BUILD_VALIDATION_RETRY continuity: the generic FSM has no
#    CHANGES_REQUESTED -> BUILDING edge, so a single-mode run whose required
#    validation fails must land back on READY_TO_BUILD (deterministic
#    post-hook) or the next build claim can never happen. This regressed
#    silently because program mode claims directly from CHANGES_REQUESTED.
# 2. Foreground `build transition --to CHANGES_REQUESTED` (single mode) must
#    fund the repair round and return the run to a claimable state.
# 3. Protocol-authoritative state fields cannot be overridden by caller
#    extras (FSM bypass defense).
# 4. Guard classifier hardening: reviewer fd-numbered write redirects
#    (1>/3>/10>) refused while stderr capture (2>) and fd duplication stay
#    permitted; builder git submodule/replace/reflog mutations refused with
#    read-only forms allowed; VM/container provisioners (colima/finch/
#    limactl) refused as parallel container clients; rsync daemon URLs
#    refused as remote transfer.
#
# No model is called; synthetic semantic results are schema-correct.

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

OFLOOP="$OFLOOP_BIN"
export PYTHONPATH="$LIB_DIR${PYTHONPATH:+:$PYTHONPATH}"

# ---------- 1. build-validation retry returns to a claimable state ----------

T="$(make_tmp_repo)"
mkdir -p "$T/src" && echo "print(1)" > "$T/src/a.py"
git -C "$T" add . && git -C "$T" commit -m "src" >/dev/null

"$OFLOOP" spec new "$T" "repair-continuity" >/dev/null
RID="$(ls -1t "$T/.ownframework-loop" | head -n1)"
PP="$T/.ownframework-loop/$RID/WORK_PACKET.md"
cat > "$PP" <<PKTEOF
\`\`\`json
{
  "schema": "ownframework-work-packet/v2",
  "packet_id": "p-1",
  "created_at": "2026-07-23T00:00:00Z",
  "work_class": "BUG",
  "risk_class": "low",
  "title": "repair-continuity",
  "target": {"repo": "$T", "branch": "master", "classification": "local_only"},
  "acceptance_criteria": [{"id": "AC-1", "text": "ok"}],
  "non_goals": [],
  "allowed_paths": ["src/"],
  "protected_paths": [".ownframework-loop/"],
  "work_units": [{"id": "UNIT-1", "title": "u", "scope": "s"}],
  "required_validation": [{"name": "must_pass", "command": "sh -c 'exit 1'", "kind": "fast"}],
  "merge_authority": "human_only",
  "deploy_authority": "human_only",
  "push_authority": "human_only",
  "external_action_authority": "none",
  "risk_budget": {"max_files_changed": 25, "max_diff_lines": 1000, "max_repair_rounds": 3}
}
\`\`\`
body
PKTEOF
python3 - "$T" "$RID" <<'PY'
import sys, os
from pathlib import Path
sys.path.insert(0, os.environ.get("OFLOOP_LIB"))
from ownframework_loop import execution_start
execution_start.ensure_executable(
    canonical_repo=Path(sys.argv[1]), run_id=sys.argv[2],
    actor="test", binding_method="build_start",
)
PY

"$OFLOOP" build claim "$T" "$RID" >/dev/null
"$OFLOOP" build prepare "$T" "$RID" >/dev/null
SEMANTIC="$("$OFLOOP" build agent-skeleton "$T" "$RID" | jq -r '.agent_result_path')"
python3 - "$SEMANTIC" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1]); d = json.loads(p.read_text())
d["summary"] = "synthetic builder result for validation retry"
d["outcome_requested"] = "candidate_ready"
d["unit_ids_completed"] = ["UNIT-1"]
d["acceptance_addressed"] = ["AC-1"]
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
WT="$T/.worktrees/ownframework-loop/$RID/builder"
echo "x" > "$WT/src/x.py" && git -C "$WT" add src/x.py && git -C "$WT" commit -m "candidate" >/dev/null

"$OFLOOP" build finalize "$T" "$RID" "$SEMANTIC" >/dev/null 2>&1 || true

RECEIPT_NEXT="$(python3 -c "import json;print(json.load(open('$T/.ownframework-loop/$RID/BUILD_RECEIPT.json'))['next_state'])")"
assert_eq "$RECEIPT_NEXT" "CHANGES_REQUESTED" "receipt records the validation-retry verdict"
STATE="$(python3 -c "import json;print(json.load(open('$T/.ownframework-loop/$RID/STATE.json'))['state'])")"
assert_eq "$STATE" "READY_TO_BUILD" "single-mode validation retry lands claimable READY_TO_BUILD"
REPAIR="$(python3 -c "import json;print(json.load(open('$T/.ownframework-loop/$RID/STATE.json')).get('repair_round',0))")"
assert_eq "$REPAIR" "0" "build-validation retry does not charge repair_round"

OUT="$("$OFLOOP" build claim "$T" "$RID")"
assert_eq "$(printf '%s' "$OUT" | jq -r '.build_pass_count')" "2" "next build pass is reachable and counted"
STATE="$(python3 -c "import json;print(json.load(open('$T/.ownframework-loop/$RID/STATE.json'))['state'])")"
assert_eq "$STATE" "BUILDING" "second claim reaches BUILDING"

# ---------- 2. foreground build transition keeps single mode claimable ----------

T2="$(make_tmp_repo)"
mkdir -p "$T2/src" && echo "1" > "$T2/src/a.py"
git -C "$T2" add . && git -C "$T2" commit -m "src" >/dev/null
RID2="$(make_approved_run "$T2" BUG low "fg-transition")"
"$OFLOOP" build claim "$T2" "$RID2" >/dev/null
"$OFLOOP" build transition "$T2" "$RID2" --to CHANGES_REQUESTED --reason "fg retry" >/dev/null
STATE2="$(python3 -c "import json;print(json.load(open('$T2/.ownframework-loop/$RID2/STATE.json'))['state'])")"
assert_eq "$STATE2" "READY_TO_BUILD" "foreground single-mode CHANGES_REQUESTED returns claimable"
REPAIR2="$(python3 -c "import json;print(json.load(open('$T2/.ownframework-loop/$RID2/STATE.json')).get('repair_round',0))")"
assert_eq "$REPAIR2" "1" "foreground transition funded the repair round"

# ---------- 2b. crash between transition and post-hook is reconciled ----------
# Simulate a crash that landed a single-mode run in CHANGES_REQUESTED after the
# deterministic transition but before its READY_TO_BUILD post-hook: drive the
# state there directly, then let reconcile_run complete the post-hook.

"$OFLOOP" build claim "$T2" "$RID2" >/dev/null
python3 - "$T2" "$RID2" <<'PY'
import sys, os
from pathlib import Path
sys.path.insert(0, os.environ.get("OFLOOP_LIB"))
from ownframework_loop import state as state_mod
repo, rid = Path(sys.argv[1]), sys.argv[2]
# Move BUILDING -> CHANGES_REQUESTED exactly as a finalizer transition would,
# then stop (simulated crash before the post-hook).
state_mod.transition(repo, rid, to_state="CHANGES_REQUESTED", actor="test", reason="simulate crash window")
assert state_mod.load(repo, rid)["state"] == "CHANGES_REQUESTED"
PY
python3 - "$T2" "$RID2" <<'PY'
import sys, os
from pathlib import Path
sys.path.insert(0, os.environ.get("OFLOOP_LIB"))
from ownframework_loop import reconcile
rr = reconcile.reconcile_run(canonical_repo=Path(sys.argv[1]), run_id=sys.argv[2])
assert rr["ok"], rr
assert any(a == "complete_single_mode_changes_requested_post_hook" for a in rr["actions"]), rr["actions"]
PY
STATE2="$(python3 -c "import json;print(json.load(open('$T2/.ownframework-loop/$RID2/STATE.json'))['state'])")"
assert_eq "$STATE2" "READY_TO_BUILD" "reconcile completes a crashed single-mode CHANGES_REQUESTED post-hook"

# ---------- 3. extras may not override protocol-authoritative fields ----------

python3 - "$T" "$RID" <<'PY'
import sys, os
from pathlib import Path
sys.path.insert(0, os.environ.get("OFLOOP_LIB"))
from ownframework_loop import state as state_mod
try:
    state_mod.transition(
        Path(sys.argv[1]), sys.argv[2],
        to_state="READY_FOR_REVIEW", actor="test",
        extras={"state": "APPROVED"},
    )
except ValueError:
    print("reserved-extra refusal ok")
else:
    raise SystemExit("extras overriding `state` was accepted")
cur = state_mod.load(Path(sys.argv[1]), sys.argv[2])
assert cur["state"] == "BUILDING", cur["state"]
PY
pass "transition extras cannot override protocol-authoritative state fields"

# ---------- 4. guard classifier hardening ----------

python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ.get("OFLOOP_LIB"))
from ownframework_loop import guards, external_action

# Reviewer redirects: fd-numbered writes refused; stderr capture and fd
# duplication stay permitted.
refused = [
    "echo x 1>/tmp/evil", "echo x 1>>/tmp/evil", "echo x >/tmp/evil",
    "echo x >>/tmp/evil", "echo x &>/tmp/evil", "echo x 3>/tmp/evil",
    "echo x 10>/tmp/evil", "echo x <>/tmp/evil",
]
allowed = [
    "cmd 2>/tmp/err.log", "cmd 2>>/tmp/err.log", "cmd 1>&2", "cmd >&2",
    "cmd 2>&1", "cmd 3>&1", "cat file",
]
for seg in refused:
    assert not guards.is_reviewer_allowed(seg), f"should be refused: {seg}"
for seg in allowed:
    assert guards._reviewer_redirects_mutating(seg) is False, f"redirect false positive: {seg}"

# Builder git topology: mutations refused, read-only forms allowed.
topo_refused = [
    "git submodule add https://a/b sub",
    "git submodule update --init",
    "git submodule deinit -f .",
    "git replace --graft abc def",
    "git replace -d abc",
    "git reflog expire --expire=now",
    "git reflog delete HEAD@{1}",
]
topo_allowed = [
    "git submodule status",
    "git replace -l",
    "git reflog",
    "git reflog show HEAD@{1}",
]
for seg in topo_refused:
    assert guards._builder_git_topology_mutation(seg) is not None, f"should be refused: {seg}"
for seg in topo_allowed:
    assert guards._builder_git_topology_mutation(seg) is None, f"should be allowed: {seg}"

# VM/container provisioners are parallel container-control clients.
env = {"OFLOOP_SEMANTIC_CONTEXT": "1", "OFLOOP_ROLE": "builder"}
for cmd in ("colima start", "finch run alpine", "limactl start default"):
    r = guards.classify_bash_command_with_env(cmd, env)
    assert r["severity"] == "forbidden", (cmd, r)

# Remote rsync includes daemon-mode URLs.
pat = next(
    p for p, _cls, desc in external_action._BLOCKED_BASH_PATTERNS
    if desc == "remote rsync"
)
assert pat.search("rsync -av /src rsync://host/mod"), "rsync:// daemon URL not refused"
assert pat.search("rsync -avz ./ user@host:/dest"), "ssh-form rsync not refused"
print("guard classifier hardening ok")
PY
pass "guard classifier hardening (redirects, git topology, container clients, rsync)"

echo "OF_LOOP_V092_SINGLE_MODE_REPAIR_CONTINUITY=PASS"
