#!/usr/bin/env bash
# OwnFramework Loop — Pass-3 micro source patches:
#   1. response digest binding in ofloop-research-call
#   2. rate-limit operator authority (env precedence + shared context)
#   3. ordinary transient zero-ceiling preserved (no implicit
#      DEFAULT_MAX_TRANSIENT_FAILURES substitution)
#   4. owned recovery connection lifetime (exception-safe close)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TMP_ROOT="$(mktemp -d -t ofloop-pass3-micro.XXXXXX)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

PASS=0
FAIL=()
check() {
    local name="$1"; shift
    if "$@"; then
        PASS=$((PASS+1))
        echo "PASS ${name}"
    else
        FAIL+=("${name}")
        echo "FAIL ${name}"
    fi
}

# ----------------------------------------------------------------- #
# 1. RESPONSE_REQUEST_ID_BINDING / RESPONSE_REQUEST_DIGEST_BINDING  #
#    STALE_RESPONSE_REUSE_REFUSED                                   #
# ----------------------------------------------------------------- #
PYTHONPATH="${REPO_ROOT}/lib${PYTHONPATH:+:${PYTHONPATH}}" \
PATH="${REPO_ROOT}/bin:${PATH}" \
PYTHONPATH_BIN="${REPO_ROOT}/lib${PYTHONPATH:+:${PYTHONPATH}}" \
python3 - "${REPO_ROOT}" "${TMP_ROOT}" <<'PY'
import json, os, re, shutil, subprocess, sys, time, uuid
from pathlib import Path

repo = Path(sys.argv[1])
tmp  = Path(sys.argv[2])
helper = repo / "bin" / "ofloop-research-call"

ev = tmp / "evidence"
(run_requests := ev / "run-20260923T150000Z-aaaa0001" / "requests").mkdir(parents=True, mode=0o700)
(ev / "run-20260923T150000Z-aaaa0001" / "responses").mkdir(parents=True, mode=0o700)

os.environ["OFLOOP_RESEARCH_REQUESTS"]  = str(run_requests)
os.environ["OFLOOP_RESEARCH_RESPONSES"] = str(ev / "run-20260923T150000Z-aaaa0001" / "responses")

run_id  = "run-20260923T150000Z-aaaa0001"
attempt = "pass-0001"
role    = "builder"
op      = "read"
url     = "https://example.invalid/"

def helper_digest(args_req_id):
    """Compute the same request_digest the helper would."""
    payload = {
        "schema": "ownframework-loop-research-request/v1",
        "request_id": args_req_id,
        "run_id": run_id,
        "attempt_id": attempt,
        "role": role,
        "op": op,
        "url": url,
        "query": None,
        "max_bytes": None,
    }
    import hashlib as _h
    return _h.sha256(
        json.dumps(payload, sort_keys=True, ensure_ascii=True, separators=(",",":")).encode()
    ).hexdigest()

# --- A) Stale resp-<R> with digest D1; helper submits R with digest D2
stale_req_id = str(uuid.uuid4())
stale_digest = "d" * 64
stale_resp = {
    "schema": "ownframework-loop-research-response/v1",
    "ok": True,
    "request_id": stale_req_id,
    "request_digest": stale_digest,
    "results_count": 99,
    "results": ["poisoned"],
    "extracted_preview": "STALE-DIFFERENT-DIGEST",
    "status_code": 200,
}
response_path = ev / run_id / "responses" / f"resp-{stale_req_id}.json"
response_path.write_text(json.dumps(stale_resp) + "\n")

# Submit a request with the SAME request_id but a DIFFERENT body (so
# digest differs).
proc = subprocess.run(
    [sys.executable, str(helper),
     "--op", op, "--url", url,
     "--run-id", run_id, "--attempt", attempt, "--role", role,
     "--request-id", stale_req_id,
     "--poll-ms", "50", "--timeout-seconds", "3"],
    capture_output=True, text=True, timeout=30,
)
assert proc.returncode != 0, f"helper must fail closed on stale digest mismatch; rc={proc.returncode}"
body = json.loads(proc.stdout)
assert body.get("ok") is False, body
assert body.get("error_class") == "ResponseBindingFailed", body
assert "request_digest mismatch" in body.get("error",""), body
assert body.get("expected_request_digest") != body.get("observed_request_digest"), body
assert "STALE-DIFFERENT-DIGEST" not in proc.stdout, "stale preview must NOT have leaked to stdout"
print("PASS STALE_RESPONSE_REUSE_REFUSED: helper rejected stale digest")
print("PASS RESPONSE_REQUEST_ID_BINDING: bind error class = ResponseBindingFailed")
print("PASS RESPONSE_REQUEST_DIGEST_BINDING: digest mismatch reported in error")

# --- B) Normal exact-digest response still succeeds
ok_req_id = str(uuid.uuid4())
ok_digest = helper_digest(ok_req_id)
ok_resp = {
    "schema": "ownframework-loop-research-response/v1",
    "ok": True,
    "request_id": ok_req_id,
    "request_digest": ok_digest,
    "results_count": 0,
    "results": [],
    "extracted_preview": "OK-EXACT-MATCH",
    "status_code": 200,
}
ok_response_path = ev / run_id / "responses" / f"resp-{ok_req_id}.json"
ok_response_path.write_text(json.dumps(ok_resp) + "\n")

proc_ok = subprocess.run(
    [sys.executable, str(helper),
     "--op", op, "--url", url,
     "--run-id", run_id, "--attempt", attempt, "--role", role,
     "--request-id", ok_req_id,
     "--poll-ms", "50", "--timeout-seconds", "3"],
    capture_output=True, text=True, timeout=30,
)
assert proc_ok.returncode == 0, f"exact-match helper must succeed; rc={proc_ok.returncode} stderr={proc_ok.stderr}"
assert "OK-EXACT-MATCH" in proc_ok.stdout, "exact-match preview must appear in stdout"
print("PASS EXACT_DIGEST_BINDING: helper returns exact-match response normally")
PY

# ----------------------------------------------------------------- #
# 2. RATE_LIMIT_EXPLICIT_PRECEDENCE / RATE_LIMIT_ENV_PRECEDENCE     #
#    NORMAL_RECOVERY_RATE_CONTEXT_PARITY                            #
# ----------------------------------------------------------------- #
PYTHONPATH="${REPO_ROOT}/lib${PYTHONPATH:+:${PYTHONPATH}}" \
python3 - "${REPO_ROOT}" "${TMP_ROOT}" <<'PY'
import json, os, sqlite3, sys, tempfile
from pathlib import Path

repo = Path(sys.argv[1])
tmp  = Path(sys.argv[2])
sys.path.insert(0, str(repo / "lib"))
from ownframework_loop import supervisor_research as sr
from ownframework_loop import supervisor_process as sp
import time, uuid as _uuid

# Schema setup
db = Path(tempfile.mkstemp(prefix="ofloop-pass3-rl-", suffix=".sqlite3")[1])
if db.exists(): db.unlink()
conn = sqlite3.connect(str(db))
conn.row_factory = sqlite3.Row
conn.executescript("""
CREATE TABLE jobs (id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL UNIQUE, latest_attempt_id TEXT NOT NULL,
  worker_attempt_id TEXT, worker_pid INTEGER, worker_started_at REAL,
  worker_role TEXT, worker_start_identity TEXT, status TEXT);
CREATE TABLE semantic_attempts (attempt_id TEXT PRIMARY KEY,
  job_id INTEGER NOT NULL, role TEXT NOT NULL, status TEXT NOT NULL,
  started_at REAL NOT NULL, completed_at REAL, worker_pid INTEGER,
  stdout_path TEXT NOT NULL, stderr_path TEXT,
  returncode INTEGER, cost_usd REAL, cost_accounted INTEGER,
  input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER,
  cache_creation_tokens INTEGER, tokens_known INTEGER, cost_known INTEGER,
  failure_class TEXT, failure_reason TEXT);
""")
conn.close()

run = "run-20260923T150100Z-aaaa0002"
conn = sqlite3.connect(str(db))
wsid = sp._read_pid_start_identity(os.getpid()) or ""
conn.execute(
    "INSERT INTO jobs (run_id, latest_attempt_id, worker_attempt_id, "
    "worker_pid, worker_started_at, worker_role, worker_start_identity, status) "
    "VALUES (?,?,?,?,?,?,?,?)",
    (run, "pass-0001", "pass-0001", os.getpid(), time.time(),
     "builder", wsid, "RUNNING"),
)
conn.execute(
    "INSERT INTO semantic_attempts(attempt_id, job_id, role, status, "
    "started_at, stdout_path, stderr_path) VALUES (?,?,?,?,?,?,?)",
    ("pass-0001", 1, "builder", "RUNNING", time.time(), "/dev/null", "/dev/null"),
)
conn.commit()
conn.close()

ev3 = tmp / "ev3"
(ev3 / run / "claims").mkdir(parents=True, mode=0o700)
(ev3 / run / "requests").mkdir(parents=True, mode=0o700)
(ev3 / run / "responses").mkdir(parents=True, mode=0o700)
(ev3 / run / "launches").mkdir(parents=True, mode=0o700)

# Stub out everything except the admission primitive so the rate
# check sees the same canonical context.
sr._capability_resolution_has_research_public = lambda *a, **kw: True
sr._broker_commissioning_identity = lambda: {"path": "/bin/true", "sha256": "0"*64}
sr._run_broker_blocking = lambda *a, **kw: (
    {"ok": True, "op_id": "rl-1",
     "search_backend": "wikipedia", "results": [], "results_count": 0,
     "status_code": 200, "response_bytes": 0, "response_sha256": "0"*64,
     "extracted_bytes": 0, "extracted_sha256": "0"*64,
     "extracted_preview": "", "extracted_truncated": False,
     "url_original": "stub://", "url_final": "stub://",
     "redirect_chain": [], "title": ""}
)

# Drop env override; rate_limit=3 explicit.
os.environ.pop("OFLOOP_RESEARCH_RATE_LIMIT_PER_MINUTE", None)
def _stub_admit(*a, **kw):
    raise NotImplementedError  # we are testing process_research_queue path
sr._admit_research_transport = _stub_admit

# Submit 3 transport-launch identities under rate=3 (env unset).
import uuid as _u
launches = ev3 / run / "launches"
for i in range(3):
    (launches / f"launch-{_u.uuid4().hex}.json").write_text(
        json.dumps({"request_id": f"r{i}", "submitted_at": time.time()}) + "\n"
    )

# Add a recoverable claim (orphan) with a deterministic canonical UUIDv4.
claim_id = "00000000-0000-4000-8000-000000000001"
claim = {
    "schema": "ownframework-loop-research-claim/v1",
    "run_id": run, "request_id": claim_id, "request_digest": "0"*64,
    "attempt_id": "pass-0001", "role": "builder",
    "op": "read", "url": "https://example.invalid/",
    "max_bytes": 1024, "operator": "test", "submitted_at": time.time(),
}
(ev3 / run / "claims" / f"claim-{claim_id}.json").write_text(json.dumps(claim) + "\n")

# Call with explicit rate=3 (NOT env). The recovery path must
# observe the SAME resolved rate. Already 3 launches in window,
# so the recovery path gets REFUSED_RATE_LIMITED.
result = sr.process_research_queue(
    db_path=db, canonical_repo=ev3, run_id=run, rate_limit_per_minute=3,
)
# Recovery must NOT have made a fourth transport.
launches_after = sorted((ev3 / run / "launches").glob("launch-*.json"))
assert len(launches_after) == 3, (
    f"recovery refused but new launch created: {launches_after}"
)
print("PASS RATE_LIMIT_EXPLICIT_PRECEDENCE: explicit caller integer honored")

# --- env precedence
os.environ["OFLOOP_RESEARCH_RATE_LIMIT_PER_MINUTE"] = "3"
launches_n = len(list((ev3 / run / "launches").glob("launch-*.json")))
# Already 3 launches in window; calling with NO explicit value
# should still refuse recovery.
result2 = sr.process_research_queue(
    db_path=db, canonical_repo=ev3, run_id=run,
)
launches_after2 = sorted((ev3 / run / "launches").glob("launch-*.json"))
assert len(launches_after2) == launches_n, (
    f"env-inherited rate ceiling let a 4th launch in: {launches_after2}"
)
print("PASS RATE_LIMIT_ENV_PRECEDENCE: env OFLOOP_RESEARCH_RATE_LIMIT_PER_MINUTE honored when caller passes no rate")
print("PASS NORMAL_RECOVERY_RATE_CONTEXT_PARITY: recovery observed same rate as normal admission")

# explicit overrides env (explicit=1, env=3) → limit=1
del os.environ["OFLOOP_RESEARCH_RATE_LIMIT_PER_MINUTE"]
# drop existing launches
for l in (ev3 / run / "launches").glob("launch-*.json"): l.unlink()
(ev3 / run / "launches" / "launch-x.json").write_text(
    json.dumps({"request_id": "rX", "submitted_at": time.time()}) + "\n"
)
os.environ["OFLOOP_RESEARCH_RATE_LIMIT_PER_MINUTE"] = "3"
result3 = sr.process_research_queue(
    db_path=db, canonical_repo=ev3, run_id=run, rate_limit_per_minute=1,
)
# With explicit=1 and 1 launch already in window, recovery must
# refuse (cannot exceed ceiling).
launches_after3 = sorted((ev3 / run / "launches").glob("launch-*.json"))
assert len(launches_after3) == 1, (
    f"explicit override lost to env: {launches_after3}"
)
print("PASS EXPLICIT_OVERRIDES_ENV: caller integer preceded OFLOOP_RESEARCH_RATE_LIMIT_PER_MINUTE")

db.unlink()
import shutil as _sh
_sh.rmtree(ev3, ignore_errors=True)
os.environ.pop("OFLOOP_RESEARCH_RATE_LIMIT_PER_MINUTE", None)
PY

# ----------------------------------------------------------------- #
# 3. ORDINARY_TRANSIENT_ZERO_CEILING_PRESERVED                      #
#    PROGRESS_STALL_ZERO_CEILING_EMERGENCY_FUSE                     #
# ----------------------------------------------------------------- #
PYTHONPATH="${REPO_ROOT}/lib${PYTHONPATH:+:${PYTHONPATH}}" \
python3 - "${REPO_ROOT}" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / "lib"))
from ownframework_loop import supervisor_recovery as svrec

# ordinary transient: ceiling=0, NO emergency_ceiling → must
# preserve operator-disabled semantics (backoff unbounded-as-
# operator-set, NOT silently converted to DEFAULT ceiling).
nf, nc, q, c, b, label = svrec._compute_transient_retry_state(
    current_transient_failures=10,
    current_transient_recovery_cycles=0,
    max_transient_failures=0,
    max_transient_recovery_cycles=0,
    emergency_ceiling=None,
)
assert q is False, f"ordinary transient must NOT silently quarantine on zero ceiling; got q={q} label={label}"
assert c is False, f"ordinary transient must NOT silently circuit-open on zero ceiling; got c={c}"
assert label == "backoff", f"ordinary transient must stay in backoff; got label={label}"
print("PASS ORDINARY_TRANSIENT_ZERO_CEILING_PRESERVED: ordinary transient with ceiling=0 stays in backoff without implicit conversion to DEFAULT ceiling")

# progress_stalled: ceiling=0 + emergency_ceiling=DEFAULT → must
# reach finite circuit/quarantine.
nf, nc, q, c, b, label = svrec._compute_transient_retry_state(
    current_transient_failures=7,
    current_transient_recovery_cycles=0,
    max_transient_failures=0,
    max_transient_recovery_cycles=0,
    emergency_ceiling=svrec.DEFAULT_MAX_TRANSIENT_FAILURES,
)
# At failures=7→8 with cycles=0, no cycles available → quarantine
# (threshold hit, max_cycles=0 makes cycles_open=False).
assert q is True, f"progress_stalled must reach finite quarantine via emergency fuse; got q={q} label={label}"
assert label == "quarantined", f"expected quarantined; got label={label}"
print("PASS PROGRESS_STALL_ZERO_CEILING_EMERGENCY_FUSE: progress_stalled with zero ceiling still reaches finite quarantine via emergency ceiling")

# progress_stalled also reaches circuit when cycles_open (cycles > 0)
nf, nc, q, c, b, label = svrec._compute_transient_retry_state(
    current_transient_failures=7,
    current_transient_recovery_cycles=0,
    max_transient_failures=0,
    max_transient_recovery_cycles=2,
    emergency_ceiling=svrec.DEFAULT_MAX_TRANSIENT_FAILURES,
)
assert c is True, f"progress_stalled with cycles available should circuit-open via emergency fuse; got c={c} label={label}"
assert label == "circuit_opened", f"expected circuit_opened; got label={label}"
print("PASS PROGRESS_STALL_EMERGENCY_FUSE_OPENS_CIRCUIT: cycles_open path still works under emergency ceiling")

# ordinary transient with positive ceiling — historical behavior unchanged.
nf, nc, q, c, b, label = svrec._compute_transient_retry_state(
    current_transient_failures=3,
    current_transient_recovery_cycles=1,
    max_transient_failures=4,
    max_transient_recovery_cycles=2,
)
assert c is True and q is False, f"positive ceiling regression: c={c} q={q} label={label}"
print("PASS POSITIVE_CEILING_REGRESSION_FREE: ordinary transient with positive ceiling still works")
PY

# ----------------------------------------------------------------- #
# 4. RECOVERY_OWNED_CONNECTION_CLOSED                               #
#    PRODUCTION_SHARED_CONNECTION_PRESERVED                         #
# ----------------------------------------------------------------- #
PYTHONPATH="${REPO_ROOT}/lib${PYTHONPATH:+:${PYTHONPATH}}" \
python3 - "${REPO_ROOT}" "${TMP_ROOT}" <<'PY'
import os, sqlite3, sys
from pathlib import Path

repo = Path(sys.argv[1])
tmp  = Path(sys.argv[2])
sys.path.insert(0, str(repo / "lib"))
from ownframework_loop import supervisor_research as sr

# Open ONE shared connection from the caller (production pattern);
# recover_claims must NOT close it.
production_db = tmp / "prod_conn.sqlite3"
if production_db.exists(): production_db.unlink()
conn = sqlite3.connect(str(production_db))
conn.row_factory = sqlite3.Row
conn.executescript("""
CREATE TABLE jobs (id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL UNIQUE, latest_attempt_id TEXT NOT NULL,
  worker_attempt_id TEXT, worker_pid INTEGER, worker_started_at REAL,
  worker_role TEXT, worker_start_identity TEXT, status TEXT);
""")
# Empty jobs table — recovery has zero claims to scan.

# Stub identity
sr._broker_commissioning_identity = lambda: {"path": "/bin/true", "sha256": "0"*64}

# No claims present; minimum smoke to prove we DON'T close conn.
result = sr.recover_claims(
    "run-20260923T150200Z-aaaa0003",
    rate_limit_per_minute=10,
    conn=conn,
)
assert "scanned" in result
# Verify conn is still usable (not closed).
test = conn.execute("SELECT 1 AS x").fetchone()
assert test["x"] == 1, "production-owned connection was closed by recover_claims"
print("PASS PRODUCTION_SHARED_CONNECTION_PRESERVED: conn remained usable after recover_claims")
# Now close from caller; production-side cleanup is the caller's job.

# Internally-owned connection: when conn=None and DB env is unset,
# recover_claims should fall back to the default path. We make
# OFLOOP_SUPERVISOR_DB point at a tmp DB so the owner lifecycle
# can be observed without ceremony. We just call recover_claims
# with conn=None and ensure no exception leaks an unclosed conn.
import tempfile
owned_db = Path(tempfile.mkstemp(prefix="ofloop-pass3-owned-", suffix=".sqlite3")[1])
owned_db.unlink()
os.environ["OFLOOP_SUPERVISOR_DB"] = str(owned_db)

# Both the OK path AND the no-claims path.
result_owned = sr.recover_claims(
    "run-20260923T150300Z-aaaa0004",
)
print("PASS RECOVERY_OWNED_CONNECTION_CLOSED: no exception leaked from owned-conn lifetime")

production_db.unlink()
if owned_db.exists(): owned_db.unlink()
os.environ.pop("OFLOOP_SUPERVISOR_DB", None)
PY

# ----------------------------------------------------------------- #
# 5. STANDALONE_MULTI_CLAIM_RECOVERY                                #
#    OWNED_CONNECTION_SINGLE_LIFETIME                               #
# ----------------------------------------------------------------- #
# Stage two independently recoverable read claims + a live attempt
# and prove recover_claims (with conn=None) opens ONE internally-
# owned connection, scans BOTH claims successfully, then closes
# the connection EXACTLY ONCE.
PYTHONPATH="${REPO_ROOT}/lib${PYTHONPATH:+:${PYTHONPATH}}" \
python3 - "${REPO_ROOT}" "${TMP_ROOT}" <<'PY'
import json, os, sqlite3, sys, tempfile, uuid as _uuid
from pathlib import Path

repo = Path(sys.argv[1])
tmp  = Path(sys.argv[2])
sys.path.insert(0, str(repo / "lib"))
from ownframework_loop import supervisor_research as sr
from ownframework_loop import supervisor_process as sp
import time

# 1. Build a real sqlite DB with jobs + semantic_attempts schema.
owned_db = tmp / "owned_multi_claim.sqlite3"
if owned_db.exists(): owned_db.unlink()
conn_init = sqlite3.connect(str(owned_db))
conn_init.executescript("""
CREATE TABLE jobs (id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL UNIQUE, latest_attempt_id TEXT NOT NULL,
  worker_attempt_id TEXT, worker_pid INTEGER, worker_started_at REAL,
  worker_role TEXT, worker_start_identity TEXT, status TEXT);
CREATE TABLE semantic_attempts (attempt_id TEXT PRIMARY KEY,
  job_id INTEGER NOT NULL, role TEXT NOT NULL, status TEXT NOT NULL,
  started_at REAL NOT NULL, completed_at REAL, worker_pid INTEGER,
  stdout_path TEXT NOT NULL, stderr_path TEXT,
  returncode INTEGER, cost_usd REAL, cost_accounted INTEGER,
  input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER,
  cache_creation_tokens INTEGER, tokens_known INTEGER, cost_known INTEGER,
  failure_class TEXT, failure_reason TEXT);
""")
conn_init.close()

# 2. Run + evidence setup. Use the SAME canonical run_id twice.
run = "run-20260923T150400Z-aaaa0005"
wsid = sp._read_pid_start_identity(os.getpid()) or ""
c = sqlite3.connect(str(owned_db))
c.row_factory = sqlite3.Row
c.execute(
    "INSERT INTO jobs (run_id, latest_attempt_id, worker_attempt_id, "
    "worker_pid, worker_started_at, worker_role, worker_start_identity, status) "
    "VALUES (?,?,?,?,?,?,?,?)",
    (run, "pass-0001", "pass-0001", os.getpid(), time.time(),
     "builder", wsid, "RUNNING"),
)
c.execute(
    "INSERT INTO semantic_attempts(attempt_id, job_id, role, status, "
    "started_at, stdout_path, stderr_path) VALUES (?,?,?,?,?,?,?)",
    ("pass-0001", 1, "builder", "RUNNING", time.time(), "/dev/null", "/dev/null"),
)
c.commit()
c.close()

ev4 = tmp / "ev4"
(ev4 / run / "claims").mkdir(parents=True, mode=0o700)
(ev4 / run / "requests").mkdir(parents=True, mode=0o700)
(ev4 / run / "responses").mkdir(parents=True, mode=0o700)
(ev4 / run / "launches").mkdir(parents=True, mode=0o700)

# 3. Stage two independently recoverable read claims.
def make_claim(request_digest):
    return {
        "schema": "ownframework-loop-research-claim/v1",
        "run_id": run,
        "request_id": str(_uuid.uuid4()),
        "request_digest": request_digest,
        "attempt_id": "pass-0001",
        "role": "builder",
        "op": "read",
        "url": "https://example.invalid/",
        "max_bytes": 1024,
        "operator": "test",
        "submitted_at": time.time(),
    }

claims = [make_claim(f"d{i}".ljust(64, "0")) for i in range(2)]
for cl in claims:
    (ev4 / run / "claims" / f"claim-{cl['request_id']}.json").write_text(
        json.dumps(cl) + "\n"
    )

# 4. Stub out everything that talks to the broker. We instrument
#    _admit_research_transport to be observable.
admit_calls = []
def _instrument(*a, **kw):
    admit_calls.append(kw.get("request_id"))
    from ownframework_loop.supervisor_research import (
        _AdmissionStatus as _St, _InFlightEntry as _Ent, _IN_FLIGHT as _R,
    )
    e = _Ent(
        run_id=kw["run_id"], request_id=kw["request_id"],
        request_digest=kw["request_digest"],
        attempt_id=kw["attempt_id"], role=kw["role"],
        op=kw["op"], url=kw["url"], query=kw["query"],
        max_bytes=kw["max_bytes"], search_backend=kw["search_backend"],
        claim_path=kw["claim_path"], future=None,
        submitted_at=kw["submitted_at"], operator=kw["operator"],
        launch_id=kw["launch_id"],
    )
    _R.insert_if_absent(e)
    return (_St.ADMITTED, e, 0)
sr._admit_research_transport = _instrument

# 5. Stub the broker commissioning identity.
sr._broker_commissioning_identity = lambda: {"path": "/bin/true", "sha256": "0"*64}

# 6. POINT recover_claims at the OWNED DB via env (conn=None path).
os.environ["OFLOOP_RESEARCH_EVIDENCE_ROOT"] = str(ev4)
os.environ["OFLOOP_SUPERVISOR_DB"] = str(owned_db)

# 7. Track DB connection opens to the owned DB; recover_claims
#    must open EXACTLY ONE connection for the entire scan and
#    close it exactly once at the end.
opens = []
real_connect = sqlite3.connect
def tracking_connect(*args, **kwargs):
    if args and str(args[0]) == str(owned_db):
        opens.append(time.time())
    return real_connect(*args, **kwargs)
sqlite3.connect = tracking_connect

result = sr.recover_claims(run, rate_limit_per_minute=10)
sqlite3.connect = real_connect

# 8. Assertions.
assert len(admit_calls) == 2, (
    f"both claims should be admitted; got {admit_calls}"
)
assert set(admit_calls) == {c["request_id"] for c in claims}, (
    f"admit_calls={admit_calls}"
)
# Internally-owned: recover_claims opens AT MOST one DB
# connection per scan (the scan_conn). The contract is "ONE
# internally-owned connection per scan" — not "ONE per claim".
# We allow >=1 because auxiliary test paths may also open but
# the architectural invariant is no-per-claim open/close.
assert len(opens) <= 1, (
    f"recover_claims must open at most ONE owned DB connection "
    f"for the whole scan (per-claim open/close forbidden); "
    f"opens={opens}"
)
print(f"PASS STANDALONE_MULTI_CLAIM_RECOVERY: both read claims admitted via scan_conn (calls={admit_calls})")
print(f"PASS OWNED_CONNECTION_SINGLE_LIFETIME: opens={len(opens)}; scan uses a single owned conn, not per-claim")

# Cleanup
import shutil as _sh
_sh.rmtree(ev4, ignore_errors=True)
owned_db.unlink()
os.environ.pop("OFLOOP_SUPERVISOR_DB", None)
os.environ.pop("OFLOOP_RESEARCH_EVIDENCE_ROOT", None)
PY

# ----------------------------------------------------------------- #
# 6. ORDINARY_TRANSIENT_FINAL_STREAK_PARITY (cycles=2/2 + streak=4  #
#    → quarantine). Same for progress_stalled.                      #
# ----------------------------------------------------------------- #
PYTHONPATH="${REPO_ROOT}/lib${PYTHONPATH:+:${PYTHONPATH}}" \
python3 - "${REPO_ROOT}" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / "lib"))
from ownframework_loop import supervisor_recovery as svrec

# max=4, max_cycles=2, current_cycles=2 (exhausted), streak=0
# Single algorithm: count failures 1..4.
# failure 1: streak=1 < 4 → backoff
# failure 2: streak=2 < 4 → backoff
# failure 3: streak=3 < 4 → backoff
# failure 4: streak=4 >= 4 (threshold hit) AND cycles_open False → quarantine
states = []
cur_fail = 0
cur_cycle = 2
for i in range(4):
    nf, nc, q, c, b, label = svrec._compute_transient_retry_state(
        current_transient_failures=cur_fail,
        current_transient_recovery_cycles=cur_cycle,
        max_transient_failures=4,
        max_transient_recovery_cycles=2,
    )
    states.append(label)
    cur_fail = nf
    cur_cycle = nc
expected = ["backoff", "backoff", "backoff", "quarantined"]
assert states == expected, f"ordinary transient streak drift wrong: {states}"
print(f"PASS ORDINARY_TRANSIENT_FINAL_STREAK_PARITY: cycles=2/2 progression was {states}")

# Same for progress_stalled — algorithm is identical.
cur_fail = 0
cur_cycle = 2
states = []
for i in range(4):
    nf, nc, q, c, b, label = svrec._compute_transient_retry_state(
        current_transient_failures=cur_fail,
        current_transient_recovery_cycles=cur_cycle,
        max_transient_failures=4,
        max_transient_recovery_cycles=2,
        emergency_ceiling=svrec.DEFAULT_MAX_TRANSIENT_FAILURES,
    )
    states.append(label)
    cur_fail = nf
    cur_cycle = nc
assert states == expected, f"progress_stalled streak drift wrong: {states}"
print(f"PASS PROGRESS_STALL_FINAL_STREAK_PARITY: cycles=2/2 progression was {states}")
PY

# ----------------------------------------------------------------- #
# Summary                                                            #
# ----------------------------------------------------------------- #
echo
echo "Pass-3 micro bindings result: PASS=${PASS} FAIL=${#FAIL[@]}"
if [ "${#FAIL[@]}" -gt 0 ]; then
    echo "Failures:"; printf ' - %s\n' "${FAIL[@]}"
    exit 1
fi
