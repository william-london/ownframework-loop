"""Fail-closed linked rollover for an exhausted, blocked PROGRAM candidate.

This is deliberately not a generic resume/reset path.  It can create one
linked child only when a terminal parent has an accepted, fully-accounted
review whose sole deterministic rejection was one failed required validation,
while the same candidate has clean BUILD authority and no remaining BUILD
pass.  The child imports all semantic/source counters, copies the exact packet
bytes, and may enter REVIEW only after a fresh successful deterministic
validation and an immutable origin receipt.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
import re
import time
from pathlib import Path
from typing import Any

from . import (
    approval,
    assessment,
    branch_resolver,
    build_finalize,
    git_checks,
    integrity,
    packet,
    program,
    receipts,
    schema_validate,
    secrets_v2,
    state,
    supervisor_db,
    util,
    verdicts,
    validation_executor,
    worktrees,
)


AUTHORITY_SCHEMA = "ownframework-loop-program-rollover-authority/v1"
PREFLIGHT_SCHEMA = "ownframework-loop-rollover-preflight/v1"
ORIGIN_SCHEMA = "ownframework-loop-candidate-origin/v1"


class ProgramRolloverRefused(RuntimeError):
    """Raised when linked rollover authority cannot be proven."""


def _canonical_product_checkout_is_clean(repo: Path) -> bool:
    """Require a clean product checkout while permitting Loop-owned metadata.

    Run state and registered Loop worktrees live below reserved, untracked
    control-plane roots.  They are not candidate product changes and must not
    make an otherwise exact baseline checkout appear dirty.  Every tracked
    change and every untracked path outside those two roots remains a refusal.
    A failed Git status probe is never treated as clean.
    """
    result = util.run_subprocess(
        [
            "git", "-C", str(repo), "status", "--porcelain=v1",
            "--untracked-files=all", "-z",
        ],
        timeout=10,
    )
    if result.returncode != 0:
        return False
    control_roots = (".ownframework-loop", ".worktrees/ownframework-loop")
    if any((repo / root).is_symlink() for root in control_roots):
        return False
    for entry in result.stdout.split("\0"):
        if not entry:
            continue
        if len(entry) < 4 or entry[2] != " ":
            return False
        status, path = entry[:2], entry[3:]
        if status != "??":
            return False
        if not any(path == root or path.startswith(root + "/") for root in control_roots):
            return False
        if (repo / path).is_symlink():
            return False
    return True


def _wall_clock_now() -> float:
    """Clock seam for absolute rollover deadline calculation."""
    return time.time()


def _json_bytes(value: Any) -> bytes:
    return json.dumps(value, indent=2, sort_keys=True).encode("utf-8")


def _rollover_capability_binding(
    canonical_repo: Path,
    run_id: str,
    meta: dict[str, Any],
    *,
    runner: str,
    allow_create: bool,
) -> dict[str, Any]:
    """Resolve and verify the child's immutable packet/profile binding.

    A rollover child has no semantic BUILD pass from which the ordinary
    runner could create its first binding. Its mandatory deterministic
    validation therefore establishes the standard run binding at the core
    boundary. Replays may verify an existing binding, but may not silently
    recreate a missing binding after rollover authority has been published.
    """
    from . import capabilities, capability_binding, runner_profiles, runtime_env

    profile = runner_profiles.resolve_profile(
        str(meta.get("runner_profile") or "default"), provider=runner,
    )
    runner_profiles.verify_profile_integrity(profile)
    attestation = runner_profiles.verify_effort_attestation(profile)
    if attestation is not None:
        profile = dict(profile)
        profile["effort_attestation"] = attestation
    resolution = capabilities.resolve_capabilities(
        [str(item) for item in (meta.get("capabilities") or [])],
        canonical_repo=canonical_repo,
        role="reviewer",
        repo_cache_root=runtime_env.repo_tool_cache_dir(canonical_repo),
        ephemeral_cache_root=(
            runtime_env.runtime_cache_dir(canonical_repo, run_id, "validation")
            / "capability-cache"
        ),
        packet_network_allowlist=[
            str(item) for item in (meta.get("network_read_allowlist") or [])
        ],
        evidence_run_key=run_id,
    )
    capabilities.verify_resolution_integrity(resolution)
    return capability_binding.ensure_run_binding(
        canonical_repo, run_id, resolution, profile, allow_create=allow_create,
    )


def _create_once(path: Path, raw: bytes, *, mode: int = 0o600) -> None:
    """Create a private immutable file, or accept only byte-identical replay."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    except FileExistsError:
        if path.is_symlink() or not path.is_file() or path.read_bytes() != raw:
            raise ProgramRolloverRefused(f"create-once evidence conflicts: {path.name}")
        if path.stat().st_mode & 0o077:
            raise ProgramRolloverRefused(f"rollover evidence permissions are too broad: {path.name}")
        return
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        util.fsync_dir(path.parent)
    except BaseException:
        try:
            path.unlink()
        except OSError:
            pass
        raise


def _create_once_json(path: Path, value: dict[str, Any]) -> str:
    raw = _json_bytes(value)
    _create_once(path, raw)
    return hashlib.sha256(raw).hexdigest()


def _load_private_json(path: Path) -> dict[str, Any] | None:
    value = util.read_private_json(path, default=None)
    return value if isinstance(value, dict) else None


def _job_snapshot(job: Any) -> dict[str, Any]:
    fields = (
        "id", "repo", "run_id", "runner", "status", "infra_failures",
        "max_infra_failures", "transient_failures", "max_transient_failures",
        "transient_recovery_cycles", "max_transient_recovery_cycles",
        "total_cost_usd", "total_input_tokens", "total_output_tokens",
        "total_cache_read_tokens", "total_cache_creation_tokens",
        "observed_total_tokens", "max_total_cost_usd", "max_total_tokens",
        "max_wall_seconds", "execution_started_at", "runtime_generation",
        "legacy_budget_ambiguous", "worker_pid", "worker_pgid",
        "worker_attempt_id", "worker_role", "latest_attempt_id",
        "candidate_branch", "execution_mode", "max_pass_runtime_seconds",
    )
    snapshot = {key: job[key] for key in fields if key in job.keys()}
    # ``observed_total_tokens`` is a derived read-model field, not a SQLite
    # column. Rollover deliberately reads the raw ledger row, so compute the
    # same projection here before reconciling it against attempt history.
    if "observed_total_tokens" not in snapshot:
        snapshot["observed_total_tokens"] = sum(
            int(snapshot.get(key) or 0)
            for key in (
                "total_input_tokens", "total_output_tokens",
                "total_cache_read_tokens", "total_cache_creation_tokens",
            )
        )
    return snapshot


def _snapshot_digest(value: Any) -> str:
    return hashlib.sha256(_json_bytes(value)).hexdigest()


def _wall_clock_authority(
    job: dict[str, Any],
    *,
    now: float,
) -> dict[str, float | None]:
    """Bind rollover wall authority to the parent's absolute deadline.

    ``max_wall_seconds`` is a duration only when paired with its start time.
    Copying the parent's *remaining* duration and starting that duration again
    at child execution would replenish time spent approving or enqueueing the
    rollover.  The child therefore gets a frozen clock origin at rollover
    creation, with a duration that ends no later than the parent's deadline.
    """
    ceiling = int(job.get("max_wall_seconds") or 0)
    if ceiling <= 0:
        return {
            "parent_deadline_unix": None,
            "child_execution_started_at": None,
        }
    parent_started = float(job.get("execution_started_at") or 0.0)
    if parent_started <= 0:
        raise ProgramRolloverRefused(
            "wall-clock budget is enabled but parent start time is unknown"
        )
    deadline = parent_started + ceiling
    remaining = int(deadline - now)
    if remaining <= 0:
        raise ProgramRolloverRefused("parent wall-clock envelope is exhausted")
    return {
        "parent_deadline_unix": deadline,
        "child_execution_started_at": now,
    }


def _validate_frozen_wall_clock_authority(
    authority_doc: dict[str, Any],
    envelope: dict[str, Any],
    *,
    now: float,
) -> tuple[float | None, float | None]:
    """Prove the child clock remains anchored before preflight/enrollment."""
    clock = authority_doc.get("wall_clock_authority")
    if not isinstance(clock, dict):
        raise ProgramRolloverRefused("rollover wall-clock authority is missing")
    raw_deadline = clock.get("parent_deadline_unix")
    raw_origin = clock.get("child_execution_started_at")
    wall = int(envelope.get("max_wall_seconds") or 0)
    if raw_deadline is None:
        if raw_origin is not None or wall != 0:
            raise ProgramRolloverRefused("unlimited rollover wall-clock authority is contradictory")
        return None, None
    try:
        deadline = float(raw_deadline)
        origin = float(raw_origin)
    except (TypeError, ValueError, OverflowError) as exc:
        raise ProgramRolloverRefused("rollover wall-clock authority is malformed") from exc
    if wall <= 0 or origin <= 0 or origin + wall > deadline or now >= deadline:
        raise ProgramRolloverRefused("rollover wall-clock deadline is exhausted or inconsistent")
    return origin, deadline


def _validation_rows_match(
    required: list[dict[str, Any]],
    rows: Any,
    *,
    checkpoint_id: str,
    pass_number: int,
) -> bool:
    if not isinstance(rows, list) or len(rows) != len(required):
        return False
    for index, (spec, row) in enumerate(zip(required, rows)):
        if not isinstance(row, dict):
            return False
        expected_exit = int(spec.get("expected_exit_code") if spec.get("expected_exit_code") is not None else 0)
        if any((
            row.get("name") != spec.get("name"),
            row.get("command") != spec.get("command"),
            row.get("kind") != spec.get("kind"),
            row.get("expected_exit_code") != expected_exit,
            row.get("expected_marker") != spec.get("expected_marker"),
            row.get("passed") is not True,
            row.get("infra_failure") is not False,
            row.get("candidate_invalid") is not False,
            row.get("timed_out") is not False,
            row.get("checkpoint_id") != checkpoint_id,
            row.get("pass_number") != pass_number,
            row.get("validation_index") != index,
        )):
            return False
    return True


def _db_parent_snapshot(
    canonical_repo: Path,
    parent_run_id: str,
    *,
    db_path: Path | None = None,
    require_global_idle: bool = False,
) -> tuple[dict[str, Any], list[dict[str, Any]], dict[str, Any]]:
    db = db_path or supervisor_db.default_db_path()
    repo_text = str(canonical_repo.resolve(strict=False))
    with supervisor_db._managed_connect_readonly(db) as conn:
        job = conn.execute(
            "SELECT * FROM jobs WHERE repo=? AND run_id=? ORDER BY id",
            (repo_text, parent_run_id),
        ).fetchall()
        if len(job) != 1:
            raise ProgramRolloverRefused("parent must have exactly one production supervisor enrollment")
        job_row = job[0]
        attempts = conn.execute(
            "SELECT * FROM semantic_attempts WHERE job_id=? ORDER BY started_at, attempt_id",
            (int(job_row["id"]),),
        ).fetchall()
        attempt_rows = [dict(row) for row in attempts]
        global_running = conn.execute(
            "SELECT COUNT(*) FROM jobs WHERE status='RUNNING' AND worker_pid IS NOT NULL"
        ).fetchone()[0]
    snapshot = _job_snapshot(job_row)
    if snapshot.get("status") != "DONE":
        raise ProgramRolloverRefused("parent supervisor enrollment is not terminal DONE")
    if any(snapshot.get(key) is not None for key in ("worker_pid", "worker_pgid", "worker_attempt_id", "worker_role")):
        raise ProgramRolloverRefused("parent supervisor row still claims a worker")
    if require_global_idle and int(global_running or 0) != 0:
        raise ProgramRolloverRefused("production supervisor reports another active worker; rollover admission is paused")
    if int(snapshot.get("legacy_budget_ambiguous") or 0):
        raise ProgramRolloverRefused("parent operational budget envelope is ambiguous")
    if not attempt_rows:
        raise ProgramRolloverRefused("parent has no durable semantic-attempt history")
    if any(row.get("status") in {"RESERVED", "RUNNING"} for row in attempt_rows):
        raise ProgramRolloverRefused("parent has a nonterminal semantic attempt")
    if any(
        int(row.get("cost_known") or 0) != 1
        or int(row.get("cost_accounted") or 0) != 1
        or int(row.get("tokens_known") or 0) != 1
        for row in attempt_rows
    ):
        raise ProgramRolloverRefused("parent semantic attempt accounting is unknown or incomplete")
    cost = sum(float(row.get("cost_usd") or 0.0) for row in attempt_rows)
    input_tokens = sum(int(row.get("input_tokens") or 0) for row in attempt_rows)
    output_tokens = sum(int(row.get("output_tokens") or 0) for row in attempt_rows)
    cache_tokens = sum(int(row.get("cache_read_tokens") or 0) for row in attempt_rows)
    creation_tokens = sum(int(row.get("cache_creation_tokens") or 0) for row in attempt_rows)
    checks = (
        ("total_cost_usd", cost, 1e-7),
        ("total_input_tokens", input_tokens, 0),
        ("total_output_tokens", output_tokens, 0),
        ("total_cache_read_tokens", cache_tokens, 0),
        ("total_cache_creation_tokens", creation_tokens, 0),
        ("observed_total_tokens", input_tokens + output_tokens + cache_tokens + creation_tokens, 0),
    )
    for field, total, tolerance in checks:
        actual = snapshot.get(field)
        if actual is None or (
            not math.isclose(float(actual), float(total), rel_tol=0.0, abs_tol=tolerance)
        ):
            raise ProgramRolloverRefused(f"parent accounting does not reconcile at {field}")
    return snapshot, attempt_rows, {
        "cost_usd": cost,
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "cache_read_tokens": cache_tokens,
        "cache_creation_tokens": creation_tokens,
        "observed_total_tokens": input_tokens + output_tokens + cache_tokens + creation_tokens,
    }


def _remaining_operational_envelope(
    job: dict[str, Any],
    totals: dict[str, Any],
    *,
    now: float | None = None,
) -> dict[str, Any]:
    """Return ceilings that preserve, rather than replenish, parent authority."""
    def remaining(ceiling_key: str, spent_key: str, *, off_value: Any = 0) -> Any:
        ceiling = job.get(ceiling_key)
        if ceiling is None or float(ceiling) <= 0:
            return off_value
        left = float(ceiling) - float(job.get(spent_key) or 0)
        if left <= 0:
            raise ProgramRolloverRefused(f"no remaining {ceiling_key} envelope")
        return int(left) if ceiling_key != "max_total_cost_usd" else left

    infra = int(job.get("max_infra_failures") or 0) - int(job.get("infra_failures") or 0)
    transient = int(job.get("max_transient_failures") or 0) - int(job.get("transient_failures") or 0)
    cycles = int(job.get("max_transient_recovery_cycles") or 0) - int(job.get("transient_recovery_cycles") or 0)
    if min(infra, transient, cycles) < 0:
        raise ProgramRolloverRefused("parent failure counters exceed their frozen operational envelope")
    observed_at = float(now if now is not None else time.time())
    wall_clock = _wall_clock_authority(job, now=observed_at)
    deadline = wall_clock["parent_deadline_unix"]
    wall = int(deadline - observed_at) if deadline is not None else 0
    if deadline is not None and wall <= 0:
        raise ProgramRolloverRefused("parent wall-clock envelope is exhausted")
    return {
        "max_infra_failures": infra,
        "max_transient_failures": transient,
        "max_transient_recovery_cycles": cycles,
        "max_total_cost_usd": remaining("max_total_cost_usd", "total_cost_usd", off_value=0.0),
        "max_total_tokens": remaining("max_total_tokens", "observed_total_tokens", off_value=0),
        "max_wall_seconds": wall,
        "max_pass_runtime_seconds": int(job.get("max_pass_runtime_seconds") or 0),
    }


def _verified_current_checkpoint_id(meta: dict[str, Any], pstate: dict[str, Any]) -> str:
    """Prove one current checkpoint is the next eligible point in the frozen graph."""
    current = pstate.get("current_checkpoints") or []
    if len(current) != 1 or pstate.get("blocked") is True:
        raise ProgramRolloverRefused("parent must have one eligible, nonblocked current checkpoint")
    packet_ids = [
        str(cp.get("id") or "")
        for cp in (meta.get("checkpoint_graph") or {}).get("checkpoints", [])
        if isinstance(cp, dict)
    ]
    finalized_rows = pstate.get("finalized_checkpoints") or []
    finalized_ids = [
        str(row.get("id") or "") for row in finalized_rows if isinstance(row, dict)
    ]
    if (
        len(finalized_ids) != len(finalized_rows)
        or len(finalized_ids) != len(set(finalized_ids))
        or any(cp_id not in packet_ids for cp_id in finalized_ids)
        or any(row.get("terminal_state") != "APPROVED" for row in finalized_rows)
    ):
        raise ProgramRolloverRefused("parent finalized-checkpoint evidence is contradictory or non-approved")
    checkpoint_rows = {
        str(cp.get("id")): cp
        for cp in (pstate.get("checkpoints") or [])
        if isinstance(cp, dict)
    }
    if any(checkpoint_rows.get(cp_id, {}).get("terminal") != "APPROVED" for cp_id in finalized_ids):
        raise ProgramRolloverRefused("parent finalized list does not match checkpoint terminal states")
    finalized_set = set(finalized_ids)
    if any(
        cp.get("terminal") == "APPROVED" and str(cp.get("id")) not in finalized_set
        for cp in checkpoint_rows.values()
    ):
        raise ProgramRolloverRefused("parent checkpoint terminal state is missing finalized evidence")
    expected_current = program.advance_to_next(pstate, meta).get("current_checkpoints") or []
    if current != expected_current:
        raise ProgramRolloverRefused("parent current checkpoint is not the next eligible frozen checkpoint")
    return str(current[0])


def _assert_parent_artifacts(
    repo: Path,
    run_id: str,
    *,
    expected_packet_sha: str,
    expected_baseline_sha: str,
    expected_candidate_sha: str,
    db_path: Path | None = None,
) -> dict[str, Any]:
    root = state.run_dir(repo, run_id)
    if (root / "STATE_TXN.json").exists():
        raise ProgramRolloverRefused("parent has an unfinished state transaction")
    intact, problems = integrity.assert_artifacts_intact(repo, run_id)
    if not intact:
        raise ProgramRolloverRefused("parent artifact chain is not intact: " + "; ".join(problems))
    event_path = root / "EVENTS.log"
    events = integrity.read_event_chain(event_path)
    if not events or integrity.compute_event_chain_hash(event_path) != integrity.get_event_chain_hash(event_path):
        raise ProgramRolloverRefused("parent event chain is absent or invalid")
    state_doc = state.load(repo, run_id)
    if not isinstance(state_doc, dict) or schema_validate.validate_state(state_doc):
        raise ProgramRolloverRefused("parent STATE schema is invalid")
    state_ok, state_reason = integrity.verify_state_sha(root / "STATE.json", event_path)
    if not state_ok:
        raise ProgramRolloverRefused("parent STATE/event binding is invalid: " + state_reason)
    if state_doc.get("state") != "BLOCKED" or state.is_stop_requested(repo, run_id):
        raise ProgramRolloverRefused("parent must be BLOCKED and not explicitly STOPPED")
    if state_doc.get("last_candidate_sha") != expected_candidate_sha:
        raise ProgramRolloverRefused("parent last candidate does not match the explicit expected SHA")

    packet_path = root / "WORK_PACKET.md"
    packet_bytes = packet_path.read_bytes()
    packet_sha = hashlib.sha256(packet_bytes).hexdigest()
    if packet_sha != expected_packet_sha:
        raise ProgramRolloverRefused("parent packet SHA does not match the explicit expected SHA")
    meta, _ = packet.parse_packet_file(packet_path)
    packet_errors = packet.validate_packet_for_approval(meta)
    if packet_errors or not packet.packet_is_program(meta):
        raise ProgramRolloverRefused("parent packet is invalid or not PROGRAM mode")
    if not isinstance(meta.get("runner_profile"), str) or not meta["runner_profile"].strip():
        raise ProgramRolloverRefused("parent packet has no frozen runner profile")
    approval_doc = approval.load_approval(repo, run_id)
    approval_ok, approval_reason = approval.validate_approval_binding(
        canonical_repo=repo,
        run_id=run_id,
        approval=approval_doc,
        packet=meta,
        packet_path=packet_path,
    )
    if not approval_ok:
        raise ProgramRolloverRefused("parent approval binding is invalid: " + approval_reason)
    baseline = str((approval_doc or {}).get("baseline_sha") or "")
    if baseline != expected_baseline_sha:
        raise ProgramRolloverRefused("parent approval baseline does not match explicit expected SHA")
    if git_checks.branch_head(repo, str((approval_doc or {}).get("baseline_branch") or "")) != baseline:
        raise ProgramRolloverRefused("parent baseline branch ref has moved")

    pstate = state_doc.get("program") or {}
    current_checkpoint_id = _verified_current_checkpoint_id(meta, pstate)
    cp_meta = next(
        (cp for cp in (meta.get("checkpoint_graph") or {}).get("checkpoints", []) if cp.get("id") == current_checkpoint_id),
        None,
    )
    cp_state = next((cp for cp in (pstate.get("checkpoints") or []) if cp.get("id") == current_checkpoint_id), None)
    if not isinstance(cp_meta, dict) or not isinstance(cp_state, dict) or cp_state.get("terminal"):
        raise ProgramRolloverRefused("parent CP-01 packet/state identity is invalid")
    graph_ok, graph_reason = program.verify_frozen_graph(meta, pstate)
    if not graph_ok:
        raise ProgramRolloverRefused("parent PROGRAM graph is not frozen to packet: " + graph_reason)

    candidate = expected_candidate_sha
    parent_branch = str((approval_doc or {}).get("candidate_branch") or "")
    if not git_checks.commit_exists(repo, candidate):
        raise ProgramRolloverRefused("parent candidate commit is unavailable")
    if not build_finalize._ancestor_of(repo, candidate, baseline):
        raise ProgramRolloverRefused("parent candidate is not a descendant of the approved baseline")
    if not build_finalize._candidate_branch_contains(repo, parent_branch, candidate):
        raise ProgramRolloverRefused("parent candidate branch does not contain candidate")
    if git_checks.current_branch(repo) != str((approval_doc or {}).get("baseline_branch") or "") or git_checks.current_head(repo) != baseline:
        raise ProgramRolloverRefused("canonical checkout is not at the sealed baseline branch/SHA")
    if not _canonical_product_checkout_is_clean(repo):
        raise ProgramRolloverRefused("canonical product checkout is not clean")

    build_receipt = receipts.load_receipt(repo, run_id)
    if not isinstance(build_receipt, dict) or schema_validate.validate_receipt(build_receipt):
        raise ProgramRolloverRefused("parent BUILD_RECEIPT is missing or schema-invalid")
    if (
        build_receipt.get("candidate_sha") != candidate
        or build_receipt.get("baseline_sha") != baseline
        or build_receipt.get("candidate_branch") != parent_branch
        or build_receipt.get("packet_sha256") != packet_sha
        or build_receipt.get("approval_sha256") != approval.approval_artifact_sha256(approval_doc or {})
        or build_receipt.get("validation_status") != "PASS"
        or build_receipt.get("next_state") != "READY_FOR_REVIEW"
        or (build_receipt.get("scope_check") or {}).get("result") != "pass"
        or (build_receipt.get("protected_path_check") or {}).get("result") != "pass"
        or (build_receipt.get("secret_scan_check") or {}).get("result") != "pass"
        or (build_receipt.get("candidate_identity_reproof") or {}).get("result") != "pass"
        or (build_receipt.get("program_source_ceiling_check") or {}).get("result") != "pass"
    ):
        raise ProgramRolloverRefused("parent BUILD_RECEIPT does not prove the exact clean in-scope candidate")
    if any(not row.get("passed") for row in (build_receipt.get("validation") or [])):
        raise ProgramRolloverRefused("parent BUILD_RECEIPT contains a failed required validation")

    review_verdict = verdicts.load_verdict(repo, run_id)
    if not isinstance(review_verdict, dict) or schema_validate.validate_verdict(review_verdict):
        raise ProgramRolloverRefused("parent REVIEW_VERDICT is missing or schema-invalid")
    assessment_path = assessment.assessment_path(repo, run_id)
    reviewer_assessment = util.read_private_json(assessment_path, default=None)
    if not isinstance(reviewer_assessment, dict) or assessment.validate_assessment_contract(reviewer_assessment):
        raise ProgramRolloverRefused("parent semantic reviewer assessment is missing or invalid")

    validation_rows = review_verdict.get("validation_results")
    expected_validation = program.resolve_effective_required_validation(meta, state_doc)
    if (
        review_verdict.get("verdict") != "CHANGES_REQUESTED"
        or review_verdict.get("failure_reason") != "validation_failed"
        or review_verdict.get("recommended_next_state") != "CHANGES_REQUESTED"
        or not isinstance(validation_rows, list)
        or len(validation_rows) != 1
        or len(expected_validation) != 1
    ):
        raise ProgramRolloverRefused("parent verdict is not a single validation-only rejection")
    failed = validation_rows[0]
    if (
        failed.get("passed") is not False
        or failed.get("command") != expected_validation[0].get("command")
        or failed.get("name") != expected_validation[0].get("name")
        or failed.get("infra_failure") is not False
        or failed.get("candidate_invalid") is not False
        or failed.get("timed_out") is True
        or not re.fullmatch(r"[0-9a-f]{64}", str(failed.get("stderr_sha256") or ""))
    ):
        raise ProgramRolloverRefused("parent has ambiguous or contradictory validation failure evidence")
    if (
        (review_verdict.get("infra_failure") or {}).get("result") != "pass"
        or int((review_verdict.get("infra_failure") or {}).get("count", -1)) != 0
        or (review_verdict.get("candidate_environment_invalid") or {}).get("result") != "pass"
        or int((review_verdict.get("candidate_environment_invalid") or {}).get("count", -1)) != 0
        or (review_verdict.get("scope_check") or {}).get("result") != "pass"
        or (review_verdict.get("protected_path_check") or {}).get("result") != "pass"
        or (review_verdict.get("secret_scan_check") or {}).get("result") != "pass"
        or (review_verdict.get("integrity_check") or {}).get("acceptance_coverage_complete") is not True
        or (review_verdict.get("integrity_check") or {}).get("non_goal_coverage_complete") is not True
    ):
        raise ProgramRolloverRefused("parent review has candidate/authority findings beyond the validation failure")
    if any(item.get("classification") == "must_fix" for item in review_verdict.get("findings") or []):
        raise ProgramRolloverRefused("parent REVIEW_VERDICT contains a must-fix finding")
    if reviewer_assessment.get("recommended_verdict") != "APPROVED":
        raise ProgramRolloverRefused("parent semantic reviewer did not recommend approval")
    if reviewer_assessment.get("review_scope") != "checkpoint":
        raise ProgramRolloverRefused("parent semantic reviewer scope is not the current checkpoint")
    if reviewer_assessment.get("scope_findings") or reviewer_assessment.get("protected_findings") or reviewer_assessment.get("secret_findings"):
        raise ProgramRolloverRefused("parent semantic reviewer reported scope/protected/secret findings")
    if any(item.get("classification") == "must_fix" for item in reviewer_assessment.get("findings") or []):
        raise ProgramRolloverRefused("parent semantic assessment contains a must-fix finding")
    expected_assessment = assessment.build_skeleton(repo, run_id)
    if any(reviewer_assessment.get(key) != expected_assessment.get(key) for key in assessment.FIXED_KEYS):
        raise ProgramRolloverRefused("parent reviewer assessment fixed identity does not match the core skeleton")
    ac_map = {str(row.get("id")): row.get("result") for row in review_verdict.get("acceptance_results") or []}
    required_acs = program.current_checkpoint_acceptance_criterion_ids(meta, pstate)
    if any(ac_map.get(ac) != "pass" for ac in required_acs):
        raise ProgramRolloverRefused("parent reviewer did not pass every current-checkpoint acceptance criterion")
    ng_map = {str(row.get("id")): row.get("result") for row in review_verdict.get("non_goal_results") or []}
    required_ngs = [str(item.get("id")) for item in meta.get("non_goals") or [] if isinstance(item, dict)]
    if any(ng_map.get(ng) != "preserved" for ng in required_ngs):
        raise ProgramRolloverRefused("parent reviewer did not preserve every packet non-goal")

    builder_wt = worktrees.builder_worktree(repo, run_id)
    reviewer_wt = worktrees.reviewer_worktree(repo, run_id)
    for name, wt in (("builder", builder_wt), ("reviewer", reviewer_wt)):
        if (
            not wt.is_dir()
            or not worktrees.is_registered_worktree(repo, wt)
            or git_checks.current_head(wt) != candidate
            or git_checks.dirty_status(wt) != "clean"
        ):
            raise ProgramRolloverRefused(f"parent {name} worktree is not clean and pinned to the candidate")
    if git_checks.current_branch(builder_wt) != parent_branch:
        raise ProgramRolloverRefused("parent builder branch does not match its approval")

    parent_job, attempts, accounting = _db_parent_snapshot(
        repo, run_id, db_path=db_path, require_global_idle=True,
    )
    latest_reviewer = next(
        (row for row in reversed(attempts) if row.get("role") == "reviewer" and int(row.get("semantic_accepted") or 0) == 1),
        None,
    )
    if not isinstance(latest_reviewer, dict) or latest_reviewer.get("status") != "COMPLETED":
        raise ProgramRolloverRefused("no accepted completed reviewer attempt exists")
    if (
        latest_reviewer.get("attempt_id") != parent_job.get("latest_attempt_id")
        or latest_reviewer.get("accepted_candidate_sha") != candidate
        or latest_reviewer.get("accepted_semantic_sha256") != util.sha256_file(assessment_path)
    ):
        raise ProgramRolloverRefused("accepted reviewer ledger identity does not match the sealed assessment/candidate")
    cumulative = pstate.get("cumulative_counters") or {}
    mirror_fields = {
        "build_pass_count": "build_pass_count",
        "review_pass_count": "review_pass_count",
        "repair_round": "repair_round_count",
    }
    if any(
        int(state_doc.get(state_key) or 0) != int(cumulative.get(program_key, -1))
        for state_key, program_key in mirror_fields.items()
    ):
        raise ProgramRolloverRefused("parent STATE and PROGRAM cumulative counters do not reconcile")
    build_cap = int(cp_meta.get("risk_budget", {}).get("max_build_passes") or 0)
    review_cap = int(cp_meta.get("risk_budget", {}).get("max_review_passes") or 0)
    if build_cap != int(cp_state.get("build_pass_count") or 0):
        raise ProgramRolloverRefused("parent build cap is not exactly exhausted")
    if int(cp_state.get("review_pass_count") or 0) >= review_cap:
        raise ProgramRolloverRefused("parent has no remaining checkpoint review entitlement")

    source = {
        "packet_sha256": packet_sha,
        "approval_sha256": util.sha256_file(root / "APPROVAL.json"),
        "state_sha256": util.sha256_file(root / "STATE.json"),
        "event_chain_sha256": integrity.compute_event_chain_hash(event_path),
        "build_receipt_sha256": util.sha256_file(root / "BUILD_RECEIPT.json"),
        "review_verdict_sha256": util.sha256_file(root / "REVIEW_VERDICT.json"),
        "review_assessment_sha256": util.sha256_file(assessment_path),
        "review_assessment_path": str(assessment_path),
        "review_attempt_id": str(latest_reviewer["attempt_id"]),
        "failed_validation_stderr_sha256": str(failed.get("stderr_sha256") or ""),
        "parent_candidate_sha": candidate,
        "parent_candidate_branch": parent_branch,
        "parent_baseline_sha": baseline,
        "parent_baseline_branch": str((approval_doc or {}).get("baseline_branch") or ""),
        "parent_job_id": int(parent_job["id"]),
        "parent_job_sha256": _snapshot_digest(parent_job),
        "parent_runtime_generation": str(parent_job.get("runtime_generation") or ""),
        "parent_cost_totals": accounting,
        "parent_attempt_count": len(attempts),
    }
    observed_at = _wall_clock_now()
    wall_clock = _wall_clock_authority(parent_job, now=observed_at)
    return {
        "repo": repo,
        "parent_run_id": run_id,
        "state": state_doc,
        "packet_meta": meta,
        "packet_bytes": packet_bytes,
        "approval": approval_doc,
        "build_receipt": build_receipt,
        "review_verdict": review_verdict,
        "review_assessment": reviewer_assessment,
        "review_assessment_path": assessment_path,
        "program": pstate,
        "checkpoint_meta": cp_meta,
        "checkpoint_id": current_checkpoint_id,
        "checkpoint_state": cp_state,
        "job": parent_job,
        "attempts": attempts,
        "accounting": accounting,
        "latest_reviewer_attempt": latest_reviewer,
        "source": source,
        "operational_envelope": _remaining_operational_envelope(
            parent_job, accounting, now=observed_at,
        ),
        "wall_clock_authority": wall_clock,
        "wall_clock_observed_at": observed_at,
    }


def _child_run_id(source: dict[str, Any], parent_run_id: str) -> str:
    identity = "\0".join((
        parent_run_id,
        str(source["packet_sha256"]),
        str(source["parent_candidate_sha"]),
        str(source["review_attempt_id"]),
    ))
    return "roll-" + hashlib.sha256(identity.encode("utf-8")).hexdigest()[:24]


def create_linked_program_rollover(
    *,
    canonical_repo: Path,
    parent_run_id: str,
    expected_packet_sha256: str,
    expected_baseline_sha: str,
    expected_candidate_sha: str,
    db_path: Path | None = None,
) -> dict[str, Any]:
    """Create/replay one deterministic linked child without starting BUILD."""
    repo = Path(canonical_repo).resolve(strict=False)
    if not re.fullmatch(r"[0-9a-f]{64}", expected_packet_sha256):
        raise ProgramRolloverRefused("expected packet SHA must be full SHA-256")
    if not re.fullmatch(r"[0-9a-f]{40}", expected_baseline_sha):
        raise ProgramRolloverRefused("expected baseline must be a full Git SHA")
    if not re.fullmatch(r"[0-9a-f]{40}", expected_candidate_sha):
        raise ProgramRolloverRefused("expected candidate must be a full Git SHA")
    proof = _assert_parent_artifacts(
        repo,
        parent_run_id,
        expected_packet_sha=expected_packet_sha256,
        expected_baseline_sha=expected_baseline_sha,
        expected_candidate_sha=expected_candidate_sha,
        db_path=db_path,
    )
    parent_state = proof["state"]
    parent_program = proof["program"]
    candidate = expected_candidate_sha
    child_id = _child_run_id(proof["source"], parent_run_id)
    child_branch = branch_resolver.default_candidate_branch(child_id)
    state.validate_run_id(child_id)
    if not git_checks.is_valid_branch_name(child_branch):
        raise ProgramRolloverRefused("derived child candidate branch is not a valid Git ref")
    child_root = state.run_dir(repo, child_id)
    child_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    authority_path = child_root / "ROLLOVER_AUTHORITY.json"
    child_binding = _rollover_capability_binding(
        repo,
        child_id,
        proof["packet_meta"],
        runner=str(proof["job"].get("runner") or ""),
        allow_create=not authority_path.exists(),
    )
    child_binding_sha = str(child_binding.get("binding_sha256") or "")
    if not re.fullmatch(r"[0-9a-f]{64}", child_binding_sha):
        raise ProgramRolloverRefused("child capability binding has no valid digest")

    source_packet_sha = str(proof["source"]["packet_sha256"])
    authority_doc = {
        "schema": AUTHORITY_SCHEMA,
        "parent_run_id": parent_run_id,
        "child_run_id": child_id,
        "candidate_sha": candidate,
        "child_packet_sha256": source_packet_sha,
        "child_baseline_sha": expected_baseline_sha,
        "child_baseline_branch": str((proof["approval"] or {}).get("baseline_branch") or ""),
        "child_candidate_branch": child_branch,
        "source": proof["source"],
        "imported_counters": {
            "build_pass_count": int(parent_state.get("build_pass_count") or 0),
            "review_pass_count": int(parent_state.get("review_pass_count") or 0),
            "repair_round_count": int(parent_state.get("repair_round") or 0),
            "files_changed_unique": int((parent_program.get("cumulative_counters") or {}).get("files_changed_unique") or 0),
            "diff_lines_total": int((parent_program.get("cumulative_counters") or {}).get("diff_lines_total") or 0),
        },
        "checkpoint_id": proof["checkpoint_id"],
        "operational_envelope_remaining": proof["operational_envelope"],
        "wall_clock_authority": proof["wall_clock_authority"],
        "capability_binding_sha256": child_binding_sha,
        "runner": str(proof["job"].get("runner") or ""),
        "source_failure_classification": "historical_validation_cause_unproven",
        "source_diagnostic_sha256": proof["source"]["failed_validation_stderr_sha256"],
        "source_diagnostic_bytes_found": False,
    }
    _create_once(child_root / "WORK_PACKET.md", proof["packet_bytes"])
    if authority_path.exists():
        prior_authority = _load_private_json(authority_path)
        if not isinstance(prior_authority, dict):
            raise ProgramRolloverRefused("existing child rollover authority is unreadable")
        prior_envelope = prior_authority.get("operational_envelope_remaining")
        comparable_prior = dict(prior_authority)
        comparable_new = dict(authority_doc)
        comparable_prior.pop("operational_envelope_remaining", None)
        comparable_new.pop("operational_envelope_remaining", None)
        comparable_prior.pop("wall_clock_authority", None)
        comparable_new.pop("wall_clock_authority", None)
        if comparable_prior != comparable_new or not isinstance(prior_envelope, dict):
            raise ProgramRolloverRefused("existing child authority conflicts with the proven parent source")
        current_envelope = authority_doc["operational_envelope_remaining"]
        if any(
            prior_envelope.get(key) != current_envelope.get(key)
            for key in current_envelope
            if key != "max_wall_seconds"
        ):
            raise ProgramRolloverRefused("existing child operational envelope conflicts with parent remaining authority")
        prior_wall = int(prior_envelope.get("max_wall_seconds") or 0)
        current_wall = int(current_envelope.get("max_wall_seconds") or 0)
        prior_clock = prior_authority.get("wall_clock_authority")
        current_clock = authority_doc.get("wall_clock_authority")
        if not isinstance(prior_clock, dict) or not isinstance(current_clock, dict):
            raise ProgramRolloverRefused("existing rollover authority has no wall-clock deadline binding")
        if prior_clock.get("parent_deadline_unix") != current_clock.get("parent_deadline_unix"):
            raise ProgramRolloverRefused("existing rollover wall-clock deadline conflicts with parent authority")
        parent_deadline = current_clock.get("parent_deadline_unix")
        if parent_deadline is None:
            if prior_wall != 0 or prior_clock.get("child_execution_started_at") is not None:
                raise ProgramRolloverRefused("existing rollover wall-clock envelope conflicts with an unlimited parent")
        else:
            try:
                prior_origin = float(prior_clock["child_execution_started_at"])
                deadline = float(parent_deadline)
                observed_at = float(proof["wall_clock_observed_at"])
                prior_duration = int(prior_wall)
            except (KeyError, TypeError, ValueError, OverflowError) as exc:
                raise ProgramRolloverRefused("existing rollover wall-clock authority is malformed") from exc
            if (
                prior_duration <= 0
                or prior_origin <= 0
                or prior_origin > observed_at
                or prior_origin + prior_duration > deadline
                or current_wall > prior_duration
            ):
                raise ProgramRolloverRefused("existing rollover wall-clock envelope is no longer safe to replay")
        if prior_wall != current_wall and not (
            parent_deadline is not None and 0 < current_wall < prior_wall
        ):
            raise ProgramRolloverRefused("existing rollover wall-clock envelope is no longer safe to replay")
        # Keep the first-created clock origin and duration immutable.  Replays
        # may observe less time remaining, but can never restart or widen the
        # parent deadline.
        authority_doc["operational_envelope_remaining"] = prior_envelope
        authority_doc["wall_clock_authority"] = prior_clock
    authority_bytes = _json_bytes(authority_doc)
    authority_sha = hashlib.sha256(authority_bytes).hexdigest()
    _create_once(authority_path, authority_bytes)
    if hashlib.sha256(authority_path.read_bytes()).hexdigest() != authority_sha:
        raise ProgramRolloverRefused("child rollover authority did not persist byte-identically")

    initial = state.load(repo, child_id)
    if initial is None:
        initial = state.initial_state(child_id)
        initial["spec_baseline_branch"] = authority_doc["child_baseline_branch"]
        initial["spec_baseline_sha"] = expected_baseline_sha
        initial["spec_snapshot_at"] = util.utc_now_iso()
        state.save(repo, child_id, initial)
    elif (
        initial.get("run_id") != child_id
        or initial.get("spec_baseline_sha") != expected_baseline_sha
        or initial.get("spec_baseline_branch") != authority_doc["child_baseline_branch"]
    ):
        raise ProgramRolloverRefused("existing deterministic child STATE conflicts with rollover authority")
    events_path = state.events_path(repo, child_id)
    child_events = integrity.read_event_chain(events_path) if events_path.exists() else []
    if not any(event.get("event_type") == "run_created" for event in child_events):
        state.append_event(
            repo,
            child_id,
            event_type="run_created",
            old_state=None,
            new_state="AWAITING_APPROVAL",
            actor="ofloop-program-rollover",
            reason=f"linked candidate rollover from {parent_run_id}; no BUILD entitlement added",
            extras={"parent_run_id": parent_run_id, "rollover_authority_sha256": authority_sha},
        )

    existing = state.load_verified(repo, child_id)
    if isinstance(existing.get("program"), dict):
        existing_rollover = (existing.get("program") or {}).get("rollover_provenance") or {}
        if (
            existing_rollover.get("parent_run_id") != parent_run_id
            or existing_rollover.get("rollover_authority_sha256") != authority_sha
            or existing_rollover.get("candidate_sha") != candidate
            or int(existing.get("build_pass_count") or 0) != authority_doc["imported_counters"]["build_pass_count"]
            or int(existing.get("review_pass_count") or 0) != authority_doc["imported_counters"]["review_pass_count"]
            or int(existing.get("repair_round") or 0) != authority_doc["imported_counters"]["repair_round_count"]
        ):
            raise ProgramRolloverRefused("existing child rollover state conflicts with immutable source authority")
        imported = existing
    else:
        program_block = json.loads(integrity.canonical_json_dumps(parent_program))
        program_block.setdefault("source_sha_provenance", {})["candidate_branch"] = child_branch
        counters = authority_doc["imported_counters"]
        cp_state = proof["checkpoint_state"]
        rollover = {
            "schema": "ownframework-loop-program-rollover/v1",
            "parent_run_id": parent_run_id,
            "candidate_sha": candidate,
            "rollover_authority_sha256": authority_sha,
            "source_packet_sha256": proof["source"]["packet_sha256"],
            "source_approval_sha256": proof["source"]["approval_sha256"],
            "source_state_sha256": proof["source"]["state_sha256"],
            "source_event_chain_sha256": proof["source"]["event_chain_sha256"],
            "source_build_receipt_sha256": proof["source"]["build_receipt_sha256"],
            "source_review_verdict_sha256": proof["source"]["review_verdict_sha256"],
            "source_review_assessment_sha256": proof["source"]["review_assessment_sha256"],
            "source_review_attempt_id": proof["source"]["review_attempt_id"],
            "checkpoint_id": authority_doc["checkpoint_id"],
            "imported_counters": counters,
            "checkpoint_counters": {
                "build_pass_count": int(cp_state.get("build_pass_count") or 0),
                "review_pass_count": int(cp_state.get("review_pass_count") or 0),
                "repair_round_count": int(cp_state.get("repair_round_count") or 0),
                "no_progress_streak": int(cp_state.get("no_progress_streak") or 0),
            },
            "initial_review_pass_number": int(parent_state.get("review_pass_count") or 0) + 1,
        }
        program_block["rollover_provenance"] = rollover
        imported = state.initialize_program_rollover(
            repo,
            child_id,
            program_block=program_block,
            build_pass_count=counters["build_pass_count"],
            review_pass_count=counters["review_pass_count"],
            repair_round=counters["repair_round_count"],
            no_progress_streak=int(parent_state.get("no_progress_streak") or 0),
            candidate_sha=candidate,
            baseline_sha=expected_baseline_sha,
            baseline_branch=authority_doc["child_baseline_branch"],
            candidate_branch=child_branch,
            parent_run_id=parent_run_id,
            rollover_authority_sha256=authority_sha,
        )
    return {
        "ok": True,
        "parent_run_id": parent_run_id,
        "run_id": child_id,
        "state": imported.get("state"),
        "candidate_sha": candidate,
        "candidate_branch": child_branch,
        "packet_sha256": source_packet_sha,
        "baseline_sha": expected_baseline_sha,
        "rollover_authority_sha256": authority_sha,
        "build_pass_count": imported.get("build_pass_count"),
        "review_pass_count": imported.get("review_pass_count"),
        "repair_round": imported.get("repair_round"),
        "next_step": f"approve the exact copied packet with: ofloop spec approve {repo} {child_id}",
    }


def _verify_parent_source_authority(
    canonical_repo: Path,
    authority_doc: dict[str, Any],
) -> None:
    parent_id = str(authority_doc.get("parent_run_id") or "")
    state.validate_run_id(parent_id)
    source = authority_doc.get("source") or {}
    parent_root = state.run_dir(canonical_repo, parent_id)
    if (parent_root / "STATE_TXN.json").exists():
        raise ProgramRolloverRefused("parent acquired an unfinished state transaction after rollover")
    paths = {
        "WORK_PACKET.md": source.get("packet_sha256"),
        "APPROVAL.json": source.get("approval_sha256"),
        "STATE.json": source.get("state_sha256"),
        "BUILD_RECEIPT.json": source.get("build_receipt_sha256"),
        "REVIEW_VERDICT.json": source.get("review_verdict_sha256"),
    }
    for name, digest in paths.items():
        path = parent_root / name
        if not isinstance(digest, str) or not path.is_file() or util.sha256_file(path) != digest:
            raise ProgramRolloverRefused(f"rollover parent evidence changed: {name}")
    assessment_path = Path(str(source.get("review_assessment_path") or ""))
    if (
        not assessment_path.is_file()
        or util.sha256_file(assessment_path) != source.get("review_assessment_sha256")
    ):
        raise ProgramRolloverRefused("rollover parent semantic assessment changed")
    events_path = parent_root / "EVENTS.log"
    if (
        not events_path.is_file()
        or integrity.compute_event_chain_hash(events_path) != source.get("event_chain_sha256")
    ):
        raise ProgramRolloverRefused("rollover parent event-chain evidence changed")
    state_ok, reason = integrity.verify_state_sha(parent_root / "STATE.json", events_path)
    if not state_ok:
        raise ProgramRolloverRefused("rollover parent state/event binding failed: " + reason)
    intact, errors = integrity.assert_artifacts_intact(canonical_repo, parent_id)
    if not intact:
        raise ProgramRolloverRefused("rollover parent artifact chain changed: " + "; ".join(errors))
    job, attempts, _ = _db_parent_snapshot(canonical_repo, parent_id)
    if (
        int(job.get("id") or -1) != int(source.get("parent_job_id") or -2)
        or _snapshot_digest(job) != source.get("parent_job_sha256")
        or len(attempts) != int(source.get("parent_attempt_count") or -1)
    ):
        raise ProgramRolloverRefused("rollover parent supervisor/attempt ledger changed")
    accepted = next((row for row in attempts if row.get("attempt_id") == source.get("review_attempt_id")), None)
    if (
        accepted is None
        or accepted.get("role") != "reviewer"
        or accepted.get("status") != "COMPLETED"
        or int(accepted.get("semantic_accepted") or 0) != 1
        or accepted.get("accepted_candidate_sha") != source.get("parent_candidate_sha")
        or accepted.get("accepted_semantic_sha256") != source.get("review_assessment_sha256")
    ):
        raise ProgramRolloverRefused("rollover parent accepted reviewer-attempt authority changed")


def _child_authority(canonical_repo: Path, run_id: str) -> tuple[dict[str, Any], str]:
    state.validate_run_id(run_id)
    root = state.run_dir(canonical_repo, run_id)
    path = root / "ROLLOVER_AUTHORITY.json"
    doc = _load_private_json(path)
    if not isinstance(doc, dict) or doc.get("schema") != AUTHORITY_SCHEMA or doc.get("child_run_id") != run_id:
        raise ProgramRolloverRefused("child rollover authority is missing or invalid")
    digest = util.sha256_file(path)
    return doc, digest


def verify_candidate_origin(
    canonical_repo: Path,
    run_id: str,
    *,
    expected_review_pass: int | None = None,
) -> dict[str, Any] | None:
    """Verify the child origin at its first inherited-candidate REVIEW only.

    Regular runs return None. Later reviews/checkpoints in a rollover child do
    not depend on the origin receipt; their own normal BUILD receipts apply.
    """
    repo = Path(canonical_repo).resolve(strict=False)
    current = state.load_verified(repo, run_id)
    if not state.is_program_state(current):
        return None
    program_state = current.get("program") or {}
    rollover = program_state.get("rollover_provenance") or {}
    if rollover.get("schema") != "ownframework-loop-program-rollover/v1":
        return None
    initial_review_pass = int(rollover.get("initial_review_pass_number") or 0)
    current_review_pass = int(current.get("review_pass_count") or 0)
    if expected_review_pass is not None and expected_review_pass != initial_review_pass:
        return None
    current_state = str(current.get("state") or "")
    # Admission/enqueue happen before the ordinary reviewer claim increments
    # the pass counter; review preparation/finalization happen after it does.
    preclaim = current_state == "READY_FOR_REVIEW" and current_review_pass == initial_review_pass - 1
    claimed = current_state == "REVIEWING" and current_review_pass == initial_review_pass
    if not (preclaim or claimed):
        return None
    authority_doc, authority_sha = _child_authority(repo, run_id)
    candidate = str(rollover.get("candidate_sha") or "")
    if (
        authority_sha != rollover.get("rollover_authority_sha256")
        or authority_doc.get("candidate_sha") != candidate
        or authority_doc.get("parent_run_id") != rollover.get("parent_run_id")
        or authority_doc.get("child_packet_sha256") != rollover.get("source_packet_sha256")
    ):
        raise ProgramRolloverRefused("child rollover authority hash/identity mismatch")
    _verify_parent_source_authority(repo, authority_doc)
    root = state.run_dir(repo, run_id)
    packet_path = root / "WORK_PACKET.md"
    approval_doc = approval.load_approval(repo, run_id)
    if (
        not packet_path.is_file()
        or util.sha256_file(packet_path) != authority_doc.get("child_packet_sha256")
        or not isinstance(approval_doc, dict)
    ):
        raise ProgramRolloverRefused("child packet/approval is missing or changed")
    meta, _ = packet.parse_packet_file(packet_path)
    approval_ok, approval_reason = approval.validate_approval_binding(
        canonical_repo=repo,
        run_id=run_id,
        approval=approval_doc,
        packet=meta,
        packet_path=packet_path,
    )
    if not approval_ok:
        raise ProgramRolloverRefused("child approval binding invalid: " + approval_reason)
    child_binding = _rollover_capability_binding(
        repo,
        run_id,
        meta,
        runner=str(authority_doc.get("runner") or ""),
        allow_create=False,
    )
    if child_binding.get("binding_sha256") != authority_doc.get("capability_binding_sha256"):
        raise ProgramRolloverRefused("child capability binding differs from linked rollover authority")
    receipt_path = receipts.receipt_path(repo, run_id)
    receipt_doc = receipts.load_receipt(repo, run_id)
    preflight_path = root / "ROLLOVER_PREFLIGHT.json"
    preflight_doc = _load_private_json(preflight_path)
    if not isinstance(receipt_doc, dict) or not isinstance(preflight_doc, dict):
        raise ProgramRolloverRefused("candidate-origin receipt/preflight is missing")
    receipt_sha = util.sha256_file(receipt_path)
    preflight_sha = util.sha256_file(preflight_path)
    origin = receipt_doc.get("candidate_origin") or {}
    if (
        receipt_doc.get("candidate_sha") != candidate
        or current.get("last_candidate_sha") != candidate
        or receipt_doc.get("packet_sha256") != authority_doc.get("child_packet_sha256")
        or receipt_doc.get("approval_sha256") != approval.approval_artifact_sha256(approval_doc)
        or receipt_doc.get("validation_status") != "PASS"
        or receipt_doc.get("next_state") != "READY_FOR_REVIEW"
        or preflight_doc.get("schema") != PREFLIGHT_SCHEMA
        or preflight_doc.get("result") != "PASS"
        or preflight_doc.get("run_id") != run_id
        or preflight_doc.get("candidate_sha") != candidate
        or preflight_doc.get("packet_sha256") != authority_doc.get("child_packet_sha256")
        or preflight_doc.get("approval_sha256") != approval.approval_artifact_sha256(approval_doc)
        or preflight_doc.get("capability_binding_sha256") != authority_doc.get("capability_binding_sha256")
        or rollover.get("preflight_sha256") != preflight_sha
        or rollover.get("review_admission_receipt_sha256") != receipt_sha
        or origin.get("schema") != ORIGIN_SCHEMA
        or origin.get("rollover_authority_sha256") != authority_sha
        or origin.get("parent_run_id") != authority_doc.get("parent_run_id")
        or origin.get("child_run_id") != run_id
        or origin.get("candidate_sha") != candidate
        or origin.get("preflight_sha256") != preflight_sha
        or origin.get("child_approval_sha256") != approval.approval_artifact_sha256(approval_doc)
    ):
        raise ProgramRolloverRefused("candidate-origin receipt is not bound to the exact child review authority")
    return {
        "parent_run_id": authority_doc["parent_run_id"],
        "child_run_id": run_id,
        "candidate_sha": candidate,
        "rollover_authority_sha256": authority_sha,
        "preflight_sha256": preflight_sha,
        "build_receipt_sha256": receipt_sha,
        "review_pass_number": initial_review_pass,
    }


def prepare_rollover_review(
    *,
    canonical_repo: Path,
    run_id: str,
    db_path: Path | None = None,
) -> dict[str, Any]:
    """Freshly validate the inherited candidate and admit it to ordinary REVIEW."""
    repo = Path(canonical_repo).resolve(strict=False)
    child = state.load_verified(repo, run_id)
    if not state.is_program_state(child):
        raise ProgramRolloverRefused("rollover child is not a PROGRAM state")
    program_state = child.get("program") or {}
    rollover = program_state.get("rollover_provenance") or {}
    if rollover.get("schema") != "ownframework-loop-program-rollover/v1":
        raise ProgramRolloverRefused("child has no rollover provenance")
    authority_doc, authority_sha = _child_authority(repo, run_id)
    if authority_sha != rollover.get("rollover_authority_sha256"):
        raise ProgramRolloverRefused("child rollover authority digest mismatch")
    inherited_envelope = authority_doc.get("operational_envelope_remaining")
    if not isinstance(inherited_envelope, dict):
        raise ProgramRolloverRefused("child rollover operational envelope is missing")
    _validate_frozen_wall_clock_authority(
        authority_doc, inherited_envelope, now=_wall_clock_now(),
    )
    _verify_parent_source_authority(repo, authority_doc)
    root = state.run_dir(repo, run_id)
    packet_path = root / "WORK_PACKET.md"
    packet_bytes = packet_path.read_bytes()
    packet_sha = hashlib.sha256(packet_bytes).hexdigest()
    if packet_sha != authority_doc.get("child_packet_sha256"):
        raise ProgramRolloverRefused("child packet bytes differ from linked parent packet")
    meta, _ = packet.parse_packet_file(packet_path)
    approval_doc = approval.load_approval(repo, run_id)
    approval_ok, approval_reason = approval.validate_approval_binding(
        canonical_repo=repo,
        run_id=run_id,
        approval=approval_doc,
        packet=meta,
        packet_path=packet_path,
    )
    if not approval_ok:
        raise ProgramRolloverRefused("child approval binding invalid: " + approval_reason)
    child_binding = _rollover_capability_binding(
        repo,
        run_id,
        meta,
        runner=str(authority_doc.get("runner") or ""),
        allow_create=False,
    )
    child_binding_sha = str(child_binding.get("binding_sha256") or "")
    if child_binding_sha != authority_doc.get("capability_binding_sha256"):
        raise ProgramRolloverRefused("child capability binding differs from linked rollover authority")
    approval_sha = approval.approval_artifact_sha256(approval_doc or {})
    candidate = str(rollover.get("candidate_sha") or "")
    if child.get("state") not in {"READY_TO_BUILD", "READY_FOR_REVIEW"}:
        raise ProgramRolloverRefused("child must be approved READY_TO_BUILD before rollover preflight")
    imported = rollover.get("imported_counters") or {}
    if (
        int(child.get("build_pass_count") or 0) != int(imported.get("build_pass_count", -1))
        or int(child.get("review_pass_count") or 0) != int(imported.get("review_pass_count", -1))
        or int(child.get("repair_round") or 0) != int(imported.get("repair_round_count", -1))
        or int(child.get("build_pass_count") or 0) != int(authority_doc["imported_counters"]["build_pass_count"])
    ):
        raise ProgramRolloverRefused("child imported counters changed")
    checkpoint_id = str(rollover.get("checkpoint_id") or "")
    current_ids = (program_state.get("current_checkpoints") or [])
    cp_meta = next((
        cp for cp in (meta.get("checkpoint_graph") or {}).get("checkpoints", [])
        if cp.get("id") == checkpoint_id
    ), None)
    cp_state = next((
        cp for cp in (program_state.get("checkpoints") or [])
        if cp.get("id") == checkpoint_id
    ), None)
    cp_counters = rollover.get("checkpoint_counters") or {}
    if (
        current_ids != [checkpoint_id]
        or not isinstance(cp_meta, dict)
        or not isinstance(cp_state, dict)
        or cp_state.get("terminal")
        or any(int(cp_state.get(key) or 0) != int(cp_counters.get(key, -1)) for key in (
            "build_pass_count", "review_pass_count", "repair_round_count", "no_progress_streak"
        ))
    ):
        raise ProgramRolloverRefused("rollover current checkpoint identity/counters changed")
    cp_build_count = int(cp_state.get("build_pass_count") or 0)
    cp_build_cap = int((cp_meta.get("risk_budget") or {}).get("max_build_passes") or 0)
    if cp_build_count != cp_build_cap:
        raise ProgramRolloverRefused("rollover candidate would require a new or reset checkpoint BUILD entitlement")
    if child.get("last_candidate_sha") != candidate:
        raise ProgramRolloverRefused("child state is not bound to the inherited candidate")
    expected_branch = str(authority_doc.get("child_candidate_branch") or "")
    branch = branch_resolver.resolve_candidate_branch(repo, run_id, packet=meta)
    if branch != expected_branch or approval_doc.get("candidate_branch") != expected_branch:
        raise ProgramRolloverRefused("child candidate branch does not match linked rollover authority")

    builder_info = worktrees.add_candidate_origin_worktree(
        repo,
        run_id,
        branch=expected_branch,
        candidate_sha=candidate,
        rollover_authority_sha256=authority_sha,
    )
    builder_wt = Path(builder_info["path"])
    if (
        git_checks.current_head(builder_wt) != candidate
        or git_checks.current_branch(builder_wt) != expected_branch
        or git_checks.dirty_status(builder_wt) != "clean"
        or not build_finalize._ancestor_of(repo, candidate, str(approval_doc.get("baseline_sha") or ""))
        or not build_finalize._candidate_branch_contains(repo, expected_branch, candidate)
    ):
        raise ProgramRolloverRefused("child candidate worktree/lineage failed exact identity proof")

    required = program.resolve_effective_required_validation(meta, child)
    if not required:
        raise ProgramRolloverRefused("packet has no effective required validation; rollover review is not admitted")
    preflight_path = root / "ROLLOVER_PREFLIGHT.json"
    if preflight_path.exists():
        preflight = _load_private_json(preflight_path)
        if (
            not isinstance(preflight, dict)
            or preflight.get("schema") != PREFLIGHT_SCHEMA
            or preflight.get("run_id") != run_id
            or preflight.get("parent_run_id") != authority_doc.get("parent_run_id")
            or preflight.get("rollover_authority_sha256") != authority_sha
            or preflight.get("candidate_sha") != candidate
            or preflight.get("packet_sha256") != packet_sha
            or preflight.get("approval_sha256") != approval_sha
            or preflight.get("capability_binding_sha256") != child_binding_sha
            or preflight.get("candidate_branch") != expected_branch
            or preflight.get("baseline_sha") != approval_doc.get("baseline_sha")
            or preflight.get("checkpoint_id") != checkpoint_id
            or preflight.get("build_pass_count_unchanged") != int(child.get("build_pass_count") or 0)
            or preflight.get("repair_round_unchanged") != int(child.get("repair_round") or 0)
        ):
            raise ProgramRolloverRefused("existing rollover preflight conflicts with exact authority")
        if preflight.get("result") != "PASS":
            raise ProgramRolloverRefused("prior rollover preflight failed; no silent retry or bypass is allowed")
        validations = preflight.get("validations") or []
        if not _validation_rows_match(
            required, validations, checkpoint_id=checkpoint_id,
            pass_number=int(child.get("build_pass_count") or 0),
        ):
            raise ProgramRolloverRefused("existing rollover preflight validation rows do not match the frozen packet")
    else:
        validations = []
        timeout = int((meta.get("required_runtime_proof") or {}).get("max_runtime_seconds") or 600)
        infra_marker = util.run_dir(repo, run_id) / "rollover-validation-infra.json"
        for index, spec in enumerate(required):
            result = validation_executor.run_required_validation(
                cwd=builder_wt,
                validation=spec,
                timeout_seconds=timeout,
                canonical_repo=repo,
                run_id=run_id,
                packet=meta,
                candidate_sha=candidate,
                role="builder",
                infra_failure_path=infra_marker,
                checkpoint_id=checkpoint_id,
                pass_number=int(child.get("build_pass_count") or 0),
                validation_index=index,
            )
            validations.append(result)
        identity_ok = (
            git_checks.current_head(builder_wt) == candidate
            and git_checks.current_branch(builder_wt) == expected_branch
            and git_checks.dirty_status(builder_wt) == "clean"
            and git_checks.branch_head(repo, str(approval_doc.get("baseline_branch") or ""))
                == str(approval_doc.get("baseline_sha") or "")
        )
        passed = identity_ok and _validation_rows_match(
            required,
            validations,
            checkpoint_id=checkpoint_id,
            pass_number=int(child.get("build_pass_count") or 0),
        )
        preflight = {
            "schema": PREFLIGHT_SCHEMA,
            "run_id": run_id,
            "parent_run_id": authority_doc["parent_run_id"],
            "rollover_authority_sha256": authority_sha,
            "candidate_sha": candidate,
            "packet_sha256": packet_sha,
            "approval_sha256": approval_sha,
            "capability_binding_sha256": child_binding_sha,
            "candidate_branch": expected_branch,
            "baseline_sha": str(approval_doc.get("baseline_sha") or ""),
            "checkpoint_id": checkpoint_id,
            "build_pass_count_unchanged": int(child.get("build_pass_count") or 0),
            "repair_round_unchanged": int(child.get("repair_round") or 0),
            "candidate_identity_reproof": "pass" if identity_ok else "fail",
            "validations": validations,
            "result": "PASS" if passed else "FAIL",
            "timestamp": util.utc_now_iso(),
        }
        _create_once_json(preflight_path, preflight)
        if not passed:
            raise ProgramRolloverRefused("fresh deterministic candidate validation failed; review was not admitted")

    # If a prior invocation admitted review but crashed before returning, the
    # state-transition owner and origin verifier make this replay idempotent.
    if child.get("state") == "READY_FOR_REVIEW":
        origin = verify_candidate_origin(repo, run_id, expected_review_pass=int(rollover.get("initial_review_pass_number") or 0))
        if not origin:
            raise ProgramRolloverRefused("READY_FOR_REVIEW child lacks valid candidate-origin authority")
        return {"ok": True, "run_id": run_id, "state": "READY_FOR_REVIEW", "already_admitted": True, **origin}

    changed_paths = build_finalize._changed_paths_between(builder_wt, str(approval_doc.get("baseline_sha") or ""), candidate)
    stats = receipts.compute_diff_stats(builder_wt, str(approval_doc.get("baseline_sha") or ""), candidate)
    scope_findings: list[dict[str, Any]] = []
    protected_paths: list[str] = []
    sensitive_paths: list[str] = []
    secret_findings: list[dict[str, Any]] = []
    for changed in changed_paths:
        path_class = build_finalize._classify_path_against_packet(meta, changed)
        if path_class == "out_of_scope":
            scope_findings.append({"path": changed, "kind": "out_of_scope"})
        elif path_class == "protected":
            protected_paths.append(changed)
        elif path_class == "sensitive":
            sensitive_paths.append(changed)
        target = builder_wt / changed
        if target.exists():
            for hit in secrets_v2.scan_path_for_secrets_strict(target):
                severity = secrets_v2.normalize_public_artifact_severity(hit["severity"])
                secret_findings.append({
                    "path": changed,
                    "pattern_id": hit["pattern_id"],
                    "severity": severity,
                    "sha256": hit["sha256"],
                    "redacted_prefix": hit["redacted_prefix"],
                    "line": hit.get("line"),
                    "count": hit["count"],
                })
    if scope_findings or protected_paths or secrets_v2.has_hard_secret(secret_findings):
        raise ProgramRolloverRefused("candidate-origin static scope/protected/hard-secret proof failed")
    current_cp_state = next(
        (cp for cp in (program_state.get("checkpoints") or [])
         if cp.get("id") == rollover.get("checkpoint_id")),
        None,
    )
    current_cp_meta = next(
        (cp for cp in (meta.get("checkpoint_graph") or {}).get("checkpoints", [])
         if cp.get("id") == rollover.get("checkpoint_id")),
        None,
    )
    if (
        not isinstance(current_cp_state, dict)
        or not isinstance(current_cp_meta, dict)
        or int((current_cp_meta.get("risk_budget") or {}).get("max_build_passes") or 0)
            != int(current_cp_state.get("build_pass_count") or 0)
    ):
        raise ProgramRolloverRefused("current checkpoint BUILD count changed during candidate-origin validation")

    cumulative = (program_state.get("cumulative_counters") or {})
    ceilings = (program_state.get("cumulative_ceilings") or {})
    top_budget = meta.get("risk_budget") or {}
    source_ceiling = {
        "result": "pass",
        "accounting": "absolute_baseline_to_candidate",
        "files_changed_unique": int(stats["files_changed"]),
        "diff_lines_total": int(stats["added_lines"] + stats["removed_lines"]),
        "max_unique_changed_files": int(ceilings.get("max_unique_changed_files") or 0),
        "max_baseline_to_final_diff_lines": int(ceilings.get("max_baseline_to_final_diff_lines") or 0),
        "top_level_risk_max_files_changed": int(top_budget.get("max_files_changed") or 0),
        "top_level_risk_max_diff_lines": int(top_budget.get("max_diff_lines") or 0),
        "program_max_unique_changed_files": int(ceilings.get("max_unique_changed_files") or 0),
        "program_max_baseline_to_final_diff_lines": int(ceilings.get("max_baseline_to_final_diff_lines") or 0),
        "effective_max_files_changed": build_finalize._strict_ceiling(
            int(top_budget.get("max_files_changed") or 0),
            int(ceilings.get("max_unique_changed_files") or 0),
        ),
        "effective_max_diff_lines": build_finalize._strict_ceiling(
            int(top_budget.get("max_diff_lines") or 0),
            int(ceilings.get("max_baseline_to_final_diff_lines") or 0),
        ),
    }
    if (
        source_ceiling["effective_max_files_changed"]
        and source_ceiling["files_changed_unique"] > source_ceiling["effective_max_files_changed"]
    ) or (
        source_ceiling["effective_max_diff_lines"]
        and source_ceiling["diff_lines_total"] > source_ceiling["effective_max_diff_lines"]
    ):
        raise ProgramRolloverRefused("candidate-origin source ceiling proof failed")
    if (
        int(cumulative.get("files_changed_unique") or 0) != source_ceiling["files_changed_unique"]
        or int(cumulative.get("diff_lines_total") or 0) != source_ceiling["diff_lines_total"]
    ):
        raise ProgramRolloverRefused("parent cumulative source accounting is not absolute candidate accounting")

    origin_record = {
        "schema": ORIGIN_SCHEMA,
        "rollover_authority_sha256": authority_sha,
        "parent_run_id": authority_doc["parent_run_id"],
        "child_run_id": run_id,
        "parent_packet_sha256": authority_doc["source"]["packet_sha256"],
        "parent_approval_sha256": authority_doc["source"]["approval_sha256"],
        "parent_state_sha256": authority_doc["source"]["state_sha256"],
        "parent_event_chain_sha256": authority_doc["source"]["event_chain_sha256"],
        "parent_build_receipt_sha256": authority_doc["source"]["build_receipt_sha256"],
        "parent_review_verdict_sha256": authority_doc["source"]["review_verdict_sha256"],
        "parent_review_assessment_sha256": authority_doc["source"]["review_assessment_sha256"],
        "parent_review_attempt_id": authority_doc["source"]["review_attempt_id"],
        "parent_candidate_sha": candidate,
        "candidate_sha": candidate,
        "parent_candidate_branch": authority_doc["source"]["parent_candidate_branch"],
        "child_packet_sha256": packet_sha,
        "child_approval_sha256": approval_sha,
        "child_baseline_sha": str(approval_doc.get("baseline_sha") or ""),
        "child_candidate_branch": expected_branch,
        "preflight_sha256": util.sha256_file(preflight_path),
    }
    receipt = receipts.new_receipt(
        run_id=run_id,
        packet_sha256=packet_sha,
        approval_sha256=approval_sha,
        work_unit_id=program.current_checkpoint_work_unit_id(meta, program_state),
        baseline_sha=str(approval_doc.get("baseline_sha") or ""),
        candidate_sha=candidate,
        candidate_branch=expected_branch,
        builder_worktree=str(builder_wt),
        builder_pass_number=int(child.get("build_pass_count") or 0),
        repair_round=int(child.get("repair_round") or 0),
        files_changed=int(stats["files_changed"]),
        added_lines=int(stats["added_lines"]),
        removed_lines=int(stats["removed_lines"]),
        changed_paths=sorted(changed_paths),
        validation=list(validations),
        protected_path_check={"result": "pass", "offending_paths": []},
        secret_scan_check={"result": "pass", "findings": secret_findings[:20]},
        scope_check={"result": "pass", "findings": []},
        sensitive_path_assessment={"result": "elevated" if sensitive_paths else "none", "paths": sensitive_paths},
        additional_review_required=bool(meta.get("additional_review_required")) or bool(sensitive_paths),
        builder_agent="ofloop-program-rollover",
        next_state="READY_FOR_REVIEW",
        agent_summary="No semantic BUILD was launched. The exact inherited candidate passed fresh deterministic validation and core scope/identity checks.",
        notes="Candidate-origin rollover receipt; parent BUILD and semantic attempt history remain immutable.",
        validation_status="PASS",
        candidate_origin=origin_record,
    )
    receipt["candidate_identity_reproof"] = {
        "result": "pass",
        "head_before_validation": candidate,
        "head_after_validation": candidate,
        "worktree_status_after_validation": "clean",
        "canonical_branch_ok_after_validation": True,
        "canonical_branch_detail_after_validation": "baseline branch remains at the sealed SHA",
    }
    receipt["program_source_ceiling_check"] = {
        **source_ceiling,
        "breach": "",
    }
    receipts.validate_receipt_contract(receipt)
    receipt_path = receipts.receipt_path(repo, run_id)
    if receipt_path.exists():
        existing_receipt = receipts.load_receipt(repo, run_id)
        if not isinstance(existing_receipt, dict) or existing_receipt.get("candidate_origin") != origin_record:
            raise ProgramRolloverRefused("existing child BUILD_RECEIPT conflicts with candidate-origin authority")
    else:
        receipts.write_receipt(repo, run_id, receipt)
    receipt_sha = util.sha256_file(receipt_path)
    preflight_sha = util.sha256_file(preflight_path)
    rollover["preflight_sha256"] = preflight_sha
    admitted = state.transition_program_rollover_to_review(
        repo,
        run_id,
        candidate_sha=candidate,
        rollover_authority_sha256=authority_sha,
        preflight_sha256=preflight_sha,
        receipt_sha256=receipt_sha,
    )
    origin = verify_candidate_origin(
        repo,
        run_id,
        expected_review_pass=int(rollover.get("initial_review_pass_number") or 0),
    )
    if not origin:
        raise ProgramRolloverRefused("typed review admission did not leave a verifiable candidate origin")
    state.append_event(
        repo,
        run_id,
        event_type="program_rollover_candidate_origin_proven",
        old_state="READY_FOR_REVIEW",
        new_state="READY_FOR_REVIEW",
        actor="ofloop-program-rollover",
        commit_sha=candidate,
        reason="candidate origin and fresh deterministic preflight verified before ordinary review dispatch",
        extras={
            "parent_run_id": authority_doc["parent_run_id"],
            "rollover_authority_sha256": authority_sha,
            "preflight_sha256": preflight_sha,
            "rollover_receipt_sha256": receipt_sha,
            "build_pass_count": int(admitted.get("build_pass_count") or 0),
            "review_pass_count": int(admitted.get("review_pass_count") or 0),
            "repair_round": int(admitted.get("repair_round") or 0),
        },
    )
    return {
        "ok": True,
        "run_id": run_id,
        "parent_run_id": authority_doc["parent_run_id"],
        "state": "READY_FOR_REVIEW",
        "candidate_sha": candidate,
        "packet_sha256": packet_sha,
        "approval_sha256": approval_sha,
        "rollover_authority_sha256": authority_sha,
        "preflight_sha256": preflight_sha,
        "build_receipt_sha256": receipt_sha,
        "build_pass_count": admitted.get("build_pass_count"),
        "review_pass_count": admitted.get("review_pass_count"),
        "repair_round": admitted.get("repair_round"),
        "candidate_origin": origin,
    }


def enqueue_envelope_for_child(
    canonical_repo: Path,
    run_id: str,
    *,
    runner: str,
    requested: dict[str, Any] | None = None,
) -> dict[str, Any] | None:
    """Constrain a rollover child enqueue to the parent's remaining ceilings.

    Returns None for ordinary runs. A rollover child is refused unless its
    parent snapshot and authority remain intact. Callers must pass these
    ceilings to the ordinary supervisor enqueue owner.
    """
    repo = Path(canonical_repo).resolve(strict=False)
    root = state.run_dir(repo, run_id)
    if not (root / "ROLLOVER_AUTHORITY.json").exists():
        return None
    authority_doc, authority_sha = _child_authority(repo, run_id)
    if runner != authority_doc.get("runner"):
        raise ProgramRolloverRefused("rollover child runner differs from the frozen parent runner")
    child = state.load_verified(repo, run_id)
    rollover = ((child.get("program") or {}).get("rollover_provenance") or {})
    if (
        rollover.get("schema") != "ownframework-loop-program-rollover/v1"
        or rollover.get("rollover_authority_sha256") != authority_sha
        or child.get("state") != "READY_FOR_REVIEW"
    ):
        raise ProgramRolloverRefused("rollover child may be enqueued only after typed review admission")
    origin = verify_candidate_origin(
        repo,
        run_id,
        expected_review_pass=int(rollover.get("initial_review_pass_number") or 0),
    )
    if not origin:
        raise ProgramRolloverRefused("rollover child candidate origin is not valid for enqueue")
    envelope = authority_doc.get("operational_envelope_remaining")
    if not isinstance(envelope, dict):
        raise ProgramRolloverRefused("rollover child has no inherited operational envelope")
    execution_started_at, parent_deadline = _validate_frozen_wall_clock_authority(
        authority_doc, envelope, now=_wall_clock_now(),
    )
    for key, requested_value in (requested or {}).items():
        if requested_value is not None and requested_value != envelope.get(key):
            raise ProgramRolloverRefused(f"enqueue request would alter inherited ceiling {key}")
    result = dict(envelope)
    result["execution_started_at"] = execution_started_at
    result["parent_deadline_unix"] = parent_deadline
    return result
