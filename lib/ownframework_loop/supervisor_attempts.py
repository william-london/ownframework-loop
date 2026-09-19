"""Supervisor attempts — semantic-attempt lifecycle owner.

This module is the canonical named owner of the supervisor's
semantic-attempt lifecycle surface.  The implementations continue
to live in ``supervisor.py`` because they share tight internal
coupling with the durable DB primitives (``_managed_connect``,
``_repository_scheduling_identity``) and the run-state machine
(``_hold_dict``, ``_update_job``, ``_recover_stale_running``,
``_replay_candidate_sha``, accounting helpers).

This owner is intentionally a thin named seam, the same shape as
``supervisor_readmodel.py`` and ``supervisor_recovery.py``.
Extracting the implementations without relocating the
run-state machine and DB primitives together would force a
partial extraction that produces sync drift.  Deferred to a
later consolidation once a DB-owner / run-state-owner module is
named.

What this module owns NOW:

  * The semantic claim that "the supervisor's semantic-attempt
    lifecycle surface is one named authority";
  * Stable re-exports so an external caller can write
    ``from ownframework_loop.supervisor_attempts import _reserve_semantic_attempt``
    instead of reaching into the supervisor package;
  * A documentation index of every attempts surface this
    authority owns.

The functions re-exported below are:

  * ``_attempt_provenance_gate`` — claim-time gate that proves
    a candidate's provenance before a fresh attempt is reserved;
  * ``_maybe_complete_semantic_artifact`` — finalize an
    in-flight semantic artifact when a worker exits;
  * ``_publish_acceptance_for_ready_artifact`` — publish the
    acceptance receipt for a READY semantic artifact;
  * ``_replay_candidate_sha`` — recover the candidate SHA that
    was replayed into the durable run directory;
  * ``_reserve_semantic_attempt`` — allocate one semantic
    attempt row (idempotent on duplicate reservation);
  * ``_set_worker_pid`` — bind a worker subprocess PID to the
    active attempt row;
  * ``_update_job`` — mutate durable job state for an in-flight
    attempt (used by recovery, claim, attempts, FSM);
  * ``_ensure_execution_started`` — flip ``execution_started_at``
    exactly once on the first worker spawn.
"""
from __future__ import annotations

from .supervisor import (  # re-export facade
    _attempt_provenance_gate,
    _maybe_complete_semantic_artifact,
    _publish_acceptance_for_ready_artifact,
    _replay_candidate_sha,
    _reserve_semantic_attempt,
    _set_worker_pid,
    _update_job,
    _ensure_execution_started,
)


__all__ = [
    "_attempt_provenance_gate",
    "_maybe_complete_semantic_artifact",
    "_publish_acceptance_for_ready_artifact",
    "_replay_candidate_sha",
    "_reserve_semantic_attempt",
    "_set_worker_pid",
    "_update_job",
    "_ensure_execution_started",
]
