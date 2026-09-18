"""Shared deterministic proof primitives for BUILD and REVIEW finalizers.

Both ``build_finalize.py`` and ``review_finalize.py`` are role-specific
orchestrators over a small shared core:

  * JSON artifact loading (fail-safe default on parse error);
  * candidate-branch-contains / ancestor-of git checks;
  * packet-scope path classification (allowed / protected /
    elevated / sensitive / out_of_scope);
  * strict-ceiling math for cross-checked budget envelopes.

This module owns those primitives. The role-specific finalizers
import them and retain their role-specific orchestration
(build-only: BUILD_AGENT_RESULT validation, source-mutation
ownership; review-only: REVIEW_AGENT_ASSESSMENT validation,
must-fix fingerprinting).

Every function here was previously duplicated in both finalizers.
Tests for the original behaviour live with the role-specific
finalizers.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from . import (
    packet as packet_mod,
    util,
)


def read_json(path: Path, default: Any = None) -> Any:
    """Read a JSON artifact or return ``default`` on absence/parse error."""
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return default


def candidate_branch_contains(
    canonical_repo: Path, candidate_branch: str, candidate_sha: str
) -> bool:
    """Return True iff ``candidate_branch`` contains ``candidate_sha``."""
    r = util.run_subprocess(
        ["git", "-C", str(canonical_repo), "merge-base", "--is-ancestor",
         candidate_sha, candidate_branch],
        timeout=10,
    )
    return r.returncode == 0


def ancestor_of(
    canonical_repo: Path, candidate_sha: str, baseline_sha: str
) -> bool:
    """Return True iff ``candidate_sha`` is a descendant of ``baseline_sha``."""
    r = util.run_subprocess(
        ["git", "-C", str(canonical_repo), "merge-base", "--is-ancestor",
         baseline_sha, candidate_sha],
        timeout=10,
    )
    return r.returncode == 0


def path_in_list(path: str, prefix: str) -> bool:
    """Match ``path`` against a single scope entry (supports ``dir/**``)."""
    return packet_mod.path_matches_scope_entry(path, prefix)


def classify_path_against_packet(packet: dict[str, Any], path: str) -> str:
    """Return one of 'allowed', 'protected', 'sensitive', 'elevated',
    'out_of_scope' for a single path against the packet's scope sets.

    Order is fixed: protected > allowed > elevated > sensitive >
    out_of_scope.  Identical semantics for build and review; previously
    duplicated in both finalizers.
    """
    if packet_mod.is_protected_path(packet, path):
        return "protected"
    if packet_mod.is_allowed_path(packet, path):
        return "allowed"
    elevated = packet.get("elevated_allowed_paths") or []
    if any(path_in_list(path, p) for p in elevated):
        return "elevated"
    sensitive = packet.get("sensitive_paths") or []
    if any(path_in_list(path, p) for p in sensitive):
        return "sensitive"
    return "out_of_scope"


def strict_ceiling(top: int, program_ceiling: int) -> int:
    """Return the stricter of two ceilings; 0 means 'not declared'.

    When both are declared the effective envelope is
    ``min(top, program_ceiling)`` so neither approved limit can
    silently widen the source envelope. When only one side is
    declared, that declared value is the strict envelope.
    """
    if top and program_ceiling:
        return min(int(top), int(program_ceiling))
    return int(top or program_ceiling or 0)
