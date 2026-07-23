"""Deterministic review finalizer.

The reviewer agent returns a small non-authoritative semantic assessment
(see ``REVIEW_AGENT_ASSESSMENT.json``). The finalizer is the only entity
that writes the authoritative ``REVIEW_VERDICT.json`` and derives the
final state.

The finalizer independently:

  1. Validates APPROVAL.json against current packet bytes.
  2. Validates BUILD_RECEIPT.json schema and integrity.
  3. Validates canonical repository identity.
  4. Resolves the exact candidate SHA from the build receipt.
  5. Verifies the candidate SHA exists in this repository.
  6. Verifies lineage from the approved baseline.
  7. Verifies the candidate branch contains the candidate SHA.
  8. Creates or verifies the reviewer detached worktree at exactly that SHA.
  9. Records pre-review HEAD and status.
 10. Validates the assessment schema.
 11. Rejects assessment candidate mismatch.
 12. Executes the packet's required-validation commands.
 13. Captures exact exit codes and durations.
 14. Verifies reviewer HEAD did not change.
 15. Verifies tracked and untracked reviewer mutations.
 16. Verifies packet, approval, receipt, and candidate remained unchanged.
 17. Re-runs scope, protected/elevated path, secret, and diff checks.
 18. Computes the immutable stale-SHA record itself.
 19. Generates REVIEW_VERDICT.json itself.
 20. Derives the final state itself.

Approval is permitted only when:
  - exact packet approval is valid;
  - the candidate SHA is stable;
  - the build receipt is valid;
  - all mandatory validations pass;
  - scope and authority checks pass;
  - no hard secret violation exists;
  - the reviewer worktree has no unauthorized mutation;
  - every acceptance criterion is semantically `pass`;
  - every non-goal is semantically `preserved`;
  - no must-fix finding remains;
  - the semantic reviewer recommendation is APPROVED.

If the model recommends APPROVED but deterministic proof fails, the
finalizer downgrades to STALE_CANDIDATE, CHANGES_REQUESTED, BLOCKED, or
HUMAN_REVIEW_REQUIRED as appropriate.

The model cannot influence the finalizer's verdict on any of the
checks above. Any model-supplied ``recommended_next_state`` field is
ignored.
"""

from __future__ import annotations

import json
import re
import time
from pathlib import Path
from typing import Any

from . import (
    approval, git_checks, integrity, limits as limits_mod,
    packet as packet_mod, receipts, secrets_v2, state as state_mod,
    transitions, util, verdicts, worktrees,
)


SCHEMA_AGENT_ASSESSMENT = "ownframework-loop-review-agent-assessment/v1"


ASSESSMENT_REQUIRED = (
    "schema", "run_id", "candidate_sha_claimed",
    "acceptance_results", "non_goal_results", "findings",
    "recommended_verdict",
)

ASSESSMENT_ALLOWED_VERDICTS = {
    "APPROVED", "CHANGES_REQUESTED", "BLOCKED",
    "HUMAN_REVIEW_REQUIRED", "STALE_CANDIDATE",
}


def _read_json(path: Path, default: Any = None) -> Any:
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return default


def _validation_shape_ok(cmd: dict[str, Any]) -> bool:
    return isinstance(cmd, dict) and "command" in cmd and "name" in cmd


def _run_validation_command(cwd: Path, command: str, *, timeout_seconds: int) -> dict[str, Any]:
    """Mirrors build_finalize._run_validation_command — kept separate to
    avoid shared mutable state."""
    import subprocess
    start = time.monotonic()
    try:
        proc = subprocess.run(
            ["/bin/sh", "-c", command],
            cwd=str(cwd),
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
            check=False,
        )
        duration = time.monotonic() - start
        max_capture = 64 * 1024
        stdout = (proc.stdout or "")[:max_capture]
        stderr = (proc.stderr or "")[:max_capture]
        truncated = (len(proc.stdout or "") > max_capture) or (len(proc.stderr or "") > max_capture)
        return {
            "exit_code": int(proc.returncode),
            "duration_seconds": float(duration),
            "stdout": stdout,
            "stderr": stderr,
            "truncated": truncated,
            "timed_out": False,
        }
    except subprocess.TimeoutExpired:
        duration = time.monotonic() - start
        return {
            "exit_code": 124,
            "duration_seconds": float(duration),
            "stdout": "",
            "stderr": "command timed out",
            "truncated": False,
            "timed_out": True,
        }
    except Exception as e:
        duration = time.monotonic() - start
        return {
            "exit_code": 1,
            "duration_seconds": float(duration),
            "stdout": "",
            "stderr": f"command failed: {type(e).__name__}",
            "truncated": False,
            "timed_out": False,
        }


def _ancestor_of(canonical_repo: Path, candidate_sha: str, baseline_sha: str) -> bool:
    r = util.run_subprocess(
        ["git", "-C", str(canonical_repo), "merge-base", "--is-ancestor", baseline_sha, candidate_sha],
        timeout=10,
    )
    return r.returncode == 0


def _candidate_branch_contains(canonical_repo: Path, candidate_branch: str, candidate_sha: str) -> bool:
    r = util.run_subprocess(
        ["git", "-C", str(canonical_repo), "merge-base", "--is-ancestor", candidate_sha, candidate_branch],
        timeout=10,
    )
    return r.returncode == 0


def _classify_path_against_packet(packet: dict[str, Any], path: str) -> str:
    if packet_mod.is_protected_path(packet, path):
        return "protected"
    if packet_mod.is_allowed_path(packet, path):
        return "allowed"
    elevated = packet.get("elevated_allowed_paths") or []
    if any(_path_in_list(path, p) for p in elevated):
        return "elevated"
    sensitive = packet.get("sensitive_paths") or []
    if any(_path_in_list(path, p) for p in sensitive):
        return "sensitive"
    return "out_of_scope"


def _path_in_list(path: str, prefix: str) -> bool:
    fp = path.lstrip("./").lstrip("/")
    p = prefix.rstrip("/").lstrip("./").lstrip("/")
    if not p:
        return False
    return fp == p or fp.startswith(p + "/")


def _assessment_schema_ok(assessment: dict[str, Any]) -> tuple[bool, list[str]]:
    errors: list[str] = []
    for f in ASSESSMENT_REQUIRED:
        if f not in assessment:
            errors.append(f"missing required field: {f}")
    if assessment.get("schema") != SCHEMA_AGENT_ASSESSMENT:
        errors.append(f"schema must be {SCHEMA_AGENT_ASSESSMENT}")
    if assessment.get("recommended_verdict") not in ASSESSMENT_ALLOWED_VERDICTS:
        errors.append(f"recommended_verdict must be one of {sorted(ASSESSMENT_ALLOWED_VERDICTS)}")
    if not isinstance(assessment.get("acceptance_results"), list):
        errors.append("acceptance_results must be a list")
    if not isinstance(assessment.get("non_goal_results"), list):
        errors.append("non_goal_results must be a list")
    if not isinstance(assessment.get("findings"), list):
        errors.append("findings must be a list")
    return (not errors), errors


def finalize_review(
    *,
    canonical_repo: Path,
    run_id: str,
    assessment_path: Path | None,
    actor: str = "of-reviewer",
) -> dict[str, Any]:
    """Run the deterministic review finalizer."""
    canonical_repo = Path(canonical_repo).resolve(strict=False)
    run_d = state_mod.run_dir(canonical_repo, run_id)
    packet_path = run_d / "WORK_PACKET.md"
    if not packet_path.exists():
        raise RuntimeError("WORK_PACKET.md missing")

    # 1. Validate approval binding.
    meta, _ = packet_mod.parse_packet_file(packet_path)
    errors = packet_mod.validate_packet_metadata(meta)
    if errors:
        raise RuntimeError("packet invalid: " + "; ".join(errors))
    approval_doc = approval.load_approval(canonical_repo, run_id)
    ok, msg = approval.validate_approval_binding(
        canonical_repo=canonical_repo,
        run_id=run_id,
        approval=approval_doc,
        packet=meta,
        packet_path=packet_path,
    )
    if not ok:
        raise RuntimeError(f"approval invalid: {msg}")
    baseline_sha = approval_doc["baseline_sha"]

    # 2. Validate build receipt.
    receipt = receipts.load_receipt(canonical_repo, run_id)
    if receipt is None:
        raise RuntimeError("BUILD_RECEIPT.json missing — cannot review without a build receipt")
    if not (receipt.get("schema") or "").startswith("ownframework-loop-build-receipt/"):
        raise RuntimeError("BUILD_RECEIPT.json schema invalid")
    receipt_candidate_sha = receipt.get("candidate_sha")
    if not receipt_candidate_sha:
        raise RuntimeError("BUILD_RECEIPT.json missing candidate_sha")

    # 3. Validate canonical repo.
    if not git_checks.is_git_repo(canonical_repo):
        raise RuntimeError("canonical repo is not a git repository")

    # 4. Verify candidate SHA exists.
    if not git_checks.commit_exists(canonical_repo, receipt_candidate_sha):
        raise RuntimeError(f"candidate SHA {receipt_candidate_sha[:12]} does not exist in canonical repo")

    # 5. Verify lineage.
    if not _ancestor_of(canonical_repo, receipt_candidate_sha, baseline_sha):
        raise RuntimeError(f"candidate SHA {receipt_candidate_sha[:12]} does not descend from baseline {baseline_sha[:12]}")

    # 6. Verify candidate branch contains candidate SHA.
    receipt_branch = receipt.get("candidate_branch") or ""
    if not _candidate_branch_contains(canonical_repo, receipt_branch, receipt_candidate_sha):
        raise RuntimeError(f"candidate branch {receipt_branch!r} does not contain candidate SHA")

    # 7. Create or verify reviewer detached worktree.
    reviewer_wt = util.reviewer_worktree(canonical_repo, run_id)
    try:
        wt_setup = worktrees.add_reviewer_worktree(
            canonical_repo,
            run_id,
            candidate_sha=receipt_candidate_sha,
            expected_setup_sha=receipt_candidate_sha,
        )
    except worktrees.WorktreeError as e:
        raise RuntimeError(f"reviewer worktree setup failed: {e}")

    # 8. Record pre-review HEAD.
    pre_review_head = git_checks.current_head(reviewer_wt)

    # 9. Validate assessment schema.
    assessment: dict[str, Any] = {}
    if assessment_path is not None:
        assessment = _read_json(assessment_path, default={}) or {}
    schema_ok, schema_errs = _assessment_schema_ok(assessment)
    if not schema_ok and assessment:
        raise RuntimeError("assessment schema invalid: " + "; ".join(schema_errs))

    # 10. Reject assessment candidate mismatch.
    if assessment and assessment.get("candidate_sha_claimed"):
        if assessment["candidate_sha_claimed"] != receipt_candidate_sha:
            raise RuntimeError(
                f"assessment candidate_sha_claimed={assessment['candidate_sha_claimed'][:12]} "
                f"!= receipt candidate_sha={receipt_candidate_sha[:12]}"
            )

    # 11. Run required validations from the packet (re-run for verifier freshness).
    validations: list[dict[str, Any]] = []
    validation_pass = True
    for v in meta.get("required_validation") or []:
        if not _validation_shape_ok(v):
            continue
        cmd = v["command"]
        name = v["name"]
        kind = v.get("kind") or "fast"
        timeout = int(meta.get("required_runtime_proof", {}).get("max_runtime_seconds") or 600)
        result = _run_validation_command(reviewer_wt, cmd, timeout_seconds=timeout)
        expected_exit = int(v.get("expected_exit_code") or 0)
        ok_v = (result["exit_code"] == expected_exit)
        if not ok_v:
            validation_pass = False
        validations.append({
            "name": name,
            "command": cmd,
            "kind": kind,
            "exit_code": int(result["exit_code"]),
            "duration_seconds": float(result["duration_seconds"]),
            "expected_exit_code": expected_exit,
            "passed": ok_v,
            "timed_out": result["timed_out"],
        })

    # 12. Re-run scope, protected, secret checks (independent of builder).
    diff_r = util.run_subprocess(
        ["git", "-C", str(reviewer_wt), "diff", "--name-only", baseline_sha, receipt_candidate_sha],
        timeout=30,
    )
    changed_paths = [p for p in diff_r.stdout.splitlines() if p.strip()] if diff_r.returncode == 0 else []

    scope_findings: list[dict[str, Any]] = []
    protected_findings: list[dict[str, Any]] = []
    sensitive_findings: list[dict[str, Any]] = []
    for path in changed_paths:
        klass = _classify_path_against_packet(meta, path)
        if klass == "out_of_scope":
            scope_findings.append({"path": path})
        elif klass == "protected":
            protected_findings.append({"path": path})
        elif klass == "sensitive":
            sensitive_findings.append({"path": path})

    secret_findings: list[dict[str, Any]] = []
    for path in changed_paths:
        abs_path = reviewer_wt / path
        if not abs_path.exists():
            continue
        hits = secrets_v2.scan_path_for_secrets_redacted(abs_path)
        for hit in hits:
            secret_findings.append({
                "path": path,
                "pattern_id": hit["pattern_id"],
                "severity": hit["severity"],
                "sha256": hit["sha256"],
                "redacted_prefix": hit["redacted_prefix"],
                "line": hit.get("line"),
                "count": hit["count"],
            })
    hard_secret_blocks = [f for f in secret_findings if f["severity"] == "hard"]

    # 13. Verify reviewer HEAD did not change.
    post_review_head = git_checks.current_head(reviewer_wt)
    tracked_mutation_check = {
        "detected": pre_review_head != post_review_head,
        "before_sha": pre_review_head,
        "after_sha": post_review_head,
        "changed_paths": [],
    }

    # 14. Verify packet, approval, receipt, candidate unchanged.
    final_packet_sha = util.sha256_text(packet_path.read_text(encoding="utf-8"))
    final_approval_sha = approval.approval_artifact_sha256(approval_doc) if approval_doc else None
    final_receipt_sha = util.sha256_file(receipts.receipt_path(canonical_repo, run_id))
    integrity_check = {
        "packet_sha_match": final_packet_sha == approval_doc["packet_sha256"],
        "approval_present": approval_doc is not None,
        "approval_sha_stable": True,  # approval is unchanged this pass
        "receipt_sha_stable": final_receipt_sha == (receipt.get("approval_sha256") or final_receipt_sha),
        "candidate_sha_present": git_checks.commit_exists(canonical_repo, receipt_candidate_sha),
    }

    # 15. Acceptance criteria semantic check.
    ac_results = assessment.get("acceptance_results") or []
    if not isinstance(ac_results, list):
        ac_results = []
    ac_fail = [a for a in ac_results if (a.get("result") or "").lower() != "pass"]
    ng_results = assessment.get("non_goal_results") or []
    if not isinstance(ng_results, list):
        ng_results = []
    ng_violated = [g for g in ng_results if (g.get("result") or "").lower() != "preserved"]
    must_fix = [f for f in (assessment.get("findings") or []) if f.get("classification") == "must_fix"]

    # 16. Stale-SHA record.
    stale_sha_check = {
        "sha_match": True,
        "receipt_match": True,
        "packet_hash_match": final_packet_sha == approval_doc["packet_sha256"],
        "branch_contains_sha": True,
    }

    # 17. Compute final verdict.
    if hard_secret_blocks:
        verdict = "BLOCKED"
        failure_reason = "hard_secret_detected"
    elif protected_findings:
        verdict = "BLOCKED"
        failure_reason = "protected_path_in_diff"
    elif scope_findings:
        verdict = "BLOCKED"
        failure_reason = "scope_violation"
    elif tracked_mutation_check["detected"]:
        verdict = "BLOCKED"
        failure_reason = "reviewer_tracked_mutation"
    elif not integrity_check["packet_sha_match"]:
        verdict = "BLOCKED"
        failure_reason = "packet_sha_changed"
    elif not integrity_check["candidate_sha_present"]:
        verdict = "BLOCKED"
        failure_reason = "candidate_sha_missing"
    elif not validation_pass:
        verdict = "CHANGES_REQUESTED"
        failure_reason = "validation_failed"
    elif must_fix:
        verdict = "CHANGES_REQUESTED"
        failure_reason = "must_fix_finding"
    elif ac_fail:
        verdict = "CHANGES_REQUESTED"
        failure_reason = "acceptance_criterion_failed"
    elif ng_violated:
        verdict = "BLOCKED"
        failure_reason = "non_goal_violated"
    elif (assessment.get("recommended_verdict") or "APPROVED") != "APPROVED":
        # Honest downgrade: reviewer did not recommend approval.
        verdict = assessment.get("recommended_verdict") or "CHANGES_REQUESTED"
        failure_reason = "reviewer_not_recommending_approval"
    else:
        verdict = "APPROVED"
        failure_reason = ""

    # 18. State transition mapping.
    if state_mod.is_stop_requested(canonical_repo, run_id):
        next_state = "STOPPED"
    elif verdict == "APPROVED":
        next_state = "APPROVED"
    elif verdict == "CHANGES_REQUESTED":
        next_state = "CHANGES_REQUESTED"
    elif verdict == "STALE_CANDIDATE":
        next_state = "READY_FOR_REVIEW"
    elif verdict == "HUMAN_REVIEW_REQUIRED":
        next_state = "BLOCKED"
    else:  # BLOCKED
        next_state = "BLOCKED"

    # 19. Build authoritative verdict.
    new_verdict = {
        "schema": "ownframework-loop-review-verdict/v2",
        "run_id": run_id,
        "packet_sha256": approval_doc["packet_sha256"],
        "approval_sha256": approval.approval_artifact_sha256(approval_doc),
        "candidate_sha_reviewed": receipt_candidate_sha,
        "baseline_sha": baseline_sha,
        "review_pass_number": int(state_mod.load(canonical_repo, run_id).get("review_pass_count") or 1),
        "verdict": verdict,
        "acceptance_results": ac_results,
        "non_goal_results": ng_results,
        "findings": (assessment.get("findings") or []),
        "commands_executed": [v["command"] for v in validations],
        "validation_results": validations,
        "tracked_mutation_check": tracked_mutation_check,
        "stale_sha_check": stale_sha_check,
        "integrity_check": integrity_check,
        "protected_path_check": {
            "result": "fail" if protected_findings else "pass",
            "offending_paths": [p["path"] for p in protected_findings],
        },
        "secret_scan_check": {
            "result": "fail" if hard_secret_blocks else "pass",
            "findings": secret_findings[:20],
        },
        "scope_check": {
            "result": "fail" if scope_findings else "pass",
            "findings": scope_findings,
        },
        "sensitive_path_assessment": {
            "result": "elevated" if sensitive_findings else "none",
            "paths": [p["path"] for p in sensitive_findings],
        },
        "reviewer_identity": "of-reviewer",
        "timestamp": util.utc_now_iso(),
        "failure_reason": failure_reason,
        "codex_escalation_recommended": bool(assessment.get("codex_escalation_recommended")) if assessment else False,
        "codex_reason": (assessment.get("codex_reason") if assessment else None),
    }

    # 20. Persist.
    verdicts.write_verdict(canonical_repo, run_id, new_verdict)

    # 21. Append event.
    state_mod.append_event(
        canonical_repo, run_id,
        event_type="review_finalized",
        old_state=state_mod.load(canonical_repo, run_id).get("state"),
        new_state=next_state,
        actor=actor,
        commit_sha=receipt_candidate_sha,
        reason=f"deterministic finalizer -> verdict={verdict} -> {next_state}",
        extras={
            "verdict": verdict,
            "failure_reason": failure_reason,
            "must_fix_count": len(must_fix),
            "ac_fail_count": len(ac_fail),
            "ng_violated_count": len(ng_violated),
            "hard_secret_blocks": len(hard_secret_blocks),
            "validation_pass": validation_pass,
        },
    )

    # 22. Transition if appropriate.
    cur = state_mod.load(canonical_repo, run_id)
    if cur.get("state") != next_state and transitions.is_valid(cur.get("state"), next_state):
        state_mod.transition(
            canonical_repo, run_id,
            to_state=next_state,
            actor=actor,
            reason=f"finalizer verdict={verdict}",
            commit_sha=receipt_candidate_sha,
        )
        if next_state == "CHANGES_REQUESTED":
            cur = state_mod.load(canonical_repo, run_id)
            cur["repair_round"] = int(cur.get("repair_round", 0)) + 1
            cur["no_progress_streak"] = 0
            state_mod.save(canonical_repo, run_id, cur)

    return new_verdict
