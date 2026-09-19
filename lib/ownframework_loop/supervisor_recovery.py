"""Supervisor recovery — stale-running ownership recovery owner.

This module is the canonical named owner of the supervisor's
recovery / hold-ownership surface.  The implementations continue
to live in ``supervisor.py`` because they share tight internal
coupling with the durable DB primitives (``_managed_connect``,
``_repository_scheduling_identity``) and the hold state
machinery (``_hold_dict``).

This owner is intentionally a thin named seam, the same shape as
``supervisor_readmodel.py``.  Extracting the implementations
without relocating the hold-state machine and DB primitives
together would force a partial extraction that produces sync
drift.  Deferred to a later consolidation once a DB-owner /
schema-owner module is named.

What this module owns NOW:

  * The semantic claim that "the supervisor's recovery / hold
    ownership surface is one named authority";
  * Stable re-exports so an external caller can write
    ``from ownframework_loop.supervisor_recovery import _recover_stale_running``
    instead of reaching into the supervisor package;
  * A documentation index of every recovery surface this
    authority owns.

The functions re-exported below are:

  * ``_recover_stale_running`` — sweep stale RUNNING enrollments
    whose owning runtime generation no longer matches the live
    supervisor (the runtime-recovery lane);
  * ``_recovery_ownership_matches`` — predicate: does one row's
    owning generation still match the live supervisor's
    generation?  Used by the recovery sweep and by tests.
  * ``_validate_dispatch_hold_request`` — bounded validation
    of a hold request before it is written;
  * ``_hold_row`` — fetch one dispatch-hold row by job id;
  * ``_hold_dict`` — project one dispatch-hold row into the
    operator-facing dict shape (shared with the read-model
    surface);
  * ``_hold_matches_before_claim`` — predicate: does one hold
    still satisfy its pre-claim invariants?
"""
from __future__ import annotations

from .supervisor import (  # re-export facade
    _recover_stale_running,
    _recovery_ownership_matches,
    _validate_dispatch_hold_request,
    _hold_row,
    _hold_dict,
    _hold_matches_before_claim,
)


__all__ = [
    "_recover_stale_running",
    "_recovery_ownership_matches",
    "_validate_dispatch_hold_request",
    "_hold_row",
    "_hold_dict",
    "_hold_matches_before_claim",
]
