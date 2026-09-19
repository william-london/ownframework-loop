from pathlib import Path

# This is temporary GitHub-only correction scaffolding. The final candidate
# removes this file and the temporary workflow before exact-SHA CI.

# B002 diagnostic-only persistence primitive.
p = Path("lib/ownframework_loop/supervisor_db.py")
text = p.read_text()
if "def _persist_job_last_error(" in text:
    raise SystemExit("diagnostic primitive already exists")
text = text.rstrip() + '''\n\n\ndef _persist_job_last_error(\n    conn: sqlite3.Connection,\n    job_id: int,\n    *,\n    last_error: str,\n) -> None:\n    \"\"\"Persist a diagnostic without performing a job lifecycle transition.\n\n    Unlike `_update_job`, this preserves status, retry/counter state, and all\n    worker ownership fields. A missing row is an invariant/programming error.\n    \"\"\"\n    import time as _time\n    cur = conn.execute(\n        \"UPDATE jobs SET last_error=?, updated_at=? WHERE id=?\",\n        (str(last_error), _time.time(), int(job_id)),\n    )\n    if cur.rowcount != 1:\n        conn.rollback()\n        raise RuntimeError(\n            f\"diagnostic persistence lost job row authority: job_id={int(job_id)}\"\n        )\n    conn.commit()\n''' + "\n"
p.write_text(text)

# B002 sibling paths + missing canonical build_agent import.
p = Path("lib/ownframework_loop/supervisor_attempts.py")
text = p.read_text()
anchor = "from . import state as state_mod\n"
if text.count(anchor) != 1:
    raise SystemExit("attempts import anchor mismatch")
text = text.replace(anchor, anchor + "from . import build_agent as build_agent_mod\n", 1)
marker = "\n\n\n\ndef _maybe_complete_semantic_artifact("
if text.count(marker) != 1:
    raise SystemExit("attempts helper marker mismatch")
helper = '''\n\n\ndef _persist_semantic_acceptance_failure(\n    conn: sqlite3.Connection,\n    *,\n    job_id: int,\n    exc: RuntimeError,\n) -> None:\n    \"\"\"Persist acceptance refusal without changing lifecycle ownership.\"\"\"\n    _db_mod._persist_job_last_error(\n        conn,\n        int(job_id),\n        last_error=(f\"semantic_acceptance_publication_failed: {exc}\")[-4000:],\n    )\n'''
text = text.replace(marker, helper + marker, 1)
old = '''        except RuntimeError as exc:\n            # v0.10.0-dev b002: narrow the catch from `except Exception` to\n            # `except RuntimeError as exc` and surface the actual cause on\n            # last_error so the downstream gate refusal carries diagnostic\n            # context for the operator. The gate below still rejects replay\n            # when semantic_accepted=0, but the operator sees the real cause\n            # (identity drift, missing attempt row, unaccounted cost) rather\n            # than the gate's opaque refusal reason.\n            try:\n                _db_mod._update_job(\n                    conn,\n                    int(job_id),\n                    last_error=(\n                        f\"semantic_acceptance_publication_failed: {exc}\"\n                    )[-4000:],\n                )\n            except Exception:\n                pass\n'''
new = '''        except RuntimeError as exc:\n            # B002: diagnostic-only; preserve lifecycle and worker ownership.\n            _persist_semantic_acceptance_failure(\n                conn, job_id=int(job_id), exc=exc\n            )\n'''
if text.count(old) != 1:
    raise SystemExit("maybe-complete B002 block mismatch")
text = text.replace(old, new, 1)
old = '''    except RuntimeError as exc:\n        # v0.10.0-dev b002: surface the actual cause on last_error so the\n        # downstream gate refusal carries diagnostic context. The gate still\n        # rejects replay when semantic_accepted=0, but the operator now sees\n        # the real reason (identity drift, missing attempt, unaccounted cost)\n        # rather than an opaque refusal.\n        # The helper reuses the existing job status (typically RUNNING); pass\n        # it through so _update_job's required status_value kwarg is satisfied.\n        try:\n            current_status = conn.execute(\n                \"SELECT status FROM jobs WHERE id=?\", (int(job_id),)\n            ).fetchone()\n            status_value = str(current_status[\"status\"] or \"RUNNING\") if current_status else \"RUNNING\"\n            _db_mod._update_job(\n                conn,\n                int(job_id),\n                status_value=status_value,\n                last_error=(\n                    f\"semantic_acceptance_publication_failed: {exc}\"\n                )[-4000:],\n            )\n        except Exception:\n            # The surface-call must not mask a programming defect in the\n            # publication helper itself. Re-raising here would silently abort\n            # the recovery path; logging the cause is sufficient because\n            # the gate's downstream refusal already carries diagnostic context.\n            pass\n'''
new = '''    except RuntimeError as exc:\n        # B002: symmetric diagnostic-only persistence.\n        _persist_semantic_acceptance_failure(\n            conn, job_id=int(job_id), exc=exc\n        )\n'''
if text.count(old) != 1:
    raise SystemExit("ready-artifact B002 block mismatch")
p.write_text(text.replace(old, new, 1))

# F007 valid journal may heal unreadable/torn bytes, never parseable tampering.
p = Path("lib/ownframework_loop/state.py")
text = p.read_text()
old = '''    if current_sha == prior_state_sha:\n        atomic_write_json(sp, new_state, mode=0o600)\n        current_sha = integrity.sha256_file(sp)\n    elif current_sha != new_sha:\n        raise integrity.TamperingDetected(\n            \"pending state transaction prior state binding mismatch\"\n        )\n'''
new = '''    if current_sha == prior_state_sha:\n        atomic_write_json(sp, new_state, mode=0o600)\n        current_sha = integrity.sha256_file(sp)\n    elif current_sha != new_sha:\n        # Only unreadable/torn bytes may be explained by this proven journal.\n        current_doc = read_json(sp, default=None) if sp.exists() else None\n        if current_doc is None:\n            atomic_write_json(sp, new_state, mode=0o600)\n            current_sha = integrity.sha256_file(sp)\n        else:\n            raise integrity.TamperingDetected(\n                \"pending state transaction prior state binding mismatch\"\n            )\n'''
if text.count(old) != 1:
    raise SystemExit("state recovery block mismatch")
text = text.replace(old, new, 1)
old = '''            # v0.10.0-dev f007: distinguish torn-write (STATE.json bytes do\n            # not parse as JSON OR do not match recorded SHA) from adversarial\n            # tampering. A torn write is recoverable: re-run the pending-journal\n            # recovery path under the same flock and return the recovered\n            # state. Adversarial tampering still raises TamperingDetected.\n            #\n            # The distinguishing signal: a torn file fails to parse as JSON\n            # (read_json returns the default) OR parses cleanly but the SHA\n            # does not match (msg starts with \"state sha mismatch:\").\n            #\n            # Strategy:\n            # 1. Read the file via read_json. If it returns the default,\n            #    the file is unreadable/torn → attempt journal recovery.\n            # 2. Otherwise parse the bytes (we already have a dict), but\n            #    the SHA didn't match. This is adversarial tampering; do\n            #    NOT attempt journal recovery (the journal is also under\n            #    the attacker's control).\n'''
new = '''            # v0.10.0-dev f007: unreadable STATE bytes are torn; a\n            # parseable SHA mismatch is tampering. A valid pending journal may\n            # recover only the former; otherwise unreadable bytes are StateTorn.\n'''
if text.count(old) != 1:
    raise SystemExit("state comment mismatch")
p.write_text(text.replace(old, new, 1))

# Behavioral proofs appended before summary.
p = Path("tests/integration/test_v10e_pre1_behavioral_proofs.sh")
text = p.read_text()
old = "import tempfile\nimport time\nfrom pathlib import Path\n"
if text.count(old) != 1:
    raise SystemExit("test import marker mismatch")
text = text.replace(old, "import tempfile\nimport time\nimport types\nfrom pathlib import Path\n", 1)
old = "import ownframework_loop.supervisor_recovery as recovery_mod\n"
if text.count(old) != 1:
    raise SystemExit("test supervisor import marker mismatch")
text = text.replace(old, old + "import ownframework_loop.supervisor as supervisor_mod\nimport ownframework_loop.supervisor_claims as claims_mod\n", 1)
summary = "# =========================================================================\n# SUMMARY\n# =========================================================================\n"
if text.count(summary) != 1:
    raise SystemExit("test summary marker mismatch")
extra = r'''
# =========================================================================
# A002 OWNER-LEVEL: supervisor computes timeout supplied to finalizer
# =========================================================================
print("\n=== A002 owner boundary: supervisor derives finalize timeout ===")

def run_a002_owner_case(*, max_wall, clock_values):
    root = Path(tempfile.mkdtemp(prefix="a002-owner-"))
    dbp = root / "sup.sqlite3"
    c = sqlite3.connect(str(dbp)); c.row_factory = sqlite3.Row
    db_mod.bootstrap_schema(c)
    c.execute("INSERT INTO jobs (repo,run_id,runner,status,created_at,updated_at,runtime_generation,max_wall_seconds) VALUES (?,?,'fake','QUEUED',1,1,'gen-test',?)", (str(root), "a002-owner-r", int(max_wall)))
    c.commit(); c.close()
    calls = []; ready_calls = {"n": 0}
    wo = {"schema": dispatch_mod.SCHEMA, "decision": "BUILD", "role": "builder", "run_id": "a002-owner-r", "canonical_repo": str(root), "semantic_path": str(root / "AGENT.json"), "candidate_branch": "agent/a002-owner-r/builder", "baseline_sha": "d"*40}
    class FakeRunner:
        requires_capability_receipt = False
        def run(self, *args, **kwargs):
            return types.SimpleNamespace(ok=True,cost_known=True,tokens_known=True,returncode=0,cost_usd=0.0,input_tokens=0,output_tokens=0,cache_read_tokens=0,cache_creation_tokens=0,effective_model="",model_usage_json="",stderr="",stdout="")
    def ready(_wo):
        ready_calls["n"] += 1
        return (False, "synthetic incomplete") if ready_calls["n"] == 1 else (True, "ok")
    ticks = list(clock_values); last = ticks[-1] if ticks else 1000.0
    def now(): return ticks.pop(0) if ticks else last
    saved = (claims_mod._take_next_job, supervisor_mod._current_runtime_generation, supervisor_mod._register_local_execution, dispatch_mod.claim_next, dispatch_mod.semantic_result_ready, supervisor_mod._maybe_complete_semantic_artifact, supervisor_mod._runner_preflight, supervisor_mod._capability_binding_creation_allowed, supervisor_mod._reserve_semantic_attempt, supervisor_mod.packet_mod.parse_packet_file, supervisor_mod._ensure_execution_started, supervisor_mod._runner, supervisor_mod._account_attempt_cost, supervisor_mod._replay_candidate_sha, supervisor_mod._publish_semantic_acceptance, dispatch_mod.finalize_work_order, supervisor_mod.time)
    try:
        claims_mod._take_next_job = lambda conn: conn.execute("SELECT * FROM jobs WHERE run_id='a002-owner-r'").fetchone()
        supervisor_mod._current_runtime_generation = lambda: "gen-test"
        supervisor_mod._register_local_execution = lambda _j: None
        dispatch_mod.claim_next = lambda **_k: dict(wo)
        dispatch_mod.semantic_result_ready = ready
        supervisor_mod._maybe_complete_semantic_artifact = lambda **_k: False
        supervisor_mod._runner_preflight = lambda _n: types.SimpleNamespace(ready=True,classification="",reason="",retry_after_seconds=0.0,detail="")
        supervisor_mod._capability_binding_creation_allowed = lambda *_a, **_k: True
        supervisor_mod._reserve_semantic_attempt = lambda *_a, **_k: ("a002-att", (root/"stdout", root/"stderr"))
        supervisor_mod.packet_mod.parse_packet_file = lambda _p: ({"risk_budget":{"max_pass_runtime_seconds":7200}}, "")
        supervisor_mod._ensure_execution_started = lambda *_a, **_k: 1000.0
        supervisor_mod._runner = lambda _n: FakeRunner()
        supervisor_mod._account_attempt_cost = lambda *_a, **_k: 0.0
        supervisor_mod._replay_candidate_sha = lambda **_k: "c"*40
        supervisor_mod._publish_semantic_acceptance = lambda *_a, **_k: None
        dispatch_mod.finalize_work_order = lambda _wo, *, timeout_seconds=0: (calls.append(int(timeout_seconds)) or {"finalized":True})
        supervisor_mod.time = types.SimpleNamespace(time=now)
        result = supervisor_mod.run_one(db_path=dbp)
        c = sqlite3.connect(str(dbp)); c.row_factory = sqlite3.Row
        row = c.execute("SELECT status,last_failure_class,last_failure_reason FROM jobs WHERE run_id='a002-owner-r'").fetchone(); c.close()
        return result, calls, row
    finally:
        (claims_mod._take_next_job, supervisor_mod._current_runtime_generation, supervisor_mod._register_local_execution, dispatch_mod.claim_next, dispatch_mod.semantic_result_ready, supervisor_mod._maybe_complete_semantic_artifact, supervisor_mod._runner_preflight, supervisor_mod._capability_binding_creation_allowed, supervisor_mod._reserve_semantic_attempt, supervisor_mod.packet_mod.parse_packet_file, supervisor_mod._ensure_execution_started, supervisor_mod._runner, supervisor_mod._account_attempt_cost, supervisor_mod._replay_candidate_sha, supervisor_mod._publish_semantic_acceptance, dispatch_mod.finalize_work_order, supervisor_mod.time) = saved

ra, ca, _ = run_a002_owner_case(max_wall=100, clock_values=[1040.0,1045.0])
check("A002-owner-A: positive wall budget uses remaining value", ca == [55], detail=f"calls={ca!r} result={ra!r}")
rb, cb, _ = run_a002_owner_case(max_wall=0, clock_values=[1001.0])
check("A002-owner-B: zero wall ceiling uses fallback", cb == [supervisor_mod._DEFAULT_FINALIZER_TIMEOUT_SECONDS], detail=f"calls={cb!r}")
rc, cc, rowc = run_a002_owner_case(max_wall=10, clock_values=[1001.0,1011.0])
check("A002-owner-C: exhausted positive wall budget does not launch finalizer", cc == [], detail=f"calls={cc!r}")
check("A002-owner-C: exhausted budget quarantines as usage ceiling", rc.get("action") == "QUARANTINED" and rc.get("reason") == "wall_clock_ceiling_before_finalization" and rowc["status"] == "QUARANTINED" and rowc["last_failure_class"] == "usage_ceiling" and rowc["last_failure_reason"] == "wall_clock_ceiling_before_finalization", detail=f"result={rc!r} row={dict(rowc)!r}")

# =========================================================================
# F007 REAL: actual state/journal machinery through load_verified
# =========================================================================
print("\n=== F007 behavioral: real STATE/journal recovery boundary ===")
def f7_fixture(label):
    r = Path(tempfile.mkdtemp(prefix=f"f007-{label}-")); rid = f"f007-{label}"; state_mod.run_dir(r,rid).mkdir(parents=True,exist_ok=True)
    initial = state_mod.initial_state(rid); state_mod.save(r,rid,initial); prior = state_mod.load_verified(r,rid)
    new = dict(prior); new["state"]="READY_TO_BUILD"; new["transitions_count"] = int(prior.get("transitions_count") or 0)+1; new["updated_at"]="2026-09-19T00:00:00Z"; new["last_actor"]="f007-test"
    h=list(prior.get("state_history") or []); h.append({"from":prior.get("state"),"to":"READY_TO_BUILD","at":new["updated_at"],"actor":"f007-test","reason":"synthetic interrupted write"}); new["state_history"]=h
    return r,rid,prior,new
def f7_journal(r,rid,prior,new,txid):
    sp=state_mod.state_path(r,rid); ep=state_mod.events_path(r,rid)
    j={"schema":state_mod.STATE_TXN_SCHEMA,"run_id":rid,"txn_id":txid,"prior_state_sha256":integrity_mod.sha256_file(sp),"prior_event_chain_sha256":integrity_mod.get_event_chain_hash(ep) or "","new_state_sha256":state_mod._state_payload_sha(new),"new_state":new,"event":{"event_type":"state_transition","old_state":prior.get("state"),"new_state":new.get("state"),"actor":"f007-test","commit_sha":None,"reason":"synthetic interrupted write","extras":{}}}
    state_mod.atomic_write_json(state_mod.state_txn_path(r,rid),j,mode=0o600)
r,rid,prior,new=f7_fixture("a"); f7_journal(r,rid,prior,new,"txn-a"); state_mod.state_path(r,rid).write_text("{")
try:
    got=state_mod.load_verified(r,rid); check("F007-A: real torn STATE + valid journal recovers",got==new,detail=f"got={got!r}"); check("F007-A: recovery clears journal",not state_mod.state_txn_path(r,rid).exists())
except Exception as exc: check("F007-A: real torn STATE + valid journal recovers",False,f"{type(exc).__name__}: {exc}")
r,rid,prior,new=f7_fixture("b"); f7_journal(r,rid,prior,new,"txn-b"); bad=dict(prior); bad["last_actor"]="tampered"; state_mod.atomic_write_json(state_mod.state_path(r,rid),bad,mode=0o600)
try:
    state_mod.load_verified(r,rid); check("F007-B: parseable SHA mismatch is TamperingDetected",False,"no exception")
except integrity_mod.StateTorn as exc: check("F007-B: parseable SHA mismatch is TamperingDetected",False,f"StateTorn: {exc}")
except integrity_mod.TamperingDetected: check("F007-B: parseable SHA mismatch is TamperingDetected",True)
check("F007-B: journal not laundered/cleared",state_mod.state_txn_path(r,rid).exists())
r,rid,prior,new=f7_fixture("c"); state_mod.state_path(r,rid).write_text("{")
try:
    state_mod.load_verified(r,rid); check("F007-C: torn state without journal is StateTorn",False,"no exception")
except integrity_mod.StateTorn: check("F007-C: torn state without journal is StateTorn",True)
except Exception as exc: check("F007-C: torn state without journal is StateTorn",False,f"{type(exc).__name__}: {exc}")

# =========================================================================
# B002 SYMMETRIC: both sibling refusal paths persist only diagnostics
# =========================================================================
print("\n=== B002 behavioral: symmetric diagnostic persistence ===")
r=Path(tempfile.mkdtemp(prefix="b002-sym-")); subprocess.run(["git","-C",str(r),"init","-q","--initial-branch=master"],check=True); subprocess.run(["git","-C",str(r),"config","user.email","test@x"],check=True); subprocess.run(["git","-C",str(r),"config","user.name","Test"],check=True); (r/".gitignore").write_text(".ownframework-loop/\n"); (r/"README").write_text("init\n"); subprocess.run(["git","-C",str(r),"add","."],check=True); subprocess.run(["git","-C",str(r),"commit","-q","-m","init"],check=True); subprocess.run(["git","-C",str(r),"checkout","-q","-b","agent/r/builder"],check=True)
head=subprocess.run(["git","-C",str(r),"rev-parse","HEAD"],check=True,capture_output=True,text=True).stdout.strip(); semdir=state_mod.run_dir(r,"b002-r"); semdir.mkdir(parents=True,exist_ok=True); sem=semdir/"BUILD_AGENT_RESULT.json"; sem.write_text("{}")
c=sqlite3.connect(":memory:"); c.row_factory=sqlite3.Row; c.executescript("""CREATE TABLE jobs(id INTEGER PRIMARY KEY,repo TEXT,run_id TEXT,status TEXT,latest_attempt_id TEXT,worker_attempt_id TEXT,infra_failures INTEGER DEFAULT 0,transient_failures INTEGER DEFAULT 0,transient_recovery_cycles INTEGER DEFAULT 0,total_cost_usd REAL DEFAULT 0,last_error TEXT,last_failure_class TEXT,last_failure_reason TEXT,next_attempt_at REAL DEFAULT 0,updated_at REAL DEFAULT 0,worker_pid INTEGER,worker_started_at REAL,worker_pgid INTEGER,worker_deadline_at REAL,worker_start_identity TEXT,worker_role TEXT); CREATE TABLE semantic_attempts(attempt_id TEXT PRIMARY KEY,job_id INTEGER,role TEXT,status TEXT,failure_class TEXT,failure_reason TEXT,cost_accounted INTEGER DEFAULT 0,cost_known INTEGER DEFAULT 0,cost_usd REAL DEFAULT 0,semantic_accepted INTEGER DEFAULT 0,accepted_semantic_sha256 TEXT,accepted_candidate_sha TEXT,effective_model TEXT,launch_gate_version INTEGER DEFAULT 1);"""); c.execute("INSERT INTO jobs(id,repo,run_id,status,latest_attempt_id,worker_attempt_id,worker_pid,worker_started_at,worker_pgid,worker_deadline_at,worker_start_identity,worker_role) VALUES(1,?,'b002-r','RUNNING','att-1','att-1',4242,10.5,4242,9999,'pid-start','builder')",(str(r),)); c.execute("INSERT INTO semantic_attempts(attempt_id,job_id,role,status) VALUES('att-1',1,'builder','COMPLETED')"); c.commit()
cols=("status","worker_attempt_id","worker_pid","worker_started_at","worker_pgid","worker_deadline_at","worker_start_identity","worker_role")
def snap():
    x=c.execute("SELECT * FROM jobs WHERE id=1").fetchone(); return {k:x[k] for k in cols},x["last_error"]
before,_=snap(); realpub=attempts_mod._publish_semantic_acceptance; realcomp=attempts_mod.build_agent_mod.semantically_complete_artifact; attempts_mod._publish_semantic_acceptance=lambda *_a,**_k: (_ for _ in ()).throw(RuntimeError("synthetic identity-drift sibling proof")); attempts_mod.build_agent_mod.semantically_complete_artifact=lambda **_k:{"completed":True}
try:
    attempts_mod._publish_acceptance_for_ready_artifact(conn=c,work_order={"canonical_repo":str(r),"candidate_branch":"agent/r/builder","semantic_path":str(sem)},job_id=1); after,e=snap(); check("B002-ready: cause persisted",e and "synthetic identity-drift" in e,detail=repr(e)); check("B002-ready: status/worker fields preserved",after==before,detail=f"before={before!r} after={after!r}")
    c.execute("UPDATE jobs SET last_error=NULL WHERE id=1"); c.commit(); ok=attempts_mod._maybe_complete_semantic_artifact(conn=c,work_order={"decision":"BUILD","canonical_repo":str(r),"run_id":"b002-r","worktree":str(r),"baseline_sha":head,"candidate_branch":"agent/r/builder","cp_id":"cp-1","role":"builder","semantic_path":str(sem)},semantic_reason="synthetic",job_id=1); after,e=snap(); check("B002-maybe: sibling path exercised",ok is True); check("B002-maybe: cause persisted",e and "synthetic identity-drift" in e,detail=repr(e)); check("B002-maybe: status/worker fields preserved",after==before,detail=f"before={before!r} after={after!r}")
    realdiag=db_mod._persist_job_last_error; db_mod._persist_job_last_error=lambda *_a,**_k: (_ for _ in ()).throw(TypeError("synthetic diagnostic persistence bug"))
    try:
        attempts_mod._publish_acceptance_for_ready_artifact(conn=c,work_order={"canonical_repo":str(r),"candidate_branch":"agent/r/builder","semantic_path":str(sem)},job_id=1); check("B002: programming error not swallowed",False,"no TypeError")
    except TypeError as exc: check("B002: programming error not swallowed","synthetic diagnostic" in str(exc),detail=str(exc))
    finally: db_mod._persist_job_last_error=realdiag
finally:
    attempts_mod._publish_semantic_acceptance=realpub; attempts_mod.build_agent_mod.semantically_complete_artifact=realcomp; c.close()

'''
text = text.replace(summary, extra + "\n" + summary, 1)
p.write_text(text)

# Audit wording only.
p = Path("docs/architecture/PRE_1_0_ADVERSARIAL_AUDIT.md")
text = p.read_text()
old = """- 1 hardening bug discovered and root-cause fixed during rigor closure:\n  **B002 refinement**: the original B002 fix called `_db_mod._update_job` without the required `status_value` keyword argument, which made the exception-cause persistence silently fail. Fixed by reading the current status and threading it through. This refinement is pinned by the B002 behavioral regression in `test_v10e_pre1_behavioral_proofs.sh`.\n"""
new = """- 1 hardening bug discovered and root-cause fixed during rigor closure:\n  **B002 symmetric closure**: both semantic-acceptance recovery paths now share diagnostic-only persistence. It writes bounded `last_error` while preserving durable status and every worker-ownership field, rather than misusing lifecycle-transition `_update_job`. Diagnostic-persistence programming errors propagate instead of disappearing behind `except Exception: pass`. Both sibling paths are behaviorally pinned in `test_v10e_pre1_behavioral_proofs.sh`.\n"""
if text.count(old) != 1: raise SystemExit("audit B002 target mismatch")
text=text.replace(old,new,1)
old="""**Fix:** Added `_DEFAULT_FINALIZER_TIMEOUT_SECONDS = 3600`. Always thread a timeout (packet-derived if available, else default).\n**Regression:** test_v10d section A002 asserts the constant exists, is positive, and is bounded within the per-pass envelope.\n"""
new="""**Fix:** Added `_DEFAULT_FINALIZER_TIMEOUT_SECONDS = 3600`. With `max_wall_seconds > 0`, the supervisor supplies the remaining whole-run wall budget; with no declared wall ceiling / zero, it uses the 3600-second fallback. If a positive wall budget is exhausted before finalization, finalization is not launched and the existing usage-ceiling quarantine is used.\n**Regression:** test_v10d keeps the static constant guard; `test_v10e_pre1_behavioral_proofs.sh` proves positive remaining budget, zero/omitted fallback, and exhausted-budget no-launch quarantine at the supervisor owner boundary.\n"""
if text.count(old) != 1: raise SystemExit("audit A002 target mismatch")
text=text.replace(old,new,1)
old="""**Fix:** Added `integrity.StateTorn` subclass of `TamperingDetected`. `load_verified` distinguishes torn (file unreadable) from adversarial tampering (SHA mismatch with parseable bytes). On torn, retry pending-journal recovery; if still torn, raise `StateTorn`.\n**Regression:** test_v10d section F007 asserts `StateTorn` subclass exists and inherits from `TamperingDetected`.\n**Fix files:** `lib/ownframework_loop/integrity.py:46-58`, `lib/ownframework_loop/state.py:457-498`.\n"""
new="""**Fix:** Added `integrity.StateTorn` subclass of `TamperingDetected`. `load_verified` distinguishes unreadable/torn bytes from a parseable SHA mismatch. A valid pending journal may complete the exact declared state only when current STATE bytes are unreadable; parseable mismatched bytes remain `TamperingDetected`. Unreadable state without a recoverable journal raises `StateTorn`.\n**Regression:** `test_v10e_pre1_behavioral_proofs.sh` exercises the real state/journal machinery through `load_verified`: valid journal + torn STATE recovers, parseable mismatch raises `TamperingDetected`, and torn STATE without a valid recoverable journal raises `StateTorn`.\n**Fix files:** `lib/ownframework_loop/integrity.py`, `lib/ownframework_loop/state.py`, `tests/integration/test_v10e_pre1_behavioral_proofs.sh`.\n"""
if text.count(old) != 1: raise SystemExit("audit F007 target mismatch")
text=text.replace(old,new,1)
old="""**Invariant proven:** No nested timeout is shorter than its owner-level budget without a documented safety reason. The 3600s default for both claim CLI and finalize CLI matches the historical cli.py per-pass fallback (3600s), so no operator previously relying on that behavior loses wall budget authority.\n\n**Regression proof:** test_v10d sections A001 and A002 assert the constants exist with bounded values within the per-pass envelope.\n"""
new="""**Invariant proven:** Explicit authorized packet values such as 7200s or 28800s propagate directly; 3600s is only the fallback when the relevant pass-runtime/finalizer wall authority is omitted or zero. Under a positive whole-run wall ceiling, finalization uses the remaining wall budget and does not launch once that budget is exhausted. Explicit authorized long work is therefore not clamped by the fallback.\n\n**Regression proof:** test_v10d preserves the static timeout guards; `test_v10e_pre1_behavioral_proofs.sh` proves explicit 7200s/28800s claim propagation plus owner-level finalizer remaining-budget/fallback/exhaustion behavior.\n"""
if text.count(old) != 1: raise SystemExit("audit timeout target mismatch")
p.write_text(text.replace(old,new,1))
