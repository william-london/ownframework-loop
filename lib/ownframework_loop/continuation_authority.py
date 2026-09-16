"""Shared continuation-receipt authority for supervisor and dispatch.

The supervisor's ``continue_program`` writes durable receipts at::

    <run_dir>/continuations/<continuation_id>.json

``dispatch._repair_context_for_build`` must consult the ledger to decide
whether a BLOCKED ``BUILD_RECEIPT`` has a matching supported continuation
that funds a bounded product repair. This module is the single canonical
reader; both ``supervisor.continue_program`` and
``dispatch._repair_context_for_build`` consult it so that BLOCKED-receipt
authority transport cannot drift between writer and reader.

A BLOCKED ``BUILD_RECEIPT`` by itself is **not** authority to run another
build. Authority is established only by a supported continuation receipt:

  * exact run_id match;
  * exact checkpoint_id match;
  * exact candidate_sha match (or active_candidate_sha fallback);
  * exact ``after.repair_round`` equals current state ``repair_round``;
  * candidate_branch match (when the receipt carries one);
  * status in {FUNDED, QUEUED, PENDING} — i.e. the continuation has been
    durably funded through the supported lifecycle.

If evidence is missing / stale / contradictory / ambiguous, the helpers
return ``None`` so the caller fails closed without the deterministic
transport.
"""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Any

from . import state as state_mod


SCHEMA = "ownframework-loop-program-continuation/v1"

# A continuation receipt can take several lifecycle states. The
# supervisor's ``continue_program`` writes the receipt with status="QUEUED";
# it stays QUEUED until the dispatcher reclaims the run. We accept any
# state that proves the continuation has been funded through the supported
# lifecycle, because the receipt itself — not its current status — is the
# authority for the BLOCKED repair transport.
_FUNDED_STATES = frozenset({"PENDING", "FUNDED", "QUEUED", "ACTIVE"})


def continuation_directory(canonical_repo: Path, run_id: str) -> Path:
    """Return the durable continuation-receipt directory."""
    return state_mod.run_dir(canonical_repo, run_id) / "continuations"


def derive_continuation_id(
    run_id: str,
    checkpoint_id: str,
    candidate_sha: str,
    reason: str,
) -> str:
    """Hash run/checkpoint/candidate/reason to the deterministic continuation id.

    This MUST stay in lockstep with ``supervisor._continuation_id`` so the
    ledger on disk and the in-process computation agree. We re-implement the
    same algorithm here only to keep dispatch free of the supervisor import;
    the canonical writer (``supervisor.continue_program``) continues to own
    the contract.
    """
    body = "\x00".join((run_id, checkpoint_id, candidate_sha, reason))
    return hashlib.sha256(body.encode("utf-8")).hexdigest()[:32]


def _read_receipt(path: Path) -> dict[str, Any] | None:
    try:
        import json
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, dict) else None


def _receipt_is_relevant(
    receipt: dict[str, Any],
    *,
    run_id: str,
    checkpoint_id: str,
    candidate_sha: str,
    candidate_branch: str,
    current_repair_round: int,
) -> bool:
    if str(receipt.get("schema") or "") != SCHEMA:
        return False
    if str(receipt.get("run_id") or "") != run_id:
        return False
    if str(receipt.get("checkpoint_id") or "") != checkpoint_id:
        return False
    after = receipt.get("after")
    if not isinstance(after, dict):
        return False
    try:
        receipt_after_repair_round = int(after.get("repair_round") or 0)
    except (TypeError, ValueError):
        return False
    if receipt_after_repair_round != int(current_repair_round):
        return False
    receipt_candidate = str(receipt.get("candidate_sha") or "")
    receipt_active = str(receipt.get("active_candidate_sha") or "")
    if (
        receipt_candidate != candidate_sha
        and receipt_active != candidate_sha
    ):
        return False
    receipt_branch = str(receipt.get("candidate_branch") or "")
    if receipt_branch and candidate_branch and receipt_branch != candidate_branch:
        return False
    if str(receipt.get("status") or "") not in _FUNDED_STATES:
        return False
    return True


def find_supported_for_blocked_repair(
    *,
    canonical_repo: Path,
    run_id: str,
    state_doc: dict[str, Any],
) -> dict[str, Any] | None:
    """Return the unique supported continuation backing a BLOCKED repair.

    Fail closed. Returns ``None`` when:

    * no continuation receipt directory exists;
    * no candidate checkpoint is in scope (``current_checkpoints`` empty);
    * no funded continuation matches the run/checkpoint/candidate/round tuple;
    * multiple matching continuations are present (ambiguity is unsafe).

    The chosen continuation is the most-recently-written matching receipt
    ONLY when the set of matching receipts is unambiguous (length == 1).
    """
    state_program = state_doc.get("program") or {}
    current_checkpoints = state_program.get("current_checkpoints") or []
    if not current_checkpoints:
        return None
    checkpoint_id = str(current_checkpoints[0])

    state_after = state_doc.get("repair_round")
    try:
        current_repair_round = int(state_after or 0)
    except (TypeError, ValueError):
        return None
    if current_repair_round <= 0:
        return None

    candidate_sha = str(state_doc.get("last_candidate_sha") or "")
    if not candidate_sha:
        return None

    candidate_branch = ""
    source_provenance = state_program.get("source_sha_provenance") or {}
    if isinstance(source_provenance, dict):
        candidate_branch = str(source_provenance.get("candidate_branch") or "")

    directory = continuation_directory(canonical_repo, run_id)
    if not directory.is_dir():
        return None

    matches: list[dict[str, Any]] = []
    for path in sorted(directory.glob("*.json")):
        receipt = _read_receipt(path)
        if not isinstance(receipt, dict):
            continue
        if _receipt_is_relevant(
            receipt,
            run_id=run_id,
            checkpoint_id=checkpoint_id,
            candidate_sha=candidate_sha,
            candidate_branch=candidate_branch,
            current_repair_round=current_repair_round,
        ):
            matches.append(receipt)

    if len(matches) != 1:
        # Multiple matching receipts are an authority conflict; do not
        # let the dispatcher pick an arbitrary one. Fail closed.
        return None
    return matches[0]
