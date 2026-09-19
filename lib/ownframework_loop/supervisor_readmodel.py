"""Supervisor read-model — operator-facing read-only surface owner.

This module is the canonical named owner of the supervisor's
read-only / operator-facing surface.  The implementations continue
to live in ``supervisor.py`` because they share tight internal
coupling with the DB / schema / validation primitives owned by
that module (``_managed_connect``, ``_managed_connect_readonly``,
``_repository_scheduling_identity``, ``_hold_dict``,
``_validate_max_concurrency``, ``_CONFIG_MAX_CONCURRENCY``,
``default_db_path``, ``SCHEMA``, ``DEFAULT_MAX_CONCURRENCY``).

Extracting the implementations would require relocating those
primitives too — that is deferred to a later consolidation once
a DB-owner / schema-owner module is named.  See
``docs/architecture/IMPLEMENTATION_CONSOLIDATION.md`` for the
sequencing rationale.

What this module owns NOW:

  * The semantic claim that "the supervisor's read-only /
    operator-facing surface is one named authority";
  * Stable re-exports so an external caller can write
    ``from ownframework_loop.supervisor_readmodel import status``
    instead of reaching into the supervisor package;
  * A documentation index of every read-only surface this
    authority owns.

The functions re-exported below are:

  * ``status`` — single-run operator status;
  * ``supervisor_config_get`` / ``supervisor_config_set`` —
    persistent operational execution capacity;
  * ``fleet_status`` — fleet-wide operator projection;
  * ``dispatch_hold_status`` / ``release_dispatch_hold`` /
    ``cancel_dispatch_hold`` — bounded operator hold lifecycle.

Internal read-model helpers (the ``_logical_job_row``,
``_readonly_columns``, ``_legacy_readonly_fleet_projection``,
``_run_git_readonly``, ``_registered_worktree_paths``,
``_worktree_visibility``, ``_candidate_diff_visibility``,
``_core_snapshot``, ``_job_dict`` graph) are intentionally NOT
re-exported here: they are supervisor-internal projections that
no external module is permitted to depend on.  Their authoritative
owner remains ``supervisor.py`` until a future consolidation
extracts them together with the DB / schema primitives they
compose.
"""
from __future__ import annotations

from .supervisor import (  # re-export facade
    status,
    supervisor_config_get,
    supervisor_config_set,
    fleet_status,
    dispatch_hold_status,
    release_dispatch_hold,
    cancel_dispatch_hold,
)


__all__ = [
    "status",
    "supervisor_config_get",
    "supervisor_config_set",
    "fleet_status",
    "dispatch_hold_status",
    "release_dispatch_hold",
    "cancel_dispatch_hold",
]
