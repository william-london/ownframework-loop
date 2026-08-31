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
  local repo="$1" rid="$2" lane="${3:-0}"; local p="$repo/.ownframework-loop/$rid/WORK_PACKET.md"
  printf '%s\n' '```json' > "$p"
  cat >> "$p" <<EOF
{
  "schema":"ownframework-work-packet/v2", "packet_id":"v090-single-$rid", "created_at":"2026-08-31T00:00:00Z",
  "work_class":"FEATURE", "risk_class":"low", "title":"v0.9 commissioned SINGLE lane $lane",
  "target":{"repo":"$repo","branch":"master","classification":"local_only"},
  "acceptance_criteria":[{"id":"AC-1","text":"add isolated lane $lane behavior without changing unrelated source","verification":"python -m unittest discover -s tests -q"}],
  "non_goals":[{"id":"NG-1","text":"no remote or external effects; do not modify unrelated lane files"}], "allowed_paths":["src/","tests/"], "protected_paths":[".ownframework-loop/",".git/"],
  "required_validation":[{"name":"unit","command":"python -m unittest discover -s tests -q","kind":"fast","expected_exit_code":0}],
  "work_units":[{"id":"UNIT-1","title":"isolated lane $lane","scope":"create src/lane_$lane.py and tests/test_lane_$lane.py only","acceptance":["AC-1"]}],
  "merge_authority":"human_only","deploy_authority":"human_only","push_authority":"human_only","external_action_authority":"none",
  "risk_budget":{"max_files_changed":4,"max_diff_lines":180,"max_repair_rounds":2}
}
EOF
  printf '%s\n' '```' >> "$p"
  cat >> "$p" <<EOF
Create src/lane_$lane.py with lane_value() returning "$lane" and add tests/test_lane_$lane.py proving it. Do not modify src/lib.py or any other lane file.
EOF
}
prepare(){
  local stage="${2:-A}"; [[ "$stage" =~ ^[ABC]$ ]] || die "stage_must_be_A_B_or_C"
  local base="$STATE_ROOT/canaries/concurrency-canary-$(python3 -c 'import secrets; print(secrets.token_hex(4))')"; mkdir -m 700 -p "$base"
  local repos=() runs=(); local i r rid
  if [[ "$stage" == C ]]; then
    # Final N=4 acceptance shape: three PROGRAMs plus one SINGLE across three
    # physical repositories, with PROGRAM A and SINGLE D sharing repo A but
    # owning distinct candidate workspaces.
    r="$base/repo-0"; make_repo "$r"

    "$OFLOOP" spec new "$r" "v090 commissioned C PROGRAM A" >/dev/null
    rid="$(ls -1t "$r/.ownframework-loop" | head -n1)"
    repos+=("$r"); runs+=("$rid")
    python3 "$HERE/commissioned_program_packet.py" "$r" "$r/.ownframework-loop/$rid/WORK_PACKET.md"
    PYTHONPATH="$ROOT/lib" python3 - "$r" "$rid" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import execution_start
execution_start.ensure_executable(canonical_repo=Path(sys.argv[1]), run_id=sys.argv[2], actor="v090-canary-preparer", binding_method="build_start")
PY

    "$OFLOOP" spec new "$r" "v090 commissioned C SINGLE D" >/dev/null
    rid="$(ls -1t "$r/.ownframework-loop" | head -n1)"
    repos+=("$r"); runs+=("$rid")
    make_single_packet "$r" "$rid" "D"
    PYTHONPATH="$ROOT/lib" python3 - "$r" "$rid" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import execution_start
execution_start.ensure_executable(canonical_repo=Path(sys.argv[1]), run_id=sys.argv[2], actor="v090-canary-preparer", binding_method="build_start")
PY

    for physical in 1 2; do
      r="$base/repo-$physical"; make_repo "$r"
      "$OFLOOP" spec new "$r" "v090 commissioned C PROGRAM $physical" >/dev/null
      rid="$(ls -1t "$r/.ownframework-loop" | head -n1)"
      repos+=("$r"); runs+=("$rid")
      python3 "$HERE/commissioned_program_packet.py" "$r" "$r/.ownframework-loop/$rid/WORK_PACKET.md"
      PYTHONPATH="$ROOT/lib" python3 - "$r" "$rid" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import execution_start
execution_start.ensure_executable(canonical_repo=Path(sys.argv[1]), run_id=sys.argv[2], actor="v090-canary-preparer", binding_method="build_start")
PY
    done
  else
    local n=2
    for ((i=0;i<n;i++)); do
      r="$base/repo-$i"; make_repo "$r"; "$OFLOOP" spec new "$r" "v090 commissioned $stage $i" >/dev/null
      rid="$(ls -1t "$r/.ownframework-loop" | head -n1)"; repos+=("$r"); runs+=("$rid")
      if [[ "$stage" == B ]]; then
        python3 "$HERE/commissioned_program_packet.py" "$r" "$r/.ownframework-loop/$rid/WORK_PACKET.md"
      else
        make_single_packet "$r" "$rid" "$i"
      fi
      PYTHONPATH="$ROOT/lib" python3 - "$r" "$rid" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import execution_start
execution_start.ensure_executable(canonical_repo=Path(sys.argv[1]), run_id=sys.argv[2], actor="v090-canary-preparer", binding_method="build_start")
PY
    done
  fi
  local prior; prior="$(PYTHONPATH="$ROOT/lib" python3 -B - <<PY
from ownframework_loop import supervisor
from pathlib import Path
print(supervisor.supervisor_config_get(db_path=Path("$DB"))["max_concurrency"])
PY
)"
  python3 - "$base" "$stage" "$prior" "${repos[*]}" "${runs[*]}" <<'PY'
import json,sys
from pathlib import Path
b=Path(sys.argv[1]); repos=sys.argv[4].split(); runs=sys.argv[5].split()
b.joinpath("control.json").write_text(json.dumps({"schema":"ownframework-loop-concurrency-canary/v2","status":"PREPARED","stage":sys.argv[2],"pre_canary_max_concurrency":int(sys.argv[3]),"db":str(b.parents[1]/"supervisor.sqlite3"),"repos":repos,"runs":runs,"distinct_repository_paths":len(set(repos))},indent=2,sort_keys=True)+"\n")
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
pre_restart_attempts = [
    {
        'job_id': int(row['id']),
        'attempt_id': str(row['attempt_id']),
        'role': str(row['role']),
        'worker_pid': int(row['worker_pid']) if row['worker_pid'] is not None else None,
        'worker_pgid': int(row['worker_pgid']) if row['worker_pgid'] is not None else None,
        'worker_start_identity': str(row['worker_start_identity'] or ''),
    }
    for row in active
]
control.update({
    'supervisor_restart_proven': True,
    'multi_inflight_before_restart': len(active),
    'pre_restart_attempts': pre_restart_attempts,
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
import json, sqlite3, sys
from collections import defaultdict
from pathlib import Path
from ownframework_loop import integrity, state as state_mod

control_path = Path(sys.argv[1])
c = json.loads(control_path.read_text())
db = sqlite3.connect('file:' + c['db'] + '?mode=ro', uri=True)
db.row_factory = sqlite3.Row

terminal_attempt_statuses = {
    'COMPLETED', 'COST_UNKNOWN', 'TOKENS_UNKNOWN', 'RECOVERED', 'FAILED'
}
jobs = []
attempt_ids = set()
spans = []
per_job_spans = defaultdict(list)
failed_attempts = 0
cross_repo_mixups = 0
wrong_sha = 0

for repo_text, rid in zip(c['repos'], c['runs']):
    repo = Path(repo_text).resolve()
    job = db.execute(
        'select * from jobs where repo=? and run_id=?',
        (str(repo), rid),
    ).fetchone()
    assert job is not None, (repo, rid)
    assert job['status'] == 'DONE', dict(job)
    assert int(job['repository_identity_proven'] or 0) == 1, dict(job)
    jobs.append(job)

    state_doc = state_mod.load_verified(repo, rid)
    assert isinstance(state_doc, dict), (repo, rid, 'state missing')
    assert state_doc.get('state') == 'APPROVED', state_doc

    # Replay deterministic BUILD/REVIEW finalization identity. Every finalized
    # review must bind the exact candidate produced by the immediately
    # preceding finalized build; duplicate review finalization without a new
    # build is therefore impossible to hide behind non-overlapping timings.
    events = integrity.read_event_chain(
        repo / '.ownframework-loop' / rid / 'EVENTS.log'
    )
    last_build_sha = None
    review_event_count = 0
    for event in events:
        event_type = str(event.get('event_type') or '')
        if event_type == 'build_finalized':
            event_sha = str(event.get('commit_sha') or '')
            assert event_sha, (rid, 'build_finalized_missing_sha', event)
            assert event_sha != last_build_sha, (
                rid, 'duplicate_build_finalized_same_sha', event_sha
            )
            last_build_sha = event_sha
        elif event_type == 'review_finalized':
            event_sha = str(event.get('commit_sha') or '')
            assert event_sha, (rid, 'review_finalized_missing_sha', event)
            assert last_build_sha is not None, (
                rid, 'review_finalized_without_preceding_build', event
            )
            assert event_sha == last_build_sha, (
                rid, 'review_sha_mismatch', last_build_sha, event_sha
            )
            review_event_count += 1
            last_build_sha = None
    assert review_event_count >= 1, (rid, 'no_review_finalized_event')
    assert last_build_sha is None, (rid, 'unreviewed_finalized_build', last_build_sha)

    verdict_path = repo / '.ownframework-loop' / rid / 'REVIEW_VERDICT.json'
    assert verdict_path.is_file(), verdict_path
    verdict = json.loads(verdict_path.read_text())
    assert verdict.get('run_id') == rid, verdict
    if verdict.get('candidate_sha_reviewed') != state_doc.get('last_candidate_sha'):
        wrong_sha += 1

    attempts = list(db.execute(
        'select * from semantic_attempts where job_id=? order by started_at, attempt_id',
        (job['id'],),
    ))
    assert attempts, dict(job)
    for attempt in attempts:
        assert attempt['status'] in terminal_attempt_statuses, dict(attempt)
        if attempt['status'] == 'FAILED':
            failed_attempts += 1
        attempt_id = str(attempt['attempt_id'])
        assert attempt_id not in attempt_ids, attempt_id
        attempt_ids.add(attempt_id)
        assert int(attempt['job_id']) == int(job['id']), dict(attempt)

        role = str(attempt['role'])
        for field, suffix in (('stdout_path', '.out'), ('stderr_path', '.err')):
            p = Path(str(attempt[field]))
            expected_name = f"job-{int(job['id'])}-{role}-attempt-{attempt_id}{suffix}"
            if p.parent.name != rid or p.name != expected_name:
                cross_repo_mixups += 1

        if attempt['completed_at'] is not None:
            start = float(attempt['started_at'])
            end = float(attempt['completed_at'])
            assert end >= start, dict(attempt)
            span = (
                start, end, str(job['workspace_scheduling_key']),
                int(job['id']), attempt_id,
            )
            spans.append(span)
            per_job_spans[int(job['id'])].append(span)

# One job may never own overlapping semantic attempts.
for job_id, job_spans in per_job_spans.items():
    ordered = sorted(job_spans)
    for left, right in zip(ordered, ordered[1:]):
        assert left[1] <= right[0], (
            'duplicate active semantic work in one job', job_id, left, right
        )

# Compute actual peak concurrently active workspace identities from durable
# semantic-attempt intervals. End events sort before start events at an
# identical timestamp so zero-width handoffs do not manufacture overlap.
events = []
for start, end, repo_key, job_id, attempt_id in spans:
    if end > start:
        events.append((start, 1, repo_key))
        events.append((end, -1, repo_key))
events.sort(key=lambda x: (x[0], x[1]))
active_counts = defaultdict(int)
peak = 0
for _, delta, repo_key in events:
    if delta < 0:
        active_counts[repo_key] = max(0, active_counts[repo_key] - 1)
    else:
        active_counts[repo_key] += 1
    peak = max(peak, sum(1 for value in active_counts.values() if value > 0))

repo_keys = [str(j['repository_scheduling_key']) for j in jobs]
workspace_keys = [str(j['workspace_scheduling_key']) for j in jobs]
assert all(workspace_keys) and len(set(workspace_keys)) == len(workspace_keys), workspace_keys
assert all(int(j['workspace_identity_proven'] or 0) == 1 for j in jobs)
assert cross_repo_mixups == 0, cross_repo_mixups
assert wrong_sha == 0, wrong_sha
assert failed_attempts == 0, failed_attempts

stage = c['stage']
required_peak = 4 if stage == 'C' else 2
assert peak >= required_peak, (stage, peak, required_peak)
if stage == 'C':
    assert len(set(repo_keys)) == 3, repo_keys
    grouped = defaultdict(list)
    for job in jobs:
        grouped[str(job['repository_scheduling_key'])].append(str(job['workspace_scheduling_key']))
    assert sorted(len(v) for v in grouped.values()) == [1, 1, 2], grouped
    modes = [str(job['execution_mode']) for job in jobs]
    assert modes.count('PROGRAM') == 3 and modes.count('SINGLE') == 1, modes

if stage == 'B':
    assert c.get('supervisor_restart_proven') is True, c
    assert int(c.get('multi_inflight_before_restart') or 0) >= 2, c
    before = str(c.get('runtime_generation_before_restart') or '')
    after = str(c.get('runtime_generation_after_restart') or '')
    assert before and before == after, (before, after)

    pre_restart = list(c.get('pre_restart_attempts') or [])
    assert len(pre_restart) >= 2, pre_restart
    for snapshot in pre_restart:
        rows = list(db.execute(
            'select * from semantic_attempts where attempt_id=?',
            (snapshot['attempt_id'],),
        ))
        assert len(rows) == 1, (snapshot, [dict(row) for row in rows])
        row = rows[0]
        assert int(row['job_id']) == int(snapshot['job_id']), (snapshot, dict(row))
        assert str(row['role']) == str(snapshot['role']), (snapshot, dict(row))
        assert row['status'] in terminal_attempt_statuses, (snapshot, dict(row))
        if snapshot.get('worker_pid') is not None:
            assert int(row['worker_pid']) == int(snapshot['worker_pid']), (snapshot, dict(row))
        if snapshot.get('worker_pgid') is not None:
            assert int(row['worker_pgid']) == int(snapshot['worker_pgid']), (snapshot, dict(row))
        assert str(row['worker_start_identity'] or '') == str(
            snapshot.get('worker_start_identity') or ''
        ), (snapshot, dict(row))

total_attempts = len(attempt_ids)
db.close()

print('CANARY_STATE=TERMINAL_PASS')
print('STAGE=' + stage)
print('SEMANTIC_ATTEMPTS=' + str(total_attempts))
print('FAILED_SEMANTIC_ATTEMPTS=' + str(failed_attempts))
print('PEAK_ACTIVE_WORKSPACES=' + str(peak))
print('DISTINCT_REPOSITORIES=' + str(len(set(repo_keys))))
print('DUPLICATE_ACTIVE_ATTEMPTS=0')
print('LOST_RUNS=0')
print('WRONG_SHA_REVIEWS=0')
print('FAILED_SEMANTIC_ATTEMPTS=0')
print('REVIEW_EVENT_CHAIN_SHA_COHERENT=PASS')
print('CROSS_REPO_ATTEMPT_MIXUPS=0')
print('LEDGER_COHERENCE=PASS')
if stage != 'C':
    print('PEAK_ACTIVE_REPOSITORIES=' + str(peak))
if stage == 'C':
    print('SAME_REPOSITORY_MULTI_WORKSPACE_PROOF=PASS')
    print('MIXED_PROGRAM_SINGLE_FLEET=PASS')
if stage == 'B':
    print('MULTI_INFLIGHT_BEFORE_RESTART=' + str(c['multi_inflight_before_restart']))
    print('SUPERVISOR_RESTART_PROVEN=yes')
    print('RUNTIME_GENERATION_STABLE=yes')
    print('RESTART_ATTEMPT_RECONCILIATION=PASS')
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
