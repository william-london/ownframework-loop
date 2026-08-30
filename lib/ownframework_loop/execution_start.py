"""OwnFramework Loop execution-start authority.

This module is the single deterministic owner for turning a valid, unstarted
run into an executable run. Normal operation has no separate approval
ceremony: the first legitimate execution start creates an immutable execution
seal that binds the exact packet and source baseline.

The same core path is used by native build claims and the headless
orchestrator. The historical ``APPROVAL.json`` filename and
``tty_confirmation`` method remain compatibility surfaces only.
"""
from __future__ import annotations

import hashlib
import os
import subprocess
from pathlib import Path

from . import (
    approval as approval_mod,
    branch_resolver,
    git_checks,
    packet as packet_mod,
    state as state_mod,
    util,
)
from .locking import LockBusyError, flock_exclusive

EXECUTION_BINDING_METHODS = {"build_start", "tty_confirmation"}
EXECUTION_BINDING_KIND_DEFAULT = "execution_seal"
EXECUTION_BINDING_KIND_LEGACY = "legacy_preseal"
EXECUTION_SEAL_FILENAME = "APPROVAL.json"
START_LOCK_FILENAME = "START_LOCK"
BINDING_LOCK_FILENAME = "BINDING_LOCK"


def _start_lock_path(canonical_repo, run_id):
    return state_mod.run_dir(canonical_repo, run_id) / START_LOCK_FILENAME


def _binding_lock_path(canonical_repo, run_id):
    return state_mod.run_dir(canonical_repo, run_id) / BINDING_LOCK_FILENAME


def _seal_path(canonical_repo, run_id):
    return approval_mod.approval_path(canonical_repo, run_id)


def _current_baseline(canonical_repo, expected_branch):
    if not git_checks.is_git_repo(canonical_repo):
        return None
    if git_checks.current_branch(canonical_repo) != expected_branch:
        return None
    return git_checks.current_head(canonical_repo)


def _is_tracked_or_staged_dirty(canonical_repo):
    if not git_checks.is_git_repo(canonical_repo):
        return False
    p = subprocess.run(
        [
            "git",
            "-C",
            str(canonical_repo),
            "status",
            "--porcelain",
            "--untracked-files=no",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if p.returncode != 0:
        raise RuntimeError(
            f"could not inspect canonical source cleanliness: git status rc={p.returncode}"
        )
    return p.stdout.strip() != ""


def _current_packet_sha(packet_path):
    return hashlib.sha256(packet_path.read_bytes()).hexdigest()


def _compute_candidate_branch(packet, run_id):
    prefix = (packet.get("target") or {}).get("candidate_branch_prefix")
    if isinstance(prefix, str) and prefix.strip():
        branch = prefix.strip()
        if not git_checks.is_valid_branch_name(branch):
            raise RuntimeError(f"invalid candidate branch: {branch!r}")
        return branch
    return branch_resolver.default_candidate_branch(run_id)


def _build_seal(
    *,
    canonical_repo,
    run_id,
    packet,
    packet_path,
    baseline_sha,
    binding_method,
    binding_kind,
    actor=None,
    operator_note=None,
    preregistered_baseline_sha=None,
    preregistered_baseline_branch=None,
):
    packet_sha = _current_packet_sha(packet_path)
    target_branch = (
        preregistered_baseline_branch
        or (packet.get("target") or {}).get("branch")
        or ""
    )
    candidate_branch = _compute_candidate_branch(packet, run_id)
    canonical_repo_str = str(canonical_repo.resolve(strict=False))
    token = approval_mod.derive_confirmation_token(packet_sha)
    return {
        "schema": approval_mod.SCHEMA_VERSION,
        "run_id": run_id,
        "packet_sha256": packet_sha,
        "approved_at": util.utc_now_iso(),
        "approved_actor": actor or "operator",
        "canonical_repo": canonical_repo_str,
        "baseline_branch": target_branch,
        "baseline_sha": baseline_sha,
        "packet_schema": packet.get("schema") or "",
        "approval_method": binding_method,
        "binding_kind": binding_kind,
        "confirmation_token": token,
        "operator_note": operator_note,
        "packet_work_class": packet.get("work_class"),
        "packet_risk_class": packet.get("risk_class"),
        "packet_title": packet.get("title"),
        "sensitive_paths_in_scope": list(packet.get("sensitive_paths") or []),
        "elevated_paths_in_scope": list(packet.get("elevated_allowed_paths") or []),
        "candidate_branch": candidate_branch,
        "spec_baseline_branch": preregistered_baseline_branch or target_branch,
        "spec_baseline_sha": preregistered_baseline_sha or baseline_sha,
        "spec_snapshot_at": util.utc_now_iso(),
    }


def _validate_seal_shape(seal):
    errors = approval_mod.validate_approval_shape(seal)
    if not errors and seal.get("approval_method") not in EXECUTION_BINDING_METHODS:
        errors.append(
            f"approval_method={seal.get('approval_method')!r} not in supported "
            "execution binding methods"
        )
    return errors


def _validate_seal_against_current(
    *, canonical_repo, run_id, seal, packet, packet_path
):
    expected_packet_sha = _current_packet_sha(packet_path)
    if seal["packet_sha256"] != expected_packet_sha:
        return False, (
            f"packet SHA drifted: seal={seal['packet_sha256'][:12]} "
            f"current={expected_packet_sha[:12]}"
        )

    expected_repo = str(canonical_repo.resolve(strict=False))
    packet_repo = str(((packet.get("target") or {}).get("repo") or "")).strip()
    if (
        not packet_repo
        or Path(packet_repo).expanduser().resolve(strict=False)
        != Path(expected_repo).resolve(strict=False)
    ):
        return False, "packet target.repo does not match canonical repo"
    sealed_repo = seal.get("canonical_repo", "")
    if Path(sealed_repo).resolve(strict=False) != Path(expected_repo).resolve(
        strict=False
    ):
        return False, "seal canonical_repo mismatch"

    expected_branch = (packet.get("target") or {}).get("branch") or ""
    if seal.get("baseline_branch") != expected_branch:
        return False, (
            f"seal baseline_branch={seal.get('baseline_branch')!r} != "
            f"packet target.branch={expected_branch!r}"
        )

    current_head = _current_baseline(canonical_repo, expected_branch)
    if current_head is None:
        return False, "canonical source branch missing or HEAD not resolvable"
    if current_head != seal.get("baseline_sha"):
        return False, (
            f"canonical HEAD {current_head[:12]} does not match seal baseline_sha "
            f"{str(seal.get('baseline_sha', ''))[:12]}"
        )

    try:
        expected_candidate_branch = _compute_candidate_branch(packet, run_id)
    except Exception as exc:
        return False, f"candidate branch could not be derived: {exc}"
    if seal.get("candidate_branch") != expected_candidate_branch:
        return False, (
            f"seal candidate_branch={seal.get('candidate_branch')!r} != "
            f"packet/run-derived candidate_branch={expected_candidate_branch!r}"
        )

    spec_sha = seal.get("spec_baseline_sha")
    if spec_sha and spec_sha != current_head:
        return False, (
            f"canonical source moved between spec and start: "
            f"spec_snapshot={spec_sha[:12]} current={current_head[:12]}"
        )

    if _is_tracked_or_staged_dirty(canonical_repo):
        return False, "canonical source has tracked or staged changes"
    return True, "ok"


def _ensure_program_for_sealed(canonical_repo, run_id, packet, seal):
    if not packet_mod.packet_is_program(packet):
        return None
    from . import cli as cli_mod

    info = cli_mod._ensure_program_initialized(canonical_repo, run_id, packet, seal)
    return info.get("program")


def _activate_sealed_run(canonical_repo, run_id, actor, reason):
    """Activate a sealed pre-start run exactly once and prove the result.

    The caller holds START_LOCK + BINDING_LOCK. Transition failures are never
    swallowed. Durable seal/PROGRAM evidence may remain after a crash/fault; a
    later call validates and reuses those artifacts, then retries activation.
    """
    cur = state_mod.load_verified(canonical_repo, run_id)
    if cur is None:
        raise RuntimeError(f"STATE.json missing for run {run_id}")

    current_state = cur.get("state")
    if current_state in ("AWAITING_APPROVAL", "READY_TO_START"):
        state_mod.transition(
            canonical_repo,
            run_id,
            to_state="READY_TO_BUILD",
            actor=actor,
            reason=reason,
        )

    cur = state_mod.load_verified(canonical_repo, run_id)
    final_state = (cur or {}).get("state") or ""
    executable_or_later = {
        "READY_TO_BUILD",
        "BUILDING",
        "READY_FOR_REVIEW",
        "REVIEWING",
        "CHANGES_REQUESTED",
        "APPROVED",
        "BLOCKED",
        "STOPPED",
    }
    if final_state not in executable_or_later:
        raise RuntimeError(
            f"execution-start activation produced unexpected state={final_state!r}"
        )
    return cur


def ensure_executable(
    *, canonical_repo, run_id, actor=None, binding_method="build_start"
):
    """Ensure the run is sealed, valid, and executable or legitimately later."""
    if binding_method not in EXECUTION_BINDING_METHODS:
        raise RuntimeError(
            f"unsupported binding_method={binding_method!r}; must be one of "
            f"{sorted(EXECUTION_BINDING_METHODS)}"
        )

    packet_path = state_mod.run_dir(canonical_repo, run_id) / "WORK_PACKET.md"
    if not packet_path.exists():
        raise RuntimeError("WORK_PACKET.md missing")

    packet, _ = packet_mod.parse_packet_file(packet_path)
    errors = packet_mod.validate_packet_for_approval(packet)
    if errors:
        raise RuntimeError("packet invalid: " + "; ".join(errors))
    if not git_checks.is_git_repo(canonical_repo):
        raise RuntimeError("canonical repo is not a git repository")
    packet_repo = str(((packet.get("target") or {}).get("repo") or "")).strip()
    if (
        not packet_repo
        or Path(packet_repo).expanduser().resolve(strict=False)
        != Path(canonical_repo).resolve(strict=False)
    ):
        raise RuntimeError("packet target.repo does not match canonical repository")

    target_branch = (packet.get("target") or {}).get("branch") or ""
    if not target_branch:
        raise RuntimeError("packet target.branch missing")
    actual_branch = git_checks.current_branch(canonical_repo)
    if actual_branch != target_branch:
        raise RuntimeError(
            f"canonical repo is on branch {actual_branch!r}, packet expects "
            f"{target_branch!r}"
        )

    seal_path = _seal_path(canonical_repo, run_id)
    start_lock = _start_lock_path(canonical_repo, run_id)
    binding_lock = _binding_lock_path(canonical_repo, run_id)

    try:
        with flock_exclusive(start_lock, blocking=True, timeout_seconds=30):
            with flock_exclusive(binding_lock, blocking=True, timeout_seconds=30):
                existing = approval_mod.load_approval(canonical_repo, run_id)
                if seal_path.exists() and existing is None:
                    raise RuntimeError(
                        "existing execution seal is unreadable or malformed; "
                        "refusing overwrite"
                    )

                if existing is not None:
                    seal_errors = _validate_seal_shape(existing)
                    if seal_errors:
                        raise RuntimeError(
                            "existing execution seal malformed: "
                            + "; ".join(seal_errors)
                        )
                    ok, msg = _validate_seal_against_current(
                        canonical_repo=canonical_repo,
                        run_id=run_id,
                        seal=existing,
                        packet=packet,
                        packet_path=packet_path,
                    )
                    if not ok:
                        raise RuntimeError(f"existing execution seal invalid: {msg}")

                    cur = state_mod.load_verified(canonical_repo, run_id)
                    if cur is None:
                        raise RuntimeError(f"STATE.json missing for run {run_id}")
                    if cur.get("state") in ("AWAITING_APPROVAL", "READY_TO_START"):
                        _ensure_program_for_sealed(
                            canonical_repo, run_id, packet, existing
                        )
                        _activate_sealed_run(
                            canonical_repo,
                            run_id,
                            actor or "operator",
                            "resume sealed execution start",
                        )
                    return existing

                baseline_sha = git_checks.current_head(canonical_repo)
                if not baseline_sha:
                    raise RuntimeError("canonical repo has no HEAD")
                if _is_tracked_or_staged_dirty(canonical_repo):
                    raise RuntimeError(
                        "canonical source has tracked or staged changes; refusing "
                        "to seal execution start against dirty source"
                    )

                prior_state = state_mod.load_verified(canonical_repo, run_id)
                if prior_state is None:
                    raise RuntimeError(f"STATE.json missing for run {run_id}")
                prior_baseline_sha = prior_state.get("spec_baseline_sha") or ""
                prior_baseline_branch = prior_state.get("spec_baseline_branch") or ""

                if not prior_baseline_sha and not prior_baseline_branch:
                    if not os.environ.get("OFLOOP_LEGACY_ALLOW_UNSAFE_SNAPSHOT"):
                        raise RuntimeError(
                            "legacy run has no spec-time snapshot; refusing to "
                            "seal against arbitrary current HEAD. Create a fresh "
                            "run. OFLOOP_LEGACY_ALLOW_UNSAFE_SNAPSHOT=1 is an "
                            "explicit compatibility escape for independently "
                            "verified historical runs only."
                        )
                if prior_baseline_sha and prior_baseline_sha != baseline_sha:
                    raise RuntimeError(
                        "spec-time source moved between spec and start: "
                        f"spec_baseline_sha={prior_baseline_sha[:12]} "
                        f"current={baseline_sha[:12]}"
                    )
                if prior_baseline_branch and prior_baseline_branch != target_branch:
                    raise RuntimeError(
                        "spec-time source branch moved between spec and start: "
                        f"spec_baseline_branch={prior_baseline_branch!r} "
                        f"current={target_branch!r}"
                    )

                seal = _build_seal(
                    canonical_repo=canonical_repo,
                    run_id=run_id,
                    packet=packet,
                    packet_path=packet_path,
                    baseline_sha=baseline_sha,
                    binding_method=binding_method,
                    binding_kind=(
                        EXECUTION_BINDING_KIND_LEGACY
                        if binding_method == "tty_confirmation"
                        else EXECUTION_BINDING_KIND_DEFAULT
                    ),
                    actor=actor,
                    preregistered_baseline_sha=prior_baseline_sha or None,
                    preregistered_baseline_branch=prior_baseline_branch or None,
                )
                util.atomic_write_json(seal_path, seal, mode=0o600)
                _ensure_program_for_sealed(canonical_repo, run_id, packet, seal)
                _activate_sealed_run(
                    canonical_repo,
                    run_id,
                    actor or "operator",
                    "auto-sealed at first execution start",
                )
                return seal
    except LockBusyError as e:
        raise RuntimeError(f"could not acquire execution-start lock: {e}") from e


def is_sealed(canonical_repo, run_id):
    return _seal_path(canonical_repo, run_id).exists()


def seal_summary(seal):
    return {
        "binding_method": seal.get("approval_method"),
        "binding_kind": seal.get("binding_kind"),
        "packet_sha256": seal.get("packet_sha256"),
        "baseline_sha": seal.get("baseline_sha"),
        "candidate_branch": seal.get("candidate_branch"),
        "sealed_at": seal.get("approved_at"),
        "sealed_actor": seal.get("approved_actor"),
    }
