"""OwnFramework Loop PROGRAM mode — finite packet-bound checkpoint DAG.

A v3 packet with `execution_mode: program` carries a frozen
`checkpoint_graph`. The engine drives checkpoints one at a time in
topological order, satisfying the dependency contract declared in
the graph: a checkpoint with `depends_on: [CP-X, CP-Y]` becomes
*claimable* only after CP-X and CP-Y are both terminal-APPROVED.

Genericity: this module is product-agnostic. It neither imports nor
references any specific product (ERP, Phase 9, etc.). It only consumes
packet metadata + git state.

Implements (per governing manual):
  - finite packet-bound checkpoint DAG
  - DAG validation (no cycles, no unknown deps, no duplicate ids)
  - deterministic dependency-ready checkpoint selection
  - packet-bound checkpoint order and budgets
  - checkpoint-local build/review/repair counters
  - per-checkpoint maximum 8 build, 8 review, 3 repair
  - cumulative caps == sum of approved-checkpoint exact caps
  - global source ceilings: 500 unique changed files, 30000 diff lines
  - no post-approval widening (graph SHA frozen at program start)
  - one candidate branch per run, shared across all checkpoints
  - immutable checkpoint evidence (sha256 over canonicalized evidence manifest)
  - automatic checkpoint advancement when its deps finish
  - automatic checkpoint repair against packet+global ceilings
  - guarded nonterminal checkpoint approval (refused — `nonterminal_cp_approval`)
  - crash reconciliation at checkpoint boundaries (idempotent on resume)
  - one final integrated original-baseline-to-final exact-SHA review
  - one program-level APPROVED|BLOCKED|STOPPED result
  - packet-configurable `promotion_policy` (default `human_gate`)
  - guarded `merge_on_approved` (refused if packets\' human_only authority mismatch,
    or run-level deliverable is already published)
"""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path
from typing import Any

from .util import (
    sha256_text,
    utc_now_iso,
)
from .integrity import canonical_json_dumps



PROGRAM_SCHEMA_VERSION = "ownframework-work-packet/v3"
STATE_PROGRAM_KEY = "program"
MAX_CP_BUILD_PASSES = 8
MAX_CP_REVIEW_PASSES = 8
MAX_CP_REPAIR_ROUNDS = 3
GLOBAL_MAX_UNIQUE_CHANGED_FILES = 500
GLOBAL_MAX_BASELINE_TO_FINAL_DIFF_LINES = 30000


# --------------------------------------------------------------------------- #
# Errors
# --------------------------------------------------------------------------- #


class ProgramGraphError(ValueError):
    """Static graph contract violation (DAG, deps, caps)."""


class ProgramStateError(RuntimeError):
    """Live state contract violation (frozen graph drift, ceiling breach)."""


# --------------------------------------------------------------------------- #
# Validation
# --------------------------------------------------------------------------- #


_CP_RE = re.compile(r"^CP-[0-9]+$")


def _cp_id(s: Any) -> bool:
    return isinstance(s, str) and bool(_CP_RE.fullmatch(s))


def resolve_execution_mode(meta: dict[str, Any]) -> str:
    """Return 'single' or 'program'.

    Default (when the field is absent) is 'single' — preserves
    backwards compatibility with v1/v2 packets.
    """
    v = meta.get("execution_mode")
    if v is None:
        return "single"
    if v not in ("single", "program"):
        raise ProgramGraphError(f"invalid execution_mode: {v!r}")
    return v


def validate_checkpoint_graph(packet: dict[str, Any]) -> list[str]:
    """Static structural validation of a v3 checkpoint_graph.

    Returns a list of error messages (empty list == valid).
    """
    errors: list[str] = []
    cg = packet.get("checkpoint_graph")
    if not isinstance(cg, dict):
        return ["checkpoint_graph missing or not an object"]

    order = cg.get("execution_order")
    checkpoints = cg.get("checkpoints")
    if not isinstance(order, list) or not order:
        errors.append("checkpoint_graph.execution_order must be a non-empty list")
        return errors
    if not isinstance(checkpoints, list) or not checkpoints:
        errors.append("checkpoint_graph.checkpoints must be a non-empty list")
        return errors

    by_id: dict[str, dict[str, Any]] = {}
    for cp in checkpoints:
        if not isinstance(cp, dict):
            errors.append("checkpoint is not an object")
            continue
        cid = cp.get("id")
        if not _cp_id(cid):
            errors.append(f"checkpoint id invalid: {cid!r}")
            continue
        if cid in by_id:
            errors.append(f"duplicate checkpoint id: {cid}")
            continue
        by_id[cid] = cp

        if not isinstance(cp.get("title"), str) or not cp["title"]:
            errors.append(f"{cid}: title missing/empty")
        if not isinstance(cp.get("scope"), str) or not cp["scope"]:
            errors.append(f"{cid}: scope missing/empty")

        rb = cp.get("risk_budget")
        if not isinstance(rb, dict):
            errors.append(f"{cid}: risk_budget missing")

    # Pass 2: check budgets and deps (now that by_id is fully populated).
    for cid, cp in by_id.items():
        rb = cp.get("risk_budget") or {}
        for k, mx in (
            ("max_build_passes", MAX_CP_BUILD_PASSES),
            ("max_review_passes", MAX_CP_REVIEW_PASSES),
            ("max_repair_rounds", MAX_CP_REPAIR_ROUNDS),
        ):
            v = rb.get(k)
            if not isinstance(v, int) or v < 1 or v > mx:
                errors.append(f"{cid}: {k} must be int in [1..{mx}], got {v!r}")

        deps = cp.get("depends_on", [])
        if not isinstance(deps, list):
            errors.append(f"{cid}: depends_on must be a list")
            continue
        for d in deps:
            if not _cp_id(d):
                errors.append(f"{cid}: depends_on has invalid id {d!r}")
            elif d == cid:
                errors.append(f"{cid}: cannot depend on itself")
            elif d not in by_id:
                errors.append(f"{cid}: depends on unknown checkpoint {d}")

    # Order must list every checkpoint exactly once.
    seen = set()
    for cid in order:
        if not _cp_id(cid):
            errors.append(f"execution_order has invalid id {cid!r}")
            continue
        if cid not in by_id:
            errors.append(f"execution_order references unknown checkpoint {cid}")
            continue
        if cid in seen:
            errors.append(f"execution_order has duplicate id {cid}")
        seen.add(cid)
    missing = set(by_id) - seen
    if missing:
        errors.append(f"execution_order omits checkpoints: {sorted(missing)}")

    # Acyclic: a checkpoint can never precede one of its dependencies.
    position = {cid: i for i, cid in enumerate(order)}
    for cid, idx in position.items():
        cp = by_id[cid]
        for d in cp.get("depends_on", []):
            if d not in position:
                continue
            if position[d] >= idx:
                errors.append(
                    f"execution order invalid: {cid} (idx {idx}) "
                    f"must come AFTER dependency {d} (idx {position[d]})"
                )

    # Global source ceilings — either from packet or use universal max.
    sc = cg.get("global_source_ceilings", {})
    if isinstance(sc, dict):
        for k, mx in (
            ("max_unique_changed_files", GLOBAL_MAX_UNIQUE_CHANGED_FILES),
            ("max_baseline_to_final_diff_lines", GLOBAL_MAX_BASELINE_TO_FINAL_DIFF_LINES),
        ):
            v = sc.get(k)
            if v is None:
                continue
            if not isinstance(v, int) or v < 1 or v > mx:
                errors.append(
                    f"global_source_ceilings.{k} must be int in [1..{mx}], got {v!r}"
                )

    return errors


def checkpoint_graph_sha256(packet: dict[str, Any]) -> str:
    """Frozen canonical hash of the checkpoint_graph dict.

    Readers re-compute and verify before acting; any post-approval
    widening of the graph fails the check.
    """
    cg = packet.get("checkpoint_graph") or {}
    body = {
        "execution_order": cg.get("execution_order", []),
        "checkpoints": cg.get("checkpoints", []),
        "global_source_ceilings": cg.get("global_source_ceilings", {}),
    }
    return sha256_text(canonical_json_dumps(body))


def resolve_promotion_policy(packet: dict[str, Any]) -> str:
    """Return "human_gate" (default) or "merge_on_approved"."""
    p = packet.get("promotion_policy")
    if p is None:
        return "human_gate"
    if p not in ("human_gate", "merge_on_approved"):
        raise ProgramGraphError(f"invalid promotion_policy: {p!r}")
    return p


# --------------------------------------------------------------------------- #
# State materialization
# --------------------------------------------------------------------------- #


def materialise_initial_program_state(
    packet: dict[str, Any],
    *,
    baseline_sha: str,
    candidate_branch: str,
) -> dict[str, Any]:
    """Build the v2 `program` block for a freshly-approved v3 packet.

    Single source of truth for initial program-state shape. Captured at
    program start so any later edit to the packet (post-approval widening)
    is detectable by recomputing `checkpoint_graph_sha256` and refusing.
    """
    errors = validate_checkpoint_graph(packet)
    if errors:
        raise ProgramGraphError("checkpoint graph invalid: " + "; ".join(errors))

    checkpoints_state: list[dict[str, Any]] = []
    for cp in packet["checkpoint_graph"]["checkpoints"]:
        checkpoints_state.append({
            "id": cp["id"],
            "build_pass_count": 0,
            "review_pass_count": 0,
            "repair_round_count": 0,
            "no_progress_streak": 0,
            "candidate_sha": None,
            "build_receipt_sha256": None,
            "verdict_sha256": None,
            "terminal": "",
        })

    # Cumulative caps == sum of the exact approved checkpoint caps.
    cumulative = {
        "max_build_passes": 0,
        "max_review_passes": 0,
        "max_repair_rounds": 0,
    }
    for cp in packet["checkpoint_graph"]["checkpoints"]:
        rb = cp["risk_budget"]
        cumulative["max_build_passes"] += int(rb["max_build_passes"])
        cumulative["max_review_passes"] += int(rb["max_review_passes"])
        cumulative["max_repair_rounds"] += int(rb["max_repair_rounds"])

    sc = (packet["checkpoint_graph"].get("global_source_ceilings") or {})
    cumulative["max_unique_changed_files"] = int(
        sc.get("max_unique_changed_files", GLOBAL_MAX_UNIQUE_CHANGED_FILES)
    )
    cumulative["max_baseline_to_final_diff_lines"] = int(
        sc.get("max_baseline_to_final_diff_lines", GLOBAL_MAX_BASELINE_TO_FINAL_DIFF_LINES)
    )

    # current_checkpoints: the topological first CP with no blocking deps.
    deps_map = {
        cp["id"]: [d for d in cp.get("depends_on", [])]
        for cp in packet["checkpoint_graph"]["checkpoints"]
    }
    finalized_ids: set[str] = set()
    remaining = [cid for cid in packet["checkpoint_graph"]["execution_order"]
                 if cid not in finalized_ids]
    current: list[str] = []
    for cid in remaining:
        if all(d in finalized_ids for d in deps_map.get(cid, [])):
            current.append(cid)
            break
    if not current:
        for cid in remaining:
            current = [cid]
            break

    return {
        "execution_mode": "program",
        "checkpoint_graph_sha256": checkpoint_graph_sha256(packet),
        "promotion_policy": resolve_promotion_policy(packet),
        "current_checkpoints": current,
        "finalized_checkpoints": [],
        "cumulative_counters": {
            "build_pass_count": 0,
            "review_pass_count": 0,
            "repair_round_count": 0,
            "files_changed_unique": 0,
            "diff_lines_total": 0,
        },
        "cumulative_ceilings": cumulative,
        "checkpoints": checkpoints_state,
        "blocked": False,
        "source_sha_provenance": {
            "baseline_sha": baseline_sha,
            "candidate_branch": candidate_branch,
            "captured_at": utc_now_iso(),
        },
    }


# --------------------------------------------------------------------------- #
# Selection
# --------------------------------------------------------------------------- #


def select_next_checkpoint(
    packet: dict[str, Any], program_state: dict[str, Any]
) -> str | None:
    """Return the deterministic next claimable checkpoint id, or None."""
    cur = program_state.get("current_checkpoints") or []
    if not cur:
        return None
    return cur[0]


def ready_to_claim(cp_state: dict[str, Any], packet_cp: dict[str, Any]) -> tuple[bool, str]:
    """(ok, reason)."""
    if cp_state.get("terminal"):
        return False, f"terminal={cp_state['terminal']}"
    rb = packet_cp["risk_budget"]
    if cp_state["build_pass_count"] >= rb["max_build_passes"]:
        return False, "build cap"
    if cp_state["review_pass_count"] >= rb["max_review_passes"]:
        return False, "review cap"
    if cp_state["repair_round_count"] >= rb["max_repair_rounds"]:
        return False, "repair cap"
    return True, "ok"


def finalize_checkpoint(
    *,
    program_state: dict[str, Any],
    cp_id: str,
    terminal_state: str,
    evidence_manifest: dict[str, Any],
) -> dict[str, Any]:
    """Mark a checkpoint as finalized. Returns updated program_state.

    Refuses APPROVED for any checkpoint whose counters are not at >=1
    or whose global counters exceed caps. BLOCKED and STOPPED may be
    set from any state.
    """
    if terminal_state not in ("APPROVED", "BLOCKED", "STOPPED"):
        raise ProgramStateError(f"invalid terminal_state: {terminal_state}")

    cp = _find_cp(program_state, cp_id)
    if terminal_state == "APPROVED":
        if cp["build_pass_count"] < 1 or cp["review_pass_count"] < 1:
            raise ProgramStateError(
                "nonterminal_cp_approval_refused: cannot finalize APPROVED "
                "with no build+review pass"
            )
        cc = program_state["cumulative_counters"]
        ce = program_state["cumulative_ceilings"]
        if cc["files_changed_unique"] > ce["max_unique_changed_files"]:
            raise ProgramStateError("nonterminal_cp_approval_refused: file cap")
        if cc["diff_lines_total"] > ce["max_baseline_to_final_diff_lines"]:
            raise ProgramStateError("nonterminal_cp_approval_refused: diff cap")

    new = _deepcopy_program(program_state)
    cp_new = _find_cp(new, cp_id)
    cp_new["terminal"] = terminal_state

    finalized = list(new.get("finalized_checkpoints", []))
    finalized.append({
        "id": cp_id,
        "terminal_state": terminal_state,
        "finalized_at": utc_now_iso(),
        "evidence_sha256": sha256_text(canonical_json_dumps(evidence_manifest)),
    })
    new["finalized_checkpoints"] = finalized

    new["current_checkpoints"] = [c for c in new["current_checkpoints"] if c != cp_id]
    _refresh_current_checkpoints(new, packet_for=evidence_manifest.get("_packet"))
    return new


def advance_to_next(program_state: dict[str, Any], packet: dict[str, Any]) -> dict[str, Any]:
    """Compute the deterministic next checkpoint after a finalization."""
    new = _deepcopy_program(program_state)
    _refresh_current_checkpoints(new, packet_for=packet)
    return new


# --------------------------------------------------------------------------- #
# Cumulative counters & gates
# --------------------------------------------------------------------------- #


def increment_cp_counter(
    program_state: dict[str, Any],
    *,
    cp_id: str,
    counter: str,
    packet_cp: dict[str, Any],
) -> dict[str, Any]:
    """Increment a per-checkpoint counter, refusing past per-cp caps.

    The `cumulative_counters` (build/review/repair) are also bumped.
    For unique-files / diff-lines cumulative counts, callers pass through
    `record_aggregate_change` to keep them in lockstep with the source tree.
    """
    if counter not in (
        "build_pass_count", "review_pass_count", "repair_round_count",
    ):
        raise ProgramStateError(f"unknown counter {counter!r}")

    new = _deepcopy_program(program_state)
    cp = _find_cp(new, cp_id)
    cap_key = {
        "build_pass_count": "max_build_passes",
        "review_pass_count": "max_review_passes",
        "repair_round_count": "max_repair_rounds",
    }[counter]
    cap = int(packet_cp["risk_budget"][cap_key])
    if cp[counter] >= cap:
        raise ProgramStateError(
            f"per-checkpoint cap reached for {counter} on {cp_id}: {cp[counter]}/{cap}"
        )
    cp[counter] += 1
    new["cumulative_counters"][counter] += 1

    cum_cap = new["cumulative_ceilings"][cap_key]
    if new["cumulative_counters"][counter] > cum_cap:
        raise ProgramStateError(
            f"cumulative cap reached for {counter}: "
            f"{new["cumulative_counters"][counter]}/{cum_cap}"
        )
    return new


def record_aggregate_change(
    program_state: dict[str, Any],
    *,
    files_changed_unique_delta: int,
    diff_lines_delta: int,
) -> dict[str, Any]:
    """Bump the cumulative source-tree counters and enforce global caps."""
    if files_changed_unique_delta < 0 or diff_lines_delta < 0:
        raise ProgramStateError("aggregate change must be non-negative")
    new = _deepcopy_program(program_state)
    new["cumulative_counters"]["files_changed_unique"] += int(files_changed_unique_delta)
    new["cumulative_counters"]["diff_lines_total"] += int(diff_lines_delta)
    ce = new["cumulative_ceilings"]
    cc = new["cumulative_counters"]
    if cc["files_changed_unique"] > ce["max_unique_changed_files"]:
        raise ProgramStateError(
            f"global file cap reached: {cc['files_changed_unique']}/{ce['max_unique_changed_files']}"
        )
    if cc["diff_lines_total"] > ce["max_baseline_to_final_diff_lines"]:
        raise ProgramStateError(
            f"global diff-lines cap reached: {cc['diff_lines_total']}/{ce['max_baseline_to_final_diff_lines']}"
        )
    return new


# --------------------------------------------------------------------------- #
# Reader / verification
# --------------------------------------------------------------------------- #


def verify_frozen_graph(packet: dict[str, Any], program_state: dict[str, Any]) -> tuple[bool, str]:
    """Verify the program_state\'s frozen graph hash matches the packet."""
    cur = program_state.get("checkpoint_graph_sha256")
    want = checkpoint_graph_sha256(packet)
    if cur != want:
        return False, "post-approval_graph_drift"
    return True, "ok"


# --------------------------------------------------------------------------- #
# Result synthesis
# --------------------------------------------------------------------------- #


def is_program_terminal(program_state: dict[str, Any]) -> tuple[bool, str]:
    """Return (is_terminal, terminal_state-or-empty)."""
    cur = program_state.get("current_checkpoints") or []
    if cur:
        return False, ""
    finalized = program_state.get("finalized_checkpoints") or []
    if not finalized:
        return False, ""
    states = {fc["terminal_state"] for fc in finalized}
    if "BLOCKED" in states:
        return True, "BLOCKED"
    if "STOPPED" in states:
        return True, "STOPPED"
    if states == {"APPROVED"}:
        return True, "APPROVED"
    return False, ""


def program_terminal_reason(program_state: dict[str, Any]) -> str:
    fc = program_state.get("finalized_checkpoints") or []
    if not fc:
        return "no_checkpoints_finalized"
    bad = [f for f in fc if f["terminal_state"] in ("BLOCKED", "STOPPED")]
    if bad:
        return f"{bad[0]['terminal_state'].lower()}:{bad[0]['id']}"
    return "all_checkpoints_approved"


# --------------------------------------------------------------------------- #
# Promotion gate
# --------------------------------------------------------------------------- #


def promotion_allowed(packet: dict[str, Any], program_state: dict[str, Any]) -> tuple[bool, str]:
    """Decide whether a program-level APPROVED run may proceed to merge."""
    policy = resolve_promotion_policy(packet)
    if policy != "merge_on_approved":
        return False, "human_gate_required"

    if packet.get("merge_authority") != "delegated":
        return False, "merge_authority_must_be_delegated"

    is_term, term = is_program_terminal(program_state)
    if not is_term or term != "APPROVED":
        return False, f"not_terminal_approved:{term}"

    cum = program_state["cumulative_counters"]
    ce = program_state["cumulative_ceilings"]
    if cum["files_changed_unique"] > ce["max_unique_changed_files"]:
        return False, "file_cap_breach"
    if cum["diff_lines_total"] > ce["max_baseline_to_final_diff_lines"]:
        return False, "diff_lines_cap_breach"
    return True, "ok"


# --------------------------------------------------------------------------- #
# Internal helpers
# --------------------------------------------------------------------------- #


def _find_cp(program_state: dict[str, Any], cp_id: str) -> dict[str, Any]:
    for cp in program_state["checkpoints"]:
        if cp["id"] == cp_id:
            return cp
    raise ProgramStateError(f"unknown checkpoint id: {cp_id}")


def _deepcopy_program(program_state: dict[str, Any]) -> dict[str, Any]:
    """Deep copy without importing copy (we already json-roundtrip inputs)."""
    return json.loads(canonical_json_dumps(program_state))


def _refresh_current_checkpoints(
    program_state: dict[str, Any],
    *,
    packet_for: dict[str, Any] | None,
) -> None:
    """Recompute the deterministic next claimable checkpoint."""
    if packet_for is None:
        return
    order: list[str] = packet_for["checkpoint_graph"]["execution_order"]
    by_id: dict[str, dict[str, Any]] = {
        cp["id"]: cp for cp in packet_for["checkpoint_graph"]["checkpoints"]
    }
    finalized_ids = {fc["id"]: fc["terminal_state"] for fc in program_state["finalized_checkpoints"]}
    new_current: list[str] = []
    for cid in order:
        if cid in finalized_ids:
            continue
        cp = by_id[cid]
        deps_ok = all(finalized_ids.get(d) == "APPROVED" for d in cp.get("depends_on", []))
        if deps_ok:
            new_current.append(cid)
            break
    program_state["current_checkpoints"] = new_current


# --------------------------------------------------------------------------- #
# Source-tree accounting (used by the build finalizer in program mode)
# --------------------------------------------------------------------------- #


def source_tree_accounting(
    *,
    canonical_repo: Path,
    baseline_sha: str,
    candidate_sha: str,
) -> dict[str, int]:
    """Return files_changed_unique, diff_lines for candidate vs baseline."""
    diff = subprocess.run(
        ["git", "-C", str(canonical_repo), "diff", "--no-color",
         baseline_sha, candidate_sha, "--numstat"],
        capture_output=True, text=True, check=True,
    )
    files = 0
    diff_lines = 0
    for line in diff.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        a, d = parts[0], parts[1]
        if a == "-" or d == "-":
            continue
        try:
            ai = int(a)
            di = int(d)
        except ValueError:
            continue
        files += 1
        diff_lines += ai + di
    return {"files_changed_unique": files, "diff_lines": diff_lines}


__all__ = [
    "PROGRAM_SCHEMA_VERSION", "STATE_PROGRAM_KEY",
    "MAX_CP_BUILD_PASSES", "MAX_CP_REVIEW_PASSES", "MAX_CP_REPAIR_ROUNDS",
    "GLOBAL_MAX_UNIQUE_CHANGED_FILES", "GLOBAL_MAX_BASELINE_TO_FINAL_DIFF_LINES",
    "ProgramGraphError", "ProgramStateError",
    "resolve_execution_mode", "validate_checkpoint_graph",
    "checkpoint_graph_sha256", "resolve_promotion_policy",
    "materialise_initial_program_state",
    "select_next_checkpoint", "ready_to_claim",
    "finalize_checkpoint", "advance_to_next",
    "increment_cp_counter", "record_aggregate_change",
    "verify_frozen_graph",
    "is_program_terminal", "program_terminal_reason",
    "promotion_allowed",
    "source_tree_accounting",
]
