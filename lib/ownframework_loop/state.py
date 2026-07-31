"""State file operations under flock — load, transition, append events."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
from typing import Any

from .locking import flock_exclusive
from .transitions import assert_valid
from .util import (
    atomic_write_json, read_json, run_dir, utc_now_iso, ensure_mode,
    fsync_dir,
)
from . import integrity
from . import limits as limits_mod


SCHEMA_VERSION = "ownframework-loop-state/v1"


def state_path(canonical_repo: Path, run_id: str) -> Path:
    return run_dir(canonical_repo, run_id) / "STATE.json"


def events_path(canonical_repo: Path, run_id: str) -> Path:
    return run_dir(canonical_repo, run_id) / "EVENTS.log"


def lock_path(canonical_repo: Path, run_id: str) -> Path:
    return run_dir(canonical_repo, run_id) / "LOCK"


def stop_path(canonical_repo: Path, run_id: str) -> Path:
    return run_dir(canonical_repo, run_id) / "STOP"


def initial_state(run_id: str) -> dict[str, Any]:
    """Return a fresh initial state document (AWAITING_APPROVAL)."""
    now = utc_now_iso()
    return {
        "schema": SCHEMA_VERSION,
        "run_id": run_id,
        "state": "AWAITING_APPROVAL",
        "state_history": [
            {"from": None, "to": "AWAITING_APPROVAL", "at": now, "actor": "spec", "reason": "run created"}
        ],
        "transitions_count": 0,
        "build_pass_count": 0,
        "review_pass_count": 0,
        "repair_round": 0,
        "no_progress_streak": 0,
        "started_at": now,
        "updated_at": now,
        "last_actor": "spec",
        "terminal_reason": None,
        "last_candidate_sha": None,
    }


def load(canonical_repo: Path, run_id: str) -> dict[str, Any] | None:
    return read_json(state_path(canonical_repo, run_id))


def load_verified(canonical_repo: Path, run_id: str) -> dict[str, Any]:
    """Load STATE.json AND verify its SHA matches the last recorded event.

    Raises `integrity.TamperingDetected` on mismatch. Returns {} for missing
    (lets the caller decide what to do — usually create a fresh state).
    """
    sp = state_path(canonical_repo, run_id)
    ep = events_path(canonical_repo, run_id)
    ok, msg = integrity.verify_state_sha(sp, ep)
    if not ok:
        raise integrity.TamperingDetected(msg)
    return read_json(sp, default={}) or {}


def save(canonical_repo: Path, run_id: str, payload: dict[str, Any]) -> None:
    """Persist state under flock and record an integrity event.

    `save()` is reserved for cases where the caller has computed a full new
    state object (e.g. updating counters, patching a field). It writes
    STATE.json atomically and appends a `state_saved` event so the SHA
    chain stays consistent for subsequent `transition()` / `save()` calls.
    """
    actor = str(payload.get("last_actor", "spec"))
    with flock_exclusive(lock_path(canonical_repo, run_id)):
        atomic_write_json(state_path(canonical_repo, run_id), payload, mode=0o600)
        ensure_mode(events_path(canonical_repo, run_id), 0o600)
    try:
        fsync_dir(state_path(canonical_repo, run_id).parent)
    except OSError:
        pass
    append_event(
        canonical_repo, run_id,
        event_type="state_saved",
        old_state=payload.get("state"),
        new_state=payload.get("state"),
        actor=actor,
        commit_sha=payload.get("last_candidate_sha"),
        reason="non-transition state save",
    )


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
        "event_chain_sha256": "PENDING",
    }
    if extras:
        record.update(extras)
    # Pre-serialize with a placeholder chain hash, compute the chained
    # SHA over the file as it will exist AFTER this line, then patch the
    # record and re-serialize so the on-disk line carries the chain hash.
    line = _json_dumps(record)
    chain_hash = _compute_chain_hash_for_append(ep, line, state_sha_now)
    record["event_chain_sha256"] = chain_hash
    line = _json_dumps(record)

    with flock_exclusive(lock_path(canonical_repo, run_id)):
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
    # Verify before reading.
    sp = state_path(canonical_repo, run_id)
    ep = events_path(canonical_repo, run_id)
    ok, msg = integrity.verify_state_sha(sp, ep)
    if not ok:
        raise integrity.TamperingDetected(f"transition refused: {msg}")

    with flock_exclusive(lock_path(canonical_repo, run_id)):
        current = read_json(state_path(canonical_repo, run_id))
        if current is None or current == {}:
            raise FileNotFoundError(f"STATE.json missing for run {run_id}")
        from_state = current["state"]
        assert_valid(from_state, to_state)

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

        atomic_write_json(state_path(canonical_repo, run_id), new, mode=0o600)
    # Directory fsync for the rename, then audit outside the lock.
    try:
        fsync_dir(state_path(canonical_repo, run_id).parent)
    except OSError:
        pass
    append_event(
        canonical_repo, run_id,
        event_type="state_transition",
        old_state=from_state,
        new_state=to_state,
        actor=actor,
        commit_sha=commit_sha,
        reason=reason,
    )
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
    if hard_cap:
        limits_mod.enforce(counter, int(current_counter(canonical_repo, run_id, counter) or 0), packet)

    with flock_exclusive(lock_path(canonical_repo, run_id)):
        current = read_json(state_path(canonical_repo, run_id))
        if current is None or current == {}:
            raise FileNotFoundError(f"STATE.json missing for run {run_id}")
        new = dict(current)
        new[counter] = int(current.get(counter, 0)) + 1
        new["updated_at"] = utc_now_iso()
        new["last_actor"] = actor
        atomic_write_json(state_path(canonical_repo, run_id), new, mode=0o600)
    # Audit outside the lock.
    append_event(
        canonical_repo, run_id,
        event_type="counter_incremented",
        old_state=None, new_state=None,
        actor=actor, commit_sha=None,
        reason=None, extras={"counter": counter, "new_value": new[counter],
                            "cap": limits_mod.effective_cap(counter, packet)},
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
    """SHA-256 over the full EVENTS.log after appending `line`.

    Computes the chain that will exist once `line` is written to disk,
    so we can record it atomically in the event itself.
    """
    try:
        existing = ep.read_bytes() if ep.exists() else b""
    except OSError:
        existing = b""
    h = hashlib.sha256()
    if existing:
        h.update(existing)
    if not existing.endswith(b"\n") and existing:
        h.update(b"\n")
    h.update(line.encode("utf-8"))
    return h.hexdigest()
