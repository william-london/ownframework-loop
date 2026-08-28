"""Command-line interface for OwnFramework Loop.

Thin wrapper around the Python library. Used by skills, agents, hooks, tests,
and installers. Stable, JSON-friendly output.

Usage:

  ofloop spec new <repo> <mission>
  ofloop spec status <repo> <run-id>
  ofloop spec approve <repo> <run-id> [--actor <name>]
  ofloop spec amend <repo> <run-id> <requested change>
  ofloop spec stop <repo> <run-id> [--reason <reason>]
  ofloop spec abandon <repo> <run-id>

  ofloop build claim <repo> <run-id> [--actor <name>]
  ofloop build transition <repo> <run-id> --to <state> [--reason <r>] [--actor <name>] [--commit-sha <sha>]
  ofloop build write-receipt <repo> <run-id> <receipt.json>
  ofloop build marker <repo> <run-id>

  ofloop review write-verdict <repo> <run-id> <verdict.json>
  ofloop review marker <repo> <run-id>

  ofloop doctor <repo> [--run-id <id>]
  ofloop new-repo <root> <project-name> [--init-baseline]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import uuid
from pathlib import Path
from typing import Any

from . import (
    git_checks, guards,
    locking, packet as packet_mod, program as program_mod, receipts,
    scheduling, state as state_mod, transitions, util, verdicts, worktrees,
    integrity, limits as limits_mod, approval, build_finalize, review_finalize,
    branch_resolver, execution_start,
    dispatch as dispatch_mod, supervisor as supervisor_mod,
)


SCHEMA_PACKET = "ownframework-work-packet/v2"
SCHEMA_STATE = "ownframework-loop-state/v1"


# --- helpers ---------------------------------------------------------------

def _emit(payload: dict[str, Any], *, exit_code: int = 0) -> None:
    """Write a structured JSON response to stdout and exit."""
    sys.stdout.write(json.dumps(payload, indent=2, sort_keys=True, default=str))
    sys.stdout.write("\n")
    sys.stdout.flush()
    if exit_code != 0:
        sys.exit(exit_code)


def _emit_error(message: str, *, exit_code: int = 1, **extras: Any) -> None:
    payload = {"ok": False, "error": message}
    payload.update(extras)
    _emit(payload, exit_code=exit_code)


def _repo_path(arg: str) -> Path:
    p = Path(arg).expanduser().resolve(strict=False)
    if not p.exists() or not p.is_dir():
        _emit_error(f"repository path does not exist: {arg}", exit_code=2)
    return p


def _require_packet(canonical_repo: Path, run_id: str) -> dict[str, Any]:
    path = state_mod.run_dir(canonical_repo, run_id) / "WORK_PACKET.md"
    if not path.exists():
        _emit_error(f"WORK_PACKET.md missing for run {run_id}", exit_code=2)
    meta, _ = packet_mod.parse_packet_file(path)
    errors = packet_mod.validate_packet_metadata(meta)
    if errors:
        _emit_error("packet validation failed", exit_code=2, errors=errors)
    return meta


# --- spec subcommands ------------------------------------------------------

def cmd_spec_new(args: argparse.Namespace) -> None:
    repo = _repo_path(args.repo)
    # F-004 closure: deterministic CLI-side eligibility guards.
    # The spec skill remains the primary gate, but the CLI refuses
    # categorically unsupported targets without requiring --unsafe.
    unsafe = bool(getattr(args, "unsafe", False))
    if not git_checks.is_git_repo(repo):
        _emit_error(
            "not a git repository; spec new requires a Git repository. "
            "Use 'ofloop new-repo' for explicit NEW_REPOSITORY bootstrap.",
            exit_code=2,
            classification="NON_GIT_REFUSAL",
        )
    if git_checks.is_bare(repo):
        _emit_error(
            "bare repositories are not eligible targets",
            exit_code=2,
            classification="BARE_REPOSITORY_UNSUPPORTED",
        )
    cls = git_checks.dirty_classification(repo)
    if (cls["has_tracked_modified"] or cls["has_tracked_deleted"] or cls["has_staged"]) and not unsafe:
        _emit_error(
            "tracked dirty state detected; refuse, stash, reset, clean, or "
            "absorb those changes. To force-create a run in spite of dirt, "
            "use --unsafe (model layer will still refuse).",
            exit_code=2,
            classification="TRACKED_DIRTY_REFUSAL",
            dirty=cls,
        )
    # Refuse when a conflicting run branch exists with this run id pattern.
    run_id = state_mod.run_dir(repo, f"run-{util.utc_now_compact()}-{uuid.uuid4().hex[:8]}").name
    candidate_branch = f"factory/candidate/{run_id}"
    if git_checks.branch_exists(repo, candidate_branch):
        _emit_error(
            f"conflicting run branch already exists: {candidate_branch}",
            exit_code=2,
            classification="RUN_BRANCH_COLLISION",
        )
    state_mod.run_dir(repo, run_id).mkdir(parents=True, exist_ok=True)
    initial = state_mod.initial_state(run_id)
    # v0.5.0: snapshot the source identity so first build start can refuse
    # if the canonical source moved or got dirty between spec and start.
    initial["spec_baseline_branch"] = git_checks.current_branch(repo)
    initial["spec_baseline_sha"] = git_checks.current_head(repo) or ""
    initial["spec_snapshot_at"] = util.utc_now_iso()
    state_mod.save(repo, run_id, initial)
    state_mod.append_event(
        repo, run_id,
        event_type="run_created",
        old_state=None, new_state="AWAITING_APPROVAL",
        actor="spec",
        reason=args.mission[:200] if args.mission else None,
    )
    _emit({
        "ok": True,
        "run_id": run_id,
        "state": "AWAITING_APPROVAL",
        "next_step": (
            f"draft and validate packet at {state_mod.run_dir(repo, run_id) / 'WORK_PACKET.md'}, "
            f"then start with: ofloop dispatch claim {repo} {run_id} "
            f"or interactive /loop /of-loop:build {run_id}"
        ),
    })




def _ensure_program_initialized(
    repo: Path,
    run_id: str,
    meta: dict[str, Any],
    approval_doc: dict[str, Any],
) -> dict[str, Any]:
    """Materialize PROGRAM state exactly once from the approved packet.

    v0.4.5: PROGRAM materialization is deterministic setup, not a second
    authority gate. Human approval is the only operator gate. For an already
    initialized PROGRAM run this function is a strict no-op after verifying the
    frozen graph, baseline, and candidate branch. It never resets live
    checkpoint/cumulative progress.
    """
    if not packet_mod.packet_is_program(meta):
        return {"is_program": False, "initialized": False, "program": None}

    from . import branch_resolver

    baseline_sha = str(approval_doc.get("baseline_sha") or "")
    candidate_branch = str(approval_doc.get("candidate_branch") or "")
    if not baseline_sha or not candidate_branch:
        raise RuntimeError("approved PROGRAM run missing frozen baseline/candidate branch")

    expected = program_mod.materialise_initial_program_state(
        meta,
        baseline_sha=baseline_sha,
        candidate_branch=candidate_branch,
    )
    cur = state_mod.load(repo, run_id)
    if cur is None:
        raise RuntimeError(f"STATE.json missing for {run_id}")

    existing = cur.get("program")
    if isinstance(existing, dict):
        ok, reason = program_mod.verify_frozen_graph(meta, existing)
        if not ok:
            raise RuntimeError(f"refusing PROGRAM re-initialization: {reason}")
        provenance = existing.get("source_sha_provenance") or {}
        if provenance.get("baseline_sha") not in (None, "", baseline_sha):
            raise RuntimeError("refusing PROGRAM re-initialization: baseline provenance drift")
        if provenance.get("candidate_branch") not in (None, "", candidate_branch):
            raise RuntimeError("refusing PROGRAM re-initialization: candidate branch provenance drift")
        if cur.get("schema") != state_mod.PROGRAM_STATE_SCHEMA_VERSION:
            raise RuntimeError("PROGRAM block present under non-PROGRAM state schema")
        return {
            "is_program": True,
            "initialized": False,
            "program": existing,
            "candidate_branch": candidate_branch,
            "baseline_sha": baseline_sha,
        }

    new_state = dict(cur)
    new_state["program"] = expected
    new_state["schema"] = state_mod.PROGRAM_STATE_SCHEMA_VERSION
    state_mod.save(repo, run_id, new_state)
    state_mod.append_event(
        repo,
        run_id,
        event_type="program_initialized",
        old_state=cur.get("state"),
        new_state=cur.get("state"),
        actor="ofloop-core",
        reason="approved v3 PROGRAM graph materialized exactly once",
        extras={
            "checkpoint_graph_sha256": expected.get("checkpoint_graph_sha256"),
            "candidate_branch": candidate_branch,
            "baseline_sha": baseline_sha,
        },
    )
    return {
        "is_program": True,
        "initialized": True,
        "program": expected,
        "candidate_branch": candidate_branch,
        "baseline_sha": baseline_sha,
    }


def cmd_program_init(args: argparse.Namespace) -> None:
    """Back-compat PROGRAM initializer.

    v0.4.5: successful human approval auto-materializes v3 PROGRAM state.
    This command remains for diagnosis/recovery of pre-v0.4.5 approved runs.
    It is idempotent: an already initialized run is verified and returned
    unchanged; it can never reset checkpoint or cumulative progress.
    """
    repo = _repo_path(args.repo)
    run_id = args.run_id
    packet_path = state_mod.run_dir(repo, run_id) / "WORK_PACKET.md"
    if not packet_path.exists():
        _emit_error("WORK_PACKET.md missing", exit_code=2)
    meta, _ = packet_mod.parse_packet_file(packet_path)
    if not packet_mod.packet_is_program(meta):
        _emit_error("packet is not a v3 program-mode packet", exit_code=2)

    approval_doc = approval.load_approval(repo, run_id)
    ok, msg = approval.validate_approval_binding(
        canonical_repo=repo,
        run_id=run_id,
        approval=approval_doc,
        packet=meta,
        packet_path=packet_path,
    )
    if not ok:
        _emit_error(
            f"approval binding invalid: {msg}",
            exit_code=3,
            classification="APPROVAL_INVALID",
        )
    try:
        info = _ensure_program_initialized(repo, run_id, meta, approval_doc or {})
    except RuntimeError as e:
        _emit_error(
            str(e),
            exit_code=3,
            classification="PROGRAM_INIT_REFUSED",
        )
    prog = info["program"] or {}
    _emit({
        "ok": True,
        "run_id": run_id,
        "schema": state_mod.PROGRAM_STATE_SCHEMA_VERSION,
        "execution_mode": "program",
        "initialized": bool(info["initialized"]),
        "already_initialized": not bool(info["initialized"]),
        "candidate_branch": info["candidate_branch"],
        "baseline_sha": info["baseline_sha"],
        "current_checkpoints": prog.get("current_checkpoints") or [],
        "finalized_count": len(prog.get("finalized_checkpoints") or []),
        "cumulative_counters": prog.get("cumulative_counters") or {},
        "cumulative_ceilings": prog.get("cumulative_ceilings") or {},
    })

def cmd_program_status(args: argparse.Namespace) -> None:
    """Return program-state summary (or absent if not program-mode)."""
    from . import packet as packet_mod

    repo = _repo_path(args.repo)
    run_id = args.run_id
    s = state_mod.load(repo, run_id)
    if s is None:
        _emit_error(f"run not found: {run_id}", exit_code=2)
    prog = s.get("program")
    if not isinstance(prog, dict):
        _emit({
            "ok": True,
            "run_id": run_id,
            "execution_mode": "single",
            "is_program": False,
        })
        return
    is_term, term_state = program_mod.is_program_terminal(prog) if False else (
        __import__("ownframework_loop.program", fromlist=["is_program_terminal"]).is_program_terminal(prog)
    )
    _emit({
        "ok": True,
        "run_id": run_id,
        "execution_mode": "program",
        "is_program": True,
        "promotion_policy": prog.get("promotion_policy"),
        "current_checkpoints": prog.get("current_checkpoints"),
        "finalized_count": len(prog.get("finalized_checkpoints", [])),
        "is_terminal": is_term,
        "terminal_state": term_state,
        "cumulative_counters": prog.get("cumulative_counters"),
        "cumulative_ceilings": prog.get("cumulative_ceilings"),
        "baseline_sha_provenance": (
            prog.get("source_sha_provenance", {}).get("baseline_sha")
        ),
    })


def cmd_spec_status(args: argparse.Namespace) -> None:
    repo = _repo_path(args.repo)
    s = state_mod.load(repo, args.run_id)
    if s is None:
        _emit_error(f"run not found: {args.run_id}", exit_code=2)
    packet_path = state_mod.run_dir(repo, args.run_id) / "WORK_PACKET.md"
    packet = None
    if packet_path.exists():
        try:
            meta, _ = packet_mod.parse_packet_file(packet_path)
            packet = {
                "title": meta.get("title"),
                "work_class": meta.get("work_class"),
                "risk_class": meta.get("risk_class"),
                "human_approved": meta.get("human_approved", False),
                "packet_sha256": util.sha256_text(packet_path.read_text(encoding="utf-8")),
            }
        except Exception as e:
            packet = {"error": str(e)}
    receipt = receipts.load_receipt(repo, args.run_id)
    verdict = verdicts.load_verdict(repo, args.run_id)
    stop = state_mod.is_stop_requested(repo, args.run_id)
    _emit({
        "ok": True,
        "run_id": args.run_id,
        "state": s.get("state"),
        "transitions_count": s.get("transitions_count"),
        "build_pass_count": s.get("build_pass_count"),
        "review_pass_count": s.get("review_pass_count"),
        "repair_round": s.get("repair_round"),
        "no_progress_streak": s.get("no_progress_streak"),
        "last_actor": s.get("last_actor"),
        "last_candidate_sha": s.get("last_candidate_sha"),
        "stop_requested": stop,
        "packet": packet,
        "has_receipt": receipt is not None,
        "has_verdict": verdict is not None,
        "last_verdict": (verdict.get("verdict") if verdict else None),
    })


def cmd_spec_approve(args: argparse.Namespace) -> None:
    """External approval gate.

    Approval authority lives in a separate ``APPROVAL.json`` artifact.
    The packet bytes are NOT modified. The CLI prompts the operator on
    a TTY for a confirmation token derived from the packet SHA; only
    after the typed token matches does it write ``APPROVAL.json`` and
    transition to READY_TO_BUILD.

    The model cannot approve its own packet:
      - This subcommand requires a TTY. Non-interactive stdin is refused.
      - The token is a deterministic short hash of the packet SHA; the
        model has no way to type it without operator confirmation.
    """
    repo = _repo_path(args.repo)
    packet_path = state_mod.run_dir(repo, args.run_id) / "WORK_PACKET.md"
    if not packet_path.exists():
        _emit_error("WORK_PACKET.md missing", exit_code=2)
    meta, _ = packet_mod.parse_packet_file(packet_path)
    errors = packet_mod.validate_packet_for_approval(meta)
    if errors:
        _emit_error("packet invalid", exit_code=2, errors=errors)

    # v0.4.5: prove that an approved PROGRAM can be materialized BEFORE
    # asking the human to authorize it. This prevents an approval artifact
    # from being created for a graph/envelope that cannot initialize.
    if packet_mod.packet_is_program(meta):
        from . import branch_resolver
        baseline_preflight = git_checks.current_head(repo)
        candidate_preflight = (
            (meta.get("target") or {}).get("candidate_branch_prefix")
            or branch_resolver.default_candidate_branch(args.run_id)
        )
        try:
            program_mod.materialise_initial_program_state(
                meta,
                baseline_sha=baseline_preflight or "",
                candidate_branch=candidate_preflight,
            )
        except program_mod.ProgramGraphError as e:
            _emit_error(
                f"PROGRAM pre-approval materialization refused: {e}",
                exit_code=2,
                classification="PROGRAM_GRAPH_INVALID",
            )

    # v0.3.5 (AUD2-P0-1): actor is recorded as attribution only; it is
    # NOT authority. The CLI no longer accepts OFLOOP_ACTOR env as a
    # fallback — operators must pass --actor explicitly.
    actor = args.actor or "operator"
    note = args.note
    try:
        approval_doc = approval.request_human_approval(
            canonical_repo=repo,
            run_id=args.run_id,
            packet_path=packet_path,
            actor=actor,
            operator_note=note,
        )
    except RuntimeError as e:
        state_mod.append_event(
            repo, args.run_id,
            event_type="approval_refused",
            old_state=state_mod.load(repo, args.run_id).get("state"),
            new_state=None,
            actor=actor,
            reason=str(e),
        )
        _emit_error(str(e), exit_code=4, classification="OF_LOOP_APPROVAL_REFUSED")

    # Record the approval event (artifact hash included).
    approval_sha = approval.approval_artifact_sha256(approval_doc)
    cur_state = state_mod.load(repo, args.run_id).get("state")
    state_mod.append_event(
        repo, args.run_id,
        event_type="packet_approved",
        old_state=cur_state,
        new_state=None,
        actor=actor,
        reason=f"packet_sha256={approval_doc['packet_sha256']}",
        extras={
            "approval_sha256": approval_sha,
            "approval_method": approval_doc["approval_method"],
            "baseline_sha": approval_doc["baseline_sha"],
            "baseline_branch": approval_doc["baseline_branch"],
            "confirmation_token": approval_doc["confirmation_token"],
        },
    )

    # v0.4.5: human approval is the one and only PROGRAM operator gate.
    # Materialize the frozen graph now; no separate `program init` command is
    # required in normal operation.
    program_info = {"is_program": False, "initialized": False, "program": None}
    if packet_mod.packet_is_program(meta):
        try:
            program_info = _ensure_program_initialized(
                repo, args.run_id, meta, approval_doc,
            )
        except RuntimeError as e:
            _emit_error(
                f"approved PROGRAM materialization refused: {e}",
                exit_code=4,
                classification="PROGRAM_INIT_REFUSED_AFTER_APPROVAL",
            )

    # Transition AWAITING_APPROVAL -> READY_TO_BUILD only.
    cur = state_mod.load(repo, args.run_id)
    if cur.get("state") == "AWAITING_APPROVAL":
        state_mod.transition(
            repo, args.run_id,
            to_state="READY_TO_BUILD",
            actor=actor,
            reason=f"packet approved (packet_sha={approval_doc['packet_sha256'][:12]})",
        )
    _emit({
        "ok": True,
        "run_id": args.run_id,
        "approved": True,
        "approval_artifact": str(approval.approval_path(repo, args.run_id)),
        "packet_sha256": approval_doc["packet_sha256"],
        "baseline_sha": approval_doc["baseline_sha"],
        "baseline_branch": approval_doc["baseline_branch"],
        "approval_method": approval_doc["approval_method"],
        "state": "READY_TO_BUILD",
        "execution_mode": "program" if program_info.get("is_program") else "single",
        "program_initialized": bool(program_info.get("initialized")),
        "current_checkpoints": (
            (program_info.get("program") or {}).get("current_checkpoints") or []
        ),
    })


def cmd_spec_inspect_legacy(args: argparse.Namespace) -> None:
    """Inspect a run for legacy V1 approval fields and recommend re-approval."""
    repo = _repo_path(args.repo)
    packet_path = state_mod.run_dir(repo, args.run_id) / "WORK_PACKET.md"
    if not packet_path.exists():
        _emit_error("WORK_PACKET.md missing", exit_code=2)
    meta, _ = packet_mod.parse_packet_file(packet_path)
    legacy_packet = approval.is_legacy_packet_approval(meta)
    legacy_schema = packet_mod.packet_is_legacy_v1(meta)
    approval_doc = approval.load_approval(repo, args.run_id)
    ok, msg = approval.validate_approval_binding(
        canonical_repo=repo,
        run_id=args.run_id,
        approval=approval_doc,
        packet=meta,
        packet_path=packet_path,
    )
    _emit({
        "ok": True,
        "run_id": args.run_id,
        "legacy_packet_metadata": legacy_packet,
        "legacy_schema": legacy_schema,
        "has_approval_artifact": approval_doc is not None,
        "approval_binding_ok": ok,
        "approval_binding_message": msg,
        "recommendation": (
            "re-approve under V2" if (legacy_packet or legacy_schema or not ok) else "ok"
        ),
    })


def cmd_spec_amend(args: argparse.Namespace) -> None:
    repo = _repo_path(args.repo)
    packet_path = state_mod.run_dir(repo, args.run_id) / "WORK_PACKET.md"
    if not packet_path.exists():
        _emit_error("WORK_PACKET.md missing", exit_code=2)
    state_mod.append_event(
        repo, args.run_id,
        event_type="packet_amend_requested",
        old_state=None, new_state=None,
        actor="human",
        reason=args.change[:500],
    )
    _emit({"ok": True, "run_id": args.run_id, "amend_request_recorded": True})


def cmd_spec_stop(args: argparse.Namespace) -> None:
    repo = _repo_path(args.repo)
    state_mod.request_stop(repo, args.run_id, reason=args.reason, actor="human")
    cur = state_mod.load(repo, args.run_id)
    if cur and cur.get("state") not in ("APPROVED", "BLOCKED", "STOPPED"):
        state_mod.transition(
            repo, args.run_id, to_state="STOPPED",
            actor="human", reason=args.reason or "human stop",
        )
    _emit({"ok": True, "run_id": args.run_id, "stopped": True})


def cmd_spec_abandon(args: argparse.Namespace) -> None:
    repo = _repo_path(args.repo)
    state_mod.request_stop(repo, args.run_id, reason="abandoned", actor="human")
    cur = state_mod.load(repo, args.run_id)
    if cur and cur.get("state") not in ("STOPPED",):
        state_mod.transition(
            repo, args.run_id, to_state="STOPPED",
            actor="human", reason="abandoned",
        )
    _emit({"ok": True, "run_id": args.run_id, "abandoned": True})


# --- build subcommands -----------------------------------------------------

def _require_valid_approval(repo: Path, run_id: str) -> tuple[dict[str, Any], dict[str, Any], Path]:
    """Validate the packet + APPROVAL.json binding before any build/review work.

    Returns (packet_meta, approval_doc, packet_path). Raises RuntimeError
    on any failure; the CLI converts that to a refusal.
    """
    packet_path = state_mod.run_dir(repo, run_id) / "WORK_PACKET.md"
    if not packet_path.exists():
        raise RuntimeError("WORK_PACKET.md missing")
    meta, _ = packet_mod.parse_packet_file(packet_path)
    errors = packet_mod.validate_packet_for_approval(meta)
    if errors:
        raise RuntimeError("packet invalid: " + "; ".join(errors))
    approval_doc = approval.load_approval(repo, run_id)
    ok, msg = approval.validate_approval_binding(
        canonical_repo=repo,
        run_id=run_id,
        approval=approval_doc,
        packet=meta,
        packet_path=packet_path,
    )
    if not ok:
        raise RuntimeError(f"approval invalid: {msg}")
    return meta, approval_doc or {}, packet_path


def cmd_build_claim(args: argparse.Namespace) -> None:
    """Claim a build pass. The single durable owner of build_pass_count.

    Program mode (v2 state) routes through the unified claim owner
    `program.claim_build_pass`, which performs per-cp cap, cumulative
    cap, top-level mirror, and persistence under one flock so no
    counter can desync on a crash between writes.

    Single mode (v1) keeps the legacy path: V1 cap of 8 (or packet
    override) is enforced, replay returns replayed=True, state is
    transitioned to BUILDING.

    Both paths emit the same shape: {ok, run_id, state, build_pass_count,
    cp_id, replayed, cumulative, cap}.
    """
    repo = _repo_path(args.repo)
    # v0.5.0: first build claim auto-seals the run via execution_start.
    # Sealed runs bypass the legacy approval-ceremony refusal.
    try:
        seal = execution_start.ensure_executable(
            canonical_repo=repo, run_id=args.run_id,
            actor=args.actor or "operator",
            binding_method="build_start",
        )
    except RuntimeError as e:
        _emit_error(str(e), exit_code=4)
    try:
        meta, _approval_doc, _packet_path = _require_valid_approval(repo, args.run_id)
    except RuntimeError as e:
        _emit_error(str(e), exit_code=4)
    cur = state_mod.load(repo, args.run_id)
    cur_state = cur.get("state")

    # PROGRAM mode: unified claim owner.
    if state_mod.is_program_state(cur):
        try:
            r = program_mod.claim_build_pass(
                canonical_repo=repo,
                run_id=args.run_id,
                packet=meta,
            )
        except program_mod.ClaimRefused as e:
            _emit_error(f"build claim refused: {e}", exit_code=4)
        _emit({
            "ok": True,
            "run_id": args.run_id,
            "state": "BUILDING",
            "build_pass_count": r["claimed_pass_number"],
            "cp_id": r.get("cp_id"),
            "cumulative": r["cumulative"],
            "cap": r["cap"],
            "replayed": r["replayed"],
        })
        return

    # SINGLE mode: v0.5.2 atomic per-run claim lock. Two concurrent
    # single-mode build claims must converge on one pass.
    claim_lock = state_mod.run_dir(repo, args.run_id) / "BUILD_CLAIM_LOCK"
    try:
        with locking.flock_exclusive(claim_lock, blocking=True, timeout_seconds=30):
            cur = state_mod.load(repo, args.run_id)
            cur_state = cur.get("state")
            if cur_state not in ("READY_TO_BUILD", "CHANGES_REQUESTED", "BUILDING"):
                _emit_error(f"cannot claim in state {cur_state!r}", exit_code=2)
            if cur_state == "BUILDING":
                _emit({
                    "ok": True,
                    "run_id": args.run_id,
                    "state": "BUILDING",
                    "build_pass_count": int(cur.get("build_pass_count") or 0),
                    "replayed": True,
                })
                return
            try:
                state_mod.transition(
                    repo, args.run_id, to_state="BUILDING",
                    actor=args.actor or "of-builder",
                    reason="claim build pass",
                )
                new_pass_count = state_mod.increment_counter(
                    repo, args.run_id, counter="build_pass_count",
                    actor="of-builder", packet=meta,
                    hard_cap=True,
                )
            except limits_mod.RepairLimitExceeded as e:
                _emit_error(f"repair limit exceeded: {e}", exit_code=4)
            state_mod.append_event(
                repo, args.run_id,
                event_type="build_claimed",
                old_state=cur_state, new_state="BUILDING",
                actor=args.actor or "of-builder",
            )
            _emit({
                "ok": True,
                "run_id": args.run_id,
                "state": "BUILDING",
                "build_pass_count": new_pass_count,
                "replayed": False,
            })
            return
    except locking.LockBusyError as e:
        _emit_error(f"build claim lock contention: {e}", exit_code=4)
def cmd_review_claim(args: argparse.Namespace) -> None:
    """Claim a review pass. The single durable owner of review_pass_count.

    Program mode (v2 state) routes through the unified claim owner
    `program.claim_review_pass`. Single mode keeps the legacy V1 path.
    """
    repo = _repo_path(args.repo)
    try:
        meta, _approval_doc, _packet_path = _require_valid_approval(repo, args.run_id)
    except RuntimeError as e:
        _emit_error(str(e), exit_code=4)
    cur = state_mod.load(repo, args.run_id)
    cur_state = cur.get("state")

    # PROGRAM mode: unified claim owner.
    if state_mod.is_program_state(cur):
        try:
            r = program_mod.claim_review_pass(
                canonical_repo=repo,
                run_id=args.run_id,
                packet=meta,
            )
        except program_mod.ClaimRefused as e:
            _emit_error(f"review claim refused: {e}", exit_code=4)
        _emit({
            "ok": True,
            "run_id": args.run_id,
            "state": "REVIEWING",
            "review_pass_count": r["claimed_pass_number"],
            "cp_id": r.get("cp_id"),
            "cumulative": r["cumulative"],
            "cap": r["cap"],
            "replayed": r["replayed"],
        })
        return

    # SINGLE mode: v0.5.2 atomic per-run claim lock. Two concurrent
    # single-mode review claims must converge on one pass.
    claim_lock = state_mod.run_dir(repo, args.run_id) / "REVIEW_CLAIM_LOCK"
    try:
        with locking.flock_exclusive(claim_lock, blocking=True, timeout_seconds=30):
            cur = state_mod.load(repo, args.run_id)
            cur_state = cur.get("state")
            if cur_state not in ("READY_FOR_REVIEW", "CHANGES_REQUESTED", "REVIEWING"):
                _emit_error(f"cannot claim in state {cur_state!r}", exit_code=2)
            if cur_state == "REVIEWING":
                _emit({
                    "ok": True,
                    "run_id": args.run_id,
                    "state": "REVIEWING",
                    "review_pass_count": int(cur.get("review_pass_count") or 0),
                    "replayed": True,
                })
                return
            try:
                state_mod.transition(
                    repo, args.run_id, to_state="REVIEWING",
                    actor=args.actor or "of-reviewer",
                    reason="claim review pass",
                )
                new_pass_count = state_mod.increment_counter(
                    repo, args.run_id, counter="review_pass_count",
                    actor="of-reviewer", packet=meta,
                    hard_cap=True,
                )
            except limits_mod.RepairLimitExceeded as e:
                _emit_error(f"repair limit exceeded: {e}", exit_code=4)
            state_mod.append_event(
                repo, args.run_id,
                event_type="review_claimed",
                old_state=cur_state, new_state="REVIEWING",
                actor=args.actor or "of-reviewer",
            )
            _emit({
                "ok": True,
                "run_id": args.run_id,
                "state": "REVIEWING",
                "review_pass_count": new_pass_count,
                "replayed": False,
            })
            return
    except locking.LockBusyError as e:
        _emit_error(f"review claim lock contention: {e}", exit_code=4)
def cmd_build_transition(args: argparse.Namespace) -> None:
    repo = _repo_path(args.repo)
    state_mod.transition(
        repo, args.run_id, to_state=args.to,
        actor=args.actor or "of-builder",
        reason=args.reason or "",
        commit_sha=getattr(args, "commit_sha", None),
    )
    if args.to == "CHANGES_REQUESTED":
        # Increment repair round. In program mode, route through the
        # unified claim owner so per-cp, cumulative, and top-level mirror
        # counters cannot desync (matches review_finalize.py repair path).
        # v0.3.5 (F-4-01): pass source_evidence_sha so the replay guard
        # distinguishes fresh repair rounds from duplicate retries.
        cur = state_mod.load(repo, args.run_id)
        if state_mod.is_program_state(cur):
            meta, _approval_doc, _packet_path = _require_valid_approval(repo, args.run_id)
            ev_sha = (
                getattr(args, "commit_sha", None)
                or (cur or {}).get("last_candidate_sha")
                or ""
            )
            try:
                program_mod.claim_repair_round(
                    canonical_repo=repo,
                    run_id=args.run_id,
                    packet=meta,
                    source_evidence_sha=ev_sha or None,
                )
            except program_mod.ClaimRefused as e:
                _emit_error(f"repair claim refused: {e}", exit_code=4)
            # v0.3.5 (F-4-01): post-hook — transition CHANGES_REQUESTED
            # back to READY_TO_BUILD so the next build pass is not
            # classified as a replay of the previous repair.
            try:
                state_mod.transition(
                    repo, args.run_id,
                    to_state="READY_TO_BUILD",
                    actor=args.actor or "operator",
                    reason="repair_round claimed; ready for next build",
                )
            except Exception:
                pass  # Idempotent: if state is already READY_TO_BUILD, the
                      # FSM refuses (no edge from CHANGES_REQUESTED in
                      # single-mode). Tolerate this race; the next build
                      # claim will start from the current state.
            _emit({"ok": True, "run_id": args.run_id, "state": args.to})
            return
        # Single-mode V1 path: direct increment.
        cur["repair_round"] = int(cur.get("repair_round", 0)) + 1
        cur["no_progress_streak"] = 0
        state_mod.save(repo, args.run_id, cur)
        state_mod.append_event(
            repo, args.run_id, event_type="repair_round_incremented",
            old_state=None, new_state=None,
            actor=args.actor or "of-builder",
            extras={"repair_round": cur["repair_round"]},
        )
    _emit({"ok": True, "run_id": args.run_id, "state": args.to})


def cmd_build_write_receipt(args: argparse.Namespace) -> None:
    """DEPRECATED V1 path — kept for backward compatibility.

    The V2 finalizer is the only entity that writes the authoritative
    build receipt. ``ofloop build finalize`` performs the full
    deterministic verification and writes the receipt itself.
    This command refuses on V2 pipelines and emits a warning.
    """
    repo = _repo_path(args.repo)
    _emit_error(
        "ofloop build write-receipt is deprecated by V2. Use "
        "`ofloop build finalize <repo> <run-id> [agent-result.json]` instead.",
        exit_code=2,
        classification="OF_LOOP_WRITE_RECEIPT_DEPRECATED",
    )


def cmd_build_cleanup(args: argparse.Namespace) -> None:
    """Remove the per-run builder worktree (idempotent; safe to re-run)."""
    repo = _repo_path(args.repo)
    ok, msg = worktrees.cleanup_builder_worktree(repo, args.run_id)
    state_mod.append_event(
        repo, args.run_id,
        event_type="builder_worktree_cleanup",
        old_state=state_mod.load(repo, args.run_id).get("state"),
        new_state=None,
        actor="build_cleanup",
        reason=msg,
    )
    _emit({"ok": ok, "run_id": args.run_id, "message": msg, "removed": ok})


def cmd_review_cleanup(args: argparse.Namespace) -> None:
    """Remove the per-run reviewer worktree (idempotent; safe to re-run)."""
    repo = _repo_path(args.repo)
    ok, msg = worktrees.cleanup_reviewer_worktree(repo, args.run_id)
    state_mod.append_event(
        repo, args.run_id,
        event_type="reviewer_worktree_cleanup",
        old_state=state_mod.load(repo, args.run_id).get("state"),
        new_state=None,
        actor="review_cleanup",
        reason=msg,
    )
    _emit({"ok": ok, "run_id": args.run_id, "message": msg, "removed": ok})


def cmd_teardown_branch(args: argparse.Namespace) -> None:
    """Guarded candidate-branch teardown. Requires packet-controlled authority.

    Refuses unless ALL of:
      - packet declares ``teardown_allowed: true``
      - the run state is APPROVED, BLOCKED, STOPPED, or CHANGES_REQUESTED
    """
    repo = _repo_path(args.repo)
    s = state_mod.load(repo, args.run_id)
    if s is None:
        _emit_error(f"run not found: {args.run_id}", exit_code=2)
    try:
        meta, approval_doc, _packet_path = _require_valid_approval(repo, args.run_id)
    except RuntimeError as e:
        _emit_error(
            f"teardown refused: {e}",
            exit_code=4,
            classification="OF_LOOP_TEARDOWN_APPROVAL_INVALID",
        )
    if not bool(meta.get("teardown_allowed")):
        _emit_error(
            "teardown refused: approved packet does not declare teardown_allowed=true",
            exit_code=4, classification="OF_LOOP_TEARDOWN_NOT_AUTHORIZED",
        )
    cur_state = s.get("state")
    if cur_state not in ("APPROVED", "BLOCKED", "STOPPED", "CHANGES_REQUESTED"):
        _emit_error(
            f"teardown refused: run is in {cur_state!r}; only APPROVED/BLOCKED/STOPPED/CHANGES_REQUESTED are teardown-eligible",
            exit_code=4, classification="OF_LOOP_TEARDOWN_STATE_INELIGIBLE",
        )
    frozen_branch = str(approval_doc.get("candidate_branch") or "")
    branch = branch_resolver.resolve_candidate_branch(
        repo, args.run_id, packet=meta,
    )
    if not frozen_branch or branch != frozen_branch:
        _emit_error(
            "teardown refused: candidate branch does not match frozen approval",
            exit_code=4,
            classification="OF_LOOP_TEARDOWN_BRANCH_DRIFT",
        )
    if branch == str(approval_doc.get("baseline_branch") or ""):
        _emit_error(
            "teardown refused: candidate branch equals approved baseline branch",
            exit_code=4,
            classification="OF_LOOP_TEARDOWN_BASELINE_BRANCH",
        )
    if not git_checks.branch_exists(repo, branch):
        _emit({"ok": True, "run_id": args.run_id, "branch": branch, "removed": False, "message": "branch already absent"})
        return
    r = util.run_subprocess(
        ["git", "-C", str(repo), "branch", "-D", branch],
        timeout=15,
    )
    if r.returncode != 0:
        _emit_error(f"branch delete failed: {r.stderr.strip()}", exit_code=5)
    state_mod.append_event(
        repo, args.run_id,
        event_type="candidate_branch_teardown",
        old_state=cur_state, new_state=None,
        actor="teardown", reason=f"deleted branch {branch}",
    )
    _emit({"ok": True, "run_id": args.run_id, "branch": branch, "removed": True, "message": "deleted"})


def cmd_build_finalize(args: argparse.Namespace) -> None:
    """Deterministic build finalizer.

    The builder agent returns a semantic ``BUILD_AGENT_RESULT.json``.
    The finalizer independently verifies the candidate, computes diff
    stats, runs validations, scans for secrets, and writes the
    authoritative ``BUILD_RECEIPT.json``. The model cannot influence
    the finalizer's verdict on any of the deterministic checks.
    """
    repo = _repo_path(args.repo)
    agent_result_path = Path(args.agent_result).resolve(strict=False) if args.agent_result else None
    try:
        receipt = build_finalize.finalize_build(
            canonical_repo=repo,
            run_id=args.run_id,
            agent_result_path=agent_result_path,
        )
    except RuntimeError as e:
        state_mod.append_event(
            repo, args.run_id,
            event_type="build_finalize_refused",
            old_state=state_mod.load(repo, args.run_id).get("state"),
            new_state=None,
            actor="build_finalizer",
            reason=str(e),
        )
        _emit_error(str(e), exit_code=4, classification="OF_LOOP_BUILD_FINALIZE_REFUSED")
    _emit({
        "ok": True,
        "run_id": args.run_id,
        "candidate_sha": receipt["candidate_sha"],
        "files_changed": receipt["files_changed"],
        "added_lines": receipt["added_lines"],
        "removed_lines": receipt["removed_lines"],
        "next_state": receipt["next_state"],
        "validation_count": len(receipt["validation"]),
        "hard_secret_blocks": sum(1 for f in receipt["secret_scan_check"]["findings"] if f.get("severity") == "hard"),
        "scope_findings": len(receipt["scope_check"]["findings"]),
        "protected_findings": len(receipt["protected_path_check"]["offending_paths"]),
    })


def cmd_build_marker(args: argparse.Namespace) -> None:
    repo = _repo_path(args.repo)
    cur = state_mod.load(repo, args.run_id)
    state = cur.get("state")
    action, delay = scheduling.recommend_next_delay_minutes(role="builder", state=state)
    marker = scheduling.builder_marker(
        run_id=args.run_id,
        state=state,
        action=action,
        next_delay_minutes=delay,
        reason="builder pass complete",
    )
    sys.stdout.write(marker)
    sys.stdout.flush()


# --- review subcommands ----------------------------------------------------

def cmd_review_write_verdict(args: argparse.Namespace) -> None:
    """DEPRECATED V1 path — kept for backward compatibility.

    The V2 finalizer is the only entity that writes the authoritative
    review verdict. ``ofloop review finalize`` performs the full
    deterministic verification and writes the verdict itself.
    """
    repo = _repo_path(args.repo)
    _emit_error(
        "ofloop review write-verdict is deprecated by V2. Use "
        "`ofloop review finalize <repo> <run-id> <assessment.json>` instead.",
        exit_code=2,
        classification="OF_LOOP_WRITE_VERDICT_DEPRECATED",
    )


def cmd_review_finalize(args: argparse.Namespace) -> None:
    """Deterministic review finalizer.

    The reviewer agent returns a semantic assessment
    (``REVIEW_AGENT_ASSESSMENT.json``). The finalizer independently
    verifies the candidate SHA, re-runs validations, scans for
    secrets, and writes the authoritative ``REVIEW_VERDICT.json``.
    The model cannot influence the finalizer's verdict on any of the
    deterministic checks.
    """
    repo = _repo_path(args.repo)
    assessment_path = Path(args.assessment).resolve(strict=False) if args.assessment else None
    try:
        verdict = review_finalize.finalize_review(
            canonical_repo=repo,
            run_id=args.run_id,
            assessment_path=assessment_path,
        )
    except RuntimeError as e:
        state_mod.append_event(
            repo, args.run_id,
            event_type="review_finalize_refused",
            old_state=state_mod.load(repo, args.run_id).get("state"),
            new_state=None,
            actor="review_finalizer",
            reason=str(e),
        )
        _emit_error(str(e), exit_code=4, classification="OF_LOOP_REVIEW_FINALIZE_REFUSED")
    _emit({
        "ok": True,
        "run_id": args.run_id,
        "verdict": verdict["verdict"],
        "candidate_sha": verdict["candidate_sha_reviewed"],
        "failure_reason": verdict["failure_reason"],
        "must_fix_count": sum(1 for f in verdict["findings"] if f.get("classification") == "must_fix"),
        "hard_secret_blocks": sum(1 for f in verdict["secret_scan_check"]["findings"] if f.get("severity") == "hard"),
        "validation_pass": all(v["passed"] for v in verdict["validation_results"]),
    })


def cmd_review_prepare(args: argparse.Namespace) -> None:
    """Deterministically pin the current review candidate/worktree/context."""
    from . import review_prepare as review_prepare_mod

    repo = _repo_path(args.repo)
    try:
        ctx = review_prepare_mod.prepare(
            canonical_repo=repo,
            run_id=args.run_id,
        )
    except review_prepare_mod.ReviewPrepareRefused as e:
        _emit_error(
            f"review prepare refused: {e}",
            exit_code=4,
            classification="OF_LOOP_REVIEW_PREPARE_REFUSED",
        )
    except RuntimeError as e:
        _emit_error(str(e), exit_code=4)
    print(json.dumps(ctx, indent=2, sort_keys=True))


def cmd_review_assessment_skeleton(args: argparse.Namespace) -> None:
    """Write a schema-conformant REVIEW_AGENT_ASSESSMENT.json skeleton.

    v0.4.2: the deterministic review finalizer refuses any assessment whose
    top-level shape does not match the contract. This subcommand materializes
    a pre-shaped skeleton at the run scratch path so the reviewer agent only
    fills in runtime-dependent values (acceptance_results, non_goal_results,
    findings, validation_results, evidence, timestamp). Idempotent unless
    --overwrite is supplied.
    """
    from . import assessment as assessment_mod
    repo = _repo_path(args.repo)
    try:
        _require_valid_approval(repo, args.run_id)
        cur = state_mod.load(repo, args.run_id)
        if not cur or cur.get("state") != "REVIEWING":
            raise RuntimeError(
                f"assessment skeleton requires REVIEWING state, got "
                f"{(cur or {}).get('state')!r}"
            )
        path = assessment_mod.write_skeleton(
            repo,
            args.run_id,
            overwrite=bool(args.overwrite),
        )
    except RuntimeError as e:
        _emit_error(str(e), exit_code=4)
    print(json.dumps({
        "ok": True,
        "run_id": args.run_id or path.parent.name,
        "assessment_path": str(path),
        "shape": "ownframework-loop-review-agent-assessment/v1",
        "overwritten": bool(args.overwrite),
    }, indent=2))


def cmd_review_marker(args: argparse.Namespace) -> None:
    repo = _repo_path(args.repo)
    cur = state_mod.load(repo, args.run_id)
    state = cur.get("state")
    action, delay = scheduling.recommend_next_delay_minutes(role="reviewer", state=state)
    marker = scheduling.reviewer_marker(
        run_id=args.run_id,
        state=state,
        action=action,
        next_delay_minutes=delay,
        reason="reviewer pass complete",
    )
    sys.stdout.write(marker)
    sys.stdout.flush()


# --- doctor / new-repo -----------------------------------------------------

def cmd_doctor(args: argparse.Namespace) -> None:
    repo = _repo_path(args.repo)
    if not git_checks.is_git_repo(repo):
        _emit({"ok": False, "is_git_repo": False})
        return
    # F-003 closure: refuse bare repositories explicitly.
    if git_checks.is_bare(repo):
        _emit({
            "ok": False,
            "repo": str(repo),
            "is_git_repo": True,
            "bare": True,
            "reason": "bare repositories are not eligible targets",
            "classification": "BARE_REPOSITORY_UNSUPPORTED",
        })
        return
    info = {
        "ok": True,
        "repo": str(repo),
        "is_git_repo": True,
        "bare": False,
        "toplevel": str(git_checks.git_toplevel(repo)),
        "current_branch": git_checks.current_branch(repo),
        "current_head": git_checks.current_head(repo),
        "remote_count": git_checks.remote_count(repo),
        "remotes": git_checks.remotes(repo),
        "is_dirty": git_checks.is_dirty(repo),
        "dirty_classification": git_checks.dirty_classification(repo),
    }
    if args.run_id:
        run_dir = state_mod.run_dir(repo, args.run_id)
        info["run_dir"] = str(run_dir)
        info["run_dir_exists"] = run_dir.exists()
        if run_dir.exists():
            info["state"] = state_mod.load(repo, args.run_id)
            packet_path = run_dir / "WORK_PACKET.md"
            info["packet_exists"] = packet_path.exists()
            if packet_path.exists():
                info["packet_sha256"] = util.sha256_text(packet_path.read_text(encoding="utf-8"))
            info["has_receipt"] = (run_dir / "BUILD_RECEIPT.json").exists()
            info["has_verdict"] = (run_dir / "REVIEW_VERDICT.json").exists()
            info["stop_requested"] = state_mod.is_stop_requested(repo, args.run_id)
            # Crash reconciliation: detect receipt-written-but-not-transitioned,
            # event-chain-vs-state mismatch, and verifier-cache inconsistencies.
            state_obj = info["state"] if isinstance(info["state"], dict) else None
            events_path = run_dir / "EVENTS.log"
            info["crash_reconciliation"] = _reconcile_crashes(
                repo, args.run_id, state_obj,
                run_dir / "BUILD_RECEIPT.json",
                run_dir / "REVIEW_VERDICT.json",
                events_path,
            )
            info["ok"] = bool(info["crash_reconciliation"].get("ok", True)) and info["ok"]
    _emit(info)


def _reconcile_crashes(
    repo: Path, run_id: str, state_obj: dict[str, Any] | None,
    receipt_path: Path, verdict_path: Path, events_path: Path,
) -> dict[str, Any]:
    """Inspect run artifacts and surface any inconsistencies.

    Returns a dict with keys:
      ok              - True iff no anomaly detected.
      anomalies       - list of human-readable findings (empty when clean).
      state_chain_ok  - True iff verify_state_sha(STATE.json, EVENTS.log) passes.
      event_chain_ok  - True iff compute_event_chain_hash equals the most
                        recent recorded event_chain_sha256 in EVENTS.log.
      receipt_present - True iff receipt_path exists.
      verdict_present - True iff verdict_path exists.
      packet_binds_receipt - True iff receipt.packet_sha256 matches approval's.
    """
    anomalies: list[str] = []
    receipt_present = receipt_path.exists()
    verdict_present = verdict_path.exists()

    state_chain_ok = True
    try:
        ok, msg = integrity.verify_state_sha(state_mod.state_path(repo, run_id), events_path)
        state_chain_ok = ok
        if not ok:
            anomalies.append(f"state_chain_mismatch: {msg}")
    except Exception as e:
        anomalies.append(f"state_chain_check_error: {e}")

    event_chain_ok = True
    if events_path.exists():
        try:
            recorded_chain = integrity.get_event_chain_hash(events_path)
            actual_chain = integrity.compute_event_chain_hash(events_path)
            event_chain_ok = (recorded_chain == actual_chain)
            if not event_chain_ok:
                anomalies.append("event_chain_mismatch")
        except Exception as e:
            anomalies.append(f"event_chain_check_error: {e}")
            event_chain_ok = False

    packet_binds_receipt = True
    if receipt_present and state_obj is not None:
        try:
            with open(receipt_path, encoding="utf-8") as f:
                rec = json.load(f)
            approval_doc = approval.load_approval(repo, run_id)
            if approval_doc:
                rec_packet_sha = rec.get("packet_sha256")
                approval_packet_sha = approval_doc.get("packet_sha256")
                if rec_packet_sha and approval_packet_sha and rec_packet_sha != approval_packet_sha:
                    anomalies.append(
                        f"receipt_packet_sha_mismatch: receipt={rec_packet_sha[:12]} "
                        f"!= approval={approval_packet_sha[:12]}"
                    )
                    packet_binds_receipt = False
                cand = rec.get("candidate_sha")
                if cand and not git_checks.commit_exists(repo, cand):
                    anomalies.append(f"receipt_candidate_missing: {cand[:12]}")
        except Exception as e:
            anomalies.append(f"receipt_inspection_error: {e}")

    if verdict_present and state_obj is not None:
        try:
            with open(verdict_path, encoding="utf-8") as f:
                ver = json.load(f)
            cand = ver.get("candidate_sha_reviewed")
            if cand and not git_checks.commit_exists(repo, cand):
                anomalies.append(f"verdict_candidate_missing: {cand[:12]}")
        except Exception as e:
            anomalies.append(f"verdict_inspection_error: {e}")

    return {
        "ok": not anomalies,
        "anomalies": anomalies,
        "state_chain_ok": state_chain_ok,
        "event_chain_ok": event_chain_ok,
        "receipt_present": receipt_present,
        "verdict_present": verdict_present,
        "packet_binds_receipt": packet_binds_receipt,
    }


def cmd_new_repo(args: argparse.Namespace) -> None:
    root = Path(args.root).expanduser().resolve(strict=False)
    target = root / args.project_name
    if target.exists() and any(target.iterdir()):
        _emit_error(f"target not empty: {target}", exit_code=2)
    target.mkdir(parents=True, exist_ok=True)
    import subprocess
    subprocess.run(["git", "init", "-b", "master", str(target)], check=True)
    rc = git_checks.remote_count(target)
    if rc > 0:
        _emit_error(f"newly created repo has remotes (should be zero)", exit_code=2)
    if args.init_baseline:
        # F-002 closure: read the effective Git identity from the target
        # repo's local config (which inherits from global config). Never
        # silently synthesize an identity; never modify global config.
        name, email = git_checks.effective_git_author(target)
        if not name or not email:
            _emit_error(
                "git identity not configured (user.name / user.email). "
                "Configure once via 'git config --global user.name ...' "
                "and 'git config --global user.email ...', or set them "
                "in the target repo's local config.",
                exit_code=4,
                classification="MISSING_GIT_IDENTITY",
            )
        readme = target / "README.md"
        readme.write_text(
            f"# {args.project_name}\n\nMinimal bootstrap baseline created by OwnFramework Loop.\n",
            encoding="utf-8",
        )
        gitignore = target / ".gitignore"
        gitignore.write_text(".ownframework-loop/\n.worktrees/ownframework-loop/\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(target), "add", "README.md", ".gitignore"], check=True)
        # Use the discovered identity; do NOT pass --local config writes.
        env = {**os.environ, "GIT_AUTHOR_NAME": name, "GIT_AUTHOR_EMAIL": email,
               "GIT_COMMITTER_NAME": name, "GIT_COMMITTER_EMAIL": email}
        subprocess.run(
            ["git", "-C", str(target), "commit", "-m", "loop-v1: minimal bootstrap baseline"],
            check=True, env=env,
        )
    _emit({
        "ok": True,
        "target": str(target),
        "branch": "master",
        "remote_count": git_checks.remote_count(target),
        "baseline_initialized": bool(args.init_baseline),
        "git_author": {"name": name if args.init_baseline else None,
                       "email": email if args.init_baseline else None},
    })


# --- argument parser -------------------------------------------------------

def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="ofloop", description="OwnFramework Loop CLI")
    sub = p.add_subparsers(dest="command", required=True)

    # spec
    spec = sub.add_parser("spec", help="spec subcommands")
    spec_sub = spec.add_subparsers(dest="spec_cmd", required=True)
    s_new = spec_sub.add_parser("new", help="create a new run")
    s_new.add_argument("repo")
    s_new.add_argument("mission", nargs="?")
    s_new.add_argument("--unsafe", action="store_true",
                       help="bypass CLI-side dirty-state refusal (model layer still refuses)")
    s_new.set_defaults(func=cmd_spec_new)
    s_status = spec_sub.add_parser("status", help="show run status")
    s_status.add_argument("repo")
    s_status.add_argument("run_id")
    s_status.set_defaults(func=cmd_spec_status)
    s_app = spec_sub.add_parser(
        "approve",
        help="legacy compatibility pre-seal (TTY only; normal 0.6 flow does not require it)",
    )
    s_app.add_argument("repo")
    s_app.add_argument("run_id")
    # v0.3.5 (AUD2-P0-1): OFLOOP_ACTOR env is no longer accepted as a
    # defaulting fallback. Operator must pass --actor explicitly; the
    # default value "operator" is a literal placeholder, not a claim of
    # identity. recorded as attribution only, not authority.
    s_app.add_argument("--actor", default="operator",
                        help="operator identifier recorded in APPROVAL.json as attribution (not authority)")
    s_app.add_argument("--note", default=None,
                       help="optional operator note recorded in APPROVAL.json")
    # v0.3.5 (AUD2-P0-1): --assume-tty removed entirely. Approval
    # requires a genuine interactive TTY. There is no automation
    # override.
    s_app.set_defaults(func=cmd_spec_approve)
    s_legacy = spec_sub.add_parser("inspect-legacy", help="inspect a run for legacy V1 approval fields")
    s_legacy.add_argument("repo")
    s_legacy.add_argument("run_id")
    s_legacy.set_defaults(func=cmd_spec_inspect_legacy)
    s_amd = spec_sub.add_parser("amend", help="amend an existing packet")
    s_amd.add_argument("repo")
    s_amd.add_argument("run_id")
    s_amd.add_argument("change")
    s_amd.set_defaults(func=cmd_spec_amend)
    s_stop = spec_sub.add_parser("stop", help="stop a run")
    s_stop.add_argument("repo")
    s_stop.add_argument("run_id")
    s_stop.add_argument("--reason", default="")
    s_stop.set_defaults(func=cmd_spec_stop)
    s_aban = spec_sub.add_parser("abandon", help="abandon a run")
    s_aban.add_argument("repo")
    s_aban.add_argument("run_id")
    s_aban.set_defaults(func=cmd_spec_abandon)
    program = sub.add_parser("program", help="program subcommands")
    program_sub = program.add_subparsers(dest="program_sub", required=True)
    p_init = program_sub.add_parser(
        "init",
        help="legacy compatibility PROGRAM materialization; normal flow auto-materializes at first start",
    )
    p_init.add_argument("repo")
    p_init.add_argument("run_id")
    p_init.set_defaults(func=cmd_program_init)
    p_stat = program_sub.add_parser("status", help="program-state summary")
    p_stat.add_argument("repo")
    p_stat.add_argument("run_id")
    p_stat.set_defaults(func=cmd_program_status)

    s_td = spec_sub.add_parser("teardown-branch", help="guarded candidate-branch teardown (packet-controlled)")
    s_td.add_argument("repo")
    s_td.add_argument("run_id")
    s_td.set_defaults(func=cmd_teardown_branch)

    # build
    bld = sub.add_parser("build", help="build subcommands")
    bld_sub = bld.add_subparsers(dest="build_cmd", required=True)
    b_claim = bld_sub.add_parser("claim", help="claim a build pass")
    b_claim.add_argument("repo")
    b_claim.add_argument("run_id")
    b_claim.add_argument("--actor", default="of-builder")
    b_claim.set_defaults(func=cmd_build_claim)
    b_trans = bld_sub.add_parser("transition", help="transition state")
    b_trans.add_argument("repo")
    b_trans.add_argument("run_id")
    b_trans.add_argument("--to", required=True)
    b_trans.add_argument("--reason", default="")
    b_trans.add_argument("--actor", default="of-builder")
    b_trans.add_argument("--commit-sha", default=None,
                          help="candidate SHA to record as last_candidate_sha on this transition")
    b_trans.set_defaults(func=cmd_build_transition)
    b_rec = bld_sub.add_parser("write-receipt", help="DEPRECATED — use build finalize")
    b_rec.add_argument("repo")
    b_rec.add_argument("run_id")
    b_rec.add_argument("receipt")
    b_rec.set_defaults(func=cmd_build_write_receipt)
    b_cln = bld_sub.add_parser("cleanup", help="remove per-run builder worktree (idempotent)")
    b_cln.add_argument("repo")
    b_cln.add_argument("run_id")
    b_cln.set_defaults(func=cmd_build_cleanup)
    b_fin = bld_sub.add_parser("finalize", help="deterministic build finalizer (V2)")
    b_fin.add_argument("repo")
    b_fin.add_argument("run_id")
    b_fin.add_argument("agent_result", nargs="?", default=None,
                       help="path to BUILD_AGENT_RESULT.json (semantic)")
    b_fin.set_defaults(func=cmd_build_finalize)
    b_mk = bld_sub.add_parser("marker", help="emit builder marker")
    b_mk.add_argument("repo")
    b_mk.add_argument("run_id")
    b_mk.set_defaults(func=cmd_build_marker)

    # v0.4.3: deterministic builder agent result skeleton.
    b_skel = bld_sub.add_parser(
        "agent-skeleton",
        help="write a deterministic BUILD_AGENT_RESULT.json skeleton at the run scratch path",
    )
    b_skel.add_argument("repo")
    b_skel.add_argument("run_id", nargs="?", default=None)
    b_skel.add_argument("--overwrite", action="store_true",
                        help="overwrite an existing BUILD_AGENT_RESULT.json")
    b_skel.set_defaults(func=cmd_build_agent_skeleton)

    # v0.4.3: deterministic build preparation that owns worktree +
    # branch resolution so the model does not have to.
    b_prep = bld_sub.add_parser(
        "prepare",
        help="deterministic build preparation (branch, baseline, worktree, scratch); "
             "the parent build skill MUST use this instead of raw git worktree add",
    )
    b_prep.add_argument("repo")
    b_prep.add_argument("run_id", nargs="?", default=None)
    b_prep.add_argument("--repair-round", type=int, default=0)
    b_prep.set_defaults(func=cmd_build_prepare)

    # review
    rev = sub.add_parser("review", help="review subcommands")
    rev_sub = rev.add_subparsers(dest="review_cmd", required=True)
    r_wv = rev_sub.add_parser("write-verdict", help="DEPRECATED — use review finalize")
    r_wv.add_argument("repo")
    r_wv.add_argument("run_id")
    r_wv.add_argument("verdict")
    r_wv.set_defaults(func=cmd_review_write_verdict)
    r_claim = rev_sub.add_parser("claim", help="claim a review pass")
    r_claim.add_argument("repo")
    r_claim.add_argument("run_id")
    r_claim.add_argument("--actor", default="of-reviewer")
    r_claim.set_defaults(func=cmd_review_claim)
    r_prep = rev_sub.add_parser(
        "prepare",
        help="deterministic reviewer preparation (candidate, exact-SHA worktree, scratch)",
    )
    r_prep.add_argument("repo")
    r_prep.add_argument("run_id")
    r_prep.set_defaults(func=cmd_review_prepare)
    r_fin = rev_sub.add_parser("finalize", help="deterministic review finalizer (V2)")
    r_fin.add_argument("repo")
    r_fin.add_argument("run_id")
    r_fin.add_argument("assessment", nargs="?", default=None,
                       help="path to REVIEW_AGENT_ASSESSMENT.json (semantic)")
    r_fin.set_defaults(func=cmd_review_finalize)
    r_cln = rev_sub.add_parser("cleanup", help="remove per-run reviewer worktree (idempotent)")
    r_cln.add_argument("repo")
    r_cln.add_argument("run_id")
    r_cln.set_defaults(func=cmd_review_cleanup)
    r_mk = rev_sub.add_parser("marker", help="emit reviewer marker")
    r_mk.add_argument("repo")
    r_mk.add_argument("run_id")
    r_mk.set_defaults(func=cmd_review_marker)
    r_skel = rev_sub.add_parser(
        "assessment-skeleton",
        help="write a deterministic REVIEW_AGENT_ASSESSMENT.json skeleton at the run scratch path",
    )
    r_skel.add_argument("repo")
    r_skel.add_argument("run_id", nargs="?", default=None)
    r_skel.add_argument("--overwrite", action="store_true",
                       help="overwrite an existing REVIEW_AGENT_ASSESSMENT.json")
    r_skel.set_defaults(func=cmd_review_assessment_skeleton)

    # loop run — single-mode unattended orchestrator
    from . import orchestrator as orch_mod
    def cmd_loop_run(args: argparse.Namespace) -> None:
        repo = _repo_path(args.repo)
        out = orch_mod.dispatch_run_mode(
            canonical_repo=repo,
            run_id=args.run_id,
            mission=args.mission or '',
            max_repair_rounds=int(args.max_repair_rounds) if args.max_repair_rounds is not None else None,
        )
        ok = bool(out.get("ok")) if isinstance(out, dict) else False
        _emit(out, exit_code=0 if ok else 1)

    lp = sub.add_parser('loop', help='unattended loop orchestration')
    l_sub = lp.add_subparsers(dest='loop_cmd', required=True)
    l_run = l_sub.add_parser('run', help='unattended loop orchestration (single OR program mode)')
    l_run.add_argument('repo')
    l_run.add_argument('--run-id', default=None,
                       help='target run id (defaults to most recent)')
    l_run.add_argument('mission', nargs='?')
    l_run.add_argument('--max-repair-rounds', type=int, default=None,
                       help='override packet.risk_budget.max_repair_rounds')
    l_run.set_defaults(func=cmd_loop_run)

    # dispatch — one deterministic work-order owner for interactive or durable hosts.
    def cmd_dispatch_claim(args: argparse.Namespace) -> None:
        repo = _repo_path(args.repo)
        try:
            out = dispatch_mod.claim_next(canonical_repo=repo, run_id=args.run_id)
        except dispatch_mod.DispatchError as e:
            _emit_error(str(e), exit_code=4, classification="OF_LOOP_DISPATCH_REFUSED")
        _emit(out)

    def cmd_dispatch_finalize(args: argparse.Namespace) -> None:
        repo = _repo_path(args.repo)
        order = {
            "schema": dispatch_mod.SCHEMA,
            "decision": args.decision,
            "canonical_repo": str(repo),
            "run_id": args.run_id,
            "semantic_path": args.semantic_path,
        }
        try:
            out = dispatch_mod.finalize_work_order(order)
        except dispatch_mod.DispatchError as e:
            _emit_error(str(e), exit_code=4, classification="OF_LOOP_DISPATCH_FINALIZE_REFUSED")
        _emit(out)

    dsp = sub.add_parser("dispatch", help="atomic BUILD/REVIEW/WAIT/TERMINAL work-order boundary")
    dsp_sub = dsp.add_subparsers(dest="dispatch_cmd", required=True)
    d_claim = dsp_sub.add_parser("claim", help="claim and prepare exactly one semantic work order")
    d_claim.add_argument("repo")
    d_claim.add_argument("run_id")
    d_claim.set_defaults(func=cmd_dispatch_claim)
    d_fin = dsp_sub.add_parser("finalize", help="finalize one completed semantic work order")
    d_fin.add_argument("repo")
    d_fin.add_argument("run_id")
    d_fin.add_argument("decision", choices=["BUILD", "REVIEW"])
    d_fin.add_argument("semantic_path")
    d_fin.set_defaults(func=cmd_dispatch_finalize)

    # supervisor — durable machine execution clock. Protocol truth remains in core artifacts.
    def cmd_supervisor_enqueue(args: argparse.Namespace) -> None:
        repo = _repo_path(args.repo)
        out = supervisor_mod.enqueue(
            canonical_repo=repo,
            run_id=args.run_id,
            runner=args.runner,
            db_path=Path(args.db).expanduser() if args.db else None,
            max_infra_failures=args.max_infra_failures,
            max_total_cost_usd=args.max_cost_usd,
            max_wall_seconds=args.max_wall_seconds,
        )
        _emit(out)

    def cmd_supervisor_status(args: argparse.Namespace) -> None:
        repo = _repo_path(args.repo)
        out = supervisor_mod.status(
            canonical_repo=repo,
            run_id=args.run_id,
            db_path=Path(args.db).expanduser() if args.db else None,
        )
        _emit(out, exit_code=0 if out.get("ok") else 2)

    def cmd_supervisor_serve(args: argparse.Namespace) -> None:
        out = supervisor_mod.serve(
            db_path=Path(args.db).expanduser() if args.db else None,
            poll_seconds=args.poll_seconds,
            timeout_seconds=args.timeout_seconds,
            once=bool(args.once),
        )
        if out is not None:
            _emit(out, exit_code=0 if out.get("ok") else 1)

    sup = sub.add_parser("supervisor", help="durable zero-LLM-idle execution supervisor")
    sup_sub = sup.add_subparsers(dest="supervisor_cmd", required=True)
    s_enq = sup_sub.add_parser("enqueue", help="enqueue one existing human-originated run")
    s_enq.add_argument("repo")
    s_enq.add_argument("run_id")
    s_enq.add_argument("--runner", default="claude-code")
    s_enq.add_argument("--db", default=None)
    s_enq.add_argument("--max-infra-failures", type=int, default=3)
    s_enq.add_argument(
        "--max-cost-usd", type=float, default=25.0,
        help="operational model-cost ceiling per enqueued run; <=0 disables",
    )
    s_enq.add_argument(
        "--max-wall-seconds", type=int, default=28800,
        help="operational wall-clock ceiling from first supervisor execution; <=0 disables",
    )
    s_enq.set_defaults(func=cmd_supervisor_enqueue)
    s_ss = sup_sub.add_parser("status", help="show supervisor operational state")
    s_ss.add_argument("repo")
    s_ss.add_argument("run_id")
    s_ss.add_argument("--db", default=None)
    s_ss.set_defaults(func=cmd_supervisor_status)
    s_srv = sup_sub.add_parser("serve", help="run the durable supervisor execution clock")
    s_srv.add_argument("--db", default=None)
    s_srv.add_argument("--poll-seconds", type=float, default=2.0)
    s_srv.add_argument("--timeout-seconds", type=int, default=3600)
    s_srv.add_argument("--once", action="store_true")
    s_srv.set_defaults(func=cmd_supervisor_serve)

    # doctor
    doc = sub.add_parser("doctor", help="inspect repo + run")
    doc.add_argument("repo")
    doc.add_argument("--run-id", default=None)
    doc.set_defaults(func=cmd_doctor)

    # new-repo
    nr = sub.add_parser("new-repo", help="initialize a local-only repo")
    nr.add_argument("root")
    nr.add_argument("project_name")
    nr.add_argument("--init-baseline", action="store_true")
    nr.set_defaults(func=cmd_new_repo)

    return p


def cmd_build_agent_skeleton(args: argparse.Namespace) -> None:
    """Write a schema-conformant BUILD_AGENT_RESULT.json skeleton.

    v0.4.3: the deterministic build finalizer refuses any agent result
    whose top-level shape does not match the contract (the v0.4.2
    incident demonstrated the cost of letting the agent reconstruct
    the schema from prose). This subcommand materializes a pre-shaped
    skeleton at the run scratch path so the agent only fills in
    runtime-dependent values: summary, evidence, blocker_reason,
    escalation_*, unit_ids_completed, acceptance_addressed, notes,
    timestamp. Idempotent unless --overwrite is supplied.

    v0.4.4 (defect 7): independently re-verifies approval binding BEFORE
    writing the skeleton. Each deterministic boundary must fail closed
    itself; never rely on the parent model having called another
    validator first.
    """
    from . import build_agent as build_agent_mod
    repo = _repo_path(args.repo)
    run_id = args.run_id
    if not run_id:
        rd = state_mod.run_dir(repo, "")
        runs = sorted(p.name for p in rd.iterdir() if p.is_dir() and p.name.startswith("run-"))
        if not runs:
            _emit_error("no run-* directories", exit_code=2)
        if len(runs) > 1:
            _emit_error(
                f"multiple active runs; pass --run-id explicitly: {', '.join(runs)}",
                exit_code=2,
            )
        run_id = runs[0]
    # Defect 7: re-verify approval binding (packet + APPROVAL.json match).
    try:
        _require_valid_approval(repo, run_id)
    except RuntimeError as e:
        _emit_error(f"approval-binding refused: {e}", exit_code=4,
                    classification="OF_LOOP_APPROVAL_BINDING_DRIFT")
    try:
        path = build_agent_mod.write_skeleton(
            repo,
            run_id,
            overwrite=bool(args.overwrite),
        )
    except RuntimeError as e:
        _emit_error(str(e), exit_code=4)
    print(json.dumps({
        "ok": True,
        "run_id": run_id,
        "agent_result_path": str(path),
        "shape": build_agent_mod.SCHEMA_AGENT_RESULT,
        "overwritten": bool(args.overwrite),
    }, indent=2))


def cmd_build_prepare(args: argparse.Namespace) -> None:
    """Deterministic build preparation.

    v0.4.3 hardening: replaces the model-owned `git worktree add`
    pattern that the v0.4.2 incident showed was unreliable. Returns a
    machine-readable execution context that the parent build skill and
    the fresh `of-builder` agent consume:

      - current checkpoint id
      - baseline SHA
      - candidate branch (single source of truth via branch_resolver)
      - exact builder worktree path (created or reused, deterministic)
      - approved packet SHA
      - approval SHA
      - current work_unit_id
      - repair round / pass identity

    The parent build skill MUST NOT issue raw `git worktree add`,
    `git worktree remove`, or `git branch <invented-name>` for ordinary
    pass setup. Run `ofloop build prepare` instead.
    """
    from . import build_prepare as build_prepare_mod
    repo = _repo_path(args.repo)
    try:
        ctx = build_prepare_mod.prepare(
            canonical_repo=repo,
            run_id=args.run_id,
            repair_round=int(getattr(args, "repair_round", 0) or 0),
        )
    except build_prepare_mod.PrepareRefused as e:
        _emit_error(f"build prepare refused: {e}", exit_code=4)
    except RuntimeError as e:
        _emit_error(str(e), exit_code=2)
    print(json.dumps(ctx, indent=2, sort_keys=True))



def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    try:
        args.func(args)
    except transitions.InvalidTransitionError as e:
        _emit_error(f"invalid transition: {e}", exit_code=3)
    except FileNotFoundError as e:
        _emit_error(f"file not found: {e}", exit_code=2)
    except Exception as e:
        _emit_error(str(e), exit_code=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
