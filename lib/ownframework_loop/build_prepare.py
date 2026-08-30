"""Deterministic build preparation — owns branch + baseline + worktree.

v0.4.3 hardening: the v0.4.2 incident demonstrated that letting the
parent build skill issue raw `git worktree add -b <branch> <path> <sha>`
reconstructs three protocol values in the model's head:

  - candidate branch (packet-declared prefix vs default factory/candidate/<run-id>)
  - worktree path (.worktrees/ownframework-loop/<run-id>/builder)
  - baseline SHA (from APPROVAL.json)

That reconstruction is exactly the kind of model-owned deterministic
plumbing we want out of the model's discretion. This module:

  1. Reads APPROVAL.json for the frozen baseline SHA and frozen
     candidate_branch (single source of truth, v0.4.3).
  2. Falls back through branch_resolver if APPROVAL.json is missing
     candidate_branch (legacy run recovery path).
  3. Creates or reuses the builder worktree deterministically (delegates
     to worktrees.add_builder_worktree for the flocked add path).
  4. Returns a single machine-readable context dict the parent skill
     and the fresh `of-builder` agent consume.
  5. Refuses with PrepareRefused if the canonical repo's HEAD has
     drifted off the approved baseline_sha, or if the packet does not
     validate, or if no approval exists.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from . import (
    approval as approval_mod,
    branch_resolver,
    git_checks,
    packet as packet_mod,
    program as program_mod,
    state as state_mod,
    util,
    worktrees as worktrees_mod,
    build_agent as build_agent_mod,
)


class PrepareRefused(RuntimeError):
    """Raised on deterministic build preparation refusals."""


def _resolve_run_id(canonical_repo: Path, run_id: str | None) -> str:
    if run_id:
        return run_id
    rd = Path(canonical_repo) / ".ownframework-loop"
    runs = sorted(p.name for p in rd.iterdir() if p.is_dir() and p.name.startswith("run-"))
    if not runs:
        raise PrepareRefused(
            f"no run-* directories under {canonical_repo}/.ownframework-loop"
        )
    if len(runs) > 1:
        raise PrepareRefused(
            f"multiple active runs in {canonical_repo}/.ownframework-loop; "
            f"pass --run-id explicitly: {', '.join(runs)}"
        )
    return runs[0]


def _resolve_current_checkpoint(canonical_repo: Path, run_id: str) -> str:
    """Resolve the current CP id from the program state, or None for single mode."""
    state = state_mod.load_verified(canonical_repo, run_id)
    if not state_mod.is_program_state(state):
        return ""
    program = state.get("program") or {}
    cps = program.get("current_checkpoints") or []
    return cps[0] if cps else ""


def _resolve_current_work_unit(canonical_repo: Path, run_id: str) -> str:
    """Resolve the current work_unit_id from the packet + state."""
    packet_p = state_mod.run_dir(canonical_repo, run_id) / "WORK_PACKET.md"
    if not packet_p.exists():
        raise PrepareRefused(f"WORK_PACKET.md missing for run {run_id}")
    meta, _ = packet_mod.parse_packet_file(packet_p)
    work_units = meta.get("work_units") or []
    if not work_units:
        return ""
    state = state_mod.load_verified(canonical_repo, run_id)
    if state_mod.is_program_state(state):
        cp_id = _resolve_current_checkpoint(canonical_repo, run_id)
        cps = (meta.get("checkpoint_graph") or {}).get("checkpoints") or []
        for cp in cps:
            if cp.get("id") == cp_id:
                cp_wus = cp.get("work_units") or []
                if cp_wus:
                    return cp_wus[0]
    return work_units[0].get("id") or ""


def prepare(
    *,
    canonical_repo: Path,
    run_id: str | None,
    repair_round: int = 0,
) -> dict[str, Any]:
    """Deterministic build preparation. Returns a context dict.

    Refuses (PrepareRefused) on any of:
      - canonical repo is not a git repo
      - WORK_PACKET.md missing or invalid
      - APPROVAL.json missing or invalid
      - canonical HEAD drifted off approved baseline_sha
      - branch resolution ambiguous
    """
    canonical_repo = Path(canonical_repo).resolve(strict=False)
    if not git_checks.is_git_repo(canonical_repo):
        raise PrepareRefused(f"canonical repo is not a git repository: {canonical_repo}")
    run_id = _resolve_run_id(canonical_repo, run_id)

    # Validate packet and approval.
    packet_p = state_mod.run_dir(canonical_repo, run_id) / "WORK_PACKET.md"
    if not packet_p.exists():
        raise PrepareRefused(f"WORK_PACKET.md missing for run {run_id}")
    meta, _ = packet_mod.parse_packet_file(packet_p)
    errs = packet_mod.validate_packet_for_approval(meta)
    if errs:
        raise PrepareRefused("packet invalid: " + "; ".join(errs))

    approval_doc = approval_mod.load_approval(canonical_repo, run_id)
    if not approval_doc:
        raise PrepareRefused(f"APPROVAL.json missing for run {run_id}")
    approval_sha = approval_mod.approval_artifact_sha256(approval_doc)
    packet_sha = approval_doc.get("packet_sha256") or ""
    baseline_sha = approval_doc.get("baseline_sha") or ""
    baseline_branch = approval_doc.get("baseline_branch") or ""
    if not baseline_sha:
        raise PrepareRefused("APPROVAL.json missing baseline_sha")

    # Defect 7 (v0.4.4): independently re-verify approval binding BEFORE
    # any protocol mutation. Each deterministic boundary must fail
    # closed itself — never rely on the parent model having called
    # another validator first.
    current_packet_sha = util.sha256_text(packet_p.read_text(encoding="utf-8"))
    if current_packet_sha != packet_sha:
        raise PrepareRefused(
            f"approval-binding drift: APPROVAL.json packet_sha256={packet_sha[:12]} "
            f"no longer matches current WORK_PACKET bytes sha={current_packet_sha[:12]}"
        )
    bind_ok, bind_msg = approval_mod.validate_approval_binding(
        canonical_repo=canonical_repo,
        run_id=run_id,
        approval=approval_doc,
        packet=meta,
        packet_path=packet_p,
    )
    if not bind_ok:
        raise PrepareRefused(f"approval-binding invalid: {bind_msg}")

    # Canonical HEAD drift guard.
    cur_head = git_checks.current_head(canonical_repo)
    if not cur_head:
        raise PrepareRefused("canonical repo has no HEAD")
    if cur_head != baseline_sha:
        raise PrepareRefused(
            f"canonical HEAD {cur_head} drifted from approved "
            f"baseline {baseline_sha}"
        )

    # Resolve candidate branch from packet > approval > state > default.
    candidate_branch = branch_resolver.resolve_candidate_branch(
        canonical_repo, run_id, packet=meta,
    )
    if not candidate_branch or not isinstance(candidate_branch, str):
        raise PrepareRefused("could not resolve candidate_branch")

    # Current checkpoint / work-unit / acceptance identity.
    state_doc = state_mod.load_verified(canonical_repo, run_id)
    cp_id = _resolve_current_checkpoint(canonical_repo, run_id)
    work_unit_id = _resolve_current_work_unit(canonical_repo, run_id)
    if state_mod.is_program_state(state_doc):
        acceptance_criterion_ids = (
            program_mod.current_checkpoint_acceptance_criterion_ids(
                meta, (state_doc or {}).get("program") or {}
            )
        )
    else:
        acceptance_criterion_ids = program_mod.packet_acceptance_criterion_ids(meta)

    # Builder worktree: create or reuse, deterministic.
    wt = worktrees_mod.add_builder_worktree(
        canonical_repo=canonical_repo,
        run_id=run_id,
        branch=candidate_branch,
        base_sha=baseline_sha,
    )
    wt_path = Path(wt["path"]).resolve(strict=False)

    # Worktree path the contract expects (exposed for documentation +
    # the hook's `is_builder_wt` test which is path-based).
    expected_wt_path = util.builder_worktree(canonical_repo, run_id)
    if str(expected_wt_path.resolve(strict=False)) != str(wt_path):
        # Should not happen — worktrees_mod resolves the same way.
        raise PrepareRefused(
            f"worktree path mismatch: expected {expected_wt_path}, got {wt_path}"
        )

    # Defect 5B (v0.4.4): the returned actual_branch must equal the
    # frozen candidate branch. We surface actual_branch so the parent
    # skill and reviewer path can independently verify.
    actual_branch = wt.get("actual_branch") or ""
    if actual_branch != candidate_branch:
        raise PrepareRefused(
            f"worktree actual branch {actual_branch!r} != frozen candidate "
            f"branch {candidate_branch!r}"
        )

    ctx: dict[str, Any] = {
        "canonical_repo": str(canonical_repo),
        "run_id": run_id,
        "schema": "ownframework-loop-build-prepare/v1",
        "execution_mode": "program" if state_mod.is_program_state(
            state_mod.load_verified(canonical_repo, run_id)
        ) else "single",
        "cp_id": cp_id,
        "work_unit_id": work_unit_id,
        "acceptance_criterion_ids": acceptance_criterion_ids,
        "repair_round": int(repair_round or 0),
        "baseline_sha": baseline_sha,
        "baseline_branch": baseline_branch,
        "candidate_branch": candidate_branch,
        "packet_sha256": packet_sha,
        "approval_sha256": approval_sha,
        "builder_worktree": str(wt_path),
        "builder_worktree_existed": bool(wt.get("existed")),
        "builder_head": wt.get("head"),
        "builder_actual_branch": wt.get("actual_branch", candidate_branch),
        "candidate_branch": candidate_branch,
        "agent_result_path": str(build_agent_mod.agent_result_path(canonical_repo, run_id)),
        "agent_result_exists": build_agent_mod.agent_result_path(canonical_repo, run_id).exists(),
        "prepared_at": util.utc_now_iso(),
        "preparation_owner": "ofloop build prepare",
    }
    return ctx
