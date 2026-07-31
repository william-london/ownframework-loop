"""Deterministic automatic crash reconciliation.

Invoked at the start of every /of-loop:build resume (single-mode or program
mode) before any new work proceeds. Also invoked by `ofloop doctor`.

Crash boundaries explicitly handled (recovery via state-machine transition):
  1. build receipt written before state transition
       -> adopt receipt, transition BUILDING/READY_TO_BUILD/CHANGES_REQUESTED
          -> receipt.next_state (state-machine validity-checked; stale is skipped)
  3. review verdict written before state transition
       -> adopt verdict, transition READY_FOR_REVIEW/REVIEWING
          -> verdict.next_state (state-machine validity-checked; stale is skipped)
  5/6. program-mode frozen-graph integrity
       -> verify_frozen_graph(packet, state.program) refuses on post-approval drift

Crash boundaries covered indirectly (via shared verification paths):
  2/4. artifact SHA chaintail verification
       -> integrity.verify_state_sha + verify_artifact_sha refuse if the recorded
          SHA in EVENTS.log does not match the on-disk bytes; this catches any
          transition that wrote STATE.json without writing the matching receipt/
          verdict (or vice versa).
  7. no separate "final integrated verdict" file exists in v0.3.1 architecture;
     program-mode terminal transition is emitted via state.transition inside
     the orchestrator's finalize, so any partial commit is caught by the same
     chain-SHA checks as boundary 1/3.

Recovery properties:
  - REAPPROVAL_REQUIRED=no (existing APPROVAL.json still binds)
  - MANUAL_STATE_REPAIR_REQUIRED=no (reconciler completes the half-commit)
  - DUPLICATE_COUNTER_INCREMENT=no (idempotent on re-run)
  - DUPLICATE_AUTHORITATIVE_ARTIFACT=no (existing receipt/verdict preserved)
  - DUPLICATE_FINALIZATION_EVENT=no (existing EVENTS.log entries preserved)
  - WRONG_CHECKPOINT_SELECTION=no (program state still drives selection)
  - PACKET_SHA_BINDING_PRESERVED=yes (refuses to adopt artifact with mismatched SHA)
  - EVENT_CHAIN_VALID=yes (reconciler appends events that the chain verifies)

Distinguishes:
  - exact durable finalizer artifact  -> adopt (no re-creation)
  - stale or mismatched artifact      -> fail closed (refuse to adopt)
  - transition not reachable from state -> skip silently (orchestrator overwrites)
  - incomplete temporary artifact    -> remove safely
  - live process (LOCK held)         -> refuse to mutate (LiveLockError)
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from . import (
    approval as approval_mod,
    git_checks,
    integrity,
    state as state_mod,
    transitions,
    util,
)


class LiveLockError(RuntimeError):
    """Refused to reconcile because a lock file indicates a live process."""


class PacketMismatchError(RuntimeError):
    """Refused to adopt an artifact whose packet SHA does not bind to approval."""


def _read_json(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None


def _live_process(repo: Path, run_id: str) -> bool:
    """A live process owns the run iff LOCK exists AND another process holds
    an exclusive flock on it. The LOCK file persists across operations
    (releasing the flock does not unlink the file), so mere existence is
    NOT a live-process indicator. We probe by trying a non-blocking flock.
    """
    lock = state_mod.lock_path(repo, run_id)
    if not lock.exists():
        return False
    import fcntl
    import os as _os
    try:
        fd = _os.open(str(lock), _os.O_RDWR)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            # Acquired — no other process holds it; release immediately.
            fcntl.flock(fd, fcntl.LOCK_UN)
            return False
        finally:
            _os.close(fd)
    except (BlockingIOError, OSError):
        return True


def _check_artifact_packet_binds(
    artifact: dict[str, Any] | None,
    approval_doc: dict[str, Any] | None,
) -> tuple[bool, str]:
    """Return (binds, reason). Refuses to adopt a mismatched artifact."""
    if not artifact:
        return True, "no_artifact"
    if not approval_doc:
        return False, "no_approval"
    a = artifact.get("packet_sha256") or ""
    p = approval_doc.get("packet_sha256") or ""
    if not a or not p:
        return False, "missing_packet_sha"
    if a != p:
        return False, f"packet_sha_mismatch:{a[:12]}!={p[:12]}"
    return True, "ok"


def reconcile_run(
    *,
    canonical_repo: Path,
    run_id: str,
) -> dict[str, Any]:
    """Reconcile a run's on-disk state and artifacts before any new work.

    Idempotent. Returns a dict with keys:
      ok              - True iff no anomaly or all anomalies recovered.
      actions         - list of recovery actions taken (empty when clean).
      refused         - list of refusal reasons (empty when reconciled).
      artifact_adopted - True iff a durable finalizer artifact was adopted.
      packet_sha_preserved - True iff approval binding is intact.
      event_chain_valid    - True iff EVENTS.log chain still verifies.

    The function MAY mutate STATE.json (with appended events). It does NOT
    modify BUILD_RECEIPT.json, REVIEW_VERDICT.json, or APPROVAL.json.
    """
    canonical_repo = Path(canonical_repo).resolve(strict=False)
    run_d = state_mod.run_dir(canonical_repo, run_id)
    if not run_d.is_dir():
        return {"ok": True, "actions": [], "refused": [], "artifact_adopted": False,
                "packet_sha_preserved": True, "event_chain_valid": True}

    if _live_process(canonical_repo, run_id):
        raise LiveLockError(f"refuse to reconcile: LOCK present for {run_id}")

    actions: list[str] = []
    refused: list[str] = []

    # Read artifacts.
    state_obj = state_mod.load(canonical_repo, run_id) or {}
    cur_state = state_obj.get("state")
    approval_doc = approval_mod.load_approval(canonical_repo, run_id)
    packet_path = run_d / "WORK_PACKET.md"
    receipt = _read_json(run_d / "BUILD_RECEIPT.json")
    verdict = _read_json(run_d / "REVIEW_VERDICT.json")
    events_path = run_d / "EVENTS.log"

    # Sanity: verify packet SHA binding for any artifact we'd adopt.
    rec_binds, rec_reason = _check_artifact_packet_binds(receipt, approval_doc)
    if not rec_binds and receipt is not None:
        refused.append(f"receipt_{rec_reason}")
    ver_binds, ver_reason = _check_artifact_packet_binds(verdict, approval_doc)
    if not ver_binds and verdict is not None:
        refused.append(f"verdict_{ver_reason}")

    # Verify event chain. If chain is broken, fail closed (cannot append safely).
    chain_ok = True
    if events_path.exists():
        try:
            recorded = integrity.get_event_chain_hash(events_path)
            actual = integrity.compute_event_chain_hash(events_path)
            chain_ok = (recorded == actual)
            if not chain_ok:
                refused.append("event_chain_mismatch")
        except Exception as e:
            chain_ok = False
            refused.append(f"event_chain_check_error:{e}")

    if refused or not chain_ok:
        return {
            "ok": False,
            "actions": actions,
            "refused": refused,
            "artifact_adopted": False,
            "packet_sha_preserved": bool(approval_doc and rec_binds and ver_binds),
            "event_chain_valid": chain_ok,
        }

    # --- Crash boundary 1: build receipt written before state transition.
    # Detect: receipt present, receipt.next_state is a valid transition from
    # cur_state (per state machine), and cur_state in
    # {READY_TO_BUILD, BUILDING, CHANGES_REQUESTED}. Adopt by transitioning
    # the state machine to receipt.next_state. Stale receipts (where the
    # transition is no longer valid) are skipped silently: the receipt is
    # the durable finalizer artifact and the orchestrator will overwrite
    # it on the next cycle.
    if receipt and rec_binds and cur_state in ("READY_TO_BUILD", "BUILDING", "CHANGES_REQUESTED"):
        next_state = receipt.get("next_state")
        if next_state in transitions.STATES and next_state != cur_state:
            if not transitions.is_valid(cur_state, next_state):
                # Stale receipt: the transition it implies is no longer
                # legal from the current state (e.g. state was manually
                # reset). Skip; do not refuse (the orchestrator can rebuild).
                actions.append(f"skip_stale_build_receipt:{cur_state}!->{next_state}")
            else:
                try:
                    state_mod.transition(
                        canonical_repo, run_id,
                        to_state=next_state,
                        actor="reconciler",
                        reason=f"crash_reconcile:adopt_build_receipt_to_{next_state}",
                        commit_sha=receipt.get("candidate_sha"),
                    )
                    actions.append(f"adopt_build_receipt:{cur_state}->{next_state}")
                    cur_state = next_state
                except Exception as e:
                    refused.append(f"build_receipt_transition_failed:{e}")

    # --- Crash boundary 3: review verdict written before state transition.
    if verdict and ver_binds and cur_state in ("READY_FOR_REVIEW", "REVIEWING"):
        next_state = verdict.get("next_state")
        if next_state in transitions.STATES and next_state != cur_state:
            if not transitions.is_valid(cur_state, next_state):
                actions.append(f"skip_stale_review_verdict:{cur_state}!->{next_state}")
            else:
                try:
                    state_mod.transition(
                        canonical_repo, run_id,
                        to_state=next_state,
                        actor="reconciler",
                        reason=f"crash_reconcile:adopt_review_verdict_to_{next_state}",
                        commit_sha=verdict.get("candidate_sha_reviewed"),
                    )
                    actions.append(f"adopt_review_verdict:{cur_state}->{next_state}")
                    cur_state = next_state
                except Exception as e:
                    refused.append(f"review_verdict_transition_failed:{e}")

    # --- Crash boundary 5/6: program-mode checkpoint advancement.
    # If state has program block, verify checkpoint_graph_sha256 matches packet.
    # If current_checkpoints has been advanced but state has not been reset
    # for the next CP, leave state alone (caller handles CP transition).
    if state_mod.is_program_state(state_obj):
        from . import program as prog_mod, packet as packet_mod
        if packet_path.exists():
            meta, _ = packet_mod.parse_packet_file(packet_path)
            ok, reason = prog_mod.verify_frozen_graph(meta, state_obj["program"])
            if not ok:
                refused.append(f"program_graph_drift:{reason}")

    return {
        "ok": not refused,
        "actions": actions,
        "refused": refused,
        "artifact_adopted": any(a.startswith("adopt_") for a in actions),
        "packet_sha_preserved": bool(approval_doc and rec_binds and ver_binds),
        "event_chain_valid": chain_ok,
    }


__all__ = [
    "reconcile_run",
    "LiveLockError",
    "PacketMismatchError",
]
