#!/usr/bin/env bash
# v0.9 commissioned concurrency harness. PREPARE is model-free; START is the
# deliberate point at which the commissioned service may spend semantic calls.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OFLOOP="${OFLOOP_CANARY_OFLOOP_BIN:-$(command -v ofloop || true)}"
[[ -x "$OFLOOP" ]] || { echo "CANARY_STATE=TERMINAL_FAIL reason=ofloop_missing" >&2; exit 1; }
STATE_ROOT="${OFLOOP_CANARY_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/ownframework-loop}"
DB="$STATE_ROOT/supervisor.sqlite3"
die(){ echo "CANARY_STATE=TERMINAL_FAIL reason=$*" >&2; exit 1; }
field(){ python3 - "$1" "$2" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); v=d
for k in sys.argv[2].split('.'): v=v[k]
print(v if not isinstance(v,(dict,list)) else json.dumps(v,sort_keys=True))
PY
}
make_repo(){
  local p="$1"; mkdir -p "$p/src" "$p/tests"
  git init -q -b master "$p"; git -C "$p" config user.email canary@localhost; git -C "$p" config user.name 'OwnFramework Canary'
  printf 'def hello():\n    return "seed"\n' > "$p/src/lib.py"
  printf 'from src.lib import hello\n\ndef test_seed():\n    assert hello() == "seed"\n' > "$p/tests/test_lib.py"
  touch "$p/src/__init__.py"; git -C "$p" add src tests; git -C "$p" commit -qm seed
}
make_single_packet(){
  local repo="$1" rid="$2"; local p="$repo/.ownframework-loop/$rid/WORK_PACKET.md"
  printf '%s\n' '```json' > "$p"
  cat >> "$p" <<EOF
{
  "schema":"ownframework-work-packet/v2", "packet_id":"v090-single-$rid", "created_at":"2026-08-31T00:00:00Z",
  "work_class":"FEATURE", "risk_class":"low", "title":"v0.9 commissioned SINGLE $rid",
  "target":{"repo":"$repo","branch":"master","classification":"local_only"},
  "acceptance_criteria":[{"id":"AC-1","text":"extend hello with a name while preserving seed behavior","verification":"python -m unittest discover -s tests -q"}],
  "non_goals":[{"id":"NG-1","text":"no remote or external effects"}], "allowed_paths":["src/","tests/"], "protected_paths":[".ownframework-loop/",".git/"],
  "required_validation":[{"name":"unit","command":"python -m unittest discover -s tests -q","kind":"fast","expected_exit_code":0}],
  "work_units":[{"id":"UNIT-1","title":"extend hello","scope":"src/ and tests/","acceptance":["AC-1"]}],
  "merge_authority":"human_only","deploy_authority":"human_only","push_authority":"human_only","external_action_authority":"none",
  "risk_budget":{"max_files_changed":10,"max_diff_lines":300,"max_repair_rounds":2}
}
EOF
  printf '%s\n' '```' >> "$p"
  cat >> "$p" <<'EOF'
Extend hello to accept an optional name and add a passing test.
EOF
}
prepare(){
  local stage="${2:-A}"; [[ "$stage" =~ ^[ABC]$ ]] || die "stage_must_be_A_B_or_C"
  local base="$STATE_ROOT/canaries/concurrency-canary-$(python3 -c 'import secrets; print(secrets.token_hex(4))')"; mkdir -m 700 -p "$base"
  local n=2; [[ "$stage" == C ]] && n=4
  local repos=() runs=(); local i
  for ((i=0;i<n;i++)); do
    local r="$base/repo-$i"; make_repo "$r"; "$OFLOOP" spec new "$r" "v090 commissioned $stage $i" >/dev/null
    local rid; rid="$(ls -1t "$r/.ownframework-loop" | head -n1)"; repos+=("$r"); runs+=("$rid")
    if [[ "$stage" == B || ( "$stage" == C && "$i" -lt 3 ) ]]; then
      python3 "$HERE/commissioned_program_packet.py" "$r" "$r/.ownframework-loop/$rid/WORK_PACKET.md"
    else
      make_single_packet "$r" "$rid"
    fi
    PYTHONPATH="$ROOT/lib" python3 - "$r" "$rid" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import execution_start
execution_start.ensure_executable(canonical_repo=Path(sys.argv[1]), run_id=sys.argv[2], actor='v090-canary-preparer', binding_method='build_start')
PY
  done
  local prior; prior="$(PYTHONPATH="$ROOT/lib" python3 -B - <<PY
from ownframework_loop import supervisor
from pathlib import Path
print(supervisor.supervisor_config_get(db_path=Path("$DB"))["max_concurrency"])
PY
)"
  python3 - "$base" "$stage" "$prior" "${repos[*]}" "${runs[*]}" <<'PY'
import json,sys
from pathlib import Path
b=Path(sys.argv[1]); b.joinpath('control.json').write_text(json.dumps({'schema':'ownframework-loop-concurrency-canary/v1','status':'PREPARED','stage':sys.argv[2],'pre_canary_max_concurrency':int(sys.argv[3]),'db':str(b.parents[1]/'supervisor.sqlite3'),'repos':sys.argv[4].split(),'runs':sys.argv[5].split()},indent=2,sort_keys=True)+'\n')
PY
  echo "CANARY_STATE=PREPARED"; echo "CANARY_ROOT=$base"; echo "STAGE=$stage"; echo "REAL_MODEL_EXECUTED=no"; echo "PRE_CANARY_MAX_CONCURRENCY=$prior"
}
start(){
  local root="$1"; [[ "$(field "$root/control.json" status)" == PREPARED ]] || die "start_requires_prepared"
  local stage; stage="$(field "$root/control.json" stage)"; local n=2; [[ "$stage" == C ]] && n=4
  "$OFLOOP" supervisor config set max_concurrency "$n" --db "$DB" >/dev/null
  local -a rp ri
  rp=()
  while IFS= read -r value; do rp+=("$value"); done < <(python3 - "$root/control.json" <<'PY'
import json,sys
for value in json.load(open(sys.argv[1]))["repos"]: print(value)
PY
)
  ri=()
  while IFS= read -r value; do ri+=("$value"); done < <(python3 - "$root/control.json" <<'PY'
import json,sys
for value in json.load(open(sys.argv[1]))["runs"]: print(value)
PY
)
  local i; for ((i=0;i<${#rp[@]};i++)); do "$OFLOOP" supervisor enqueue "${rp[$i]}" "${ri[$i]}" --db "$DB" >/dev/null; done
  python3 - "$root/control.json" "$n" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); d=json.loads(p.read_text()); d.update(status='STARTED',max_concurrency=int(sys.argv[2])); p.write_text(json.dumps(d,indent=2,sort_keys=True)+'\n')
PY
  echo "CANARY_STATE=STARTED"; echo "REAL_MODEL_EXECUTION=commissioned_service_now_authorized"
}
status(){
  local root="$1"; local -a rp ri
  rp=()
  while IFS= read -r value; do rp+=("$value"); done < <(python3 - "$root/control.json" <<'PY'
import json,sys
for value in json.load(open(sys.argv[1]))["repos"]: print(value)
PY
)
  ri=()
  while IFS= read -r value; do ri+=("$value"); done < <(python3 - "$root/control.json" <<'PY'
import json,sys
for value in json.load(open(sys.argv[1]))["runs"]: print(value)
PY
)
  local i; for ((i=0;i<${#rp[@]};i++)); do "$OFLOOP" supervisor status "${rp[$i]}" "${ri[$i]}" --db "$DB"; done
}
restart(){
  local root="$1"; [[ "$(field "$root/control.json" status)" == STARTED ]] || die "restart_requires_started"
  [[ "$(field "$root/control.json" stage)" == B ]] || die "restart_is_for_stage_B"
  PYTHONPATH="$ROOT/lib" python3 - "$root/control.json" <<'PY'
import json, os, sqlite3, subprocess, sys, time
from pathlib import Path

control_path = Path(sys.argv[1])
control = json.loads(control_path.read_text())
db_path = control['db']
ids = tuple(control['runs'])
deadline = time.time() + 1800
before = None
active = []
while time.time() < deadline:
    db = sqlite3.connect('file:' + db_path + '?mode=ro', uri=True)
    db.row_factory = sqlite3.Row
    active = list(db.execute(
        """select j.id,j.runtime_generation,a.attempt_id,a.role,a.worker_pid,a.worker_pgid,
                  a.worker_start_identity
             from jobs j join semantic_attempts a on a.job_id=j.id
            where j.run_id in (?,?) and a.status='RUNNING'
              and j.status='RUNNING' and a.worker_pid is not null""", ids
    ))
    if len(active) >= 2:
        before = str(active[0]['runtime_generation'] or '')
        break
    db.close()
    time.sleep(1)
if len(active) < 2:
    raise SystemExit('MULTI_INFLIGHT_BEFORE_RESTART=FAIL')
label = 'com.ownframework.loop-supervisor'
target = f'gui/{os.getuid()}/{label}'
result = subprocess.run(['launchctl', 'kickstart', '-k', target], text=True,
                        capture_output=True)
if result.returncode:
    raise SystemExit('SUPERVISOR_RESTART_PROVEN=no: ' + (result.stderr or result.stdout))
deadline = time.time() + 60
while time.time() < deadline:
    probe = subprocess.run(['launchctl', 'print', target], text=True,
                           capture_output=True)
    if probe.returncode == 0 and 'state = running' in probe.stdout:
        break
    time.sleep(1)
else:
    raise SystemExit('SERVICE_ACTIVE_AFTER_RESTART=no')
db = sqlite3.connect('file:' + db_path + '?mode=ro', uri=True)
after = str(db.execute(
    "select runtime_generation from jobs where run_id=?", (ids[0],)
).fetchone()[0] or '')
db.close()
control.update({
    'supervisor_restart_proven': True,
    'multi_inflight_before_restart': len(active),
    'runtime_generation_before_restart': before,
    'runtime_generation_after_restart': after,
    'restart_at': time.time(),
})
control_path.write_text(json.dumps(control, indent=2, sort_keys=True) + '\n')
print('MULTI_INFLIGHT_BEFORE_RESTART=' + str(len(active)))
print('SUPERVISOR_RESTART_PROVEN=yes')
print('SERVICE_ACTIVE_AFTER_RESTART=yes')
print('RUNTIME_GENERATION_STABLE=' + ('yes' if before == after else 'no'))
PY
}
verify(){
  local root="$1"; PYTHONPATH="$ROOT/lib" python3 - "$root/control.json" <<'PY'
import json,sqlite3,sys
from pathlib import Path
c=json.loads(Path(sys.argv[1]).read_text()); db=sqlite3.connect('file:'+c['db']+'?mode=ro',uri=True); db.row_factory=sqlite3.Row
jobs=[]
all_spans=[]
for repo,rid in zip(c['repos'],c['runs']):
 j=db.execute('select * from jobs where repo=? and run_id=?',(str(Path(repo).resolve()),rid)).fetchone(); assert j and j['status']=='DONE',dict(j) if j else None; jobs.append(j)
 attempts=[]
 for a in db.execute('select * from semantic_attempts where job_id=? order by started_at',(j['id'],)): attempts.append(a)
 assert attempts and all(a['status'] in ('COMPLETED','COST_UNKNOWN','TOKENS_UNKNOWN','RECOVERED','FAILED') for a in attempts)
 spans=[(float(a['started_at']),float(a['completed_at'] or a['started_at']),str(j['repository_scheduling_key'])) for a in attempts if a['completed_at']]
 all_spans.extend(spans)
 c['_attempts']=sum(len(list(db.execute('select 1 from semantic_attempts where job_id=?',(j['id'],)))) for j in jobs)
 c['_overlap']=any(x[2]!=y[2] and x[0]<y[1] and y[0]<x[1] for x in all_spans for y in all_spans)
db.close(); assert c.get('_overlap') is True, 'no durable cross-repository overlap'; print('CANARY_STATE=TERMINAL_PASS'); print('SEMANTIC_ATTEMPTS='+str(c['_attempts'])); print('PEAK_ACTIVE_REPOSITORIES='+str(len(c['repos'])))
PY
}
destroy(){
  local root="$1"; local prior; prior="$(field "$root/control.json" pre_canary_max_concurrency)"; "$OFLOOP" supervisor config set max_concurrency "$prior" --db "$DB" >/dev/null
  python3 - "$root/control.json" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); d=json.loads(p.read_text()); d['status']='DESTROYED'; p.write_text(json.dumps(d,indent=2,sort_keys=True)+'\n')
PY
  rm -rf "$root"; echo "CANARY_CLEANUP=PASS"; echo "CANARY_CONFIG_RESTORED=yes"
}
case "${1:-}" in prepare) prepare "$@";; start) start "$2";; status) status "$2";; restart) restart "$2";; verify) verify "$2";; destroy) destroy "$2";; *) echo "usage: $0 prepare A|B|C | start ROOT | status ROOT | restart ROOT | verify ROOT | destroy ROOT" >&2; exit 2;; esac
