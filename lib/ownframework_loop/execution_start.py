"""v0.5.0 — single deterministic execution-start owner.

Owns the transition from a fresh unstarted run to an executable run.

Replaces the v0.4.6 mandatory human-TTY approval ceremony with an
automatic, immutable execution seal created at the first legitimate
execution start. The first build pass by the operator IS the
authorization to execute the exact bounded packet locally.

Two surfaces converge on this module:

  - `ofloop build claim`      (single + program mode)
  - `ofloop loop run`         (headless orchestrator)

Both call ensure_executable() and observe the same semantics.

The optional legacy TTY pre-seal path remains for backward compatibility
but is no longer part of the normal operator workflow.
"""
from __future__ import annotations
import hashlib, subprocess
from pathlib import Path
from typing import Any
from . import (
    approval as approval_mod, branch_resolver, git_checks,
    packet as packet_mod, state as state_mod, util,
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
        ["git", "-C", str(canonical_repo), "status", "--porcelain",
         "--untracked-files=no"],
        capture_output=True, text=True, check=False,
    )
    return p.stdout.strip() != ""

def _current_packet_sha(packet_path):
    return hashlib.sha256(packet_path.read_bytes()).hexdigest()

def _compute_candidate_branch(packet, run_id):
    prefix = (packet.get("target") or {}).get("candidate_branch_prefix")
    if isinstance(prefix, str) and prefix.strip():
        return prefix
    return branch_resolver.default_candidate_branch(run_id)

def _build_seal(*, canonical_repo, run_id, packet, packet_path, baseline_sha,
                binding_method, binding_kind, actor=None, operator_note=None,
                preregistered_baseline_sha=None, preregistered_baseline_branch=None):
    packet_sha = _current_packet_sha(packet_path)
    target_branch = (
        preregistered_baseline_branch
        or (packet.get("target") or {}).get("branch") or ""
    )
    candidate_branch = _compute_candidate_branch(packet, run_id)
    canonical_repo_str = str(canonical_repo.resolve(strict=False))
    token = approval_mod.derive_confirmation_token(packet_sha)
    seal = {
        "schema": approval_mod.SCHEMA_VERSION,
        "run_id": run_id, "packet_sha256": packet_sha,
        "approved_at": util.utc_now_iso(),
        "approved_actor": actor or "operator",
        "canonical_repo": canonical_repo_str,
        "baseline_branch": target_branch, "baseline_sha": baseline_sha,
        "packet_schema": packet.get("schema") or "",
        "approval_method": binding_method,
        "binding_kind": binding_kind,
        "confirmation_token": token, "operator_note": operator_note,
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
    return seal

def _validate_seal_shape(seal):
    errors = approval_mod.validate_approval_shape(seal)
    if not errors:
        if seal.get("approval_method") not in EXECUTION_BINDING_METHODS:
            errors.append(f"approval_method={seal.get('approval_method')!r} not in v0.5.0 execution binding methods")
        # binding_kind is informational; legacy v0.4.x seals do not
        # have it. New v0.5.0 seals always have it.
    return errors

def _validate_seal_against_current(*, canonical_repo, run_id, seal, packet, packet_path):
    expected_packet_sha = _current_packet_sha(packet_path)
    if seal["packet_sha256"] != expected_packet_sha:
        return False, (f"packet SHA drifted: seal={seal['packet_sha256'][:12]} current={expected_packet_sha[:12]}")
    expected_repo = str(canonical_repo.resolve(strict=False))
    sealed_repo = seal.get("canonical_repo", "")
    if Path(sealed_repo).resolve(strict=False) != Path(expected_repo).resolve(strict=False):
        return False, "seal canonical_repo mismatch"
    expected_branch = (packet.get("target") or {}).get("branch") or ""
    if seal.get("baseline_branch") != expected_branch:
        return False, f"seal baseline_branch={seal.get('baseline_branch')!r} != packet target.branch={expected_branch!r}"
    current_head = _current_baseline(canonical_repo, expected_branch)
    if current_head is None:
        return False, "canonical source branch missing or HEAD not resolvable"
    if current_head != seal.get("baseline_sha"):
        return False, (f"canonical HEAD {current_head[:12]} does not match seal baseline_sha {str(seal.get('baseline_sha',''))[:12]}")
    spec_sha = seal.get("spec_baseline_sha")
    if spec_sha and spec_sha != current_head:
        return False, (f"canonical source moved between spec and start: spec_snapshot={spec_sha[:12]} current={current_head[:12]}")
    if _is_tracked_or_staged_dirty(canonical_repo):
        return False, "canonical source has tracked or staged changes"
    return True, "ok"

def _ensure_program_for_sealed(canonical_repo, run_id, packet, seal):
    if not packet_mod.packet_is_program(packet):
        return None
    from . import cli as cli_mod
    info = cli_mod._ensure_program_initialized(canonical_repo, run_id, packet, seal)
    return info.get("program")

def ensure_executable(*, canonical_repo, run_id, actor=None, binding_method="build_start"):
    """Ensure the run is sealed, valid, and in READY_TO_BUILD (or replayable)."""
    if binding_method not in EXECUTION_BINDING_METHODS:
        raise RuntimeError(f"unsupported binding_method={binding_method!r}; must be one of {sorted(EXECUTION_BINDING_METHODS)}")
    packet_path = state_mod.run_dir(canonical_repo, run_id) / "WORK_PACKET.md"
    if not packet_path.exists():
        raise RuntimeError("WORK_PACKET.md missing")
    packet, _ = packet_mod.parse_packet_file(packet_path)
    errors = packet_mod.validate_packet_for_approval(packet)
    if errors:
        raise RuntimeError("packet invalid: " + "; ".join(errors))
    if not git_checks.is_git_repo(canonical_repo):
        raise RuntimeError("canonical repo is not a git repository")
    target_branch = (packet.get("target") or {}).get("branch") or ""
    if not target_branch:
        raise RuntimeError("packet target.branch missing")
    if git_checks.current_branch(canonical_repo) != target_branch:
        raise RuntimeError(f"canonical repo is on branch {git_checks.current_branch(canonical_repo)!r}, packet expects {target_branch!r}")
    seal_path = _seal_path(canonical_repo, run_id)
    start_lock = _start_lock_path(canonical_repo, run_id)
    binding_lock = _binding_lock_path(canonical_repo, run_id)
    try:
        with flock_exclusive(start_lock, blocking=True, timeout_seconds=30):
            with flock_exclusive(binding_lock, blocking=True, timeout_seconds=30):
                existing_seal_path = approval_mod.approval_path(canonical_repo, run_id)
                existing = approval_mod.load_approval(canonical_repo, run_id)
                if existing_seal_path.exists() and existing is None:
                    raise RuntimeError(
                        "existing seal malformed: bytes are not valid JSON; refusing to overwrite"
                    )
                if existing is not None:
                    seal_errors = _validate_seal_shape(existing)
                    if seal_errors:
                        raise RuntimeError("existing seal malformed: " + "; ".join(seal_errors))
                    ok, msg = _validate_seal_against_current(
                        canonical_repo=canonical_repo, run_id=run_id,
                        seal=existing, packet=packet, packet_path=packet_path)
                    if not ok:
                        raise RuntimeError(f"existing seal invalid: {msg}")
                    # Seals are immutable: a valid existing seal (regardless of
                    # which legitimate v0.5.0 binding method won the first-write
                    # race) is accepted. The caller's binding_method only
                    # controls the WRITE path; once a seal exists it is the
                    # canonical execution binding.
                    cur = state_mod.load(canonical_repo, run_id)
                    if cur.get("state") in ("AWAITING_APPROVAL", "READY_TO_START"):
                        _ensure_program_for_sealed(canonical_repo, run_id, packet, existing)
                        try:
                            state_mod.transition(canonical_repo, run_id, to_state="READY_TO_BUILD",
                                                 actor=actor or "operator",
                                                 reason="auto-sealed at first build start")
                        except Exception:
                            pass
                    return existing
                baseline_sha = git_checks.current_head(canonical_repo)
                if not baseline_sha:
                    raise RuntimeError("canonical repo has no HEAD")
                if _is_tracked_or_staged_dirty(canonical_repo):
                    raise RuntimeError("canonical source has tracked or staged changes; refusing to seal an execution start against dirty source")
                # v0.5.1: consume STATE.spec_baseline_sha/spec_baseline_branch
                # to refuse source drift between spec-time and start-time.
                prior_state = state_mod.load(canonical_repo, run_id)
                prior_baseline_sha = (prior_state or {}).get("spec_baseline_sha") or ""
                prior_baseline_branch = (prior_state or {}).get("spec_baseline_branch") or ""
                # v0.5.1 explicit legacy-run policy: if a pre-v0.5.0 unstarted
                # run lacks a spec-time snapshot, refuse unless the
                # operator passes --legacy-allow-unsafe-snapshot-via-current-head.
                # Casual reuse is forbidden; silent substitution of
                # arbitrary current HEAD defeats the drift invariant.
                if not prior_baseline_sha and not prior_baseline_branch:
                    import os as _os
                    if not _os.environ.get("OFLOOP_LEGACY_ALLOW_UNSAFE_SNAPSHOT"):
                        raise RuntimeError(
                            "legacy-run policy: run has no spec-time snapshot; "
                            "refusing to seal against arbitrary current HEAD. "
                            "Create a fresh run, or set "
                            "OFLOOP_LEGACY_ALLOW_UNSAFE_SNAPSHOT=1 only if you "
                            "have independent proof the packet was authored "
                            "against the current canonical HEAD."
                        )
                if prior_baseline_sha and prior_baseline_sha != baseline_sha:
                    raise RuntimeError(
                        f"spec-time source moved between spec and start: spec_baseline_sha={prior_baseline_sha[:12]} current={baseline_sha[:12]}"
                    )
                if prior_baseline_branch and prior_baseline_branch != target_branch:
                    raise RuntimeError(
                        f"spec-time source branch moved between spec and start: spec_baseline_branch={prior_baseline_branch!r} current={target_branch!r}"
                    )
                seal = _build_seal(
                    canonical_repo=canonical_repo, run_id=run_id, packet=packet,
                    packet_path=packet_path, baseline_sha=baseline_sha,
                    binding_method=binding_method,
                    binding_kind=(EXECUTION_BINDING_KIND_LEGACY if binding_method == "tty_confirmation" else EXECUTION_BINDING_KIND_DEFAULT),
                    actor=actor,
                )
                util.atomic_write_json(seal_path, seal, mode=0o600)
                _ensure_program_for_sealed(canonical_repo, run_id, packet, seal)
                cur = state_mod.load(canonical_repo, run_id)
                if cur.get("state") in ("AWAITING_APPROVAL", "READY_TO_START"):
                    try:
                        state_mod.transition(canonical_repo, run_id, to_state="READY_TO_BUILD",
                                             actor=actor or "operator",
                                             reason="auto-sealed at first build start")
                    except Exception:
                        pass
                return seal
    except LockBusyError as e:
        raise RuntimeError(f"could not acquire v0.5.0 start lock: {e}") from e

def is_sealed(canonical_repo, run_id):
    return _seal_path(canonical_repo, run_id).exists()

def seal_summary(seal):
    return {
        "binding_method": seal.get("approval_method"),
        "binding_kind": seal.get("binding_kind"),
        "packet_sha256": seal.get("packet_sha256"),
        "baseline_sha": seal.get("baseline_sha"),
        "candidate_branch": seal.get("candidate_branch"),
        "approved_at": seal.get("approved_at"),
        "approved_actor": seal.get("approved_actor"),
    }
