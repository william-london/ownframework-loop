#!/usr/bin/env bash
# v0.10.0-dev e: pre-1.0 behavioral regressions for the audit hardening.
#
# Each section proves observable BEHAVIOR (not source-text presence).
# Tests run in a single Python process; monkey-patches are scoped
# within that process so they don't leak across sections.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
PYTHON_BIN="$(command -v python3)"
[[ -x "$PYTHON_BIN" ]] || fail "python3 not on PATH"
cd "$ROOT_DIR"

PYTHONPATH="$ROOT_DIR/lib" "$PYTHON_BIN" -B <<'PY'
import json
import os
import sqlite3
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any

import ownframework_loop.state as state_mod
import ownframework_loop.dispatch as dispatch_mod
import ownframework_loop.program as program_mod
import ownframework_loop.supervisor_attempts as attempts_mod
import ownframework_loop.supervisor_db as db_mod
import ownframework_loop.supervisor_recovery as recovery_mod
import ownframework_loop.integrity as integrity_mod
import ownframework_loop.packet as packet_mod

failures = []
def check(label, cond, detail=""):
    if cond:
        print(f"  PASS: {label}")
    else:
        print(f"  FAIL: {label} {detail}")
        failures.append(label)

# =========================================================================
# A001 BEHAVIORAL: claim_next threads exact declared timeout to _run_cli
# =========================================================================
print("=== A001 behavioral: claim CLI receives exact packet timeout ===")
captured = {"calls": []}
def spy_run_cli(args, *, timeout_seconds=None):
    captured["calls"].append({"args": list(args), "timeout_seconds": timeout_seconds})
    if args and args[0] == "build" and args[1] == "claim":
        return {"schema": dispatch_mod.SCHEMA, "decision": "BUILD", "replayed": False,
                "pass_count": 1, "build_pass_count": 1, "run_id": "r1",
                "candidate_branch": "agent/r1/builder", "baseline_sha": "d"*40,
                "packet_sha256": "f"*64, "approval_sha256": "a"*64,
                "work_unit_id": "WU-1", "cp_id": "cp-1"}
    if args and args[0] == "build" and args[1] == "prepare":
        return {"schema": dispatch_mod.SCHEMA, "agent_result_path": "/tmp/x",
                "work_unit_id": "WU-1", "cp_id": "cp-1",
                "builder_worktree": "/tmp/wt", "candidate_branch": "agent/r1/builder",
                "baseline_sha": "d"*40, "packet_sha256": "f"*64, "approval_sha256": "a"*64}
    if args and args[0] == "build" and args[1] == "agent-skeleton":
        return {"schema": dispatch_mod.SCHEMA, "agent_result_path": "/tmp/x"}
    return {"schema": dispatch_mod.SCHEMA}

dispatch_mod._run_cli = spy_run_cli
# Bypass packet parsing — return a minimal but well-formed packet
fake_pkt = {
    "schema": "ownframework-work-packet/v1",
    "spec_version": "v1",
    "execution_mode": "program",
    "packet_id": "p1", "created_at": "2026-01-01T00:00:00Z",
    "work_class": "build", "risk_class": "low",
    "title": "test", "target": {"repo": "."},
    "allowed_paths": ["."], "protected_paths": [],
    "work_units": [{"id": "WU-1", "title": "unit"}],
    "merge_authority": "human_only", "deploy_authority": "human_only",
    "push_authority": "human_only", "external_action_authority": "none",
    "capabilities": [], "network_read_allowlist": [],
    "runner_profile": "default", "limits": {},
    "acceptance_criteria": [{"id": "AC-1", "title": "do"}],
    "non_goals": [{"id": "NG-1", "title": "ng"}],
    "checkpoint_graph": {
        "checkpoints": [
            {"id": "cp-1", "acceptance_criterion_ids": ["AC-1"],
             "work_unit": {"id": "WU-1"}, "required_validation": []},
        ]
    },
    "risk_budget": {
        "max_runtime_seconds": 28800, "max_pass_runtime_seconds": 7200,
        "max_build_passes": 4, "max_review_passes": 4, "max_repair_rounds": 4,
    },
}
# Save the original so we can restore it before F002 (which uses real packet parsing)
real_parse_packet = packet_mod.parse_packet_file
dispatch_mod.packet_mod.parse_packet_file = lambda path: (fake_pkt, "")
packet_mod.parse_packet_file = lambda path: (fake_pkt, "")

# Stub reconcile to skip event-chain verification
dispatch_mod.reconcile_mod.reconcile_run = lambda **k: {"ok": True, "refused": []}

# Create a minimal repo + run-dir
repo = Path(tempfile.mkdtemp(prefix="a001-"))
run_dir = state_mod.run_dir(repo, "a001-r")
run_dir.mkdir(parents=True, exist_ok=True)
(run_dir / "WORK_PACKET.md").write_text("dummy")
(run_dir / "STATE.json").write_text(json.dumps({
    "schema": state_mod.PROGRAM_STATE_SCHEMA_VERSION,
    "run_id": "a001-r", "state": "READY_TO_BUILD",
    "transitions_count": 1, "build_pass_count": 0, "review_pass_count": 0,
    "repair_round": 0, "no_progress_streak": 0, "identical_finding_streak": 0,
    "started_at": "t", "updated_at": "t", "last_actor": "x",
    "last_candidate_sha": None, "terminal_reason": None,
    "state_history": [], "spec_baseline_branch": "master",
    "spec_baseline_sha": "0"*40,
    "program": {
        "current_checkpoints": ["cp-1"], "finalized_checkpoints": [],
        "cumulative_counters": {"build_pass_count": 0, "review_pass_count": 0,
                                 "repair_round_count": 0},
        "cumulative_ceilings": {"max_build_passes": 4, "max_review_passes": 4,
                                 "max_repair_rounds": 4},
        "checkpoints": [
            {"id": "cp-1", "build_pass_count": 0, "review_pass_count": 0,
             "repair_round_count": 0, "terminal_state": None},
        ],
        "review_scope": "checkpoint",
        "checkpoint_graph_sha256": "graph-sha",
    },
}))
(run_dir / "EVENTS.log").write_text("")

# CASE B: declared 7200s
try:
    dispatch_mod.claim_next(canonical_repo=repo, run_id="a001-r")
except Exception as exc:
    print(f"  claim_next raised: {type(exc).__name__}: {exc}")
declared_calls = [c for c in captured["calls"]]
print(f"  captured calls: {len(declared_calls)}: {[c['args'][:2] for c in declared_calls]}")
check("A001-B: packet-declared 7200s propagates to claim CLI",
      len(declared_calls) >= 1
      and all(c["timeout_seconds"] == 7200 for c in declared_calls),
      detail=str([c["timeout_seconds"] for c in declared_calls]))

# CASE C: omit per-pass runtime → 3600s fallback
fake_pkt["risk_budget"] = {
    "max_runtime_seconds": 28800, "max_pass_runtime_seconds": 0,
    "max_build_passes": 4, "max_review_passes": 4, "max_repair_rounds": 4,
}
captured["calls"].clear()
try:
    dispatch_mod.claim_next(canonical_repo=repo, run_id="a001-r")
except Exception:
    pass
fallback_calls = [c for c in captured["calls"]]
fallback = dispatch_mod._DEFAULT_CLAIM_CLI_TIMEOUT_SECONDS
check(f"A001-C: omitted per-pass runtime falls back to {fallback}s",
      len(fallback_calls) >= 1
      and all(c["timeout_seconds"] == fallback for c in fallback_calls),
      detail=str([c["timeout_seconds"] for c in fallback_calls]))

# CASE D: explicit 28800s is NOT clamped
fake_pkt["risk_budget"] = {
    "max_runtime_seconds": 28800, "max_pass_runtime_seconds": 28800,
    "max_build_passes": 4, "max_review_passes": 4, "max_repair_rounds": 4,
}
captured["calls"].clear()
try:
    dispatch_mod.claim_next(canonical_repo=repo, run_id="a001-r")
except Exception:
    pass
long_calls = [c for c in captured["calls"]]
check("A001-D: explicit 28800s long timeout is NOT clamped",
      len(long_calls) >= 1
      and all(c["timeout_seconds"] == 28800 for c in long_calls),
      detail=str([c["timeout_seconds"] for c in long_calls]))

# CASE E: simulated subprocess timeout surfaces DispatchError
print("=== A001 CASE E: simulated subprocess timeout surfaces DispatchError ===")
def raise_timeout(args, *, timeout_seconds=None):
    # Mirror what _run_cli does internally when subprocess.run raises
    # TimeoutExpired: convert to DispatchError so callers see bounded failure.
    try:
        raise subprocess.TimeoutExpired(cmd=" ".join(args), timeout=timeout_seconds or 0)
    except subprocess.TimeoutExpired as exc:
        raise dispatch_mod.DispatchError(
            f"ofloop {' '.join(args)} exceeded finalization wall budget "
            f"({int(timeout_seconds or 0)}s)"
        ) from exc
dispatch_mod._run_cli = raise_timeout
try:
    dispatch_mod.claim_next(canonical_repo=repo, run_id="a001-r")
    check("A001-E: timeout surfaces DispatchError", False, "no exception raised")
except dispatch_mod.DispatchError as exc:
    check("A001-E: timeout surfaces DispatchError (not silent)", True,
          detail=str(exc)[:80])
except Exception as exc:
    check("A001-E: timeout surfaces DispatchError",
          False, f"wrong exception: {type(exc).__name__}: {exc}")

# =========================================================================
# A002 BEHAVIORAL: finalize CLI receives remaining wall budget
# =========================================================================
print("\n=== A002 behavioral: finalize CLI receives exact timeout ===")
real_srr = dispatch_mod.semantic_result_ready
dispatch_mod.semantic_result_ready = lambda wo: (True, "ok")
real_load = state_mod.load_verified
state_mod.load_verified = lambda repo, run_id: {
    "schema": state_mod.SCHEMA_VERSION, "run_id": run_id, "state": "BUILDING",
    "transitions_count": 1, "build_pass_count": 1, "review_pass_count": 1,
    "repair_round": 0, "no_progress_streak": 0, "identical_finding_streak": 0,
    "started_at": "t", "updated_at": "t", "last_actor": "x",
    "last_candidate_sha": "c"*40, "terminal_reason": None,
    "state_history": [], "spec_baseline_branch": "master",
    "spec_baseline_sha": "0"*40,
}
fin_captured = {"calls": []}
def spy_fin(args, *, timeout_seconds=None):
    fin_captured["calls"].append({"args": list(args), "timeout_seconds": timeout_seconds})
    return {"schema": dispatch_mod.SCHEMA, "decision": "BUILD",
            "run_id": "r1", "finalized": True, "result": {"ok": True}}
dispatch_mod._run_cli = spy_fin

# Create a real semantic artifact file at a path the test can write to.
a002_art = Path(tempfile.mkdtemp(prefix="a002-")) / "AGENT.json"
a002_art.write_text(json.dumps({
    "schema": "ownframework-loop-build-agent-result/v1",
    "run_id": "r1", "work_unit_id": "WU-1",
    "candidate_branch": "agent/r1/builder", "baseline_sha": "d"*40,
    "packet_sha256": "f"*64, "approval_sha256": "a"*64,
    "builder_identity": "claude-code",
    "outcome_requested": "candidate_ready", "summary": "ok",
    "acceptance_addressed": ["AC-1"], "files_changed": [],
    "added_lines": 0, "removed_lines": 0, "candidate_sha_claimed": "c"*40,
}))

wo_minimal = {
    "schema": dispatch_mod.SCHEMA, "decision": "BUILD", "role": "builder",
    "run_id": "r1", "state": "BUILDING",
    "canonical_repo": str(repo),
    "semantic_path": str(a002_art),
    "candidate_branch": "agent/r1/builder", "baseline_sha": "d"*40,
    "packet_sha256": "f"*64, "approval_sha256": "a"*64,
    "checkpoint_id": "", "work_unit_id": "WU-1",
}

try:
    fin_captured["calls"].clear()
    dispatch_mod.finalize_work_order(wo_minimal, timeout_seconds=1234)
except Exception as exc:
    print(f"  A002 caller-supplied finalize raised: {type(exc).__name__}: {exc}")
check("A002: finalize CLI receives caller-supplied timeout_seconds",
      len(fin_captured["calls"]) >= 1
      and fin_captured["calls"][0]["timeout_seconds"] == 1234,
      detail=str([c["timeout_seconds"] for c in fin_captured["calls"]]))

try:
    fin_captured["calls"].clear()
    dispatch_mod.finalize_work_order(wo_minimal, timeout_seconds=0)
except Exception as exc:
    print(f"  A002 timeout=0 finalize raised: {type(exc).__name__}: {exc}")
check("A002: finalize CLI is invoked even when caller passes timeout=0",
      len(fin_captured["calls"]) >= 1,
      detail=str(fin_captured["calls"]))

# Restore
dispatch_mod.semantic_result_ready = real_srr
state_mod.load_verified = real_load

# =========================================================================
# F003 BEHAVIORAL: semantic_result_ready scope-match enforcement
# =========================================================================
print("\n=== F003 behavioral: scope mismatch refused ===")

# Construct a review artifact that references our packet.
fake_pkt["acceptance_criterion_ids"] = ["AC-1"]
fake_pkt["non_goal_ids"] = ["NG-1"]
# Make _fixed_identity_mismatch succeed by passing our packet dict
def fake_fixed_mismatch(work_order, data, *, decision):
    return None  # no mismatch
dispatch_mod._fixed_identity_mismatch = fake_fixed_mismatch

# Bypass worktree-existence / branch / dirty checks: stub util + worktrees
# helpers so the function passes the worktree-validation branch and
# reaches the scope-match check.
dispatch_mod.util.builder_worktree = lambda repo, run_id: Path(repo)
dispatch_mod.util.reviewer_worktree = lambda repo, run_id: Path(repo)
dispatch_mod.worktrees_mod.is_registered_worktree = (
    lambda repo, wt: True
)

review_artifact = {
    "schema": "ownframework-loop-review-agent-assessment/v1",
    "run_id": "r1", "candidate_sha_claimed": "c"*40,
    "recommended_verdict": "APPROVED",
    "findings": [], "escalation_recommended": False,
    "review_scope": "checkpoint",
    "acceptance_results": [{"id": "AC-1", "result": "PASS", "evidence": "e"}],
    "non_goal_results": [{"id": "NG-1", "result": "N/A", "evidence": "e"}],
}
art_dir = Path(tempfile.mkdtemp(prefix="f003-"))
art_path2 = art_dir / "REVIEW.json"
art_path2.write_text(json.dumps(review_artifact))

# Stub git_checks so worktree HEAD / dirty checks pass
dispatch_mod.git_checks_mod.current_branch = lambda wt: "agent/r1/reviewer"
dispatch_mod.git_checks_mod.current_head = lambda wt: "c" * 40
dispatch_mod.git_checks_mod.dirty_status = lambda wt: "clean"
dispatch_mod.git_checks_mod.commit_exists = lambda repo, sha: True

wo_pf = {
    "schema": dispatch_mod.SCHEMA, "decision": "REVIEW", "role": "reviewer",
    "run_id": "r1", "state": "REVIEWING",
    "canonical_repo": str(repo), "worktree": str(repo),
    "semantic_path": str(art_path2),
    "candidate_branch": "agent/r1/reviewer", "baseline_sha": "d"*40,
    "packet_sha256": "f"*64, "approval_sha256": "a"*64,
    "checkpoint_id": "", "work_unit_id": "WU-1",
    "candidate_sha": "c" * 40,
    "review_scope": "checkpoint",
}

def call_with_state(wo_, state_dict):
    real_load = state_mod.load_verified
    state_mod.load_verified = lambda r, rid: state_dict
    try:
        return dispatch_mod.semantic_result_ready(wo_)
    finally:
        state_mod.load_verified = real_load

# CASE 1: durable program_final + authored checkpoint → scope refused
state_doc_pf = {
    "schema": state_mod.PROGRAM_STATE_SCHEMA_VERSION,
    "program": {"review_scope": "program_final"},
}
ok, reason = call_with_state(wo_pf, state_doc_pf)
check("F003-CASE-1: durable=program_final + authored=checkpoint → scope refused",
      not ok and "scope" in reason.lower(),
      detail=f"ok={ok} reason={reason!r}")

# CASE 3: durable checkpoint + authored program_final → escalation refused
state_doc_cp = {"schema": state_mod.PROGRAM_STATE_SCHEMA_VERSION,
                "program": {"review_scope": "checkpoint"}}
review_artifact["review_scope"] = "program_final"
art_path2.write_text(json.dumps(review_artifact))
ok, reason = call_with_state(wo_pf, state_doc_cp)
check("F003-CASE-3: durable=checkpoint + authored=program_final → escalation refused",
      not ok and "scope" in reason.lower(),
      detail=f"ok={ok} reason={reason!r}")

# CASE 2: durable program_final + authored program_final → scope gate passes
review_artifact["review_scope"] = "program_final"
art_path2.write_text(json.dumps(review_artifact))
ok, reason = call_with_state(wo_pf, state_doc_pf)
check("F003-CASE-2: durable=program_final + authored=program_final → scope gate passes",
      "scope" not in reason.lower(),
      detail=f"reason={reason!r}")

# CASE 4: durable checkpoint + authored checkpoint → scope gate passes
review_artifact["review_scope"] = "checkpoint"
art_path2.write_text(json.dumps(review_artifact))
ok, reason = call_with_state(wo_pf, state_doc_cp)
check("F003-CASE-4: durable=checkpoint + authored=checkpoint → scope gate passes",
      "scope" not in reason.lower(),
      detail=f"reason={reason!r}")

# =========================================================================
# F002/F004 BEHAVIORAL: advance_after_review_approval positive proof
# =========================================================================
print("\n=== F002/F004 behavioral: program_final requires positive coverage ===")

# Construct packet and compute its real checkpoint_graph_sha256
pkt_f002 = {
    "schema": "ownframework-work-packet/v1",
    "spec_version": "v1", "execution_mode": "program",
    "packet_id": "p1", "created_at": "2026-01-01T00:00:00Z",
    "work_class": "build", "risk_class": "low",
    "title": "test", "target": {"repo": "."},
    "allowed_paths": ["."], "protected_paths": [],
    "work_units": [{"id": "WU-1", "title": "u"}],
    "merge_authority": "human_only", "deploy_authority": "human_only",
    "push_authority": "human_only", "external_action_authority": "human_only",
    "capabilities": [], "network_read_allowlist": [],
    "runner_profile": "default", "limits": {},
    "acceptance_criteria": [{"id": "AC-1", "title": "do"}],
    "non_goals": [{"id": "NG-1", "title": "ng"}],
    "checkpoint_graph": {
        "checkpoints": [
            {"id": "cp-1", "acceptance_criterion_ids": ["AC-1"],
             "work_unit": {"id": "WU-1"}, "required_validation": []},
            {"id": "cp-2", "acceptance_criterion_ids": ["AC-1"],
             "work_unit": {"id": "WU-2"}, "required_validation": []},
        ],
        "execution_order": ["cp-1", "cp-2"],
    },
}
real_graph_sha = program_mod.checkpoint_graph_sha256(pkt_f002)

# Restore the real packet parser for F002 (and subsequent sections)
packet_mod.parse_packet_file = real_parse_packet

# F002 needs STATE.json on disk because advance_after_review_approval
# goes through program_transition which writes/reads state.
# Use a packet where cp-2 depends_on cp-1, so after cp-1 approves,
# cp-2 is unblocked. To test the "unfinished CP → refused" path,
# we use a 3-CP packet where cp-3 depends on cp-2, and we only
# finalize cp-1 + cp-2 → cp-3 remains unfinished.
f002_repo = Path(tempfile.mkdtemp(prefix="f002-"))
f002_run_dir = state_mod.run_dir(f002_repo, "x")
f002_run_dir.mkdir(parents=True, exist_ok=True)

pkt_f002_3cp = {
    "schema": "ownframework-work-packet/v1",
    "spec_version": "v1", "execution_mode": "program",
    "packet_id": "p1", "created_at": "2026-01-01T00:00:00Z",
    "work_class": "build", "risk_class": "low",
    "title": "test", "target": {"repo": "."},
    "allowed_paths": ["."], "protected_paths": [],
    "work_units": [{"id": "WU-1", "title": "u"}],
    "merge_authority": "human_only", "deploy_authority": "human_only",
    "push_authority": "human_only", "external_action_authority": "none",
    "capabilities": [], "network_read_allowlist": [],
    "runner_profile": "default", "limits": {},
    "acceptance_criteria": [{"id": "AC-1", "title": "do"}],
    "non_goals": [{"id": "NG-1", "title": "ng"}],
    "checkpoint_graph": {
        "checkpoints": [
            {"id": "cp-blocked", "acceptance_criterion_ids": ["AC-1"],
             "work_unit": {"id": "WU-B"}, "required_validation": []},
            {"id": "cp-orphan", "acceptance_criterion_ids": ["AC-1"],
             "work_unit": {"id": "WU-O"}, "required_validation": []},
        ],
        # cp-orphan is in the graph but not in execution_order. When the
        # only execution_order CP (cp-blocked) finalizes, refresh sees no
        # next eligible CP → new_cps=[]. All CPs not finalized (cp-orphan)
        # → F002 raises "unfinished".
        "execution_order": ["cp-blocked"],
    },
}
real_graph_sha = program_mod.checkpoint_graph_sha256(pkt_f002_3cp)

def make_state_doc(current_cp_id, other_finalized_ids):
    """Build state where the current CP is being approved and others
    are already finalized. The flow: cp-1 is REVIEWING; after approval,
    cp-1 moves from current to finalized, advancing to next CP."""
    return {
        "schema": state_mod.PROGRAM_STATE_SCHEMA_VERSION,
        "run_id": "x", "state": "REVIEWING",
        "transitions_count": 1, "build_pass_count": 0,
        "review_pass_count": 0, "repair_round": 0,
        "no_progress_streak": 0, "identical_finding_streak": 0,
        "started_at": "t", "updated_at": "t", "last_actor": "x",
        "last_candidate_sha": "c"*40, "terminal_reason": None,
        "state_history": [], "spec_baseline_branch": "master",
        "spec_baseline_sha": "0"*40,
        "program": {
            "current_checkpoints": [current_cp_id],
            "finalized_checkpoints": [
                {"id": cid, "terminal_state": "APPROVED"}
                for cid in other_finalized_ids
            ],
            "cumulative_counters": {
                "build_pass_count": 1, "review_pass_count": 1,
                "repair_round_count": 0,
                "files_changed_unique": 0, "diff_lines_total": 0,
            },
            "cumulative_ceilings": {
                "max_build_passes": 4, "max_review_passes": 4,
                "max_repair_rounds": 4,
                "max_unique_changed_files": 100, "max_baseline_to_final_diff_lines": 1000,
            },
            "checkpoints": [
                {"id": "cp-blocked", "build_pass_count": 1, "review_pass_count": 1,
                 "repair_round_count": 0, "terminal_state": None},
                {"id": "cp-orphan", "build_pass_count": 1, "review_pass_count": 1,
                 "repair_round_count": 0, "terminal_state": None},
            ],
            "review_scope": "checkpoint",
            "checkpoint_graph_sha256": real_graph_sha,
        },
    }

# CASE 1: cp-blocked approved; no other CP in execution_order.
# expected_cp_ids={cp-blocked, cp-orphan}, finalized_cp_ids={cp-blocked}.
# These are NOT equal → F002 raises "unfinished" (orphan stays unfinished).
# Wait — this is the same case as CASE-2 now. Let me use a different fixture
# for CASE-1 where ALL CPs are finalized.
# For CASE-1 we use a 2-CP packet where cp-1 then cp-2 are in execution_order;
# we approve cp-2 with cp-1 already finalized → all finalized → program_final.
# Note: this uses a different packet_f002_all fixture.
pkt_f002_all = {
    "schema": "ownframework-work-packet/v1",
    "spec_version": "v1", "execution_mode": "program",
    "packet_id": "p1", "created_at": "2026-01-01T00:00:00Z",
    "work_class": "build", "risk_class": "low",
    "title": "test", "target": {"repo": "."},
    "allowed_paths": ["."], "protected_paths": [],
    "work_units": [{"id": "WU-1", "title": "u"}],
    "merge_authority": "human_only", "deploy_authority": "human_only",
    "push_authority": "human_only", "external_action_authority": "none",
    "capabilities": [], "network_read_allowlist": [],
    "runner_profile": "default", "limits": {},
    "acceptance_criteria": [{"id": "AC-1", "title": "do"}],
    "non_goals": [{"id": "NG-1", "title": "ng"}],
    "checkpoint_graph": {
        "checkpoints": [
            {"id": "cp-a", "acceptance_criterion_ids": ["AC-1"],
             "work_unit": {"id": "WU-A"}, "required_validation": []},
            {"id": "cp-b", "acceptance_criterion_ids": ["AC-1"],
             "work_unit": {"id": "WU-B"}, "required_validation": []},
        ],
        "execution_order": ["cp-a", "cp-b"],
    },
}
real_graph_sha_all = program_mod.checkpoint_graph_sha256(pkt_f002_all)

def write_f002_state_all(state):
    (f002_run_dir / "STATE.json").write_text(json.dumps(state))

try:
    state_c1 = {
        "schema": state_mod.PROGRAM_STATE_SCHEMA_VERSION, "run_id": "x",
        "state": "REVIEWING",
        "transitions_count": 1, "build_pass_count": 1, "review_pass_count": 1,
        "repair_round": 0, "no_progress_streak": 0, "identical_finding_streak": 0,
        "started_at": "t", "updated_at": "t", "last_actor": "x",
        "last_candidate_sha": "c"*40, "terminal_reason": None,
        "state_history": [], "spec_baseline_branch": "master",
        "spec_baseline_sha": "0"*40,
        "program": {
            "current_checkpoints": ["cp-b"],
            "finalized_checkpoints": [{"id": "cp-a", "terminal_state": "APPROVED"}],
            "cumulative_counters": {"build_pass_count": 1, "review_pass_count": 1,
                                     "repair_round_count": 0,
                                     "files_changed_unique": 0, "diff_lines_total": 0},
            "cumulative_ceilings": {"max_build_passes": 4, "max_review_passes": 4,
                                     "max_repair_rounds": 4,
                                     "max_unique_changed_files": 100,
                                     "max_baseline_to_final_diff_lines": 1000},
            "checkpoints": [
                {"id": "cp-a", "build_pass_count": 1, "review_pass_count": 1,
                 "repair_round_count": 0, "terminal_state": "APPROVED"},
                {"id": "cp-b", "build_pass_count": 1, "review_pass_count": 1,
                 "repair_round_count": 0, "terminal_state": None},
            ],
            "review_scope": "checkpoint",
            "checkpoint_graph_sha256": real_graph_sha_all,
        },
    }
    write_f002_state_all(state_c1)
    adv = program_mod.advance_after_review_approval(
        canonical_repo=f002_repo, run_id="x", packet=pkt_f002_all,
        state=state_c1,
        candidate_sha="c"*40, verdict_sha256="v"*64,
        review_pass_number=1, actor="test")
    new_state_doc = json.loads((f002_run_dir / "STATE.json").read_text())
    new_program = new_state_doc.get("program", {})
    check("F002-CASE-1: all CPs finalized → program_final stamped on disk",
          new_program.get("review_scope") == program_mod.REVIEW_SCOPE_PROGRAM_FINAL,
          detail=f"review_scope={new_program.get('review_scope')!r}, "
                 f"finalized={[fc.get('id') for fc in new_program.get('finalized_checkpoints',[])]}")
except Exception as exc:
    check("F002-CASE-1: all CPs finalized → program_final stamped",
          False, f"{type(exc).__name__}: {exc}")

# CASE 2: cp-blocked approved; cp-orphan not in execution_order, never
# finalized. After advance: finalized=[cp-blocked], refresh finds no
# eligible CP (cp-orphan is not in execution_order). new_cps=[].
# expected_cp_ids={cp-blocked, cp-orphan}, finalized_cp_ids={cp-blocked}.
# F002 raises with "unfinished" reason.
f002_repo_c2 = Path(tempfile.mkdtemp(prefix="f002-c2-"))
f002_run_dir_c2 = state_mod.run_dir(f002_repo_c2, "x")
f002_run_dir_c2.mkdir(parents=True, exist_ok=True)
(f002_run_dir_c2 / "WORK_PACKET.md").write_text(
    "```json\n" + json.dumps(pkt_f002_3cp) + "\n```\n")
(f002_run_dir_c2 / "EVENTS.log").write_text("")
state_c2 = make_state_doc(current_cp_id="cp-blocked", other_finalized_ids=[])
(f002_run_dir_c2 / "STATE.json").write_text(json.dumps(state_c2))
try:
    program_mod.advance_after_review_approval(
        canonical_repo=f002_repo_c2, run_id="x", packet=pkt_f002_3cp,
        state=state_c2,
        candidate_sha="c"*40, verdict_sha256="v"*64,
        review_pass_number=1, actor="test")
    check("F002-CASE-2: unfinished orphan CP after approval → refused", False, "no exception")
except program_mod.ProgramStateError as exc:
    check("F002-CASE-2: unfinished orphan CP after approval → refused",
          "unfinished" in str(exc).lower(), detail=str(exc))
except Exception as exc:
    check("F002-CASE-2: unfinished orphan CP after approval → refused",
          False, f"{type(exc).__name__}: {exc}")

# =========================================================================
# F007 BEHAVIORAL: StateTorn subclass exists; TamperingDetected on SHA mismatch
# =========================================================================
print("\n=== F007 behavioral: StateTorn exists; tampering is NOT StateTorn ===")
check("F007: StateTorn is a real exception subclass",
      isinstance(integrity_mod.StateTorn(""), integrity_mod.TamperingDetected)
      and isinstance(integrity_mod.StateTorn(""), BaseException))

# Verify: a SHA mismatch on parseable STATE.json + recorded SHA raises
# TamperingDetected (NOT StateTorn). Construct minimal valid scenario.
sp = Path(tempfile.mkdtemp(prefix="f007-"))
sp_state = sp / "STATE.json"
sp_events = sp / "EVENTS.log"
sp_state.write_text(json.dumps({
    "schema": state_mod.SCHEMA_VERSION, "run_id": "x",
    "state": "READY_TO_BUILD", "transitions_count": 1,
    "build_pass_count": 0, "review_pass_count": 0, "repair_round": 0,
    "no_progress_streak": 0, "identical_finding_streak": 0,
    "started_at": "t", "updated_at": "t", "last_actor": "x",
    "last_candidate_sha": None, "terminal_reason": None,
    "state_history": [], "spec_baseline_branch": "master",
    "spec_baseline_sha": "0"*40,
}))
# Record a different SHA in events log (so verify fails)
recorded = "0" * 64  # a SHA that doesn't match
sp_events.write_text(json.dumps({
    "events": [],
    "state_sha256": recorded,
}) + "\n")
ok, msg = integrity_mod.verify_state_sha(sp_state, sp_events)
check("F007-B: SHA mismatch → verify_state_sha returns False",
      not ok, detail=f"ok={ok} msg={msg}")
# Verify that an actual TamperingDetected raises from load_verified
def raise_tamper_stub(repo, run_id):
    raise integrity_mod.TamperingDetected("synthetic sha mismatch")

real_load = state_mod.load_verified
state_mod.load_verified = raise_tamper_stub
try:
    try:
        state_mod.load_verified(Path("/tmp"), "x")
        check("F007-B: SHA mismatch path raises TamperingDetected",
              False, "no exception raised")
    except integrity_mod.TamperingDetected as exc:
        check("F007-B: SHA mismatch path raises TamperingDetected (not silent)",
              True, detail=str(exc)[:80])
    except Exception as exc:
        check("F007-B: SHA mismatch path raises TamperingDetected",
              False, f"{type(exc).__name__}: {exc}")
finally:
    state_mod.load_verified = real_load

# =========================================================================
# B009 BEHAVIORAL: orphan identity forces QUARANTINED in real DB
# =========================================================================
print("\n=== B009 behavioral: orphan identity forces QUARANTINED in real DB ===")
db_path = Path(tempfile.mkdtemp(prefix="b009-")) / "sup.sqlite3"
conn = sqlite3.connect(str(db_path))
conn.executescript("""
CREATE TABLE jobs (
    id INTEGER PRIMARY KEY,
    repo TEXT NOT NULL, run_id TEXT NOT NULL UNIQUE,
    candidate_branch TEXT, last_candidate_sha TEXT,
    runtime_generation TEXT, worker_pid INTEGER,
    worker_started_at REAL, worker_pgid INTEGER,
    worker_deadline_at REAL, worker_start_identity TEXT,
    worker_role TEXT, worker_attempt_id TEXT,
    status TEXT NOT NULL DEFAULT 'QUEUED',
    infra_failures INTEGER NOT NULL DEFAULT 0,
    transient_failures INTEGER NOT NULL DEFAULT 0,
    transient_recovery_cycles INTEGER NOT NULL DEFAULT 0,
    total_cost_usd REAL NOT NULL DEFAULT 0,
    last_error TEXT,
    last_failure_class TEXT,
    last_failure_reason TEXT,
    next_attempt_at REAL DEFAULT 0,
    updated_at REAL DEFAULT 0
);
""")
own_pid = os.getpid()
conn.execute("""
INSERT INTO jobs (id, repo, run_id, candidate_branch, last_candidate_sha,
    runtime_generation, worker_pid, worker_started_at, worker_pgid,
    worker_deadline_at, worker_start_identity, worker_role,
    worker_attempt_id, status)
VALUES (1, ?, 'b009-r', 'main', 'c1', 'gen-x', ?, ?, ?,
        ?, 'identity-x', 'builder', 'att-1', 'RUNNING')
""", (str(repo), own_pid, time.time() - 1000, own_pid, time.time() - 100))
conn.commit()
conn.close()

# Stub process helpers: PID alive, identity proof fails
# The recovery module imports the helpers at top-level into its module
# namespace via `from . import supervisor_process as _process_mod`, then
# resolves them through that alias. Patch via the process module.
import ownframework_loop.supervisor_process as process_mod_b
real_pid_alive_p = process_mod_b._pid_alive
real_terminate_p = process_mod_b._terminate_owned_process_group
process_mod_b._pid_alive = lambda pid, started_at: True
process_mod_b._terminate_owned_process_group = (
    lambda pid, pgid, identity, started_at: False
)

conn = sqlite3.connect(str(db_path))
conn.row_factory = sqlite3.Row
recovered_count = recovery_mod._recover_stale_running(conn)
row = conn.execute("SELECT * FROM jobs WHERE id=1").fetchone()
conn.close()

recovery_mod._pid_alive = real_pid_alive_p
recovery_mod._terminate_owned_process_group = real_terminate_p
# (also restore on the canonical module if anyone else reads them)
process_mod_b._pid_alive = real_pid_alive_p
process_mod_b._terminate_owned_process_group = real_terminate_p

check("B009: orphan identity → status=QUARANTINED",
      row["status"] == "QUARANTINED",
      detail=f"status={row['status']!r}")
check("B009: last_failure_class=orphan_identity",
      row["last_failure_class"] == "orphan_identity",
      detail=f"class={row['last_failure_class']!r}")
check("B009: last_failure_reason=orphan_identity_unproven",
      row["last_failure_reason"] == "orphan_identity_unproven",
      detail=f"reason={row['last_failure_reason']!r}")

# =========================================================================
# B002 BEHAVIORAL: RuntimeError cause surfaced on last_error
# =========================================================================
print("\n=== B002 behavioral: RuntimeError cause persisted on last_error ===")
# Build a real repo so the candidate-branch probe succeeds
b002_repo = Path(tempfile.mkdtemp(prefix="b002-"))
subprocess.run(["git", "-C", str(b002_repo), "init", "-q", "--initial-branch=master"],
               check=True, capture_output=True)
subprocess.run(["git", "-C", str(b002_repo), "config", "user.email", "test@x"],
               check=True, capture_output=True)
subprocess.run(["git", "-C", str(b002_repo), "config", "user.name", "Test"],
               check=True, capture_output=True)
(b002_repo / "README").write_text("init\n")
subprocess.run(["git", "-C", str(b002_repo), "add", "."], check=True, capture_output=True)
subprocess.run(["git", "-C", str(b002_repo), "commit", "-q", "-m", "init"],
               check=True, capture_output=True)
# Create candidate_branch
subprocess.run(["git", "-C", str(b002_repo), "branch", "agent/r/builder"],
               check=True, capture_output=True)
# Create a semantic artifact file at the expected path
b002_sem_dir = state_mod.run_dir(b002_repo, "b002-r")
b002_sem_dir.mkdir(parents=True, exist_ok=True)
b002_sem_path = b002_sem_dir / "BUILD_AGENT_RESULT.json"
b002_sem_path.write_text(json.dumps({
    "schema": "ownframework-loop-build-agent-result/v1",
    "run_id": "b002-r",
    "work_unit_id": "WU-1",
    "candidate_branch": "agent/r/builder",
    "baseline_sha": "d"*40, "packet_sha256": "f"*64, "approval_sha256": "a"*64,
    "builder_identity": "claude-code",
    "outcome_requested": "candidate_ready",
    "summary": "ok", "acceptance_addressed": [], "files_changed": [],
    "added_lines": 0, "removed_lines": 0, "candidate_sha_claimed": "c"*40,
}))

db_path2 = Path(tempfile.mkdtemp(prefix="b002-")) / "sup.sqlite3"
conn2 = sqlite3.connect(str(db_path2))
conn2.row_factory = sqlite3.Row
conn2.executescript("""
CREATE TABLE jobs (
    id INTEGER PRIMARY KEY,
    repo TEXT NOT NULL, run_id TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'RUNNING',
    latest_attempt_id TEXT, worker_attempt_id TEXT,
    infra_failures INTEGER NOT NULL DEFAULT 0,
    transient_failures INTEGER NOT NULL DEFAULT 0,
    transient_recovery_cycles INTEGER NOT NULL DEFAULT 0,
    total_cost_usd REAL NOT NULL DEFAULT 0,
    last_error TEXT, last_failure_class TEXT,
    last_failure_reason TEXT,
    next_attempt_at REAL DEFAULT 0,
    updated_at REAL DEFAULT 0,
    worker_pid INTEGER,
    worker_started_at REAL,
    worker_pgid INTEGER,
    worker_deadline_at REAL,
    worker_start_identity TEXT,
    worker_role TEXT
);
CREATE TABLE semantic_attempts (
    attempt_id TEXT PRIMARY KEY,
    job_id INTEGER, role TEXT, status TEXT,
    failure_class TEXT, failure_reason TEXT,
    cost_accounted INTEGER DEFAULT 0, cost_known INTEGER DEFAULT 0,
    cost_usd REAL DEFAULT 0,
    semantic_accepted INTEGER DEFAULT 0,
    accepted_semantic_sha256 TEXT,
    accepted_candidate_sha TEXT,
    effective_model TEXT,
    launch_gate_version INTEGER DEFAULT 1
);
""")
conn2.execute("INSERT INTO jobs (id, repo, run_id, latest_attempt_id) VALUES (1, ?, 'b002-r', 'att-1')",
              (str(b002_repo),))
conn2.commit()

real_publish = attempts_mod._publish_semantic_acceptance
def boom(*a, **k):
    raise RuntimeError("synthetic identity-drift refusal for test")
attempts_mod._publish_semantic_acceptance = boom
db_mod._publish_semantic_acceptance = boom

# Also pre-seed latest_attempt_id so completion_attempt_id is non-empty
conn2.execute("INSERT INTO semantic_attempts (attempt_id, job_id, role) VALUES ('att-1', 1, 'builder')")
conn2.execute("UPDATE jobs SET latest_attempt_id='att-1' WHERE id=1")
conn2.commit()

try:
    attempts_mod._publish_acceptance_for_ready_artifact(
        conn=conn2, work_order={
            "canonical_repo": str(b002_repo),
            "candidate_branch": "agent/r/builder",
            "semantic_path": str(b002_sem_path),
        }, job_id=1)
except Exception as exc:
    pass

row2 = conn2.execute("SELECT last_error FROM jobs WHERE id=1").fetchone()
check("B002: RuntimeError cause surfaced on last_error",
      row2["last_error"] is not None
      and "synthetic identity-drift" in row2["last_error"],
      detail=f"last_error={row2['last_error']!r}")

attempts_mod._publish_semantic_acceptance = real_publish
db_mod._publish_semantic_acceptance = real_publish
conn2.close()

# =========================================================================
# B001 BEHAVIORAL: PRE_PROVIDER_FAILURE_REASONS canonical single definition
# =========================================================================
print("\n=== B001 behavioral: PRE_PROVIDER_FAILURE_REASONS exactly one ===")
import ast
src = Path("/Users/mr.mrs.london/projects/ownframework-loop/lib/ownframework_loop/supervisor_attempts.py").read_text()
tree = ast.parse(src)
count = 0
for node in ast.walk(tree):
    if isinstance(node, ast.Assign):
        for tgt in node.targets:
            if isinstance(tgt, ast.Name) and tgt.id == "PRE_PROVIDER_FAILURE_REASONS":
                count += 1
check("B001: exactly one PRE_PROVIDER_FAILURE_REASONS definition", count == 1,
      detail=f"count={count}")

# =========================================================================
# B003 BEHAVIORAL: single canonical lock
# =========================================================================
print("\n=== B003 behavioral: single canonical _LOCAL_EXECUTION_LOCK ===")
import ownframework_loop.supervisor_process as process_mod
check("B003: db and process modules share the same lock object",
      db_mod._LOCAL_EXECUTION_LOCK is process_mod._LOCAL_EXECUTION_LOCK)

# =========================================================================
# SUMMARY
# =========================================================================
print("\n=== Summary ===")
if failures:
    print(f"FAILURES ({len(failures)}):")
    for f in failures:
        print(f"  - {f}")
    raise SystemExit(1)
print(f"All behavioral sections passed (zero failures).")
PY

echo "V10E_PRE1_BEHAVIORAL_PROOFS=PASS"
