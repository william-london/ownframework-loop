"""Deterministic build finalizer.

The builder agent returns a small non-authoritative semantic result
(see ``BUILD_AGENT_RESULT.json``). The finalizer is the only entity that
writes the authoritative ``BUILD_RECEIPT.json`` and derives the next
state.

The finalizer independently:

  1. Validates APPROVAL.json against current packet bytes.
  2. Validates canonical repo and builder worktree identity.
  3. Validates the exact candidate branch.
  4. Resolves baseline SHA from approval.
  5. Resolves candidate HEAD from Git.
  6. Verifies the candidate commit exists in this repo.
  7. Verifies the candidate descends from baseline.
  8. Verifies candidate branch contains the candidate SHA.
  9. Verifies canonical baseline branch was not modified.
 10. Computes changed paths and added/removed lines from Git.
 11. Applies the approved work-class-aware budget.
 12. Verifies allowed paths.
 13. Verifies protected/elevated paths against the packet.
 14. Scans the candidate diff and changed files for hard secret patterns.
 15. Executes the packet's required-validation commands itself.
 16. Captures exact exit codes and durations.
 17. Detects no progress and repeated candidate SHA.
 18. Enforces pass and repair limits.
 19. Generates BUILD_RECEIPT.json itself.
 20. Writes the receipt atomically.
 21. Appends the event.
 22. Derives the next state.

The model cannot influence the finalizer's verdict on any of the
checks above. Any model-supplied ``next_state`` field is ignored.
"""

from __future__ import annotations

import json
import re
import time
from pathlib import Path
from typing import Any

from . import (
    approval, git_checks, guards, integrity, limits as limits_mod,
    packet as packet_mod, receipts, secrets_v2, state as state_mod,
    transitions, util, worktrees, build_agent as build_agent_mod,
)


SCHEMA_AGENT_RESULT = "ownframework-loop-build-agent-result/v1"

# Hard schema for the semantic agent result.
AGENT_RESULT_REQUIRED = (
    "schema", "run_id", "work_unit_id", "outcome_requested",
)
AGENT_RESULT_ALLOWED_OUTCOMES = {"candidate_ready", "blocked", "stopped"}


def _read_json(path: Path, default: Any = None) -> Any:
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return default


def _run_validation_command(
    cwd: Path,
    command: str,
    *,
    timeout_seconds: int,
    canonical_repo: Path,
    run_id: str,
) -> dict[str, Any]:
    """Run a validation command, capture exit code, stdout, stderr, duration.

    Read output via bounded subprocess so candidate diffs containing
    embedded secrets never flow into the Python source as a string.

    Uses hermetic_subprocess_env so Python bytecode, pytest cache, and
    other ephemeral runtime state land in the supervisor-owned runtime-cache
    directory rather than the exact-SHA candidate worktree. This keeps
    the dirty-worktree check honest.
    """
    import subprocess
    from . import runtime_env
    start = time.monotonic()
    try:
        proc = subprocess.run(
            ["/bin/sh", "-c", command],
            cwd=str(cwd),
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
            check=False,
            env=runtime_env.hermetic_subprocess_env(canonical_repo, run_id, "validation"),
        )
        duration = time.monotonic() - start
        # Cap captured output to 64 KiB to prevent unbounded memory.
        max_capture = 64 * 1024
        stdout = (proc.stdout or "")[:max_capture]
        stderr = (proc.stderr or "")[:max_capture]
        truncated = (len(proc.stdout or "") > max_capture) or (len(proc.stderr or "") > max_capture)
        return {
            "exit_code": int(proc.returncode),
            "duration_seconds": float(duration),
            "stdout": stdout,
            "stderr": stderr,
            "truncated": truncated,
            "timed_out": False,
        }
    except subprocess.TimeoutExpired:
        duration = time.monotonic() - start
        return {
            "exit_code": 124,
            "duration_seconds": float(duration),
            "stdout": "",
            "stderr": "command timed out",
            "truncated": False,
            "timed_out": True,
        }
    except Exception as e:
        raise RuntimeError(
            f"validation command could not execute: {type(e).__name__}"
        ) from e


def _changed_paths_between(worktree: Path, baseline_sha: str, candidate_sha: str) -> list[str]:
    """Return the list of changed paths between two SHAs.

    FAIL-CLOSED: any git-diff failure raises RuntimeError. The historical
    []-on-failure pattern was fail-open (zero changed paths = no scope
    violations = no protected-path hits = no secret findings). Authoritative
    callers now refuse an unverifiable diff rather than accept empty
    evidence.
    """
    r = util.run_subprocess(
        ["git", "-C", str(worktree), "diff", "--name-only", baseline_sha, candidate_sha],
        timeout=30,
    )
    if r.returncode != 0:
        raise RuntimeError(
            f"git diff --name-only failed rc={r.returncode} for "
            f"{baseline_sha[:12]}..{candidate_sha[:12]}: {r.stderr.strip()}"
        )
    return [line.strip() for line in r.stdout.splitlines() if line.strip()]


def _diff_stats(worktree: Path, baseline_sha: str, candidate_sha: str) -> dict[str, int]:
    """Compute files_changed, added_lines, removed_lines."""
    return receipts.compute_diff_stats(worktree, baseline_sha, candidate_sha)


def _candidate_branch_contains(canonical_repo: Path, candidate_branch: str, candidate_sha: str) -> bool:
    r = util.run_subprocess(
        ["git", "-C", str(canonical_repo), "merge-base", "--is-ancestor", candidate_sha, candidate_branch],
        timeout=10,
    )
    return r.returncode == 0


def _ancestor_of(canonical_repo: Path, candidate_sha: str, baseline_sha: str) -> bool:
    """Return True iff candidate_sha is a descendant of baseline_sha."""
    r = util.run_subprocess(
        ["git", "-C", str(canonical_repo), "merge-base", "--is-ancestor", baseline_sha, candidate_sha],
        timeout=10,
    )
    return r.returncode == 0


def _verify_canonical_branch_unchanged(canonical_repo: Path, baseline_sha: str, expected_branch: str) -> tuple[bool, str]:
    """Refuse if the canonical branch's HEAD has drifted from the approved baseline.

    The builder writes commits inside its own worktree; the canonical
    branch (master / main / etc.) must NOT be advanced by the build.
    """
    if not git_checks.is_git_repo(canonical_repo):
        return False, "canonical repo is not a git repository"
    branch = git_checks.current_branch(canonical_repo)
    if branch != expected_branch:
        return False, f"canonical branch={branch!r}, expected {expected_branch!r}"
    head = git_checks.current_head(canonical_repo)
    if head is None:
        return False, "canonical repo has no HEAD"
    if head != baseline_sha:
        return False, f"canonical HEAD {head} drifted from approved baseline {baseline_sha}"
    return True, "ok"


def _classify_path_against_packet(packet: dict[str, Any], path: str) -> str:
    """Return one of 'allowed', 'protected', 'sensitive', 'elevated', 'out_of_scope'."""
    if packet_mod.is_protected_path(packet, path):
        return "protected"
    if packet_mod.is_allowed_path(packet, path):
        return "allowed"
    elevated = packet.get("elevated_allowed_paths") or []
    if any(_path_in_list(path, p) for p in elevated):
        return "elevated"
    sensitive = packet.get("sensitive_paths") or []
    if any(_path_in_list(path, p) for p in sensitive):
        return "sensitive"
    return "out_of_scope"


def _path_in_list(path: str, prefix: str) -> bool:
    # Keep elevated/sensitive matching identical to allowed/protected
    # packet scope semantics, including the compatibility ``dir/**`` suffix.
    return packet_mod.path_matches_scope_entry(path, prefix)


def _build_agent_result_schema_ok(result: dict[str, Any]) -> tuple[bool, list[str]]:
    errors: list[str] = []
    for f in AGENT_RESULT_REQUIRED:
        if f not in result:
            errors.append(f"missing required field: {f}")
    if result.get("schema") != SCHEMA_AGENT_RESULT:
        errors.append(f"schema must be {SCHEMA_AGENT_RESULT}")
    if result.get("outcome_requested") not in AGENT_RESULT_ALLOWED_OUTCOMES:
        errors.append(f"outcome_requested must be one of {sorted(AGENT_RESULT_ALLOWED_OUTCOMES)}")
    return (not errors), errors


def finalize_build(
    *,
    canonical_repo: Path,
    run_id: str,
    agent_result_path: Path | None,
    actor: str = "of-builder",
) -> dict[str, Any]:
    """Run the deterministic build finalizer.

    Returns the authoritative receipt it constructed. Caller may emit it
    via ``ofloop build finalize`` or write it directly via the shared
    ``receipts.write_receipt`` helper.
    """
    canonical_repo = Path(canonical_repo).resolve(strict=False)
    run_d = state_mod.run_dir(canonical_repo, run_id)
    packet_path = run_d / "WORK_PACKET.md"
    if not packet_path.exists():
        raise RuntimeError("WORK_PACKET.md missing")

    # 1. Validate approval binding.
    meta, _ = packet_mod.parse_packet_file(packet_path)
    errors = packet_mod.validate_packet_for_approval(meta)
    if errors:
        raise RuntimeError("packet invalid: " + "; ".join(errors))
    approval_doc = approval.load_approval(canonical_repo, run_id)
    ok, msg = approval.validate_approval_binding(
        canonical_repo=canonical_repo,
        run_id=run_id,
        approval=approval_doc,
        packet=meta,
        packet_path=packet_path,
    )
    if not ok:
        raise RuntimeError(f"approval invalid: {msg}")
    baseline_sha = approval_doc["baseline_sha"]
    baseline_branch = approval_doc["baseline_branch"]

    # 2. Validate state.
    state = state_mod.load_verified(canonical_repo, run_id)
    if state.get("state") != "BUILDING":
        raise RuntimeError(
            f"build finalize requires BUILDING state, got {state.get('state')!r}"
        )

    # 3. Validate builder worktree.
    builder_wt = util.builder_worktree(canonical_repo, run_id)
    if not builder_wt.exists():
        raise RuntimeError("builder worktree missing")

    # 4. Read and validate semantic agent result.
    if agent_result_path is None:
        raise RuntimeError(
            "semantic BUILD_AGENT_RESULT.json is required; deterministic "
            "finalization cannot substitute for a semantic builder pass"
        )
    agent_result_path = Path(agent_result_path).resolve(strict=False)
    if state_mod.is_program_state(state):
        expected_agent_path = build_agent_mod.agent_result_path(
            canonical_repo, run_id
        ).resolve(strict=False)
        if agent_result_path != expected_agent_path:
            raise RuntimeError(
                f"PROGRAM build semantic result path {agent_result_path} != "
                f"current claimed pass path {expected_agent_path}"
            )
    agent_result = _read_json(agent_result_path, default={}) or {}
    if not agent_result:
        raise RuntimeError("semantic builder result missing or empty")
    schema_ok, schema_errs = _build_agent_result_schema_ok(agent_result)
    if not schema_ok:
        raise RuntimeError("agent result schema invalid: " + "; ".join(schema_errs))
    outcome_requested = agent_result.get("outcome_requested")
    if agent_result and agent_result.get("run_id") and agent_result["run_id"] != run_id:
        raise RuntimeError("agent result run_id mismatch")

    if agent_result:
        expected_identity = {
            "packet_sha256": approval_doc["packet_sha256"],
            "approval_sha256": approval.approval_artifact_sha256(approval_doc),
            "baseline_sha": baseline_sha,
            "candidate_branch": approval_doc.get("candidate_branch"),
            "builder_identity": "of-builder",
        }
        for key, expected in expected_identity.items():
            if key in agent_result and expected is not None and agent_result.get(key) != expected:
                raise RuntimeError(
                    f"agent result fixed identity {key}={agent_result.get(key)!r} "
                    f"!= expected {expected!r}"
                )
        if "candidate_sha" in agent_result:
            raise RuntimeError(
                "agent result must not supply candidate_sha; Git HEAD is authoritative"
            )

        if state_mod.is_program_state(state):
            current_cps = ((state.get("program") or {}).get("current_checkpoints") or [])
            if not current_cps:
                raise RuntimeError("PROGRAM build has no current checkpoint")
            cp_id = current_cps[0]
            cp_meta = next(
                (cp for cp in (meta.get("checkpoint_graph") or {}).get("checkpoints", [])
                 if cp.get("id") == cp_id),
                None,
            )
            if cp_meta is None:
                raise RuntimeError(f"current checkpoint {cp_id} missing from packet")
            allowed_units: set[str] = set()
            for unit in cp_meta.get("work_units") or []:
                if isinstance(unit, str):
                    allowed_units.add(unit)
                elif isinstance(unit, dict) and isinstance(unit.get("id"), str):
                    allowed_units.add(unit["id"])
            if allowed_units and agent_result.get("work_unit_id") not in allowed_units:
                raise RuntimeError(
                    f"agent result work_unit_id {agent_result.get('work_unit_id')!r} "
                    f"is not in current checkpoint {cp_id} units {sorted(allowed_units)}"
                )

    # 5. Resolve candidate SHA and branch.
    candidate_sha = git_checks.current_head(builder_wt)
    if candidate_sha is None:
        raise RuntimeError("builder worktree has no HEAD")
    candidate_branch = git_checks.require_current_branch(builder_wt)

    # The actual branch must equal the approval-frozen candidate branch.
    # Never fabricate either side of this comparison.
    approval_frozen_branch = str(approval_doc.get("candidate_branch") or "")
    if not approval_frozen_branch:
        raise RuntimeError("approval missing frozen candidate_branch")
    if candidate_branch != approval_frozen_branch:
        raise RuntimeError(
            f"builder worktree actual branch {candidate_branch!r} != "
            f"approval-frozen candidate_branch {approval_frozen_branch!r}"
        )

    # 6. Verify candidate SHA exists in canonical repo.
    if not git_checks.commit_exists(canonical_repo, candidate_sha):
        raise RuntimeError(f"candidate SHA {candidate_sha[:12]} does not exist in canonical repo")

    # 7. Verify candidate descends from baseline.
    if not _ancestor_of(canonical_repo, candidate_sha, baseline_sha):
        raise RuntimeError(f"candidate SHA {candidate_sha[:12]} does not descend from baseline {baseline_sha[:12]}")

    # 8. Verify candidate branch contains candidate SHA.
    branch_contains = _candidate_branch_contains(canonical_repo, candidate_branch, candidate_sha)
    if not branch_contains:
        raise RuntimeError(f"candidate branch {candidate_branch!r} does not contain candidate SHA")

    # 9. Verify canonical branch unchanged.
    canon_ok, canon_msg = _verify_canonical_branch_unchanged(canonical_repo, baseline_sha, baseline_branch)
    if not canon_ok:
        raise RuntimeError(f"canonical branch drift: {canon_msg}")

    # 10. Compute changed paths and diff stats.
    changed_paths = _changed_paths_between(builder_wt, baseline_sha, candidate_sha)
    stats = _diff_stats(builder_wt, baseline_sha, candidate_sha)

    # 11. Budget check.
    budget = (meta.get("risk_budget") or {})
    max_files = int(budget.get("max_files_changed") or 0)
    max_lines = int(budget.get("max_diff_lines") or 0)
    if max_files and stats["files_changed"] > max_files:
        raise RuntimeError(
            f"files_changed={stats['files_changed']} exceeds budget max_files_changed={max_files}"
        )
    if max_lines and (stats["added_lines"] + stats["removed_lines"]) > max_lines:
        raise RuntimeError(
            f"diff_lines={stats['added_lines'] + stats['removed_lines']} exceeds budget max_diff_lines={max_lines}"
        )
    budget_ok, budget_violations = util.budget_within_ceiling({
        "max_files_changed": max_files,
        "max_diff_lines": max_lines,
        "max_repair_rounds": int(budget.get("max_repair_rounds") or 0),
    })
    if not budget_ok:
        raise RuntimeError("budget over absolute ceiling: " + "; ".join(budget_violations))

    # 12. Scope & 13. protected/elevated path checks.
    scope_findings: list[dict[str, Any]] = []
    protected_findings: list[dict[str, Any]] = []
    sensitive_findings: list[dict[str, Any]] = []
    for path in changed_paths:
        klass = _classify_path_against_packet(meta, path)
        if klass == "out_of_scope":
            scope_findings.append({"path": path, "kind": "out_of_scope"})
        elif klass == "protected":
            # Hard-stop: protected path. The packet must NOT allow it.
            protected_findings.append({"path": path, "kind": "protected"})
        elif klass == "sensitive":
            sensitive_findings.append({"path": path, "kind": "sensitive"})
        # 'allowed' and 'elevated' are fine.

    # 14. Secret scan on changed files and diff.
    secret_findings: list[dict[str, Any]] = []
    for path in changed_paths:
        abs_path = builder_wt / path
        if not abs_path.exists():
            continue
        # Use redacted scan only — never include literal match.
        hits = secrets_v2.scan_path_for_secrets_strict(abs_path)
        for hit in hits:
            secret_findings.append({
                "path": path,
                "pattern_id": hit["pattern_id"],
                "severity": hit["severity"],
                "sha256": hit["sha256"],
                "redacted_prefix": hit["redacted_prefix"],
                "line": hit.get("line"),
                "count": hit["count"],
            })
    # Hard secret pattern presence blocks candidate finalization.
    hard_secret_blocks = [f for f in secret_findings if f["severity"] == "hard"]
    if hard_secret_blocks:
        raise RuntimeError(
            "hard secret pattern detected in candidate: "
            + "; ".join(f"{f['path']}:{f['pattern_id']}" for f in hard_secret_blocks[:5])
        )

    # 15. Execute required validation commands.
    validations: list[dict[str, Any]] = []
    for v in meta.get("required_validation") or []:
        cmd = (v or {}).get("command") or ""
        name = (v or {}).get("name") or "validation"
        kind = (v or {}).get("kind") or "fast"
        timeout = int(meta.get("required_runtime_proof", {}).get("max_runtime_seconds") or 600)
        command_policy = guards.classify_bash_command(cmd)
        if command_policy.get("severity") == "forbidden":
            raise RuntimeError(
                "required_validation command refused by deterministic guard: "
                + "; ".join(command_policy.get("forbidden") or ["forbidden command"])
            )
        result = _run_validation_command(
            builder_wt,
            cmd,
            timeout_seconds=timeout,
            canonical_repo=canonical_repo,
            run_id=run_id,
        )
        expected_exit = int(
            v.get("expected_exit_code")
            if v.get("expected_exit_code") is not None
            else 0
        )
        expected_marker = v.get("expected_marker")
        marker_match = (
            True
            if expected_marker is None
            else str(expected_marker) in (
                str(result.get("stdout") or "") + str(result.get("stderr") or "")
            )
        )
        passed = (
            not bool(result["timed_out"])
            and int(result["exit_code"]) == expected_exit
            and marker_match
        )
        validations.append({
            "name": name,
            "command": cmd,
            "kind": kind,
            "exit_code": int(result["exit_code"]),
            "duration_seconds": float(result["duration_seconds"]),
            "expected_exit_code": expected_exit,
            "passed": passed,
            "timed_out": result["timed_out"],
            "stdout_truncated": result["truncated"],
            "marker_match": marker_match,
        })

    # 16. Validation succeeds only when every declared command satisfies its
    # own exit-code/marker contract and no command timed out.
    validation_pass = all(bool(v.get("passed")) for v in validations) if validations else True

    # 17. No-progress detection (v0.3.7 F-4-01: progress-sensitive).
    #
    # The streak advances only when the candidate SHA matches the
    # previous run's candidate SHA EXACTLY. Any difference — even a
    # single character — is real progress and resets the streak to 0.
    # The threshold comes from packet.risk_budget.max_consecutive_no_progress_passes
    # (default: limits.MAX_CONSECUTIVE_NO_PROGRESS_PASSES=8) and acts as
    # an emergency fuse, not a normal stop. Productive passes continue
    # indefinitely; identical-no-progress only stops at the threshold.
    last_candidate = state.get("last_candidate_sha")
    no_progress_streak = int(state.get("no_progress_streak") or 0)
    progress_made = (not last_candidate) or (last_candidate != candidate_sha)
    if not progress_made:
        no_progress_streak += 1
    else:
        no_progress_streak = 0

    # 18. Repair limits.
    # build_pass_count is owned by the claim path (cmd_build_claim).
    # The finalizer reads the existing claimed count and uses it as
    # builder_pass_number. The finalizer never increments, so:
    #   - idempotent finalizer replay cannot double-count.
    #   - a crashed claim still consumes one pass (the claim committed it).
    #   - resume of the same claimed pass produces the same number.
    new_build_pass_count = int(state.get("build_pass_count") or 0)
    new_repair_round = int(state.get("repair_round") or 0)
    cap_build = limits_mod.effective_cap("build_pass_count", meta)
    cap_repair = limits_mod.effective_cap("repair_round", meta)
    if new_build_pass_count < 1:
        # Refuse: a finalizer must run AFTER a successful claim.
        raise RuntimeError(
            "build_pass_count=0; refuse to finalize. Claim the build pass first."
        )
    if cap_build is not None and new_build_pass_count > cap_build:
        raise RuntimeError(f"build_pass_count={new_build_pass_count} above cap={cap_build}")

    # 19. Derive next_state.
    if state_mod.is_stop_requested(canonical_repo, run_id):
        next_state = "STOPPED"
    elif not ok:
        next_state = "AWAITING_APPROVAL"
    elif hard_secret_blocks:
        next_state = "BLOCKED"
    elif protected_findings:
        next_state = "BLOCKED"
    elif scope_findings:
        next_state = "BLOCKED"
    elif not validation_pass:
        # Mandatory validation failed; transition to CHANGES_REQUESTED
        # so the builder can repair. Only BLOCK if the failure is hard.
        next_state = "CHANGES_REQUESTED"
    elif outcome_requested == "blocked":
        next_state = "BLOCKED"
    elif outcome_requested == "stopped":
        next_state = "STOPPED"
    elif cap_repair is not None and new_repair_round >= cap_repair:
        next_state = "BLOCKED"
    elif no_progress_streak >= limits_mod.effective_cap("no_progress_streak", meta):
        next_state = "BLOCKED"
    else:
        next_state = "READY_FOR_REVIEW"

    # 20. Build the authoritative receipt.
    receipt = {
        "schema": "ownframework-loop-build-receipt/v2",
        "run_id": run_id,
        "packet_sha256": approval_doc["packet_sha256"],
        "approval_sha256": approval.approval_artifact_sha256(approval_doc),
        "work_unit_id": (agent_result.get("work_unit_id") if agent_result else None) or "UNIT-1",
        "baseline_sha": baseline_sha,
        "candidate_sha": candidate_sha,
        "candidate_branch": candidate_branch,
        "builder_worktree": str(builder_wt),
        "builder_pass_number": int(new_build_pass_count),
        "repair_round": int(new_repair_round),
        "files_changed": int(stats["files_changed"]),
        "added_lines": int(stats["added_lines"]),
        "removed_lines": int(stats["removed_lines"]),
        "changed_paths": sorted(changed_paths),
        "validation": validations,
        "protected_path_check": {
            "result": "fail" if protected_findings else "pass",
            "offending_paths": [p["path"] for p in protected_findings],
        },
        "secret_scan_check": {
            "result": "fail" if hard_secret_blocks else "pass",
            "findings": secret_findings[:20],  # bounded
        },
        "scope_check": {
            "result": "fail" if scope_findings else "pass",
            "findings": scope_findings,
        },
        "sensitive_path_assessment": {
            "result": "elevated" if sensitive_findings else "none",
            "paths": [p["path"] for p in sensitive_findings],
        },
        "additional_review_required": bool(meta.get("additional_review_required")) or bool(sensitive_findings),
        "timestamp": util.utc_now_iso(),
        "builder_agent": "of-builder",
        "next_state": next_state,
        "agent_summary": (agent_result.get("summary") if agent_result else None),
        "blocker_reason": (agent_result.get("blocker_reason") if agent_result else None),
        "escalation_recommended": bool(agent_result.get("escalation_recommended")) if agent_result else False,
        "escalation_reason": (agent_result.get("escalation_reason") if agent_result else None),
    }

    # 21. Persist atomically.
    receipts.write_receipt(canonical_repo, run_id, receipt)

    # 22. Append event.
    state_mod.append_event(
        canonical_repo, run_id,
        event_type="build_finalized",
        old_state=state.get("state"),
        new_state=next_state,
        actor=actor,
        commit_sha=candidate_sha,
        reason=f"deterministic finalizer -> {next_state}",
        extras={
            "files_changed": receipt["files_changed"],
            "added_lines": receipt["added_lines"],
            "removed_lines": receipt["removed_lines"],
            "validation_pass": validation_pass,
            "hard_secret_blocks": len(hard_secret_blocks),
            "protected_findings": len(protected_findings),
            "scope_findings": len(scope_findings),
        },
    )

    # 23. Update state counters.
    cur = state_mod.load(canonical_repo, run_id)
    cur["no_progress_streak"] = no_progress_streak
    cur["last_candidate_sha"] = candidate_sha
    cur["build_pass_count"] = int(new_build_pass_count)
    state_mod.save(canonical_repo, run_id, cur)

    # 24. Transition if appropriate.
    if cur.get("state") != next_state and transitions.is_valid(cur.get("state"), next_state):
        state_mod.transition(
            canonical_repo, run_id,
            to_state=next_state,
            actor=actor,
            reason=f"finalizer next_state={next_state}",
            commit_sha=candidate_sha,
        )

    return receipt
