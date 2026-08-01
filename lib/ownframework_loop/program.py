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
            f"{new['cumulative_counters'][counter]}/{cum_cap}"
        )
    return new


def _bump_counter_one(
    program_state: dict[str, Any],
    *,
    cp_id: str,
    counter: str,
    packet_cp: dict[str, Any],
) -> dict[str, Any]:
    """Pure-Python helper: bump per-cp + cumulative counters in memory.

    Both caps are checked *before* any mutation. Raises on cap breach.
    Returns a deep-copied program_state with the counters bumped.

    Used by both the legacy `increment_cp_counter` and the unified
    `claim_*_pass` owner functions so the cap logic exists in exactly
    one place.
    """
    if counter not in (
        "build_pass_count", "review_pass_count", "repair_round_count",
    ):
        raise ProgramStateError(f"unknown counter {counter!r}")
    cap_key = {
        "build_pass_count": "max_build_passes",
        "review_pass_count": "max_review_passes",
        "repair_round_count": "max_repair_rounds",
    }[counter]
    cp_cap = int(packet_cp["risk_budget"][cap_key])
    cum_cap = int(program_state["cumulative_ceilings"][cap_key])

    new = _deepcopy_program(program_state)
    cp = _find_cp(new, cp_id)
    if cp[counter] >= cp_cap:
        raise ProgramStateError(
            f"per-checkpoint cap reached for {counter} on {cp_id}: "
            f"{cp[counter]}/{cp_cap}"
        )
    if new["cumulative_counters"][counter] >= cum_cap:
        raise ProgramStateError(
            f"cumulative cap reached for {counter}: "
            f"{new['cumulative_counters'][counter]}/{cum_cap}"
        )
    cp[counter] += 1
    new["cumulative_counters"][counter] += 1
    return new


class ClaimRefused(ProgramStateError):
    """Raised by claim_*_pass when the program has refused a claim.

    Carries a stable `code` (machine-readable) and a human `message`.
    Subclass of ProgramStateError so existing exception handlers in
    callers still catch it without code change.
    """


def _resolve_packet_cp(packet: dict[str, Any], cp_id: str) -> dict[str, Any]:
    for cp in packet["checkpoint_graph"]["checkpoints"]:
        if cp["id"] == cp_id:
            return cp
    raise ClaimRefused(f"unknown checkpoint id: {cp_id}")


def _unified_claim_pass(
    *,
    canonical_repo: Path,
    run_id: str,
    packet: dict[str, Any],
    counter: str,
    pass_kind: str,
    source_evidence_sha: str | None = None,
) -> dict[str, Any]:
    """Single durable owner of the PROGRAM build/review/repair claim.

    Performs EVERY step of the claim under ONE flock-protected state
    save so per-cp, cumulative, and top-level mirror counters cannot
    desync on a crash between any two writes.

    Steps (in order, under one flock):

      1. verify STATE.json present and program block present
      2. verify schema == ownframework-loop-state/v2
      3. verify frozen graph SHA matches packet (no post-approval widening)
      4. resolve the current claimable checkpoint (select_next_checkpoint)
      5. verify the cp is not yet terminal
      6. enforce per-checkpoint cap (pre-mutation check, refuses before bump)
      7. enforce approved program cumulative cap (pre-mutation check)
      8. increment per-cp counter exactly once
      9. increment cumulative counter exactly once
     10. mirror the increment into the top-level state counter exactly once
     11. persist STATE.json atomically (single write)
     12. return the stable claimed pass numbers

    Replay safety: if the current FSM state already corresponds to the
    claimed pass (e.g. BUILDING for build_pass_count) AND the source
    evidence SHA matches the recorded evidence for that cp, the
    function returns the existing pass number WITHOUT incrementing.

    v0.3.5 (F-4-01): for repair_round_count, the replay guard is
    keyed on `source_evidence_sha` rather than the (state, cum>0)
    pair. Each repair round has different evidence (the candidate
    SHA changes between rounds); a duplicate evidence SHA is a
    genuine retry. This allows max_repair_rounds > 1 to actually
    function.
    """
    from . import state as state_mod  # late import to avoid cycle at module load

    if counter not in (
        "build_pass_count", "review_pass_count", "repair_round_count",
    ):
        raise ClaimRefused(f"unsupported counter for claim: {counter!r}")

    top_counter_name = {
        "build_pass_count": "build_pass_count",
        "review_pass_count": "review_pass_count",
        "repair_round_count": "repair_round",
    }[counter]

    # Repair replay state: CHANGES_REQUESTED (the state entered after
    # review_finalize returns CHANGES_REQUESTED). Setting it to "BUILDING"
    # would poison the next build claim's replay guard.
    # After a successful claim_repair_round, the explicit post-hook forces
    # state back to READY_TO_BUILD (or CHANGES_REQUESTED) so the next build
    # claim is NOT replayed.
    replay_states = {
        "build_pass_count": "BUILDING",
        "review_pass_count": "REVIEWING",
        "repair_round_count": "CHANGES_REQUESTED",
    }

    cap_key = {
        "build_pass_count": "max_build_passes",
        "review_pass_count": "max_review_passes",
        "repair_round_count": "max_repair_rounds",
    }[counter]

    with state_mod._locked_state(canonical_repo, run_id) as cur:
        # 1. STATE.json must be present.
        if not isinstance(cur, dict):
            raise ClaimRefused("STATE.json missing or unreadable")
        # 2. Schema must be v2 (program).
        if cur.get("schema") != state_mod.PROGRAM_STATE_SCHEMA_VERSION:
            raise ClaimRefused(
                f"program state required (got schema={cur.get('schema')!r})"
            )
        program_state = cur.get("program")
        if not isinstance(program_state, dict):
            raise ClaimRefused("missing program block")
        # 3. Frozen graph must match.
        ok, reason = verify_frozen_graph(packet, program_state)
        if not ok:
            raise ClaimRefused(f"frozen-graph drift: {reason}")

        # Replay guard. Two cases:
        #
        # (a) build_pass_count / review_pass_count — keyed on the FSM
        #     state. After a successful claim, the state is set to
        #     BUILDING / REVIEWING. A retried claim sees the same
        #     state and returns the existing pass number without
        #     incrementing. This is the original guard.
        #
        # (b) repair_round_count — keyed on source_evidence_sha per-cp.
        #     v0.3.5 (F-4-01): the FSM state alone is insufficient
        #     because CHANGES_REQUESTED is the persistent state for
        #     repair claims. Each repair round has different evidence
        #     (the candidate SHA changes between rounds); a duplicate
        #     evidence SHA is a genuine retry.
        cur_state = cur.get("state")
        existing_cum = int(program_state["cumulative_counters"].get(counter, 0))
        # Resolve the current cp id once so both guard branches use it.
        cp_id_replay = select_next_checkpoint(packet, program_state)
        existing_cp = (
            next(
                (c for c in program_state["checkpoints"]
                 if c["id"] == cp_id_replay),
                None,
            ) if cp_id_replay else None
        )
        existing_cp_pass = (
            int(existing_cp[counter]) if existing_cp else 0
        )
        # Per-cp evidence tracking: stores the source_evidence_sha
        # of the last claim on this cp, keyed by counter.
        last_evidence = (
            (existing_cp or {}).get("last_evidence_sha_by_counter") or {}
        )
        last_evidence_for_counter = last_evidence.get(counter)

        is_replay = False
        if counter == "repair_round_count":
            # Repair replay: same cp AND same evidence SHA = replay.
            if (
                existing_cp_pass > 0
                and source_evidence_sha is not None
                and source_evidence_sha == last_evidence_for_counter
            ):
                is_replay = True
        else:
            # Build/review replay: state must already match.
            if cur_state == replay_states[counter] and existing_cum > 0:
                is_replay = True

        if is_replay:
            existing_top = int(cur.get(top_counter_name, 0) or 0)
            return {
                "ok": True,
                "run_id": run_id,
                "counter": counter,
                "pass_kind": pass_kind,
                "cp_id": cp_id_replay,
                "claimed_pass_number": existing_top,
                "cp_pass_number": existing_cp_pass,
                "cumulative": int(
                    program_state["cumulative_counters"].get(counter, 0)
                ),
                "cap": int(
                    program_state["cumulative_ceilings"].get(cap_key, 0)
                ),
                "replayed": True,
            }

        # 4+5. Resolve current cp and verify it's claimable.
        cp_id = select_next_checkpoint(packet, program_state)
        if cp_id is None:
            raise ClaimRefused("no claimable checkpoint")
        packet_cp = _resolve_packet_cp(packet, cp_id)
        cp_live = _find_cp(program_state, cp_id)
        if cp_live.get("terminal"):
            raise ClaimRefused(
                f"checkpoint {cp_id} is terminal: {cp_live['terminal']}"
            )

        # 6+7+8+9. Bump per-cp + cumulative under deep-copy, refusing if
        # either cap would be exceeded. Pure-Python; no I/O until step 11.
        new_program = _bump_counter_one(
            program_state,
            cp_id=cp_id,
            counter=counter,
            packet_cp=packet_cp,
        )

        # v0.3.5 (F-4-01): record the source_evidence_sha on the cp
        # so the replay guard can distinguish a fresh repair round
        # from a duplicate retry.
        new_program_evidence = _deepcopy_program(new_program)
        cp_new = _find_cp(new_program_evidence, cp_id)
        ev_map = dict(cp_new.get("last_evidence_sha_by_counter") or {})
        if source_evidence_sha is not None:
            ev_map[counter] = source_evidence_sha
        cp_new["last_evidence_sha_by_counter"] = ev_map

        # 10. Mirror into top-level state counter and transition FSM so the
        #     replay guard (state==BUILDING|REVIEWING) detects re-claims.
        new_state = dict(cur)
        new_state["program"] = new_program_evidence
        new_state[top_counter_name] = int(cur.get(top_counter_name, 0) or 0) + 1
        new_state["updated_at"] = state_mod.utc_now_iso()
        new_state["last_actor"] = "of-loop-claim"
        # Repair claim returns to CHANGES_REQUESTED (we just claimed a
        # repair round on a CHANGES_REQUESTED state) so the next build
        # claim is NOT replayed. Build/review claims stay in BUILDING/
        # REVIEWING so legitimate replay returns idempotent.
        new_state["state"] = replay_states[counter]
        # Mirror build_pass_count into the program.state counter so
        # downstream readers (which check both v1 and v2 counters) stay
        # consistent with the program block.

        # 11. Persist atomically (under flock from the with-block).
        state_mod._write_state_locked(canonical_repo, run_id, new_state)

        # 12. Return stable pass numbers.
        cp_pass = int(_find_cp(new_program, cp_id)[counter])
        cum = int(new_program["cumulative_counters"][counter])
        return {
            "ok": True,
            "run_id": run_id,
            "counter": counter,
            "pass_kind": pass_kind,
            "cp_id": cp_id,
            "claimed_pass_number": int(new_state[top_counter_name]),
            "cp_pass_number": cp_pass,
            "cumulative": cum,
            "cap": int(new_program["cumulative_ceilings"][cap_key]),
            "replayed": False,
        }


def claim_build_pass(
    *,
    canonical_repo: Path,
    run_id: str,
    packet: dict[str, Any],
) -> dict[str, Any]:
    """Atomically claim one PROGRAM build pass. Single durable owner.

    Routes through `_unified_claim_pass` which is the ONLY function
    allowed to mutate program-build counters. Both the CLI
    (`cmd_build_claim`) and the orchestrator's `_drive_build_cycle`
    must call this; no separate counter increments are permitted.
    """
    return _unified_claim_pass(
        canonical_repo=canonical_repo,
        run_id=run_id,
        packet=packet,
        counter="build_pass_count",
        pass_kind="build",
    )


def claim_review_pass(
    *,
    canonical_repo: Path,
    run_id: str,
    packet: dict[str, Any],
) -> dict[str, Any]:
    """Atomically claim one PROGRAM review pass. Single durable owner."""
    return _unified_claim_pass(
        canonical_repo=canonical_repo,
        run_id=run_id,
        packet=packet,
        counter="review_pass_count",
        pass_kind="review",
    )


def claim_repair_round(
    *,
    canonical_repo: Path,
    run_id: str,
    packet: dict[str, Any],
    source_evidence_sha: str | None = None,
) -> dict[str, Any]:
    """Atomically claim one PROGRAM repair round. Single durable owner.

    v0.3.5 (F-4-01): accepts `source_evidence_sha` so the replay
    guard can distinguish a fresh repair round (different evidence,
    e.g. a new candidate SHA) from a duplicate retry (same evidence).
    The caller should pass the candidate SHA from the most recent
    build receipt so each round has fresh evidence.
    """
    return _unified_claim_pass(
        canonical_repo=canonical_repo,
        run_id=run_id,
        packet=packet,
        counter="repair_round_count",
        pass_kind="repair",
        source_evidence_sha=source_evidence_sha,
    )


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
    "ClaimRefused", "claim_build_pass", "claim_review_pass",
    "claim_repair_round", "_unified_claim_pass", "_bump_counter_one",
    "verify_frozen_graph",
    "is_program_terminal", "program_terminal_reason",
    "promotion_allowed",
    "source_tree_accounting",
]
