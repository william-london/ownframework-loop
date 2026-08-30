"""State file operations under flock — load, transition, append events."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
from typing import Any

from .locking import flock_exclusive
from . import transitions
from .util import (
    atomic_write_json, read_json, run_dir, utc_now_iso, ensure_mode,
    fsync_dir,
)
from . import integrity
from . import limits as limits_mod

import re

_RUN_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")


def validate_run_id(run_id: object) -> str:
    """Validate a run_id is a safe identifier for filesystem and git ref use.

    Rejects:
      - non-strings
      - empty strings
      - path traversal (`.`, `..`, `/`, `\\`)
      - leading separators or dots
      - control characters and NUL
      - names longer than 64 chars
      - names that begin with `-` (option-injection)

    Returns the validated run_id unchanged on success. Raises ValueError
    on any failure so callers MUST handle the refusal (fail closed).
    """
    if not isinstance(run_id, str):
        raise ValueError(f"invalid run_id: not a string ({type(run_id).__name__})")
    if not run_id:
        raise ValueError("invalid run_id: empty")
    if any(ch in run_id for ch in ("/", "\\", "\x00")):
        raise ValueError(f"invalid run_id: path separator or NUL in {run_id!r}")
    if run_id in (".", "..") or run_id.startswith((".", "-")):
        raise ValueError(f"invalid run_id: leading dot or dash in {run_id!r}")
    if not _RUN_ID_RE.match(run_id):
        raise ValueError(f"invalid run_id: must match ^[A-Za-z0-9][A-Za-z0-9._-]{{0,63}}$ — got {run_id!r}")
    return run_id


SCHEMA_VERSION = "ownframework-loop-state/v1"
PROGRAM_STATE_SCHEMA_VERSION = "ownframework-loop-state/v2"
SUPPORTED_STATE_SCHEMA_VERSIONS = (SCHEMA_VERSION, PROGRAM_STATE_SCHEMA_VERSION)
STATE_TXN_SCHEMA_VERSION = "ownframework-loop-state-txn/v1"
_EVENT_RESERVED_FIELDS = frozenset({
    "ts", "run_id", "event_type", "old_state", "new_state", "actor",
    "commit_sha", "reason", "state_sha256", "event_chain_sha256",
})


def state_path(canonical_repo: Path, run_id: str) -> Path:
    return run_dir(canonical_repo, run_id) / "STATE.json"


def events_path(canonical_repo: Path, run_id: str) -> Path:
    return run_dir(canonical_repo, run_id) / "EVENTS.log"


def lock_path(canonical_repo: Path, run_id: str) -> Path:
    return run_dir(canonical_repo, run_id) / "LOCK"


def stop_path(canonical_repo: Path, run_id: str) -> Path:
    return run_dir(canonical_repo, run_id) / "STOP"


def state_txn_path(canonical_repo: Path, run_id: str) -> Path:
    """Transient write-ahead intent for one STATE/EVENTS atomic commit."""
    return run_dir(canonical_repo, run_id) / "STATE_TXN.json"


def initial_state(run_id: str) -> dict[str, Any]:
    """Return a fresh initial state document (AWAITING_APPROVAL)."""
    now = utc_now_iso()
    return {
        "schema": SCHEMA_VERSION,
        "run_id": run_id,
        "state": "AWAITING_APPROVAL",
        "state_history": [
            {"from": "", "to": "AWAITING_APPROVAL", "at": now, "actor": "spec", "reason": "run created"}
        ],
        "transitions_count": 0,
        "build_pass_count": 0,
        "review_pass_count": 0,
        "repair_round": 0,
        "no_progress_streak": 0,
        "started_at": now,
        "updated_at": now,
        "last_actor": "spec",
        "terminal_reason": "",
        "last_candidate_sha": "",
    }


def load(canonical_repo: Path, run_id: str) -> dict[str, Any] | None:
    """Load authoritative state with crash recovery and SHA verification.

    Raw, unverified STATE.json reads are not a public authority surface.  If a
    prior Loop-owned state/event commit was interrupted, the write-ahead intent
    is recovered first under the run flock.  Any mismatch not explained by that
    exact intent remains a tampering failure.
    """
    sp = state_path(canonical_repo, run_id)
    if state_txn_path(canonical_repo, run_id).exists():
        recover_pending_state_transaction(canonical_repo, run_id)
    if not sp.exists():
        return None
    ep = events_path(canonical_repo, run_id)
    ok, msg = integrity.verify_state_sha(sp, ep)
    if not ok:
        raise integrity.TamperingDetected(msg)
    payload = read_json(sp, default=None)
    if not isinstance(payload, dict):
        raise integrity.TamperingDetected(f"STATE.json unreadable or non-object for run {run_id}")
    return payload


def load_verified(canonical_repo: Path, run_id: str) -> dict[str, Any]:
    """Compatibility alias for the verified authoritative state loader."""
    return load(canonical_repo, run_id) or {}


def _state_payload_bytes(payload: dict[str, Any]) -> bytes:
    # Must match util.atomic_write_json byte-for-byte.
    return json.dumps(payload, indent=2, sort_keys=True).encode("utf-8")


def _state_payload_sha256(payload: dict[str, Any]) -> str:
    return hashlib.sha256(_state_payload_bytes(payload)).hexdigest()


def _validate_event_extras(extras: dict[str, Any] | None) -> None:
    if not extras:
        return
    overlap = _EVENT_RESERVED_FIELDS.intersection(extras)
    if overlap:
        raise ValueError(
            "event extras may not override authoritative fields: "
            + ", ".join(sorted(overlap))
        )


def _build_event_line(
    *,
    previous_chain: str,
    state_sha_now: str | None,
    run_id: str,
    event_type: str,
    old_state: str | None,
    new_state: str | None,
    actor: str,
    commit_sha: str | None = None,
    reason: str | None = None,
    extras: dict[str, Any] | None = None,
    ts: str | None = None,
) -> str:
    """Build the exact canonical event line before any authoritative write."""
    _validate_event_extras(extras)
    record: dict[str, Any] = {
        "ts": ts or utc_now_iso(),
        "run_id": run_id,
        "event_type": event_type,
        "old_state": old_state,
        "new_state": new_state,
        "actor": actor,
        "commit_sha": commit_sha,
        "reason": reason,
        "state_sha256": state_sha_now,
        "event_chain_sha256": "0" * 64,
    }
    if extras:
        record.update(extras)
    stripped = {k: v for k, v in record.items() if k != "event_chain_sha256"}
    h = hashlib.sha256()
    h.update((previous_chain or "").encode("utf-8"))
    h.update(integrity.canonical_json_dumps(stripped).encode("utf-8"))
    record["event_chain_sha256"] = h.hexdigest()
    return _json_dumps(record)


def _atomic_append_exact_event_locked(ep: Path, line: str) -> None:
    """Atomically replace EVENTS.log with prior bytes plus exactly one line.

    Caller MUST hold the run flock.  Rewriting the modest per-run log through a
    fsynced temp + replace makes a crash observe either the old complete log or
    the new complete log, never a malformed partial JSON line.
    """
    ep.parent.mkdir(parents=True, exist_ok=True)
    prior = ep.read_bytes() if ep.exists() else b""
    suffix = (line + "\n").encode("utf-8")
    tmp = ep.parent / f".{ep.name}.tmp.{os.getpid()}"
    with open(tmp, "wb") as fh:
        fh.write(prior)
        fh.write(suffix)
        fh.flush()
        try:
            os.fsync(fh.fileno())
        except OSError:
            pass
    os.replace(tmp, ep)
    ensure_mode(ep, 0o600)
    try:
        fsync_dir(ep.parent)
    except OSError:
        pass


def _state_txn_payload_locked(
    canonical_repo: Path,
    run_id: str,
    *,
    new_state_payload: dict[str, Any],
    event_type: str,
    old_state: str | None,
    new_state: str | None,
    actor: str,
    commit_sha: str | None = None,
    reason: str | None = None,
    extras: dict[str, Any] | None = None,
) -> dict[str, Any]:
    sp = state_path(canonical_repo, run_id)
    ep = events_path(canonical_repo, run_id)
    old_state_sha = integrity.sha256_file(sp) if sp.exists() else ""
    old_event_chain = integrity.get_event_chain_hash(ep) or ""
    old_event_size = ep.stat().st_size if ep.exists() else 0
    new_state_sha = _state_payload_sha256(new_state_payload)
    event_line = _build_event_line(
        previous_chain=old_event_chain,
        state_sha_now=new_state_sha,
        run_id=run_id,
        event_type=event_type,
        old_state=old_state,
        new_state=new_state,
        actor=actor,
        commit_sha=commit_sha,
        reason=reason,
        extras=extras,
    )
    return {
        "schema": STATE_TXN_SCHEMA_VERSION,
        "run_id": run_id,
        "old_state_sha256": old_state_sha,
        "new_state_sha256": new_state_sha,
        "old_event_chain_sha256": old_event_chain,
        "old_event_size": int(old_event_size),
        "new_state": new_state_payload,
        "event_line": event_line,
        "created_at": utc_now_iso(),
    }


def _recover_pending_state_transaction_locked(
    canonical_repo: Path,
    run_id: str,
) -> bool:
    """Finish one exact Loop-owned torn STATE/EVENTS commit, or fail closed."""
    tp = state_txn_path(canonical_repo, run_id)
    if not tp.exists():
        return False
    try:
        txn = json.loads(tp.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise integrity.TamperingDetected(
            f"pending state transaction unreadable for {run_id}: {exc}"
        ) from exc
    if not isinstance(txn, dict) or txn.get("schema") != STATE_TXN_SCHEMA_VERSION:
        raise integrity.TamperingDetected("pending state transaction schema mismatch")
    if txn.get("run_id") != run_id:
        raise integrity.TamperingDetected("pending state transaction run_id mismatch")
    new_payload = txn.get("new_state")
    event_line = txn.get("event_line")
    if not isinstance(new_payload, dict) or not isinstance(event_line, str):
        raise integrity.TamperingDetected("pending state transaction payload malformed")

    old_state_sha = str(txn.get("old_state_sha256") or "")
    new_state_sha = str(txn.get("new_state_sha256") or "")
    if _state_payload_sha256(new_payload) != new_state_sha:
        raise integrity.TamperingDetected("pending state transaction new-state digest mismatch")

    sp = state_path(canonical_repo, run_id)
    ep = events_path(canonical_repo, run_id)
    current_state_sha = integrity.sha256_file(sp) if sp.exists() else ""
    if current_state_sha not in {old_state_sha, new_state_sha}:
        raise integrity.TamperingDetected(
            "STATE.json is neither the pre-commit nor intended post-commit bytes"
        )

    try:
        old_event_size = int(txn.get("old_event_size"))
    except (TypeError, ValueError) as exc:
        raise integrity.TamperingDetected("pending state transaction event size malformed") from exc
    old_chain = str(txn.get("old_event_chain_sha256") or "")
    event_bytes = (event_line + "\n").encode("utf-8")
    data = ep.read_bytes() if ep.exists() else b""

    event_committed = False
    if len(data) == old_event_size:
        actual_old_chain = integrity.compute_event_chain_hash(ep) if data else ""
        if actual_old_chain != old_chain:
            raise integrity.TamperingDetected(
                "EVENTS.log pre-transaction chain/size does not match pending intent"
            )
    elif (
        len(data) == old_event_size + len(event_bytes)
        and data[old_event_size:] == event_bytes
    ):
        expected_chain = str(json.loads(event_line).get("event_chain_sha256") or "")
        actual_chain = integrity.compute_event_chain_hash(ep)
        if not expected_chain or actual_chain != expected_chain:
            raise integrity.TamperingDetected(
                "EVENTS.log committed transaction line has invalid chain"
            )
        event_committed = True
    else:
        raise integrity.TamperingDetected(
            "EVENTS.log bytes are not explained by the pending state transaction"
        )

    if event_committed:
        if current_state_sha != new_state_sha:
            raise integrity.TamperingDetected(
                "transaction event committed without intended STATE.json bytes"
            )
    else:
        if current_state_sha != new_state_sha:
            atomic_write_json(sp, new_payload, mode=0o600)
        _atomic_append_exact_event_locked(ep, event_line)

    ok, msg = integrity.verify_state_sha(sp, ep)
    if not ok:
        raise integrity.TamperingDetected(
            f"recovered state transaction failed final state binding: {msg}"
        )
    recorded = integrity.get_event_chain_hash(ep)
    actual = integrity.compute_event_chain_hash(ep)
    if not recorded or recorded != actual:
        raise integrity.TamperingDetected(
            "recovered state transaction failed final event-chain verification"
        )

    try:
        tp.unlink()
        fsync_dir(tp.parent)
    except FileNotFoundError:
        pass
    except OSError:
        # The authoritative commit is already complete.  A stale intent is
        # harmless and will be re-proven/cleaned on the next read.
        pass
    return True


def recover_pending_state_transaction(
    canonical_repo: Path,
    run_id: str,
) -> bool:
    """Recover a pending state transaction under the authoritative run flock."""
    with flock_exclusive(lock_path(canonical_repo, run_id)):
        return _recover_pending_state_transaction_locked(canonical_repo, run_id)


def _commit_state_event_locked(
    canonical_repo: Path,
    run_id: str,
    *,
    new_state_payload: dict[str, Any],
    event_type: str,
    old_state: str | None,
    new_state: str | None,
    actor: str,
    commit_sha: str | None = None,
    reason: str | None = None,
    extras: dict[str, Any] | None = None,
) -> None:
    """Write-ahead, then commit STATE.json + matching event under one flock."""
    tp = state_txn_path(canonical_repo, run_id)
    txn = _state_txn_payload_locked(
        canonical_repo,
        run_id,
        new_state_payload=new_state_payload,
        event_type=event_type,
        old_state=old_state,
        new_state=new_state,
        actor=actor,
        commit_sha=commit_sha,
        reason=reason,
        extras=extras,
    )
    atomic_write_json(tp, txn, mode=0o600)
    atomic_write_json(state_path(canonical_repo, run_id), new_state_payload, mode=0o600)
    _atomic_append_exact_event_locked(events_path(canonical_repo, run_id), txn["event_line"])
    try:
        tp.unlink()
        fsync_dir(tp.parent)
    except FileNotFoundError:
        pass
    except OSError:
        # Leave the fully described intent behind; verified load will prove the
        # completed commit and clean it later.
        pass


def _verify_mutation_integrity_locked(canonical_repo: Path, run_id: str) -> None:
    """Fail closed before extending or mutating authoritative state history.

    Caller MUST hold the per-run flock. Both the existing event-chain tail and
    the STATE.json SHA binding are proven before any new write can bless current
    bytes as authoritative. This prevents a later ordinary event/state update
    from laundering prior tampering into a fresh trusted chain tail.
    """
    sp = state_path(canonical_repo, run_id)
    ep = events_path(canonical_repo, run_id)

    # A previous Loop-owned commit may have died after durable intent but
    # before both authoritative files converged. Recover only that exact intent.
    _recover_pending_state_transaction_locked(canonical_repo, run_id)

    if ep.exists():
        events = integrity.read_event_chain(ep)
        if events:
            recorded = integrity.get_event_chain_hash(ep)
            actual = integrity.compute_event_chain_hash(ep)
            if not recorded or recorded != actual:
                raise integrity.TamperingDetected(
                    "event chain integrity mismatch before state mutation"
                )

    if sp.exists() or ep.exists():
        ok, msg = integrity.verify_state_sha(sp, ep)
        if not ok:
            raise integrity.TamperingDetected(
                f"state integrity mismatch before mutation: {msg}"
            )


def save(canonical_repo: Path, run_id: str, payload: dict[str, Any]) -> None:
    """Persist state under flock with a recoverable matching state_saved event."""
    actor = str(payload.get("last_actor", "spec"))
    sp = state_path(canonical_repo, run_id)
    with flock_exclusive(lock_path(canonical_repo, run_id)):
        _verify_mutation_integrity_locked(canonical_repo, run_id)
        old = read_json(sp, default={}) if sp.exists() else {}
        _commit_state_event_locked(
            canonical_repo,
            run_id,
            new_state_payload=payload,
            event_type="state_saved",
            old_state=(old or {}).get("state") or payload.get("state"),
            new_state=payload.get("state"),
            actor=actor,
            commit_sha=payload.get("last_candidate_sha"),
            reason="non-transition state save",
        )
    try:
        fsync_dir(sp.parent)
    except OSError:
        pass


def _locked_state(canonical_repo: Path, run_id: str):
    """Context manager: hold flock, yield current STATE.json.

    Used by the unified PROGRAM claim (`program._unified_claim_pass`) to
    perform validation, mutation, and persistence under one flock so the
    per-cp counter, cumulative counter, and top-level mirror cannot
    desync on a crash between reads and writes.
    """
    import contextlib

    @contextlib.contextmanager
    def _ctx():
        with flock_exclusive(lock_path(canonical_repo, run_id)):
            _verify_mutation_integrity_locked(canonical_repo, run_id)
            cur = read_json(state_path(canonical_repo, run_id))
            yield cur
    return _ctx()


def _write_state_locked(
    canonical_repo: Path,
    run_id: str,
    payload: dict[str, Any],
) -> None:
    """Persist STATE.json + state_saved event transactionally under an existing flock."""
    actor = str(payload.get("last_actor", "spec"))
    _commit_state_event_locked(
        canonical_repo,
        run_id,
        new_state_payload=payload,
        event_type="state_saved",
        old_state=payload.get("state"),
        new_state=payload.get("state"),
        actor=actor,
        commit_sha=payload.get("last_candidate_sha"),
        reason="program_claim_unified_save",
    )


def _append_event_locked(
    canonical_repo: Path,
    run_id: str,
    *,
    event_type: str,
    old_state: str | None,
    new_state: str | None,
    actor: str,
    commit_sha: str | None = None,
    reason: str | None = None,
    extras: dict[str, Any] | None = None,
) -> None:
    """Append one canonical event atomically WITHOUT acquiring the flock."""
    sp = state_path(canonical_repo, run_id)
    ep = events_path(canonical_repo, run_id)
    previous_chain = integrity.get_event_chain_hash(ep) or ""
    state_sha_now = integrity.sha256_file(sp) if sp.exists() else None
    line = _build_event_line(
        previous_chain=previous_chain,
        state_sha_now=state_sha_now,
        run_id=run_id,
        event_type=event_type,
        old_state=old_state,
        new_state=new_state,
        actor=actor,
        commit_sha=commit_sha,
        reason=reason,
        extras=extras,
    )
    _atomic_append_exact_event_locked(ep, line)


def append_event(
    canonical_repo: Path,
    run_id: str,
    *,
    event_type: str,
    old_state: str | None,
    new_state: str | None,
    actor: str,
    commit_sha: str | None = None,
    reason: str | None = None,
    extras: dict[str, Any] | None = None,
) -> None:
    """Atomically append a verified event under the per-run flock."""
    with flock_exclusive(lock_path(canonical_repo, run_id)):
        _verify_mutation_integrity_locked(canonical_repo, run_id)
        _append_event_locked(
            canonical_repo,
            run_id,
            event_type=event_type,
            old_state=old_state,
            new_state=new_state,
            actor=actor,
            commit_sha=commit_sha,
            reason=reason,
            extras=extras,
        )


def transition(
    canonical_repo: Path,
    run_id: str,
    *,
    to_state: str,
    actor: str,
    reason: str | None = None,
    commit_sha: str | None = None,
    extras: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Transition authoritative state with a crash-recoverable matching event."""
    sp = state_path(canonical_repo, run_id)
    with flock_exclusive(lock_path(canonical_repo, run_id)):
        _verify_mutation_integrity_locked(canonical_repo, run_id)
        current = read_json(sp)
        if current is None or current == {}:
            raise FileNotFoundError(f"STATE.json missing for run {run_id}")
        from_state = current["state"]
        transitions.assert_valid(from_state, to_state)

        now = utc_now_iso()
        new = dict(current)
        new["state"] = to_state
        new["transitions_count"] = int(current.get("transitions_count", 0)) + 1
        new["updated_at"] = now
        new["last_actor"] = actor
        if commit_sha:
            new["last_candidate_sha"] = commit_sha
        if to_state in ("APPROVED", "BLOCKED", "STOPPED"):
            new["terminal_reason"] = reason
        history = list(current.get("state_history", []))
        history.append({"from": from_state, "to": to_state, "at": now, "actor": actor, "reason": reason})
        new["state_history"] = history
        if extras:
            new.update(extras)

        _commit_state_event_locked(
            canonical_repo,
            run_id,
            new_state_payload=new,
            event_type="state_transition",
            old_state=from_state,
            new_state=to_state,
            actor=actor,
            commit_sha=commit_sha,
            reason=reason,
        )
    try:
        fsync_dir(sp.parent)
    except OSError:
        pass
    return new


def increment_counter(
    canonical_repo: Path,
    run_id: str,
    *,
    counter: str,
    actor: str,
    packet: dict[str, Any] | None = None,
    hard_cap: bool = True,
) -> int:
    """Increment a top-level integer counter with a recoverable matching event."""
    sp = state_path(canonical_repo, run_id)
    with flock_exclusive(lock_path(canonical_repo, run_id)):
        _verify_mutation_integrity_locked(canonical_repo, run_id)
        current = read_json(sp)
        if current is None or current == {}:
            raise FileNotFoundError(f"STATE.json missing for run {run_id}")
        if hard_cap:
            limits_mod.enforce(counter, int(current.get(counter, 0) or 0), packet)
        new = dict(current)
        new[counter] = int(current.get(counter, 0)) + 1
        new["updated_at"] = utc_now_iso()
        new["last_actor"] = actor
        _commit_state_event_locked(
            canonical_repo,
            run_id,
            new_state_payload=new,
            event_type="counter_incremented",
            old_state=None,
            new_state=None,
            actor=actor,
            commit_sha=None,
            reason=None,
            extras={
                "counter": counter,
                "new_value": new[counter],
                "cap": limits_mod.effective_cap(counter, packet),
            },
        )
    return new[counter]


def current_counter(canonical_repo: Path, run_id: str, counter: str) -> int | None:
    s = load(canonical_repo, run_id)
    if not s:
        return None
    return int(s.get(counter, 0))


def request_stop(canonical_repo: Path, run_id: str, *, reason: str, actor: str = "human") -> None:
    """Create a STOP file and record an event."""
    sp = stop_path(canonical_repo, run_id)
    sp.parent.mkdir(parents=True, exist_ok=True)
    sp.write_text(f"stopped_at={utc_now_iso()}\nreason={reason}\nactor={actor}\n", encoding="utf-8")
    ensure_mode(sp, 0o600)
    append_event(
        canonical_repo, run_id,
        event_type="stop_requested",
        old_state=None, new_state=None,
        actor=actor, commit_sha=None, reason=reason,
    )


def is_stop_requested(canonical_repo: Path, run_id: str) -> bool:
    return stop_path(canonical_repo, run_id).exists()


def program_transition(
    canonical_repo: Path,
    run_id: str,
    *,
    to_state: str,
    actor: str,
    reason: str | None = None,
    commit_sha: str | None = None,
    extras: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Atomic PROGRAM-mode state transition + event append under one flock.

    v0.3.5 (A1-001/A1-004/A1-005): the program-mode orchestrator no
    longer bypasses the FSM via state_mod.save(). Every orchestrator-
    initiated state transition goes through this function, which:

      1. Acquires the per-run flock.
      2. Reads STATE.json.
      3. Validates against the program-mode FSM
         (transitions.assert_valid_program).
      4. Persists STATE.json atomically.
      5. Appends the state_transition event with chain hash INSIDE
         the same flock (using _append_event_locked).
      6. Releases the flock.

    The single-mode FSM table is consulted first; program-mode
    escape hatches (APPROVED/BLOCKED -> READY_TO_BUILD) are permitted
    ONLY when the run has more claimable checkpoints. Once the
    program is fully terminated, this function falls back to
    transitions.assert_valid behavior (terminal states cannot be left).

    Use this function instead of state_mod.save() when changing the
    top-level `state` field. For purely field updates that do NOT
    change `state` (e.g., bumping the `schema` version or writing a
    new `program` sub-object after a finalize_checkpoint call that
    did NOT change `state`), use state_mod.save() directly.

    Returns the new state document.
    """
    sp = state_path(canonical_repo, run_id)
    ep = events_path(canonical_repo, run_id)
    lp = lock_path(canonical_repo, run_id)

    with flock_exclusive(lp):
        # Verify under the same flock that owns the subsequent read/write.
        _verify_mutation_integrity_locked(canonical_repo, run_id)
        current = read_json(sp)
        if current is None or current == {}:
            raise FileNotFoundError(
                f"STATE.json missing for run {run_id}"
            )
        from_state = current["state"]
        # Determine whether the destination PROGRAM graph still has work.
        # When a transition atomically carries a replacement program block
        # (for example review approval finalizing CP-1 and selecting CP-2),
        # validate against that prospective block rather than the stale
        # pre-transition one.
        has_more_cps = False
        prospective_program = (
            extras.get("program")
            if isinstance(extras, dict) and isinstance(extras.get("program"), dict)
            else current.get("program")
        )
        prog = prospective_program
        if isinstance(prog, dict):
            # v0.3.7 (F-1-01): finalize_checkpoint() stores entries as
            # dicts ({"id": cp_id, ...}). The previous code called
            # set() directly on dict entries (TypeError); a bare
            # `except Exception` then forced has_more_cps=False and
            # broke the program-mode APPROVED -> READY_TO_BUILD
            # escape hatch after the first checkpoint. Extract IDs
            # explicitly and never swallow malformed evidence.
            finalized: set[str] = set()
            for fc in prog.get("finalized_checkpoints") or []:
                if isinstance(fc, dict):
                    cid = fc.get("id")
                    if isinstance(cid, str):
                        finalized.add(cid)
            pp = canonical_repo / ".ownframework-loop" / run_id / "WORK_PACKET.md"
            order: list[str] = []
            if pp.exists():
                from . import packet as _packet_mod
                _meta, _ = _packet_mod.parse_packet_file(pp)
                cg = (_meta or {}).get("checkpoint_graph") or {}
                order = list(cg.get("execution_order") or [])
            if order:
                has_more_cps = any(
                    cid not in finalized for cid in order
                )
        # v0.3.7 (F-2-03): bind the transition to the exact candidate SHA.
        # If a commit_sha was provided and it differs from the run's bound
        # candidate (`last_candidate_sha`), refuse the transition. This
        # prevents a stale or overwritten candidate from being re-approved
        # across the TOCTOU window between review verdict commit and the
        # state transition. The transitions.assert_valid_program keyword
        # is also accepted (see transitions.py:135) for callers that want
        # to plumb the bound explicitly.
        if commit_sha and current.get("last_candidate_sha") and commit_sha != current["last_candidate_sha"]:
            raise transitions.InvalidTransitionError(
                f"bound_candidate_sha mismatch: provided={commit_sha[:12]} "
                f"last={current['last_candidate_sha'][:12]}"
            )
        transitions.assert_valid_program(
            from_state, to_state,
            has_more_checkpoints=has_more_cps,
            bound_candidate_sha=commit_sha or None,
        )

        now = utc_now_iso()
        new = dict(current)
        new["state"] = to_state
        new["transitions_count"] = int(current.get("transitions_count", 0)) + 1
        new["updated_at"] = now
        new["last_actor"] = actor
        if commit_sha:
            new["last_candidate_sha"] = commit_sha
        if to_state in ("APPROVED", "BLOCKED", "STOPPED"):
            new["terminal_reason"] = reason
        history = list(current.get("state_history", []))
        history.append({
            "from": from_state, "to": to_state, "at": now,
            "actor": actor, "reason": reason,
        })
        new["state_history"] = history
        if extras:
            new.update(extras)

        _commit_state_event_locked(
            canonical_repo,
            run_id,
            new_state_payload=new,
            event_type="state_transition",
            old_state=from_state,
            new_state=to_state,
            actor=actor,
            commit_sha=commit_sha,
            reason=reason,
        )

    try:
        fsync_dir(sp.parent)
    except OSError:
        pass
    return new


def _json_dumps(obj: Any) -> str:
    """Canonical JSON serialization for events.

    Delegates to integrity.canonical_json_dumps so the on-disk and
    recomputation paths use a single serializer. Both must produce
    identical bytes for the recorded event_chain_sha256 to verify.
    """
    return integrity.canonical_json_dumps(obj)


def _compute_chain_hash_for_append(
    ep: Path, line: str, state_sha_now: str | None
) -> str:
    """Return the iterative chain hash for the new event.

    chain_hash_n = SHA( chain_hash_(n-1) || event_n_minus_event_chain_sha256 )

    Reads the previous chain hash from the most recent event in ``ep``
    (or empty string if there are no prior events). Reconstructs the
    record from ``line`` (canonical JSON), strips ``event_chain_sha256``,
    and combines. The result is non-self-referential: it does NOT depend
    on its own value, so the verifier in
    ``integrity.compute_event_chain_hash`` recomputes the same bytes.
    """
    # Locate the previous chain hash from the on-disk tail.
    prev_chain = ""
    # STRICT: malformed/tampered prior history must propagate. Resetting to an
    # empty chain root would bless corrupted history with a fresh valid tail.
    prev = integrity.get_event_chain_hash(ep)
    if prev:
        prev_chain = prev

    # This line is produced by our own canonical serializer. If it cannot be
    # decoded, that is an internal invariant violation and must propagate.
    record = json.loads(line)
    stripped = {k: v for k, v in record.items() if k != "event_chain_sha256"}
    payload = integrity.canonical_json_dumps(stripped).encode("utf-8")

    h = hashlib.sha256()
    h.update(prev_chain.encode("utf-8"))
    h.update(payload)
    return h.hexdigest()



def is_program_state(s: dict[str, Any] | None) -> bool:
    """True iff state has a `program` object (v2 program-mode)."""
    return isinstance(s, dict) and isinstance(s.get("program"), dict)


def require_program_state(s: dict[str, Any] | None) -> dict[str, Any]:
    """Return the `program` object or raise.

    Use this BEFORE any program-state mutation so callers don't have to
    remember the v2 vs v1 distinction.
    """
    if not is_program_state(s):
        raise RuntimeError(
            "program state required (v2 with `program` key); "
            f"got schema={s.get('schema') if s else None!r}"
        )
    return s["program"]


def program_state_path(canonical_repo: Path, run_id: str) -> Path:
    """Convenience path (no separate file)."""
    return state_path(canonical_repo, run_id)
