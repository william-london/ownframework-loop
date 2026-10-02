"""State file operations under flock — load, transition, append events."""

from __future__ import annotations

import hashlib
import json
import os
import stat
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

# Callers may attach diagnostic metadata, but may never replace protocol
# identity/integrity fields. state_txn_id is reserved to the internal
# write-ahead transaction mechanism.
_EVENT_AUTHORITATIVE_FIELDS = frozenset({
    "ts", "run_id", "event_type", "old_state", "new_state", "actor",
    "commit_sha", "reason", "state_sha256", "event_chain_sha256",
} | set(integrity.ARTIFACT_EVENT_KEYS.values()))
_EVENT_CALLER_RESERVED_FIELDS = _EVENT_AUTHORITATIVE_FIELDS | {"state_txn_id"}


# Protocol-authoritative state fields, defined structurally: these are owned
# by the FSM, run identity, integrity chain, claim/finalize owners, and the
# frozen run-authority objects. Generic caller extras may NEVER write any of
# them — authoritative updates flow exclusively through the explicit typed
# owner parameters of the transition owners (or the dedicated claim/finalize
# owners). Allowing extras to override `state` would let a caller land any
# to_state (e.g. APPROVED) regardless of the validated transition; overriding
# run_id/transitions_count/state_history would desync the event-chain SHA
# binding on the next verified read; overriding last_candidate_sha, counters,
# fuses or the frozen `program` object would forge run authority.
STATE_OWNER_FIELDS = frozenset({
    # Document identity + integrity chain.
    "schema", "run_id", "state", "state_history", "transitions_count",
    "started_at", "updated_at", "last_actor",
    # FSM/finalize-owned counters and review-repetition fuses.
    "build_pass_count", "review_pass_count", "repair_round",
    "no_progress_streak", "identical_finding_streak",
    "last_must_fix_fingerprint",
    # Candidate identity and termination.
    "last_candidate_sha", "terminal_reason",
    # Frozen run authority.
    "program",
    "spec_baseline_branch", "spec_baseline_sha", "spec_snapshot_at",
})

# Generic transition extras are structurally incapable of mutating STATE.json:
# diagnostic transport belongs in append_event() extras (a separate contract)
# and authoritative fields belong to the typed owner parameters. This
# allow-list is intentionally empty; enlisting a key here is a protocol
# change, not a caller convenience.
_STATE_EXTRA_ALLOWED_KEYS = frozenset()

# Fields atomic_patch() may write. atomic_patch() is the NON-authoritative
# read-modify-write owner; every acceptable field must be explicitly enlisted
# here AND be absent from STATE_OWNER_FIELDS. No state field qualifies today:
# every meaningful field is owner-controlled, so the enlisted set is empty.
_STATE_PATCH_ALLOWED_FIELDS = frozenset()


def _validate_state_extras(
    extras: dict[str, Any] | None,
    *,
    owner: str = "transition",
) -> None:
    """Structurally reject generic state mutation through caller extras.

    Owner-authoritative fields are refused by name first (best diagnostic);
    ANY other key is refused as well because generic extras may never write
    STATE.json at all.
    """
    if not extras:
        return
    owner_overlap = STATE_OWNER_FIELDS.intersection(extras)
    if owner_overlap:
        raise ValueError(
            f"{owner} extras may not override protocol-authoritative state "
            "fields: " + ", ".join(sorted(owner_overlap))
        )
    raise ValueError(
        f"{owner} extras may not mutate STATE.json; no generic extras are "
        "accepted (diagnostics belong in append_event; authoritative updates "
        "use the typed owner parameters): " + ", ".join(sorted(extras))
    )


def _validate_patch_fields(fields: dict[str, Any] | None) -> None:
    if not fields:
        raise ValueError("atomic_patch requires at least one field")
    owner_overlap = STATE_OWNER_FIELDS.intersection(fields)
    if owner_overlap:
        raise ValueError(
            "atomic_patch may not write protocol-authoritative state fields: "
            + ", ".join(sorted(owner_overlap))
        )
    foreign = set(fields) - _STATE_PATCH_ALLOWED_FIELDS
    if foreign:
        raise ValueError(
            "atomic_patch fields must be explicitly enlisted non-authoritative"
            " fields; refused: " + ", ".join(sorted(foreign))
        )


def _owner_int(name: str, value: Any) -> int:
    try:
        out = int(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"typed owner field {name!r} must be an integer") from exc
    if out < 0:
        raise ValueError(f"typed owner field {name!r} must be non-negative")
    return out


def _validate_event_extras(
    extras: dict[str, Any] | None,
    *,
    allow_state_txn_id: bool = False,
) -> None:
    if not extras:
        return
    reserved = (
        _EVENT_AUTHORITATIVE_FIELDS
        if allow_state_txn_id
        else _EVENT_CALLER_RESERVED_FIELDS
    )
    overlap = reserved.intersection(extras)
    if overlap:
        raise ValueError(
            "event extras may not override authoritative fields: "
            + ", ".join(sorted(overlap))
        )


def state_txn_path(canonical_repo: Path, run_id: str) -> Path:
    """Write-ahead intent for one STATE.json + EVENTS.log transaction."""
    return run_dir(canonical_repo, run_id) / "STATE_TXN.json"


def _event_append_tmp_path(canonical_repo: Path, run_id: str) -> Path:
    """Non-authoritative temp used for atomic EVENTS.log replacement."""
    return run_dir(canonical_repo, run_id) / ".EVENTS.log.append.tmp"


def _cleanup_stale_event_append_tmp_locked(
    canonical_repo: Path,
    run_id: str,
) -> bool:
    """Remove append temp left by a dead writer while caller holds run flock."""
    tmp = _event_append_tmp_path(canonical_repo, run_id)
    try:
        tmp.unlink()
    except FileNotFoundError:
        return False
    try:
        fsync_dir(tmp.parent)
    except OSError:
        pass
    return True


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
    _cleanup_stale_event_append_tmp_locked(canonical_repo, run_id)
    tp = state_txn_path(canonical_repo, run_id)
    if tp.is_symlink():
        raise integrity.TamperingDetected(
            "pending state transaction must not be a symlink"
        )
    if not tp.exists():
        return None
    try:
        st = tp.stat()
    except OSError as exc:
        raise integrity.TamperingDetected(
            f"pending state transaction metadata is unreadable: {exc}"
        ) from exc
    if not stat.S_ISREG(st.st_mode):
        raise integrity.TamperingDetected(
            "pending state transaction must be a regular file"
        )
    if hasattr(os, "getuid") and st.st_uid != os.getuid():
        raise integrity.TamperingDetected(
            "pending state transaction must be owned by supervisor user"
        )
    if stat.S_IMODE(st.st_mode) & 0o077:
        raise integrity.TamperingDetected(
            "pending state transaction must be private (0600)"
        )
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
        # Only unreadable/torn bytes may be explained by this proven journal.
        current_doc = read_json(sp, default=None) if sp.exists() else None
        if current_doc is None:
            atomic_write_json(sp, new_state, mode=0o600)
            current_sha = integrity.sha256_file(sp)
        else:
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
    # Reject invalid caller metadata before writing the journal or STATE bytes.
    _validate_event_extras(extras)
    tp = state_txn_path(canonical_repo, run_id)
    if tp.exists() or tp.is_symlink():
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

    This is an authoritative READ, so it must never create a run that does not
    exist. Reading a repository or run that holds no run directory returns the
    same empty result the integrity check already yields for "no state or event
    chain yet", WITHOUT materializing the repository or the run directory.

    Historically this acquired the creating flock unconditionally, so a caller
    that merely OBSERVED a retired historical run (``supervisor``'s
    program-boundary reconciliation replays every ``DONE`` enrollment)
    resurrected that run's entire ``.ownframework-loop/<run_id>/`` skeleton
    under the operator's canonical project root. A read may never manufacture
    the run it reads.

    A run directory that DOES exist keeps the ordinary creating lock: a
    legitimate run established without a per-run lock must still be readable,
    and creating a lock inside an existing run directory establishes nothing
    new. A proven pending write-ahead transaction is completed first. The event
    chain and the final STATE SHA binding are then verified while the same
    flock is held, eliminating the verify-then-read race for authority-bearing
    callers.
    """
    sp = state_path(canonical_repo, run_id)
    ep = events_path(canonical_repo, run_id)
    if not run_dir(canonical_repo, run_id).is_dir():
        # This run does not exist, so it has no durable state to verify and no
        # lock to take. Return without creating the repository or the run.
        return {}
    with flock_exclusive(lock_path(canonical_repo, run_id)):
        _recover_pending_state_txn_locked(canonical_repo, run_id)
        events: list[dict[str, Any]] = []
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
            # v0.10.0-dev f007: unreadable STATE bytes are torn; a
            # parseable SHA mismatch is tampering. A valid pending journal may
            # recover only the former; otherwise unreadable bytes are StateTorn.
            current_bytes = read_json(sp, default=None)
            if current_bytes is None:
                # STATE.json is unreadable / truncated / malformed. Try to
                # recover from the pending journal one more time under the
                # same flock. If still torn, raise StateTorn.
                _recover_pending_state_txn_locked(canonical_repo, run_id)
                recovered = read_json(sp, default=None)
                if recovered is None:
                    raise integrity.StateTorn(
                        "STATE.json is unreadable/torn; "
                        f"pending journal did not produce a recoverable state: {msg}"
                    )
                recovered_events = integrity.read_event_chain(ep) if ep.exists() else []
                _verify_semantic_budget_allocation_bindings(recovered, recovered_events)
                return recovered
            raise integrity.TamperingDetected(msg)
        payload = read_json(sp, default={}) or {}
        _verify_semantic_budget_allocation_bindings(payload, events if ep.exists() else [])
        return payload


def _verify_semantic_budget_allocation_bindings(
    payload: dict[str, Any], events: list[dict[str, Any]],
) -> None:
    """Require adaptive allocations to be digest-bound by claim/import events."""
    program = payload.get("program") if isinstance(payload, dict) else None
    allocations = (
        program.get("semantic_budget_allocations") or []
        if isinstance(program, dict) else []
    )
    if not allocations:
        return
    if not isinstance(allocations, list):
        raise integrity.TamperingDetected("semantic budget allocation ledger is malformed")
    canonical_allocations = json.loads(integrity.canonical_json_dumps(allocations))
    imported_prefix_lengths: set[int] = set()
    for event in events:
        if event.get("event_type") != "mission_segment_materialized":
            continue
        import_sha = str(event.get("semantic_budget_import_sha256") or "")
        if not import_sha:
            continue
        recorded_count = event.get("semantic_budget_import_count")
        if isinstance(recorded_count, int) and not isinstance(recorded_count, bool):
            candidate_counts = (recorded_count,)
        else:
            # Older materialization events bound the imported ledger by digest
            # only. Find the exact imported prefix so later claim-bound
            # allocations may be appended without invalidating that evidence.
            candidate_counts = range(1, len(canonical_allocations) + 1)
        for count in candidate_counts:
            if count < 1 or count > len(canonical_allocations):
                continue
            prefix = canonical_allocations[:count]
            prefix_sha = hashlib.sha256(
                integrity.canonical_json_dumps(prefix).encode("utf-8")
            ).hexdigest()
            if prefix_sha == import_sha:
                imported_prefix_lengths.add(count)
                break
    for index, item in enumerate(allocations):
        if not isinstance(item, dict):
            raise integrity.TamperingDetected("semantic budget allocation entry is malformed")
        body = dict(item)
        allocation_id = str(body.pop("allocation_id", ""))
        expected_id = hashlib.sha256(
            integrity.canonical_json_dumps(body).encode("utf-8")
        ).hexdigest()
        if allocation_id != expected_id:
            raise integrity.TamperingDetected("semantic budget allocation digest mismatch")
        allocation_sha = hashlib.sha256(
            integrity.canonical_json_dumps(item).encode("utf-8")
        ).hexdigest()
        directly_bound = any(
            event.get("semantic_budget_allocation_id") == allocation_id
            and event.get("semantic_budget_allocation_sha256") == allocation_sha
            for event in events
        )
        import_bound = any(index < count for count in imported_prefix_lengths)
        if not directly_bound and not import_bound:
            raise integrity.TamperingDetected(
                "semantic budget allocation has no durable claim or segment-import binding"
            )


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


def _validate_initial_state_payload(run_id: str, payload: dict[str, Any]) -> None:
    """Validate the COMPLETE creation-time STATE contract.

    A creation-only writer is not permission to mint arbitrary authoritative
    fields. The payload must be exactly initial_state(run_id), optionally plus
    the all-or-nothing SPEC source snapshot owned by spec creation.
    """
    validate_run_id(run_id)
    if not isinstance(payload, dict):
        raise ValueError("initial state payload must be an object")

    required = set(initial_state(run_id))
    snapshot_fields = {
        "spec_baseline_branch", "spec_baseline_sha", "spec_snapshot_at",
    }
    missing = required - set(payload)
    unknown = set(payload) - required - snapshot_fields
    if missing:
        raise ValueError(
            "initial state payload missing required fields: "
            + ", ".join(sorted(missing))
        )
    if unknown:
        raise ValueError(
            "initial state payload has unsupported fields: "
            + ", ".join(sorted(unknown))
        )
    present_snapshot = set(payload).intersection(snapshot_fields)
    if present_snapshot and present_snapshot != snapshot_fields:
        raise ValueError(
            "initial state source snapshot must supply branch, sha, and timestamp together"
        )

    structural = {
        "schema": SCHEMA_VERSION,
        "run_id": run_id,
        "state": "AWAITING_APPROVAL",
        "transitions_count": 0,
        "build_pass_count": 0,
        "review_pass_count": 0,
        "repair_round": 0,
        "no_progress_streak": 0,
        "last_actor": "spec",
        "terminal_reason": "",
        "last_candidate_sha": "",
    }
    for key, expected in structural.items():
        if payload.get(key) != expected:
            raise ValueError(
                f"initial state field {key!r} must be {expected!r}, "
                f"got {payload.get(key)!r}"
            )

    started_at = payload.get("started_at")
    if (
        not isinstance(started_at, str) or not started_at
        or payload.get("updated_at") != started_at
    ):
        raise ValueError(
            "initial state started_at/updated_at must be one non-empty timestamp"
        )
    history = payload.get("state_history")
    expected_history = [{
        "from": "",
        "to": "AWAITING_APPROVAL",
        "at": started_at,
        "actor": "spec",
        "reason": "run created",
    }]
    if history != expected_history:
        raise ValueError("initial state history does not match the creation contract")

    if present_snapshot:
        if not all(isinstance(payload.get(k), str) for k in snapshot_fields):
            raise ValueError("initial state source snapshot fields must be strings")
        if not payload.get("spec_snapshot_at"):
            raise ValueError("initial state spec_snapshot_at must be non-empty")


def save(canonical_repo: Path, run_id: str, payload: dict[str, Any]) -> None:
    """Create the initial durable state for a brand-new run. CREATION-ONLY.

    Once STATE.json exists, `save()` refuses unconditionally: no existing-state
    mutation — identity or otherwise — can flow through it, structurally
    eliminating stale read-modify-write lost-update windows. Every later
    mutation has a typed owner:

      * FSM/state changes: transition() / program_transition() /
        transition_funded_repair() with explicit typed owner parameters;
      * claim counters/fuses: the claim and finalize owners;
      * diagnostics: append_event() extras (a separate contract).
    """
    _validate_initial_state_payload(run_id, payload)
    actor = str(payload.get("last_actor", "spec"))
    sp = state_path(canonical_repo, run_id)
    with flock_exclusive(lock_path(canonical_repo, run_id)):
        # Existing durable history must verify before it can be overwritten.
        # A brand-new run legitimately has neither STATE nor EVENTS yet.
        _verify_mutation_integrity_locked(canonical_repo, run_id)
        if sp.exists():
            raise ValueError(
                "save() is creation-only: STATE.json already exists for run "
                f"{run_id}; state mutations go through the transition owners "
                "(transition/program_transition/transition_funded_repair) with "
                "typed owner parameters"
            )
        _commit_state_event_locked(
            canonical_repo,
            run_id,
            payload,
            event_type="state_saved",
            old_state=None,
            new_state=payload.get("state"),
            actor=actor,
            commit_sha=payload.get("last_candidate_sha"),
            reason="initial state creation",
        )
    try:
        fsync_dir(sp.parent)
    except OSError:
        pass


def initialize_program_rollover(
    canonical_repo: Path,
    run_id: str,
    *,
    program_block: dict[str, Any],
    build_pass_count: int,
    review_pass_count: int,
    repair_round: int,
    no_progress_streak: int,
    candidate_sha: str,
    baseline_sha: str,
    baseline_branch: str,
    candidate_branch: str,
    parent_run_id: str,
    rollover_authority_sha256: str,
) -> dict[str, Any]:
    """Import frozen PROGRAM progress into a newly-created rollover child.

    This is a creation-only typed owner. It may only extend a pristine
    AWAITING_APPROVAL state created by ``spec new``; it cannot alter an
    existing or terminal run. The source-run authority and copied packet are
    verified by the rollover owner before this call, while this function
    enforces the state/counter/graph invariants under the child's state lock.
    """
    validate_run_id(run_id)
    validate_run_id(parent_run_id)
    if not isinstance(program_block, dict) or not program_block:
        raise ValueError("rollover PROGRAM block must be a non-empty object")
    if not re.fullmatch(r"[0-9a-f]{40}", str(candidate_sha or "")):
        raise ValueError("rollover candidate SHA must be a full Git SHA")
    if not re.fullmatch(r"[0-9a-f]{64}", str(rollover_authority_sha256 or "")):
        raise ValueError("rollover authority digest must be SHA-256")
    counters = {
        "build_pass_count": _owner_int("build_pass_count", build_pass_count),
        "review_pass_count": _owner_int("review_pass_count", review_pass_count),
        "repair_round_count": _owner_int("repair_round", repair_round),
        "files_changed_unique": _owner_int(
            "files_changed_unique", int((program_block.get("cumulative_counters") or {}).get("files_changed_unique", -1))
        ),
        "diff_lines_total": _owner_int(
            "diff_lines_total", int((program_block.get("cumulative_counters") or {}).get("diff_lines_total", -1))
        ),
    }
    copied = json.loads(integrity.canonical_json_dumps(program_block))
    from . import packet as packet_mod, program as program_mod, schema_validate, util as util_mod

    run_root = run_dir(canonical_repo, run_id)
    packet_path = run_root / "WORK_PACKET.md"
    authority_path = run_root / "ROLLOVER_AUTHORITY.json"
    if not packet_path.is_file() or not authority_path.is_file():
        raise RuntimeError("rollover packet/authority must exist before state import")
    if integrity.sha256_file(authority_path) != rollover_authority_sha256:
        raise RuntimeError("rollover authority digest does not match its durable file")
    authority_doc = util_mod.read_private_json(authority_path, default=None)
    if (
        not isinstance(authority_doc, dict)
        or authority_doc.get("schema") != "ownframework-loop-program-rollover-authority/v1"
        or authority_doc.get("child_run_id") != run_id
        or authority_doc.get("parent_run_id") != parent_run_id
        or authority_doc.get("candidate_sha") != candidate_sha
        or authority_doc.get("child_packet_sha256") != integrity.sha256_file(packet_path)
        or authority_doc.get("child_baseline_sha") != baseline_sha
        or authority_doc.get("child_baseline_branch") != baseline_branch
        or authority_doc.get("child_candidate_branch") != candidate_branch
    ):
        raise RuntimeError("rollover authority does not bind the child state import")
    packet_meta, _ = packet_mod.parse_packet_file(packet_path)
    packet_errors = packet_mod.validate_packet_for_approval(packet_meta)
    if packet_errors:
        raise RuntimeError("rollover child packet is invalid: " + "; ".join(packet_errors))
    graph_ok, graph_reason = program_mod.verify_frozen_graph(packet_meta, copied)
    if not graph_ok:
        raise RuntimeError(f"rollover PROGRAM graph does not match copied packet: {graph_reason}")
    if packet_mod.packet_is_program(packet_meta) is not True:
        raise RuntimeError("rollover child packet is not PROGRAM mode")
    prog_counters = copied.get("cumulative_counters") or {}
    expected_mirrors = {
        "build_pass_count": counters["build_pass_count"],
        "review_pass_count": counters["review_pass_count"],
        "repair_round_count": counters["repair_round_count"],
    }
    if any(int(prog_counters.get(key, -1)) != value for key, value in expected_mirrors.items()):
        raise ValueError("rollover counters do not match copied PROGRAM cumulative counters")
    if copied.get("blocked") is True:
        raise ValueError("rollover refuses a terminal/blocked PROGRAM graph")
    current_checkpoints = copied.get("current_checkpoints") or []
    if len(current_checkpoints) != 1:
        raise ValueError("rollover requires exactly one current checkpoint")
    finalized_rows = copied.get("finalized_checkpoints") or []
    finalized_ids = [str(row.get("id") or "") for row in finalized_rows if isinstance(row, dict)]
    if (
        len(finalized_ids) != len(finalized_rows)
        or len(finalized_ids) != len(set(finalized_ids))
        or any(row.get("terminal_state") != "APPROVED" for row in finalized_rows)
    ):
        raise ValueError("rollover finalized-checkpoint evidence is contradictory")
    checkpoints_by_id = {
        str(cp.get("id")): cp for cp in copied.get("checkpoints", []) if isinstance(cp, dict)
    }
    if any(checkpoints_by_id.get(cp_id, {}).get("terminal") != "APPROVED" for cp_id in finalized_ids):
        raise ValueError("rollover finalized list does not match checkpoint terminal states")
    if any(
        cp.get("terminal") == "APPROVED" and str(cp.get("id")) not in set(finalized_ids)
        for cp in checkpoints_by_id.values()
    ):
        raise ValueError("rollover checkpoint approval lacks finalized evidence")
    expected_current = program_mod.advance_to_next(copied, packet_meta).get("current_checkpoints") or []
    if current_checkpoints != expected_current:
        raise ValueError("rollover current checkpoint is not the next eligible frozen checkpoint")
    provenance = copied.get("rollover_provenance") or {}
    if (
        provenance.get("schema") != "ownframework-loop-program-rollover/v1"
        or provenance.get("parent_run_id") != parent_run_id
        or provenance.get("rollover_authority_sha256") != rollover_authority_sha256
        or provenance.get("candidate_sha") != candidate_sha
        or provenance.get("imported_counters") != counters
    ):
        raise ValueError("copied PROGRAM rollover provenance is inconsistent")
    source_provenance = copied.get("source_sha_provenance") or {}
    if (
        source_provenance.get("baseline_sha") != baseline_sha
        or source_provenance.get("candidate_branch") != candidate_branch
    ):
        raise ValueError("rollover PROGRAM baseline/branch provenance is inconsistent")
    cp_id = str(current_checkpoints[0])
    cp_state = next(
        (cp for cp in (copied.get("checkpoints") or []) if cp.get("id") == cp_id),
        None,
    )
    cp_counters = provenance.get("checkpoint_counters") or {}
    if not isinstance(cp_state, dict) or any(
        int(cp_state.get(key) or 0) != int(cp_counters.get(key, -1))
        for key in ("build_pass_count", "review_pass_count", "repair_round_count")
    ):
        raise ValueError("rollover current-checkpoint counters are inconsistent")

    sp = state_path(canonical_repo, run_id)
    with flock_exclusive(lock_path(canonical_repo, run_id)):
        _verify_mutation_integrity_locked(canonical_repo, run_id)
        current = read_json(sp)
        if not isinstance(current, dict) or current.get("run_id") != run_id:
            raise FileNotFoundError(f"new rollover state missing for {run_id}")
        if current.get("state") != "AWAITING_APPROVAL" or current.get("schema") != SCHEMA_VERSION:
            raise RuntimeError("rollover import requires pristine AWAITING_APPROVAL state")
        if any(int(current.get(key) or 0) != 0 for key in (
            "build_pass_count", "review_pass_count", "repair_round"
        )):
            raise RuntimeError("rollover import refuses a child with already-used counters")
        if "program" in current:
            raise RuntimeError("rollover import refuses an already initialized child PROGRAM")
        if (
            current.get("spec_baseline_sha") != baseline_sha
            or current.get("spec_baseline_branch") != baseline_branch
        ):
            raise RuntimeError("rollover child source snapshot does not match the frozen baseline")

        new = dict(current)
        new["schema"] = PROGRAM_STATE_SCHEMA_VERSION
        new["program"] = copied
        new["build_pass_count"] = counters["build_pass_count"]
        new["review_pass_count"] = counters["review_pass_count"]
        new["repair_round"] = counters["repair_round_count"]
        new["no_progress_streak"] = _owner_int("no_progress_streak", no_progress_streak)
        new["last_candidate_sha"] = candidate_sha
        new["updated_at"] = utc_now_iso()
        new["last_actor"] = "ofloop-program-rollover"
        schema_errors = schema_validate.validate_state(new)
        if schema_errors:
            raise ValueError(
                "rollover imported STATE schema invalid: " + "; ".join(schema_errors[:20])
            )
        _commit_state_event_locked(
            canonical_repo,
            run_id,
            new,
            event_type="program_rollover_materialized",
            old_state="AWAITING_APPROVAL",
            new_state="AWAITING_APPROVAL",
            actor="ofloop-program-rollover",
            commit_sha=candidate_sha,
            reason="copied immutable PROGRAM counters for linked candidate rollover",
            extras={
                "parent_run_id": parent_run_id,
                "candidate_sha": candidate_sha,
                "rollover_authority_sha256": rollover_authority_sha256,
                "imported_counters": counters,
            },
        )
    try:
        fsync_dir(sp.parent)
    except OSError:
        pass
    return new


def transition_program_rollover_to_review(
    canonical_repo: Path,
    run_id: str,
    *,
    candidate_sha: str,
    rollover_authority_sha256: str,
    preflight_sha256: str,
    receipt_sha256: str,
) -> dict[str, Any]:
    """Move an approved, validated rollover candidate into ordinary REVIEW.

    This is the only READY_TO_BUILD -> READY_FOR_REVIEW edge. It is not a
    general FSM escape: the child must carry the typed rollover provenance,
    unchanged imported counters, a schema-valid rollover-origin build receipt,
    and exact digest bindings for the deterministic preflight and receipt.
    """
    validate_run_id(run_id)
    for label, value in (
        ("candidate", candidate_sha),
        ("rollover authority", rollover_authority_sha256),
        ("preflight", preflight_sha256),
        ("build receipt", receipt_sha256),
    ):
        expected_len = 40 if label == "candidate" else 64
        if not re.fullmatch(rf"[0-9a-f]{{{expected_len}}}", str(value or "")):
            raise ValueError(f"invalid {label} digest")

    from . import (
        approval as approval_mod,
        branch_resolver,
        build_finalize as build_finalize_mod,
        git_checks,
        packet as packet_mod,
        program as program_mod,
        program_rollover as program_rollover_mod,
        receipts as receipts_mod,
        util as util_mod,
        worktrees as worktrees_mod,
    )

    run_root = run_dir(canonical_repo, run_id)
    authority_path = run_root / "ROLLOVER_AUTHORITY.json"
    preflight_path = run_root / "ROLLOVER_PREFLIGHT.json"
    receipt_path = receipts_mod.receipt_path(canonical_repo, run_id)
    sp = state_path(canonical_repo, run_id)
    with flock_exclusive(lock_path(canonical_repo, run_id)):
        _verify_mutation_integrity_locked(canonical_repo, run_id)
        current = read_json(sp)
        if not isinstance(current, dict) or current.get("state") != "READY_TO_BUILD":
            raise RuntimeError("rollover review admission requires READY_TO_BUILD")
        program = current.get("program")
        rollover = (program or {}).get("rollover_provenance") if isinstance(program, dict) else None
        if not isinstance(rollover, dict):
            raise RuntimeError("rollover PROGRAM provenance is missing")
        if (
            rollover.get("candidate_sha") != candidate_sha
            or rollover.get("rollover_authority_sha256") != rollover_authority_sha256
        ):
            raise RuntimeError("rollover candidate/preflight identity mismatch")
        counters = rollover.get("imported_counters") or {}
        if (
            int(current.get("build_pass_count") or 0) != int(counters.get("build_pass_count", -1))
            or int(current.get("review_pass_count") or 0) != int(counters.get("review_pass_count", -1))
            or int(current.get("repair_round") or 0) != int(counters.get("repair_round_count", -1))
        ):
            raise RuntimeError("rollover counters changed before review admission")
        if not authority_path.is_file() or util_mod.sha256_file(authority_path) != rollover_authority_sha256:
            raise RuntimeError("rollover authority file is absent or changed")
        authority_doc = util_mod.read_private_json(authority_path, default=None)
        if (
            not isinstance(authority_doc, dict)
            or authority_doc.get("schema") != "ownframework-loop-program-rollover-authority/v1"
            or authority_doc.get("child_run_id") != run_id
            or authority_doc.get("candidate_sha") != candidate_sha
            or authority_doc.get("parent_run_id") != rollover.get("parent_run_id")
        ):
            raise RuntimeError("rollover authority identity is invalid")
        program_rollover_mod._verify_parent_source_authority(
            Path(canonical_repo).resolve(strict=False), authority_doc,
        )
        source = authority_doc.get("source") or {}
        child_packet_path = run_root / "WORK_PACKET.md"
        child_packet_sha = util_mod.sha256_file(child_packet_path) if child_packet_path.is_file() else ""
        child_approval_path = run_root / "APPROVAL.json"
        child_approval_doc = approval_mod.load_approval(canonical_repo, run_id)
        child_approval_sha = (
            approval_mod.approval_artifact_sha256(child_approval_doc)
            if isinstance(child_approval_doc, dict) else ""
        )
        child_packet_meta, _ = packet_mod.parse_packet_file(child_packet_path)
        child_approval_ok = bool(
            isinstance(child_approval_doc, dict)
            and child_approval_doc.get("run_id") == run_id
            and child_approval_doc.get("canonical_repo") == str(Path(canonical_repo).resolve(strict=False))
            and child_approval_doc.get("packet_sha256") == child_packet_sha
            and child_approval_doc.get("canonical_repo")
                == str(Path(str((child_packet_meta.get("target") or {}).get("repo") or "")).expanduser().resolve(strict=False))
            and child_approval_doc.get("baseline_branch") == current.get("spec_baseline_branch")
            and child_approval_doc.get("baseline_sha") == current.get("spec_baseline_sha")
            and child_approval_doc.get("baseline_sha")
                == git_checks.branch_head(canonical_repo, str(current.get("spec_baseline_branch") or ""))
            and child_approval_doc.get("candidate_branch") == authority_doc.get("child_candidate_branch")
            and child_approval_doc.get("confirmation_token")
                == approval_mod.derive_confirmation_token(child_packet_sha)
            and not approval_mod.validate_approval_shape(child_approval_doc)
            and child_packet_sha == authority_doc.get("child_packet_sha256")
            and child_approval_sha
        )
        if not child_approval_ok:
            raise RuntimeError("rollover child approval is invalid or not bound to the frozen authority")
        if (
            authority_doc.get("child_baseline_sha") != current.get("spec_baseline_sha")
            or authority_doc.get("child_baseline_branch") != current.get("spec_baseline_branch")
            or authority_doc.get("child_candidate_branch") != child_approval_doc.get("candidate_branch")
        ):
            raise RuntimeError("rollover authority source/baseline/candidate branch mismatch")
        expected_candidate_branch = branch_resolver.resolve_candidate_branch(
            canonical_repo, run_id, packet=child_packet_meta, state_doc=current,
        )
        if child_approval_doc.get("candidate_branch") != expected_candidate_branch:
            raise RuntimeError("rollover child approval candidate branch is not packet/run-derived")
        if (
            child_packet_meta.get("target", {}).get("branch")
            != current.get("spec_baseline_branch")
            or Path(str(child_packet_meta.get("target", {}).get("repo") or "")).expanduser().resolve(strict=False)
            != Path(canonical_repo).resolve(strict=False)
            or child_packet_meta.get("target", {}).get("expected_baseline_sha")
            != current.get("spec_baseline_sha")
        ):
            raise RuntimeError("rollover child packet target does not match the frozen source authority")
        parent_root = run_dir(canonical_repo, str(rollover.get("parent_run_id") or ""))
        parent_events = parent_root / "EVENTS.log"
        source_paths = {
            "WORK_PACKET.md": parent_root / "WORK_PACKET.md",
            "APPROVAL.json": parent_root / "APPROVAL.json",
            "STATE.json": parent_root / "STATE.json",
            "BUILD_RECEIPT.json": parent_root / "BUILD_RECEIPT.json",
            "REVIEW_VERDICT.json": parent_root / "REVIEW_VERDICT.json",
            "REVIEW_AGENT_ASSESSMENT.json": Path(str(source.get("review_assessment_path") or "")),
        }
        source_names = {
            "WORK_PACKET.md": "packet_sha256",
            "APPROVAL.json": "approval_sha256",
            "STATE.json": "state_sha256",
            "BUILD_RECEIPT.json": "build_receipt_sha256",
            "REVIEW_VERDICT.json": "review_verdict_sha256",
            "REVIEW_AGENT_ASSESSMENT.json": "review_assessment_sha256",
        }
        for artifact_name, artifact_path in source_paths.items():
            expected_source_sha = str(source.get(source_names[artifact_name]) or "")
            if (
                not expected_source_sha
                or not artifact_path.is_file()
                or util_mod.sha256_file(artifact_path) != expected_source_sha
            ):
                raise RuntimeError(f"rollover parent source artifact changed: {artifact_name}")
        if (
            not parent_events.is_file()
            or integrity.compute_event_chain_hash(parent_events) != source.get("event_chain_sha256")
        ):
            raise RuntimeError("rollover parent event chain changed")
        if not preflight_path.is_file() or util_mod.sha256_file(preflight_path) != preflight_sha256:
            raise RuntimeError("rollover preflight file is absent or changed")
        preflight_doc = util_mod.read_private_json(preflight_path, default=None)
        cp_id = str(rollover.get("checkpoint_id") or "")
        cp_state = next(
            (cp for cp in (program.get("checkpoints") or []) if cp.get("id") == cp_id),
            None,
        )
        cp_counters = rollover.get("checkpoint_counters") or {}
        if (
            not isinstance(cp_state, dict)
            or cp_state.get("terminal")
            or (program.get("current_checkpoints") or []) != [cp_id]
            or any(int(cp_state.get(key) or 0) != int(cp_counters.get(key, -1)) for key in (
                "build_pass_count", "review_pass_count", "repair_round_count", "no_progress_streak"
            ))
        ):
            raise RuntimeError("rollover checkpoint/counter authority changed before review admission")
        checkpoint_meta = next(
            (cp for cp in (child_packet_meta.get("checkpoint_graph") or {}).get("checkpoints", []) if cp.get("id") == cp_id),
            None,
        )
        if not isinstance(checkpoint_meta, dict) or int(cp_state.get("build_pass_count") or 0) != int(
            (checkpoint_meta.get("risk_budget") or {}).get("max_build_passes") or 0
        ):
            raise RuntimeError("rollover no longer has an exactly exhausted checkpoint BUILD cap")
        candidate_wt = worktrees_mod.builder_worktree(Path(canonical_repo), run_id)
        if (
            not candidate_wt.is_dir()
            or not worktrees_mod.is_registered_worktree(Path(canonical_repo), candidate_wt)
            or git_checks.current_head(candidate_wt) != candidate_sha
            or git_checks.current_branch(candidate_wt) != child_approval_doc.get("candidate_branch")
            or git_checks.dirty_status(candidate_wt) != "clean"
            or not git_checks.commit_exists(Path(canonical_repo), candidate_sha)
            or not build_finalize_mod._ancestor_of(Path(canonical_repo), candidate_sha, str(current.get("spec_baseline_sha") or ""))
            or not build_finalize_mod._candidate_branch_contains(Path(canonical_repo), str(child_approval_doc.get("candidate_branch") or ""), candidate_sha)
        ):
            raise RuntimeError("rollover candidate worktree or lineage changed before review admission")
        source_stats = receipts_mod.compute_diff_stats(
            candidate_wt,
            str(current.get("spec_baseline_sha") or ""),
            candidate_sha,
        )
        if not receipt_path.is_file() or util_mod.sha256_file(receipt_path) != receipt_sha256:
            raise RuntimeError("rollover BUILD_RECEIPT is absent or changed")
        receipt_doc = receipts_mod.load_receipt(canonical_repo, run_id)
        if not isinstance(receipt_doc, dict):
            raise RuntimeError("rollover BUILD_RECEIPT is invalid")
        receipts_mod.validate_receipt_contract(receipt_doc)
        source_check = receipt_doc.get("program_source_ceiling_check") or {}
        cumulative = program.get("cumulative_counters") or {}
        cumulative_ceilings = program.get("cumulative_ceilings") or {}
        top_budget = child_packet_meta.get("risk_budget") or {}
        effective_files = build_finalize_mod._strict_ceiling(
            int(top_budget.get("max_files_changed") or 0),
            int(cumulative_ceilings.get("max_unique_changed_files") or 0),
        )
        effective_lines = build_finalize_mod._strict_ceiling(
            int(top_budget.get("max_diff_lines") or 0),
            int(cumulative_ceilings.get("max_baseline_to_final_diff_lines") or 0),
        )
        if any((
            source_check.get("result") != "pass",
            source_check.get("accounting") != "absolute_baseline_to_candidate",
            source_check.get("files_changed_unique") != int(source_stats["files_changed"]),
            source_check.get("diff_lines_total") != int(source_stats["added_lines"] + source_stats["removed_lines"]),
            source_check.get("effective_max_files_changed") != effective_files,
            source_check.get("effective_max_diff_lines") != effective_lines,
            int(cumulative.get("files_changed_unique") or 0) != int(source_stats["files_changed"]),
            int(cumulative.get("diff_lines_total") or 0) != int(source_stats["added_lines"] + source_stats["removed_lines"]),
            effective_files > 0 and int(source_stats["files_changed"]) > effective_files,
            effective_lines > 0 and int(source_stats["added_lines"] + source_stats["removed_lines"]) > effective_lines,
        )):
            raise RuntimeError("rollover candidate does not pass exact PROGRAM source-ceiling proof")
        identity_reproof = receipt_doc.get("candidate_identity_reproof") or {}
        if any((
            identity_reproof.get("result") != "pass",
            identity_reproof.get("head_before_validation") != candidate_sha,
            identity_reproof.get("head_after_validation") != candidate_sha,
            identity_reproof.get("worktree_status_after_validation") != "clean",
            identity_reproof.get("canonical_branch_ok_after_validation") is not True,
        )):
            raise RuntimeError("rollover candidate identity reproof is incomplete")
        required_validation = program_mod.resolve_effective_required_validation(child_packet_meta, current)
        if (
            not isinstance(preflight_doc, dict)
            or preflight_doc.get("schema") != "ownframework-loop-rollover-preflight/v1"
            or preflight_doc.get("run_id") != run_id
            or preflight_doc.get("parent_run_id") != rollover.get("parent_run_id")
            or preflight_doc.get("rollover_authority_sha256") != rollover_authority_sha256
            or preflight_doc.get("candidate_sha") != candidate_sha
            or preflight_doc.get("packet_sha256") != util_mod.sha256_file(run_root / "WORK_PACKET.md")
            or preflight_doc.get("result") != "PASS"
            or preflight_doc.get("approval_sha256") != child_approval_sha
            or preflight_doc.get("candidate_branch") != child_approval_doc.get("candidate_branch")
            or preflight_doc.get("baseline_sha") != current.get("spec_baseline_sha")
            or preflight_doc.get("checkpoint_id") != cp_id
            or preflight_doc.get("build_pass_count_unchanged") != int(current.get("build_pass_count") or 0)
            or preflight_doc.get("repair_round_unchanged") != int(current.get("repair_round") or 0)
            or preflight_doc.get("candidate_identity_reproof") != "pass"
            or not program_rollover_mod._validation_rows_match(
                required_validation,
                preflight_doc.get("validations"),
                checkpoint_id=cp_id,
                pass_number=int(current.get("build_pass_count") or 0),
            )
            or authority_doc.get("child_packet_sha256") != preflight_doc.get("packet_sha256")
        ):
            raise RuntimeError("rollover validation preflight identity/result is invalid")
        origin = receipt_doc.get("candidate_origin") or {}
        if (
            origin.get("schema") != "ownframework-loop-candidate-origin/v1"
            or origin.get("rollover_authority_sha256") != rollover_authority_sha256
            or origin.get("parent_run_id") != rollover.get("parent_run_id")
            or origin.get("child_run_id") != run_id
            or origin.get("candidate_sha") != candidate_sha
            or origin.get("preflight_sha256") != preflight_sha256
            or origin.get("child_approval_sha256") != child_approval_sha
            or origin.get("parent_packet_sha256") != source.get("packet_sha256")
            or origin.get("parent_approval_sha256") != source.get("approval_sha256")
            or origin.get("parent_state_sha256") != source.get("state_sha256")
            or origin.get("parent_event_chain_sha256") != source.get("event_chain_sha256")
            or origin.get("parent_build_receipt_sha256") != source.get("build_receipt_sha256")
            or origin.get("parent_review_verdict_sha256") != source.get("review_verdict_sha256")
            or origin.get("parent_review_assessment_sha256") != source.get("review_assessment_sha256")
            or origin.get("parent_review_attempt_id") != source.get("review_attempt_id")
            or origin.get("parent_candidate_sha") != source.get("parent_candidate_sha")
            or origin.get("parent_candidate_branch") != source.get("parent_candidate_branch")
            or origin.get("child_packet_sha256") != child_packet_sha
            or origin.get("child_baseline_sha") != current.get("spec_baseline_sha")
            or origin.get("child_candidate_branch") != child_approval_doc.get("candidate_branch")
            or receipt_doc.get("candidate_sha") != candidate_sha
            or receipt_doc.get("run_id") != run_id
            or receipt_doc.get("packet_sha256") != preflight_doc.get("packet_sha256")
            or receipt_doc.get("approval_sha256") != child_approval_sha
            or receipt_doc.get("baseline_sha") != current.get("spec_baseline_sha")
            or receipt_doc.get("candidate_branch") != child_approval_doc.get("candidate_branch")
            or receipt_doc.get("builder_pass_number") != int(current.get("build_pass_count") or 0)
            or receipt_doc.get("repair_round") != int(current.get("repair_round") or 0)
            or receipt_doc.get("validation_status") != "PASS"
            or receipt_doc.get("validation") != preflight_doc.get("validations")
            or (receipt_doc.get("validation") and any(not v.get("passed") for v in receipt_doc["validation"]))
            or (receipt_doc.get("scope_check") or {}).get("result") != "pass"
            or (receipt_doc.get("protected_path_check") or {}).get("result") != "pass"
            or (receipt_doc.get("secret_scan_check") or {}).get("result") != "pass"
            or (receipt_doc.get("candidate_identity_reproof") or {}).get("result") != "pass"
            or (receipt_doc.get("program_source_ceiling_check") or {}).get("result") != "pass"
            or receipt_doc.get("next_state") != "READY_FOR_REVIEW"
        ):
            raise RuntimeError("rollover receipt does not authorize the exact review candidate")
        if current.get("last_candidate_sha") != candidate_sha:
            raise RuntimeError("rollover STATE candidate changed before review admission")
        packet_path = run_root / "WORK_PACKET.md"
        packet_meta, _ = packet_mod.parse_packet_file(packet_path)
        if not packet_mod.packet_is_program(packet_meta):
            raise RuntimeError("rollover packet is not PROGRAM mode")
        cp_id = str(rollover.get("checkpoint_id") or "")
        cp_state = next(
            (cp for cp in (program.get("checkpoints") or []) if cp.get("id") == cp_id),
            None,
        )
        if cp_state is None or cp_state.get("terminal"):
            raise RuntimeError("rollover checkpoint is absent or already terminal")
        cp_state["candidate_sha"] = candidate_sha
        cp_state["build_receipt_sha256"] = receipt_sha256

        now = utc_now_iso()
        new = dict(current)
        new_program = json.loads(integrity.canonical_json_dumps(program))
        new_rollover = dict(new_program["rollover_provenance"])
        new_rollover["preflight_sha256"] = preflight_sha256
        new_rollover["review_admission_receipt_sha256"] = receipt_sha256
        new_rollover["review_admitted_at"] = now
        new_program["rollover_provenance"] = new_rollover
        rollover_cp = next(
            (cp for cp in new_program["checkpoints"] if cp.get("id") == cp_id),
            None,
        )
        rollover_cp["candidate_sha"] = candidate_sha
        rollover_cp["build_receipt_sha256"] = receipt_sha256
        new["program"] = new_program
        new["state"] = "READY_FOR_REVIEW"
        new["transitions_count"] = int(current.get("transitions_count", 0)) + 1
        new["updated_at"] = now
        new["last_actor"] = "ofloop-program-rollover"
        history = list(current.get("state_history") or [])
        history.append({
            "from": "READY_TO_BUILD",
            "to": "READY_FOR_REVIEW",
            "at": now,
            "actor": "ofloop-program-rollover",
            "reason": "current candidate preflight passed; inherited build budget remains unchanged",
        })
        new["state_history"] = history
        from . import schema_validate
        state_errors = schema_validate.validate_state(new)
        if state_errors:
            raise ValueError(
                "rollover review-admission STATE schema invalid: "
                + "; ".join(state_errors[:20])
            )
        _commit_state_event_locked(
            canonical_repo,
            run_id,
            new,
            event_type="program_rollover_review_admitted",
            old_state="READY_TO_BUILD",
            new_state="READY_FOR_REVIEW",
            actor="ofloop-program-rollover",
            commit_sha=candidate_sha,
            reason="exact inherited candidate passed current deterministic validation and scope proof",
            extras={
                "rollover_authority_sha256": rollover_authority_sha256,
                "preflight_sha256": preflight_sha256,
                "rollover_receipt_sha256": receipt_sha256,
                "build_pass_count_unchanged": int(current.get("build_pass_count") or 0),
                "repair_round_unchanged": int(current.get("repair_round") or 0),
            },
        )
    try:
        fsync_dir(sp.parent)
    except OSError:
        pass
    return new


def atomic_patch(
    canonical_repo: Path,
    run_id: str,
    fields: dict[str, Any],
    *,
    actor: str,
    reason: str,
    event_type: str = "state_saved",
) -> dict[str, Any]:
    """Crash-atomic read-modify-write of NON-authoritative fields only.

    `fields` is validated against the structural field classes: every
    protocol-authoritative field (STATE_OWNER_FIELDS) is refused, and every
    accepted field must be explicitly enlisted in _STATE_PATCH_ALLOWED_FIELDS.
    The current state and every owner field are carried through unchanged.
    Because the read, mutation, and commit all happen under one flock + one
    STATE_TXN, there is no stale read->save lost-update window. Returns the
    committed payload.
    """
    _validate_patch_fields(fields)
    sp = state_path(canonical_repo, run_id)
    with flock_exclusive(lock_path(canonical_repo, run_id)):
        _verify_mutation_integrity_locked(canonical_repo, run_id)
        current = read_json(sp)
        if not isinstance(current, dict) or not current:
            raise FileNotFoundError(f"STATE.json missing for run {run_id}")
        new = dict(current)
        new.update(fields)
        new["updated_at"] = utc_now_iso()
        new["last_actor"] = actor
        _commit_state_event_locked(
            canonical_repo,
            run_id,
            new,
            event_type=event_type,
            old_state=current.get("state"),
            new_state=new.get("state"),
            actor=actor,
            commit_sha=new.get("last_candidate_sha"),
            reason=reason,
        )
    try:
        fsync_dir(sp.parent)
    except OSError:
        pass
    return new


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


def bind_mission_segment(
    canonical_repo: Path,
    run_id: str,
    *,
    mission_segment: dict[str, Any],
) -> dict[str, Any]:
    """Attach immutable core-derived mission identity to a v4 PROGRAM state.

    The mission module verifies the create-once mission/segment records before
    calling this typed owner. This state transaction makes the binding visible
    to ordinary PROGRAM verification without allowing a generic state write.
    Replays are accepted only when the exact same binding is already present.
    """
    validate_run_id(run_id)
    if not isinstance(mission_segment, dict):
        raise ValueError("mission_segment must be an object")
    from . import packet as packet_mod, schema_validate
    run_root = run_dir(canonical_repo, run_id)
    meta, _ = packet_mod.parse_packet_file(run_root / "WORK_PACKET.md")
    if (
        meta.get("schema") != packet_mod.MISSION_PROGRAM_SCHEMA_VERSION
        or not packet_mod.packet_is_program(meta)
    ):
        raise ValueError("mission segment binding requires a v4 PROGRAM packet")
    with _locked_state(canonical_repo, run_id) as cur:
        if not isinstance(cur, dict) or cur.get("run_id") != run_id:
            raise FileNotFoundError(f"STATE.json missing for {run_id}")
        prog = cur.get("program")
        if not isinstance(prog, dict):
            raise ValueError("mission segment binding requires materialized PROGRAM state")
        existing = prog.get("mission_segment")
        if existing is not None:
            if existing != mission_segment:
                raise RuntimeError("mission segment state binding conflicts with durable authority")
            return cur
        if cur.get("state") not in ("AWAITING_APPROVAL", "READY_TO_BUILD"):
            raise RuntimeError("mission segment identity must be bound before semantic execution")
        new = dict(cur)
        new_prog = json.loads(integrity.canonical_json_dumps(prog))
        new_prog["mission_segment"] = json.loads(integrity.canonical_json_dumps(mission_segment))
        new["program"] = new_prog
        new["updated_at"] = utc_now_iso()
        new["last_actor"] = "ofloop-mission"
        errors = schema_validate.validate_state(new)
        if errors:
            raise ValueError("mission segment state invalid: " + "; ".join(errors[:20]))
        _commit_state_event_locked(
            canonical_repo, run_id, new,
            event_type="mission_segment_bound",
            old_state=cur.get("state"), new_state=cur.get("state"),
            actor="ofloop-mission", commit_sha=cur.get("last_candidate_sha"),
            reason="bound v4 PROGRAM state to sealed mission segment",
            extras={
                "mission_id": mission_segment.get("mission_id"),
                "segment_number": mission_segment.get("segment_number"),
                "segment_authority_sha256": mission_segment.get("segment_authority_sha256"),
            },
        )
    try:
        fsync_dir(run_root)
    except OSError:
        pass
    return load_verified(canonical_repo, run_id)


def initialize_program_mission_segment(
    canonical_repo: Path,
    run_id: str,
    *,
    program_block: dict[str, Any],
    build_pass_count: int,
    review_pass_count: int,
    repair_round: int,
    no_progress_streak: int,
    candidate_sha: str,
    baseline_sha: str,
    baseline_branch: str,
    candidate_branch: str,
    mission_segment: dict[str, Any],
) -> dict[str, Any]:
    """Creation-only typed import of authorized checkpoint progress.

    Used only for a deterministic mission successor (including the explicit
    legacy-admission path). It preserves semantic/checkpoint counters and
    approved history, resets only segment-local source measurements, and
    cannot reopen or mutate an existing run.
    """
    validate_run_id(run_id)
    if not re.fullmatch(r"[0-9a-f]{40}", str(candidate_sha or "")):
        raise ValueError("mission segment baseline candidate must be a full Git SHA")
    if not re.fullmatch(r"[0-9a-f]{40}", str(baseline_sha or "")):
        raise ValueError("mission segment baseline must be a full Git SHA")
    if not isinstance(program_block, dict) or not isinstance(mission_segment, dict):
        raise ValueError("mission segment PROGRAM authority must be objects")
    if program_block.get("mission_segment") != mission_segment:
        raise ValueError("PROGRAM block mission identity does not match typed segment authority")
    from . import git_checks, packet as packet_mod, program as program_mod, schema_validate
    run_root = run_dir(canonical_repo, run_id)
    packet_path = run_root / "WORK_PACKET.md"
    if not packet_path.is_file():
        raise FileNotFoundError("mission successor WORK_PACKET.md is missing")
    meta, _ = packet_mod.parse_packet_file(packet_path)
    errors = packet_mod.validate_packet_for_approval(meta)
    if errors or meta.get("schema") != packet_mod.MISSION_PROGRAM_SCHEMA_VERSION:
        raise ValueError("mission successor packet invalid: " + "; ".join(errors[:20]))
    graph_ok, graph_reason = program_mod.verify_frozen_graph(meta, program_block)
    if not graph_ok:
        raise ValueError(f"mission successor frozen graph mismatch: {graph_reason}")
    if (meta.get("target") or {}).get("branch") != baseline_branch:
        raise ValueError("mission successor baseline branch differs from packet")
    target_head = git_checks.branch_head(canonical_repo, baseline_branch)
    if target_head != baseline_sha:
        raise ValueError("mission successor baseline branch does not resolve to exact baseline")
    current_checkpoints = program_block.get("current_checkpoints") or []
    if (
        not current_checkpoints
        or len(current_checkpoints) != len(set(current_checkpoints))
        or any(not isinstance(value, str) or not value for value in current_checkpoints)
    ):
        raise ValueError("mission successor must have a non-empty unique current-checkpoint set")
    counters = {
        "build_pass_count": _owner_int("build_pass_count", build_pass_count),
        "review_pass_count": _owner_int("review_pass_count", review_pass_count),
        "repair_round_count": _owner_int("repair_round", repair_round),
    }
    mirrors = program_block.get("cumulative_counters") or {}
    if any(int(mirrors.get(key, -1)) != value for key, value in counters.items()):
        raise ValueError("mission successor cumulative semantic counters do not reconcile")
    source = program_block.get("source_sha_provenance") or {}
    if source.get("baseline_sha") != baseline_sha or source.get("candidate_branch") != candidate_branch:
        raise ValueError("mission successor source provenance differs from segment identity")
    source_stats = program_mod.source_tree_accounting(
        canonical_repo=canonical_repo, baseline_sha=baseline_sha, candidate_sha=candidate_sha,
    )
    expected_lines = int(source_stats["diff_lines"])
    if int(mirrors.get("files_changed_unique", -1)) != int(source_stats["files_changed_unique"]) or int(mirrors.get("diff_lines_total", -1)) != expected_lines:
        raise ValueError("mission successor segment-local source accounting is inconsistent")

    sp = state_path(canonical_repo, run_id)
    with flock_exclusive(lock_path(canonical_repo, run_id)):
        _verify_mutation_integrity_locked(canonical_repo, run_id)
        cur = read_json(sp)
        if not isinstance(cur, dict) or cur.get("run_id") != run_id:
            raise FileNotFoundError(f"new mission segment STATE.json missing for {run_id}")
        if cur.get("state") != "AWAITING_APPROVAL" or cur.get("schema") != SCHEMA_VERSION:
            raise RuntimeError("mission segment import requires pristine AWAITING_APPROVAL state")
        if "program" in cur or any(int(cur.get(key) or 0) != 0 for key in (
            "build_pass_count", "review_pass_count", "repair_round",
        )):
            raise RuntimeError("mission segment import refuses already-used state")
        if cur.get("spec_baseline_sha") != baseline_sha or cur.get("spec_baseline_branch") != baseline_branch:
            raise RuntimeError("mission segment state snapshot differs from frozen baseline")
        new = dict(cur)
        new["schema"] = PROGRAM_STATE_SCHEMA_VERSION
        new["program"] = json.loads(integrity.canonical_json_dumps(program_block))
        new["build_pass_count"] = counters["build_pass_count"]
        new["review_pass_count"] = counters["review_pass_count"]
        new["repair_round"] = counters["repair_round_count"]
        new["no_progress_streak"] = _owner_int("no_progress_streak", no_progress_streak)
        new["last_candidate_sha"] = candidate_sha
        new["updated_at"] = utc_now_iso()
        new["last_actor"] = "ofloop-mission"
        state_errors = schema_validate.validate_state(new)
        if state_errors:
            raise ValueError("mission segment imported state invalid: " + "; ".join(state_errors[:20]))
        allocation_import_sha = None
        allocations = (program_block.get("semantic_budget_allocations") or [])
        if allocations:
            allocation_import_sha = hashlib.sha256(
                integrity.canonical_json_dumps(allocations).encode("utf-8")
            ).hexdigest()
        event_extras = {
            "mission_id": mission_segment.get("mission_id"),
            "segment_number": mission_segment.get("segment_number"),
            "predecessor_run_id": mission_segment.get("predecessor_run_id"),
            "segment_baseline_sha": baseline_sha,
        }
        if allocation_import_sha:
            event_extras["semantic_budget_import_sha256"] = allocation_import_sha
            event_extras["semantic_budget_import_count"] = len(allocations)
        _commit_state_event_locked(
            canonical_repo, run_id, new,
            event_type="mission_segment_materialized",
            old_state="AWAITING_APPROVAL", new_state="AWAITING_APPROVAL",
            actor="ofloop-mission", commit_sha=candidate_sha,
            reason="imported immutable approved checkpoint history into mission segment",
            extras=event_extras,
        )
    try:
        fsync_dir(sp.parent)
    except OSError:
        pass
    return load_verified(canonical_repo, run_id)


def _write_state_locked(
    canonical_repo: Path,
    run_id: str,
    payload: dict[str, Any],
    *,
    extras: dict[str, Any] | None = None,
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
        extras=extras,
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
    # Internal state transactions may attach state_txn_id; no other
    # authoritative event field can be supplied through extras.
    _validate_event_extras(extras, allow_state_txn_id=True)
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
    # Core-owned publication binding: every event snapshots every currently
    # present authoritative artifact. Callers cannot spoof these keys because
    # they are part of _EVENT_AUTHORITATIVE_FIELDS above.
    record.update(integrity.artifact_event_hashes(run_dir(canonical_repo, run_id)))
    if extras:
        record.update(extras)
    line = _json_dumps(record)
    chain_hash = _compute_chain_hash_for_append(ep, line, state_sha_now)
    record["event_chain_sha256"] = chain_hash
    line = _json_dumps(record)

    ep.parent.mkdir(parents=True, exist_ok=True)
    existing = ep.read_bytes() if ep.exists() else b""
    tmp = _event_append_tmp_path(canonical_repo, run_id)
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
    """Append one verified event atomically under the per-run flock.

    Caller-supplied extras are diagnostic only. They cannot override run/state/
    chain identity or spoof the internal state_txn_id recovery marker.
    """
    _validate_event_extras(extras)
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
    no_progress_streak: int | None = None,
    build_pass_count: int | None = None,
    identical_finding_streak: int | None = None,
    last_must_fix_fingerprint: str | None = None,
    program_block: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Atomically transition state under flock, appending an event.

    The flock is held only for the read-modify-write of STATE.json. The
    audit event is appended after the lock is released to avoid re-entrant
    flock acquisition on the same file (which is not guaranteed to be
    re-entrant across open file descriptions on all POSIX kernels).

    Before transitioning, this function loads STATE.json *and* verifies
    its recorded SHA. If the file was edited externally, we raise
    `integrity.TamperingDetected`.

    Authoritative field updates travel ONLY through the typed owner
    parameters (validated, non-generic). `commit_sha` owns
    `last_candidate_sha`; terminal states own `terminal_reason`. Generic
    `extras` are structurally refused: diagnostics belong in append_event().
    """
    _validate_state_extras(extras, owner="transition")
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
        if to_state == "SEGMENT_BOUNDARY":
            # This terminal state is reserved for a clean, source-cap-only
            # v4 mission boundary. Ordinary callers, v1-v3 packets, and
            # non-PROGRAM runs cannot manufacture it through the generic FSM.
            from . import packet as _packet_mod, receipts as _receipts_mod

            packet_path = run_dir(canonical_repo, run_id) / "WORK_PACKET.md"
            try:
                boundary_meta, _ = _packet_mod.parse_packet_file(packet_path)
            except Exception as exc:
                raise transitions.InvalidTransitionError(
                    "SEGMENT_BOUNDARY requires a readable sealed v4 PROGRAM packet"
                ) from exc
            receipt = _receipts_mod.load_receipt(canonical_repo, run_id)
            proof = (receipt or {}).get("segment_boundary") if isinstance(receipt, dict) else None
            source = (receipt or {}).get("program_source_ceiling_check") if isinstance(receipt, dict) else None
            if (
                from_state != "BUILDING"
                or boundary_meta.get("schema") != _packet_mod.MISSION_PROGRAM_SCHEMA_VERSION
                or not _packet_mod.packet_is_program(boundary_meta)
                or not is_program_state(current)
                or not isinstance((current.get("program") or {}).get("mission_segment"), dict)
                or not isinstance(receipt, dict)
                or receipt.get("next_state") != "SEGMENT_BOUNDARY"
                or receipt.get("candidate_sha") != commit_sha
                or receipt.get("validation_status") != "PASS"
                or not isinstance(proof, dict)
                or proof.get("result") != "authorized"
                or proof.get("source_candidate_sha") != commit_sha
                or not isinstance(source, dict)
                or source.get("result") != "fail"
                or source.get("mission_budget_result") != "pass"
                or (receipt.get("scope_check") or {}).get("result") != "pass"
                or (receipt.get("protected_path_check") or {}).get("result") != "pass"
                or (receipt.get("secret_scan_check") or {}).get("result") != "pass"
                or (receipt.get("candidate_identity_reproof") or {}).get("result") != "pass"
            ):
                raise transitions.InvalidTransitionError(
                    "SEGMENT_BOUNDARY lacks exact v4 source-cap-only finalizer evidence"
                )
            # The finalizer's proof is evidence, not authority by itself. Re-run
            # the deterministic boundary adjudication against the state held
            # under this lock, the sealed mission records, the event chain, and
            # the exact candidate/source measurements before making the state
            # terminal. This prevents a structurally valid but fabricated
            # receipt from manufacturing successor authority.
            from . import program as _program_mod, program_mission as _mission_mod
            from . import schema_validate as _schema_validate

            receipt_errors = _schema_validate.validate_receipt(receipt)
            if receipt_errors:
                raise transitions.InvalidTransitionError(
                    "SEGMENT_BOUNDARY receipt is schema-invalid: " + "; ".join(receipt_errors[:5])
                )
            validation_rows = receipt.get("validation")
            expected_validations = _program_mod.resolve_effective_required_validation(
                boundary_meta, current,
            )
            validation_rows_match = (
                isinstance(validation_rows, list)
                and len(validation_rows) == len(expected_validations)
                and all(
                    isinstance(row, dict)
                    and row.get("name") == expected.get("name")
                    and row.get("command") == expected.get("command")
                    and row.get("kind") == expected.get("kind")
                    and row.get("expected_exit_code") == int(expected.get("expected_exit_code", 0))
                    and row.get("expected_marker") == expected.get("expected_marker")
                    and row.get("passed") is True
                    and row.get("timed_out") is not True
                    and row.get("infra_failure") is not True
                    and row.get("candidate_invalid") is not True
                    for row, expected in zip(validation_rows, expected_validations)
                )
            )
            if (
                receipt.get("outcome_requested") != "candidate_ready"
                or not validation_rows_match
                or receipt.get("validation_status") != "PASS"
                or int((receipt.get("infra_failure") or {}).get("count") or 0) != 0
                or int((receipt.get("candidate_environment_invalid") or {}).get("count") or 0) != 0
            ):
                raise transitions.InvalidTransitionError(
                    "SEGMENT_BOUNDARY requires candidate-ready semantic output and exact passing validation evidence"
                )
            try:
                segment_context = _mission_mod.load_segment(
                    canonical_repo, run_id, state_snapshot=current,
                )
                if segment_context is None:
                    raise _mission_mod.MissionAuthorityError("v4 segment authority is missing")
                authorized, recomputed_proof = _mission_mod.segment_boundary_eligibility(
                    canonical_repo,
                    run_id,
                    meta=boundary_meta,
                    current_state=current,
                    candidate_sha=str(commit_sha or ""),
                    source_check=source,
                    validation_pass=True,
                    infra_failure_count=0,
                    identity_reproof=receipt.get("candidate_identity_reproof") or {},
                    scope_findings=(receipt.get("scope_check") or {}).get("findings") or [],
                    protected_findings=(receipt.get("protected_path_check") or {}).get("offending_paths") or [],
                    hard_secret_blocks=[
                        item for item in ((receipt.get("secret_scan_check") or {}).get("findings") or [])
                        if isinstance(item, dict) and item.get("severity") == "hard"
                    ],
                    outcome_requested=receipt.get("outcome_requested"),
                    candidate_invalid_count=int(
                        (receipt.get("candidate_environment_invalid") or {}).get("count") or 0
                    ),
                    segment_context=segment_context,
                )
            except Exception as exc:
                raise transitions.InvalidTransitionError(
                    f"SEGMENT_BOUNDARY authority recomputation failed: {type(exc).__name__}"
                ) from exc
            if not authorized or recomputed_proof != proof:
                raise transitions.InvalidTransitionError(
                    "SEGMENT_BOUNDARY recomputed authority differs from the finalizer receipt"
                )
        transitions.assert_valid(from_state, to_state)

        now = utc_now_iso()
        new = dict(current)
        new["state"] = to_state
        new["transitions_count"] = int(current.get("transitions_count", 0)) + 1
        new["updated_at"] = now
        new["last_actor"] = actor
        if commit_sha:
            new["last_candidate_sha"] = commit_sha
        if to_state in ("APPROVED", "BLOCKED", "STOPPED", "SEGMENT_BOUNDARY"):
            new["terminal_reason"] = reason
        history = list(current.get("state_history", []))
        history.append({"from": from_state, "to": to_state, "at": now, "actor": actor, "reason": reason})
        new["state_history"] = history
        if no_progress_streak is not None:
            new["no_progress_streak"] = _owner_int("no_progress_streak", no_progress_streak)
        if build_pass_count is not None:
            new["build_pass_count"] = _owner_int("build_pass_count", build_pass_count)
        if identical_finding_streak is not None:
            new["identical_finding_streak"] = _owner_int(
                "identical_finding_streak", identical_finding_streak
            )
        if last_must_fix_fingerprint is not None:
            new["last_must_fix_fingerprint"] = str(last_must_fix_fingerprint)
        if program_block is not None:
            if not isinstance(program_block, dict) or not program_block:
                raise ValueError("typed owner field 'program_block' must be a non-empty dict")
            if not is_program_state(current):
                raise ValueError("program_block supplied for a non-PROGRAM run")
            new["program"] = program_block

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


def transition_funded_repair(
    canonical_repo: Path,
    run_id: str,
    *,
    packet: dict[str, Any],
    actor: str,
    commit_sha: str,
    no_progress_streak: int | None = None,
    program_block: dict[str, Any] | None = None,
    identical_finding_streak: int | None = None,
    last_must_fix_fingerprint: str | None = None,
    allowed_sources: frozenset[str] = frozenset({"REVIEWING"}),
    claimed_reason: str = "repair entitlement claimed atomically",
) -> dict[str, Any]:
    """Atomically fund a repair entitlement while moving to CHANGES_REQUESTED.

    `<allowed_sources>` -> CHANGES_REQUESTED and the exact repair entitlement
    are one STATE_TXN-backed mutation.  When the repair envelope is exhausted
    the same mutation seals BLOCKED instead, so no crash boundary can ever
    expose an unfunded / claimable CHANGES_REQUESTED state.  This is the single
    crash-atomic funding owner shared by the live review finalizer, crash
    reconciliation, and the foreground repair transition (SINGLE + PROGRAM).

    This owner has NO generic extras channel. The caller supplies the already
    computed candidate-convergence streak and, when needed, the already
    computed PROGRAM accounting block. Repair funding, accounting, and the
    streak update stay in this same atomic owner.
    """
    sp = state_path(canonical_repo, run_id)
    with flock_exclusive(lock_path(canonical_repo, run_id)):
        _verify_mutation_integrity_locked(canonical_repo, run_id)
        current = read_json(sp)
        if not isinstance(current, dict) or not current:
            raise FileNotFoundError(f"STATE.json missing for run {run_id}")
        from_state = current.get("state")
        if from_state not in allowed_sources:
            raise RuntimeError(
                "atomic funded repair requires state in "
                f"{sorted(allowed_sources)}, got {from_state!r}"
            )

        new = dict(current)
        repair_claimed = False
        repair_block_reason = ""
        if is_program_state(current):
            from . import program as program_mod
            program_state = current.get("program")
            if not isinstance(program_state, dict):
                raise RuntimeError("PROGRAM review rejection missing program block")
            ok, reason = program_mod.verify_frozen_graph(packet, program_state)
            if not ok:
                raise RuntimeError(
                    f"PROGRAM review rejection frozen-graph drift: {reason}"
                )
            mirror = int(current.get("repair_round", 0) or 0)
            cumulative = int(
                program_state["cumulative_counters"].get("repair_round_count", 0)
            )
            if mirror != cumulative:
                raise RuntimeError(
                    f"repair counter mirror drift: top={mirror}, cumulative={cumulative}"
                )
            # v0.9.1+: when program.review_scope == "program_final" there is
            # no current checkpoint; the final review's repair entitlement
            # is funded against the program-wide cumulative cap only.
            if (
                isinstance(program_state, dict)
                and program_state.get("review_scope")
                == program_mod.REVIEW_SCOPE_PROGRAM_FINAL
            ):
                cum_cap = int(program_state["cumulative_ceilings"]["max_repair_rounds"])
                if cumulative >= cum_cap:
                    target = "BLOCKED"
                    repair_block_reason = (
                        f"repair claim refused (cap exhausted): "
                        f"program-wide {cumulative}/{cum_cap}"
                    )
                else:
                    new_program = json.loads(integrity.canonical_json_dumps(program_state))
                    new_program["cumulative_counters"]["repair_round_count"] = (
                        cumulative + 1
                    )
                    new["program"] = new_program
                    new["repair_round"] = mirror + 1
                    target = "CHANGES_REQUESTED"
                    repair_claimed = True
            else:
                cp_id = program_mod.select_next_checkpoint(packet, program_state)
                if cp_id is None:
                    raise RuntimeError("PROGRAM review rejection has no current checkpoint")
                packet_cp = program_mod._resolve_packet_cp(packet, cp_id)
                try:
                    new_program = program_mod._bump_counter_one(
                        program_state,
                        cp_id=cp_id,
                        counter="repair_round_count",
                        packet_cp=packet_cp,
                        packet=packet,
                        state_doc=current,
                        run_id=run_id,
                    )
                except program_mod.ProgramStateError as exc:
                    target = "BLOCKED"
                    repair_block_reason = f"repair claim refused (cap exhausted): {exc}"
                else:
                    cp_new = program_mod._find_cp(new_program, cp_id)
                    ev_map = dict(cp_new.get("last_evidence_sha_by_counter") or {})
                    ev_map["repair_round_count"] = commit_sha
                    cp_new["last_evidence_sha_by_counter"] = ev_map
                    new["program"] = new_program
                    new["repair_round"] = mirror + 1
                    target = "CHANGES_REQUESTED"
                    repair_claimed = True
        else:
            current_round = int(current.get("repair_round", 0) or 0)
            cap = limits_mod.effective_cap("repair_round", packet)
            if cap is not None and current_round >= cap:
                target = "BLOCKED"
                repair_block_reason = (
                    f"repair claim refused (cap exhausted): "
                    f"repair_round={current_round} cap={cap}"
                )
            else:
                new["repair_round"] = current_round + 1
                target = "CHANGES_REQUESTED"
                repair_claimed = True

        transitions.assert_valid(from_state, target)
        now = utc_now_iso()
        new["state"] = target
        new["transitions_count"] = int(current.get("transitions_count", 0)) + 1
        new["updated_at"] = now
        new["last_actor"] = actor
        # Only rebind the candidate when the caller proved one; an empty
        # commit_sha must not clobber the run's bound candidate.
        if commit_sha:
            new["last_candidate_sha"] = commit_sha
        history = list(current.get("state_history", []))
        reason = claimed_reason if repair_claimed else repair_block_reason
        history.append({
            "from": from_state,
            "to": target,
            "at": now,
            "actor": actor,
            "reason": reason,
        })
        new["state_history"] = history
        if target == "BLOCKED":
            new["terminal_reason"] = reason
        if program_block is not None:
            if not isinstance(program_block, dict) or not program_block:
                raise ValueError("typed owner field 'program_block' must be a non-empty dict")
            if not is_program_state(current):
                raise ValueError("program_block supplied for a non-PROGRAM run")
            # The finalizer supplies a pre-transition snapshot with only
            # absolute source-accounting fields updated. Start with this
            # atomic owner's post-funding state so checkpoint-local repair
            # counts and last-evidence bindings survive as well as the
            # cumulative mirror. Copy only the two caller-owned source stats.
            new["program"] = _merge_funded_repair_program_block(
                current_program=current.get("program") or {},
                funded_program=new.get("program") or {},
                source_program=program_block,
            )
        # Owner-owned: preserve the finalizer's candidate-convergence result
        # inside the same atomic funding mutation. A missing value retains the
        # historical fresh-context default for callers without a candidate
        # comparison (for example review rejection).
        new["no_progress_streak"] = (
            _owner_int("no_progress_streak", no_progress_streak)
            if no_progress_streak is not None
            else 0
        )
        if identical_finding_streak is not None:
            new["identical_finding_streak"] = _owner_int(
                "identical_finding_streak", identical_finding_streak
            )
        if last_must_fix_fingerprint is not None:
            new["last_must_fix_fingerprint"] = str(last_must_fix_fingerprint)

        extras = {}
        old_allocations = (current.get("program") or {}).get("semantic_budget_allocations") or []
        new_allocations = (new.get("program") or {}).get("semantic_budget_allocations") or []
        if repair_claimed and len(new_allocations) > len(old_allocations):
            allocation = new_allocations[-1]
            extras = {
                "semantic_budget_allocation_id": allocation["allocation_id"],
                "semantic_budget_allocation_sha256": hashlib.sha256(
                    integrity.canonical_json_dumps(allocation).encode("utf-8")
                ).hexdigest(),
                "semantic_budget_counter_kind": "repair_round_count",
            }
        _commit_state_event_locked(
            canonical_repo,
            run_id,
            new,
            event_type="state_transition",
            old_state=from_state,
            new_state=target,
            actor=actor,
            commit_sha=commit_sha,
            reason=reason,
            extras=extras,
        )
    try:
        fsync_dir(sp.parent)
    except OSError:
        pass
    return {
        "state": target,
        "repair_claimed": repair_claimed,
        "repair_round": int(new.get("repair_round", 0) or 0),
        "reason": reason,
    }


def _merge_funded_repair_program_block(
    *,
    current_program: dict[str, Any],
    funded_program: dict[str, Any],
    source_program: dict[str, Any],
) -> dict[str, Any]:
    """Preserve repair-owner mutations while accepting source stats only."""
    if not all(isinstance(item, dict) and item for item in (
        current_program, funded_program, source_program,
    )):
        raise ValueError("funded repair PROGRAM merge requires three non-empty objects")
    source_keys = ("files_changed_unique", "diff_lines_total")

    def without_source_stats(value: dict[str, Any]) -> dict[str, Any]:
        result = json.loads(integrity.canonical_json_dumps(value))
        counters = result.get("cumulative_counters")
        if isinstance(counters, dict):
            for key in source_keys:
                counters.pop(key, None)
        return result

    if without_source_stats(current_program) != without_source_stats(source_program):
        raise ValueError(
            "funded repair PROGRAM snapshot contains changes beyond source accounting"
        )
    merged = json.loads(integrity.canonical_json_dumps(funded_program))
    merged_counters = merged.get("cumulative_counters")
    source_counters = source_program.get("cumulative_counters")
    if not isinstance(merged_counters, dict) or not isinstance(source_counters, dict):
        raise ValueError("funded repair PROGRAM cumulative counters are malformed")
    for key in source_keys:
        value = source_counters.get(key)
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            raise ValueError(f"funded repair source accounting {key} is invalid")
        merged_counters[key] = value
    return merged


def transition_review_rejection_with_repair(
    canonical_repo: Path,
    run_id: str,
    *,
    packet: dict[str, Any],
    actor: str,
    commit_sha: str,
    identical_finding_streak: int | None = None,
    last_must_fix_fingerprint: str | None = None,
) -> dict[str, Any]:
    """Atomically fund a rejected review before exposing repair execution.

    REVIEWING -> CHANGES_REQUESTED and the exact repair entitlement are one
    STATE_TXN-backed mutation.  When the repair envelope is exhausted the same
    mutation seals BLOCKED instead, so no crash boundary can expose an unfunded
    builder state.  Thin REVIEWING-pinned wrapper over transition_funded_repair.
    """
    return transition_funded_repair(
        canonical_repo,
        run_id,
        packet=packet,
        actor=actor,
        commit_sha=commit_sha,
        identical_finding_streak=identical_finding_streak,
        last_must_fix_fingerprint=last_must_fix_fingerprint,
        allowed_sources=frozenset({"REVIEWING"}),
        claimed_reason="review rejected; repair entitlement claimed atomically",
    )


_SINGLE_CLAIM_SPECS: dict[str, tuple[str, str, frozenset[str]]] = {
    "build": ("build_pass_count", "BUILDING", frozenset({"READY_TO_BUILD", "CHANGES_REQUESTED"})),
    "review": ("review_pass_count", "REVIEWING", frozenset({"READY_FOR_REVIEW"})),
}


def _single_claim_history_count(current: dict[str, Any], target: str) -> int:
    history = current.get("state_history") or []
    if not isinstance(history, list):
        raise RuntimeError("single claim state_history is malformed")
    return sum(
        1 for item in history
        if isinstance(item, dict) and item.get("to") == target
    )


def claim_single_pass(
    canonical_repo: Path,
    run_id: str,
    *,
    pass_kind: str,
    actor: str,
    packet: dict[str, Any] | None,
) -> dict[str, Any]:
    """Atomically claim one SINGLE build/review pass.

    State transition, cap check and pass-counter funding are ONE STATE_TXN.
    A replay is accepted only when the in-flight state has a matching funded
    transition count. Historical pre-v0.9.1 crashes that persisted the state
    transition but not its counter are deterministically healed (or BLOCKED
    when the missing entitlement would exceed the cap).
    """
    spec = _SINGLE_CLAIM_SPECS.get(pass_kind)
    if spec is None:
        raise ValueError(f"unsupported single pass kind: {pass_kind!r}")
    counter, target, allowed_sources = spec
    sp = state_path(canonical_repo, run_id)
    with flock_exclusive(lock_path(canonical_repo, run_id)):
        _verify_mutation_integrity_locked(canonical_repo, run_id)
        current = read_json(sp)
        if not isinstance(current, dict) or not current:
            raise FileNotFoundError(f"STATE.json missing for run {run_id}")
        if is_program_state(current):
            raise RuntimeError("single-pass claim owner refuses PROGRAM state")
        cur_state = str(current.get("state") or "")
        count = int(current.get(counter, 0) or 0)
        cap = limits_mod.effective_cap(counter, packet)
        history_claims = _single_claim_history_count(current, target)

        # Idempotent replay, including deterministic recovery of the historical
        # transition->counter crash window from older source generations.
        if cur_state == target:
            if history_claims == count and count > 0:
                return {
                    "ok": True, "state": target, "counter": counter,
                    "claimed_pass_number": count, "cap": cap,
                    "replayed": True, "recovered": False,
                }
            if history_claims == count + 1:
                if cap is not None and count >= cap:
                    new = dict(current)
                    now = utc_now_iso()
                    reason = (
                        f"{pass_kind} claim recovery refused: missing entitlement "
                        f"would exceed cap {count}/{cap}"
                    )
                    transitions.assert_valid(cur_state, "BLOCKED")
                    new["state"] = "BLOCKED"
                    new["transitions_count"] = int(current.get("transitions_count", 0)) + 1
                    new["updated_at"] = now
                    new["last_actor"] = actor
                    new["terminal_reason"] = reason
                    history = list(current.get("state_history") or [])
                    history.append({
                        "from": cur_state, "to": "BLOCKED", "at": now,
                        "actor": actor, "reason": reason,
                    })
                    new["state_history"] = history
                    _commit_state_event_locked(
                        canonical_repo, run_id, new,
                        event_type="state_transition",
                        old_state=cur_state, new_state="BLOCKED",
                        actor=actor, reason=reason,
                        extras={"claim_counter": counter, "claim_cap": cap},
                    )
                    raise limits_mod.RepairLimitExceeded(reason)
                new = dict(current)
                new[counter] = count + 1
                new["updated_at"] = utc_now_iso()
                new["last_actor"] = actor
                _commit_state_event_locked(
                    canonical_repo, run_id, new,
                    event_type=f"{pass_kind}_claim_recovered",
                    old_state=target, new_state=target,
                    actor=actor,
                    reason="recovered legacy in-flight claim funding",
                    extras={
                        "claim_counter": counter,
                        "claimed_pass_number": count + 1,
                        "claim_cap": cap,
                    },
                )
                return {
                    "ok": True, "state": target, "counter": counter,
                    "claimed_pass_number": count + 1, "cap": cap,
                    "replayed": False, "recovered": True,
                }
            raise RuntimeError(
                f"{pass_kind} in-flight claim/counter drift: "
                f"state_history_claims={history_claims} {counter}={count}"
            )

        if cur_state not in allowed_sources:
            raise transitions.InvalidTransitionError(
                f"{pass_kind} claim refused in state {cur_state!r}; "
                f"allowed={sorted(allowed_sources)}"
            )
        if cap is not None and count >= cap:
            new = dict(current)
            now = utc_now_iso()
            reason = f"{pass_kind} claim refused: {counter}={count} reached cap={cap}"
            transitions.assert_valid(cur_state, "BLOCKED")
            new["state"] = "BLOCKED"
            new["transitions_count"] = int(current.get("transitions_count", 0)) + 1
            new["updated_at"] = now
            new["last_actor"] = actor
            new["terminal_reason"] = reason
            history = list(current.get("state_history") or [])
            history.append({
                "from": cur_state, "to": "BLOCKED", "at": now,
                "actor": actor, "reason": reason,
            })
            new["state_history"] = history
            _commit_state_event_locked(
                canonical_repo, run_id, new,
                event_type="state_transition",
                old_state=cur_state, new_state="BLOCKED",
                actor=actor, reason=reason,
                extras={"claim_counter": counter, "claim_cap": cap},
            )
            raise limits_mod.RepairLimitExceeded(reason)

        # READY_TO_BUILD -> BUILDING and READY_FOR_REVIEW -> REVIEWING are
        # ordinary FSM edges. CHANGES_REQUESTED -> BUILDING is a narrow claim-
        # owner recovery edge for a SINGLE run that crashed before its normal
        # READY_TO_BUILD post-hook.
        if not (pass_kind == "build" and cur_state == "CHANGES_REQUESTED"):
            transitions.assert_valid(cur_state, target)

        now = utc_now_iso()
        new = dict(current)
        new["state"] = target
        new[counter] = count + 1
        new["transitions_count"] = int(current.get("transitions_count", 0)) + 1
        new["updated_at"] = now
        new["last_actor"] = actor
        history = list(current.get("state_history") or [])
        history.append({
            "from": cur_state, "to": target, "at": now,
            "actor": actor, "reason": f"claim {pass_kind} pass",
        })
        new["state_history"] = history
        _commit_state_event_locked(
            canonical_repo, run_id, new,
            event_type="state_transition",
            old_state=cur_state, new_state=target,
            actor=actor, reason=f"claim {pass_kind} pass",
            extras={
                "claim_counter": counter,
                "claimed_pass_number": count + 1,
                "claim_cap": cap,
            },
        )
        return {
            "ok": True, "state": target, "counter": counter,
            "claimed_pass_number": count + 1, "cap": cap,
            "replayed": False, "recovered": False,
        }


def increment_counter(
    canonical_repo: Path,
    run_id: str,
    *,
    counter: str,
    actor: str,
    packet: dict[str, Any] | None = None,
    hard_cap: bool = True,
) -> int:
    """Retired generic counter-mutation seam.

    All protocol counters have deterministic owners. SINGLE build/review pass
    entitlement is owned by claim_single_pass(); PROGRAM counters by the
    unified PROGRAM claim owner; repair/no-progress counters by their dedicated
    funding/finalization owners. The compatibility symbol remains fail-closed
    so an old caller cannot silently regain generic STATE write authority.
    """
    raise ValueError(
        "increment_counter() is retired; protocol counters require their "
        "deterministic claim/funding/finalization owner"
    )


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
    program_block: dict[str, Any] | None = None,
    schema_version: str | None = None,
    identical_finding_streak: int | None = None,
    last_must_fix_fingerprint: str | None = None,
) -> dict[str, Any]:
    """Atomic PROGRAM-mode state transition + event append under one flock.

    PROGRAM-mode transitions never bypass the FSM via raw state writes.
    Every deterministic program transition goes through this function, which:

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

    This is the sole owner of PROGRAM top-level state changes. PROGRAM
    sub-object updates travel through the typed `program_block` parameter
    (validated as a dict) — never through generic extras and never through
    save(), which is creation-only. Generic `extras` are structurally
    refused; diagnostics belong in append_event().

    Returns the new state document.
    """
    _validate_state_extras(extras, owner="program_transition")
    if to_state == "SEGMENT_BOUNDARY":
        raise transitions.InvalidTransitionError(
            "SEGMENT_BOUNDARY is a build-finalizer-only v4 boundary, not a PROGRAM review transition"
        )
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
        if program_block is not None and (
            not isinstance(program_block, dict) or not program_block
        ):
            raise ValueError(
                "typed owner field 'program_block' must be a non-empty dict"
            )
        prospective_program = (
            program_block if program_block is not None else current.get("program")
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
        # state transition.
        if commit_sha and current.get("last_candidate_sha") and commit_sha != current["last_candidate_sha"]:
            raise transitions.InvalidTransitionError(
                f"bound_candidate_sha mismatch: provided={commit_sha[:12]} "
                f"last={current['last_candidate_sha'][:12]}"
            )
        transitions.assert_valid_program(
            from_state, to_state,
            has_more_checkpoints=has_more_cps,
        )

        now = utc_now_iso()
        new = dict(current)
        new["state"] = to_state
        new["transitions_count"] = int(current.get("transitions_count", 0)) + 1
        new["updated_at"] = now
        new["last_actor"] = actor
        if commit_sha:
            new["last_candidate_sha"] = commit_sha
        if to_state in ("APPROVED", "BLOCKED", "STOPPED", "SEGMENT_BOUNDARY"):
            new["terminal_reason"] = reason
        elif from_state in ("APPROVED", "BLOCKED", "STOPPED"):
            # Leaving a terminal state through a PROGRAM continuation
            # invalidates the prior termination reason; a stale value would
            # make a continuing run read as still terminated.
            new["terminal_reason"] = ""
        history = list(current.get("state_history", []))
        history.append({
            "from": from_state, "to": to_state, "at": now,
            "actor": actor, "reason": reason,
        })
        new["state_history"] = history
        if program_block is not None:
            new["program"] = program_block
        if schema_version is not None:
            new["schema"] = str(schema_version)
        if identical_finding_streak is not None:
            new["identical_finding_streak"] = _owner_int(
                "identical_finding_streak", identical_finding_streak
            )
        if last_must_fix_fingerprint is not None:
            new["last_must_fix_fingerprint"] = str(last_must_fix_fingerprint)

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


def retry_blocked_program_review_after_validation_infrastructure(
    canonical_repo: Path,
    run_id: str,
    *,
    packet: dict[str, Any],
    checkpoint_id: str,
    candidate_sha: str,
    review_attempt_id: str,
    semantic_sha256: str,
    prior_verdict_sha256: str,
    recovery_id: str,
    prior_runtime_generation: str,
    runtime_generation: str,
    packet_sha256: str,
    approval_sha256: str,
    build_receipt_sha256: str,
    prior_capability_binding_sha256: str,
    capability_binding_sha256: str,
    validation_evidence_sha256: str,
    checkpoint_build_pass_count: int,
    checkpoint_review_pass_count: int,
    checkpoint_repair_round_count: int,
    preflight_sha256: str,
    accounting_sha256: str,
) -> dict[str, Any]:
    """Reopen only the same accepted review after validator infrastructure repair.

    This is a deliberately narrow PROGRAM state owner, not a general escape
    from BLOCKED.  The supervisor proves the accepted semantic attempt,
    candidate, packet, approval, prior blocked verdict, durable broker
    evidence, worktrees, runtime-generation boundary, and one-use recovery
    receipt before calling this function. This owner independently re-proves
    the frozen graph, current checkpoint, terminality, candidate binding, and
    preceding review event under the STATE/EVENTS lock. No engineering or
    repair counter moves.

    The ordinary FSM remains unchanged: STOPPED and other BLOCKED runs still
    have no transition out.  The specialized event identity makes a crash
    replay idempotent without accepting an unrelated REVIEWING state.
    """
    validate_run_id(run_id)
    for label, value in (
        ("candidate_sha", candidate_sha),
        ("semantic_sha256", semantic_sha256),
        ("prior_verdict_sha256", prior_verdict_sha256),
        ("recovery_id", recovery_id),
        ("packet_sha256", packet_sha256),
        ("approval_sha256", approval_sha256),
        ("build_receipt_sha256", build_receipt_sha256),
        ("prior_capability_binding_sha256", prior_capability_binding_sha256),
        ("capability_binding_sha256", capability_binding_sha256),
        ("validation_evidence_sha256", validation_evidence_sha256),
        ("preflight_sha256", preflight_sha256),
        ("accounting_sha256", accounting_sha256),
    ):
        if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}" if label != "candidate_sha" else r"[0-9a-f]{40}", value):
            raise ValueError(f"{label} is invalid")
    if not isinstance(review_attempt_id, str) or not re.fullmatch(r"[0-9a-f]{32,64}", review_attempt_id):
        raise ValueError("review_attempt_id is invalid")
    if (
        not isinstance(prior_runtime_generation, str)
        or not prior_runtime_generation
        or not isinstance(runtime_generation, str)
        or not runtime_generation
        or prior_runtime_generation == runtime_generation
    ):
        raise ValueError("validation recovery requires distinct proven runtime generations")

    sp = state_path(canonical_repo, run_id)
    ep = events_path(canonical_repo, run_id)
    with flock_exclusive(lock_path(canonical_repo, run_id)):
        _verify_mutation_integrity_locked(canonical_repo, run_id)
        current = read_json(sp)
        if not isinstance(current, dict) or current.get("schema") != PROGRAM_STATE_SCHEMA_VERSION:
            raise ValueError("PROGRAM state required for validation-infrastructure retry")
        if current.get("state") == "STOPPED":
            raise transitions.InvalidTransitionError(
                "STOPPED is absorbing; validation-infrastructure retry refused"
            )
        if not is_program_state(current):
            raise ValueError("PROGRAM state required for validation-infrastructure retry")

        program_state = current.get("program") or {}
        from . import program as program_mod
        frozen_ok, frozen_reason = program_mod.verify_frozen_graph(packet, program_state)
        if not frozen_ok:
            raise ValueError(f"PROGRAM frozen-graph verification failed: {frozen_reason}")
        active_checkpoint = program_mod.select_next_checkpoint(packet, program_state)
        if active_checkpoint != checkpoint_id:
            raise transitions.InvalidTransitionError(
                "validation-infrastructure retry checkpoint does not match the active checkpoint"
            )
        if str(current.get("last_candidate_sha") or "") != candidate_sha:
            raise transitions.InvalidTransitionError(
                "validation-infrastructure retry candidate does not match STATE.json"
            )
        if program_state.get("blocked") is True:
            raise transitions.InvalidTransitionError(
                "PROGRAM authority is blocked; infrastructure review retry refused"
            )

        cp_state = next(
            (item for item in (program_state.get("checkpoints") or [])
             if isinstance(item, dict) and item.get("id") == checkpoint_id),
            None,
        )
        cp_packet = next(
            (item for item in ((packet.get("checkpoint_graph") or {}).get("checkpoints") or [])
             if isinstance(item, dict) and item.get("id") == checkpoint_id),
            None,
        )
        if cp_state is None or cp_packet is None:
            raise ValueError("active checkpoint is missing from frozen packet or PROGRAM state")
        if cp_state.get("terminal"):
            raise transitions.InvalidTransitionError(
                "terminal checkpoint cannot use validation-infrastructure retry"
            )
        cap = int(((cp_packet.get("risk_budget") or {}).get("max_build_passes") or 0))
        used = int(cp_state.get("build_pass_count") or 0)
        if cap <= 0 or used != cap:
            raise transitions.InvalidTransitionError(
                "specialized review retry requires the active checkpoint build cap to be exhausted"
            )
        actual_cp_counts = (
            int(cp_state.get("build_pass_count") or 0),
            int(cp_state.get("review_pass_count") or 0),
            int(cp_state.get("repair_round_count") or 0),
        )
        requested_cp_counts = (
            int(checkpoint_build_pass_count),
            int(checkpoint_review_pass_count),
            int(checkpoint_repair_round_count),
        )

        events = integrity.read_event_chain(ep) if ep.exists() else []
        matching_events = [
            event for event in events
            if isinstance(event, dict)
            and event.get("event_type") == "program_review_infrastructure_retry"
            and event.get("recovery_id") == recovery_id
        ]
        if current.get("state") == "REVIEWING":
            if len(matching_events) != 1:
                raise transitions.InvalidTransitionError(
                    "REVIEWING state lacks one matching infrastructure-retry event"
                )
            event = matching_events[0]
            expected_event_values = {
                "checkpoint_id": checkpoint_id,
                "candidate_sha": candidate_sha,
                "review_attempt_id": review_attempt_id,
                "semantic_sha256": semantic_sha256,
                "prior_verdict_sha256": prior_verdict_sha256,
                "prior_runtime_generation": prior_runtime_generation,
                "runtime_generation": runtime_generation,
                "recovery_packet_sha256": packet_sha256,
                "recovery_approval_sha256": approval_sha256,
                "recovery_build_receipt_sha256": build_receipt_sha256,
                "prior_capability_binding_sha256": prior_capability_binding_sha256,
                "capability_binding_sha256": capability_binding_sha256,
                "validation_evidence_sha256": validation_evidence_sha256,
                "preflight_sha256": preflight_sha256,
                "accounting_sha256": accounting_sha256,
                "checkpoint_build_pass_count": checkpoint_build_pass_count,
                "checkpoint_review_pass_count": checkpoint_review_pass_count,
                "checkpoint_repair_round_count": checkpoint_repair_round_count,
            }
            if any(event.get(key) != value for key, value in expected_event_values.items()):
                raise integrity.TamperingDetected(
                    "infrastructure-retry event contradicts requested identity"
                )
            if actual_cp_counts != requested_cp_counts:
                raise integrity.TamperingDetected(
                    "checkpoint counters changed after validation-infrastructure retry"
                )
            program_counters = program_state.get("cumulative_counters") or {}
            if (
                int(current.get("build_pass_count") or 0)
                != int(program_counters.get("build_pass_count") or 0)
                or int(current.get("review_pass_count") or 0)
                != int(program_counters.get("review_pass_count") or 0)
                or int(current.get("repair_round") or 0)
                != int(program_counters.get("repair_round_count") or 0)
                or event.get("build_pass_count") != int(current.get("build_pass_count") or 0)
                or event.get("review_pass_count") != int(current.get("review_pass_count") or 0)
                or event.get("repair_round") != int(current.get("repair_round") or 0)
            ):
                raise integrity.TamperingDetected(
                    "PROGRAM counter mirrors changed after validation-infrastructure retry"
                )
            return {
                "ok": True,
                "idempotent": True,
                "state": "REVIEWING",
                "checkpoint_id": checkpoint_id,
                "candidate_sha": candidate_sha,
                "build_pass_count": int(current.get("build_pass_count") or 0),
                "review_pass_count": int(current.get("review_pass_count") or 0),
                "repair_round": int(current.get("repair_round") or 0),
            }
        if current.get("state") != "BLOCKED":
            raise transitions.InvalidTransitionError(
                "validation-infrastructure retry requires BLOCKED or its matching REVIEWING replay"
            )
        if matching_events:
            raise integrity.TamperingDetected(
                "infrastructure-retry event exists while STATE.json is still BLOCKED"
            )
        source_review = events[-1] if events else {}
        evidence_refs = source_review.get("validation_evidence_refs") or []
        if any((
            source_review.get("event_type") != "review_finalized",
            source_review.get("old_state") != "REVIEWING",
            source_review.get("new_state") != "BLOCKED",
            source_review.get("verdict") != "BLOCKED",
            source_review.get("failure_reason") != "infra_failure",
            source_review.get("validation_pass") is not False,
            source_review.get("infra_failure_count") != 1,
            source_review.get("commit_sha") != candidate_sha,
            source_review.get("review_verdict_sha256") != prior_verdict_sha256,
            source_review.get("packet_sha256") != packet_sha256,
            source_review.get("build_receipt_sha256") != build_receipt_sha256,
            not any(
                isinstance(item, dict)
                and item.get("sha256") == validation_evidence_sha256
                for item in evidence_refs
            ),
        )):
            raise transitions.InvalidTransitionError(
                "retry lacks the exact preceding blocked verdict and durable evidence"
            )
        if actual_cp_counts != requested_cp_counts:
            raise transitions.InvalidTransitionError(
                "checkpoint counters changed before validation-infrastructure retry"
            )
        program_counters = program_state.get("cumulative_counters") or {}
        if (
            int(current.get("build_pass_count") or 0)
            != int(program_counters.get("build_pass_count") or 0)
            or int(current.get("review_pass_count") or 0)
            != int(program_counters.get("review_pass_count") or 0)
            or int(current.get("repair_round") or 0)
            != int(program_counters.get("repair_round_count") or 0)
        ):
            raise integrity.TamperingDetected(
                "PROGRAM counter mirrors disagree before validation-infrastructure retry"
            )
        if is_stop_requested(canonical_repo, run_id):
            raise transitions.InvalidTransitionError(
                "stop request prevents validation-infrastructure retry"
            )

        now = utc_now_iso()
        new = dict(current)
        new["state"] = "REVIEWING"
        new["transitions_count"] = int(current.get("transitions_count", 0)) + 1
        new["updated_at"] = now
        new["last_actor"] = "ofloop-validation-infrastructure-recovery"
        new["terminal_reason"] = ""
        history = list(current.get("state_history", []))
        history.append({
            "from": "BLOCKED",
            "to": "REVIEWING",
            "at": now,
            "actor": "ofloop-validation-infrastructure-recovery",
            "reason": "replay exact accepted reviewer assessment after validator infrastructure repair",
        })
        new["state_history"] = history
        _commit_state_event_locked(
            canonical_repo,
            run_id,
            new,
            event_type="program_review_infrastructure_retry",
            old_state="BLOCKED",
            new_state="REVIEWING",
            actor="ofloop-validation-infrastructure-recovery",
            commit_sha=candidate_sha,
            reason="replay exact accepted reviewer assessment after validator infrastructure repair",
            extras={
                "recovery_id": recovery_id,
                "checkpoint_id": checkpoint_id,
                "candidate_sha": candidate_sha,
                "review_attempt_id": review_attempt_id,
                "semantic_sha256": semantic_sha256,
                "prior_verdict_sha256": prior_verdict_sha256,
                "prior_runtime_generation": prior_runtime_generation,
                "runtime_generation": runtime_generation,
                "recovery_packet_sha256": packet_sha256,
                "recovery_approval_sha256": approval_sha256,
                "recovery_build_receipt_sha256": build_receipt_sha256,
                "prior_capability_binding_sha256": prior_capability_binding_sha256,
                "capability_binding_sha256": capability_binding_sha256,
                "validation_evidence_sha256": validation_evidence_sha256,
                "preflight_sha256": preflight_sha256,
                "accounting_sha256": accounting_sha256,
                "build_pass_count": int(current.get("build_pass_count") or 0),
                "review_pass_count": int(current.get("review_pass_count") or 0),
                "repair_round": int(current.get("repair_round") or 0),
                "checkpoint_build_pass_count": actual_cp_counts[0],
                "checkpoint_review_pass_count": actual_cp_counts[1],
                "checkpoint_repair_round_count": actual_cp_counts[2],
            },
        )
    try:
        fsync_dir(sp.parent)
    except OSError:
        pass
    return {
        "ok": True,
        "idempotent": False,
        "state": "REVIEWING",
        "checkpoint_id": checkpoint_id,
        "candidate_sha": candidate_sha,
        "build_pass_count": int(current.get("build_pass_count") or 0),
        "review_pass_count": int(current.get("review_pass_count") or 0),
        "repair_round": int(current.get("repair_round") or 0),
    }


def continue_blocked_program(
    canonical_repo: Path,
    run_id: str,
    *,
    packet: dict[str, Any],
    actor: str,
    reason: str,
    commit_sha: str,
    continuation_id: str,
    expected_previous_candidate_sha: str | None = None,
) -> dict[str, Any]:
    """Fund one explicit continuation of a blocked PROGRAM checkpoint.

    This is the protocol owner for the operator-authorized BLOCKED escape.
    It deliberately combines the per-checkpoint repair counter, cumulative
    repair counter, and ``BLOCKED -> READY_TO_BUILD`` transition under the
    normal state transaction.  A repeated call after that transaction has
    committed is an idempotent observation and never spends another repair.

    The supervisor owns the cross-system continuation receipt and the
    DONE->QUEUED ledger transition; this function owns only protocol state.
    """
    validate_run_id(run_id)
    if not isinstance(reason, str) or not reason.strip():
        raise ValueError("continuation reason must be non-empty")
    if not isinstance(commit_sha, str) or not re.fullmatch(r"[0-9a-f]{40}", commit_sha):
        raise ValueError("continuation candidate SHA must be a full commit SHA")
    if not isinstance(continuation_id, str) or not re.fullmatch(r"[0-9a-f]{32,64}", continuation_id):
        raise ValueError("continuation id is invalid")

    sp = state_path(canonical_repo, run_id)
    with flock_exclusive(lock_path(canonical_repo, run_id)):
        _verify_mutation_integrity_locked(canonical_repo, run_id)
        current = read_json(sp)
        if not isinstance(current, dict) or not current:
            raise FileNotFoundError(f"STATE.json missing for run {run_id}")
        if current.get("schema") != PROGRAM_STATE_SCHEMA_VERSION:
            raise ValueError("PROGRAM state required for continuation")
        expected_previous = expected_previous_candidate_sha or commit_sha
        if not isinstance(expected_previous, str) or not re.fullmatch(r"[0-9a-f]{40}", expected_previous):
            raise ValueError("continuation previous candidate SHA is invalid")
        if str(current.get("last_candidate_sha") or "") != expected_previous:
            raise transitions.InvalidTransitionError(
                "continuation candidate SHA does not match STATE.json bound candidate"
            )
        program_state = current.get("program")
        if not isinstance(program_state, dict):
            raise ValueError("PROGRAM state missing program block")
        from . import program as program_mod
        ok, graph_reason = program_mod.verify_frozen_graph(packet, program_state)
        if not ok:
            raise ValueError(f"PROGRAM frozen-graph verification failed: {graph_reason}")
        cp_id = program_mod.select_next_checkpoint(packet, program_state)
        if not cp_id:
            raise transitions.InvalidTransitionError(
                "continuation refused: PROGRAM has no unfinished checkpoint"
            )
        if current.get("state") == "READY_TO_BUILD":
            return {
                "ok": True,
                "continued": False,
                "idempotent": True,
                "state": "READY_TO_BUILD",
                "checkpoint_id": cp_id,
                "repair_round": int(current.get("repair_round") or 0),
                "cumulative_repair_round_count": int(
                    program_state["cumulative_counters"].get("repair_round_count", 0)
                ),
            }
        if current.get("state") != "BLOCKED":
            raise transitions.InvalidTransitionError(
                "continuation requires BLOCKED or an already-continued READY_TO_BUILD state"
            )

        mirror = int(current.get("repair_round") or 0)
        cumulative = int(program_state["cumulative_counters"].get("repair_round_count", 0))
        if mirror != cumulative:
            raise ValueError(
                f"repair counter mirror drift: top={mirror}, cumulative={cumulative}"
            )
        packet_cp = program_mod._resolve_packet_cp(packet, cp_id)
        new_program = program_mod._bump_counter_one(
            program_state,
            cp_id=cp_id,
            counter="repair_round_count",
            packet_cp=packet_cp,
        )
        new = dict(current)
        new["program"] = new_program
        new["repair_round"] = mirror + 1
        new["state"] = "READY_TO_BUILD"
        new["terminal_reason"] = ""
        now = utc_now_iso()
        new["updated_at"] = now
        new["last_actor"] = actor
        history = list(current.get("state_history", []))
        history.append({
            "from": "BLOCKED",
            "to": "READY_TO_BUILD",
            "at": now,
            "actor": actor,
            "reason": reason,
        })
        new["state_history"] = history
        _commit_state_event_locked(
            canonical_repo,
            run_id,
            new,
            event_type="program_continuation",
            old_state="BLOCKED",
            new_state="READY_TO_BUILD",
            actor=actor,
            commit_sha=commit_sha,
            reason=reason,
            extras={
                "continuation_id": continuation_id,
                "checkpoint_id": cp_id,
                "repair_round_before": mirror,
                "repair_round_after": mirror + 1,
                "cumulative_repair_round_before": cumulative,
                "cumulative_repair_round_after": cumulative + 1,
            },
        )
    try:
        fsync_dir(sp.parent)
    except OSError:
        pass
    return {
        "ok": True,
        "continued": True,
        "idempotent": False,
        "state": "READY_TO_BUILD",
        "checkpoint_id": cp_id,
        "repair_round": mirror + 1,
        "cumulative_repair_round_count": cumulative + 1,
    }


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
