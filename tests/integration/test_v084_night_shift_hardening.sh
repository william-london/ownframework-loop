#!/usr/bin/env bash
# v0.8.4 night-shift hardening regression.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib"
TMP="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP"
  rm -f "$ROOT_DIR/.install.provenance" "$ROOT_DIR/.install.log" "$ROOT_DIR/.uninstall.log" "$ROOT_DIR/.supervisor-refresh.log"
}
trap cleanup EXIT

python3 -B - "$TMP" "$ROOT_DIR" <<'PY'
import json, os, sys
from pathlib import Path
tmp=Path(sys.argv[1]); root=Path(sys.argv[2]); sys.path.insert(0,str(root/"lib"))
from ownframework_loop import dispatch, integrity, state, supervisor
from ownframework_loop.util import atomic_write_json

# Torn STATE/EVENTS commit: exact Loop WAL must auto-recover.
repo=tmp/"wal"; repo.mkdir(); run="run-v084-wal"; state.run_dir(repo,run).mkdir(parents=True)
state.save(repo,run,state.initial_state(run))
events_before=state.events_path(repo,run).read_bytes()
new=dict(state.load(repo,run)); new["no_progress_streak"]=7; new["last_actor"]="fault-test"
orig=state._atomic_append_exact_event_locked
def fail(_ep,_line): raise RuntimeError("FAULT_AFTER_STATE")
state._atomic_append_exact_event_locked=fail
try:
    try: state.save(repo,run,new)
    except RuntimeError as exc: assert "FAULT_AFTER_STATE" in str(exc)
    else: raise AssertionError("fault injection did not fire")
finally:
    state._atomic_append_exact_event_locked=orig
assert state.state_txn_path(repo,run).exists()
assert state.events_path(repo,run).read_bytes()==events_before
recovered=state.load(repo,run)
assert recovered["no_progress_streak"]==7
assert not state.state_txn_path(repo,run).exists()
ok,why=integrity.verify_state_sha(state.state_path(repo,run),state.events_path(repo,run)); assert ok,why
assert integrity.get_event_chain_hash(state.events_path(repo,run))==integrity.compute_event_chain_hash(state.events_path(repo,run))

# WAL must not launder unrelated bytes.
repo2=tmp/"tamper"; repo2.mkdir(); run2="run-v084-tamper"; state.run_dir(repo2,run2).mkdir(parents=True)
state.save(repo2,run2,state.initial_state(run2)); n2=dict(state.load(repo2,run2)); n2["no_progress_streak"]=11
state._atomic_append_exact_event_locked=fail
try:
    try: state.save(repo2,run2,n2)
    except RuntimeError: pass
finally:
    state._atomic_append_exact_event_locked=orig
with state.events_path(repo2,run2).open("ab") as fh: fh.write(b'{"foreign":"tamper"}\n')
try: state.load(repo2,run2)
except integrity.TamperingDetected: pass
else: raise AssertionError("unexplained drift accepted")
assert state.state_txn_path(repo2,run2).exists()

# Event extras cannot overwrite authoritative integrity fields.
repo3=tmp/"extra"; repo3.mkdir(); run3="run-v084-extra"; state.run_dir(repo3,run3).mkdir(parents=True)
state.save(repo3,run3,state.initial_state(run3)); before=state.events_path(repo3,run3).read_bytes()
try:
    state.append_event(repo3,run3,event_type="probe",old_state=None,new_state=None,actor="test",extras={"state_sha256":"0"*64})
except ValueError: pass
else: raise AssertionError("reserved event field override accepted")
assert state.events_path(repo3,run3).read_bytes()==before

# Dispatch terminal fallback may not trust raw STATE.json.
repo4=tmp/"terminal"; repo4.mkdir(); run4="run-v084-terminal"; state.run_dir(repo4,run4).mkdir(parents=True)
state.save(repo4,run4,state.initial_state(run4))
raw=json.loads(state.state_path(repo4,run4).read_text()); raw["state"]="APPROVED"; atomic_write_json(state.state_path(repo4,run4),raw)
old_cli=dispatch._run_cli
dispatch._run_cli=lambda *a,**k: (_ for _ in ()).throw(dispatch.DispatchError("synthetic claim failure"))
try:
    try: dispatch._claim_or_terminal(["build","claim"],repo=repo4,run_id=run4)
    except integrity.TamperingDetected: pass
    else: raise AssertionError("tampered terminal state trusted")
finally:
    dispatch._run_cli=old_cli

# RETIRED cannot hide an unresolved semantic attempt.
repo5=tmp/"retire"; repo5.mkdir(); db=tmp/"retire.sqlite3"
out=supervisor.enqueue(canonical_repo=repo5,run_id="run-v084-retire",db_path=db,runtime_generation="ofloop-0.8.4@test")
assert out["status"]=="QUEUED"
with supervisor._connect(db) as c:
    jid=int(c.execute("SELECT id FROM jobs WHERE run_id='run-v084-retire'").fetchone()["id"])
    c.execute("UPDATE jobs SET status='QUARANTINED',worker_pid=NULL,worker_started_at=NULL,worker_role=NULL WHERE id=?",(jid,))
    c.execute("""INSERT INTO semantic_attempts
      (attempt_id,job_id,role,status,started_at,stdout_path,stderr_path)
      VALUES ('attempt-unresolved',?,'builder','RESERVED',1.0,'/tmp/o','/tmp/e')""",(jid,))
ref=supervisor.retire(canonical_repo=repo5,run_id="run-v084-retire",db_path=db)
assert ref.get("retired") is False and ref.get("reason")=="retire_refuses_unresolved_semantic_attempt",ref
with supervisor._connect(db) as c:
    c.execute("UPDATE semantic_attempts SET status='COMPLETED',completed_at=2.0,returncode=0,cost_accounted=1 WHERE attempt_id='attempt-unresolved'")
ret=supervisor.retire(canonical_repo=repo5,run_id="run-v084-retire",db_path=db)
assert ret.get("retired") is True and ret["runtime_generation_preserved"]=="ofloop-0.8.4@test",ret

# Production Claude runner owns a sealed local sandbox/tool envelope.
wt=tmp/"worktree"; wt.mkdir(); fake=tmp/"fake-claude"; argsf=tmp/"args.json"
fake.write_text("""#!/usr/bin/env python3
import json,os,sys
open(os.environ["ARGS_FILE"],"w").write(json.dumps(sys.argv[1:]))
sys.stdin.read()
print(json.dumps({"is_error":False,"result":"ok","total_cost_usd":0.01,"usage":{"input_tokens":1,"output_tokens":1}}))
"""); fake.chmod(0o755)
os.environ["OFLOOP_CLAUDE_BIN"]=str(fake); os.environ["ARGS_FILE"]=str(argsf); os.environ.pop("OFLOOP_CLAUDE_EXTRA_ARGS",None)
rr=supervisor.ClaudeCodeRunner().run({"role":"builder","worktree":str(wt),"canonical_repo":str(repo5),"run_id":"run-v084-runner"},timeout_seconds=10)
assert rr.ok,rr
argv=json.loads(argsf.read_text())
def val(flag): return argv[argv.index(flag)+1]
assert val("--setting-sources")=="user"
assert "--strict-mcp-config" in argv and val("--mcp-config")=="{}"
assert "--no-chrome" in argv and "--no-session-persistence" in argv
assert val("--tools")==supervisor.DEFAULT_CLAUDE_TOOLS
toolset=set(val("--tools").split(","))
assert toolset=={"Read","Edit","Write","NotebookEdit","Bash","Glob","Grep"},toolset
settings=json.loads(val("--settings")); sb=settings["sandbox"]
assert sb["enabled"] and sb["failIfUnavailable"] and sb["autoAllowBashIfSandboxed"]
assert sb["allowUnsandboxedCommands"] is False
assert set(settings["permissions"]["deny"])=={"WebFetch","WebSearch"}
assert settings["disableBypassPermissionsMode"]=="disable" and settings["autoMemoryEnabled"] is False
before=argsf.read_text(); os.environ["OFLOOP_CLAUDE_EXTRA_ARGS"]="--settings {}"
try: supervisor.ClaudeCodeRunner().run({"role":"builder","worktree":str(wt),"canonical_repo":str(repo5),"run_id":"run-v084-runner"},timeout_seconds=10)
except RuntimeError as exc: assert "may not override" in str(exc)
else: raise AssertionError("authority override accepted")
assert argsf.read_text()==before
print("V084_PYTHON_INVARIANTS=PASS")
PY

# Fake macOS + Claude surfaces for canonical install/uninstall lifecycle proof.
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/uname" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == "-s" ]]; then echo Darwin; else /usr/bin/uname "$@"; fi
SH
cat > "$FAKEBIN/launchctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$CLAUDE_CALLS"
if [[ "$1" == "plugin" && "$2" == "marketplace" && "$3" == "list" ]]; then
  echo ownframework
  exit 0
fi
if [[ "$1" == "plugin" && "$2" == "install" ]]; then
  cache="$HOME/.claude/plugins/cache/ownframework/of-loop/$TEST_VERSION"
  mkdir -p "$cache"
  git -C "$TEST_SOURCE_ROOT" archive HEAD | tar -x -C "$cache"
fi
exit 0
SH
chmod +x "$FAKEBIN/uname" "$FAKEBIN/launchctl" "$FAKEBIN/claude"

make_ledger() {
  local db="$1" status="$2"
  mkdir -p "$(dirname "$db")"
  python3 -B - "$db" "$status" <<'PY'
import sqlite3,sys
c=sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE jobs (id INTEGER PRIMARY KEY, run_id TEXT, status TEXT)")
c.execute("INSERT INTO jobs VALUES (1,'run-lifecycle',?)",(sys.argv[2],))
c.commit(); c.close()
PY
}

# RETIRED must not block canonical managed install.
IHOME="$TMP/ihome"; IXDG="$TMP/ixdg"; mkdir -p "$IHOME/Library/LaunchAgents" "$IXDG/ownframework-loop"
: > "$IHOME/Library/LaunchAgents/com.ownframework.loop-supervisor.plist"
make_ledger "$IXDG/ownframework-loop/supervisor.sqlite3" RETIRED
ICALLS="$TMP/icalls"; : > "$ICALLS"
HOME="$IHOME" XDG_STATE_HOME="$IXDG" PATH="$FAKEBIN:$PATH" CLAUDE_CALLS="$ICALLS" TEST_SOURCE_ROOT="$ROOT_DIR" TEST_VERSION="0.8.4" SOURCE_ROOT="$ROOT_DIR" OFLOOP_SKIP_SHIM=1 OFLOOP_SKIP_SUPERVISOR_REFRESH=1 bash "$ROOT_DIR/install.sh" >"$TMP/install-retired.out" 2>&1 || {
  cat "$TMP/install-retired.out" >&2; fail "canonical install blocked RETIRED";
}
grep -Fq "plugin install" "$ICALLS" || fail "RETIRED install never reached plugin install"

# QUEUED still blocks before plugin-manager mutation.
QHOME="$TMP/qhome"; QXDG="$TMP/qxdg"; mkdir -p "$QHOME/Library/LaunchAgents" "$QXDG/ownframework-loop"
: > "$QHOME/Library/LaunchAgents/com.ownframework.loop-supervisor.plist"
make_ledger "$QXDG/ownframework-loop/supervisor.sqlite3" QUEUED
QCALLS="$TMP/qcalls"; : > "$QCALLS"
set +e
HOME="$QHOME" XDG_STATE_HOME="$QXDG" PATH="$FAKEBIN:$PATH" CLAUDE_CALLS="$QCALLS" TEST_SOURCE_ROOT="$ROOT_DIR" TEST_VERSION="0.8.4" SOURCE_ROOT="$ROOT_DIR" OFLOOP_SKIP_SHIM=1 OFLOOP_SKIP_SUPERVISOR_REFRESH=1 bash "$ROOT_DIR/install.sh" >"$TMP/install-queued.out" 2>&1
qrc=$?
set -e
[[ "$qrc" -eq 13 ]] || { cat "$TMP/install-queued.out" >&2; fail "QUEUED install expected rc=13 got $qrc"; }
[[ ! -s "$QCALLS" ]] || fail "QUEUED install called Claude before refusal"

# RETIRED must not block canonical managed uninstall.
UHOME="$TMP/uhome"; UXDG="$TMP/uxdg"; mkdir -p "$UHOME/Library/LaunchAgents" "$UXDG/ownframework-loop"
: > "$UHOME/Library/LaunchAgents/com.ownframework.loop-supervisor.plist"
make_ledger "$UXDG/ownframework-loop/supervisor.sqlite3" RETIRED
UCALLS="$TMP/ucalls"; : > "$UCALLS"
HOME="$UHOME" XDG_STATE_HOME="$UXDG" PATH="$FAKEBIN:$PATH" CLAUDE_CALLS="$UCALLS" TEST_SOURCE_ROOT="$ROOT_DIR" TEST_VERSION="0.8.4" OFLOOP_SKIP_SHIM=1 bash "$ROOT_DIR/uninstall.sh" >"$TMP/uninstall-retired.out" 2>&1 || {
  cat "$TMP/uninstall-retired.out" >&2; fail "canonical uninstall blocked RETIRED";
}
grep -Fq "plugin uninstall" "$UCALLS" || fail "RETIRED uninstall never reached plugin manager"

grep -Fq 'STATE_TXN.json' "$ROOT_DIR/hooks/block_protected_paths.sh" || fail "STATE_TXN.json is not a protected protocol artifact"

pass "v0.8.4 night-shift hardening invariants"
echo "V084_NIGHT_SHIFT_HARDENING=PASS"
