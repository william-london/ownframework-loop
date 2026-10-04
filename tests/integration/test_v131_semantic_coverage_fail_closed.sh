#!/usr/bin/env bash
# v1.1.2 — semantic acceptance/non-goal coverage must fail closed.
#
# Defect (test debt, not a verdict-semantics defect): review_finalize.finalize_review
# contains the fail-closed branch
#
#   EXPECTED_AC_SET != SEMANTIC_REPORTED_AC_SET  =>  APPROVED impossible
#   EXPECTED_NG_SET != SEMANTIC_REPORTED_NG_SET  =>  APPROVED impossible
#
#   failure_reason = "semantic_coverage_incomplete"
#
# at review_finalize.py:545-554 and :638-640. The post-HVAC audit found that
# string occurs exactly once in the entire repository and NOWHERE in tests/:
# every canonical fixture supplied a complete, well-formed AC/NG set, so the
# one branch that refuses a review for UNDER-REPORTING coverage had never
# executed. That is precisely the anti-rubber-stamp guard — the guard that
# stops a semantic model from gaining APPROVED by omitting inconvenient
# criteria — and it was unproven.
#
# This patch adds coverage only. It does not change verdict semantics: the
# cases below assert the CURRENT branch behaviour against the real
# finalize_review production owner, not a re-implementation.
#
# Required invariants proven here:
#   MISSING_AC          => semantic_coverage_incomplete (no APPROVED)
#   DUPLICATE_AC        => cannot substitute for a missing expected AC
#   UNEXPECTED_AC       => cannot substitute for a missing expected AC
#   MISSING_NG          => semantic_coverage_incomplete
#   COMPLETE COVERAGE   => normal verdict logic still governs (APPROVED)
#   PROGRAM_FINAL       => expected set is the FULL packet contract
#   PROGRAM_FINAL gap   => semantic_coverage_incomplete at final scope too
#   CHECKPOINT_SCOPE    => CP-owned ACs only; future-checkpoint ACs rejected
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib:$ROOT_DIR/tests/helpers${PYTHONPATH:+:$PYTHONPATH}"
export OFLOOP_LIB="$ROOT_DIR/lib"
export PYTHONDONTWRITEBYTECODE=1
TMP="$(mktemp -d -t ofloop-v131-semantic-coverage.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

python3 -B - "$TMP" "$ROOT_DIR" <<'PY'
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(sys.argv[2])
sys.path.insert(0, str(ROOT / "lib"))
sys.path.insert(0, str(ROOT / "tests" / "helpers"))
sys.path.insert(0, str(ROOT / "tests"))

from ownframework_loop import (  # noqa: E402
    approval, assessment as assessment_mod, program as program_mod, receipts,
    review_finalize, state as state_mod, worktrees,
)
from state_seed import seed_state  # noqa: E402


def git(repo, *args):
    r = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
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
    git(repo, "add", "README.md")
    git(repo, "commit", "-qm", "seed")
    (repo / "src").mkdir()
    (repo / "src" / "cli.py").write_text("def cli_main():\n    return 'cli'\n")
    git(repo, "add", "src/")
    git(repo, "commit", "-qm", "impl")
    return repo


def materialise_program(repo, run_id, cp_ac_ids):
    """Two-checkpoint PROGRAM, 3 packet ACs, 2 packet non-goals.

    cp_ac_ids maps CP-1 / CP-2 to the criteria each checkpoint owns, so the
    checkpoint-scope cases can prove CP-owned coverage is enforced.
    """
    branch = git(repo, "branch", "--show-current") or "master"
    baseline = git(repo, "rev-parse", "HEAD")
    run_dir = repo / ".ownframework-loop" / run_id
    run_dir.mkdir(parents=True)
    checkpoints = [
        {"id": "CP-1", "title": "cp1", "scope": "cp1", "depends_on": [],
         "acceptance_criterion_ids": list(cp_ac_ids["CP-1"]),
         "risk_budget": {"max_build_passes": 6, "max_review_passes": 6,
                         "max_repair_rounds": 2}},
        {"id": "CP-2", "title": "cp2", "scope": "cp2", "depends_on": ["CP-1"],
         "acceptance_criterion_ids": list(cp_ac_ids["CP-2"]),
         "risk_budget": {"max_build_passes": 6, "max_review_passes": 6,
                         "max_repair_rounds": 2}},
    ]
    packet = {
        "schema": "ownframework-work-packet/v3",
        "packet_id": f"packet-{run_id}",
        "created_at": "2026-09-17T00:00:00Z",
        "work_class": "FEATURE",
        "risk_class": "low",
        "title": f"semantic coverage {run_id}",
        "target": {"repo": str(repo), "branch": branch, "classification": "local_only"},
        "execution_mode": "program",
        "checkpoint_graph": {
            "execution_order": ["CP-1", "CP-2"], "checkpoints": checkpoints,
        },
        "promotion_policy": "human_gate",
        "acceptance_criteria": [
            {"id": "AC-1", "text": "first"},
            {"id": "AC-2", "text": "second"},
            {"id": "AC-3", "text": "third"},
        ],
        "non_goals": [
            {"id": "NG-1", "text": "no regressions"},
            {"id": "NG-2", "text": "no scope widening"},
        ],
        "allowed_paths": ["src/"],
        "protected_paths": [".ownframework-loop/"],
        "work_units": [{"id": "UNIT-1", "title": "u1", "scope": "do"}],
        "merge_authority": "human_only",
        "deploy_authority": "human_only",
        "push_authority": "human_only",
        "external_action_authority": "none",
        "risk_budget": {
            "max_files_changed": 100, "max_diff_lines": 5000,
            "max_build_passes": 30, "max_review_passes": 30, "max_repair_rounds": 16,
        },
    }
    (run_dir / "WORK_PACKET.md").write_text(
        "```json\n" + json.dumps(packet, indent=2) + "\n```\nfixture\n"
    )
    state_mod.save(repo, run_id, state_mod.initial_state(run_id))
    import hashlib
    packet_sha = hashlib.sha256((run_dir / "WORK_PACKET.md").read_bytes()).hexdigest()
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
        "max_build_passes": 30, "max_review_passes": 30, "max_repair_rounds": 16,
    })
    seed_state(repo, run_id, current, reason="fixture materialization")
    return packet, baseline


def advance_to_reviewing(repo, run_id, packet):
    """Real claim -> builder commit -> build receipt -> review claim."""
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
        marker = wt / "src" / "_ofloop_marker.txt"
        marker.write_text(f"{run_id} build {claim['cp_pass_number']} {nonce}\n")
        subprocess.run(["git", "-C", str(wt), "add", "src/_ofloop_marker.txt"],
                       check=True, capture_output=True)
        rc = subprocess.run(["git", "-C", str(wt), "commit", "-qm",
                             f"build {claim['cp_pass_number']} {run_id} {nonce}"],
                            capture_output=True, text=True)
        if rc.returncode != 0:
            raise RuntimeError(f"worktree commit failed: {rc.stderr}")
        new_sha = subprocess.check_output(
            ["git", "-C", str(wt), "rev-parse", "HEAD"], text=True).strip()
    else:
        scratch = f"_ofloop_scratch/{run_id}"
        subprocess.run(["git", "-C", str(repo), "checkout", "-q", "-b", scratch],
                       check=True, capture_output=True)
        (repo / "src" / "_ofloop_marker.txt").write_text(
            f"{run_id} build {claim['cp_pass_number']} {nonce}\n")
        subprocess.run(["git", "-C", str(repo), "add", "src/_ofloop_marker.txt"],
                       check=True, capture_output=True)
        subprocess.run(["git", "-C", str(repo), "commit", "-qm",
                        f"build {claim['cp_pass_number']} {run_id} {nonce}"],
                       check=True, capture_output=True)
        new_sha = subprocess.check_output(
            ["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
        subprocess.run(["git", "-C", str(repo), "checkout", "-q", "master"],
                       check=True, capture_output=True)
        worktrees.add_builder_worktree(
            repo, run_id, branch=candidate_branch, base_sha=new_sha)
        wt = repo / ".worktrees" / "ownframework-loop" / run_id / "builder"
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
    cur = state_mod.load(repo, run_id)
    assert cur.get("state") == "BUILDING", cur.get("state")
    state_mod.transition(repo, run_id, to_state="READY_FOR_REVIEW",
                         actor="of-builder", reason="build complete",
                         commit_sha=new_sha)
    program_mod.claim_review_pass(canonical_repo=repo, run_id=run_id, packet=packet)
    return cp_id, new_sha


def finalize_with(repo, run_id, *, ac_ids, ng_ids, recommended="APPROVED"):
    """Drive the REAL finalize_review with an explicit reported AC/NG set."""
    state_doc = state_mod.load(repo, run_id)
    program_state = state_doc.get("program") or {}
    review_scope = program_state.get("review_scope") or "checkpoint"
    candidate_sha = state_doc["last_candidate_sha"]
    approval_doc = approval.load_approval(repo, run_id)
    assessment = {
        "schema": "ownframework-loop-review-agent-assessment/v1",
        "run_id": run_id,
        "candidate_sha_claimed": candidate_sha,
        "reviewer_worktree": str(
            (repo / ".worktrees" / "ownframework-loop" / run_id / "reviewer")
            .resolve(strict=False)
        ),
        "reviewer_head_before": candidate_sha,
        "reviewer_head_after": candidate_sha,
        "packet_sha256_recomputed": approval_doc["packet_sha256"],
        "approval_sha256": approval.approval_artifact_sha256(approval_doc),
        "build_receipt_sha256": util_sha(repo, run_id),
        "scope_findings": [], "protected_findings": [], "secret_findings": [],
        "reviewer_identity": "of-reviewer",
        "review_scope": review_scope,
        "validation_results": [],
        "acceptance_results": [
            {"id": ac, "result": "pass", "evidence": f"{ac} reported by synthetic reviewer."}
            for ac in ac_ids
        ],
        "non_goal_results": [
            {"id": ng, "result": "preserved", "evidence": f"{ng} preserved."}
            for ng in ng_ids
        ],
        "findings": [],
        "escalation_recommended": False,
        "escalation_reason": None,
        "recommended_verdict": recommended,
        "timestamp": "2026-09-17T00:00:00Z",
    }
    assessment_path = assessment_mod.assessment_path(repo, run_id)
    assessment_path.parent.mkdir(parents=True, exist_ok=True)
    assessment_path.write_text(json.dumps(assessment, indent=2))
    worktrees.add_reviewer_worktree(
        repo, run_id, candidate_sha=candidate_sha, expected_setup_sha=candidate_sha)
    return review_finalize.finalize_review(
        canonical_repo=repo, run_id=run_id,
        assessment_path=assessment_path, actor="of-builder",
    )


def util_sha(repo, run_id):
    import hashlib
    return hashlib.sha256(receipts.receipt_path(repo, run_id).read_bytes()).hexdigest()


def expect_incomplete(verdict, label):
    assert verdict.get("verdict") == "CHANGES_REQUESTED", \
        f"{label}: expected CHANGES_REQUESTED, got {verdict.get('verdict')!r}"
    assert verdict.get("failure_reason") == "semantic_coverage_incomplete", \
        f"{label}: expected semantic_coverage_incomplete, got {verdict.get('failure_reason')!r}"
    print(f"{label}=PASS")


CP_SPLIT = {"CP-1": ["AC-1", "AC-2"], "CP-2": ["AC-3"]}

with tempfile.TemporaryDirectory(dir=sys.argv[1]) as td:
    root = Path(td)
    repo = make_repo("cov", root)

    # ---- 1. MISSING_AC: CP-1 owns AC-1/AC-2; report only AC-1 -------------
    rid = "run-missing-ac"
    pk, _ = materialise_program(repo, rid, CP_SPLIT)
    advance_to_reviewing(repo, rid, pk)
    expect_incomplete(
        finalize_with(repo, rid, ac_ids=["AC-1"], ng_ids=["NG-1", "NG-2"]),
        "MISSING_AC",
    )

    # ---- 2. DUPLICATE_AC cannot stand in for a missing expected AC ---------
    rid = "run-dup-ac"
    pk, _ = materialise_program(repo, rid, CP_SPLIT)
    advance_to_reviewing(repo, rid, pk)
    expect_incomplete(
        finalize_with(repo, rid, ac_ids=["AC-1", "AC-1"], ng_ids=["NG-1", "NG-2"]),
        "DUPLICATE_AC",
    )

    # ---- 3. UNEXPECTED_AC cannot stand in for a missing expected AC --------
    rid = "run-extra-ac"
    pk, _ = materialise_program(repo, rid, CP_SPLIT)
    advance_to_reviewing(repo, rid, pk)
    expect_incomplete(
        finalize_with(repo, rid, ac_ids=["AC-1", "AC-99"], ng_ids=["NG-1", "NG-2"]),
        "UNEXPECTED_AC",
    )

    # ---- 4. MISSING_NG: full AC set, one non-goal omitted ------------------
    rid = "run-missing-ng"
    pk, _ = materialise_program(repo, rid, CP_SPLIT)
    advance_to_reviewing(repo, rid, pk)
    expect_incomplete(
        finalize_with(repo, rid, ac_ids=["AC-1", "AC-2"], ng_ids=["NG-1"]),
        "MISSING_NG",
    )

    # ---- 5. COMPLETE exact coverage still follows normal verdict logic -----
    rid = "run-complete"
    pk, _ = materialise_program(repo, rid, CP_SPLIT)
    advance_to_reviewing(repo, rid, pk)
    ok = finalize_with(repo, rid, ac_ids=["AC-1", "AC-2"], ng_ids=["NG-1", "NG-2"])
    assert ok.get("verdict") == "APPROVED", ok.get("verdict")
    assert not ok.get("failure_reason"), ok.get("failure_reason")
    print("COMPLETE_COVERAGE_APPROVES=PASS")

    # ---- 6. CHECKPOINT_SCOPE: CP-1 owns AC-1 only; future AC-2 rejected ---
    rid = "run-cp-scope"
    pk, _ = materialise_program(repo, rid, {"CP-1": ["AC-1"], "CP-2": ["AC-2", "AC-3"]})
    advance_to_reviewing(repo, rid, pk)
    expect_incomplete(
        finalize_with(repo, rid, ac_ids=["AC-1", "AC-2"], ng_ids=["NG-1", "NG-2"]),
        "CHECKPOINT_SCOPE_FUTURE_AC",
    )

    # ---- 7. PROGRAM_FINAL: expected set is the FULL packet contract --------
    rid = "run-final-complete"
    pk, _ = materialise_program(repo, rid, CP_SPLIT)
    # CP-1 approves on its owned ACs only.
    advance_to_reviewing(repo, rid, pk)
    assert finalize_with(repo, rid, ac_ids=["AC-1", "AC-2"],
                          ng_ids=["NG-1", "NG-2"])["verdict"] == "APPROVED"
    # CP-2 approves on its owned ACs only.
    advance_to_reviewing(repo, rid, pk)
    assert finalize_with(repo, rid, ac_ids=["AC-3"],
                          ng_ids=["NG-1", "NG-2"])["verdict"] == "APPROVED"
    state_doc = state_mod.load(repo, rid)
    assert (state_doc.get("program") or {}).get("review_scope") == "program_final", \
        "expected program_final scope after both checkpoints approved"
    assert state_doc.get("state") == "READY_FOR_REVIEW", state_doc.get("state")
    # Final review reports the FULL packet contract -> coverage holds.
    program_mod.claim_review_pass(canonical_repo=repo, run_id=rid, packet=pk)
    fin = finalize_with(repo, rid, ac_ids=["AC-1", "AC-2", "AC-3"],
                        ng_ids=["NG-1", "NG-2"])
    assert fin.get("verdict") == "APPROVED", \
        f"PROGRAM_FINAL full-packet coverage should hold: {fin.get('verdict')!r} " \
        f"{fin.get('failure_reason')!r}"
    assert fin.get("review_scope") == "program_final", fin.get("review_scope")
    print("PROGRAM_FINAL_FULL_PACKET_COVERAGE=PASS")

    # ---- 8. PROGRAM_FINAL: a gap is still fail-closed at final scope ------
    rid = "run-final-gap"
    pk, _ = materialise_program(repo, rid, CP_SPLIT)
    advance_to_reviewing(repo, rid, pk)
    finalize_with(repo, rid, ac_ids=["AC-1", "AC-2"], ng_ids=["NG-1", "NG-2"])
    advance_to_reviewing(repo, rid, pk)
    finalize_with(repo, rid, ac_ids=["AC-3"], ng_ids=["NG-1", "NG-2"])
    program_mod.claim_review_pass(canonical_repo=repo, run_id=rid, packet=pk)
    expect_incomplete(
        finalize_with(repo, rid, ac_ids=["AC-1", "AC-2"], ng_ids=["NG-1", "NG-2"]),
        "PROGRAM_FINAL_MISSING_AC",
    )

print("V131_SEMANTIC_COVERAGE_FAIL_CLOSED=PASS")
PY
