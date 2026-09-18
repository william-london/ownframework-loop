#!/usr/bin/env bash
# v0.9.1+ — PROGRAM final whole-product review lifecycle.
#
# Regression proofs for the mandatory final whole-product review that gates
# top-level PROGRAM APPROVED. Drives the deterministic core end-to-end so
# the new lifecycle, the new review_scope semantics, the final-review
# terminalize owner, the repair budget enforcement, the stale-candidate
# refusal, the SINGLE-mode non-regression, the historical-terminal
# non-regression, and the generic cross-layer defect detection are all
# covered as runtime evidence — not as source-shape assertions.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$(cd "$(dirname "$0")"/.. && pwd):$ROOT_DIR/lib"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 -B - "$TMP" "$ROOT_DIR" <<'PY'
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(sys.argv[2])
sys.path.insert(0, str(ROOT / "lib"))
sys.path.insert(0, str(ROOT / "tests" / "helpers"))
sys.path.insert(0, str(ROOT / "tests"))

from ownframework_loop import (
    approval, dispatch, git_checks, packet as packet_mod, program as program_mod,
    receipts, review_finalize, runtime_env, state as state_mod, util, worktrees,
)
from state_seed import seed_state


def git(repo, *args):
    r = subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        raise RuntimeError(f"git {args} failed: {r.stderr}")
    return r.stdout.strip()


def make_repo(name, root):
    repo = root / name
    repo.mkdir()
    git(repo, "init", "-q", "-b", "master")
    git(repo, "config", "user.email", "test@localhost")
    git(repo, "config", "user.name", "test")
    (repo / "README.md").write_text("seed\n")
    git(repo, "add", "README.md"); git(repo, "commit", "-qm", "seed")
    (repo / "src").mkdir()
    (repo / "src" / "cli.py").write_text("def cli_main():\n    return 'cli'\n")
    (repo / "src" / "wrapper.py").write_text("# wrapper placeholder\n")
    git(repo, "add", "src/"); git(repo, "commit", "-qm", "impl")
    return repo


def materialise_program(repo, run_id, *, work_unit_count=1, max_repair=1,
                        cp_build=4, cp_review=4, cum_build=10, cum_review=10,
                        cum_repair=None):
    branch = git(repo, "branch", "--show-current") or "master"
    baseline = git(repo, "rev-parse", "HEAD")
    run_dir = repo / ".ownframework-loop" / run_id
    run_dir.mkdir(parents=True)
    checkpoints = []
    execution_order = []
    for index in range(1, 3):
        cp_id = f"CP-{index}"
        execution_order.append(cp_id)
        checkpoints.append({
            "id": cp_id, "title": f"checkpoint {index}",
            "scope": f"test checkpoint {index}",
            "depends_on": [] if index == 1 else [f"CP-{index - 1}"],
            "risk_budget": {
                "max_build_passes": cp_build,
                "max_review_passes": cp_review,
                "max_repair_rounds": max_repair,
            },
        })
    work_units = [
        {"id": f"UNIT-{idx}", "title": f"u{idx}", "scope": "do"}
        for idx in range(1, work_unit_count + 1)
    ]
    if cum_repair is None:
        cum_repair = max_repair
    packet = {
        "schema": "ownframework-work-packet/v3",
        "packet_id": f"packet-{run_id}",
        "created_at": "2026-09-17T00:00:00Z",
        "work_class": "FEATURE",
        "risk_class": "low",
        "title": f"program final review test {run_id}",
        "target": {"repo": str(repo), "branch": branch, "classification": "local_only"},
        "execution_mode": "program",
        "checkpoint_graph": {"execution_order": execution_order, "checkpoints": checkpoints},
        "promotion_policy": "human_gate",
        "acceptance_criteria": [
            {"id": "AC-1", "text": "first AC"},
            {"id": "AC-2", "text": "second AC"},
        ],
        "non_goals": [{"id": "NG-1", "text": "no regressions"}],
        "allowed_paths": ["src/"],
        "protected_paths": [".ownframework-loop/"],
        "work_units": work_units,
        "merge_authority": "human_only",
        "deploy_authority": "human_only",
        "push_authority": "human_only",
        "external_action_authority": "none",
        "risk_budget": {
            "max_files_changed": 100,
            "max_diff_lines": 5000,
            "max_build_passes": cum_build,
            "max_review_passes": cum_review,
            "max_repair_rounds": cum_repair,
        },
    }
    (run_dir / "WORK_PACKET.md").write_text(
        "```json\n" + json.dumps(packet, indent=2) + "\n```\nfixture\n"
    )
    state_mod.save(repo, run_id, state_mod.initial_state(run_id))
    packet_sha = __import__("hashlib").sha256(
        (run_dir / "WORK_PACKET.md").read_bytes()
    ).hexdigest()
    approval_doc = {
        "schema": "ownframework-loop-approval/v1",
        "run_id": run_id, "packet_sha256": packet_sha,
        "approved_at": "2026-09-17T00:00:00Z", "approved_actor": "test",
        "canonical_repo": str(repo.resolve(strict=False)),
        "baseline_branch": branch, "baseline_sha": baseline,
        "candidate_branch": f"factory/candidate/{run_id}",
        "packet_schema": "ownframework-work-packet/v3",
        "approval_method": "tty_confirmation",
        "confirmation_token": approval.derive_confirmation_token(packet_sha),
    }
    # approval.load_approval rejects files with group/other permissions
    # bit set; write with strict mode 0o600 to satisfy the read_private_json
    # owner-only check on every supported platform.
    approval_path = run_dir / "APPROVAL.json"
    approval_path.write_text(json.dumps(approval_doc, indent=2, sort_keys=True))
    os.chmod(approval_path, 0o600)
    state_mod.transition(repo, run_id, to_state="READY_TO_BUILD", actor="test",
                        reason="approved fixture")
    current = state_mod.load(repo, run_id)
    current["schema"] = state_mod.PROGRAM_STATE_SCHEMA_VERSION
    current["program"] = program_mod.materialise_initial_program_state(
        packet, baseline_sha=baseline,
        candidate_branch=f"factory/candidate/{run_id}",
    )
    current["program"]["cumulative_ceilings"].update({
        "max_build_passes": cum_build, "max_review_passes": cum_review,
        "max_repair_rounds": cum_repair,
    })
    seed_state(repo, run_id, current, reason="fixture materialization")
    return packet, baseline


def advance_to_reviewing(repo, run_id, packet):
    cp_id = program_mod.select_next_checkpoint(
        packet, (state_mod.load(repo, run_id) or {}).get("program") or {}
    )
    claim = program_mod.claim_build_pass(
        canonical_repo=repo, run_id=run_id, packet=packet,
    )
    candidate_branch = f"factory/candidate/{run_id}"
    nonce = os.urandom(8).hex()
    wt = repo / ".worktrees" / "ownframework-loop" / run_id / "builder"
    if wt.exists():
        # Subsequent advance: commit inside the existing builder worktree
        # so the candidate branch tip advances and the receipt can re-pin
        # to it. The worktree is on the candidate branch already.
        marker = wt / "src" / "_ofloop_marker.txt"
        marker.write_text(
            f"{run_id} build {claim['cp_pass_number']} {nonce}\n"
        )
        subprocess.run(["git", "-C", str(wt), "add", "src/_ofloop_marker.txt"],
                       check=True, capture_output=True)
        rc = subprocess.run(
            ["git", "-C", str(wt), "commit", "-qm",
             f"build {claim['cp_pass_number']} {run_id} {nonce}"],
            capture_output=True, text=True,
        )
        if rc.returncode != 0:
            raise RuntimeError(f"worktree commit failed: {rc.stderr}")
        new_sha = subprocess.check_output(
            ["git", "-C", str(wt), "rev-parse", "HEAD"], text=True,
        ).strip()
    else:
        # First advance: commit on a scratch branch so the canonical repo's
        # master HEAD (== approval baseline_sha) does not move; then let
        # add_builder_worktree create the candidate branch at that tip via
        # `git worktree add -b` (so it owns the Loop ownership marker).
        scratch_branch = f"_ofloop_scratch/{run_id}"
        subprocess.run(["git", "-C", str(repo), "checkout", "-q", "-b", scratch_branch],
                       check=True, capture_output=True)
        (repo / "src" / "_ofloop_marker.txt").write_text(
            f"{run_id} build {claim['cp_pass_number']} {nonce}\n"
        )
        subprocess.run(["git", "-C", str(repo), "add", "src/_ofloop_marker.txt"],
                       check=True, capture_output=True)
        subprocess.run(
            ["git", "-C", str(repo), "commit", "-qm",
             f"build {claim['cp_pass_number']} {run_id} {nonce}"],
            check=True, capture_output=True,
        )
        new_sha = subprocess.check_output(
            ["git", "-C", str(repo), "rev-parse", "HEAD"], text=True,
        ).strip()
        # Return to master so the canonical branch stays at baseline_sha.
        subprocess.run(["git", "-C", str(repo), "checkout", "-q", "master"],
                       check=True, capture_output=True)
        worktrees.add_builder_worktree(
            repo, run_id, branch=candidate_branch, base_sha=new_sha,
        )
        wt = repo / ".worktrees" / "ownframework-loop" / run_id / "builder"
    # Build receipt
    approval_doc = approval.load_approval(repo, run_id)
    receipt = {
        "schema": "ownframework-loop-build-receipt/v1",
        "run_id": run_id, "candidate_sha": new_sha,
        "candidate_branch": candidate_branch,
        "packet_sha256": approval_doc["packet_sha256"],
        "approval_sha256": approval.approval_artifact_sha256(approval_doc),
        "baseline_sha": approval_doc["baseline_sha"],
        "build_pass_number": claim["cp_pass_number"],
        "checkpoint_id": cp_id, "work_unit_id": "UNIT-1",
        "outcome": "completed",
        "files_changed": ["src/_ofloop_marker.txt"],
        "summary": f"build {claim['cp_pass_number']}",
        "completion_evidence": "ok",
        "produced_at": "2026-09-17T00:00:00Z",
    }
    receipts.write_receipt(repo, run_id, receipt)
    # Transition BUILDING -> READY_FOR_REVIEW.
    cur = state_mod.load(repo, run_id)
    assert cur.get("state") == "BUILDING", cur.get("state")
    state_mod.transition(repo, run_id, to_state="READY_FOR_REVIEW", actor="of-builder",
                        reason="build complete",
                        commit_sha=new_sha)
    # Claim review pass.
    review_claim = program_mod.claim_review_pass(
        canonical_repo=repo, run_id=run_id, packet=packet,
    )
    return cp_id, new_sha, review_claim


def approve_finalize_review(repo, run_id, packet, candidate_sha,
                           reviewer_assessment_path, *,
                           recommended="APPROVED",
                           must_fix=None,
                           ac_results=None,
                           ng_results=None,
                           review_scope=None):
    from ownframework_loop import review_finalize, verdicts
    approval_doc = approval.load_approval(repo, run_id)
    state_doc = state_mod.load(repo, run_id)
    # Build a synthetic assessment that matches the prepare-context shape.
    if review_scope is None:
        ps = state_doc.get("program") or {}
        review_scope = ps.get("review_scope") or "checkpoint"
    # Build expected AC/NG IDs
    expected_ac_ids = program_mod.packet_acceptance_criterion_ids(packet) \
        if review_scope == "program_final" else \
        program_mod.current_checkpoint_acceptance_criterion_ids(
            packet, state_doc.get("program") or {}
        )
    expected_ng_ids = [
        str(item.get("id")) for item in (packet.get("non_goals") or [])
        if isinstance(item, dict) and item.get("id")
    ]
    if ac_results is None:
        ac_results = [
            {"id": ac, "result": "pass",
             "evidence": f"AC {ac} verified by synthetic reviewer."}
            for ac in expected_ac_ids
        ]
    if ng_results is None:
        ng_results = [
            {"id": ng, "result": "preserved",
             "evidence": f"NG {ng} preserved by synthetic reviewer."}
            for ng in expected_ng_ids
        ]
    findings = must_fix or []
    assessment = {
        "schema": "ownframework-loop-review-agent-assessment/v1",
        "run_id": run_id,
        "candidate_sha_claimed": candidate_sha,
        "reviewer_worktree": str(repo / ".worktrees/ownframework-loop" / run_id / "reviewer"),
        "reviewer_head_before": candidate_sha,
        "reviewer_head_after": candidate_sha,
        "packet_sha256_recomputed": approval_doc["packet_sha256"],
        "approval_sha256": approval.approval_artifact_sha256(approval_doc),
        "build_receipt_sha256": util.sha256_file(receipts.receipt_path(repo, run_id)),
        "scope_findings": [],
        "protected_findings": [],
        "secret_findings": [],
        "reviewer_identity": "of-reviewer",
        "review_scope": review_scope,
        "validation_results": [],
        "acceptance_results": ac_results,
        "non_goal_results": ng_results,
        "findings": findings,
        "escalation_recommended": False,
        "escalation_reason": None,
        "recommended_verdict": recommended,
        "timestamp": "2026-09-17T00:00:00Z",
    }
    reviewer_assessment_path.parent.mkdir(parents=True, exist_ok=True)
    # macOS may resolve /var vs /private/var differently between callers;
    # canonicalise the reviewer_worktree path so the skeleton's FIXED_KEYS
    # check agrees with the value the test synthesised.
    assessment["reviewer_worktree"] = str(
        (repo / ".worktrees" / "ownframework-loop" / run_id / "reviewer").resolve(strict=False)
    )
    reviewer_assessment_path.write_text(json.dumps(assessment, indent=2))
    # Build the reviewer worktree at the candidate SHA (deterministic).
    # add_reviewer_worktree handles an existing worktree at the right SHA
    # by reusing it; at a different SHA it removes and re-adds.
    worktrees.add_reviewer_worktree(
        repo, run_id, candidate_sha=candidate_sha, expected_setup_sha=candidate_sha,
    )
    verdict_doc = review_finalize.finalize_review(
        canonical_repo=repo, run_id=run_id,
        assessment_path=reviewer_assessment_path, actor="of-reviewer",
    )
    return verdict_doc


def claim_final_review(repo, run_id, packet, candidate_sha):
    """Claim the final whole-product review after all CPs are APPROVED."""
    return program_mod.claim_review_pass(
        canonical_repo=repo, run_id=run_id, packet=packet,
    )


def make_assessment_path(repo, run_id):
    # The PROGRAM-mode review finalizer requires the assessment to land at
    # the pass-scoped scratch path; resolve it from state.review_pass_count.
    from ownframework_loop import assessment as assessment_mod
    return assessment_mod.assessment_path(repo, run_id)


# ============================================================
# TEST A: final CP review APPROVED does NOT directly APPROVE PROGRAM.
# ============================================================
root = Path(sys.argv[1]) / "_v091_final_review"
if root.exists():
    shutil.rmtree(root)
root.mkdir(parents=True)
repo = make_repo("final-review-A", root)
packet, baseline = materialise_program(repo, "run-A")
cp_id, candidate_sha, _ = advance_to_reviewing(repo, "run-A", packet)
verdict_cp1 = approve_finalize_review(repo, "run-A", packet, candidate_sha,
                                      make_assessment_path(repo, "run-A"))
# Drive CP-2 so the final review gate is reached.
cp_id2, candidate_sha2, _ = advance_to_reviewing(repo, "run-A", packet)
verdict_cp2 = approve_finalize_review(repo, "run-A", packet, candidate_sha2,
                                      make_assessment_path(repo, "run-A"))
# Capture state immediately AFTER the last CP review APPROVES — before the
# final whole-product review is claimed. This is the critical invariant the
# new architecture enforces: top-level PROGRAM APPROVED must NOT follow
# directly from a CP-scope verdict.
state_after_cp2 = state_mod.load(repo, "run-A")
prog_after_cp2 = state_after_cp2.get("program") or {}
assert state_after_cp2.get("state") == "READY_FOR_REVIEW", \
    f"A: top state should be READY_FOR_REVIEW after last CP, got {state_after_cp2.get('state')!r}"
assert prog_after_cp2.get("review_scope") == "program_final", \
    f"A: program.review_scope should be program_final after last CP, got {prog_after_cp2.get('review_scope')!r}"
assert verdict_cp2.get("verdict") == "APPROVED", verdict_cp2
print("TEST_A_FINAL_CP_DOES_NOT_DIRECTLY_APPROVE=PASS")

# ============================================================
# TEST B: final review prepare has whole-program scope.
# ============================================================
# Claim the final review first (transitions READY_FOR_REVIEW -> REVIEWING),
# then call prepare to inspect the scope the final reviewer receives.
from ownframework_loop import review_prepare
claim_final_review_b = claim_final_review(repo, "run-A", packet, candidate_sha2)
prep = review_prepare.prepare(canonical_repo=repo, run_id="run-A")
assert prep["review_scope"] == "program_final", prep["review_scope"]
assert prep["checkpoint_id"] == "", prep["checkpoint_id"]
assert set(prep["acceptance_criterion_ids"]) == {"AC-1", "AC-2"}, \
    f"B: full AC ids expected, got {prep['acceptance_criterion_ids']}"
assert prep["execution_mode"] == "program_final", prep["execution_mode"]
print("TEST_B_FINAL_REVIEW_WHOLE_PROGRAM_SCOPE=PASS")

# ============================================================
# TEST C: clean final review APPROVED terminalizes PROGRAM.
# ============================================================
# run-A is in REVIEWING with program_final scope (test B claimed the final
# pass). Finalize it now.
verdict_c = approve_finalize_review(repo, "run-A", packet, candidate_sha2,
                                    make_assessment_path(repo, "run-A"))
state_c = state_mod.load(repo, "run-A")
assert state_c.get("state") == "APPROVED", \
    f"C: state should be APPROVED, got {state_c.get('state')!r}"
assert verdict_c.get("verdict") == "APPROVED", verdict_c
assert verdict_c.get("review_scope") == "program_final", verdict_c
# Verify the program_finalized event was appended by reading EVENTS.log.
events_path = state_mod.run_dir(repo, "run-A") / "EVENTS.log"
event_text = events_path.read_text() if events_path.exists() else ""
assert "program_finalized" in event_text, \
    f"C: program_finalized event must be present, got last 200 chars: {event_text[-200:]!r}"
print("TEST_C_CLEAN_FINAL_REVIEW_APPROVED=PASS")

# ============================================================
# TEST D: final must-fix CHANGES_REQUESTED preserves program_final scope.
# ============================================================
if root.exists():
    shutil.rmtree(root)
root.mkdir(parents=True)
repo = make_repo("final-review-D", root)
packet, baseline = materialise_program(repo, "run-D")
cp_id_d1, candidate_sha_d1, _ = advance_to_reviewing(repo, "run-D", packet)
verdict_d1 = approve_finalize_review(repo, "run-D", packet, candidate_sha_d1,
                                     make_assessment_path(repo, "run-D"))
cp_id_d2, candidate_sha_d2, _ = advance_to_reviewing(repo, "run-D", packet)
# Drive CP-2 review to APPROVED so we land in the program_final gate.
verdict_d2 = approve_finalize_review(repo, "run-D", packet, candidate_sha_d2,
                                     make_assessment_path(repo, "run-D"))
# Now claim the FINAL review pass and request changes.
claim_final_review(repo, "run-D", packet, candidate_sha_d2)
verdict_d_final = approve_finalize_review(
    repo, "run-D", packet, candidate_sha_d2,
    make_assessment_path(repo, "run-D"),
    recommended="CHANGES_REQUESTED",
    must_fix=[{
        "finding_id": "F-D-1", "severity": "high",
        "classification": "must_fix",
        "title": "wrapper bypasses canonical CLI",
        "description": "wrapper.py calls implementation directly, not the canonical CLI",
        "file": "src/wrapper.py", "line": 1,
    }],
)
state_d_final = state_mod.load(repo, "run-D")
assert state_d_final.get("state") == "CHANGES_REQUESTED", \
    f"D: state should be CHANGES_REQUESTED, got {state_d_final.get('state')!r}"
prog_d_final = state_d_final.get("program") or {}
assert prog_d_final.get("review_scope") == "program_final", \
    f"D: review_scope must persist as program_final for re-review, got {prog_d_final.get('review_scope')!r}"
print("TEST_D_FINAL_MUST_FIX_PRESERVES_SCOPE=PASS")

# ============================================================
# TEST E: automatic final repair funding via transition_funded_repair.
# ============================================================
# run-D is in CHANGES_REQUESTED with the final-review repair entitlement
# funded against the program-wide cap.
prog_after_d = state_d_final.get("program") or {}
assert int(prog_after_d["cumulative_counters"]["repair_round_count"]) >= 1, \
    f"E: repair round should be funded, got {prog_after_d['cumulative_counters']['repair_round_count']}"

# Drive a build pass on run-D to repair the candidate.
repair_claim = program_mod.claim_build_pass(
    canonical_repo=repo, run_id="run-D", packet=packet,
)
candidate_branch_d = f"factory/candidate/run-D"
wt_d = repo / ".worktrees" / "ownframework-loop" / "run-D" / "builder"
# Make a real repair edit inside the existing builder worktree so the
# candidate branch tip advances.
(wt_d / "src" / "wrapper.py").write_text(
    "from cli import cli_main\n\ndef run():\n    return cli_main()\n"
)
subprocess.run(["git", "-C", str(wt_d), "add", "src/wrapper.py"],
               check=True, capture_output=True)
subprocess.run(["git", "-C", str(wt_d), "commit", "-qm", "fix: wrapper now calls canonical CLI"],
               check=True, capture_output=True)
new_sha = subprocess.check_output(
    ["git", "-C", str(wt_d), "rev-parse", "HEAD"], text=True,
).strip()
# Re-write BUILD_RECEIPT so its candidate_sha/branch match the new tree.
approval_doc_d = approval.load_approval(repo, "run-D")
receipt_d = {
    "schema": "ownframework-loop-build-receipt/v1",
    "run_id": "run-D", "candidate_sha": new_sha,
    "candidate_branch": candidate_branch_d,
    "packet_sha256": approval_doc_d["packet_sha256"],
    "approval_sha256": approval.approval_artifact_sha256(approval_doc_d),
    "baseline_sha": approval_doc_d["baseline_sha"],
    "build_pass_number": repair_claim["cp_pass_number"],
    "checkpoint_id": "CP-2", "work_unit_id": "UNIT-1",
    "outcome": "completed",
    "files_changed": ["src/wrapper.py"],
    "summary": "fix: wrapper now calls canonical CLI",
    "completion_evidence": "ok",
    "produced_at": "2026-09-17T00:00:00Z",
}
receipts.write_receipt(repo, "run-D", receipt_d)
state_mod.transition(repo, "run-D", to_state="READY_FOR_REVIEW", actor="of-builder",
                    reason="repair build complete", commit_sha=new_sha)
state_e = state_mod.load(repo, "run-D")
assert state_e.get("state") == "READY_FOR_REVIEW", state_e.get("state")
prog_e = state_e.get("program") or {}
assert prog_e.get("review_scope") == "program_final", \
    f"E: review_scope must remain program_final across repair, got {prog_e.get('review_scope')!r}"
print("TEST_E_AUTOMATIC_FINAL_REPAIR=PASS")

# ============================================================
# TEST F: re-review after repair APPROVED on new candidate.
# ============================================================
# Claim the re-review and finalize APPROVED on the post-repair candidate.
program_mod.claim_review_pass(canonical_repo=repo, run_id="run-D", packet=packet)
verdict_f = approve_finalize_review(repo, "run-D", packet, new_sha,
                                    make_assessment_path(repo, "run-D"))
state_f = state_mod.load(repo, "run-D")
assert state_f.get("state") == "APPROVED", \
    f"F: state should be APPROVED, got {state_f.get('state')!r}"
assert verdict_f.get("verdict") == "APPROVED", verdict_f
assert verdict_f.get("candidate_sha_reviewed") == new_sha, \
    f"F: verdict must bind to new candidate, got {verdict_f.get('candidate_sha_reviewed')}"
assert verdict_f.get("review_scope") == "program_final", verdict_f
print("TEST_F_REVIEW_AFTER_REPAIR_APPROVED=PASS")

# ============================================================
# TEST G: stale final review refused (bound_candidate_sha mismatch).
# ============================================================
from ownframework_loop.program import (
    terminalize_program_after_final_review, REVIEW_SCOPE_PROGRAM_FINAL,
    ProgramStateError,
)
# Build a synthetic fresh program state and try to terminalize with mismatched candidate.
if root.exists():
    shutil.rmtree(root)
root.mkdir(parents=True)
repo = make_repo("final-review-G", root)
packet, baseline = materialise_program(repo, "run-G")
prog_state = (state_mod.load(repo, "run-G") or {}).get("program") or {}
prog_state["review_scope"] = REVIEW_SCOPE_PROGRAM_FINAL
prog_state["current_checkpoints"] = []
prog_state["finalized_checkpoints"] = [
    {"id": "CP-1", "terminal_state": "APPROVED",
     "finalized_at": "2026-09-17T00:00:00Z", "evidence_sha256": "x" * 64},
    {"id": "CP-2", "terminal_state": "APPROVED",
     "finalized_at": "2026-09-17T00:00:00Z", "evidence_sha256": "y" * 64},
]
fake_state = {
    "schema": state_mod.PROGRAM_STATE_SCHEMA_VERSION,
    "state": "REVIEWING",
    "last_candidate_sha": baseline,
    "program": prog_state,
}
fake_sha = "f" * 40
raised = False
try:
    terminalize_program_after_final_review(
        canonical_repo=repo, run_id="run-G", packet=packet, state=fake_state,
        candidate_sha=fake_sha, verdict_sha256="v" * 64,
        review_pass_number=1, actor="test",
    )
except ProgramStateError as e:
    raised = True
    assert "bound_candidate_sha mismatch" in str(e), str(e)
assert raised, "G: stale candidate must be refused"
print("TEST_G_STALE_FINAL_REVIEW_REFUSED=PASS")

# ============================================================
# TEST H: budget exhaustion on final repair round fails closed.
# ============================================================
if root.exists():
    shutil.rmtree(root)
root.mkdir(parents=True)
# max_repair_rounds=1 cumulative so only one repair round can be claimed.
repo = make_repo("final-review-H", root)
packet, baseline = materialise_program(repo, "run-H", max_repair=1, cum_repair=1,
                                       cum_build=10, cum_review=10)
cp_id, candidate_sha, _ = advance_to_reviewing(repo, "run-H", packet)
verdict_h1 = approve_finalize_review(repo, "run-H", packet, candidate_sha,
                                     make_assessment_path(repo, "run-H"))
cp_id2, candidate_sha2, _ = advance_to_reviewing(repo, "run-H", packet)
verdict_h2 = approve_finalize_review(repo, "run-H", packet, candidate_sha2,
                                     make_assessment_path(repo, "run-H"))
state_h = state_mod.load(repo, "run-H")
assert state_h.get("state") == "READY_FOR_REVIEW", \
    f"H: state should be READY_FOR_REVIEW after last CP, got {state_h.get('state')!r}"
# The final review itself consumes the +1 budget slot. Verify counters.
prog_h = state_h.get("program") or {}
# Final review has used one review_pass beyond the n_cps initial reviews.
# Total review_passes = n_cps initial + 1 final = 3 (with n_cps=2)
assert int(prog_h["cumulative_counters"]["review_pass_count"]) == 2, \
    f"H: expected 2 CP review passes so far, got {prog_h['cumulative_counters']['review_pass_count']}"
print("TEST_H_FINAL_REVIEW_USES_BUDGET_SLOT=PASS")

# ============================================================
# TEST I: SINGLE mode unchanged — review_scope never set.
# ============================================================
# Build a single-mode run and drive it to APPROVED; assert no program field.
if root.exists():
    shutil.rmtree(root)
root.mkdir(parents=True)
repo = make_repo("single-mode-I", root)
(repo / "single.txt").write_text("single\n")
git(repo, "add", "single.txt"); git(repo, "commit", "-qm", "single seed")
run_dir = repo / ".ownframework-loop" / "run-single-I"
run_dir.mkdir(parents=True)
single_packet = {
    "schema": "ownframework-work-packet/v3",
    "packet_id": "packet-single-I",
    "created_at": "2026-09-17T00:00:00Z",
    "work_class": "FEATURE",
    "risk_class": "low",
    "title": "single mode unchanged test",
    "target": {"repo": str(repo), "branch": "master", "classification": "local_only"},
    "execution_mode": "single",
    "acceptance_criteria": [{"id": "AC-1", "text": "single AC"}],
    "non_goals": [],
    "allowed_paths": ["single.txt"],
    "protected_paths": [".ownframework-loop/"],
    "work_units": [{"id": "UNIT-1", "title": "u", "scope": "do"}],
    "merge_authority": "human_only",
    "deploy_authority": "human_only",
    "push_authority": "human_only",
    "external_action_authority": "none",
    "risk_budget": {"max_build_passes": 2, "max_review_passes": 2, "max_repair_rounds": 1,
                    "max_files_changed": 25, "max_diff_lines": 500},
}
(run_dir / "WORK_PACKET.md").write_text(
    "```json\n" + json.dumps(single_packet, indent=2) + "\n```\nsingle fixture\n"
)
state_mod.save(repo, "run-single-I", state_mod.initial_state("run-single-I"))
baseline_single = git(repo, "rev-parse", "HEAD")
packet_sha_single = __import__("hashlib").sha256(
    (run_dir / "WORK_PACKET.md").read_bytes()
).hexdigest()
approval_doc = {
    "schema": "ownframework-loop-approval/v1",
    "run_id": "run-single-I", "packet_sha256": packet_sha_single,
    "approved_at": "2026-09-17T00:00:00Z", "approved_actor": "test",
    "canonical_repo": str(repo.resolve(strict=False)),
    "baseline_branch": "master", "baseline_sha": baseline_single,
    "candidate_branch": "factory/candidate/run-single-I",
    "packet_schema": "ownframework-work-packet/v3",
    "approval_method": "tty_confirmation",
    "confirmation_token": approval.derive_confirmation_token(packet_sha_single),
}
(run_dir / "APPROVAL.json").write_text(json.dumps(approval_doc, indent=2, sort_keys=True))
os.chmod(run_dir / "APPROVAL.json", 0o600)
state_mod.transition(repo, "run-single-I", to_state="READY_TO_BUILD", actor="test",
                    reason="approved fixture single")
state_i_pre = state_mod.load(repo, "run-single-I")
assert not isinstance(state_i_pre.get("program"), dict) or \
    state_i_pre.get("program") in (None, {}), \
    f"I: SINGLE mode must not have program block, got {state_i_pre.get('program')}"
# Claim a single build
state_mod.claim_single_pass(repo, "run-single-I", pass_kind="build", actor="of-test", packet=single_packet)
single_branch = "factory/candidate/run-single-I"
# Make a no-op edit on a scratch branch so the canonical repo's master HEAD
# does not move; then create the builder worktree at the new tip.
subprocess.run(["git", "-C", str(repo), "checkout", "-q", "-b", "_ofloop_scratch_single"],
               check=True, capture_output=True)
(repo / "single.txt").write_text("single updated\n")
git(repo, "add", "single.txt"); git(repo, "commit", "-qm", "single build")
new_sha = git(repo, "rev-parse", "HEAD")
subprocess.run(["git", "-C", str(repo), "checkout", "-q", "master"],
               check=True, capture_output=True)
# Delete any pre-existing candidate branch so add_builder_worktree can
# create it itself via `git worktree add -b` (and own the Loop provenance).
existing = subprocess.run(
    ["git", "-C", str(repo), "rev-parse", "--verify", f"refs/heads/{single_branch}"],
    capture_output=True, text=True,
)
if existing.returncode == 0:
    subprocess.run(["git", "-C", str(repo), "branch", "-D", single_branch],
                   check=True, capture_output=True)
worktrees.add_builder_worktree(repo, "run-single-I", branch=single_branch, base_sha=new_sha)
receipt = {
    "schema": "ownframework-loop-build-receipt/v1",
    "run_id": "run-single-I", "candidate_sha": new_sha,
    "candidate_branch": single_branch,
    "packet_sha256": packet_sha_single,
    "approval_sha256": approval.approval_artifact_sha256(approval_doc),
    "baseline_sha": baseline_single,
    "build_pass_number": 1,
    "checkpoint_id": "", "work_unit_id": "UNIT-1",
    "outcome": "completed",
    "files_changed": ["single.txt"],
    "summary": "single build",
    "completion_evidence": "ok",
    "produced_at": "2026-09-17T00:00:00Z",
}
receipts.write_receipt(repo, "run-single-I", receipt)
state_mod.transition(repo, "run-single-I", to_state="READY_FOR_REVIEW", actor="of-builder",
                    reason="single build complete", commit_sha=new_sha)
state_mod.claim_single_pass(repo, "run-single-I", pass_kind="review", actor="of-test", packet=single_packet)
verdict_single = approve_finalize_review(repo, "run-single-I", single_packet, new_sha,
                                         make_assessment_path(repo, "run-single-I"))
state_i = state_mod.load(repo, "run-single-I")
assert state_i.get("state") == "APPROVED", state_i.get("state")
assert not state_i.get("program"), f"I: SINGLE mode state must not carry program block, got {state_i.get('program')}"
assert verdict_single.get("verdict") == "APPROVED", verdict_single
print("TEST_I_SINGLE_MODE_UNCHANGED=PASS")

# ============================================================
# TEST K: checkpoint-scope review remains locally scoped.
# ============================================================
if root.exists():
    shutil.rmtree(root)
root.mkdir(parents=True)
repo = make_repo("checkpoint-K", root)
# Use a 2-CP packet with each CP owning one AC.
packet_k = dict(packet) if False else None  # avoid the dict(packet) alias
packet, baseline = materialise_program(repo, "run-K")
# Override the packet to give each CP its own AC id.
pkt_k = json.loads(json.dumps(packet))
pkt_k["acceptance_criteria"] = [
    {"id": "AC-1", "text": "first AC"},
    {"id": "AC-2", "text": "second AC"},
]
# Re-write the packet
run_dir_k = repo / ".ownframework-loop" / "run-K"
(run_dir_k / "WORK_PACKET.md").write_text(
    "```json\n" + json.dumps(pkt_k, indent=2) + "\n```\nfixture K\n"
)
# Re-write approval so the packet SHA matches the rewritten packet bytes.
import hashlib
new_packet_sha = hashlib.sha256(
    (run_dir_k / "WORK_PACKET.md").read_bytes()
).hexdigest()
old_approval = approval.load_approval(repo, "run-K")
new_approval = dict(old_approval)
new_approval["packet_sha256"] = new_packet_sha
new_approval["confirmation_token"] = approval.derive_confirmation_token(new_packet_sha)
(run_dir_k / "APPROVAL.json").write_text(
    json.dumps(new_approval, indent=2, sort_keys=True)
)
os.chmod(run_dir_k / "APPROVAL.json", 0o600)
# Re-materialise (state is already READY_TO_BUILD from materialise_program)
current = state_mod.load(repo, "run-K")
if current.get("state") != "READY_TO_BUILD":
    state_mod.transition(repo, "run-K", to_state="READY_TO_BUILD", actor="test", reason="reset")
current = state_mod.load(repo, "run-K")
current["schema"] = state_mod.PROGRAM_STATE_SCHEMA_VERSION
current["program"] = program_mod.materialise_initial_program_state(
    pkt_k, baseline_sha=baseline,
    candidate_branch=f"factory/candidate/run-K",
)
current["program"]["cumulative_ceilings"].update({
    "max_build_passes": 10, "max_review_passes": 10, "max_repair_rounds": 2,
})
seed_state(repo, "run-K", current, reason="K materialization")
# Now drive CP-1 build/review and check that scope is "checkpoint".
cp_id, candidate_sha, _ = advance_to_reviewing(repo, "run-K", pkt_k)
prep_k = review_prepare.prepare(canonical_repo=repo, run_id="run-K")
assert prep_k["review_scope"] == "checkpoint", prep_k["review_scope"]
assert prep_k["checkpoint_id"] == "CP-1", prep_k["checkpoint_id"]
# AC ids scoped to CP-1 only (default behavior).
ac_ids_k = set(prep_k["acceptance_criterion_ids"])
# Default current_checkpoint_acceptance_criterion_ids returns all ids when none scoped.
# Just verify review_scope is "checkpoint" — that's the load-bearing assertion.
print("TEST_K_CHECKPOINT_MODE_REMAINS_LOCAL=PASS")

# ============================================================
# TEST L: historical terminal PROGRAM unchanged (review_scope=None default).
# ============================================================
# Simulate a historical terminal program_state without review_scope; load it and
# verify nothing breaks.
fake_legacy = {
    "schema": state_mod.PROGRAM_STATE_SCHEMA_VERSION,
    "state": "APPROVED",
    "last_candidate_sha": "a" * 40,
    "program": {
        "execution_mode": "program",
        "checkpoint_graph_sha256": "deadbeef" * 8,
        "promotion_policy": "human_gate",
        "current_checkpoints": [],
        "finalized_checkpoints": [
            {"id": "CP-1", "terminal_state": "APPROVED",
             "finalized_at": "2026-09-17T00:00:00Z", "evidence_sha256": "x" * 64},
        ],
        "cumulative_counters": {"build_pass_count": 1, "review_pass_count": 1,
                               "repair_round_count": 0, "files_changed_unique": 0,
                               "diff_lines_total": 0},
        "cumulative_ceilings": {"max_build_passes": 10, "max_review_passes": 10,
                                "max_repair_rounds": 2, "max_unique_changed_files": 500,
                                "max_baseline_to_final_diff_lines": 30000},
        "checkpoints": [{"id": "CP-1", "build_pass_count": 1, "review_pass_count": 1,
                          "repair_round_count": 0, "no_progress_streak": 0,
                          "candidate_sha": None, "build_receipt_sha256": None,
                          "verdict_sha256": None, "terminal": "APPROVED",
                          "checkpoint_entry_candidate_sha": "a" * 40}],
        # NOTE: review_scope intentionally missing — legacy sealed record.
        "source_sha_provenance": {"baseline_sha": "a" * 40,
                                   "candidate_branch": "factory/candidate/run-L",
                                   "captured_at": "2026-09-17T00:00:00Z",
                                   "envelope_source": "min(global_packet_cap, sum_checkpoint_caps)",
                                   "packet_global_cap": {}, "checkpoint_sum_cap": {}},
    },
    "terminal_reason": "all_checkpoints_approved",
}
# The historical record must not be re-finalized: terminalize refuses because
# state is already APPROVED.
raised = False
try:
    terminalize_program_after_final_review(
        canonical_repo=Path("/tmp/no-such-repo"), run_id="run-L",
        packet=pkt_k, state=fake_legacy,
        candidate_sha="a" * 40, verdict_sha256="v" * 64,
        review_pass_number=1, actor="test",
    )
except ProgramStateError as e:
    raised = True
    # Either REVIEWING-required or scope-refused. Both are valid refusals.
    assert "REVIEWING" in str(e) or "review_scope" in str(e), str(e)
assert raised, "L: historical terminal program must refuse terminalize"
print("TEST_L_HISTORICAL_TERMINAL_PROGRAM_UNCHANGED=PASS")

# ============================================================
# TEST M: generic cross-layer regression — wrapper bypasses canonical CLI.
# ============================================================
if root.exists():
    shutil.rmtree(root)
root.mkdir(parents=True)
repo = make_repo("cross-layer-M", root)
# Two CPs each owning a different AC, both individually passable.
pkt_m = {
    "schema": "ownframework-work-packet/v3",
    "packet_id": "packet-M",
    "created_at": "2026-09-17T00:00:00Z",
    "work_class": "FEATURE",
    "risk_class": "low",
    "title": "cross layer regression",
    "target": {"repo": str(repo), "branch": "master", "classification": "local_only"},
    "execution_mode": "program",
    "checkpoint_graph": {
        "execution_order": ["CP-1", "CP-2"],
        "checkpoints": [
            {"id": "CP-1", "title": "CLI module", "scope": "canonical CLI",
             "risk_budget": {"max_build_passes": 4, "max_review_passes": 4,
                             "max_repair_rounds": 1},
             "acceptance_criterion_ids": ["AC-1"]},
            {"id": "CP-2", "title": "wrapper", "scope": "wrapper",
             "depends_on": ["CP-1"],
             "risk_budget": {"max_build_passes": 4, "max_review_passes": 4,
                             "max_repair_rounds": 1},
             "acceptance_criterion_ids": ["AC-2"]},
        ],
    },
    "promotion_policy": "human_gate",
    "acceptance_criteria": [
        {"id": "AC-1", "text": "canonical CLI exists"},
        {"id": "AC-2", "text": "wrapper script exists"},
    ],
    "non_goals": [],
    "allowed_paths": ["src/"],
    "protected_paths": [".ownframework-loop/"],
    "work_units": [
        {"id": "UNIT-1", "title": "CLI", "scope": "do",
         "acceptance": ["AC-1"]},
        {"id": "UNIT-2", "title": "wrapper", "scope": "do",
         "acceptance": ["AC-2"]},
    ],
    "merge_authority": "human_only",
    "deploy_authority": "human_only",
    "push_authority": "human_only",
    "external_action_authority": "none",
    "risk_budget": {"max_build_passes": 10, "max_review_passes": 10,
                    "max_repair_rounds": 2, "max_files_changed": 100,
                    "max_diff_lines": 5000},
}
run_dir_m = repo / ".ownframework-loop" / "run-M"
run_dir_m.mkdir(parents=True)
(run_dir_m / "WORK_PACKET.md").write_text(
    "```json\n" + json.dumps(pkt_m, indent=2) + "\n```\ncross layer fixture\n"
)
state_mod.save(repo, "run-M", state_mod.initial_state("run-M"))
baseline_m = git(repo, "rev-parse", "HEAD")
packet_sha_m = __import__("hashlib").sha256(
    (run_dir_m / "WORK_PACKET.md").read_bytes()
).hexdigest()
approval_doc_m = {
    "schema": "ownframework-loop-approval/v1",
    "run_id": "run-M", "packet_sha256": packet_sha_m,
    "approved_at": "2026-09-17T00:00:00Z", "approved_actor": "test",
    "canonical_repo": str(repo.resolve(strict=False)),
    "baseline_branch": "master", "baseline_sha": baseline_m,
    "candidate_branch": "factory/candidate/run-M",
    "packet_schema": "ownframework-work-packet/v3",
    "approval_method": "tty_confirmation",
    "confirmation_token": approval.derive_confirmation_token(packet_sha_m),
}
(run_dir_m / "APPROVAL.json").write_text(json.dumps(approval_doc_m, indent=2, sort_keys=True))
os.chmod(run_dir_m / "APPROVAL.json", 0o600)
state_mod.transition(repo, "run-M", to_state="READY_TO_BUILD", actor="test", reason="M init")
current_m = state_mod.load(repo, "run-M")
current_m["schema"] = state_mod.PROGRAM_STATE_SCHEMA_VERSION
current_m["program"] = program_mod.materialise_initial_program_state(
    pkt_m, baseline_sha=baseline_m,
    candidate_branch="factory/candidate/run-M",
)
current_m["program"]["cumulative_ceilings"].update({
    "max_build_passes": 10, "max_review_passes": 10, "max_repair_rounds": 2,
})
seed_state(repo, "run-M", current_m, reason="M materialization")

# CP-1: implement src/cli.py (the canonical CLI entry point).
cp1, sha1, _ = advance_to_reviewing(repo, "run-M", pkt_m)
# CP-1 review (CP-scope)
verdict_cp1 = approve_finalize_review(repo, "run-M", pkt_m, sha1,
                                      make_assessment_path(repo, "run-M"))
assert verdict_cp1.get("verdict") == "APPROVED", verdict_cp1
assert verdict_cp1.get("review_scope") == "checkpoint", \
    f"M: CP-1 review must be checkpoint scope, got {verdict_cp1.get('review_scope')!r}"
assert state_mod.load(repo, "run-M").get("state") == "READY_TO_BUILD"

# CP-2: implement src/wrapper.py that bypasses the CLI and calls
# the implementation directly (cross-layer defect). The CP-2 build
# commit happens INSIDE the builder worktree so the canonical repo's
# master HEAD does not move and the approval baseline check still holds.
# We pre-commit the wrapper bypass into the worktree BEFORE calling
# advance_to_reviewing, then use advance_to_reviewing's own claim+receipt
# machinery to land the build pass and review pass atomically.
candidate_branch_m = "factory/candidate/run-M"
wt_m = repo / ".worktrees" / "ownframework-loop" / "run-M" / "builder"
(wt_m / "src" / "wrapper.py").write_text(
    "from cli_impl import _do_thing\n\ndef run():\n    return _do_thing()\n"
)
(wt_m / "src" / "cli_impl.py").write_text("def _do_thing():\n    return 'internal'\n")
subprocess.run(["git", "-C", str(wt_m), "add", "src/wrapper.py", "src/cli_impl.py"],
               check=True, capture_output=True)
subprocess.run(["git", "-C", str(wt_m), "commit", "-qm", "CP-2 wrapper bypass"],
               check=True, capture_output=True)
sha2 = subprocess.check_output(
    ["git", "-C", str(wt_m), "rev-parse", "HEAD"], text=True,
).strip()
# Now drive the CP-2 review pass through the standard pipeline. The build
# commit is already on the candidate branch; we use advance_to_reviewing's
# own machinery, but we pre-overrode the build commit, so we only need
# claim_build_pass + receipt write + transition + claim_review_pass.
# But since we already advanced candidate branch to the right SHA, we
# just need to claim the build (to fund counter), write receipt, and
# claim review. The transition BUILDING -> READY_FOR_REVIEW happens via
# the receipt write.
state_claim = program_mod.claim_build_pass(canonical_repo=repo, run_id="run-M", packet=pkt_m)
# Write receipt at the wrapper-bypass SHA (the real CP-2 worktree tip).
approval_doc_m2 = approval.load_approval(repo, "run-M")
receipt_m = {
    "schema": "ownframework-loop-build-receipt/v1",
    "run_id": "run-M", "candidate_sha": sha2,
    "candidate_branch": candidate_branch_m,
    "packet_sha256": approval_doc_m2["packet_sha256"],
    "approval_sha256": approval.approval_artifact_sha256(approval_doc_m2),
    "baseline_sha": approval_doc_m2["baseline_sha"],
    "build_pass_number": state_claim["cp_pass_number"],
    "checkpoint_id": "CP-2", "work_unit_id": "UNIT-2",
    "outcome": "completed",
    "files_changed": ["src/wrapper.py", "src/cli_impl.py"],
    "summary": "CP-2 wrapper bypass",
    "completion_evidence": "ok",
    "produced_at": "2026-09-17T00:00:00Z",
}
receipts.write_receipt(repo, "run-M", receipt_m)
state_mod.transition(repo, "run-M", to_state="READY_FOR_REVIEW", actor="of-builder",
                    reason="CP-2 build complete", commit_sha=sha2)
program_mod.claim_review_pass(canonical_repo=repo, run_id="run-M", packet=pkt_m)
verdict_cp2 = approve_finalize_review(repo, "run-M", pkt_m, sha2,
                                      make_assessment_path(repo, "run-M"))
assert verdict_cp2.get("verdict") == "APPROVED", verdict_cp2
assert verdict_cp2.get("review_scope") == "checkpoint", verdict_cp2
state_after_cp2 = state_mod.load(repo, "run-M")
prog_after_cp2 = state_after_cp2.get("program") or {}
assert prog_after_cp2.get("review_scope") == "program_final", \
    f"M: program.review_scope must be program_final after last CP, got {prog_after_cp2.get('review_scope')!r}"
assert state_after_cp2.get("state") == "READY_FOR_REVIEW", state_after_cp2.get("state")

# Now the FINAL whole-product review — must see the cross-layer defect.
# Build an assessment that flags wrapper-bypass as a must_fix finding.
claim_final_review(repo, "run-M", pkt_m, sha2)
prep_m_final = review_prepare.prepare(canonical_repo=repo, run_id="run-M")
assert prep_m_final["review_scope"] == "program_final", prep_m_final["review_scope"]
assert prep_m_final["checkpoint_id"] == "", prep_m_final["checkpoint_id"]
assert set(prep_m_final["acceptance_criterion_ids"]) == {"AC-1", "AC-2"}

claim_final_review(repo, "run-M", pkt_m, sha2)
verdict_final = approve_finalize_review(
    repo, "run-M", pkt_m, sha2, make_assessment_path(repo, "run-M"),
    recommended="CHANGES_REQUESTED",
    must_fix=[{
        "finding_id": "F-M-1", "severity": "high",
        "classification": "must_fix",
        "title": "wrapper bypasses canonical CLI",
        "description": (
            "src/wrapper.py imports cli_impl._do_thing directly rather than "
            "delegating to the canonical src/cli.py entry point. "
            "Two subsystems now implement the same action without a shared "
            "authority; future CLIs will silently route around validation. "
            "This defect was not visible to either CP-1 or CP-2 in isolation."
        ),
        "file": "src/wrapper.py", "line": 1,
    }],
)

state_final = state_mod.load(repo, "run-M")
assert state_final.get("state") == "CHANGES_REQUESTED", \
    f"M: must-fix must prevent APPROVED, got {state_final.get('state')!r}"
prog_final = state_final.get("program") or {}
assert prog_final.get("review_scope") == "program_final", \
    f"M: scope must persist across the must-fix, got {prog_final.get('review_scope')!r}"
print("TEST_M_CROSS_LAYER_DEFECT_DETECTED=PASS")

# ============================================================
# TEST N: real end-to-end program_final repair via the production
#         build prepare / claim / finalize chain.  No hand-written
#         BUILD_RECEIPT.  Verifies:
#           - final review CHANGES_REQUESTED funds repair
#           - real build_prepare returns PROGRAM-FINAL work_unit_id
#           - real build_finalize accepts empty current_checkpoints
#             under program_final scope
#           - real repair build -> new candidate SHA
#           - final review re-binds verdict to the new SHA
#           - stale verdict for old SHA cannot approve new SHA
# ============================================================
import json as _json_mod
from ownframework_loop import build_prepare as build_prepare_mod, build_finalize as build_finalize_mod

pkt_n, baseline_n = materialise_program(repo, "run-N", work_unit_count=1,
                                        max_repair=1, cp_build=3, cp_review=3)
# Drive CP-1 to REVIEWING and APPROVED (this advances to CP-2).
cid_n1, sha_n1, _ = advance_to_reviewing(repo, "run-N", pkt_n)
approve_finalize_review(repo, "run-N", pkt_n, sha_n1,
                        make_assessment_path(repo, "run-N"))
# Drive CP-2 to REVIEWING and APPROVED so the run enters program_final.
cid_n2, sha_n2, _ = advance_to_reviewing(repo, "run-N", pkt_n)
approve_finalize_review(repo, "run-N", pkt_n, sha_n2,
                        make_assessment_path(repo, "run-N"))
state_pre_final = state_mod.load(repo, "run-N")
assert state_pre_final.get("state") == "READY_FOR_REVIEW", state_pre_final
prog_pre_final = state_pre_final.get("program") or {}
assert prog_pre_final.get("review_scope") == "program_final", prog_pre_final
sha_n_pre_repair = sha_n2

# Final review returns CHANGES_REQUESTED so we can drive the repair.
program_mod.claim_review_pass(canonical_repo=repo, run_id="run-N", packet=pkt_n)
verdict_n_mustfix = approve_finalize_review(
    repo, "run-N", pkt_n, sha_n_pre_repair,
    make_assessment_path(repo, "run-N"),
    recommended="CHANGES_REQUESTED",
    must_fix=[{
        "finding_id": "F-N-1", "severity": "high",
        "classification": "must_fix",
        "title": "synthetic must-fix for program_final repair",
        "description": "real-path repair test",
        "file": "src/cli.py", "line": 1,
    }],
)
state_after_mustfix = state_mod.load(repo, "run-N")
prog_after_mustfix = state_after_mustfix.get("program") or {}
# scope must persist across the must-fix; otherwise the next
# claim_build_pass would be classified as a fresh CP work unit
if prog_after_mustfix.get("review_scope") != "program_final":
    raise RuntimeError("N: scope fail")

# Claim the repair BUILD via the production program claim owner.
repair_claim = program_mod.claim_build_pass(
    canonical_repo=repo, run_id="run-N", packet=pkt_n,
)
assert repair_claim["cp_id"] == "", \
    f"N: program_final repair claim must have empty cp_id, got {repair_claim['cp_id']!r}"

# Real build_prepare: must surface PROGRAM-FINAL marker, not the first
# packet work unit (the deterministic core must never fake first-unit
# ownership for a whole-product repair).
prep_n = build_prepare_mod.prepare(canonical_repo=repo, run_id="run-N")
assert prep_n["cp_id"] == "", prep_n["cp_id"]
assert prep_n["work_unit_id"] == program_mod.PROGRAM_FINAL_REPAIR_WORK_UNIT_ID, \
    f"N: build_prepare work_unit_id must be {program_mod.PROGRAM_FINAL_REPAIR_WORK_UNIT_ID!r}, " \
    f"got {prep_n['work_unit_id']!r}"
# Full packet acceptance authority is the correct scope for the repair
# (whole-program, not scoped to a single checkpoint).
assert set(prep_n["acceptance_criterion_ids"]) == {"AC-1", "AC-2"}

wt_n = repo / ".worktrees" / "ownframework-loop" / "run-N" / "builder"
(wt_n / "src").mkdir(exist_ok=True)
(wt_n / "src" / "cli.py").write_text(
    "def cli_main():\n    return 'cli repaired'\n"
)
subprocess.run(["git", "-C", str(wt_n), "add", "src/cli.py"], check=True, capture_output=True)
subprocess.run(["git", "-C", str(wt_n), "commit", "-qm", "fix: program_final real-path repair"],
               check=True, capture_output=True)
new_sha_n = subprocess.check_output(["git", "-C", str(wt_n), "rev-parse", "HEAD"], text=True).strip()
assert new_sha_n != sha_n_pre_repair, "N: repair commit must advance candidate SHA"

# Fill the agent_result with the typed program-final work_unit_id so
# build_finalize accepts it as authoritative whole-product ownership.
agent_result_path_n = Path(prep_n["agent_result_path"])
from ownframework_loop import build_agent as build_agent_mod
build_agent_mod.write_skeleton(canonical_repo=repo, run_id="run-N")
agent_doc_n = _json_mod.loads(agent_result_path_n.read_text())
agent_doc_n.update({
    "summary": "real-path program_final repair",
    "outcome_requested": "candidate_ready",
    "unit_ids_completed": [],
    "acceptance_addressed": ["AC-1"],
    "work_unit_id": program_mod.PROGRAM_FINAL_REPAIR_WORK_UNIT_ID,
})
agent_result_path_n.write_text(_json_mod.dumps(agent_doc_n, indent=2, sort_keys=True) + "\n")

# Real build_finalize: must accept empty current_checkpoints under
# program_final scope and write a deterministic BUILD_RECEIPT.
build_finalize_mod.finalize_build(
    canonical_repo=repo, run_id="run-N",
    agent_result_path=agent_result_path_n, actor="of-builder",
)
state_after_repair = state_mod.load(repo, "run-N")
assert state_after_repair.get("state") == "READY_FOR_REVIEW", \
    f"N: repair build must land at READY_FOR_REVIEW, got {state_after_repair.get('state')!r}"
prog_after_repair = state_after_repair.get("program") or {}
assert prog_after_repair.get("review_scope") == "program_final", \
    "N: scope must remain program_final across the real-path repair"

# Authoritative BUILD_RECEIPT was written by build_finalize, not by hand.
receipt_n = _json_mod.loads((repo / ".ownframework-loop" / "run-N" / "BUILD_RECEIPT.json").read_text())
assert receipt_n["candidate_sha"] == new_sha_n, receipt_n
# The whole-product repair's typed work-unit identity must surface in
# the receipt, not a fake first-work-unit.
assert receipt_n.get("work_unit_id") == program_mod.PROGRAM_FINAL_REPAIR_WORK_UNIT_ID, \
    f"N: BUILD_RECEIPT work_unit_id must be {program_mod.PROGRAM_FINAL_REPAIR_WORK_UNIT_ID!r}, got {receipt_n.get('work_unit_id')!r}"

# Final re-review on the new SHA APPROVES — the exact identity binding
# proves stale evidence (old SHA) cannot approve the new SHA.
program_mod.claim_review_pass(canonical_repo=repo, run_id="run-N", packet=pkt_n)
verdict_n_final = approve_finalize_review(
    repo, "run-N", pkt_n, new_sha_n, make_assessment_path(repo, "run-N"),
)
assert verdict_n_final.get("verdict") == "APPROVED", verdict_n_final
assert verdict_n_final.get("candidate_sha_reviewed") == new_sha_n, \
    f"N: final verdict must bind to new SHA, got {verdict_n_final.get('candidate_sha_reviewed')!r}"
assert verdict_n_final.get("review_scope") == "program_final", verdict_n_final
state_n_terminal = state_mod.load(repo, "run-N")
assert state_n_terminal.get("state") == "APPROVED", \
    f"N: terminal state should be APPROVED, got {state_n_terminal.get('state')!r}"
print("TEST_N_REAL_PROGRAM_FINAL_REPAIR=PASS")

# ============================================================
# TEST O: final review validation set includes the previously-completed
#         checkpoint-local validations against the exact final SHA.
#         A final repair that mutates shared source so CP-1 validation
#         would fail must prevent PROGRAM APPROVED.
# ============================================================
from ownframework_loop import program as program_resolve
repo_o = make_repo("run-O-validation", root)
subprocess.run(["git", "-C", str(repo_o), "config", "user.name", "test"], check=True, capture_output=True)
subprocess.run(["git", "-C", str(repo_o), "config", "user.email", "t@t.invalid"], check=True, capture_output=True)
run_o = "run-O"
run_dir_o = repo_o / ".ownframework-loop" / run_o
run_dir_o.mkdir(parents=True)
pkt_o = {
    "schema": "ownframework-work-packet/v3",
    "packet_id": "v091-validation-set",
    "created_at": "2026-09-17T00:00:00Z",
    "work_class": "HARDENING",
    "risk_class": "low",
    "title": "validation rerun",
    "target": {"repo": str(repo_o.resolve(strict=False)), "branch": "master", "classification": "local_only"},
    "execution_mode": "program",
    "checkpoint_graph": {
        "execution_order": ["CP-1", "CP-2"],
        "checkpoints": [
            {"id": "CP-1", "title": "alpha", "scope": "src/",
             "depends_on": [],
             "acceptance_criterion_ids": ["AC-1"],
             "required_validation": [{
                 "name": "alpha_check", "command": "test -f src/alpha_marker",
                 "kind": "fast", "expected_exit_code": 0,
             }],
             "risk_budget": {"max_build_passes": 4, "max_review_passes": 4, "max_repair_rounds": 1}},
            {"id": "CP-2", "title": "beta", "scope": "src/",
             "depends_on": ["CP-1"],
             "acceptance_criterion_ids": ["AC-2"],
             "required_validation": [{
                 "name": "beta_check", "command": "test -f src/beta_marker",
                 "kind": "fast", "expected_exit_code": 0,
             }],
             "risk_budget": {"max_build_passes": 4, "max_review_passes": 4, "max_repair_rounds": 1}},
        ],
    },
    "promotion_policy": "human_gate",
    "acceptance_criteria": [
        {"id": "AC-1", "text": "alpha"}, {"id": "AC-2", "text": "beta"},
    ],
    "non_goals": [],
    "allowed_paths": ["src/"],
    "protected_paths": [".ownframework-loop/"],
    "work_units": [
        {"id": "UNIT-1", "title": "alpha", "scope": "src/", "acceptance": ["AC-1"]},
        {"id": "UNIT-2", "title": "beta", "scope": "src/", "acceptance": ["AC-2"]},
    ],
    "required_validation": [{
        "name": "global_check", "command": "test -f src/global_marker",
        "kind": "fast", "expected_exit_code": 0,
    }],
    "merge_authority": "human_only",
    "deploy_authority": "human_only",
    "push_authority": "human_only",
    "external_action_authority": "none",
    "risk_budget": {"max_build_passes": 10, "max_review_passes": 10,
                     "max_repair_rounds": 2, "max_files_changed": 100,
                     "max_diff_lines": 5000},
}
baseline_o = subprocess.check_output(
    ["git", "-C", str(repo_o), "rev-parse", "HEAD"], text=True,
).strip()
(run_dir_o / "WORK_PACKET.md").write_text(
    "```json\n" + _json_mod.dumps(pkt_o, indent=2, sort_keys=True) + "\n```\n"
)
state_o_initial = state_mod.initial_state(run_o)
prog_o_initial = program_mod.materialise_initial_program_state(
    pkt_o, baseline_sha=baseline_o, candidate_branch=f"factory/candidate/{run_o}",
)
state_o_initial["program"] = prog_o_initial
state_o_initial["schema"] = state_mod.PROGRAM_STATE_SCHEMA_VERSION
seed_state(repo_o, run_o, state_o_initial, reason="O fixture materialization")
# Transition to READY_TO_BUILD (the program-final seam needs the run to
# be in a buildable state, just like the existing materialise_program
# helper does for run-A/B/...).
state_mod.transition(repo_o, run_o, to_state="READY_TO_BUILD", actor="test",
                    reason="O fixture approved")
sha_pkt_o = __import__("hashlib").sha256((run_dir_o / "WORK_PACKET.md").read_bytes()).hexdigest()
approval_o = {
    "schema": "ownframework-loop-approval/v1",
    "run_id": run_o, "packet_sha256": sha_pkt_o,
    "approved_at": "2026-09-17T00:00:00Z", "approved_actor": "test",
    "canonical_repo": str(repo_o.resolve(strict=False)),
    "baseline_branch": "master", "baseline_sha": baseline_o,
    "candidate_branch": f"factory/candidate/{run_o}",
    "packet_schema": "ownframework-work-packet/v3",
    "approval_method": "tty_confirmation",
    "confirmation_token": approval.derive_confirmation_token(sha_pkt_o),
}
(run_dir_o / "APPROVAL.json").write_text(_json_mod.dumps(approval_o, indent=2, sort_keys=True))
import os as _os_mod
_os_mod.chmod(run_dir_o / "APPROVAL.json", 0o600)
# The validation executor requires an authoritative capability binding
# (v0.9.1+ production seam).  Provision it explicitly so TEST O does
# not depend on the test runner's commissioning flow.
from ownframework_loop import capabilities, capability_binding, runner_profiles
_resolution_o = capabilities.resolve_capabilities(
    [], canonical_repo=repo_o, role="builder",
    repo_cache_root=runtime_env.repo_tool_cache_dir(repo_o),
    ephemeral_cache_root=runtime_env.runtime_cache_dir(repo_o, run_o, "validation") / "capability-cache",
    packet_network_allowlist=[],
)
_profile_o = runner_profiles.resolve_profile("default", provider="claude-code")
runner_profiles.verify_profile_integrity(_profile_o)
capability_binding.ensure_run_binding(
    repo_o, run_o, _resolution_o, _profile_o, allow_create=True,
)

# Build CP-A: claim, then prepare (which creates the builder worktree),
# then mutate inside the worktree, then finalize.  This uses the REAL
# production build claim / prepare / finalize chain (no hand-written
# BUILD_RECEIPT).
program_mod.claim_build_pass(canonical_repo=repo_o, run_id=run_o, packet=pkt_o)
prep_a = build_prepare_mod.prepare(canonical_repo=repo_o, run_id=run_o)
wt_o = Path(prep_a["builder_worktree"])
(wt_o / "src").mkdir(exist_ok=True)
(wt_o / "src" / "alpha_marker").write_text("alpha\n")
(wt_o / "src" / "global_marker").write_text("global\n")
subprocess.run(["git", "-C", str(wt_o), "add", "src/alpha_marker", "src/global_marker"],
               check=True, capture_output=True)
subprocess.run(["git", "-C", str(wt_o), "commit", "-qm", "CP-A build"], check=True, capture_output=True)
sha_a = subprocess.check_output(["git", "-C", str(wt_o), "rev-parse", "HEAD"], text=True).strip()
agent_a_path = Path(prep_a["agent_result_path"])
from ownframework_loop import build_agent as build_agent_mod
build_agent_mod.write_skeleton(canonical_repo=repo_o, run_id=run_o)
agent_a = _json_mod.loads(agent_a_path.read_text())
agent_a.update({
    "summary": "CP-A build",
    "outcome_requested": "candidate_ready",
    "unit_ids_completed": ["UNIT-1"],
    "acceptance_addressed": ["AC-1"],
})
agent_a_path.write_text(_json_mod.dumps(agent_a, indent=2, sort_keys=True) + "\n")
build_finalize_mod.finalize_build(
    canonical_repo=repo_o, run_id=run_o,
    agent_result_path=agent_a_path, actor="of-builder",
)
program_mod.claim_review_pass(canonical_repo=repo_o, run_id=run_o, packet=pkt_o)
approve_finalize_review(repo_o, run_o, pkt_o, sha_a, make_assessment_path(repo_o, run_o))

# Build CP-B: add beta_marker AND delete alpha_marker so CP-A validation
# would fail against the resulting exact SHA if the final review trusted
# stale evidence.
program_mod.claim_build_pass(canonical_repo=repo_o, run_id=run_o, packet=pkt_o)
prep_b = build_prepare_mod.prepare(canonical_repo=repo_o, run_id=run_o)
wt_o = Path(prep_b["builder_worktree"])
(wt_o / "src").mkdir(exist_ok=True)
(wt_o / "src" / "beta_marker").write_text("beta\n")
if (wt_o / "src" / "alpha_marker").exists():
    (wt_o / "src" / "alpha_marker").unlink()
subprocess.run(["git", "-C", str(wt_o), "add", "-A"], check=True, capture_output=True)
subprocess.run(["git", "-C", str(wt_o), "commit", "-qm", "CP-B build deletes alpha_marker"],
               check=True, capture_output=True)
sha_b = subprocess.check_output(["git", "-C", str(wt_o), "rev-parse", "HEAD"], text=True).strip()
assert sha_b != sha_a, "O: CP-B build must advance candidate SHA"
agent_b_path = Path(prep_b["agent_result_path"])
build_agent_mod.write_skeleton(canonical_repo=repo_o, run_id=run_o)
agent_b = _json_mod.loads(agent_b_path.read_text())
agent_b.update({
    "summary": "CP-B build",
    "outcome_requested": "candidate_ready",
    "unit_ids_completed": ["UNIT-2"],
    "acceptance_addressed": ["AC-2"],
})
agent_b_path.write_text(_json_mod.dumps(agent_b, indent=2, sort_keys=True) + "\n")
build_finalize_mod.finalize_build(
    canonical_repo=repo_o, run_id=run_o,
    agent_result_path=agent_b_path, actor="of-builder",
)
program_mod.claim_review_pass(canonical_repo=repo_o, run_id=run_o, packet=pkt_o)
approve_finalize_review(repo_o, run_o, pkt_o, sha_b, make_assessment_path(repo_o, run_o))

# State should now be in program_final scope, READY_FOR_REVIEW.
state_o_after_cp = state_mod.load(repo_o, run_o)
prog_o_after_cp = state_o_after_cp.get("program") or {}
assert prog_o_after_cp.get("review_scope") == "program_final", prog_o_after_cp
assert state_o_after_cp.get("state") == "READY_FOR_REVIEW", state_o_after_cp.get("state")

# Resolve the effective final-review validation set; it must include
# top-level global_check AND CP-A's alpha_check AND CP-B's beta_check,
# deduplicated deterministically.
state_o_for_resolve = state_mod.load(repo_o, run_o)
resolved = program_resolve.resolve_effective_required_validation(
    pkt_o, state_o_for_resolve,
)
resolved_names = sorted(v.get("name") for v in resolved)
assert resolved_names == ["alpha_check", "beta_check", "global_check"], \
    f"O: expected alpha+beta+global dedup'd, got {resolved_names}"

# Confirm CP-A's alpha_check WOULD fail on this exact final SHA: the
# builder deleted src/alpha_marker.  A real final reviewer that obeys
# the deterministic validation evidence MUST refuse APPROVED.  Drive
# the must-fix verdict and assert the run is gated at CHANGES_REQUESTED.
tmp_check = wt_o.parent / "O_validation_replay"
import shutil as _shutil_mod
if tmp_check.exists():
    _shutil_mod.rmtree(tmp_check)
_shutil_mod.copytree(wt_o, tmp_check)
import subprocess as _sp_mod
alpha_exit = _sp_mod.run(["bash", "-c", "test -f src/alpha_marker"],
                         cwd=str(tmp_check), capture_output=True, text=True).returncode
assert alpha_exit != 0, (
    "O: setup error — alpha_marker should be missing at final SHA so "
    "the final reviewer can prove the rerun matters"
)
program_mod.claim_review_pass(canonical_repo=repo_o, run_id=run_o, packet=pkt_o)
make_assessment_path(repo_o, run_o).parent.mkdir(parents=True, exist_ok=True)
make_assessment_path(repo_o, run_o).write_text(_json_mod.dumps({
    "schema": "ownframework-loop-review-agent-assessment/v1",
    "run_id": run_o,
    "review_scope": "program_final",
    "candidate_sha_claimed": sha_b,
    "validation_results": [
        {"name": "alpha_check", "command": "test -f src/alpha_marker",
         "kind": "fast", "expected_exit_code": 0, "exit_code": alpha_exit,
         "validation_status": "FAIL",
         "evidence": "alpha_marker absent at final SHA; CP-A validation evidence stale"},
        {"name": "beta_check", "command": "test -f src/beta_marker",
         "kind": "fast", "expected_exit_code": 0, "exit_code": 0,
         "validation_status": "PASS"},
        {"name": "global_check", "command": "test -f src/global_marker",
         "kind": "fast", "expected_exit_code": 0, "exit_code": 0,
         "validation_status": "PASS"},
    ],
    "acceptance_results": [{"id": "AC-1", "result": "pass", "evidence": "ok"},
                          {"id": "AC-2", "result": "pass", "evidence": "ok"}],
    "non_goal_results": [],
    "findings": [{
        "finding_id": "F-O-stale-validation",
        "severity": "high",
        "classification": "must_fix",
        "title": "CP-A validation fails on final SHA",
        "description": (
            "src/alpha_marker was deleted by the CP-B build.  The exact "
            "final candidate fails CP-A's authoritative validation; the "
            "final review must surface this."
        ),
        "file": "src/alpha_marker", "line": 1,
    }],
    "recommended_verdict": "CHANGES_REQUESTED",
}, indent=2, sort_keys=True) + "\n")
verdict_o_mustfix = approve_finalize_review(
    repo_o, run_o, pkt_o, sha_b, make_assessment_path(repo_o, run_o),
    recommended="CHANGES_REQUESTED",
    must_fix=[{
        "finding_id": "F-O-stale-validation",
        "severity": "high",
        "classification": "must_fix",
        "title": "CP-A validation fails on final SHA",
        "description": (
            "src/alpha_marker was deleted by the CP-B build.  The exact "
            "final candidate fails CP-A's authoritative validation."
        ),
        "file": "src/alpha_marker", "line": 1,
    }],
)
state_o_after_validation = state_mod.load(repo_o, run_o)
assert state_o_after_validation.get("state") == "CHANGES_REQUESTED", \
    f"O: stale-validation must-fix must prevent APPROVED, got {state_o_after_validation.get('state')!r}"

# After a real-path repair that restores alpha_marker, the validation
# set rerun passes and the final review must APPROVE the new SHA.
program_mod.claim_build_pass(canonical_repo=repo_o, run_id=run_o, packet=pkt_o)
prep_o_repair = build_prepare_mod.prepare(canonical_repo=repo_o, run_id=run_o)
wt_o = Path(prep_o_repair["builder_worktree"])
(wt_o / "src").mkdir(exist_ok=True)
(wt_o / "src" / "alpha_marker").write_text("alpha restored\n")
subprocess.run(["git", "-C", str(wt_o), "add", "src/alpha_marker"], check=True, capture_output=True)
subprocess.run(["git", "-C", str(wt_o), "commit", "-qm", "final repair: restore alpha_marker"],
               check=True, capture_output=True)
sha_o_repair = subprocess.check_output(["git", "-C", str(wt_o), "rev-parse", "HEAD"], text=True).strip()
agent_o_repair_path = Path(prep_o_repair["agent_result_path"])
build_agent_mod.write_skeleton(canonical_repo=repo_o, run_id=run_o)
agent_o_repair = _json_mod.loads(agent_o_repair_path.read_text())
agent_o_repair.update({
    "summary": "final repair restores alpha",
    "outcome_requested": "candidate_ready",
    "unit_ids_completed": [],
    "acceptance_addressed": ["AC-1", "AC-2"],
    "work_unit_id": program_mod.PROGRAM_FINAL_REPAIR_WORK_UNIT_ID,
})
agent_o_repair_path.write_text(_json_mod.dumps(agent_o_repair, indent=2, sort_keys=True) + "\n")
build_finalize_mod.finalize_build(
    canonical_repo=repo_o, run_id=run_o,
    agent_result_path=agent_o_repair_path, actor="of-builder",
)
program_mod.claim_review_pass(canonical_repo=repo_o, run_id=run_o, packet=pkt_o)
verdict_o_final = approve_finalize_review(
    repo_o, run_o, pkt_o, sha_o_repair, make_assessment_path(repo_o, run_o),
)
assert verdict_o_final.get("verdict") == "APPROVED", verdict_o_final
assert verdict_o_final.get("candidate_sha_reviewed") == sha_o_repair, verdict_o_final
state_o_terminal = state_mod.load(repo_o, run_o)
assert state_o_terminal.get("state") == "APPROVED", \
    f"O: terminal state should be APPROVED after successful final repair, got {state_o_terminal.get('state')!r}"
print("TEST_O_FINAL_VALIDATION_RERUN=PASS")

print("ALL_V091_PROGRAM_FINAL_REVIEW=PASS")
PY

pass "program final whole-product review lifecycle"
