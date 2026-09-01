#!/usr/bin/env bash
# Final source-closure crash/negative regressions (version-neutral).
#
# Focused proofs for the closing hardening sweep, each exercising a crash
# boundary or a negative authority case against the real deterministic core:
#   1. Crash-atomic funded repair: no crash window can expose an unfunded
#      claimable CHANGES_REQUESTED; cap exhaustion seals BLOCKED atomically;
#      reconciliation completes a crashed post-hook without double-funding.
#   2. save() is creation-only; existing-state mutation is impossible.
#   3. Structural STATE ownership: generic extras channel closed for all
#      owners, funded repair has no extras parameter at all, atomic_patch
#      accepts only enlisted non-authoritative fields.
#   4. Symlinked capability/profile authority manifests are rejected.
#   5. Pre-provider runtime/evidence drift is refused by the final re-proof.
#   6. First capability binding is allowed after proven pre-provider attempts
#      (including worker_ownership_not_published) and refused after a
#      provider-reachable attempt.
#   7. Effective model truth: singular model only when provable; the full
#      provider-reported usage is preserved and never inferred away.
#
# No model is called; synthetic fixtures are schema-correct.

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

OFLOOP="$OFLOOP_BIN"
export PYTHONPATH="$LIB_DIR${PYTHONPATH:+:$PYTHONPATH}"

# ---------- 1. crash-atomic funded repair (SINGLE) ----------
T="$(make_tmp_repo)"
mkdir -p "$T/src" && echo "1" > "$T/src/a.py"
git -C "$T" add . && git -C "$T" commit -m "src" >/dev/null
"$OFLOOP" spec new "$T" "crash-atomic-repair" >/dev/null
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
  "title": "crash-atomic-repair",
  "target": {"repo": "$T", "branch": "master", "classification": "local_only"},
  "acceptance_criteria": [{"id": "AC-1", "text": "ok"}],
  "non_goals": [],
  "allowed_paths": ["src/"],
  "protected_paths": [".ownframework-loop/"],
  "work_units": [{"id": "UNIT-1", "title": "u", "scope": "s"}],
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
execution_start.ensure_executable(canonical_repo=Path(sys.argv[1]), run_id=sys.argv[2], actor="test", binding_method="build_start")
PY
"$OFLOOP" build claim "$T" "$RID" >/dev/null

# 1a. Funded repair is ONE atomic mutation: state + repair_round commit together.
python3 - "$T" "$RID" <<'PY'
import sys, os, json
from pathlib import Path
sys.path.insert(0, os.environ.get("OFLOOP_LIB"))
from ownframework_loop import state as state_mod, packet as packet_mod
repo, rid = Path(sys.argv[1]), sys.argv[2]
meta, _ = packet_mod.parse_packet_file(state_mod.run_dir(repo, rid) / "WORK_PACKET.md")
res = state_mod.transition_funded_repair(
    repo, rid, packet=meta, actor="test", commit_sha="",
    allowed_sources=frozenset({"BUILDING", "REVIEWING"}),
    claimed_reason="test funded repair",
)
assert res["state"] == "CHANGES_REQUESTED", res
assert res["repair_claimed"] is True, res
assert res["repair_round"] == 1, res
# The durable state shows the funding landed atomically with the transition.
cur = state_mod.load_verified(repo, rid)
assert cur["state"] == "CHANGES_REQUESTED" and int(cur["repair_round"]) == 1, cur["state"]
print("1a atomic funded repair ok")
PY
pass "funded repair transition + entitlement are one atomic mutation"

# 1b. Simulated crash before the post-hook: reconcile completes it WITHOUT
#     double-funding, so no unfunded CHANGES_REQUESTED is ever claimable.
python3 - "$T" "$RID" <<'PY'
import sys, os
from pathlib import Path
sys.path.insert(0, os.environ.get("OFLOOP_LIB"))
from ownframework_loop import reconcile, state as state_mod
repo, rid = Path(sys.argv[1]), sys.argv[2]
rr = reconcile.reconcile_run(canonical_repo=repo, run_id=rid)
assert rr["ok"], rr
assert any(a == "complete_single_mode_changes_requested_post_hook" for a in rr["actions"]), rr["actions"]
cur = state_mod.load_verified(repo, rid)
assert cur["state"] == "READY_TO_BUILD", cur["state"]
# Repair round was NOT double-funded by reconciliation.
assert int(cur["repair_round"]) == 1, cur["repair_round"]
print("1b reconcile post-hook completion ok")
PY
pass "crashed funded-repair post-hook reconciles without double-funding"

# 1c. Cap exhaustion seals BLOCKED atomically; no claimable CHANGES_REQUESTED.
T2="$(make_tmp_repo)"
mkdir -p "$T2/src" && echo "1" > "$T2/src/a.py"
git -C "$T2" add . && git -C "$T2" commit -m "src" >/dev/null
"$OFLOOP" spec new "$T2" "cap-exhaust" >/dev/null
RID2="$(ls -1t "$T2/.ownframework-loop" | head -n1)"
PP2="$T2/.ownframework-loop/$RID2/WORK_PACKET.md"
sed "s#\"max_repair_rounds\": 3#\"max_repair_rounds\": 1#; s#$T#$T2#; s#crash-atomic-repair#cap-exhaust#" "$PP" > "$PP2"
python3 - "$T2" "$RID2" <<'PY'
import sys, os
from pathlib import Path
sys.path.insert(0, os.environ.get("OFLOOP_LIB"))
from ownframework_loop import execution_start
execution_start.ensure_executable(canonical_repo=Path(sys.argv[1]), run_id=sys.argv[2], actor="test", binding_method="build_start")
PY
"$OFLOOP" build claim "$T2" "$RID2" >/dev/null
python3 - "$T2" "$RID2" <<'PY'
import sys, os
from pathlib import Path
sys.path.insert(0, os.environ.get("OFLOOP_LIB"))
from ownframework_loop import state as state_mod, packet as packet_mod
repo, rid = Path(sys.argv[1]), sys.argv[2]
meta, _ = packet_mod.parse_packet_file(state_mod.run_dir(repo, rid) / "WORK_PACKET.md")
# Fund the single allowed round.
r1 = state_mod.transition_funded_repair(repo, rid, packet=meta, actor="t", commit_sha="",
    allowed_sources=frozenset({"BUILDING","REVIEWING"}), claimed_reason="r1")
assert r1["state"] == "CHANGES_REQUESTED" and r1["repair_claimed"], r1
# Move back to a fundable source state, then exhaust the envelope.
state_mod.transition(repo, rid, to_state="READY_TO_BUILD", actor="t", reason="post-hook")
state_mod.transition(repo, rid, to_state="BUILDING", actor="t", reason="claim")
r2 = state_mod.transition_funded_repair(repo, rid, packet=meta, actor="t", commit_sha="",
    allowed_sources=frozenset({"BUILDING","REVIEWING"}), claimed_reason="r2")
assert r2["state"] == "BLOCKED", r2
assert r2["repair_claimed"] is False, r2
cur = state_mod.load_verified(repo, rid)
assert cur["state"] == "BLOCKED", cur["state"]
print("1c cap exhaustion seals BLOCKED atomically ok")
PY
pass "repair cap exhaustion seals BLOCKED atomically (no unfunded claimable state)"

# ---------- 2. save() is creation-only: no existing-state mutation at all ----------
python3 - "$T" "$RID" <<'PY'
import sys, os
from pathlib import Path
sys.path.insert(0, os.environ.get("OFLOOP_LIB"))
from ownframework_loop import state as state_mod
repo, rid = Path(sys.argv[1]), sys.argv[2]
cur = state_mod.load_verified(repo, rid)
# Attempt to smuggle a state change through save(): must be refused.
bad = dict(cur); bad["state"] = "APPROVED"
try:
    state_mod.save(repo, rid, bad)
    raise SystemExit("save() changed state")
except ValueError:
    pass
# Attempt to smuggle a run_id change: must be refused.
bad2 = dict(cur); bad2["run_id"] = "run-other"
try:
    state_mod.save(repo, rid, bad2)
    raise SystemExit("save() changed run_id")
except ValueError:
    pass
# Creation-only is structural: even an EXACT identity-preserving save of the
# current document is refused once durable state exists. Later mutations go
# through the transition owners with typed parameters, never through save().
exact = dict(cur)
try:
    state_mod.save(repo, rid, exact)
    raise SystemExit("save() accepted an existing-state write")
except ValueError:
    pass
assert state_mod.load_verified(repo, rid)["state"] == cur["state"]
print("2 creation-only save ok")
PY
pass "save() is creation-only; existing-state mutation is impossible"

# ---------- 3. structural STATE ownership: no generic extras channel ----------
python3 - "$T" "$RID" <<'PY'
import inspect, sys, os
from pathlib import Path
sys.path.insert(0, os.environ.get("OFLOOP_LIB"))
from ownframework_loop import state as state_mod
repo, rid = Path(sys.argv[1]), sys.argv[2]
# Every protocol-authoritative field is refused as a transition extra.
for field in sorted(state_mod.STATE_OWNER_FIELDS):
    try:
        state_mod.transition(repo, rid, to_state="READY_TO_BUILD", actor="t",
                             reason="x", extras={field: "evil"})
        raise SystemExit(f"extras overrode owner field {field}")
    except ValueError:
        pass
# Structurally, NO generic extras can mutate STATE.json at all: even an
# unknown non-owner key is refused (allow-list, not blacklist).
try:
    state_mod.transition(repo, rid, to_state="READY_TO_BUILD", actor="t",
                         reason="x", extras={"diagnostic_note": "evil"})
    raise SystemExit("generic extras accepted a foreign key")
except ValueError:
    pass
# The funded-repair owner has NO generic extras channel in its signature.
fr_params = inspect.signature(state_mod.transition_funded_repair).parameters
assert "extras" not in fr_params, "funded repair still exposes generic extras"
assert "identical_finding_streak" in fr_params
assert "last_must_fix_fingerprint" in fr_params
# atomic_patch field classes: owner fields refused, foreign keys refused,
# empty patches refused.
for field in ("state", "repair_round", "program", "last_candidate_sha",
              "no_progress_streak"):
    try:
        state_mod.atomic_patch(repo, rid, {field: "evil"}, actor="t", reason="x")
        raise SystemExit(f"atomic_patch wrote owner field {field}")
    except ValueError:
        pass
try:
    state_mod.atomic_patch(repo, rid, {"unlisted": 1}, actor="t", reason="x")
    raise SystemExit("atomic_patch accepted a non-enlisted field")
except ValueError:
    pass
try:
    state_mod.atomic_patch(repo, rid, {}, actor="t", reason="x")
    raise SystemExit("atomic_patch accepted an empty patch")
except ValueError:
    pass
assert state_mod.load_verified(repo, rid)["state"] is not None
print("3 structural state ownership ok")
PY
pass "STATE ownership is structural: extras channel closed, owners typed, patch field-classed"

# ---------- 4. symlinked authority manifests rejected ----------
python3 - <<'PY'
import os, sys, tempfile, json
from pathlib import Path
sys.path.insert(0, os.environ.get("OFLOOP_LIB"))
from ownframework_loop import capabilities, runner_profiles
tmp = Path(tempfile.mkdtemp(prefix="ofl_symlink_"))
# Build a real manifest, then point a SYMLINK at it and load via the symlink.
real = tmp / "real-host.json"
real.write_text(json.dumps({"schema": capabilities.HOST_MANIFEST_SCHEMA, "capabilities": {}}))
link = tmp / "link-host.json"
os.symlink(real, link)
try:
    capabilities._load_host_manifest(link)
    raise SystemExit("symlinked host manifest accepted")
except capabilities.CapabilityResolutionError:
    pass
realp = tmp / "real-profiles.json"
realp.write_text(json.dumps({"schema": runner_profiles.MANIFEST_SCHEMA, "profiles": {}}))
linkp = tmp / "link-profiles.json"
os.symlink(realp, linkp)
try:
    runner_profiles._load_manifest(linkp)
    raise SystemExit("symlinked profile manifest accepted")
except runner_profiles.RunnerProfileError:
    pass
print("4 symlinked manifest rejection ok")
PY
pass "symlinked capability/profile authority manifests are rejected"

# ---------- 5. pre-provider runtime/evidence drift is refused ----------
python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ.get("OFLOOP_LIB"))
from ownframework_loop import capabilities
# Build a resolution and then mutate the bound runtime fingerprint: the final
# re-proof must refuse even though every other artifact is intact.
res = {
    "schema": capabilities.SCHEMA,
    "capability_contract_revision": capabilities.CAPABILITY_CONTRACT_REVISION,
    "requested": [],
    "resolved": [],
    "network_domains": [],
    "filesystem": {"allowRead": [], "allowWrite": []},
    "environment": {},
    "path_prepend": [],
    "sandbox_network": {},
    "stable_filesystem": {"allowRead": [], "allowWrite": []},
    "host_manifest_path": None,
    "host_manifest_sha256": None,
    "semantic_runtime_fingerprint": "deadbeef" * 8,
    "platform_identity": capabilities.platform_identity(),
}
try:
    capabilities.verify_resolution_integrity(res)
    raise SystemExit("runtime fingerprint drift accepted")
except capabilities.CapabilityResolutionError:
    pass
# A resolution bound to the CURRENT fingerprint passes the runtime re-proof.
res["semantic_runtime_fingerprint"] = capabilities.semantic_runtime_fingerprint()
capabilities.verify_resolution_integrity(res)
print("5 runtime drift re-proof ok")
PY
pass "final pre-provider re-proof refuses runtime fingerprint drift"

# ---------- 6. capability binding allowance after pre-provider attempts ----------
python3 - <<'PY'
import os, sys, tempfile
from pathlib import Path
sys.path.insert(0, os.environ.get("OFLOOP_LIB"))
from ownframework_loop import supervisor
db = Path(tempfile.mkdtemp(prefix="ofl_bind_")) / "supervisor.sqlite3"
conn = supervisor._connect(db)
conn.execute("INSERT INTO jobs (repo, run_id, runner, status, created_at, updated_at) VALUES ('/r','run-a','claude-code','QUEUED',0,0)")
job_id = conn.execute("SELECT id FROM jobs WHERE run_id='run-a'").fetchone()[0]
def add_attempt(reason, status="FAILED", cost=0.0, accounted=1):
    conn.execute(
        "INSERT INTO semantic_attempts (attempt_id, job_id, role, status, started_at, stdout_path, stderr_path, failure_reason, cost_usd, cost_accounted) VALUES (?,?,?,?,?,'/o','/e',?,?,?)",
        (f"att-{reason}", job_id, "builder", status, 0, reason, cost, accounted),
    )
    conn.commit()
# No attempts: binding creation allowed.
assert supervisor._capability_binding_creation_allowed(conn, job_id) is True
# Proven pre-provider attempts (incl. worker_ownership_not_published): allowed.
add_attempt("worker_launch_failed")
assert supervisor._capability_binding_creation_allowed(conn, job_id) is True
add_attempt("worker_ownership_not_published")
assert supervisor._capability_binding_creation_allowed(conn, job_id) is True
add_attempt("capability_resolution_failed")
assert supervisor._capability_binding_creation_allowed(conn, job_id) is True
# A provider-reachable attempt (cost incurred / COMPLETED): refused.
add_attempt("some_other_failure", status="COMPLETED", cost=0.5)
assert supervisor._capability_binding_creation_allowed(conn, job_id) is False
conn.close()
print("6 capability binding allowance ok")
PY
pass "first binding allowed after pre-provider attempts, refused after provider-reachable one"

# ---------- 7. effective model truth: provable only, full usage preserved ----------
python3 - <<'PY'
import json, os, sys
sys.path.insert(0, os.environ.get("OFLOOP_LIB"))
from ownframework_loop import supervisor
# A SINGLE reported model is provable.
assert supervisor._extract_effective_model(
    {"modelUsage": {"claude-x-20260101": {"outputTokens": 10}}}
) == "claude-x-20260101"
# Explicit model field is provable.
assert supervisor._extract_effective_model({"model": "claude-z"}) == "claude-z"
# A MULTI-model mix is NOT inferred to a singular effective model...
mix = {"modelUsage": {"claude-x-20260101": {"outputTokens": 10}, "claude-y": {"outputTokens": 3}}}
assert supervisor._extract_effective_model(mix) == ""
# ...but the FULL provider-reported usage is preserved exactly.
assert json.loads(supervisor._extract_model_usage_json(mix)) == mix["modelUsage"]
# No signal -> empty (unknown), never fabricated.
assert supervisor._extract_effective_model({}) == ""
assert supervisor._extract_effective_model(None) == ""
assert supervisor._extract_model_usage_json({}) == ""
print("7 effective model truth ok")
PY
pass "effective model is provable-only; full provider usage preserved (never inferred)"

# ---------- 8. browser proof is bound to exact Playwright client bytes ----------
python3 - <<'PY'
import os, sys, tempfile
from pathlib import Path
sys.path.insert(0, os.environ.get("OFLOOP_LIB"))
from ownframework_loop import capabilities

tmp = Path(tempfile.mkdtemp(prefix="ofl_browser_client_"))
asset = tmp / "asset"
asset.mkdir()
(asset / "chromium.bin").write_bytes(b"browser-bytes")
evidence = tmp / "evidence"

client_a = {
    "package_root": "/commissioned/playwright",
    "package_tree_sha256": "a" * 64,
    "distribution_version": "9.9.9",
}
client_b = {
    **client_a,
    "package_tree_sha256": "b" * 64,
}
original = capabilities.playwright_client_identity
try:
    capabilities.playwright_client_identity = lambda: dict(client_a)
    merkle = capabilities.browser_asset_merkle_sha256(asset)
    capabilities.write_browser_runtime_proof(
        asset_root=str(asset),
        asset_merkle_sha256=merkle,
        playwright_client=client_a,
        playwright_version="9.9.9",
        browser_version="123",
        evidence_dir=evidence,
    )
    ok, reason, identity = capabilities._browser_runtime_proof_status(
        "browser.playwright.chromium",
        evidence_dir=evidence,
        expected_asset_root=asset,
    )
    assert ok, reason
    assert identity["playwright_client_identity"] == client_a

    # Same browser assets/version strings, different Playwright implementation:
    # the old proof MUST stale rather than silently certify the new client.
    capabilities.playwright_client_identity = lambda: dict(client_b)
    ok, reason, _ = capabilities._browser_runtime_proof_status(
        "browser.playwright.chromium",
        evidence_dir=evidence,
        expected_asset_root=asset,
    )
    assert not ok and "client drift" in reason.lower(), reason
finally:
    capabilities.playwright_client_identity = original
print("8 Playwright client drift stales browser proof")
PY
pass "browser proof binds exact Playwright client implementation, not version strings alone"

echo "OF_LOOP_FINAL_SOURCE_CLOSURE=PASS"
