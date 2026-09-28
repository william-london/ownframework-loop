"""Narrow recovery for an accepted review blocked only by validator infrastructure.

This is not a PROGRAM continuation: it does not claim a semantic pass, fund a
repair, or change candidate authority.  It replays the exact accepted review
artifact after the same packet validations pass under the current commissioned
environment, then lets the ordinary supervisor perform deterministic review
finalization.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sqlite3
import stat
import time
from pathlib import Path
from typing import Any

from . import (
    approval,
    assessment,
    capabilities,
    capability_binding,
    dispatch,
    git_checks,
    integrity,
    packet,
    program,
    receipts,
    runner_profiles,
    runtime_env,
    state,
    util,
    validation_executor,
    validation_evidence,
    verdicts,
    worktrees,
)

SCHEMA = "ownframework-loop-validation-infrastructure-recovery/v1"
_ACTOR = "ofloop-validation-infrastructure-recovery"
_PROFILE_IDENTITY_KEYS = ("name", "provider", "model", "effort", "identity_sha256", "effort_attestation")


def _canonical_sha(value: Any) -> str:
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()
    ).hexdigest()


def _failure(reason: str, **extra: Any) -> dict[str, Any]:
    return {"schema": SCHEMA, "ok": False, "reason": reason, **extra}


def _write_exact_private(path: Path, data: bytes) -> None:
    """Publish exact evidence without replacement; repeated identical writes pass."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    if path.exists():
        st = path.lstat()
        if not stat.S_ISREG(st.st_mode) or path.is_symlink():
            raise RuntimeError("recovery evidence target is not a regular file")
        if path.read_bytes() != data:
            raise RuntimeError("recovery evidence collision")
        os.chmod(path, 0o600)
        return
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
    except Exception:
        try:
            path.unlink()
        except OSError:
            pass
        raise
    os.chmod(path, 0o600)
    util.fsync_dir(path.parent)


def _write_exact_private_json(path: Path, payload: dict[str, Any]) -> None:
    _write_exact_private(
        path,
        (json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=True) + "\n").encode(),
    )


def _bound_uv_domains(binding: dict[str, Any]) -> set[str]:
    projection = binding.get("projection") or {}
    capabilities_list = projection.get("capabilities") or []
    for capability in capabilities_list:
        if isinstance(capability, dict) and capability.get("name") == "package.uv":
            return {
                str(domain).strip().rstrip(".").lower()
                for domain in capability.get("network_domains", [])
                if isinstance(domain, str) and domain.strip()
            }
    return set()


def _proves_permitted_registry_dns_failure(
    row: dict[str, Any], *, allowed_domains: set[str], canonical_repo: Path,
    run_id: str, checkpoint_id: str, candidate_sha: str,
    review_pass_number: int,
) -> dict[str, Any] | None:
    """Return the digest of exact, durable broker evidence for a DNS failure.

    Candidate-controlled output is deliberately irrelevant. The evidence must
    be run-owned, immutable, pass/candidate/command-bound, and report a host
    inside the frozen package.uv network authority.
    """
    if (
        row.get("passed") is not False
        or row.get("infra_failure") is not True
        or row.get("candidate_invalid") is True
        or not allowed_domains
        or row.get("checkpoint_id") != checkpoint_id
        or row.get("pass_number") != review_pass_number
        or isinstance(row.get("validation_index"), bool)
        or not isinstance(row.get("validation_index"), int)
        or row.get("validation_index") < 0
    ):
        return None
    reference = row.get("infrastructure_evidence")
    if not isinstance(reference, dict):
        return None
    identity = validation_evidence.validation_identity(
        canonical_repo=canonical_repo,
        run_id=run_id,
        checkpoint_id=checkpoint_id,
        role="reviewer",
        pass_number=review_pass_number,
        validation_index=row["validation_index"],
        candidate_sha=candidate_sha,
        cwd=util.reviewer_worktree(canonical_repo, run_id),
        validation={
            "name": row.get("name"),
            "command": row.get("command"),
            "kind": row.get("kind"),
            "expected_exit_code": row.get("expected_exit_code", 0),
            "expected_marker": row.get("expected_marker"),
        },
    )
    try:
        record, digest = validation_evidence.verify_reference(
            canonical_repo=canonical_repo,
            run_id=run_id,
            reference=reference,
            expected_identity=identity,
        )
    except (OSError, RuntimeError, ValueError):
        return None
    if not validation_evidence.proves_registry_dns_failure(
        record=record, allowed_domains=allowed_domains,
    ):
        return None
    first = (record.get("package_network_events") or [None])[0]
    if not isinstance(first, dict) or (
        first.get("kind") != "dns_resolution_failed"
        or row.get("infra_failure_reason")
        != f"package_registry_dns_resolution_failed:{first.get('host')}"
    ):
        return None
    return {
        "sha256": digest,
        "reference": dict(reference),
        "identity": identity,
    }


def _preflight_result_sha(results: list[dict[str, Any]]) -> str:
    return _canonical_sha([
        {key: row.get(key) for key in ("name", "command", "passed", "exit_code", "stdout_sha256", "stderr_sha256")}
        for row in results
    ])


def _validation_recovery_events(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        event for event in events
        if event.get("event_type") == "program_review_infrastructure_retry"
    ]


def _event_matches(event: dict[str, Any], *, attempt_id: str, candidate_sha: str) -> bool:
    return (
        event.get("review_attempt_id") == attempt_id
        and event.get("candidate_sha") == candidate_sha
    )


def _active_checkpoint(packet_meta: dict[str, Any], state_doc: dict[str, Any]) -> tuple[str, dict[str, Any], dict[str, Any]]:
    program_state = state_doc.get("program") or {}
    cp_id = program.select_next_checkpoint(packet_meta, program_state)
    cp_packet = next(
        (item for item in (packet_meta.get("checkpoint_graph") or {}).get("checkpoints", [])
         if isinstance(item, dict) and item.get("id") == cp_id),
        None,
    )
    cp_state = next(
        (item for item in program_state.get("checkpoints", [])
         if isinstance(item, dict) and item.get("id") == cp_id),
        None,
    )
    if not cp_id or cp_packet is None or cp_state is None:
        raise RuntimeError("active checkpoint is not present in the frozen packet and state")
    return str(cp_id), cp_packet, cp_state


def _assert_counter_mirrors(state_doc: dict[str, Any], cp_state: dict[str, Any]) -> None:
    cumulative = (state_doc.get("program") or {}).get("cumulative_counters") or {}
    mirrors = (
        ("build_pass_count", "build_pass_count"),
        ("review_pass_count", "review_pass_count"),
        ("repair_round", "repair_round_count"),
    )
    for state_key, program_key in mirrors:
        if int(state_doc.get(state_key) or 0) != int(cumulative.get(program_key) or 0):
            raise RuntimeError(f"PROGRAM counter mirror drift: {state_key}")
    for key in ("build_pass_count", "review_pass_count", "repair_round_count"):
        if int(cp_state.get(key) or 0) < 0:
            raise RuntimeError(f"checkpoint counter invalid: {key}")


def _assert_clean_candidate_worktrees(repo: Path, run_id: str, branch: str, candidate: str) -> None:
    for role, path in (("builder", util.builder_worktree(repo, run_id)),):
        if not path.is_dir() or not worktrees.is_registered_worktree(repo, path):
            raise RuntimeError(f"{role} worktree is missing or not registered")
        if git_checks.current_branch(path) != branch:
            raise RuntimeError(f"{role} worktree branch does not match sealed candidate branch")
        if git_checks.current_head(path) != candidate:
            raise RuntimeError(f"{role} worktree HEAD does not match exact candidate")
        if git_checks.dirty_status(path) != "clean":
            raise RuntimeError(f"{role} worktree is not clean")
    reviewer = util.reviewer_worktree(repo, run_id)
    if not reviewer.is_dir() or not worktrees.is_registered_worktree(repo, reviewer):
        raise RuntimeError("reviewer worktree is missing or not registered")
    # REVIEW preparation intentionally detaches the verifier at the immutable
    # candidate SHA; the shared candidate branch remains builder-owned.
    if git_checks.current_head(reviewer) != candidate:
        raise RuntimeError("reviewer worktree HEAD does not match exact candidate")
    if git_checks.dirty_status(reviewer) != "clean":
        raise RuntimeError("reviewer worktree is not clean")


def _validate_predecessor_evidence(
    *, repo: Path, run_id: str, candidate: str, attempt_id: str,
    packet_meta: dict[str, Any], packet_sha: str, approval_doc: dict[str, Any],
    approval_sha: str, state_doc: dict[str, Any], cp_id: str,
    cp_packet: dict[str, Any], cp_state: dict[str, Any],
    job: sqlite3.Row, attempt: sqlite3.Row,
    db_conn: sqlite3.Connection, prior_binding: dict[str, Any],
    supervisor_mod: Any,
) -> tuple[dict[str, Any], dict[str, Any], bytes, str, dict[str, Any], str]:
    if cp_packet.get("id") != cp_id or cp_state.get("id") != cp_id:
        raise RuntimeError("active checkpoint identity does not match frozen packet and state")
    receipt = receipts.load_receipt(repo, run_id)
    if not isinstance(receipt, dict):
        raise RuntimeError("authoritative BUILD_RECEIPT is missing or unreadable")  # noqa: TRY004 - this is a failed authority precondition.
    receipts.validate_receipt_contract(receipt)
    receipt_sha = util.sha256_file(receipts.receipt_path(repo, run_id))
    if any((
        receipt.get("run_id") != run_id,
        receipt.get("packet_sha256") != packet_sha,
        receipt.get("approval_sha256") != approval_sha,
        receipt.get("baseline_sha") != approval_doc.get("baseline_sha"),
        receipt.get("candidate_sha") != candidate,
        receipt.get("candidate_branch") != job["candidate_branch"],
        receipt.get("validation_status") != receipts.VALIDATION_STATUS_PASS,
        receipt.get("next_state") != "READY_FOR_REVIEW",
    )):
        raise RuntimeError("BUILD_RECEIPT does not bind the approved packet and exact candidate")
    for key in ("scope_check", "protected_path_check", "secret_scan_check"):
        if (receipt.get(key) or {}).get("result") != "pass":
            raise RuntimeError(f"BUILD_RECEIPT {key} is not passing")
    if int(receipt.get("builder_pass_number") or 0) != int(state_doc.get("build_pass_count") or 0):
        raise RuntimeError("BUILD_RECEIPT does not describe the latest claimed builder pass")

    verdict_path = verdicts.verdict_path(repo, run_id)
    if verdict_path.is_symlink() or not verdict_path.is_file():
        raise RuntimeError("authoritative REVIEW_VERDICT is missing or redirected")
    verdict_bytes = verdict_path.read_bytes()
    verdict_sha = util.sha256_bytes(verdict_bytes)
    verdict = verdicts.load_verdict(repo, run_id)
    if not isinstance(verdict, dict):
        raise RuntimeError("authoritative REVIEW_VERDICT is malformed")  # noqa: TRY004 - this is a failed authority precondition.
    verdicts.validate_verdict_contract(verdict)
    if any((
        verdict.get("run_id") != run_id,
        verdict.get("candidate_sha_reviewed") != candidate,
        verdict.get("packet_sha256") != packet_sha,
        verdict.get("approval_sha256") != approval_sha,
        verdict.get("baseline_sha") != approval_doc.get("baseline_sha"),
        verdict.get("review_pass_number") != int(state_doc.get("review_pass_count") or 0),
        verdict.get("verdict") != "BLOCKED",
        verdict.get("failure_reason") != "infra_failure",
    )):
        raise RuntimeError("latest review verdict is not the exact infrastructure-only block")
    if (verdict.get("infra_failure") or {}).get("count") != 1:
        raise RuntimeError("prior verdict does not contain exactly one infrastructure failure")
    if (verdict.get("candidate_environment_invalid") or {}).get("count") != 0:
        raise RuntimeError("prior verdict contains candidate-environment failure")
    for key in ("scope_check", "protected_path_check", "secret_scan_check", "integrity_check", "stale_sha_check"):
        value = verdict.get(key) or {}
        if value.get("result") == "fail" or value.get("sha_match") is False or value.get("packet_hash_match") is False:
            raise RuntimeError(f"prior review verdict has non-validation blocker: {key}")
    validation_rows = verdict.get("validation_results")
    failed_rows = [
        row for row in validation_rows or []
        if isinstance(row, dict) and row.get("passed") is False
    ]
    if len(failed_rows) != 1 or len(validation_rows or []) != 1:
        raise RuntimeError("prior review must contain exactly one failed packet validation")
    effective_validations = program.resolve_effective_required_validation(packet_meta, state_doc)
    failed = failed_rows[0]
    validation_index = failed.get("validation_index")
    if (
        isinstance(validation_index, bool)
        or not isinstance(validation_index, int)
        or validation_index < 0
        or validation_index >= len(effective_validations)
    ):
        raise RuntimeError("failed review validation has no valid declared index")
    declared_validation = effective_validations[validation_index]
    if any(
        declared_validation.get(key, default) != failed.get(key, default)
        for key, default in (
            ("name", "validation"),
            ("command", ""),
            ("kind", "fast"),
            ("expected_exit_code", 0),
            ("expected_marker", None),
        )
    ):
        raise RuntimeError("failed review validation is not declared by the frozen packet")
    validation_evidence_binding = _proves_permitted_registry_dns_failure(
        failed,
        allowed_domains=_bound_uv_domains(prior_binding),
        canonical_repo=repo,
        run_id=run_id,
        checkpoint_id=cp_id,
        candidate_sha=candidate,
        review_pass_number=int(verdict.get("review_pass_number") or 0),
    )
    if not validation_evidence_binding:
        raise RuntimeError("prior failure lacks exact durable package-registry DNS evidence")
    if any(row.get("result") != "pass" for row in (verdict.get("acceptance_results") or [])):
        raise RuntimeError("prior verdict contains failed acceptance criteria")
    if any(row.get("result") == "violated" for row in (verdict.get("non_goal_results") or [])):
        raise RuntimeError("prior verdict contains a non-goal violation")

    assessment_path = assessment.assessment_path(repo, run_id)
    assessment_doc = util.read_private_json(assessment_path, default=None)
    if not isinstance(assessment_doc, dict):
        raise RuntimeError("latest reviewer semantic assessment is missing")  # noqa: TRY004 - this is a failed authority precondition.
    assessment_errors = assessment.validate_assessment_contract(assessment_doc)
    if assessment_errors:
        raise RuntimeError("reviewer assessment contract invalid: " + "; ".join(assessment_errors[:8]))
    if (
        assessment_doc.get("recommended_verdict") != "APPROVED"
        or assessment_doc.get("run_id") != run_id
        or assessment_doc.get("candidate_sha_claimed") != candidate
        or any(row.get("result") != "pass" for row in assessment_doc.get("acceptance_results", []))
        or any(row.get("result") != "preserved" for row in assessment_doc.get("non_goal_results", []))
        or any(row.get("classification") == "must_fix" for row in assessment_doc.get("findings", []))
    ):
        raise RuntimeError("accepted reviewer assessment is not an exact clean approval recommendation")

    if (
        str(job["latest_attempt_id"] or "") != attempt_id
        or str(attempt["attempt_id"] or "") != attempt_id
        or str(attempt["role"] or "") != "reviewer"
        or str(attempt["status"] or "") != "COMPLETED"
        or not bool(int(attempt["semantic_accepted"] or 0))
        or not bool(int(attempt["cost_accounted"] or 0))
        or not bool(int(attempt["cost_known"] or 0))
        or not bool(int(attempt["tokens_known"] or 0))
        or attempt["failure_class"]
        or attempt["failure_reason"]
        or str(attempt["accepted_candidate_sha"] or "") != candidate
    ):
        raise RuntimeError("review attempt is not the latest accounted accepted provider result")
    semantic_path = assessment_path
    semantic_sha = hashlib.sha256(semantic_path.read_bytes()).hexdigest()
    if str(attempt["accepted_semantic_sha256"] or "") != semantic_sha:
        raise RuntimeError("accepted reviewer semantic artifact SHA does not match current bytes")
    if "review_pass_number" in attempt.keys() and (  # noqa: SIM118 - sqlite3.Row requires keys() for key membership.
        int(attempt["review_pass_number"] or 0)
        != int(state_doc.get("review_pass_count") or 0)
    ):
        raise RuntimeError("review attempt pass identity does not match current checkpoint")

    work_order = {
        "schema": dispatch.SCHEMA,
        "decision": "REVIEW",
        "role": "reviewer",
        "run_id": run_id,
        "canonical_repo": str(repo),
        "worktree": str(util.reviewer_worktree(repo, run_id)),
        "semantic_path": str(semantic_path),
        "candidate_sha": candidate,
    }
    ready, ready_reason = dispatch.semantic_result_ready(work_order)
    if not ready:
        raise RuntimeError(f"accepted reviewer assessment is not replay-ready: {ready_reason}")
    gate_ok, gate_reason, _cap_receipt = supervisor_mod._attempt_provenance_gate(
        db_conn, job=job, work_order=work_order, attempt_id=attempt_id
    )
    if not gate_ok:
        raise RuntimeError(f"accepted reviewer attempt provenance failed: {gate_reason}")

    events = integrity.read_event_chain(state.events_path(repo, run_id))
    if not events:
        raise RuntimeError("event chain lacks the infrastructure-blocking review")
    review_event = events[-1]
    evidence_refs = validation_evidence.event_references(validation_rows or [])
    if any((
        review_event.get("event_type") != "review_finalized",
        review_event.get("new_state") != "BLOCKED",
        review_event.get("failure_reason") != "infra_failure",
        review_event.get("verdict") != "BLOCKED",
        review_event.get("validation_pass") is not False,
        review_event.get("infra_failure_count") != 1,
        review_event.get("validation_evidence_refs") != evidence_refs,
        review_event.get("review_verdict_sha256") != verdict_sha,
        review_event.get("commit_sha") != candidate,
        review_event.get("packet_sha256") != packet_sha,
        review_event.get("build_receipt_sha256") != receipt_sha,
        state_doc.get("state") != "BLOCKED",
    )):
        raise RuntimeError("durable history does not bind the blocked review to its validation evidence")
    validation_evidence_sha256 = str(validation_evidence_binding["sha256"])
    if not any(ref.get("sha256") == validation_evidence_sha256 for ref in evidence_refs):
        raise RuntimeError("blocked review event does not bind the verified durable evidence")
    if (state_doc.get("program") or {}).get("blocked") is True:
        raise RuntimeError("PROGRAM authority itself is terminally blocked")
    if state.is_stop_requested(repo, run_id):
        raise RuntimeError("STOP request prevents validation-infrastructure recovery")
    return (
        receipt, verdict, verdict_bytes, semantic_sha, work_order,
        validation_evidence_binding,
    )


def _resolve_current_binding(*, repo: Path, run_id: str, packet_meta: dict[str, Any], job: sqlite3.Row, prior_binding: dict[str, Any], supervisor_mod: Any) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any], str]:
    requested = packet_meta.get("capabilities")
    if not isinstance(requested, list) or not all(isinstance(item, str) for item in requested):
        raise RuntimeError("sealed capability request is malformed")
    runner = supervisor_mod._runner(str(job["runner"] or ""))
    provider = str(getattr(runner, "runner_id", job["runner"]))
    profile = runner_profiles.resolve_profile(
        str(packet_meta.get("runner_profile") or "default"), provider=provider
    )
    runner_profiles.verify_profile_integrity(profile)
    attestation = runner_profiles.verify_effort_attestation(profile)
    if attestation is not None:
        profile = dict(profile)
        profile["effort_attestation"] = attestation
    old_profile = ((prior_binding.get("projection") or {}).get("requested_runner_profile") or {})
    if any(old_profile.get(key) != profile.get(key) for key in _PROFILE_IDENTITY_KEYS):
        raise RuntimeError("current runner profile/model/effort differs from the immutable run authority")
    old_requested = list((prior_binding.get("projection") or {}).get("requested") or [])
    if old_requested != list(requested):
        raise RuntimeError("current capability request differs from the sealed run envelope")
    resolution = capabilities.resolve_capabilities(
        [str(item) for item in requested],
        canonical_repo=repo,
        role="reviewer",
        repo_cache_root=runtime_env.repo_tool_cache_dir(repo),
        ephemeral_cache_root=(
            runtime_env.runtime_cache_dir(repo, run_id, "validation")
            / "capability-cache"
        ),
        packet_network_allowlist=[str(item) for item in (packet_meta.get("network_read_allowlist") or [])],
    )
    capability_binding._assert_runtime_ready_resolution(resolution, requested)
    projection = capability_binding.stable_projection(resolution, profile)
    desired = capability_binding._binding_document(run_id, projection)
    return resolution, profile, desired, provider


def _validation_preflight(*, repo: Path, run_id: str, packet_meta: dict[str, Any], state_doc: dict[str, Any], candidate: str) -> tuple[list[dict[str, Any]], str]:
    validations = program.resolve_effective_required_validation(packet_meta, state_doc)
    if not validations:
        raise RuntimeError("checkpoint has no effective validation contract to preflight")
    results: list[dict[str, Any]] = []
    checkpoint_id = str(
        program.select_next_checkpoint(packet_meta, state_doc.get("program") or {}) or ""
    )
    for validation_index, item in enumerate(validations):
        result = validation_executor.run_required_validation(
            cwd=util.reviewer_worktree(repo, run_id),
            validation=item,
            timeout_seconds=int((packet_meta.get("required_runtime_proof") or {}).get("max_runtime_seconds") or 600),
            canonical_repo=repo,
            run_id=run_id,
            packet=packet_meta,
            candidate_sha=candidate,
            role="reviewer",
            checkpoint_id=checkpoint_id,
            pass_number=0,
            validation_index=validation_index,
            infra_failure_path=(
                util.run_dir(repo, run_id) / "recovery" / "validation-infrastructure" / "preflight-infra.json"
            ),
        )
        results.append(result)
        if result.get("infra_failure") or result.get("candidate_invalid") or not result.get("passed"):
            raise RuntimeError(
                "current deterministic validation preflight did not pass: "
                + str(result.get("infra_failure_reason") or result.get("candidate_invalid_reason") or result.get("name"))
            )
    return results, _canonical_sha([
        {key: row.get(key) for key in ("name", "command", "passed", "exit_code", "stdout_sha256", "stderr_sha256")}
        for row in results
    ])


def _accounting_snapshot(conn: sqlite3.Connection, job: sqlite3.Row) -> dict[str, Any]:
    row = conn.execute(
        "SELECT COALESCE(SUM(CASE WHEN cost_accounted=1 THEN cost_usd ELSE 0 END),0) AS cost, "
        "COALESCE(SUM(CASE WHEN tokens_known=1 THEN input_tokens ELSE 0 END),0) AS input, "
        "COALESCE(SUM(CASE WHEN tokens_known=1 THEN output_tokens ELSE 0 END),0) AS output, "
        "COALESCE(SUM(CASE WHEN tokens_known=1 THEN cache_read_tokens ELSE 0 END),0) AS cache "
        "FROM semantic_attempts WHERE job_id=?",
        (int(job["id"]),),
    ).fetchone()
    values = {
        "cost": float(job["total_cost_usd"] or 0),
        "input": int(job["total_input_tokens"] or 0),
        "output": int(job["total_output_tokens"] or 0),
        "cache": int(job["total_cache_read_tokens"] or 0),
    }
    recomputed = {
        "cost": float(row["cost"] or 0),
        "input": int(row["input"] or 0),
        "output": int(row["output"] or 0),
        "cache": int(row["cache"] or 0),
    }
    if abs(values["cost"] - recomputed["cost"]) > 1e-8 or any(
        values[key] != recomputed[key] for key in ("input", "output", "cache")
    ):
        raise RuntimeError("supervisor aggregate does not reconcile to semantic attempt accounting")
    return values


def _verify_recovery_record(
    *, repo: Path, run_id: str, event: dict[str, Any], current: dict[str, Any],
    recovery_dir: Path,
) -> tuple[dict[str, Any], dict[str, Any]]:
    recovery_id = str(event.get("recovery_id") or "")
    if not re.fullmatch(r"[0-9a-f]{64}", recovery_id):
        raise RuntimeError("recovery event has an invalid recovery identity")
    intent = util.read_private_json(recovery_dir / "INTENT.json", default=None)
    preflight = util.read_private_json(recovery_dir / "PREFLIGHT.json", default=None)
    if not isinstance(intent, dict) or not isinstance(preflight, dict):
        raise RuntimeError("recovery event lacks its durable intent/preflight evidence")  # noqa: TRY004 - this is a failed authority precondition.
    identity = {key: value for key, value in intent.items() if key != "recovery_id"}
    if intent.get("recovery_id") != recovery_id or _canonical_sha(identity) != recovery_id:
        raise RuntimeError("recovery intent does not hash to its event identity")
    identity_checks = {
        "schema": intent.get("schema") == SCHEMA,
        "repo": intent.get("repo") == str(repo),
        "run_id": intent.get("run_id") == run_id,
        "candidate_sha": intent.get("candidate_sha") == event.get("candidate_sha"),
        "review_attempt_id": intent.get("review_attempt_id") == event.get("review_attempt_id"),
        "runtime_generation": intent.get("runtime_generation") == event.get("runtime_generation"),
        "capability_binding_sha256": intent.get("capability_binding_sha256") == event.get("capability_binding_sha256"),
        "packet_sha256": intent.get("packet_sha256") == event.get("recovery_packet_sha256"),
        "approval_sha256": intent.get("approval_sha256") == event.get("recovery_approval_sha256"),
        "build_receipt_sha256": intent.get("build_receipt_sha256") == event.get("recovery_build_receipt_sha256"),
        "semantic_sha256": intent.get("semantic_sha256") == event.get("semantic_sha256"),
        "prior_verdict_sha256": intent.get("prior_verdict_sha256") == event.get("prior_verdict_sha256"),
        "validation_evidence_sha256": intent.get("validation_evidence_sha256") == event.get("validation_evidence_sha256"),
        "accounting_sha256": intent.get("accounting_sha256") == event.get("accounting_sha256"),
        "preflight_recovery_id": preflight.get("recovery_id") == recovery_id,
        "preflight_sha256": preflight.get("preflight_sha256") == event.get("preflight_sha256"),
    }
    mismatches = [key for key, valid in identity_checks.items() if not valid]
    if mismatches:
        raise RuntimeError("recovery intent/preflight event mismatch: " + ", ".join(mismatches))
    expected_event = {
        "actor": _ACTOR,
        "event_type": "program_review_infrastructure_retry",
        "old_state": "BLOCKED",
        "new_state": "REVIEWING",
        "checkpoint_id": intent.get("checkpoint_id"),
        "candidate_sha": intent.get("candidate_sha"),
        "review_attempt_id": intent.get("review_attempt_id"),
        "semantic_sha256": intent.get("semantic_sha256"),
        "prior_verdict_sha256": intent.get("prior_verdict_sha256"),
        "validation_evidence_sha256": intent.get("validation_evidence_sha256"),
        "prior_runtime_generation": intent.get("prior_runtime_generation"),
        "runtime_generation": intent.get("runtime_generation"),
        "recovery_packet_sha256": intent.get("packet_sha256"),
        "recovery_approval_sha256": intent.get("approval_sha256"),
        "recovery_build_receipt_sha256": intent.get("build_receipt_sha256"),
        "prior_capability_binding_sha256": intent.get("prior_capability_binding_sha256"),
        "capability_binding_sha256": intent.get("capability_binding_sha256"),
        "preflight_sha256": preflight.get("preflight_sha256"),
        "accounting_sha256": intent.get("accounting_sha256"),
        "build_pass_count": int((intent.get("counters") or {}).get("build") or 0),
        "review_pass_count": int((intent.get("counters") or {}).get("review") or 0),
        "repair_round": int((intent.get("counters") or {}).get("repair") or 0),
    }
    if any(event.get(key) != value for key, value in expected_event.items()):
        raise RuntimeError("recovery event fields contradict its immutable intent")
    results = preflight.get("preflight_results")
    if not isinstance(results, list) or _preflight_result_sha(results) != event.get("preflight_sha256"):
        raise RuntimeError("recovery preflight evidence digest is invalid")
    archive = recovery_dir / "REVIEW_VERDICT.before.json"
    if archive.is_symlink() or not archive.is_file():
        raise RuntimeError("archived prior verdict is missing or redirected")
    if util.sha256_file(archive) != intent.get("prior_verdict_sha256"):
        raise RuntimeError("archived prior verdict digest does not match recovery identity")
    try:
        archived_verdict = json.loads(archive.read_bytes())
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RuntimeError("archived prior verdict is malformed") from exc
    rows = archived_verdict.get("validation_results") if isinstance(archived_verdict, dict) else None
    failed_rows = [
        row for row in rows or []
        if isinstance(row, dict) and row.get("passed") is False
    ]
    if (
        len(failed_rows) != 1
        or failed_rows[0].get("infrastructure_evidence")
        != intent.get("validation_evidence_reference")
    ):
        raise RuntimeError("archived verdict does not bind the recovered validation evidence")
    evidence_record, evidence_digest = validation_evidence.verify_reference(
        canonical_repo=repo,
        run_id=run_id,
        reference=intent.get("validation_evidence_reference"),
        expected_identity=intent.get("validation_evidence_identity"),
    )
    if evidence_digest != intent.get("validation_evidence_sha256") or not validation_evidence.proves_registry_dns_failure(
        record=evidence_record,
        allowed_domains=_bound_uv_domains(
            capability_binding._read(capability_binding.binding_path(repo, run_id))
        ),
    ):
        raise RuntimeError("durable broker evidence no longer proves the permitted DNS failure")
    state_doc = state.load_verified(repo, run_id)
    if state_doc.get("state") == "STOPPED":
        raise RuntimeError("STOPPED is absorbing; recovery replay cannot requeue it")
    if state_doc.get("state") == "REVIEWING":
        if (
            state_doc.get("last_candidate_sha") != intent.get("candidate_sha")
            or not state.is_program_state(state_doc)
        ):
            raise RuntimeError("recovery event does not match the current REVIEWING state")
        program_state = state_doc.get("program") or {}
        if program.select_next_checkpoint(_packet_from_run(repo, run_id), program_state) != intent.get("checkpoint_id"):
            raise RuntimeError("recovery checkpoint no longer matches active PROGRAM state")
        cumulative = program_state.get("cumulative_counters") or {}
        counters = intent.get("counters") or {}
        if any((
            int(state_doc.get("build_pass_count") or 0) != int(counters.get("build") or 0),
            int(state_doc.get("review_pass_count") or 0) != int(counters.get("review") or 0),
            int(state_doc.get("repair_round") or 0) != int(counters.get("repair") or 0),
            int(cumulative.get("build_pass_count") or 0) != int(counters.get("build") or 0),
            int(cumulative.get("review_pass_count") or 0) != int(counters.get("review") or 0),
            int(cumulative.get("repair_round_count") or 0) != int(counters.get("repair") or 0),
        )):
            raise RuntimeError("PROGRAM counters changed after infrastructure recovery")
    return intent, preflight


def _packet_from_run(repo: Path, run_id: str) -> dict[str, Any]:
    packet_meta, _ = packet.parse_packet_file(state.run_dir(repo, run_id) / "WORK_PACKET.md")
    return packet_meta


def _complete_interrupted_requeue(
    *, repo: Path, run_id: str, candidate: str, attempt_id: str,
    db_path: Path, current: dict[str, Any], event: dict[str, Any],
    recovery_dir: Path, supervisor_mod: Any,
) -> dict[str, Any]:
    """Finish DONE->QUEUED if a crash followed the state event publication."""
    intent, _preflight = _verify_recovery_record(
        repo=repo, run_id=run_id, event=event, current=current,
        recovery_dir=recovery_dir,
    )
    if current.get("state") != "REVIEWING":
        if current.get("state") == "BLOCKED":
            raise RuntimeError("recovery event exists but the run is BLOCKED again")
        with supervisor_mod._managed_connect_readonly(db_path) as conn:
            job, lookup = supervisor_mod._logical_job_row(conn, repo, run_id)
            if job is None:
                raise RuntimeError(f"recovered enrollment missing: {lookup}")
            return {
                "schema": SCHEMA, "ok": True, "idempotent": True,
                "recovery_id": intent["recovery_id"],
                "status": str(job["status"] or ""),
                "state": str(current.get("state") or ""),
                "candidate_sha": candidate,
            }

    packet_path = state.run_dir(repo, run_id) / "WORK_PACKET.md"
    packet_meta, _ = packet.parse_packet_file(packet_path)
    packet_sha = util.sha256_file(packet_path)
    if packet_sha != intent.get("packet_sha256"):
        raise RuntimeError("sealed packet changed after the recovery event")
    approval_doc = approval.load_approval(repo, run_id)
    approval_ok, approval_reason = approval.validate_approval_binding(
        canonical_repo=repo, run_id=run_id, approval=approval_doc,
        packet=packet_meta, packet_path=packet_path,
    )
    if not approval_ok or not isinstance(approval_doc, dict):
        raise RuntimeError("approval invalid after recovery event: " + approval_reason)
    if approval.approval_artifact_sha256(approval_doc) != intent.get("approval_sha256"):
        raise RuntimeError("approval changed after the recovery event")
    if util.sha256_file(receipts.receipt_path(repo, run_id)) != intent.get("build_receipt_sha256"):
        raise RuntimeError("BUILD_RECEIPT changed after the recovery event")
    assessment_path = assessment.assessment_path(repo, run_id)
    if assessment_path.is_symlink() or not assessment_path.is_file() or util.sha256_file(assessment_path) != intent.get("semantic_sha256"):
        raise RuntimeError("accepted reviewer semantic artifact changed after the recovery event")
    prior_verdict_path = verdicts.verdict_path(repo, run_id)
    if prior_verdict_path.is_symlink() or not prior_verdict_path.is_file() or util.sha256_file(prior_verdict_path) != intent.get("prior_verdict_sha256"):
        raise RuntimeError("prior validation-only verdict changed after the recovery event")
    branch = str(approval_doc.get("candidate_branch") or "")
    if not branch or git_checks.branch_head(repo, branch) != candidate:
        raise RuntimeError("candidate branch no longer resolves to the recovered candidate")
    _assert_clean_candidate_worktrees(repo, run_id, branch, candidate)
    work_order = {
        "schema": dispatch.SCHEMA,
        "decision": "REVIEW",
        "role": "reviewer",
        "run_id": run_id,
        "canonical_repo": str(repo),
        "worktree": str(util.reviewer_worktree(repo, run_id)),
        "semantic_path": str(assessment_path),
        "candidate_sha": candidate,
    }
    ready, ready_reason = dispatch.semantic_result_ready(work_order)
    if not ready:
        raise RuntimeError(f"accepted reviewer artifact is no longer replay-ready: {ready_reason}")
    active_binding = capability_binding._read(capability_binding.binding_path(repo, run_id))
    if active_binding.get("binding_sha256") != intent.get("capability_binding_sha256"):
        raise RuntimeError("capability binding changed after the recovery event")
    if str(supervisor_mod._current_runtime_generation() or "") != intent.get("runtime_generation"):
        raise RuntimeError("serving runtime changed after the recovery event")

    with supervisor_mod._managed_connect(db_path) as conn:
        conn.execute("BEGIN IMMEDIATE")
        job, lookup = supervisor_mod._logical_job_row(conn, repo, run_id)
        if job is None:
            raise RuntimeError(f"recovered enrollment missing: {lookup}")
        status = str(job["status"] or "")
        generation = str(job["runtime_generation"] or "")
        accounting = _accounting_snapshot(conn, job)
        if (
            accounting != intent.get("accounting")
            or _canonical_sha(accounting) != intent.get("accounting_sha256")
        ):
            raise RuntimeError("semantic accounting changed after the recovery event")
        attempt = conn.execute(
            "SELECT * FROM semantic_attempts WHERE attempt_id=? AND job_id=?",
            (attempt_id, int(job["id"])),
        ).fetchone()
        if attempt is None or any((
            str(job["latest_attempt_id"] or "") != attempt_id,
            str(attempt["role"] or "") != "reviewer",
            str(attempt["status"] or "") != "COMPLETED",
            not bool(int(attempt["semantic_accepted"] or 0)),
            not bool(int(attempt["cost_accounted"] or 0)),
            not bool(int(attempt["cost_known"] or 0)),
            not bool(int(attempt["tokens_known"] or 0)),
            str(attempt["accepted_candidate_sha"] or "") != candidate,
            str(attempt["accepted_semantic_sha256"] or "") != intent.get("semantic_sha256"),
            attempt["failure_class"],
            attempt["failure_reason"],
        )):
            raise RuntimeError("accepted review attempt changed after the recovery event")
        active = conn.execute(
            "SELECT 1 FROM semantic_attempts WHERE job_id=? AND status IN ('RESERVED','RUNNING') LIMIT 1",
            (int(job["id"]),),
        ).fetchone()
        if active:
            raise RuntimeError("active semantic attempt prevents idempotent recovery confirmation")
        provenance_ok, provenance_reason, _capability_receipt = supervisor_mod._attempt_provenance_gate(
            conn, job=job, work_order=work_order, attempt_id=attempt_id,
        )
        if not provenance_ok:
            raise RuntimeError(f"accepted review launch provenance changed: {provenance_reason}")
        if status in {"QUEUED", "RUNNING", "BACKOFF"} and generation == intent.get("runtime_generation"):
            return {
                "schema": SCHEMA, "ok": True, "idempotent": True,
                "recovery_id": intent["recovery_id"], "status": status,
                "state": "REVIEWING", "candidate_sha": candidate,
            }
        if (
            status != "DONE"
            or generation != intent.get("prior_runtime_generation")
            or str(job["latest_attempt_id"] or "") != attempt_id
            or job["worker_pid"] is not None
            or job["worker_role"] is not None
        ):
            raise RuntimeError("recovery event cannot complete an unexpected supervisor enrollment")
        changed = conn.execute(
            "UPDATE jobs SET status='QUEUED', runtime_generation=?, next_attempt_at=0, updated_at=? "
            "WHERE id=? AND status='DONE' AND runtime_generation=? AND latest_attempt_id=? "
            "AND worker_pid IS NULL AND worker_role IS NULL",
            (
                str(intent["runtime_generation"]), time.time(), int(job["id"]),
                str(intent["prior_runtime_generation"]), attempt_id,
            ),
        ).rowcount
        if changed != 1:
            raise RuntimeError("crash-safe DONE-to-QUEUED recovery compare-and-swap failed")
        updated_job = conn.execute("SELECT * FROM jobs WHERE id=?", (int(job["id"]),)).fetchone()
        if updated_job is None or _accounting_snapshot(conn, updated_job) != accounting:
            raise RuntimeError("accounting changed while completing the recovery requeue")
    return {
        "schema": SCHEMA, "ok": True, "idempotent": True,
        "recovery_id": intent["recovery_id"], "status": "QUEUED",
        "state": "REVIEWING", "candidate_sha": candidate,
        "review_attempt_id": attempt_id,
    }


def retry_blocked_review_after_validation_infrastructure(
    *, canonical_repo: Path, run_id: str, expected_candidate_sha: str,
    expected_review_attempt_id: str, db_path: Path, supervisor_mod: Any,
) -> dict[str, Any]:
    """Revalidate and requeue exactly one accepted validation-blocked review."""
    repo = Path(canonical_repo).expanduser().resolve(strict=True)
    candidate = str(expected_candidate_sha or "").lower()
    attempt_id = str(expected_review_attempt_id or "")
    if not re.fullmatch(r"[0-9a-f]{40}", candidate):
        return _failure("expected_candidate_sha_invalid")
    if not re.fullmatch(r"[A-Za-z0-9._-]{16,64}", attempt_id):
        return _failure("expected_review_attempt_id_invalid")
    try:
        state.validate_run_id(run_id)
        run_root = state.run_dir(repo, run_id)
        current = state.load_verified(repo, run_id)
        events = integrity.read_event_chain(state.events_path(repo, run_id))
        recovery_events = _validation_recovery_events(events)
        if any(
            event.get("review_attempt_id") == attempt_id
            and event.get("candidate_sha") != candidate
            for event in recovery_events
        ):
            raise RuntimeError("the requested attempt already has a recovery event for a different candidate")
        prior_recoveries = [
            event for event in recovery_events
            if _event_matches(event, attempt_id=attempt_id, candidate_sha=candidate)
        ]
        if len(prior_recoveries) > 1:
            raise RuntimeError("duplicate infrastructure-review recovery events")
        if prior_recoveries:
            event = prior_recoveries[0]
            recovery_id = str(event.get("recovery_id") or "")
            recovery_dir = run_root / "recovery" / "validation-infrastructure" / recovery_id
            result = _complete_interrupted_requeue(
                repo=repo, run_id=run_id, candidate=candidate, attempt_id=attempt_id,
                db_path=Path(db_path), current=current, event=event,
                recovery_dir=recovery_dir, supervisor_mod=supervisor_mod,
            )
            if result.get("ok"):
                return result

        packet_path = run_root / "WORK_PACKET.md"
        packet_meta, _ = packet.parse_packet_file(packet_path)
        packet_sha = util.sha256_file(packet_path)
        packet_errors = packet.validate_packet_for_approval(packet_meta)
        if packet_errors:
            raise RuntimeError("sealed packet is invalid: " + "; ".join(packet_errors[:8]))
        approval_doc = approval.load_approval(repo, run_id)
        approval_ok, approval_reason = approval.validate_approval_binding(
            canonical_repo=repo, run_id=run_id, approval=approval_doc,
            packet=packet_meta, packet_path=packet_path,
        )
        if not approval_ok or not isinstance(approval_doc, dict):
            raise RuntimeError("approval authority invalid: " + approval_reason)
        approval_sha = approval.approval_artifact_sha256(approval_doc)
        if current.get("state") == "STOPPED":
            raise RuntimeError("STOPPED is absorbing; review infrastructure recovery refused")
        if current.get("state") != "BLOCKED" or not state.is_program_state(current):
            raise RuntimeError("recovery requires the existing blocked PROGRAM state")
        if str(current.get("last_candidate_sha") or "") != candidate:
            raise RuntimeError("STATE candidate does not match the explicitly expected candidate")
        checkpoint_id, cp_packet, cp_state = _active_checkpoint(packet_meta, current)
        if (current.get("program") or {}).get("blocked") is True:
            raise RuntimeError("PROGRAM is explicitly terminal-blocked")
        _assert_counter_mirrors(current, cp_state)

        db = Path(db_path).expanduser().resolve(strict=True)
        with supervisor_mod._managed_connect_readonly(db) as conn:
            job, lookup = supervisor_mod._logical_job_row(conn, repo, run_id)
            if job is None:
                raise RuntimeError(f"supervisor enrollment not found: {lookup}")
            if (
                str(job["status"] or "") != "DONE"
                or str(job["execution_mode"] or "").upper() != "PROGRAM"
                or str(job["run_id"] or "") != run_id
                or str(Path(str(job["repo"])).resolve(strict=False)) != str(repo)
                or str(job["latest_attempt_id"] or "") != attempt_id
                or job["worker_pid"] is not None
                or job["worker_role"] is not None
            ):
                raise RuntimeError("supervisor enrollment is not the exact idle DONE reviewer recovery point")
            active_rows = conn.execute(
                "SELECT attempt_id,status FROM semantic_attempts WHERE job_id=? AND status IN ('RESERVED','RUNNING')",
                (int(job["id"]),),
            ).fetchall()
            if active_rows:
                raise RuntimeError("active or reserved semantic work prevents recovery")
            attempt = conn.execute(
                "SELECT * FROM semantic_attempts WHERE attempt_id=? AND job_id=?",
                (attempt_id, int(job["id"])),
            ).fetchone()
            if attempt is None:
                raise RuntimeError("requested accepted reviewer attempt is absent from the ledger")
            expected_counters = {
                "build": int(current.get("build_pass_count") or 0),
                "review": int(current.get("review_pass_count") or 0),
                "repair": int(current.get("repair_round") or 0),
            }
            accounting_before = _accounting_snapshot(conn, job)
            (
                receipt, _prior_verdict, verdict_bytes, semantic_sha, work_order,
                validation_evidence_binding,
            ) = _validate_predecessor_evidence(
                repo=repo, run_id=run_id, candidate=candidate, attempt_id=attempt_id,
                packet_meta=packet_meta, packet_sha=packet_sha, approval_doc=approval_doc,
                approval_sha=approval_sha, state_doc=current, cp_id=checkpoint_id,
                cp_packet=cp_packet,
                cp_state=cp_state, job=job, attempt=attempt, db_conn=conn,
                prior_binding=capability_binding._read(capability_binding.binding_path(repo, run_id)),
                supervisor_mod=supervisor_mod,
            )
            job_snapshot = dict(job)

        branch = str(job_snapshot.get("candidate_branch") or "")
        if not branch or branch != approval_doc.get("candidate_branch"):
            raise RuntimeError("candidate branch does not match sealed approval")
        if git_checks.branch_head(repo, branch) != candidate or not git_checks.commit_exists(repo, candidate):
            raise RuntimeError("candidate branch does not resolve to the expected candidate")
        if str(approval_doc.get("baseline_sha") or "") != str(receipt.get("baseline_sha") or ""):
            raise RuntimeError("build receipt baseline does not match approval")
        _assert_clean_candidate_worktrees(repo, run_id, branch, candidate)

        old_runtime = str(job_snapshot.get("runtime_generation") or "")
        serving_runtime = str(supervisor_mod._current_runtime_generation() or "")
        if not old_runtime or not serving_runtime or old_runtime == serving_runtime:
            raise RuntimeError("recovery requires a proven old/new runtime-generation boundary")
        active_binding = capability_binding._read(capability_binding.binding_path(repo, run_id))
        old_binding_sha = str(active_binding.get("binding_sha256") or "")
        if not old_binding_sha:
            raise RuntimeError("active run capability binding is missing")
        resolution, profile, desired_binding, provider = _resolve_current_binding(
            repo=repo, run_id=run_id, packet_meta=packet_meta, job=job_snapshot,
            prior_binding=active_binding, supervisor_mod=supervisor_mod,
        )
        new_binding_sha = str(desired_binding.get("binding_sha256") or "")
        if not new_binding_sha:
            raise RuntimeError("current capability binding could not be derived")
        with supervisor_mod._managed_connect_readonly(db) as conn:
            job_now, _ = supervisor_mod._logical_job_row(conn, repo, run_id)
            if job_now is None:
                raise RuntimeError("supervisor enrollment disappeared during capability resolution")
            provenance_ok, provenance_reason, _ = supervisor_mod._attempt_provenance_gate(
                conn, job=job_now, work_order=work_order, attempt_id=attempt_id,
            )
            if not provenance_ok:
                raise RuntimeError(f"accepted semantic launch provenance invalid: {provenance_reason}")

        recovery_identity = {
            "schema": SCHEMA,
            "repo": str(repo),
            "run_id": run_id,
            "job_id": int(job_snapshot["id"]),
            "checkpoint_id": checkpoint_id,
            "candidate_sha": candidate,
            "review_attempt_id": attempt_id,
            "semantic_sha256": semantic_sha,
            "prior_verdict_sha256": util.sha256_bytes(verdict_bytes),
            "validation_evidence_sha256": validation_evidence_binding["sha256"],
            "validation_evidence_reference": validation_evidence_binding["reference"],
            "validation_evidence_identity": validation_evidence_binding["identity"],
            "packet_sha256": packet_sha,
            "approval_sha256": approval_sha,
            "build_receipt_sha256": util.sha256_file(receipts.receipt_path(repo, run_id)),
            "prior_runtime_generation": old_runtime,
            "runtime_generation": serving_runtime,
            "prior_capability_binding_sha256": old_binding_sha,
            "capability_binding_sha256": new_binding_sha,
            "counters": expected_counters,
            "accounting": accounting_before,
            "accounting_sha256": _canonical_sha(accounting_before),
        }
        recovery_id = _canonical_sha(recovery_identity)
        recovery_dir = run_root / "recovery" / "validation-infrastructure" / recovery_id
        intent_path = recovery_dir / "INTENT.json"
        archive_path = recovery_dir / "REVIEW_VERDICT.before.json"
        intent = dict(recovery_identity, recovery_id=recovery_id)
        existing_intent = util.read_private_json(intent_path, default=None)
        if existing_intent is not None:
            if not isinstance(existing_intent, dict) or any(
                existing_intent.get(key) != value for key, value in intent.items()
            ):
                raise RuntimeError("existing recovery intent contradicts current authority")
        else:
            _write_exact_private_json(intent_path, intent)

        migration = None
        records, incomplete = capability_binding._migration_inventory(repo, run_id)
        has_prepared = any(record.get("status") == "PREPARED" for record in records) or bool(incomplete)
        if (
            active_binding.get("projection") != desired_binding.get("projection")
            or has_prepared
        ):
            migration = capability_binding.migrate_run_binding(
                repo, run_id, resolution, profile,
                reason="recover accepted reviewer after validator infrastructure repair",
                actor=_ACTOR,
                context={
                    "recovery_id": recovery_id,
                    "runtime_generation_before": old_runtime,
                    "runtime_generation_after": serving_runtime,
                    "engineering_state": str(current.get("state") or ""),
                    "checkpoint": checkpoint_id,
                    "supervisor_job_id": int(job_snapshot["id"]),
                    "packet_sha256": packet_sha,
                    "approval_sha256": approval_sha,
                },
                requested_capabilities=[str(item) for item in packet_meta.get("capabilities", [])],
            )
        elif new_binding_sha != old_binding_sha:
            raise RuntimeError("capability projection/digest comparison is inconsistent")

        current_active_binding = capability_binding._read(capability_binding.binding_path(repo, run_id))
        if current_active_binding.get("binding_sha256") != new_binding_sha:
            raise RuntimeError("current capability binding did not resolve to the recorded recovery authority")
        preflight_results, preflight_sha = _validation_preflight(
            repo=repo, run_id=run_id, packet_meta=packet_meta,
            state_doc=current, candidate=candidate,
        )
        if git_checks.current_head(util.reviewer_worktree(repo, run_id)) != candidate or git_checks.dirty_status(util.reviewer_worktree(repo, run_id)) != "clean":
            raise RuntimeError("reviewer candidate changed during deterministic preflight")

        _write_exact_private(archive_path, verdict_bytes)
        if util.sha256_file(archive_path) != recovery_identity["prior_verdict_sha256"]:
            raise RuntimeError("archived validation-only verdict digest does not verify")
        preflight_doc = dict(
            intent,
            preflight_sha256=preflight_sha,
            preflight_results=[
                {key: row.get(key) for key in ("name", "command", "passed", "exit_code", "stdout_sha256", "stderr_sha256")}
                for row in preflight_results
            ],
            archived_review_verdict=str(archive_path),
            capability_migration_sequence=(migration or {}).get("migration_sequence"),
            capability_migration_status=(migration or {}).get("status", "UNCHANGED"),
        )
        _write_exact_private_json(recovery_dir / "PREFLIGHT.json", preflight_doc)
        expected_cp_counts = (
            int(cp_state.get("build_pass_count") or 0),
            int(cp_state.get("review_pass_count") or 0),
            int(cp_state.get("repair_round_count") or 0),
        )
        state.retry_blocked_program_review_after_validation_infrastructure(
            repo, run_id, packet=packet_meta, checkpoint_id=checkpoint_id,
            candidate_sha=candidate, review_attempt_id=attempt_id,
            semantic_sha256=semantic_sha,
            prior_verdict_sha256=recovery_identity["prior_verdict_sha256"],
            recovery_id=recovery_id,
            prior_runtime_generation=old_runtime,
            runtime_generation=serving_runtime,
            packet_sha256=packet_sha,
            approval_sha256=approval_sha,
            build_receipt_sha256=recovery_identity["build_receipt_sha256"],
            prior_capability_binding_sha256=old_binding_sha,
            capability_binding_sha256=new_binding_sha,
            checkpoint_build_pass_count=expected_cp_counts[0],
            checkpoint_review_pass_count=expected_cp_counts[1],
            checkpoint_repair_round_count=expected_cp_counts[2],
            preflight_sha256=preflight_sha,
            accounting_sha256=recovery_identity["accounting_sha256"],
            validation_evidence_sha256=recovery_identity["validation_evidence_sha256"],
        )

        with supervisor_mod._managed_connect(db) as conn:
            conn.execute("BEGIN IMMEDIATE")
            job_now, lookup = supervisor_mod._logical_job_row(conn, repo, run_id)
            if job_now is None:
                raise RuntimeError(f"supervisor enrollment disappeared before requeue: {lookup}")
            if str(job_now["status"] or "") == "QUEUED" and str(job_now["runtime_generation"] or "") == serving_runtime:
                status_after = "QUEUED"
                idempotent = True
            else:
                active = conn.execute(
                    "SELECT 1 FROM semantic_attempts WHERE job_id=? AND status IN ('RESERVED','RUNNING') LIMIT 1",
                    (int(job_now["id"]),),
                ).fetchone()
                if active:
                    raise RuntimeError("semantic attempt became active before recovery requeue")
                changed = conn.execute(
                    "UPDATE jobs SET status='QUEUED', runtime_generation=?, next_attempt_at=0, updated_at=? "
                    "WHERE id=? AND status='DONE' AND runtime_generation=? AND latest_attempt_id=? "
                    "AND worker_pid IS NULL AND worker_role IS NULL",
                    (serving_runtime, time.time(), int(job_now["id"]), old_runtime, attempt_id),
                ).rowcount
                if changed != 1:
                    raise RuntimeError("supervisor enrollment changed before exact DONE-to-QUEUED recovery")
                status_after = "QUEUED"
                idempotent = False
            verified_job = conn.execute("SELECT * FROM jobs WHERE id=?", (int(job_now["id"]),)).fetchone()
            if verified_job is None:
                raise RuntimeError("requeued supervisor job disappeared")
            if _accounting_snapshot(conn, verified_job) != accounting_before:
                raise RuntimeError("resource accounting changed during infrastructure recovery")

        return {
            "schema": SCHEMA,
            "ok": True,
            "idempotent": idempotent,
            "recovery_id": recovery_id,
            "status": status_after,
            "state": "REVIEWING",
            "checkpoint_id": checkpoint_id,
            "candidate_sha": candidate,
            "review_attempt_id": attempt_id,
            "semantic_sha256": semantic_sha,
            "preflight_sha256": preflight_sha,
            "prior_verdict_sha256": recovery_identity["prior_verdict_sha256"],
            "archived_verdict": str(archive_path),
            "old_runtime_generation": old_runtime,
            "runtime_generation": serving_runtime,
            "prior_capability_binding_sha256": old_binding_sha,
            "capability_binding_sha256": new_binding_sha,
            "capability_migration": migration or {"status": "UNCHANGED", "migration_sequence": None},
            "profile": str(profile.get("name") or ""),
            "provider": provider,
            "build_pass_count": expected_counters["build"],
            "review_pass_count": expected_counters["review"],
            "repair_round": expected_counters["repair"],
            "accounting": accounting_before,
            "receipt": str(recovery_dir / "PREFLIGHT.json"),
        }
    except Exception as exc:  # noqa: BLE001 - convert every fail-closed refusal to a structured CLI result.
        return _failure("validation_infrastructure_review_recovery_refused", error=f"{type(exc).__name__}: {exc}")


__all__ = ["SCHEMA", "retry_blocked_review_after_validation_infrastructure"]
