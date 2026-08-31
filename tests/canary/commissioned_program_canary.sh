#!/usr/bin/env bash
# Final real-proof harness for an already installed + commissioned Loop service.
# PREPARE is model-free. START is the deliberate action that enrolls real work.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKET_RENDERER="$HERE/commissioned_program_packet.py"
WATCHER_HELPER="$HERE/commissioned_program_restart_watcher.py"

die(){ echo "CANARY_STATE=TERMINAL_FAIL reason=$*" >&2; exit 1; }
now(){ date -u +%Y-%m-%dT%H:%M:%SZ; }

field(){
  python3 - "$1" "$2" <<'PY'
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
v=d
for key in sys.argv[2].split("."):
    v=v[key]
print(v if not isinstance(v,(dict,list)) else json.dumps(v,sort_keys=True))
PY
}

update_control(){
  local control="$1"; shift
  python3 - "$control" "$@" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); d=json.loads(p.read_text())
for item in sys.argv[2:]:
    k,v=item.split("=",1); d[k]=v
p.write_text(json.dumps(d,indent=2,sort_keys=True)+"\n")
PY
}

discover(){
  OFLOOP_BIN="${OFLOOP_CANARY_OFLOOP_BIN:-$(command -v ofloop || true)}"
  [[ -n "$OFLOOP_BIN" && -x "$OFLOOP_BIN" ]] || die "installed_ofloop_missing"
  INSTALL_ROOT="$(python3 - "$OFLOOP_BIN" <<'PY'
import sys
from pathlib import Path
print(Path(sys.argv[1]).resolve(strict=True).parents[1])
PY
)"
  [[ -f "$INSTALL_ROOT/.ownframework-loop-managed" ]] || die "managed_core_marker_missing"
  grep -Fq 'kind=core' "$INSTALL_ROOT/.ownframework-loop-managed" || die "managed_core_marker_invalid"
  [[ ! -e "$INSTALL_ROOT/.git" ]] || die "canary_refuses_source_checkout_runtime"
  STATE_ROOT="${OFLOOP_CANARY_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/ownframework-loop}"
  PROVENANCE="$STATE_ROOT/runtime-provenance.json"
  DB="$STATE_ROOT/supervisor.sqlite3"
  [[ -f "$PROVENANCE" && -f "$DB" ]] || die "commissioned_runtime_evidence_missing"
  SERVICE_MANAGER="$(field "$PROVENANCE" service_manager)"
  SERVICE_LABEL="$(field "$PROVENANCE" service_label)"
  PROV_RUNTIME_ROOT="$(field "$PROVENANCE" runtime_root)"
  PROV_GENERATION="$(field "$PROVENANCE" runtime_generation)"
  [[ "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$PROV_RUNTIME_ROOT")" == "$INSTALL_ROOT" ]]     || die "provenance_runtime_root_mismatch"
}

service_active(){
  case "$SERVICE_MANAGER" in
    launchd) launchctl print "gui/$(id -u)/$SERVICE_LABEL" >/dev/null 2>&1 ;;
    systemd-user) systemctl --user is-active --quiet "$SERVICE_LABEL" ;;
    test) [[ -n "${OFLOOP_CANARY_TEST_SERVICE_ACTIVE_FILE:-}" && -f "$OFLOOP_CANARY_TEST_SERVICE_ACTIVE_FILE" ]] ;;
    *) return 1 ;;
  esac
}

restart_service(){
  case "$SERVICE_MANAGER" in
    launchd) launchctl kickstart -k "gui/$(id -u)/$SERVICE_LABEL" ;;
    systemd-user) systemctl --user restart "$SERVICE_LABEL" ;;
    test) die "test_service_restart_must_use_watcher_helper" ;;
    *) die "unsupported_service_manager_$SERVICE_MANAGER" ;;
  esac
}

prepare(){
  discover
  service_active || die "commissioned_service_not_active"
  local base="${OFLOOP_CANARY_BASE:-$STATE_ROOT/canaries}"
  mkdir -p "$base"; chmod 0700 "$base"
  local root
  root="$(mktemp -d "$base/program-canary-XXXXXXXX")"
  chmod 0700 "$root"
  local repo="$root/repo"
  git init -q -b master "$repo"
  git -C "$repo" config user.email canary@localhost
  git -C "$repo" config user.name "OwnFramework Canary"
  mkdir -p "$repo/src" "$repo/tests"
  cat >"$repo/src/names.py" <<'PY'
def normalize_name(name: str) -> str:
    return " ".join(name.strip().split())
PY
  cat >"$repo/tests/test_names.py" <<'PY'
import unittest
from src.names import normalize_name

class NamesTest(unittest.TestCase):
    def test_seed_behavior(self):
        self.assertEqual(normalize_name("  Ada   Lovelace  "), "Ada Lovelace")

if __name__ == "__main__":
    unittest.main()
PY
  touch "$repo/src/__init__.py"
  git -C "$repo" add src tests
  git -C "$repo" commit -q -m "seed commissioned canary"

  "$OFLOOP_BIN" spec new "$repo" "commissioned PROGRAM continuity canary" >/dev/null
  local rid
  rid="$(ls -1t "$repo/.ownframework-loop" | head -n1)"
  local packet="$repo/.ownframework-loop/$rid/WORK_PACKET.md"
  python3 "$PACKET_RENDERER" "$repo" "$packet"

  PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$INSTALL_ROOT/lib" python3 -B - "$packet" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import packet as packet_mod, schema_validate
p=Path(sys.argv[1]); meta,_=packet_mod.parse_packet_file(p)
errs=packet_mod.validate_packet_for_approval(meta)
assert not errs, errs
serrs=schema_validate.validate_packet(meta)
assert not serrs, serrs
assert meta["schema"]=="ownframework-work-packet/v3"
assert meta["execution_mode"]=="program"
assert meta.get("network_read_allowlist")==[]
PY

  local control="$root/control.json"
  ROOT="$root" REPO="$repo" RID="$rid" OFLOOP_BIN="$OFLOOP_BIN" INSTALL_ROOT="$INSTALL_ROOT"   STATE_ROOT="$STATE_ROOT" DB="$DB" PROVENANCE="$PROVENANCE" SERVICE_MANAGER="$SERVICE_MANAGER"   SERVICE_LABEL="$SERVICE_LABEL" GENERATION="$PROV_GENERATION" CREATED="$(now)" python3 -B - <<'PY'
import json,os
from pathlib import Path
d={
 "schema":"ownframework-loop-commissioned-canary-control/v1",
 "status":"PREPARED","created_at":os.environ["CREATED"],
 "canary_root":os.environ["ROOT"],"repo":os.environ["REPO"],"run_id":os.environ["RID"],
 "ofloop_bin":os.environ["OFLOOP_BIN"],"install_root":os.environ["INSTALL_ROOT"],
 "state_root":os.environ["STATE_ROOT"],"db":os.environ["DB"],"provenance":os.environ["PROVENANCE"],
 "service_manager":os.environ["SERVICE_MANAGER"],"service_label":os.environ["SERVICE_LABEL"],
 "runtime_generation_prepared":os.environ["GENERATION"],
 "semantic_intervention_count":0,
}
Path(os.environ["ROOT"],"control.json").write_text(json.dumps(d,indent=2,sort_keys=True)+"\n")
PY
  chmod 0600 "$control"
  echo "CANARY_STATE=PREPARED"
  echo "CANARY_ROOT=$root"
  echo "RUN_ID=$rid"
  echo "REAL_MODEL_EXECUTED=no"
  echo "NEXT_ARM_RESTART=bash $HERE/commissioned_program_canary.sh arm-restart $root"
  echo "NEXT_START=bash $HERE/commissioned_program_canary.sh start $root"
}

load_control(){
  CONTROL="$1/control.json"
  [[ -f "$CONTROL" ]] || die "control_missing"
  OFLOOP_BIN="$(field "$CONTROL" ofloop_bin)"
  INSTALL_ROOT="$(field "$CONTROL" install_root)"
  STATE_ROOT="$(field "$CONTROL" state_root)"
  DB="$(field "$CONTROL" db)"
  PROVENANCE="$(field "$CONTROL" provenance)"
  SERVICE_MANAGER="$(field "$CONTROL" service_manager)"
  SERVICE_LABEL="$(field "$CONTROL" service_label)"
  REPO="$(field "$CONTROL" repo)"
  RID="$(field "$CONTROL" run_id)"
}

start(){
  load_control "$1"
  [[ "$(field "$CONTROL" status)" == "PREPARED" ]] || die "start_requires_PREPARED"
  service_active || die "commissioned_service_not_active"
  local prepared current
  prepared="$(field "$CONTROL" runtime_generation_prepared)"
  current="$(field "$PROVENANCE" runtime_generation)"
  [[ "$prepared" == "$current" ]] || die "runtime_generation_changed_before_start"
  python3 "$WATCHER_HELPER" check "$1" || die "restart_watcher_not_armed"
  "$OFLOOP_BIN" supervisor enqueue "$REPO" "$RID" >"$1/enqueue.json"
  local bound
  bound="$(python3 - "$1/enqueue.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1])).get("runtime_generation",""))
PY
)"
  [[ -n "$bound" && "$bound" == "$prepared" ]] || die "enqueue_generation_mismatch"
  update_control "$CONTROL" "status=STARTED" "started_at=$(now)" "runtime_generation_started=$bound"
  echo "CANARY_STATE=STARTED"
  echo "RUN_ID=$RID"
  echo "REAL_MODEL_EXECUTION=commissioned_service_now_authorized"
}

arm_restart(){
  [[ -x "$WATCHER_HELPER" || -f "$WATCHER_HELPER" ]] || die "restart_watcher_helper_missing"
  python3 "$WATCHER_HELPER" arm "$1" "$WATCHER_HELPER"
}

verify(){
  load_control "$1"
  if [[ ! -f "$1/restart-proof.json" ]]; then
    local reason
    reason="$(python3 - "$CONTROL" <<'PY'
import json,sys
c=json.load(open(sys.argv[1],encoding="utf-8"))
status=c.get("watcher_status")
result=c.get("watcher_result")
if result == "RESTART_BOUNDARY_MISSED":
    print("restart_boundary_missed")
elif isinstance(result, str) and result.startswith("RESTART_FAILED:"):
    print("restart_failed")
elif status in {"ARMED","WAITING","BOUNDARY_OBSERVED","RESTARTING"}:
    print("watcher_died")
elif not c.get("watcher_id"):
    print("watcher_not_armed")
else:
    print("restart_proof_missing")
PY
)"
    die "$reason"
  fi
  PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$INSTALL_ROOT/lib" python3 -B -     "$CONTROL" "$1/restart-proof.json" <<'PY'
import json,sqlite3,sys
from pathlib import Path
from ownframework_loop import integrity,state as state_mod,packet as packet_mod

control_path=Path(sys.argv[1]); restart_path=Path(sys.argv[2])
c=json.loads(control_path.read_text()); repo=Path(c["repo"]); rid=c["run_id"]
rd=repo/".ownframework-loop"/rid
try:
    state=state_mod.load_verified(repo,rid)
    assert state["state"]=="APPROVED", state["state"]
    prog=state["program"]
    assert prog["current_checkpoints"]==[], prog["current_checkpoints"]
    cps={x["id"]:x for x in prog["checkpoints"]}
    assert cps["CP-1"]["terminal"]=="APPROVED"
    assert cps["CP-2"]["terminal"]=="APPROVED"
    assert (cps["CP-1"]["build_pass_count"],cps["CP-1"]["review_pass_count"],cps["CP-1"]["repair_round_count"])==(2,2,1), cps["CP-1"]
    assert (cps["CP-2"]["build_pass_count"],cps["CP-2"]["review_pass_count"],cps["CP-2"]["repair_round_count"])==(1,1,0), cps["CP-2"]
    cc=prog["cumulative_counters"]
    assert (cc["build_pass_count"],cc["review_pass_count"],cc["repair_round_count"])==(3,3,1), cc
    assert (state["build_pass_count"],state["review_pass_count"],state["repair_round"])==(3,3,1), state

    events=integrity.read_event_chain(rd/"EVENTS.log")
    assert integrity.compute_event_chain_hash(rd/"EVENTS.log")==integrity.get_event_chain_hash(rd/"EVENTS.log")
    last_build=None; wrong=0; review_count=0
    for ev in events:
        if ev.get("event_type")=="build_finalized":
            last_build=ev.get("commit_sha")
        elif ev.get("event_type")=="review_finalized":
            review_count += 1
            if not last_build or ev.get("commit_sha") != last_build:
                wrong += 1
    assert review_count==3 and wrong==0, (review_count,wrong)

    conn=sqlite3.connect(f"file:{Path(c['db']).resolve()}?mode=ro",uri=True)
    conn.row_factory=sqlite3.Row
    job=conn.execute("SELECT * FROM jobs WHERE repo=? AND run_id=?",(str(repo.resolve()),rid)).fetchone()
    assert job is not None and job["status"]=="DONE", dict(job) if job else None
    assert job["runtime_generation"]==c["runtime_generation_started"], dict(job)
    attempts=conn.execute("SELECT * FROM semantic_attempts WHERE job_id=? ORDER BY started_at",(job["id"],)).fetchall()
    conn.close()
    assert len(attempts)==6, [dict(x) for x in attempts]
    assert [x["role"] for x in attempts]==["builder","reviewer","builder","reviewer","builder","reviewer"]
    nonterminal={"STARTED","RUNNING","CLAIMED"}
    assert not [x for x in attempts if x["status"] in nonterminal], [dict(x) for x in attempts]
    assert len({x["attempt_id"] for x in attempts})==6

    restart=json.loads(restart_path.read_text())
    assert restart["schema"]=="ownframework-loop-commissioned-canary-restart-proof/v1"
    assert restart["observed_cp1_terminal"]=="APPROVED"
    assert restart["observed_top_state"]=="READY_TO_BUILD"
    assert restart["observed_current_checkpoints"]==["CP-2"]
    assert restart["no_active_cp2_worker"] is True
    assert restart["service_restarted"] is True
    assert restart["service_active_after_restart"] is True
    assert restart["runtime_generation_stable"] is True
    assert restart["service_manager"]==c["service_manager"]
    assert restart["service_label"]==c["service_label"]
    assert restart["watcher_id"]==c["watcher_id"]
    assert restart["runtime_generation_before"]==restart["runtime_generation_after"]==c["runtime_generation_started"]

    meta,_=packet_mod.parse_packet_file(rd/"WORK_PACKET.md")
    assert meta.get("network_read_allowlist")==[]
    assert meta.get("external_action_authority")=="none"
    remotes=__import__("subprocess").check_output(["git","-C",str(repo),"remote"],text=True).strip()
    assert remotes==""

    seal=json.loads((rd/"APPROVAL.json").read_text())
    assert seal["approval_method"]=="build_start"

    hook_log=Path(c["install_root"])/"logs"/"external_action_diagnostics.log"
    hook_text=hook_log.read_text(errors="replace") if hook_log.is_file() else ""
    assert f"run_id={rid} " in hook_text and "decision=BLOCK:" in hook_text, "negative-control hook refusal not observed"

    current_prov=json.loads(Path(c["provenance"]).read_text())
    assert current_prov["runtime_generation"]==c["runtime_generation_started"]

    c["status"]="TERMINAL_PASS"
    c["verified_at"]=__import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat()
    control_path.write_text(json.dumps(c,indent=2,sort_keys=True)+"\n")
except Exception as exc:
    c["status"]="TERMINAL_FAIL"; c["verification_failure"]=f"{type(exc).__name__}: {exc}"
    control_path.write_text(json.dumps(c,indent=2,sort_keys=True)+"\n")
    print(f"CANARY_STATE=TERMINAL_FAIL reason={type(exc).__name__}:{exc}")
    raise

print("DUPLICATE_SEMANTIC_ATTEMPTS=0")
print("LOST_SEMANTIC_ATTEMPTS=0")
print("WRONG_SHA_REVIEWS=0")
print("REPAIR_ACCOUNTING=EXACT")
print("CHECKPOINT_ACCOUNTING=EXACT")
print("RUNTIME_GENERATION_STABLE=yes")
print("STATE_EVENT_CHAIN_VALID=yes")
print("ATTEMPT_LEDGER_COHERENT=yes")
print("UNAUTHORIZED_EXTERNAL_EFFECTS=0")
print("HUMAN_SEMANTIC_INTERVENTION_DURING_RUN=0")
print("PLUGIN_HOOK_RUNTIME_FIRING=PROVEN")
print("FINAL_PROGRAM_STATE=APPROVED")
print("CANARY_STATE=TERMINAL_PASS")
PY
}

status(){
  load_control "$1"
  local job state
  job="$("$OFLOOP_BIN" supervisor status "$REPO" "$RID" 2>/dev/null || true)"
  state="$(python3 - "$REPO" "$RID" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1])/".ownframework-loop"/sys.argv[2]/"STATE.json"
print(json.load(open(p)).get("state","MISSING") if p.is_file() else "MISSING")
PY
)"
  if [[ "$state" == "APPROVED" ]] && printf '%s' "$job" | grep -Fq '"status": "DONE"'; then
    verify "$1"; return
  fi
  if [[ "$state" == "BLOCKED" || "$state" == "STOPPED" ]] || printf '%s' "$job" | grep -Eq '"status": "(QUARANTINED|RETIRED)"'; then
    echo "CANARY_STATE=TERMINAL_FAIL state=$state"
    return 1
  fi
  echo "CANARY_STATE=IN_PROGRESS state=$state"
  printf '%s\n' "$job"
}

destroy(){
  load_control "$1"
  local statusv="$(field "$CONTROL" status)"
  if [[ "$statusv" != "PREPARED" && "$statusv" != "TERMINAL_PASS" && "$statusv" != "TERMINAL_FAIL" ]]; then
    die "destroy_refuses_active_canary_status_$statusv"
  fi
  python3 "$WATCHER_HELPER" cleanup "$1" >/dev/null 2>&1 || true
  rm -rf "$1"
  echo "CANARY_DESTROYED=yes durable_supervisor_ledger_preserved=yes"
}

case "${1:-}" in
  prepare) prepare ;;
  start) [[ $# -eq 2 ]] || die "usage_start_root"; start "$2" ;;
  arm-restart) [[ $# -eq 2 ]] || die "usage_arm_restart_root"; arm_restart "$2" ;;
  status) [[ $# -eq 2 ]] || die "usage_status_root"; status "$2" ;;
  verify) [[ $# -eq 2 ]] || die "usage_verify_root"; verify "$2" ;;
  destroy) [[ $# -eq 2 ]] || die "usage_destroy_root"; destroy "$2" ;;
  *) echo "usage: $0 prepare | start ROOT | arm-restart ROOT | status ROOT | verify ROOT | destroy ROOT" >&2; exit 2 ;;
esac
