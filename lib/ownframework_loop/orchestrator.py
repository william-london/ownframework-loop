"""OwnFramework Loop — single-mode unattended orchestrator.

Drives one complete spec → build → review cycle end-to-end without
human in-the-loop approval. The operator must pre-approve the work
packet and pre-create an approval marker BEFORE the orchestrator is
invoked; the orchestrator refuses to start without that marker.

Why approval is still required:
  - The architecture splits the trust boundary: model layer writes
    semantic assessments / receipts, deterministic finalizers write
    authoritative state. The approval marker is the only place a
    human (or operator-blessed automation) acknowledges the proposed
    packet bytes.
  - The orchestrator does NOT and CANNOT bypass the marker. It only
    drives the deterministic steps that come AFTER approval has
    been recorded.

Loop shape:
  1. spec new         (always)
  2. wait for approval marker (refuse if missing)
  3. build claim + build finalize (loop until receipt is written)
  4. review claim + review finalize (loop until verdict is written)
  5. if verdict == CHANGES_REQUESTED, loop back to step 3 up to
     repair_round cap (read from packet.risk_budget.max_repair_rounds)
  6. if verdict == APPROVED, return success
  7. if verdict == BLOCKED, return failure
  8. if REPAIR_LIMIT or SCOPE_VIOLATION, return failure

The orchestrator NEVER:
  - approves a packet
  - merges, pushes, deploys, or creates remotes
  - edits the work packet
  - emits a verdict itself (the deterministic finalizer does)
  - bypasses any hook (the deterministic finalizers are the authority)
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Any

from . import (
    approval as approval_mod,
    packet as packet_mod,
    program as program_mod,
    state as state_mod,
    util,
)
from .program import ProgramStateError

ORCHESTRATOR_AGENT = "of-loop-orchestrator"
MAX_REPAIR_ROUNDS_DEFAULT = 3
TERMINAL_STATES = {"APPROVED", "BLOCKED", "STOPPED"}


def _resolve_ofloop_bin() -> str:
    import os as _os
    explicit = _os.environ.get("OFLOOP_BIN", "").strip()
    if explicit and Path(explicit).exists():
        return explicit
    sibling = Path(__file__).resolve().parent.parent.parent / "bin" / "ofloop"
    if sibling.exists():
        return str(sibling)
    return "ofloop"


def _run_cli(args: list[str], *, cwd: Path | None = None) -> dict[str, Any]:
    """Invoke the ofloop CLI as a subprocess and parse its JSON output.

    The CLI is the only authoritative way to drive state transitions.
    We shell out to it so the orchestrator never bypasses any
    deterministic finalizer.
    """
    cli = _resolve_ofloop_bin()
    proc = subprocess.run(
        [cli, *args],
        capture_output=True,
        text=True,
        check=False,
        cwd=str(cwd) if cwd else None,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"ofloop {' '.join(args)} failed: rc={proc.returncode} stderr={proc.stderr.strip()} stdout={proc.stdout.strip()[:200]}"
        )
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"ofloop {' '.join(args)} non-JSON output: {proc.stdout!r}") from e


def _require_approval_marker(canonical_repo: Path, run_id: str) -> dict[str, Any]:
    """Refuse to run without a pre-existing approval marker.

    The marker is APPROVAL.json written by spec approve. The
    orchestrator never writes it itself.
    """
    # Check whether the run even exists before blaming the approval marker.
    run_dir = canonical_repo / ".ownframework-loop" / run_id
    if not run_dir.is_dir():
        raise RuntimeError(
            f"refuse to start: run directory not found for {run_id!r} under {canonical_repo}. "
            "Operator must run: ofloop spec new <repo> <mission>"
        )
    approval_doc = approval_mod.load_approval(canonical_repo, run_id)
    if approval_doc is None:
        raise RuntimeError(
            f"refuse to start: no APPROVAL.json for run {run_id!r}. "
            "Operator must run: ofloop spec approve <repo> <run-id>"
        )
    return approval_doc


def _drive_build_cycle(canonical_repo: Path, run_id: str) -> dict[str, Any]:
    """Claim one build pass and run the deterministic finalizer."""
    # Idempotent — replay in BUILDING returns replayed=True without
    # duplicating the pass count.
    _run_cli(["build", "claim", str(canonical_repo), run_id])
    out = _run_cli(["build", "finalize", str(canonical_repo), run_id])
    return out


def _drive_review_cycle(canonical_repo: Path, run_id: str) -> dict[str, Any]:
    """Claim one review pass and run the deterministic finalizer.

    The deterministic finalizer writes the verdict, transitions the
    state, and increments the no_progress_streak / repair_round
    counters as appropriate. The orchestrator never writes the
    verdict itself.
    """
    _run_cli(["review", "claim", str(canonical_repo), run_id])
    out = _run_cli(["review", "finalize", str(canonical_repo), run_id])
    return out


def _safe_load_state(canonical_repo: Path, run_id: str) -> dict[str, Any] | None:
    """Load state.json for a run, returning None if missing/corrupt.

    The earlier pattern of state_mod.load(...).get("state") would
    crash with AttributeError when state.json is missing or corrupt.
    Returning None lets the orchestrator surface a domain refusal
    instead of a Python AttributeError.
    """
    s = state_mod.load(canonical_repo, run_id)
    if not isinstance(s, dict):
        return None
    return s


def _discover_run_id(canonical_repo: Path) -> str:
    """Discover the latest run id under the canonical repo's run dir.

    Used by the unattended single-mode when no run_id is provided.
    Returns the run id whose mtime is greatest.
    """
    from . import state as state_mod
    runs_root = Path(canonical_repo) / ".ownframework-loop"
    if not runs_root.is_dir():
        raise RuntimeError(f"no .ownframework-loop/ under {canonical_repo}")
    candidates = [p for p in runs_root.iterdir() if p.is_dir() and p.name.startswith("run-")]
    if not candidates:
        raise RuntimeError(f"no runs found under {runs_root}")
    candidates.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return candidates[0].name


def run_single_mode(
    *,
    canonical_repo: Path,
    run_id: str | None = None,
    mission: str | None = None,
    max_repair_rounds: int | None = None,
) -> dict[str, Any]:
    """Run one complete unattended single-mode cycle.

    The operator must have already created the run via spec new
    and pre-approved the work packet via spec approve. The
    orchestrator finds the run, refuses if no approval marker exists,
    and drives the build + review cycles until the run reaches a
    terminal state or the repair-round cap is hit.

    Args:
      canonical_repo: path to the git repo
      run_id: target run id (defaults to the most recently created run)
      mission: deprecated — kept for CLI back-compat; ignored when run_id is set
      max_repair_rounds: override packet.risk_budget.max_repair_rounds
    """
    canonical_repo = Path(canonical_repo).resolve(strict=False)
    if not canonical_repo.is_dir():
        raise RuntimeError(f"canonical repo not found: {canonical_repo}")

    if run_id is None:
        run_id = _discover_run_id(canonical_repo)

    # Refuse to start without an operator approval marker.
    _require_approval_marker(canonical_repo, run_id)

    # Phase 3: deterministic automatic crash reconciliation. Adopt any
    # half-committed durable artifact (BUILD_RECEIPT, REVIEW_VERDICT)
    # so the resumed cycle continues from the right state. Refuses if
    # a live process owns the LOCK file.
    try:
        from . import reconcile as reconcile_mod
        rr = reconcile_mod.reconcile_run(canonical_repo=canonical_repo, run_id=run_id)
        if not rr.get("ok"):
            return {
                "ok": False,
                "run_id": run_id,
                "terminal_state": (_safe_load_state(canonical_repo, run_id) or {}).get("state"),
                "reason": "reconcile_refused",
                "reconcile": rr,
                "history": [],
            }
    except reconcile_mod.LiveLockError as e:
        return {
            "ok": False,
            "run_id": run_id,
            "terminal_state": (_safe_load_state(canonical_repo, run_id) or {}).get("state"),
            "reason": f"live_process:{e}",
            "history": [],
        }

    # 3. Drive cycles until terminal.
    cap = max_repair_rounds if max_repair_rounds is not None else MAX_REPAIR_ROUNDS_DEFAULT
    history: list[dict[str, Any]] = []
    for round_idx in range(cap + 1):
        # Build cycle.
        try:
            _drive_build_cycle(canonical_repo, run_id)
        except Exception as e:
            history.append({"round": round_idx, "phase": "build", "error": str(e)})
            return {
                "ok": False,
                "run_id": run_id,
                "terminal_state": (_safe_load_state(canonical_repo, run_id) or {}).get("state"),
                "history": history,
                "reason": "build_cycle_failed",
            }
        # Review cycle.
        try:
            rv_out = _drive_review_cycle(canonical_repo, run_id)
        except Exception as e:
            history.append({"round": round_idx, "phase": "review", "error": str(e)})
            return {
                "ok": False,
                "run_id": run_id,
                "terminal_state": (_safe_load_state(canonical_repo, run_id) or {}).get("state"),
                "history": history,
                "reason": "review_cycle_failed",
            }
        # Read terminal state.
        cur = state_mod.load(canonical_repo, run_id)
        state = cur.get("state")
        history.append({"round": round_idx, "phase": "complete", "state": state})
        if state in TERMINAL_STATES:
            return {
                "ok": state == "APPROVED",
                "run_id": run_id,
                "terminal_state": state,
                "rounds": round_idx + 1,
                "history": history,
            }
        # CHANGES_REQUESTED → loop
        if state != "CHANGES_REQUESTED":
            return {
                "ok": False,
                "run_id": run_id,
                "terminal_state": state,
                "rounds": round_idx + 1,
                "history": history,
                "reason": f"unexpected_state:{state}",
            }

    # 4. Repair-round cap reached.
    return {
        "ok": False,
        "run_id": run_id,
        "terminal_state": (_safe_load_state(canonical_repo, run_id) or {}).get("state"),
        "rounds": cap + 1,
        "history": history,
        "reason": "repair_round_cap_reached",
    }



def run_program_mode(
    *,
    canonical_repo: Path,
    run_id: str | None = None,
    max_repair_rounds: int | None = None,
) -> dict[str, Any]:
    """Drive a v3 program-mode packet to terminal APPROVED|BLOCKED|STOPPED.

    One-at-a-time checkpoint selection. Each iteration:
      1. read program state
      2. pick the deterministic next claimable checkpoint (None ⇒ done)
      3. drive one build cycle and one review cycle against it
      4. finalize the checkpoint (APPROVED/BLOCKED/STOPPED)
      5. advance to the next claimable cp or terminate

    Refuses to start without an approval marker. Caller must have
    already written APPROVAL.json and run `program init`.
    """
    canonical_repo = Path(canonical_repo).resolve(strict=False)
    if not canonical_repo.is_dir():
        raise RuntimeError(f"canonical repo not found: {canonical_repo}")
    if run_id is None:
        run_id = _discover_run_id(canonical_repo)

    # Refuse without operator approval.
    _require_approval_marker(canonical_repo, run_id)

    # Phase 3: deterministic automatic crash reconciliation.
    try:
        from . import reconcile as reconcile_mod
        rr = reconcile_mod.reconcile_run(canonical_repo=canonical_repo, run_id=run_id)
        if not rr.get("ok"):
            return _program_done(
                canonical_repo, run_id, ok=False,
                reason="reconcile_refused", history=[{"phase": "reconcile", "rr": rr}],
            )
    except reconcile_mod.LiveLockError as e:
        return _program_done(
            canonical_repo, run_id, ok=False,
            reason=f"live_process:{e}", history=[{"phase": "reconcile", "refused": str(e)}],
        )

    # Load packet and program state.
    state = _safe_load_state(canonical_repo, run_id)
    if state is None:
        raise RuntimeError(f"STATE.json missing for run {run_id}")
    if not state_mod.is_program_state(state):
        raise RuntimeError(
            f"run {run_id} is not in program mode; use run_single_mode"
        )

    packet_path = state_mod.run_dir(canonical_repo, run_id) / "WORK_PACKET.md"
    meta, _ = packet_mod.parse_packet_file(packet_path)
    if not packet_mod.packet_is_program(meta):
        raise RuntimeError(f"run {run_id} packet is not a v3 program-mode packet")

    # Verify frozen graph (no post-approval widening).
    program_state = state["program"]
    ok, reason = program_mod.verify_frozen_graph(meta, program_state)
    if not ok:
        return _program_done(canonical_repo, run_id, ok=False, reason=reason,
                             history=[{"phase": "verify_frozen_graph", "reason": reason}])

    history: list[dict[str, Any]] = []
    cap = max_repair_rounds if max_repair_rounds is not None else program_mod.MAX_CP_REPAIR_ROUNDS
    # Bound the loop on the cumulative ceilings (sum of approved cp caps),
    # not a fixed 16. With 9 CPs at max_build=1 + max_review=1 each, the
    # loop must allow >= 18 iterations. Add a +4 safety margin for the
    # CHANGES_REQUESTED repair cycles that don't advance the counter.
    _cumulative_ce = (program_state.get("cumulative_ceilings") or {})
    _cum_build = int(_cumulative_ce.get("max_build_passes", 0)) or (
        program_mod.MAX_CP_BUILD_PASSES + program_mod.MAX_CP_REVIEW_PASSES
    )
    _cum_review = int(_cumulative_ce.get("max_review_passes", 0)) or _cum_build
    _cum_repair = int(_cumulative_ce.get("max_repair_rounds", 0)) or 0
    _loop_bound = _cum_build + _cum_review + max(_cum_repair, 4) + 4
    for round_idx in range(_loop_bound):
        cur = _safe_load_state(canonical_repo, run_id)
        if cur is None:
            return _program_done(canonical_repo, run_id, ok=False,
                                 reason="state_missing", history=history)
        prog = cur.get("program") or {}
        cp_id = program_mod.select_next_checkpoint(meta, prog)
        if cp_id is None:
            term, term_state = program_mod.is_program_terminal(prog)
            if term:
                return _program_done(
                    canonical_repo, run_id,
                    ok=term_state == "APPROVED",
                    terminal_state=term_state,
                    reason=program_mod.program_terminal_reason(prog),
                    rounds=round_idx,
                    history=history,
                )
            # No current and not terminal — bug.
            return _program_done(canonical_repo, run_id, ok=False,
                                 reason="no_current_no_terminal", history=history)

        # v0.3.5 (A1-004): STOP observation at every safe orchestration
        # boundary. If the operator has created a STOP marker file,
        # exit the loop without dispatching another cycle.
        if state_mod.is_stop_requested(canonical_repo, run_id):
            history.append({"round": round_idx, "phase": "stop_observed",
                            "cp_id": cp_id})
            return _program_done(canonical_repo, run_id, ok=False,
                                 terminal_state="STOPPED",
                                 reason="stop_observed",
                                 rounds=round_idx, history=history)

        # One build + one review cycle against the candidate.
        try:
            _drive_build_cycle(canonical_repo, run_id)
            history.append({"round": round_idx, "phase": "build", "cp_id": cp_id})
        except Exception as e:
            history.append({"round": round_idx, "phase": "build_error", "cp_id": cp_id, "error": str(e)})
            return _program_done(canonical_repo, run_id, ok=False,
                                 reason="build_cycle_failed", history=history)

        # v0.3.5 (A1-004): re-check STOP between cycles.
        if state_mod.is_stop_requested(canonical_repo, run_id):
            history.append({"round": round_idx, "phase": "stop_observed_after_build",
                            "cp_id": cp_id})
            return _program_done(canonical_repo, run_id, ok=False,
                                 terminal_state="STOPPED",
                                 reason="stop_observed",
                                 rounds=round_idx, history=history)

        try:
            _drive_review_cycle(canonical_repo, run_id)
            history.append({"round": round_idx, "phase": "review", "cp_id": cp_id})
        except Exception as e:
            history.append({"round": round_idx, "phase": "review_error", "cp_id": cp_id, "error": str(e)})
            return _program_done(canonical_repo, run_id, ok=False,
                                 reason="review_cycle_failed", history=history)

        # Read post-cycle state. The deterministic finalizers set BLOCKED
        # on hard refusals (e.g. secret leak, scope violation, stale
        # sha). We treat any post-cycle BLOCKED as program-BLOCKED for
        # this checkpoint.
        cur = _safe_load_state(canonical_repo, run_id) or {}
        post_state = cur.get("state")
        if post_state == "BLOCKED":
            # Stamp this checkpoint as BLOCKED + record evidence.
            cp_terminal = "BLOCKED"
        elif post_state == "CHANGES_REQUESTED":
            # The reviewer requested changes — increment a no_progress
            # streak and continue. If the streak hits the cp cap we
            # cap-out as BLOCKED.
            cp_terminal = None
        elif post_state == "APPROVED":
            cp_terminal = "APPROVED"
        else:
            cp_terminal = None

        if cp_terminal:
            # Bump per-checkpoint counters and global source accounting
            # before finalize_checkpoint (which validates per-cp counts).
            cp_packet = next(
                cp for cp in meta["checkpoint_graph"]["checkpoints"]
                if cp["id"] == cp_id
            )
            # v0.3.2: per-cp and cumulative build/review counters are
            # already incremented by the unified claim path
            # (program.claim_build_pass / program.claim_review_pass) which
            # _drive_build_cycle / _drive_review_cycle invoke via the CLI.
            # The orchestrator MUST NOT increment them again — doing so
            # would double-count and the per-cp cap would refuse on the
            # second cycle. We therefore read the latest program state
            # directly from disk and run only the source-tree accounting
            # and finalize steps below.
            new_prog = (cur.get("program") or {})
            try:
                # Source-tree accounting: ALWAYS run when we have a
                # baseline+candidate SHA pair. If git diff fails or the
                # record raises ProgramStateError (cap exceeded), we HARD
                # BLOCK the checkpoint rather than silently swallowing the
                # cap violation. Audit v0.3.0-F1: the previous try/except
                # swallowed cap-rejection, allowing a program to exceed
                # GLOBAL_MAX_UNIQUE_CHANGED_FILES / DIFF_LINES and still
                # finalize as APPROVED.
                baseline_sha = (program_state.get("source_sha_provenance") or {}).get("baseline_sha")
                last_candidate = cur.get("last_candidate_sha")
                if baseline_sha and last_candidate:
                    acc = program_mod.source_tree_accounting(
                        canonical_repo=canonical_repo,
                        baseline_sha=baseline_sha,
                        candidate_sha=last_candidate,
                    )
                    new_prog = program_mod.record_aggregate_change(
                        new_prog,
                        files_changed_unique_delta=acc["files_changed_unique"],
                        diff_lines_delta=acc["diff_lines"],
                    )
            except program_mod.ProgramStateError as e:
                history.append({"phase": "aggregate_cap", "reason": str(e)})
                cp_terminal = "BLOCKED"
            # Defect 3 (v0.4.4): when the orchestrator's per-round
            # outcome is APPROVED, route through the SAME deterministic
            # helper the Claude-native review_finalize uses. This is the
            # single owner of PROGRAM advancement — no second state
            # machine, no duplicated advancement logic.
            evidence_manifest = {"_packet": meta, "round": round_idx,
                                  "candidate_sha": cur.get("last_candidate_sha")}
            if cp_terminal == "APPROVED":
                ev_sha = program_mod.sha256_text(
                    program_mod.canonical_json_dumps(evidence_manifest)
                )
                # The orchestrator may not have a review verdict SHA, so
                # use the evidence manifest SHA as the link.
                adv = program_mod.advance_after_review_approval(
                    canonical_repo=canonical_repo,
                    run_id=run_id,
                    packet=meta,
                    state=cur,
                    candidate_sha=cur.get("last_candidate_sha") or "",
                    verdict_sha256=ev_sha,
                    review_pass_number=int(cur.get("review_pass_count", 0) or 0),
                    actor="orchestrator",
                )
                # Reload so we pick up the helper's saved state.
                cur = state_mod.load(canonical_repo, run_id)
                new_state = cur
                new_prog = cur.get("program") or new_prog
            else:
                new_prog = program_mod.finalize_checkpoint(
                    program_state=new_prog,
                    cp_id=cp_id,
                    terminal_state=cp_terminal,
                    evidence_manifest=evidence_manifest,
                )
                new_state = dict(cur)
                new_state["program"] = new_prog
                new_state["schema"] = state_mod.PROGRAM_STATE_SCHEMA_VERSION
                state_mod.save(canonical_repo, run_id, new_state)
            history.append({"round": round_idx, "phase": "finalize",
                            "cp_id": cp_id, "terminal_state": cp_terminal})

            # Per-build/review finalizers transitioned the top-level state
            # (e.g. to APPROVED or BLOCKED). For program mode, transition it
            # back to READY_TO_BUILD iff there is another claimable
            # checkpoint — otherwise leave it terminal.
            cur_after = _safe_load_state(canonical_repo, run_id) or {}
            next_cp = program_mod.select_next_checkpoint(
                meta, new_prog,
            )
            if next_cp is not None and cur_after.get("state") in ("APPROVED", "BLOCKED", "STOPPED"):
                # Reset state machine so the next CP can claim. The single-
                # v0.3.5 (A1-001/A1-004/A1-005): the program-mode
                # orchestrator no longer bypasses the FSM via
                # state_mod.save(). program_transition validates the
                # APPROVED -> READY_TO_BUILD escape hatch against the
                # program-mode FSM table (transitions.assert_valid_program),
                # which permits the transition ONLY when the run has
                # more claimable checkpoints.
                if cur_after.get("state") == "BLOCKED":
                    # Keep BLOCKED; we already returned below for cp_terminal=BLOCKED.
                    pass
                else:
                    try:
                        state_mod.program_transition(
                            canonical_repo, run_id,
                            to_state="READY_TO_BUILD",
                            actor="orchestrator",
                            reason=f"checkpoint {cp_id} done; advancing",
                            extras={
                                "program": new_prog,
                                "schema": state_mod.PROGRAM_STATE_SCHEMA_VERSION,
                            },
                        )
                    except Exception as e:
                        history.append({"phase": "state_reset_failed", "error": str(e)})
                        return _program_done(canonical_repo, run_id, ok=False,
                                             reason="state_reset_failed", history=history)

        if cp_terminal == "BLOCKED":
            # v0.3.5 (A1-001/A1-004/A1-005): replace direct state_mod.save()
            # with program_transition so the BLOCKED terminal is validated
            # against the FSM. The deterministic finalizers never run on
            # this state unless the program is fully terminated.
            try:
                state_mod.program_transition(
                    canonical_repo, run_id,
                    to_state="BLOCKED",
                    actor="orchestrator",
                    reason=f"cp_blocked:{cp_id}",
                    extras={
                        "program": new_prog,
                        "schema": state_mod.PROGRAM_STATE_SCHEMA_VERSION,
                    },
                )
            except Exception as e:
                history.append({"phase": "block_transition_failed", "error": str(e)})
            return _program_done(canonical_repo, run_id, ok=False,
                                 terminal_state="BLOCKED",
                                 reason=f"cp_blocked:{cp_id}", history=history)

        # Repair-round per-cp cap check.
        cp_meta = next(c for c in meta["checkpoint_graph"]["checkpoints"] if c["id"] == cp_id)
        cp_live = next(c for c in (cur.get("program") or {}).get("checkpoints", [])
                       if c["id"] == cp_id)
        if cp_live["repair_round_count"] >= cp_meta["risk_budget"]["max_repair_rounds"]:
            new_prog_blocked = program_mod.finalize_checkpoint(
                program_state=cur.get("program") or {},
                cp_id=cp_id, terminal_state="BLOCKED",
                evidence_manifest={"_packet": meta, "round": round_idx,
                                    "reason": "cp_repair_cap_reached"},
            )
            # v0.3.5 (A1-001/A1-004/A1-005): replace direct state_mod.save()
            # with program_transition so the BLOCKED terminal is validated
            # against the FSM.
            try:
                state_mod.program_transition(
                    canonical_repo, run_id,
                    to_state="BLOCKED",
                    actor="orchestrator",
                    reason=f"cp_repair_cap:{cp_id}",
                    extras={"program": new_prog_blocked},
                )
            except Exception as e:
                history.append({"phase": "repair_cap_block_failed", "error": str(e)})
            return _program_done(canonical_repo, run_id, ok=False,
                                 terminal_state="BLOCKED",
                                 reason=f"cp_repair_cap:{cp_id}", history=history)

    return _program_done(canonical_repo, run_id, ok=False,
                         reason="iteration_cap_reached", history=history)


def _program_done(
    canonical_repo: Path,
    run_id: str,
    *,
    ok: bool,
    terminal_state: str = "",
    reason: str = "",
    rounds: int = 0,
    history: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    return {
        "ok": ok,
        "run_id": run_id,
        "execution_mode": "program",
        "terminal_state": terminal_state,
        "rounds": rounds,
        "history": history or [],
        "reason": reason,
    }


def dispatch_run_mode(
    *,
    canonical_repo: Path,
    run_id: str | None = None,
    mission: str | None = None,
    max_repair_rounds: int | None = None,
) -> dict[str, Any]:
    """Dispatch between single-mode and program-mode based on the run.

    Inspects the packet for v3+execution_mode=program; if absent,
    falls back to single-mode. Returns the unified envelope shape.
    """
    canonical_repo = Path(canonical_repo).resolve(strict=False)
    if run_id is None:
        run_id = _discover_run_id(canonical_repo)
    packet_path = state_mod.run_dir(canonical_repo, run_id) / "WORK_PACKET.md"
    if not packet_path.exists():
        return run_single_mode(
            canonical_repo=canonical_repo, run_id=run_id,
            mission=mission, max_repair_rounds=max_repair_rounds,
        )
    try:
        meta, _ = packet_mod.parse_packet_file(packet_path)
        if packet_mod.packet_is_program(meta):
            return run_program_mode(
                canonical_repo=canonical_repo, run_id=run_id,
                max_repair_rounds=max_repair_rounds,
            )
    except ProgramStateError:
        raise
    except Exception:
        pass
    return run_single_mode(
        canonical_repo=canonical_repo, run_id=run_id,
        mission=mission, max_repair_rounds=max_repair_rounds,
    )
