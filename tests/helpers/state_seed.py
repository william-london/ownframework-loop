#!/usr/bin/env python3
"""Test-only crash-state seeding for deterministic fixtures.

Fixtures sometimes need to simulate the exact durable state a crashed or
interrupted protocol run would have left behind: states unreachable by one
legal transition from the fixture start point, drifted pass counters, or
checkpoint boundaries. Production code NEVER uses this seam: the protocol
library's `state.save()` is creation-only, generic transition extras cannot
write STATE.json at all, and authoritative updates go exclusively through the
transition owners' typed parameters.

This helper therefore lives in tests/, not in the protocol library. It does
NOT bypass integrity: it still verifies the existing event chain under the
per-run flock and commits through `state._commit_state_event_locked`, i.e.
the same write-ahead STATE_TXN + event-chain machinery a real transition
uses, so `load_verified()` accepts the seeded run exactly as it would a run
left behind by a genuine crash.
"""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.environ.get("OFLOOP_LIB", ""))

from ownframework_loop import state as state_mod  # noqa: E402
from ownframework_loop import util  # noqa: E402


def seed_state(
    canonical_repo,
    run_id: str,
    payload: dict,
    *,
    actor: str = "fixture",
    reason: str = "fixture crash-state seed",
    event_type: str = "state_saved",
) -> dict:
    """Durably seed `payload` as the authoritative state for one fixture run.

    Mirrors the bookkeeping a genuine transition would have recorded when the
    seeded `state` differs from the current durable state, so the seeded
    document stays internally consistent (state_history/transitions_count).
    """
    sp = state_mod.state_path(canonical_repo, run_id)
    with state_mod.flock_exclusive(state_mod.lock_path(canonical_repo, run_id)):
        state_mod._verify_mutation_integrity_locked(canonical_repo, run_id)
        old = state_mod.read_json(sp, default={}) if sp.exists() else {}
        old_state = (old or {}).get("state")
        new = dict(payload)
        now = util.utc_now_iso()
        new["updated_at"] = now
        new["last_actor"] = actor
        if old_state is not None and new.get("state") != old_state:
            history = list(new.get("state_history", []))
            history.append(
                {
                    "from": old_state,
                    "to": new.get("state"),
                    "at": now,
                    "actor": actor,
                    "reason": reason,
                }
            )
            new["state_history"] = history
            new["transitions_count"] = int(new.get("transitions_count", 0)) + 1
        state_mod._commit_state_event_locked(
            canonical_repo,
            run_id,
            new,
            event_type=event_type,
            old_state=old_state if old_state is not None else new.get("state"),
            new_state=new.get("state"),
            actor=actor,
            commit_sha=new.get("last_candidate_sha") or None,
            reason=reason,
        )
    return new
