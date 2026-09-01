"""OwnFramework Loop PROGRAM mode — finite packet-bound checkpoint DAG.

A v3 packet with `execution_mode: program` carries a frozen
`checkpoint_graph`. The engine drives checkpoints one at a time in
topological order, satisfying the dependency contract declared in
the graph: a checkpoint with `depends_on: [CP-X, CP-Y]` becomes
*claimable* only after CP-X and CP-Y are both terminal-APPROVED.

Genericity: this module is product-agnostic. It neither imports nor
references any specific product. It only consumes packet metadata + git state.

Core invariants:
  - finite packet-bound checkpoint DAG
  - deterministic dependency-ready checkpoint selection
  - packet-bound checkpoint order and budgets
  - checkpoint-local build/review/repair counters
  - bounded per-checkpoint and cumulative pass ceilings
  - cumulative caps == min(human-approved global envelope, checkpoint-cap sum)
  - no post-approval widening (graph SHA frozen at program start)
  - one candidate branch per run, shared across all checkpoints
  - immutable checkpoint evidence
  - automatic checkpoint advancement when dependencies finish
  - fail-closed repair exhaustion
  - one program-level APPROVED|BLOCKED|STOPPED result
"""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path
from typing import Any

from .util import sha256_text, utc_now_iso
from .integrity import canonical_json_dumps
from .state import is_program_state, load as state_load, append_event, save as state_save


PROGRAM_SCHEMA_VERSION = "ownframework-work-packet/v3"
STATE_PROGRAM_KEY = "program"
MAX_CP_BUILD_PASSES = 32
MAX_CP_REVIEW_PASSES = 32
MAX_CP_REPAIR_ROUNDS = 32
GLOBAL_MAX_UNIQUE_CHANGED_FILES = 500
GLOBAL_MAX_BASELINE_TO_FINAL_DIFF_LINES = 30000


class ProgramGraphError(ValueError):
    """Static graph contract violation (DAG, deps, caps)."""


class ProgramStateError(RuntimeError):
    """Live state contract violation (frozen graph drift, ceiling breach)."""


_CP_RE = re.compile(r"^CP-[0-9]+$")


def _cp_id(s: Any) -> bool:
    return isinstance(s, str) and bool(_CP_RE.fullmatch(s))


def resolve_execution_mode(meta: dict[str, Any]) -> str:
    v = meta.get("execution_mode")
    if v is None:
        return "single"
    if v not in ("single", "program"):
        raise ProgramGraphError(f"invalid execution_mode: {v!r}")
    return v


def packet_acceptance_criterion_ids(packet: dict[str, Any]) -> list[str]:
    """Return deterministic top-level acceptance-criterion identities."""
    out: list[str] = []
    for idx, item in enumerate(packet.get("acceptance_criteria") or [], start=1):
        if isinstance(item, dict) and isinstance(item.get("id"), str) and item["id"]:
            out.append(item["id"])
        else:
            out.append(f"AC-{idx}")
    return out


def current_checkpoint_acceptance_criterion_ids(
    packet: dict[str, Any],
    program_state: dict[str, Any],
) -> list[str]:
    """Resolve the exact AC set owned by the current PROGRAM checkpoint.

    Backward compatibility: a graph with no acceptance_criterion_ids mapping
    preserves the historical behavior where every checkpoint is reviewed
    against every packet-level AC.
    """
    all_ids = packet_acceptance_criterion_ids(packet)
    current = list(program_state.get("current_checkpoints") or [])
    if not current:
        return all_ids
    cp_id = current[0]
    for cp in (packet.get("checkpoint_graph") or {}).get("checkpoints") or []:
        if not isinstance(cp, dict) or cp.get("id") != cp_id:
            continue
        scoped = cp.get("acceptance_criterion_ids")
        if scoped is None:
            return all_ids
        if not isinstance(scoped, list) or not scoped:
            raise ProgramStateError(
                f"checkpoint {cp_id} acceptance_criterion_ids missing/invalid"
            )
        return [str(x) for x in scoped]
    raise ProgramStateError(f"current checkpoint {cp_id!r} missing from packet graph")


def validate_checkpoint_graph(packet: dict[str, Any]) -> list[str]:
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
        if "acceptance_criteria" in cp:
            errors.append(
                f"{cid}: checkpoint field 'acceptance_criteria' is not executable; "
                "use 'acceptance_criterion_ids' to scope top-level AC ids"
            )
        if not isinstance(cp.get("risk_budget"), dict):
            errors.append(f"{cid}: risk_budget missing")

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

    scoped_cps = [
        cp for cp in by_id.values()
        if "acceptance_criterion_ids" in cp
    ]
    if scoped_cps:
        top_items = packet.get("acceptance_criteria") or []
        explicit_top_ids: list[str] = []
        missing_explicit = False
        for item in top_items:
            if (
                isinstance(item, dict)
                and isinstance(item.get("id"), str)
                and item.get("id")
            ):
                explicit_top_ids.append(item["id"])
            else:
                missing_explicit = True
        if missing_explicit:
            errors.append(
                "checkpoint acceptance scoping requires every top-level "
                "acceptance_criteria item to carry an explicit id"
            )
        if len(set(explicit_top_ids)) != len(explicit_top_ids):
            errors.append("top-level acceptance_criteria ids must be unique")
        if len(scoped_cps) != len(by_id):
            errors.append(
                "when any checkpoint declares acceptance_criterion_ids, "
                "every checkpoint must declare it"
            )
        top_id_set = set(explicit_top_ids)
        covered: set[str] = set()
        for cid, cp in by_id.items():
            ids = cp.get("acceptance_criterion_ids")
            if not isinstance(ids, list) or not ids:
                errors.append(
                    f"{cid}: acceptance_criterion_ids must be a non-empty list"
                )
                continue
            if any(not isinstance(x, str) or not x for x in ids):
                errors.append(
                    f"{cid}: acceptance_criterion_ids entries must be non-empty strings"
                )
                continue
            if len(set(ids)) != len(ids):
                errors.append(
                    f"{cid}: acceptance_criterion_ids must not contain duplicates"
                )
            unknown = sorted(set(ids) - top_id_set)
            if unknown:
                errors.append(
                    f"{cid}: acceptance_criterion_ids reference unknown ids {unknown}"
                )
            covered.update(x for x in ids if x in top_id_set)
        missing_coverage = sorted(top_id_set - covered)
        if missing_coverage:
            errors.append(
                "checkpoint acceptance_criterion_ids do not cover packet AC ids: "
                f"{missing_coverage}"
            )

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

    position = {cid: i for i, cid in enumerate(order)}
    for cid, idx in position.items():
        cp = by_id[cid]
        for d in cp.get("depends_on", []):
            if d not in position:
                continue
            if position[d] >= idx:
                errors.append(
                    f"execution order invalid: {cid} (idx {idx}) must come AFTER dependency {d} (idx {position[d]})"
                )

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
    rb_global = packet.get("risk_budget") or {}
    if isinstance(rb_global, dict):
        n_cps = len(by_id)
        gb = rb_global.get("max_build_passes")
        gr = rb_global.get("max_review_passes")
        gp = rb_global.get("max_repair_rounds")
        if isinstance(gb, int) and gb < n_cps:
            errors.append(
                f"packet-level max_build_passes={gb} cannot accommodate {n_cps} checkpoints"
            )
        if isinstance(gr, int) and gr < n_cps:
            errors.append(
                f"packet-level max_review_passes={gr} cannot accommodate {n_cps} checkpoints"
            )
        if isinstance(gp, int) and gp > 0:
            needed = n_cps + gp
            if isinstance(gb, int) and gb < needed:
                errors.append(
                    f"packet-level max_build_passes={gb} cannot realize "
                    f"max_repair_rounds={gp} across {n_cps} checkpoints; need >= {needed}"
                )
            if isinstance(gr, int) and gr < needed:
                errors.append(
                    f"packet-level max_review_passes={gr} cannot realize "
                    f"max_repair_rounds={gp} across {n_cps} checkpoints; need >= {needed}"
                )
    return errors


def checkpoint_graph_sha256(packet: dict[str, Any]) -> str:
    cg = packet.get("checkpoint_graph") or {}
    body = {
        "execution_order": cg.get("execution_order", []),
        "checkpoints": cg.get("checkpoints", []),
        "global_source_ceilings": cg.get("global_source_ceilings", {}),
    }
    return sha256_text(canonical_json_dumps(body))


def resolve_promotion_policy(packet: dict[str, Any]) -> str:
    p = packet.get("promotion_policy")
    if p is None:
        return "human_gate"
    if p not in ("human_gate", "merge_on_approved"):
        raise ProgramGraphError(f"invalid promotion_policy: {p!r}")
    return p


def materialise_initial_program_state(
    packet: dict[str, Any],
    *,
    baseline_sha: str,
    candidate_branch: str,
) -> dict[str, Any]:
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

    global_rb = packet.get("risk_budget") or {}
    global_build_cap = int(global_rb.get("max_build_passes", 0))
    global_review_cap = int(global_rb.get("max_review_passes", 0))
    global_repair_cap = int(global_rb.get("max_repair_rounds", 0))

    sum_build = sum(int(cp["risk_budget"]["max_build_passes"]) for cp in packet["checkpoint_graph"]["checkpoints"])
    sum_review = sum(int(cp["risk_budget"]["max_review_passes"]) for cp in packet["checkpoint_graph"]["checkpoints"])
    sum_repair = sum(int(cp["risk_budget"]["max_repair_rounds"]) for cp in packet["checkpoint_graph"]["checkpoints"])

    n_cps = len(packet["checkpoint_graph"]["checkpoints"])
    if global_build_cap and global_build_cap < n_cps:
        raise ProgramGraphError(
            f"packet-level max_build_passes={global_build_cap} cannot accommodate {n_cps} checkpoints (need >=1 build per CP)"
        )
    if global_review_cap and global_review_cap < n_cps:
        raise ProgramGraphError(
            f"packet-level max_review_passes={global_review_cap} cannot accommodate {n_cps} checkpoints (need >=1 review per CP)"
        )

    cumulative = {
        "max_build_passes": min(global_build_cap, sum_build) if global_build_cap else sum_build,
        "max_review_passes": min(global_review_cap, sum_review) if global_review_cap else sum_review,
        "max_repair_rounds": min(global_repair_cap, sum_repair) if global_repair_cap else sum_repair,
    }
    sc = packet["checkpoint_graph"].get("global_source_ceilings") or {}
    cumulative["max_unique_changed_files"] = int(
        sc.get("max_unique_changed_files", GLOBAL_MAX_UNIQUE_CHANGED_FILES)
    )
    cumulative["max_baseline_to_final_diff_lines"] = int(
        sc.get("max_baseline_to_final_diff_lines", GLOBAL_MAX_BASELINE_TO_FINAL_DIFF_LINES)
    )

    deps_map = {cp["id"]: list(cp.get("depends_on", [])) for cp in packet["checkpoint_graph"]["checkpoints"]}
    remaining = list(packet["checkpoint_graph"]["execution_order"])
    current: list[str] = []
    for cid in remaining:
        if not deps_map.get(cid):
            current = [cid]
            break
    if not current and remaining:
        current = [remaining[0]]

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
            "envelope_source": "min(global_packet_cap, sum_checkpoint_caps)",
            "packet_global_cap": {
                "max_build_passes": global_build_cap,
                "max_review_passes": global_review_cap,
                "max_repair_rounds": global_repair_cap,
            },
            "checkpoint_sum_cap": {
                "max_build_passes": sum_build,
                "max_review_passes": sum_review,
                "max_repair_rounds": sum_repair,
            },
        },
    }


def select_next_checkpoint(packet: dict[str, Any], program_state: dict[str, Any]) -> str | None:
    cur = program_state.get("current_checkpoints") or []
    return cur[0] if cur else None


def ready_to_claim(cp_state: dict[str, Any], packet_cp: dict[str, Any]) -> tuple[bool, str]:
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
    if terminal_state not in ("APPROVED", "BLOCKED", "STOPPED"):
        raise ProgramStateError(f"invalid terminal_state: {terminal_state}")

    cp = _find_cp(program_state, cp_id)
    # Nonterminal checkpoints are represented by the legacy falsy empty string.
    # Never confuse that with an already-finalized checkpoint.
    if cp.get("terminal"):
        raise ProgramStateError(
            f"checkpoint {cp_id} already terminal={cp.get('terminal')}; duplicate finalization refused"
        )
    if any(fc.get("id") == cp_id for fc in (program_state.get("finalized_checkpoints") or [])):
        raise ProgramStateError(
            f"checkpoint {cp_id} already present in finalized_checkpoints; duplicate finalization refused"
        )
    if terminal_state == "APPROVED":
        if cp["build_pass_count"] < 1 or cp["review_pass_count"] < 1:
            raise ProgramStateError(
                "nonterminal_cp_approval_refused: cannot finalize APPROVED with no build+review pass"
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
    new = _deepcopy_program(program_state)
    _refresh_current_checkpoints(new, packet_for=packet)
    return new


def advance_after_review_approval(
    *,
    canonical_repo: Path,
    run_id: str,
    packet: dict[str, Any],
    state: dict[str, Any],
    candidate_sha: str,
    verdict_sha256: str,
    review_pass_number: int,
    actor: str,
) -> dict[str, Any]:
    if not is_program_state(state):
        raise ProgramStateError("advance_after_review_approval called on a non-program run")
    if state.get("state") != "REVIEWING":
        raise ProgramStateError(
            f"program advancement requires top-level REVIEWING, got {state.get('state')!r}"
        )
    cur = state.get("program") or {}
    frozen_ok, frozen_reason = verify_frozen_graph(packet, cur)
    if not frozen_ok:
        raise ProgramStateError(
            f"program advancement refused: frozen graph invalid ({frozen_reason})"
        )
    bound_candidate = state.get("last_candidate_sha") or ""
    if not bound_candidate or bound_candidate != candidate_sha:
        raise ProgramStateError(
            "program advancement candidate SHA does not match state.last_candidate_sha"
        )
    cur_cps = list(cur.get("current_checkpoints") or [])
    if not cur_cps:
        raise ProgramStateError("no current checkpoint in program state; cannot advance")
    cp_id = cur_cps[0]

    evidence_manifest = {
        "_packet": packet,
        "candidate_sha": candidate_sha,
        "verdict_sha256": verdict_sha256,
        "review_pass_number": int(review_pass_number),
        "approved_at": utc_now_iso(),
        "approved_actor": actor,
        "cp_id": cp_id,
    }
    new_program = finalize_checkpoint(
        program_state=cur,
        cp_id=cp_id,
        terminal_state="APPROVED",
        evidence_manifest=evidence_manifest,
    )
    new_program = advance_to_next(new_program, packet)
    new_cps = list(new_program.get("current_checkpoints") or [])
    next_top_state = "READY_TO_BUILD" if new_cps else "APPROVED"

    # v0.4.6: PROGRAM advancement uses the atomic FSM-owned transition path.
    # The prospective PROGRAM block is supplied so program_transition validates
    # REVIEWING -> READY_TO_BUILD against the post-finalization graph.
    from . import state as state_mod
    transition_reason = (
        "all_checkpoints_approved"
        if next_top_state == "APPROVED"
        else f"checkpoint {cp_id} approved; advancing to {new_cps[0]}"
    )
    # Typed owner parameters only; terminal_reason is owned by the transition
    # owner (set from `reason` on terminal targets, cleared on continuation).
    new_top = state_mod.program_transition(
        canonical_repo,
        run_id,
        to_state=next_top_state,
        actor=actor,
        reason=transition_reason,
        commit_sha=candidate_sha,
        program_block=new_program,
        schema_version=state_mod.PROGRAM_STATE_SCHEMA_VERSION,
        # A fresh checkpoint starts with a clean review-repetition fuse.
        identical_finding_streak=0,
        last_must_fix_fingerprint="",
    )
    append_event(
        canonical_repo, run_id,
        event_type="program_advanced",
        old_state=state.get("state"),
        new_state=next_top_state,
        actor=actor,
        commit_sha=candidate_sha,
        reason=f"CP {cp_id} APPROVED via review pass {review_pass_number}; next top state={next_top_state}, current_checkpoints={new_cps}",
        extras={
            "cp_id_finalized": cp_id,
            "cp_terminal": "APPROVED",
            "verdict_sha256": verdict_sha256,
            "next_checkpoints": new_cps,
        },
    )
    return {
        "advanced_to_cp": new_cps[0] if new_cps else "",
        "finalized_cp": cp_id,
        "next_top_state": next_top_state,
        "evidence_manifest_sha256": sha256_text(canonical_json_dumps(evidence_manifest)),
        "terminal_state": "APPROVED",
    }


def increment_cp_counter(
    program_state: dict[str, Any],
    *,
    cp_id: str,
    counter: str,
    packet_cp: dict[str, Any],
) -> dict[str, Any]:
    if counter not in ("build_pass_count", "review_pass_count", "repair_round_count"):
        raise ProgramStateError(f"unknown counter {counter!r}")
    new = _deepcopy_program(program_state)
    cp = _find_cp(new, cp_id)
    cap_key = {
        "build_pass_count": "max_build_passes",
        "review_pass_count": "max_review_passes",
        "repair_round_count": "max_repair_rounds",
    }[counter]
    cap = int(packet_cp["risk_budget"][cap_key])
    cum_cap = new["cumulative_ceilings"][cap_key]
    # Check BEFORE incrementing (same contract as _bump_counter_one): a
    # raised exception must never leave the returned state over-cap, so an
    # error handler persisting the returned dict cannot breach a ceiling.
    if cp[counter] >= cap:
        raise ProgramStateError(
            f"per-checkpoint cap reached for {counter} on {cp_id}: {cp[counter]}/{cap}"
        )
    if new["cumulative_counters"][counter] >= cum_cap:
        raise ProgramStateError(
            f"cumulative cap reached for {counter}: {new['cumulative_counters'][counter]}/{cum_cap}"
        )
    cp[counter] += 1
    new["cumulative_counters"][counter] += 1
    return new


def _bump_counter_one(
    program_state: dict[str, Any],
    *,
    cp_id: str,
    counter: str,
    packet_cp: dict[str, Any],
) -> dict[str, Any]:
    if counter not in ("build_pass_count", "review_pass_count", "repair_round_count"):
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
            f"per-checkpoint cap reached for {counter} on {cp_id}: {cp[counter]}/{cp_cap}"
        )
    if new["cumulative_counters"][counter] >= cum_cap:
        raise ProgramStateError(
            f"cumulative cap reached for {counter}: {new['cumulative_counters'][counter]}/{cum_cap}"
        )
    cp[counter] += 1
    new["cumulative_counters"][counter] += 1
    return new


class ClaimRefused(ProgramStateError):
    """A deterministic PROGRAM pass claim was refused."""


class ClaimCapExhausted(ClaimRefused):
    """A claim was refused because a packet-bound cap was reached.

    Cap exhaustion is a legitimate engineered stopping condition, not
    corruption: the run should fail closed toward BLOCKED so the supervisor
    can surface a terminal result instead of looping on quarantine.
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
    from . import state as state_mod

    if counter not in ("build_pass_count", "review_pass_count", "repair_round_count"):
        raise ClaimRefused(f"unsupported counter for claim: {counter!r}")
    top_counter_name = {
        "build_pass_count": "build_pass_count",
        "review_pass_count": "review_pass_count",
        "repair_round_count": "repair_round",
    }[counter]
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
        if not isinstance(cur, dict):
            raise ClaimRefused("STATE.json missing or unreadable")
        if cur.get("schema") != state_mod.PROGRAM_STATE_SCHEMA_VERSION:
            raise ClaimRefused(f"program state required (got schema={cur.get('schema')!r})")
        program_state = cur.get("program")
        if not isinstance(program_state, dict):
            raise ClaimRefused("missing program block")
        ok, reason = verify_frozen_graph(packet, program_state)
        if not ok:
            raise ClaimRefused(f"frozen-graph drift: {reason}")

        cur_state = cur.get("state")
        existing_cum = int(program_state["cumulative_counters"].get(counter, 0))
        cp_id_replay = select_next_checkpoint(packet, program_state)
        existing_cp = next(
            (c for c in program_state["checkpoints"] if c["id"] == cp_id_replay),
            None,
        ) if cp_id_replay else None
        existing_cp_pass = int(existing_cp[counter]) if existing_cp else 0
        last_evidence = (existing_cp or {}).get("last_evidence_sha_by_counter") or {}
        last_evidence_for_counter = last_evidence.get(counter)

        existing_top = int(cur.get(top_counter_name, 0) or 0)
        if existing_top != existing_cum:
            raise ClaimRefused(
                f"{pass_kind} counter mirror drift: top={existing_top}, cumulative={existing_cum}"
            )

        is_replay = False
        if counter == "repair_round_count":
            if (
                existing_cp_pass > 0
                and source_evidence_sha is not None
                and source_evidence_sha == last_evidence_for_counter
            ):
                is_replay = True
        elif cur_state == replay_states[counter]:
            if existing_cp is None or existing_cp_pass < 1:
                raise ClaimRefused(
                    f"{pass_kind} replay refused: in-flight state has no claimed current-checkpoint pass"
                )
            if existing_cum < 1:
                raise ClaimRefused(
                    f"{pass_kind} replay refused: cumulative counter is zero"
                )
            is_replay = True

        if is_replay:
            return {
                "ok": True,
                "run_id": run_id,
                "counter": counter,
                "pass_kind": pass_kind,
                "cp_id": cp_id_replay,
                "claimed_pass_number": existing_top,
                "cp_pass_number": existing_cp_pass,
                "cumulative": int(program_state["cumulative_counters"].get(counter, 0)),
                "cap": int(program_state["cumulative_ceilings"].get(cap_key, 0)),
                "replayed": True,
            }

        # v0.4.6: phase legality is enforced atomically by the claim owner,
        # not merely by host-skill fast paths. This closes the race where the
        # builder and reviewer lanes both read an eligible-looking state and
        # then claim in the wrong phase.
        allowed_new_states = {
            "build_pass_count": {"READY_TO_BUILD", "CHANGES_REQUESTED"},
            "review_pass_count": {"READY_FOR_REVIEW"},
            "repair_round_count": {"CHANGES_REQUESTED"},
        }
        if cur_state not in allowed_new_states[counter]:
            raise ClaimRefused(
                f"{pass_kind} claim refused in top-level state {cur_state!r}; "
                f"allowed={sorted(allowed_new_states[counter])}"
            )
        # The unified claim owner is the sole authority for these claim
        # edges (including CHANGES_REQUESTED -> BUILDING, which the generic
        # single-mode FSM table intentionally does not contain). Assert the
        # exact edge legality here so a future source/target drift fails
        # closed instead of writing an unvalidated state change.
        _CLAIM_OWNER_EDGES = {
            ("READY_TO_BUILD", "BUILDING"),
            ("CHANGES_REQUESTED", "BUILDING"),
            ("READY_FOR_REVIEW", "REVIEWING"),
            ("CHANGES_REQUESTED", "CHANGES_REQUESTED"),
        }
        if (cur_state, replay_states[counter]) not in _CLAIM_OWNER_EDGES:
            raise ClaimRefused(
                f"{pass_kind} claim edge {cur_state!r} -> "
                f"{replay_states[counter]!r} is not a legal claim-owner edge"
            )

        cp_id = select_next_checkpoint(packet, program_state)
        if cp_id is None:
            raise ClaimRefused("no claimable checkpoint")
        packet_cp = _resolve_packet_cp(packet, cp_id)
        cp_live = _find_cp(program_state, cp_id)
        if cp_live.get("terminal"):
            raise ClaimRefused(f"checkpoint {cp_id} is terminal: {cp_live['terminal']}")

        try:
            new_program = _bump_counter_one(
                program_state,
                cp_id=cp_id,
                counter=counter,
                packet_cp=packet_cp,
            )
        except ProgramStateError as exc:
            # _bump_counter_one refuses only on per-checkpoint or cumulative
            # cap exhaustion; surface that precise classification so claim
            # owners can fail closed toward BLOCKED instead of quarantine.
            raise ClaimCapExhausted(str(exc)) from exc
        new_program_evidence = _deepcopy_program(new_program)
        cp_new = _find_cp(new_program_evidence, cp_id)
        ev_map = dict(cp_new.get("last_evidence_sha_by_counter") or {})
        if source_evidence_sha is not None:
            ev_map[counter] = source_evidence_sha
        cp_new["last_evidence_sha_by_counter"] = ev_map

        new_state = dict(cur)
        new_state["program"] = new_program_evidence
        new_state[top_counter_name] = int(cur.get(top_counter_name, 0) or 0) + 1
        new_state["updated_at"] = state_mod.utc_now_iso()
        new_state["last_actor"] = "of-loop-claim"
        new_state["state"] = replay_states[counter]
        state_mod._write_state_locked(canonical_repo, run_id, new_state)

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


def claim_build_pass(*, canonical_repo: Path, run_id: str, packet: dict[str, Any]) -> dict[str, Any]:
    return _unified_claim_pass(
        canonical_repo=canonical_repo,
        run_id=run_id,
        packet=packet,
        counter="build_pass_count",
        pass_kind="build",
    )


def claim_review_pass(*, canonical_repo: Path, run_id: str, packet: dict[str, Any]) -> dict[str, Any]:
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
    """Claim one repair round; any refusal is fail-closed for the active run.

    A native reviewer must never reopen READY_TO_BUILD after the approved repair
    envelope has been exhausted. If the deterministic repair claim cannot be
    granted, transition CHANGES_REQUESTED -> BLOCKED before surfacing refusal.
    """
    try:
        return _unified_claim_pass(
            canonical_repo=canonical_repo,
            run_id=run_id,
            packet=packet,
            counter="repair_round_count",
            pass_kind="repair",
            source_evidence_sha=source_evidence_sha,
        )
    except ClaimRefused as refusal:
        from . import state as state_mod
        cur = state_mod.load_verified(canonical_repo, run_id)
        if isinstance(cur, dict) and cur.get("state") == "CHANGES_REQUESTED":
            try:
                state_mod.transition(
                    canonical_repo,
                    run_id,
                    to_state="BLOCKED",
                    actor="of-loop-repair-gate",
                    reason=f"repair claim refused: {refusal}",
                    commit_sha=cur.get("last_candidate_sha") or None,
                )
            except Exception as transition_error:
                raise ClaimRefused(
                    f"{refusal}; failed to seal run BLOCKED after repair refusal: {transition_error}"
                ) from transition_error
        raise


def record_source_accounting(
    program_state: dict[str, Any],
    *,
    files_changed_unique: int,
    diff_lines_total: int,
) -> dict[str, Any]:
    """Set the program-wide source accounting from an ABSOLUTE
    baseline-to-candidate measurement.

    The global source ceilings (``max_unique_changed_files``,
    ``max_baseline_to_final_diff_lines``) are declared in
    unique-file / baseline-to-final semantics: they bound the total
    source delta between the approved baseline and the current candidate
    of the single shared candidate branch. The correct accounting is
    therefore a re-measurement of ``baseline..candidate`` at each build
    finalization, written absolutely — NOT an additive accumulation of
    per-pass deltas. Additive per-pass accounting double-counts every
    file touched by more than one pass, counts reverted churn, and
    drifts above the true baseline-to-final delta, starving legitimate
    multi-checkpoint programs.

    Raises ``ProgramStateError`` when the measurement breaches a ceiling;
    callers must treat a breach as a fail-closed stop of the run.
    """
    if files_changed_unique < 0 or diff_lines_total < 0:
        raise ProgramStateError("source accounting must be non-negative")
    new = _deepcopy_program(program_state)
    new["cumulative_counters"]["files_changed_unique"] = int(files_changed_unique)
    new["cumulative_counters"]["diff_lines_total"] = int(diff_lines_total)
    ce = new["cumulative_ceilings"]
    cc = new["cumulative_counters"]
    breaches: list[str] = []
    if cc["files_changed_unique"] > ce["max_unique_changed_files"]:
        breaches.append(
            f"global file cap reached: {cc['files_changed_unique']}/{ce['max_unique_changed_files']}"
        )
    if cc["diff_lines_total"] > ce["max_baseline_to_final_diff_lines"]:
        breaches.append(
            f"global diff-lines cap reached: {cc['diff_lines_total']}/{ce['max_baseline_to_final_diff_lines']}"
        )
    if breaches:
        raise ProgramStateError("; ".join(breaches))
    return new


def verify_frozen_graph(packet: dict[str, Any], program_state: dict[str, Any]) -> tuple[bool, str]:
    cur = program_state.get("checkpoint_graph_sha256")
    want = checkpoint_graph_sha256(packet)
    if cur != want:
        return False, "post-approval_graph_drift"
    return True, "ok"


def is_program_terminal(program_state: dict[str, Any]) -> tuple[bool, str]:
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


def _find_cp(program_state: dict[str, Any], cp_id: str) -> dict[str, Any]:
    for cp in program_state["checkpoints"]:
        if cp["id"] == cp_id:
            return cp
    raise ProgramStateError(f"unknown checkpoint id: {cp_id}")


def _deepcopy_program(program_state: dict[str, Any]) -> dict[str, Any]:
    return json.loads(canonical_json_dumps(program_state))


def _refresh_current_checkpoints(
    program_state: dict[str, Any],
    *,
    packet_for: dict[str, Any] | None,
) -> None:
    if packet_for is None:
        return
    order: list[str] = packet_for["checkpoint_graph"]["execution_order"]
    by_id: dict[str, dict[str, Any]] = {
        cp["id"]: cp for cp in packet_for["checkpoint_graph"]["checkpoints"]
    }
    finalized_ids = {
        fc["id"]: fc["terminal_state"] for fc in program_state["finalized_checkpoints"]
    }
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


def source_tree_accounting(
    *,
    canonical_repo: Path,
    baseline_sha: str,
    candidate_sha: str,
) -> dict[str, int]:
    diff = subprocess.run(
        ["git", "-C", str(canonical_repo), "diff", "--no-color", baseline_sha, candidate_sha, "--numstat"],
        capture_output=True,
        text=True,
        check=True,
    )
    files = 0
    diff_lines = 0
    for line in diff.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) < 3:
            raise ProgramStateError(
                f"malformed git numstat line during source accounting: {line!r}"
            )
        a, d = parts[0], parts[1]
        # Binary changes report '-' for line counts, but they are still
        # changed files and must consume the unique-file source ceiling.
        files += 1
        if a == "-" or d == "-":
            continue
        try:
            ai = int(a)
            di = int(d)
        except ValueError as exc:
            raise ProgramStateError(
                f"non-numeric git numstat line during source accounting: {line!r}"
            ) from exc
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
    "finalize_checkpoint", "advance_to_next", "advance_after_review_approval",
    "increment_cp_counter", "record_source_accounting",
    "ClaimRefused", "claim_build_pass", "claim_review_pass",
    "claim_repair_round", "_unified_claim_pass", "_bump_counter_one",
    "verify_frozen_graph",
    "is_program_terminal", "program_terminal_reason",
    "source_tree_accounting",
    "ClaimCapExhausted",
]
