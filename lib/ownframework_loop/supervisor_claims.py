"""Supervisor claims — claim / enqueue / submission-budget owner.

This module is the canonical named owner of the supervisor's
claim / enqueue / submission-budget surface.  The implementations
continue to live in ``supervisor.py`` because they share tight
internal coupling with the durable DB primitives
(``_managed_connect``, ``_hold_dict``, ``_attempt_provenance_gate``,
``_reserve_semantic_attempt``, ``_recover_stale_running``,
``_update_job``, ``_hold_matches_before_claim``) and the run-state
machine.

This owner is intentionally a thin named seam, the same shape as
``supervisor_readmodel.py``, ``supervisor_recovery.py``, and
``supervisor_attempts.py``.  Extracting the implementations without
relocating the run-state machine and DB primitives together would
force a partial extraction that produces sync drift.  Deferred to
a later consolidation once a DB-owner / run-state-owner module is
named.

What this module owns NOW:

  * The semantic claim that "the supervisor's claim / enqueue /
    submission-budget surface is one named authority";
  * Stable re-exports so an external caller can write
    ``from ownframework_loop.supervisor_claims import enqueue``
    instead of reaching into the supervisor package;
  * A documentation index of every claim surface this authority
    owns.

The functions re-exported below are:

  * ``enqueue`` — durable enrollment of one job into the
    supervisor ledger (the public entry point used by every
    ``ofloop supervisor enqueue`` call);
  * ``_take_next_job`` — claim-time dispatcher: returns the
    next eligible candidate after running the stale-running
    recovery sweep (the supervisor FSM's claim phase);
  * ``_scheduler_submission_budget`` — bounded check that
    the live scheduler is still inside its permitted claim
    budget for this loop tick.
"""
from __future__ import annotations

from .supervisor import (  # re-export facade
    enqueue,
    _take_next_job,
    _scheduler_submission_budget,
)


__all__ = [
    "enqueue",
    "_take_next_job",
    "_scheduler_submission_budget",
]
