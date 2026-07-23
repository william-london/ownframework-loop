"""State file operations under flock — load, transition, append events."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from .locking import flock_exclusive
from .transitions import assert_valid
from .util import (
    atomic_write_json, read_json, run_dir, utc_now_iso, ensure_mode,
)


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


def save(canonical_repo: Path, run_id: str, payload: dict[str, Any]) -> None:
    """Persist state under flock and append a no-event marker to EVENTS.log."""
    with flock_exclusive(lock_path(canonical_repo, run_id)):
        atomic_write_json(state_path(canonical_repo, run_id), payload, mode=0o600)
        ensure_mode(events_path(canonical_repo, run_id), 0o600)


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
    """Append a JSON Lines event under flock."""
    record = {
        "ts": utc_now_iso(),
        "run_id": run_id,
        "event_type": event_type,
        "old_state": old_state,
        "new_state": new_state,
        "actor": actor,
        "commit_sha": commit_sha,
        "reason": reason,
    }
    if extras:
        record.update(extras)
    line = _json_dumps(record)
    ep = events_path(canonical_repo, run_id)
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
    """
    with flock_exclusive(lock_path(canonical_repo, run_id)):
        current = read_json(state_path(canonical_repo, run_id))
        if current is None:
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
    # OUTSIDE the lock — append the audit event.
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
) -> int:
    """Increment a top-level integer counter under flock and return the new value."""
    with flock_exclusive(lock_path(canonical_repo, run_id)):
        current = read_json(state_path(canonical_repo, run_id))
        if current is None:
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
        reason=None, extras={"counter": counter, "new_value": new[counter]},
    )
    return new[counter]


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
    import json
    return json.dumps(obj, sort_keys=True, separators=(",", ":"))
