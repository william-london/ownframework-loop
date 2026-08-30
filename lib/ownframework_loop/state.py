"""State file operations under flock — load, transition, append events."""

from __future__ import annotations

import hashlib
import json
import os
import uuid
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


def state_path(canonical_repo: Path, run_id: str) -> Path:
    return run_dir(canonical_repo, run_id) / "STATE.json"


def events_path(canonical_repo: Path, run_id: str) -> Path:
    return run_dir(canonical_repo, run_id) / "EVENTS.log"


def lock_path(canonical_repo: Path, run_id: str) -> Path:
    return run_dir(canonical_repo, run_id) / "LOCK"


def stop_path(canonical_repo: Path, run_id: str) -> Path:
    return run_dir(canonical_repo, run_id) / "STOP"


STATE_TXN_SCHEMA = "ownframework-loop-state-txn/v1"


def state_txn_path(canonical_repo: Path, run_id: str) -> Path:
    """Write-ahead intent for one STATE.json + EVENTS.log transaction."""
    return run_dir(canonical_repo, run_id) / "STATE_TXN.json"


def _state_payload_sha(payload: dict[str, Any]) -> str:
    """SHA of the exact bytes atomic_write_json() persists for state."""
    raw = json.dumps(payload, indent=2, sort_keys=True).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()


def _clear_state_txn_locked(canonical_repo: Path, run_id: str) -> None:
    tp = state_txn_path(canonical_repo, run_id)
    try:
        tp.unlink()
    except FileNotFoundError:
        return
    try:
        fsync_dir(tp.parent)
    except OSError:
        pass


def _recover_pending_state_txn_locked(
    canonical_repo: Path,
    run_id: str,
) -> str | None:
    """Finish or clear one proven write-ahead state transaction.

    Caller MUST hold the per-run flock. Recovery is deliberately narrow:
    the journal must bind the exact prior STATE SHA and exact prior event-chain
    tail. Any unrelated state/event mismatch is still tampering and fails
    closed; this mechanism only heals a transaction that this runtime durably
    declared before the crash.
    """
    tp = state_txn_path(canonical_repo, run_id)
    if not tp.exists():
        return None
    try:
        with tp.open("r", encoding="utf-8") as f:
            txn = json.load(f)
    except (OSError, json.JSONDecodeError) as exc:
        raise integrity.TamperingDetected(
            f"pending state transaction is unreadable: {exc}"
        ) from exc
    if not isinstance(txn, dict) or txn.get("schema") != STATE_TXN_SCHEMA:
        raise integrity.TamperingDetected("pending state transaction schema mismatch")
    if txn.get("run_id") != run_id:
        raise integrity.TamperingDetected("pending state transaction run_id mismatch")
    txn_id = str(txn.get("txn_id") or "")
    new_state = txn.get("new_state")
    event = txn.get("event")
    if not txn_id or not isinstance(new_state, dict) or not isinstance(event, dict):
        raise integrity.TamperingDetected("pending state transaction shape invalid")
    new_sha = str(txn.get("new_state_sha256") or "")
    if not new_sha or _state_payload_sha(new_state) != new_sha:
        raise integrity.TamperingDetected("pending state transaction payload SHA mismatch")

    sp = state_path(canonical_repo, run_id)
    ep = events_path(canonical_repo, run_id)
    events = integrity.read_event_chain(ep) if ep.exists() else []
    recorded_chain = integrity.get_event_chain_hash(ep) or ""
    actual_chain = integrity.compute_event_chain_hash(ep) if events else ""
    if recorded_chain != actual_chain:
        raise integrity.TamperingDetected(
            "event chain integrity mismatch while recovering state transaction"
        )

    current_sha = integrity.sha256_file(sp) if sp.exists() else ""
    last = events[-1] if events else None
    if isinstance(last, dict) and str(last.get("state_txn_id") or "") == txn_id:
        if current_sha != new_sha or str(last.get("state_sha256") or "") != new_sha:
            raise integrity.TamperingDetected(
                "completed state transaction does not bind the journaled state"
            )
        _clear_state_txn_locked(canonical_repo, run_id)
        return "cleared_completed_state_transaction"

    prior_chain = str(txn.get("prior_event_chain_sha256") or "")
    if recorded_chain != prior_chain:
        raise integrity.TamperingDetected(
            "pending state transaction prior event-chain binding mismatch"
        )
    prior_state_sha = str(txn.get("prior_state_sha256") or "")
    if current_sha == prior_state_sha:
        atomic_write_json(sp, new_state, mode=0o600)
        current_sha = integrity.sha256_file(sp)
    elif current_sha != new_sha:
        raise integrity.TamperingDetected(
            "pending state transaction prior state binding mismatch"
        )
    if current_sha != new_sha:
        raise integrity.TamperingDetected(
            "pending state transaction could not reproduce journaled state"
        )

    extras = dict(event.get("extras") or {})
    extras["state_txn_id"] = txn_id
    _append_event_locked(
        canonical_repo,
        run_id,
        event_type=str(event.get("event_type") or "state_saved"),
        old_state=event.get("old_state"),
        new_state=event.get("new_state"),
        actor=str(event.get("actor") or "unknown"),
        commit_sha=event.get("commit_sha"),
        reason=event.get("reason"),
        extras=extras,
    )
    _clear_state_txn_locked(canonical_repo, run_id)
    return "recovered_pending_state_transaction"


def recover_pending_state_transaction(
    canonical_repo: Path,
    run_id: str,
) -> str | None:
    """Public crash-recovery boundary used by reconciler/read paths."""
    with flock_exclusive(lock_path(canonical_repo, run_id)):
        return _recover_pending_state_txn_locked(canonical_repo, run_id)


def _commit_state_event_locked(
    canonical_repo: Path,
    run_id: str,
    payload: dict[str, Any],
    *,
    event_type: str,
    old_state: str | None,
    new_state: str | None,
    actor: str,
    commit_sha: str | None = None,
    reason: str | None = None,
    extras: dict[str, Any] | None = None,
) -> None:
    """Durably commit STATE.json + its binding event using write-ahead intent."""
    tp = state_txn_path(canonical_repo, run_id)
    if tp.exists():
        raise integrity.TamperingDetected(
            "pending state transaction exists after integrity recovery"
        )
    sp = state_path(canonical_repo, run_id)
    ep = events_path(canonical_repo, run_id)
    prior_state_sha = integrity.sha256_file(sp) if sp.exists() else ""
    prior_chain = integrity.get_event_chain_hash(ep) or ""
    txn_id = uuid.uuid4().hex
    journal = {
        "schema": STATE_TXN_SCHEMA,
        "run_id": run_id,
        "txn_id": txn_id,
        "prior_state_sha256": prior_state_sha,
        "prior_event_chain_sha256": prior_chain,
        "new_state_sha256": _state_payload_sha(payload),
        "new_state": payload,
        "event": {
            "event_type": event_type,
            "old_state": old_state,
            "new_state": new_state,
            "actor": actor,
            "commit_sha": commit_sha,
            "reason": reason,
            "extras": dict(extras or {}),
        },
    }
    atomic_write_json(tp, journal, mode=0o600)
    atomic_write_json(sp, payload, mode=0o600)
    actual_state_sha = integrity.sha256_file(sp)
    if actual_state_sha != journal["new_state_sha256"]:
        raise RuntimeError("STATE.json bytes do not match durable transaction intent")
    event_extras = dict(extras or {})
    event_extras["state_txn_id"] = txn_id
    _append_event_locked(
        canonical_repo,
        run_id,
        event_type=event_type,
        old_state=old_state,
        new_state=new_state,
        actor=actor,
        commit_sha=commit_sha,
        reason=reason,
        extras=event_extras,
    )
    _clear_state_txn_locked(canonical_repo, run_id)


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
    return read_json(state_path(canonical_repo, run_id))


def load_verified(canonical_repo: Path, run_id: str) -> dict[str, Any]:
    """Load one authoritative state snapshot under the run lock.

    A proven pending write-ahead transaction is completed first. The event
    chain and the final STATE SHA binding are then verified while the same
    flock is held, eliminating the verify-then-read race for authority-bearing
    callers.
    """
    sp = state_path(canonical_repo, run_id)
    ep = events_path(canonical_repo, run_id)
    with flock_exclusive(lock_path(canonical_repo, run_id)):
        _recover_pending_state_txn_locked(canonical_repo, run_id)
        if ep.exists():
            events = integrity.read_event_chain(ep)
            if events:
                recorded = integrity.get_event_chain_hash(ep)
                actual = integrity.compute_event_chain_hash(ep)
                if not recorded or recorded != actual:
                    raise integrity.TamperingDetected(
                        "event chain integrity mismatch while loading authoritative state"
                    )
        ok, msg = integrity.verify_state_sha(sp, ep)
        if not ok:
            raise integrity.TamperingDetected(msg)
        return read_json(sp, default={}) or {}


def _verify_mutation_integrity_locked(canonical_repo: Path, run_id: str) -> None:
    """Fail closed before extending or mutating authoritative state history.

    Caller MUST hold the per-run flock. Both the existing event-chain tail and
    the STATE.json SHA binding are proven before any new write can bless current
    bytes as authoritative. This prevents a later ordinary event/state update
    from laundering prior tampering into a fresh trusted chain tail.
    """
    sp = state_path(canonical_repo, run_id)
    ep = events_path(canonical_repo, run_id)

    # A journal is the only authority allowed to explain a torn STATE/EVENTS
    # pair. Complete that exact declared transaction before ordinary integrity
    # verification; arbitrary mismatches still fail closed below.
    _recover_pending_state_txn_locked(canonical_repo, run_id)

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
    """Persist state under flock and record an integrity event.

    `save()` is reserved for cases where the caller has computed a full new
    state object (e.g. updating counters, patching a field). It writes
    STATE.json atomically and appends a `state_saved` event so the SHA
    chain stays consistent for subsequent `transition()` / `save()` calls.
    """
    actor = str(payload.get("last_actor", "spec"))
    sp = state_path(canonical_repo, run_id)
    ep = events_path(canonical_repo, run_id)
    with flock_exclusive(lock_path(canonical_repo, run_id)):
        # Existing durable history must verify before it can be overwritten.
        # A brand-new run legitimately has neither STATE nor EVENTS yet.
        _verify_mutation_integrity_locked(canonical_repo, run_id)
        old = read_json(sp, default={}) if sp.exists() else {}
        _commit_state_event_locked(
            canonical_repo,
            run_id,
            payload,
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
    """Persist STATE.json and append a state_saved event under flock.

    Caller MUST already hold the flock (e.g. via `_locked_state`).
    Uses `_append_event_locked` to avoid re-entrant flock acquisition
    on the same LOCK file. The combined write keeps STATE.json and
    EVENTS.log consistent for downstream SHA chain verification.
    """
    actor = str(payload.get("last_actor", "spec"))
    _commit_state_event_locked(
        canonical_repo,
        run_id,
        payload,
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
    """Append a JSON Lines event WITHOUT acquiring the flock.

    Caller MUST already hold the flock (e.g. via `_locked_state`).
    Re-entrant flock acquisition is not guaranteed safe across all POSIX
    kernels, so the unified claim path holds one flock and uses this
    helper for both STATE.json write and EVENTS.log append.
    """
    sp = state_path(canonical_repo, run_id)
    ep = events_path(canonical_repo, run_id)
    state_sha_now = integrity.sha256_file(sp) if sp.exists() else None

    record: dict[str, Any] = {
        "ts": utc_now_iso(),
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
    line = _json_dumps(record)
    chain_hash = _compute_chain_hash_for_append(ep, line, state_sha_now)
    record["event_chain_sha256"] = chain_hash
    line = _json_dumps(record)

    ep.parent.mkdir(parents=True, exist_ok=True)
    with open(ep, "a", encoding="utf-8") as f:
        f.write(line + "\n")
        f.flush()
        try:
            os.fsync(f.fileno())
        except OSError:
            pass
    ensure_mode(ep, 0o600)
    try:
        fsync_dir(ep.parent)
    except OSError:
        pass


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
    """Append a JSON Lines event under flock.

    The new event carries an `event_chain_sha256` field: SHA-256 over the
    full EVENTS.log as it will exist once this line lands. Subsequent
    reads can verify the event chain by recomputing (see
    `integrity.compute_event_chain_hash`) and comparing it to the most
    recent recorded value.

    v0.3.5 (A1-002): the previous-hash read and the chain-hash
    computation now happen INSIDE the flock. Two concurrent appenders
    can no longer interleave: one acquires the flock, reads the prior
    chain hash, computes the new one, and appends; the other waits.

    v0.3.5 (limitation): if the LAST event is removed, the chain still
    validates because the chain hash of N-1 lines equals the recorded
    chain hash of N-1 lines. Truncation detection requires an
    external terminal anchor (out of scope for this patch).
    """
    sp = state_path(canonical_repo, run_id)
    ep = events_path(canonical_repo, run_id)

    # Read the prior chain hash, current state SHA, and compute the
    # new chain hash ALL under the flock. This closes the TOCTOU
    # window where two concurrent appenders could both compute their
    # chain hash from the same prior hash.
    with flock_exclusive(lock_path(canonical_repo, run_id)):
        _verify_mutation_integrity_locked(canonical_repo, run_id)
        state_sha_now = integrity.sha256_file(sp) if sp.exists() else None
        record: dict[str, Any] = {
            "ts": utc_now_iso(),
            "run_id": run_id,
            "event_type": event_type,
            "old_state": old_state,
            "new_state": new_state,
            "actor": actor,
            "commit_sha": commit_sha,
            "reason": reason,
            "state_sha256": state_sha_now,
            "event_chain_sha256": "0" * 64,  # 64-zero placeholder (same length as SHA-256 hex)
        }
        if extras:
            record.update(extras)
        # Compute the chain hash over the line as it will exist AFTER
        # substitution. Since the placeholder has the same byte length as the
        # SHA-256 hex, the only bytes that change in the canonical serialization
        # are within the chain_hash field itself — the rest of the line is
        # byte-identical. We substitute the computed hash into the field, then
        # re-serialize. Recomputation via compute_event_chain_hash yields the
        # same hash because both writes go through the same canonical serializer
        # and the chain hash is itself a function of the (length-stable) line.
        line = _json_dumps(record)
        chain_hash = _compute_chain_hash_for_append(ep, line, state_sha_now)
        record["event_chain_sha256"] = chain_hash
        line = _json_dumps(record)

        ep.parent.mkdir(parents=True, exist_ok=True)
        # Rewrite the JSONL file through an fsynced temp + atomic replace.
        # A power loss therefore leaves either the complete old chain or the
        # complete new chain, never a half-written final JSON line.
        existing = ep.read_bytes() if ep.exists() else b""
        tmp = ep.parent / f".{ep.name}.append.tmp"
        with open(tmp, "wb") as f:
            f.write(existing)
            f.write((line + "\n").encode("utf-8"))
            f.flush()
            os.fsync(f.fileno())
        ensure_mode(tmp, 0o600)
        os.replace(tmp, ep)
        ensure_mode(ep, 0o600)
        try:
            fsync_dir(ep.parent)
        except OSError:
            pass

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
    """Atomically transition state under flock, appending an event.

    The flock is held only for the read-modify-write of STATE.json. The
    audit event is appended after the lock is released to avoid re-entrant
    flock acquisition on the same file (which is not guaranteed to be
    re-entrant across open file descriptions on all POSIX kernels).

    Before transitioning, this function loads STATE.json *and* verifies
    its recorded SHA. If the file was edited externally, we raise
    `integrity.TamperingDetected`.
    """
    sp = state_path(canonical_repo, run_id)
    ep = events_path(canonical_repo, run_id)

    with flock_exclusive(lock_path(canonical_repo, run_id)):
        # Verify and mutate under the same ownership lock; otherwise another
        # writer can change STATE/EVENTS between verification and the write.
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
            new,
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
    """Increment a top-level integer counter under flock and return the new value.

    If `hard_cap` is True (default) and the counter is one of the V1-caps
    list, refuse to increment past the effective cap (V1 max or packet
    override). Raises `limits_mod.RepairLimitExceeded`.
    """
    sp = state_path(canonical_repo, run_id)
    ep = events_path(canonical_repo, run_id)
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
            new,
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
    s = read_json(state_path(canonical_repo, run_id), default=None)
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

        # STATE + binding event are one recoverable write-ahead transaction.
        _commit_state_event_locked(
            canonical_repo,
            run_id,
            new,
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
