#!/usr/bin/env bash
# v0.9.1 terminal source-closure regressions.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PYTHONPATH="$ROOT/lib${PYTHONPATH:+:$PYTHONPATH}"

python3 -B - <<'PY'
import json
import tempfile
from pathlib import Path

from ownframework_loop import capabilities, supervisor

tmp = Path(tempfile.mkdtemp(prefix="ofloop-acceptance-"))

def repo(name):
    p = tmp / name
    p.mkdir()
    return p

def wo_for(p, rid):
    sem = p / "semantic.json"
    sem.write_text("{}\n", encoding="utf-8")
    return {
        "decision": "BUILD", "role": "builder",
        "canonical_repo": str(p), "run_id": rid,
        "worktree": str(p), "semantic_path": str(sem),
    }

real_claim = supervisor.dispatch_mod.claim_next
real_ready = supervisor.dispatch_mod.semantic_result_ready
real_parse = supervisor.packet_mod.parse_packet_file
real_receipt = capabilities.read_resolution_receipt
real_finalize = supervisor.dispatch_mod.finalize_work_order

try:
    # A. Failed-provider crash after accounting but before failure publication:
    # durable cost is exactly once, but no acceptance means replay fails closed.
    p = repo("failed-crash")
    db = tmp / "failed.sqlite3"
    rid = "run-failed-crash"
    calls = {"runner": 0}
    @supervisor.register_runner
    class FailedCrashRunner:
        runner_id = "terminal-failed-crash"
        requires_capability_receipt = True
        def preflight(self):
            return supervisor.RunnerReadiness(True)
        def run(self, *args, **kwargs):
            calls["runner"] += 1
            return supervisor.RunnerResult(
                ok=False, returncode=1, cost_usd=1.25,
                stdout="provider failed", stderr="provider failed",
                cost_known=True, tokens_known=True,
            )
    supervisor.enqueue(canonical_repo=p, run_id=rid, db_path=db, runner=FailedCrashRunner.runner_id)
    work = wo_for(p, rid)
    ready_count = {"n": 0}
    def first_not_ready(_wo):
        ready_count["n"] += 1
        return (False, "not-yet") if ready_count["n"] == 1 else (True, "ready")
    supervisor.dispatch_mod.claim_next = lambda **kwargs: dict(work)
    supervisor.dispatch_mod.semantic_result_ready = first_not_ready
    supervisor.packet_mod.parse_packet_file = lambda path: ({}, "")
    class CrashWindow(BaseException):
        pass
    capabilities.read_resolution_receipt = lambda *a, **k: (_ for _ in ()).throw(CrashWindow())
    try:
        supervisor.run_one(db_path=db)
        raise AssertionError("failed-provider accounting crash did not fire")
    except CrashWindow:
        pass
    with supervisor._connect(db) as conn:
        job = conn.execute("SELECT * FROM jobs WHERE run_id=?", (rid,)).fetchone()
        attempt = conn.execute(
            "SELECT * FROM semantic_attempts WHERE job_id=?", (int(job["id"]),)
        ).fetchone()
        assert int(attempt["cost_accounted"]) == 1, dict(attempt)
        assert int(attempt["semantic_accepted"]) == 0, dict(attempt)
        assert attempt["failure_class"] is None and attempt["failure_reason"] is None, dict(attempt)
        assert abs(float(job["total_cost_usd"]) - 1.25) < 1e-9, dict(job)
        # This fake runner has no child process. Model the durable ownership
        # snapshot a real on_start publication leaves so replacement-supervisor
        # crash reconciliation can observe a dead exact attempt owner.
        conn.execute(
            """UPDATE jobs SET worker_pid=99999999, worker_started_at=1,
               worker_pgid=99999999, worker_deadline_at=1,
               worker_start_identity='synthetic-dead-owner',
               worker_role='builder', worker_attempt_id=?
               WHERE id=?""",
            (attempt["attempt_id"], int(job["id"])),
        )
        conn.commit()
    supervisor.dispatch_mod.semantic_result_ready = lambda _wo: (True, "ready")
    capabilities.read_resolution_receipt = lambda *a, **k: {
        "requested_runner_profile": {"model": "model-a"}
    }
    replay = supervisor.run_one(db_path=db)
    assert replay["action"] == "QUARANTINED", replay
    assert replay["reason"] == "semantic_replay_attempt_not_accepted", replay
    assert calls["runner"] == 1, calls
    with supervisor._connect_readonly(db) as conn:
        job = conn.execute("SELECT * FROM jobs WHERE run_id=?", (rid,)).fetchone()
        assert abs(float(job["total_cost_usd"]) - 1.25) < 1e-9, dict(job)

    # B. Successful result + valid strict model/receipt publishes acceptance
    # before finalization. A crash in finalizer can replay with zero new cost.
    p2 = repo("accepted-crash")
    db2 = tmp / "accepted.sqlite3"
    rid2 = "run-accepted-crash"
    calls2 = {"runner": 0, "finalizer": 0}
    @supervisor.register_runner
    class AcceptedCrashRunner:
        runner_id = "terminal-accepted-crash"
        requires_capability_receipt = True
        def preflight(self):
            return supervisor.RunnerReadiness(True)
        def run(self, *args, **kwargs):
            calls2["runner"] += 1
            return supervisor.RunnerResult(
                ok=True, returncode=0, cost_usd=2.5,
                stdout="ok", stderr="", cost_known=True,
                tokens_known=True, effective_model="model-a",
            )
    supervisor.enqueue(canonical_repo=p2, run_id=rid2, db_path=db2, runner=AcceptedCrashRunner.runner_id)
    work2 = wo_for(p2, rid2)
    ready2 = {"n": 0}
    def acceptance_ready(_wo):
        ready2["n"] += 1
        return (False, "not-yet") if ready2["n"] == 1 else (True, "ready")
    supervisor.dispatch_mod.claim_next = lambda **kwargs: dict(work2)
    supervisor.dispatch_mod.semantic_result_ready = acceptance_ready
    capabilities.read_resolution_receipt = lambda *a, **k: {
        "requested_runner_profile": {"model": "model-a"}
    }
    def crash_finalizer(*a, **k):
        raise CrashWindow()
    supervisor.dispatch_mod.finalize_work_order = crash_finalizer
    try:
        supervisor.run_one(db_path=db2)
        raise AssertionError("accepted pre-finalizer crash did not fire")
    except CrashWindow:
        pass
    with supervisor._connect(db2) as conn:
        job = conn.execute("SELECT * FROM jobs WHERE run_id=?", (rid2,)).fetchone()
        attempt = conn.execute(
            "SELECT * FROM semantic_attempts WHERE job_id=?", (int(job["id"]),)
        ).fetchone()
        assert int(attempt["semantic_accepted"]) == 1, dict(attempt)
        assert int(attempt["cost_accounted"]) == 1, dict(attempt)
        assert abs(float(job["total_cost_usd"]) - 2.5) < 1e-9, dict(job)
        conn.execute(
            """UPDATE jobs SET worker_pid=99999999, worker_started_at=1,
               worker_pgid=99999999, worker_deadline_at=1,
               worker_start_identity='synthetic-dead-owner',
               worker_role='builder', worker_attempt_id=?
               WHERE id=?""",
            (attempt["attempt_id"], int(job["id"])),
        )
        conn.commit()

    supervisor.dispatch_mod.semantic_result_ready = lambda _wo: (True, "ready")
    def replay_finalizer(*a, **k):
        calls2["finalizer"] += 1
        return {"finalized": True}
    supervisor.dispatch_mod.finalize_work_order = replay_finalizer
    replay2 = supervisor.run_one(db_path=db2)
    assert replay2["ok"] is True, replay2
    assert calls2 == {"runner": 1, "finalizer": 1}, calls2
    with supervisor._connect_readonly(db2) as conn:
        job = conn.execute("SELECT * FROM jobs WHERE run_id=?", (rid2,)).fetchone()
        assert abs(float(job["total_cost_usd"]) - 2.5) < 1e-9, dict(job)
    # Model the deterministic core's post-finalization state advancement: the
    # same accepted artifact is no longer an actionable semantic work order.
    supervisor.dispatch_mod.claim_next = lambda **kwargs: {
        "decision": "TERMINAL", "run_id": rid2, "canonical_repo": str(p2)
    }
    supervisor.run_one(db_path=db2)
    assert calls2["finalizer"] == 1, calls2

    # C. Strict-model substitution: cost may be durable, but acceptance is not.
    p3 = repo("strict-sub")
    db3 = tmp / "strict.sqlite3"
    rid3 = "run-strict-sub"
    @supervisor.register_runner
    class StrictSubRunner:
        runner_id = "terminal-strict-sub"
        requires_capability_receipt = True
        def preflight(self):
            return supervisor.RunnerReadiness(True)
        def run(self, *args, **kwargs):
            return supervisor.RunnerResult(
                ok=True, returncode=0, cost_usd=0.75, stdout="ok", stderr="",
                cost_known=True, tokens_known=True, effective_model="model-b",
            )
    supervisor.enqueue(canonical_repo=p3, run_id=rid3, db_path=db3, runner=StrictSubRunner.runner_id)
    work3 = wo_for(p3, rid3)
    supervisor.dispatch_mod.claim_next = lambda **kwargs: dict(work3)
    supervisor.dispatch_mod.semantic_result_ready = lambda _wo: (False, "not-yet")
    capabilities.read_resolution_receipt = lambda *a, **k: {
        "requested_runner_profile": {"model": "model-a"}
    }
    out3 = supervisor.run_one(db_path=db3)
    assert out3["failure_reason"] == "runner_profile_model_substitution", out3
    with supervisor._connect_readonly(db3) as conn:
        job = conn.execute("SELECT * FROM jobs WHERE run_id=?", (rid3,)).fetchone()
        a3 = conn.execute("SELECT * FROM semantic_attempts WHERE job_id=?", (int(job["id"]),)).fetchone()
        assert int(a3["cost_accounted"]) == 1 and int(a3["semantic_accepted"]) == 0, dict(a3)

    # D. Missing/invalid capability receipt: same refusal.
    p4 = repo("bad-receipt")
    db4 = tmp / "receipt.sqlite3"
    rid4 = "run-bad-receipt"
    @supervisor.register_runner
    class BadReceiptRunner:
        runner_id = "terminal-bad-receipt"
        requires_capability_receipt = True
        def preflight(self):
            return supervisor.RunnerReadiness(True)
        def run(self, *args, **kwargs):
            return supervisor.RunnerResult(
                ok=True, returncode=0, cost_usd=0.5, stdout="ok", stderr="",
                cost_known=True, tokens_known=True, effective_model="model-a",
            )
    supervisor.enqueue(canonical_repo=p4, run_id=rid4, db_path=db4, runner=BadReceiptRunner.runner_id)
    work4 = wo_for(p4, rid4)
    supervisor.dispatch_mod.claim_next = lambda **kwargs: dict(work4)
    supervisor.dispatch_mod.semantic_result_ready = lambda _wo: (False, "not-yet")
    def missing_receipt(*a, **k):
        raise capabilities.CapabilityResolutionError("synthetic missing receipt")
    capabilities.read_resolution_receipt = missing_receipt
    out4 = supervisor.run_one(db_path=db4)
    assert out4["failure_reason"] == "semantic_attempt_capability_receipt_invalid", out4
    with supervisor._connect_readonly(db4) as conn:
        job = conn.execute("SELECT * FROM jobs WHERE run_id=?", (rid4,)).fetchone()
        a4 = conn.execute("SELECT * FROM semantic_attempts WHERE job_id=?", (int(job["id"]),)).fetchone()
        assert int(a4["cost_accounted"]) == 1 and int(a4["semantic_accepted"]) == 0, dict(a4)
finally:
    supervisor.dispatch_mod.claim_next = real_claim
    supervisor.dispatch_mod.semantic_result_ready = real_ready
    supervisor.packet_mod.parse_packet_file = real_parse
    capabilities.read_resolution_receipt = real_receipt
    supervisor.dispatch_mod.finalize_work_order = real_finalize

print("SEMANTIC_REPLAY_ACCEPTANCE_CRASH_WINDOW=PASS")
PY

python3 -B - <<'PY'
import builtins
import tempfile
from pathlib import Path
from ownframework_loop import secrets_v2

root = Path(tempfile.mkdtemp(prefix="ofloop-secret-redacted-"))
missing = root / "missing.txt"
try:
    secrets_v2.scan_path_for_secrets_redacted(missing)
    raise AssertionError("missing file encoded as clean scan")
except secrets_v2.SecretScanIncomplete:
    pass

unreadable = root / "unreadable.txt"
unreadable.write_text("clean", encoding="utf-8")
real_open = builtins.open
def denied(file, *args, **kwargs):
    if Path(file) == unreadable:
        raise PermissionError("synthetic unreadable")
    return real_open(file, *args, **kwargs)
builtins.open = denied
try:
    try:
        secrets_v2.scan_path_for_secrets_redacted(unreadable)
        raise AssertionError("unreadable file encoded as clean scan")
    except secrets_v2.SecretScanIncomplete:
        pass
finally:
    builtins.open = real_open

oversize = root / "oversize.bin"
oversize.write_bytes(b"x" * (secrets_v2.MAX_INPUT_BYTES + 1))
try:
    secrets_v2.scan_path_for_secrets_redacted(oversize)
    raise AssertionError("truncated scan encoded as complete")
except secrets_v2.SecretScanIncomplete:
    pass

clean = root / "clean.txt"
clean.write_text("ordinary text\n", encoding="utf-8")
assert secrets_v2.scan_path_for_secrets_redacted(clean) == []

secret = root / "secret.txt"
literal = "ghp_" + ("A" * 40)
secret.write_text(literal + "\n", encoding="utf-8")
findings = secrets_v2.scan_path_for_secrets_redacted(secret)
assert findings and any(f["severity"] == "hard" for f in findings), findings
assert literal not in repr(findings), findings
print("REDACTED_SECRET_SCAN_FAIL_CLOSED=PASS")
PY

python3 -B - <<'PY'
import tempfile
from pathlib import Path
from ownframework_loop import guards

missing = Path(tempfile.mkdtemp(prefix="ofloop-legacy-guard-scan-")) / "missing.txt"
try:
    guards.scan_path_for_secrets(missing)
    raise AssertionError("legacy guard secret helper encoded read failure as clean")
except OSError:
    pass
print("LEGACY_GUARD_SECRET_SCAN_FAIL_CLOSED=PASS")
PY

TMP="$(mktemp -d -t ofloop-terminal-preflight-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP
mkdir -p "$TMP/repo"
XDG_STATE_HOME="$TMP/state" python3 -B - "$TMP" <<'PY'
import json, os, sys
from pathlib import Path
from ownframework_loop import capabilities, capability_binding, runner_profiles, runtime_env

root = Path(sys.argv[1])
manifest = runner_profiles.default_manifest_path()
manifest.parent.mkdir(parents=True, exist_ok=True)
manifest.write_text(json.dumps({
    "schema": runner_profiles.MANIFEST_SCHEMA,
    "profiles": {
        "strict": {
            "provider": "claude-code",
            "model": "claude-sonnet-4-6",
            "effort": "high",
        }
    },
}), encoding="utf-8")
manifest.chmod(0o600)
written = runner_profiles.write_effort_attestation(
    name="strict", provider="claude-code",
    model="claude-sonnet-4-6", effort="high",
)
(root / "attestation.sha").write_text(written["attestation_sha256"], encoding="utf-8")
profile = runner_profiles.resolve_profile("strict", provider="claude-code")
att = runner_profiles.verify_effort_attestation(profile)
bound = dict(profile); bound["effort_attestation"] = att
resolution = capabilities.resolve_capabilities(
    ["toolchain.python"], canonical_repo=root / "repo", role="builder",
    repo_cache_root=runtime_env.repo_tool_cache_dir(root / "repo"),
    ephemeral_cache_root=root / "cache",
    packet_network_allowlist=[],
)
projection = capability_binding.stable_projection(resolution, bound)
assert projection["requested_runner_profile"]["effort_attestation"]["attestation_sha256"] == written["attestation_sha256"]

# Runtime drift invalidates the same identity launch and preflight both verify.
real_fp = capabilities.semantic_runtime_fingerprint
capabilities.semantic_runtime_fingerprint = lambda: "d" * 64
try:
    try:
        runner_profiles.verify_effort_attestation(profile)
        raise AssertionError("runtime-drifted assertion accepted")
    except runner_profiles.RunnerProfileError:
        pass
finally:
    capabilities.semantic_runtime_fingerprint = real_fp
PY

XDG_STATE_HOME="$TMP/state" python3 -B -m ownframework_loop.cli capabilities preflight   "$TMP/repo" toolchain.python --runner-profile strict >"$TMP/preflight.json"
python3 -B - "$TMP" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
doc = json.loads((root / "preflight.json").read_text())
expected = (root / "attestation.sha").read_text()
assert doc["ok"] is True, doc
assert doc["launch_parity"] is True, doc
assert doc["diagnostic_override"] is False, doc
assert doc["runner_profile"]["effort_assertion_sha256"] == expected, doc
assert doc["runner_profile"]["effective_effort_proven"] is False, doc
PY

PROFILE_MANIFEST="$TMP/state/ownframework-loop/runner-profiles.json"
XDG_STATE_HOME="$TMP/state" python3 -B -m ownframework_loop.cli capabilities preflight   "$TMP/repo" toolchain.python --runner-profile strict   --profile-manifest "$PROFILE_MANIFEST" >"$TMP/preflight-override.json"
python3 -B - "$TMP/preflight-override.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
assert doc["ok"] is True, doc
assert doc["launch_parity"] is False, doc
assert doc["diagnostic_override"] is True, doc
assert doc["runner_profile"]["effective_effort_proven"] is False, doc
PY
echo "PREFLIGHT_LAUNCH_PROVENANCE_PARITY=PASS"

python3 -B - <<'PY'
import hashlib
import json
import tempfile
from pathlib import Path
from ownframework_loop import capabilities

root = Path(tempfile.mkdtemp(prefix="ofloop-browser-version-"))
asset = root / "asset"; asset.mkdir()
(asset / "chromium.bin").write_bytes(b"browser")
evidence = root / "evidence"
client = {
    "package_root": "/commissioned/playwright",
    "package_tree_sha256": "a" * 64,
    "distribution_version": "9.9.9",
}
real_client = capabilities.playwright_client_identity
capabilities.playwright_client_identity = lambda: dict(client)
try:
    merkle = capabilities.browser_asset_merkle_sha256(asset)
    try:
        capabilities.write_browser_runtime_proof(
            asset_root=str(asset), asset_merkle_sha256=merkle,
            playwright_client=client, playwright_version="0.0.0",
            browser_version="123", evidence_dir=evidence,
        )
        raise AssertionError("contradictory Playwright version proof was written")
    except capabilities.CapabilityResolutionError as exc:
        assert "distribution identity" in str(exc), exc

    proof = capabilities.write_browser_runtime_proof(
        asset_root=str(asset), asset_merkle_sha256=merkle,
        playwright_client=client, playwright_version="9.9.9",
        browser_version="123", evidence_dir=evidence,
    )
    assert proof["playwright_version"] == client["distribution_version"]
    path = Path(proof["proof_path"])
    doc = json.loads(path.read_text())
    doc["playwright_version"] = "0.0.0"
    body = {k: v for k, v in doc.items() if k != "proof_sha256"}
    doc["proof_sha256"] = hashlib.sha256(
        json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()
    ).hexdigest()
    path.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")
    ok, reason, _ = capabilities._browser_runtime_proof_status(
        "browser.playwright.chromium",
        evidence_dir=evidence, expected_asset_root=asset,
    )
    assert not ok and "version identity mismatch" in reason, (ok, reason)
finally:
    capabilities.playwright_client_identity = real_client
print("BROWSER_PROOF_VERSION_CONSISTENCY=PASS")
PY

echo "OF_LOOP_V091_TERMINAL_SOURCE_CLOSURE=PASS"
