"""OwnFramework Loop V1 — single-mode unattended orchestrator.

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
    state as state_mod,
    util,
)

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
            f"ofloop {' '.join(args)} failed: rc={proc.returncode} stderr={proc.stderr.strip()}"
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
                "terminal_state": state_mod.load(canonical_repo, run_id).get("state"),
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
                "terminal_state": state_mod.load(canonical_repo, run_id).get("state"),
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
        "terminal_state": state_mod.load(canonical_repo, run_id).get("state"),
        "rounds": cap + 1,
        "history": history,
        "reason": "repair_round_cap_reached",
    }
