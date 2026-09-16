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
 16b. Re-proves builder worktree HEAD, worktree cleanliness, and
      baseline-ref identity AFTER validation, so validation can
      never mutate the candidate behind the receipt's back.
 16c. For PROGRAM runs, re-measures the absolute baseline-to-candidate
      source accounting against the packet's global source ceilings.
 17. Detects no progress and repeated candidate SHA.
 18. Enforces pass limits (repair-round limits are enforced
      fail-closed at repair-claim time, so the final funded repair
      always reaches its review).
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
from pathlib import Path
from typing import Any

from . import (
    approval, git_checks, guards, integrity, limits as limits_mod,
    packet as packet_mod, program as program_mod, receipts, secrets_v2,
    validation_executor,
    state as state_mod, transitions, util, worktrees,
    build_agent as build_agent_mod,
    protected_recovery,
)


SCHEMA_AGENT_RESULT = build_agent_mod.SCHEMA_AGENT_RESULT

# Compatibility aliases for existing tests/callers; the semantic contract is
# owned in build_agent.py and shared with dispatch readiness.
AGENT_RESULT_REQUIRED = tuple(sorted(build_agent_mod.REQUIRED_RESULT_KEYS))
AGENT_RESULT_ALLOWED_OUTCOMES = set(build_agent_mod.ALLOWED_OUTCOMES)


def _read_json(path: Path, default: Any = None) -> Any:
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return default


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


def _strict_ceiling(top: int, program_ceiling: int) -> int:
    """Return the stricter of two ceilings; 0 means 'not declared'.

    When both are declared the effective envelope is min(top, program_ceiling)
    so neither approved limit can silently widen the source envelope. When
    only one side is declared, that declared value is the strict envelope.
    """
    if top and program_ceiling:
        return min(int(top), int(program_ceiling))
    return int(top or program_ceiling or 0)


def _ancestor_of(canonical_repo: Path, candidate_sha: str, baseline_sha: str) -> bool:
    """Return True iff candidate_sha is a descendant of baseline_sha."""
    r = util.run_subprocess(
        ["git", "-C", str(canonical_repo), "merge-base", "--is-ancestor", baseline_sha, candidate_sha],
        timeout=10,
    )
    return r.returncode == 0


def _verify_canonical_branch_unchanged(canonical_repo: Path, baseline_sha: str, expected_branch: str) -> tuple[bool, str]:
    """Refuse if the frozen local baseline branch ref drifted from approval.

    The visible canonical checkout may sit on another branch. The builder owns
    its isolated candidate worktree; source authority is the exact baseline ref
    and SHA, not the operator's current checkout position.
    """
    if not git_checks.is_git_repo(canonical_repo):
        return False, "canonical repo is not a git repository"
    head = git_checks.branch_head(canonical_repo, expected_branch)
    if head is None:
        return False, f"baseline branch {expected_branch!r} is missing or not resolvable"
    if head != baseline_sha:
        return False, f"baseline branch ref {head} drifted from approved baseline {baseline_sha}"
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
    errors = build_agent_mod.validate_agent_result_contract(result)
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
            "schema": SCHEMA_AGENT_RESULT,
            "run_id": run_id,
            "work_unit_id": build_agent_mod._resolve_current_work_unit_id(
                canonical_repo, run_id
            ),
            "packet_sha256": approval_doc["packet_sha256"],
            "approval_sha256": approval.approval_artifact_sha256(approval_doc),
            "baseline_sha": baseline_sha,
            "candidate_branch": approval_doc.get("candidate_branch"),
            "builder_identity": "of-builder",
        }
        for key, expected in expected_identity.items():
            if key not in agent_result or expected is not None and agent_result.get(key) != expected:
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

    # 11. Top-level risk-budget source-size envelope.
    #
    # In SINGLE mode this is the only authoritative source envelope and an
    # over-budget candidate must fail-closed here as the historical contract
    # requires.
    #
    # In PROGRAM mode the absolute PROGRAM source-accounting path (block 11b)
    # is the authoritative owner of source-size adjudication. The frozen
    # effective envelope is the stricter of this top-level limit and the
    # packet's `global_source_ceilings` — neither approved limit may silently
    # widen the envelope. A PROGRAM-mode over-budget candidate therefore
    # falls through to the structured `program_source_check` and gets the
    # deterministic BLOCKED evidence path instead of escaping as an opaque
    # RuntimeError that the supervisor auto-quarantines.
    budget = (meta.get("risk_budget") or {})
    max_files_top = int(budget.get("max_files_changed") or 0)
    max_lines_top = int(budget.get("max_diff_lines") or 0)
    program_mode = state_mod.is_program_state(state)
    top_level_breach: str | None = None
    if max_files_top and stats["files_changed"] > max_files_top:
        msg = (
            f"files_changed={stats['files_changed']} exceeds top-level "
            f"risk_budget max_files_changed={max_files_top}"
        )
        if program_mode:
            top_level_breach = top_level_breach or msg
        else:
            raise RuntimeError(msg)
    if max_lines_top and (stats["added_lines"] + stats["removed_lines"]) > max_lines_top:
        msg = (
            f"diff_lines={stats['added_lines'] + stats['removed_lines']} "
            f"exceeds top-level risk_budget max_diff_lines={max_lines_top}"
        )
        if program_mode:
            top_level_breach = top_level_breach or msg
        else:
            raise RuntimeError(msg)

    if not program_mode:
        budget_ok, budget_violations = util.budget_within_ceiling({
            "max_files_changed": max_files_top,
            "max_diff_lines": max_lines_top,
            "max_repair_rounds": int(budget.get("max_repair_rounds") or 0),
        })
        if not budget_ok:
            raise RuntimeError("budget over absolute ceiling: " + "; ".join(budget_violations))

    # 11b. PROGRAM global source ceilings — also owns top-level source-size
    # adjudication in PROGRAM mode so a frozen source-budget breach produces
    # deterministic BLOCKED evidence rather than an opaque RuntimeError.
    #
    # The packet-bound ceilings (max_unique_changed_files /
    # max_baseline_to_final_diff_lines) are declared in unique-file,
    # baseline-to-final semantics. They are therefore re-measured
    # absolutely against baseline..candidate at every build finalization
    # — the only accounting that matches the declaration. Additive
    # per-pass deltas would double-count files touched by multiple
    # passes and count reverted churn. A breach fails closed toward
    # BLOCKED (a legitimate engineered stop, like cap exhaustion) and is
    # recorded in the receipt and the program counters.
    program_source_check: dict[str, Any] | None = None
    if state_mod.is_program_state(state):
        prog = state.get("program") or {}
        ceilings = prog.get("cumulative_ceilings") or {}
        program_max_files = int(ceilings.get("max_unique_changed_files") or 0)
        program_max_lines = int(ceilings.get("max_baseline_to_final_diff_lines") or 0)

        # Strict envelope = whichever of the two approved limits is smaller;
        # a 0 means 'not declared' on that side, in which case the declared
        # value stands alone and the effective value mirrors it.
        effective_max_files = _strict_ceiling(max_files_top, program_max_files)
        effective_max_lines = _strict_ceiling(max_lines_top, program_max_lines)

        unique_files = int(stats["files_changed"])
        diff_line_total = int(stats["added_lines"]) + int(stats["removed_lines"])
        try:
            program_mod.record_source_accounting(
                prog,
                files_changed_unique=unique_files,
                diff_lines_total=diff_line_total,
            )
            program_ceiling_breach = ""
        except program_mod.ProgramStateError as exc:
            program_ceiling_breach = str(exc)

        breach_messages: list[str] = []
        if program_ceiling_breach:
            breach_messages.append(program_ceiling_breach)
        if top_level_breach:
            breach_messages.append(top_level_breach)
        if effective_max_files and unique_files > effective_max_files:
            breach_messages.append(
                f"effective file cap exceeded: {unique_files}/{effective_max_files}"
            )
        if effective_max_lines and diff_line_total > effective_max_lines:
            breach_messages.append(
                f"effective diff-lines cap exceeded: {diff_line_total}/{effective_max_lines}"
            )

        program_source_check = {
            "result": "fail" if breach_messages else "pass",
            "accounting": "absolute_baseline_to_candidate",
            "files_changed_unique": unique_files,
            "diff_lines_total": diff_line_total,
            "top_level_risk_max_files_changed": max_files_top,
            "top_level_risk_max_diff_lines": max_lines_top,
            "program_max_unique_changed_files": program_max_files,
            "program_max_baseline_to_final_diff_lines": program_max_lines,
            "effective_max_files_changed": effective_max_files,
            "effective_max_diff_lines": effective_max_lines,
            "breach": "; ".join(breach_messages),
        }

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

    # Recovery publishes a safe descendant before the normal FSM transition.
    # If the process dies in that narrow interval, replay the same funded
    # repair instead of treating the restored tree as a fresh candidate.
    pending_protected_recovery: dict[str, Any] | None = None
    protected_drift_recovery: dict[str, Any] | None = None
    original_candidate_sha = candidate_sha
    if state_mod.is_program_state(state):
        pending_cp_id = str(((state.get("program") or {}).get("current_checkpoints") or [""])[0])
        if pending_cp_id:
            pending_protected_recovery = protected_recovery.pending_completed_recovery(
                canonical_repo=canonical_repo,
                run_id=run_id,
                current_state=state,
                checkpoint_id=pending_cp_id,
                builder_worktree=builder_wt,
                candidate_branch=candidate_branch,
            )
            if pending_protected_recovery is not None:
                protected_drift_recovery = pending_protected_recovery
                original_candidate_sha = str(
                    pending_protected_recovery["previous_candidate_sha"]
                )
                protected_findings.extend(
                    {
                        "path": path,
                        "kind": "protected",
                        "recovered_candidate_drift": True,
                    }
                    for path in pending_protected_recovery["offending_paths"]
                )

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
                "severity": secrets_v2.normalize_public_artifact_severity(
                    hit["severity"]
                ),
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

    # Candidate-only protected drift is recoverable when the current candidate
    # is otherwise a valid descendant of the durable checkpoint-entry tree.
    # Recovery preserves the violating commit as history but makes the active
    # core-owned descendant use the complete safe anchor tree; no model source
    # from the tainted attempt is salvaged. Authority failures, hard secrets,
    # mixed scope/protected drift, and exhausted repair entitlement remain
    # terminal.
    protected_drift_recovery_error = ""
    if (
        protected_findings
        and pending_protected_recovery is None
        and not scope_findings
        and program_source_check is not None
        and program_source_check.get("result") == "pass"
        and state_mod.is_program_state(state)
    ):
        repair_cap = limits_mod.effective_cap("repair_round", meta)
        repair_used = int(state.get("repair_round") or 0)
        cp_id = str(((state.get("program") or {}).get("current_checkpoints") or [""])[0])
        cp_meta = next(
            (cp for cp in (meta.get("checkpoint_graph") or {}).get("checkpoints", [])
             if isinstance(cp, dict) and cp.get("id") == cp_id),
            None,
        )
        if cp_meta is not None:
            repair_cap = min(
                int(repair_cap) if repair_cap is not None else int(cp_meta["risk_budget"]["max_repair_rounds"]),
                int(cp_meta["risk_budget"]["max_repair_rounds"]),
            )
        if repair_cap is None or repair_used < int(repair_cap):
            try:
                protected_drift_recovery = protected_recovery.recover_candidate_only_protected_drift(
                    canonical_repo=canonical_repo,
                    run_id=run_id,
                    packet=meta,
                    current_state=state,
                    checkpoint_id=cp_id,
                    builder_worktree=builder_wt,
                    candidate_branch=candidate_branch,
                    candidate_sha=candidate_sha,
                    offending_paths=[str(item["path"]) for item in protected_findings],
                )
                candidate_sha = str(protected_drift_recovery["candidate_sha"])
                changed_paths = _changed_paths_between(builder_wt, baseline_sha, candidate_sha)
                stats = _diff_stats(builder_wt, baseline_sha, candidate_sha)
                # The source ceiling is authoritative over the repaired tree,
                # not over the discarded candidate.
                if state_mod.is_program_state(state):
                    prog = state.get("program") or {}
                    ceilings = prog.get("cumulative_ceilings") or {}
                    program_max_files = int(ceilings.get("max_unique_changed_files") or 0)
                    program_max_lines = int(ceilings.get("max_baseline_to_final_diff_lines") or 0)
                    effective_max_files = _strict_ceiling(max_files_top, program_max_files)
                    effective_max_lines = _strict_ceiling(max_lines_top, program_max_lines)
                    unique_files = int(stats["files_changed"])
                    diff_line_total = int(stats["added_lines"]) + int(stats["removed_lines"])
                    try:
                        program_mod.record_source_accounting(
                            prog,
                            files_changed_unique=unique_files,
                            diff_lines_total=diff_line_total,
                        )
                        breach = ""
                    except program_mod.ProgramStateError as exc:
                        breach = str(exc)
                    breach_messages: list[str] = []
                    if breach:
                        breach_messages.append(breach)
                    if top_level_breach:
                        breach_messages.append(top_level_breach)
                    if effective_max_files and unique_files > effective_max_files:
                        breach_messages.append(
                            f"effective file cap exceeded: {unique_files}/{effective_max_files}"
                        )
                    if effective_max_lines and diff_line_total > effective_max_lines:
                        breach_messages.append(
                            f"effective diff-lines cap exceeded: {diff_line_total}/{effective_max_lines}"
                        )
                    program_source_check = {
                        "result": "fail" if breach_messages else "pass",
                        "accounting": "absolute_baseline_to_candidate",
                        "files_changed_unique": unique_files,
                        "diff_lines_total": diff_line_total,
                        "top_level_risk_max_files_changed": max_files_top,
                        "top_level_risk_max_diff_lines": max_lines_top,
                        "program_max_unique_changed_files": program_max_files,
                        "program_max_baseline_to_final_diff_lines": program_max_lines,
                        "effective_max_files_changed": effective_max_files,
                        "effective_max_diff_lines": effective_max_lines,
                        "breach": "; ".join(breach_messages),
                    }
            except protected_recovery.ProtectedDriftRecoveryError as exc:
                # The original protected finding remains authoritative.  A
                # refusal here is recorded and follows the existing terminal
                # protected-path policy; no repair is silently granted.
                protected_drift_recovery_error = str(exc)

    # 15. Execute required validation commands.
    validations: list[dict[str, Any]] = []
    for v in program_mod.resolve_effective_required_validation(meta, state):
        timeout = int(meta.get("required_runtime_proof", {}).get("max_runtime_seconds") or 600)
        result = validation_executor.run_required_validation(
            cwd=builder_wt,
            validation=v,
            timeout_seconds=timeout,
            canonical_repo=canonical_repo,
            run_id=run_id,
            packet=meta,
        )
        validations.append(result)

    # 16. Validation succeeds only when every declared command satisfies its
    # own exit-code/marker contract and no command timed out.
    validation_pass = all(bool(v.get("passed")) for v in validations) if validations else True

    # 16b. Candidate identity re-proof AFTER validation.
    #
    # Validation commands are packet-declared shell executed inside the
    # builder worktree; the pre-validation identity checks (steps 5-9)
    # prove nothing about what those commands subsequently did.
    # Deterministic validation must never mutate the candidate behind the
    # receipt's back: re-prove the full sealing identity here (builder
    # HEAD, worktree cleanliness, baseline branch ref pinned at approved SHA).
    # A breach fails closed toward BLOCKED with a legible receipt instead
    # of an opaque finalize crash after the claimed pass was consumed.
    reproof_head = git_checks.current_head(builder_wt)
    reproof_cleanliness = git_checks.dirty_status(builder_wt)
    canon_ok_post, canon_msg_post = _verify_canonical_branch_unchanged(
        canonical_repo, baseline_sha, baseline_branch
    )
    identity_reproof = {
        "result": "pass",
        "head_before_validation": candidate_sha,
        "head_after_validation": reproof_head or "",
        "worktree_status_after_validation": reproof_cleanliness,
        "canonical_branch_ok_after_validation": canon_ok_post,
        "canonical_branch_detail_after_validation": canon_msg_post,
    }
    if reproof_head != candidate_sha:
        identity_reproof["result"] = "fail"
    if reproof_cleanliness != "clean":
        identity_reproof["result"] = "fail"
    if not canon_ok_post:
        identity_reproof["result"] = "fail"

    # 17. No-progress detection (v0.3.7 F-4-01: progress-sensitive).
    #
    # The streak advances only when the candidate SHA matches the
    # previous run's candidate SHA EXACTLY. Any difference — even a
    # single character — is real progress and resets the streak to 0.
    # The threshold comes from packet.risk_budget.max_consecutive_no_progress_passes
    # (default: limits.MAX_CONSECUTIVE_NO_PROGRESS_PASSES=8; packets may only
    # narrow it) and acts as an emergency fuse, not a normal stop. Productive
    # passes continue indefinitely; identical-no-progress only stops at the
    # threshold.
    last_candidate = state.get("last_candidate_sha")
    no_progress_streak = int(state.get("no_progress_streak") or 0)
    progress_made = (not last_candidate) or (last_candidate != candidate_sha)
    if not progress_made:
        no_progress_streak += 1
    else:
        no_progress_streak = 0

    # 18. Pass limits.
    # build_pass_count is owned by the claim path (cmd_build_claim).
    # The finalizer reads the existing claimed count and uses it as
    # builder_pass_number. The finalizer never increments, so:
    #   - idempotent finalizer replay cannot double-count.
    #   - a crashed claim still consumes one pass (the claim committed it).
    #   - resume of the same claimed pass produces the same number.
    #
    # Repair-round limits are deliberately NOT decided here. They are
    # enforced fail-closed at the same atomic repair owner used for scope,
    # validation, and review failures. Blocking HERE on repair_round >= cap
    # would starve the final funded repair of its review: the repaired
    # candidate must always be allowed to prove itself in review.
    new_build_pass_count = int(state.get("build_pass_count") or 0)
    new_repair_round = int(state.get("repair_round") or 0)
    cap_build = limits_mod.effective_cap("build_pass_count", meta)
    if new_build_pass_count < 1:
        # Refuse: a finalizer must run AFTER a successful claim.
        raise RuntimeError(
            "build_pass_count=0; refuse to finalize. Claim the build pass first."
        )
    if cap_build is not None and new_build_pass_count > cap_build:
        raise RuntimeError(f"build_pass_count={new_build_pass_count} above cap={cap_build}")

    repair_causes: list[str] = []
    if scope_findings:
        repair_causes.append("scope_drift")
    if not validation_pass:
        repair_causes.append("validation_failed")
    if protected_drift_recovery is not None:
        repair_causes.append("protected_candidate_drift")

    # 19. Derive next_state. (Approval binding was proven at step 1; there is
    # no path back to AWAITING_APPROVAL from BUILDING.)
    if state_mod.is_stop_requested(canonical_repo, run_id):
        next_state = "STOPPED"
    elif identity_reproof["result"] != "pass":
        # Validation mutated the candidate worktree or the canonical
        # branch behind the finalizer's back. The sealing contract is
        # broken; terminalize deterministically with the evidence in the
        # receipt rather than hand a tampered tree to review.
        next_state = "BLOCKED"
    elif program_source_check is not None and program_source_check["result"] != "pass":
        next_state = "BLOCKED"
    elif hard_secret_blocks:
        next_state = "BLOCKED"
    elif protected_findings and protected_drift_recovery is None:
        next_state = "BLOCKED"
    elif protected_findings and protected_drift_recovery is not None:
        next_state = "CHANGES_REQUESTED"
    elif scope_findings:
        # Ordinary scope drift is repairable: the fresh builder receives the
        # authoritative receipt findings through dispatch and must remove the
        # unauthorized path. Protected paths and other hard boundaries above
        # remain terminal BLOCKED.
        next_state = "CHANGES_REQUESTED"
        # A scope repair is a funded repair round, just like a rejected
        # review.  Preflight the packet-bound entitlement so exhaustion is
        # terminal rather than exposing an unfunded CHANGES_REQUESTED state.
        repair_cap = limits_mod.effective_cap("repair_round", meta)
        repair_used = int(state.get("repair_round") or 0)
        if state_mod.is_program_state(state):
            program_state = state.get("program") or {}
            cp_id = (program_state.get("current_checkpoints") or [None])[0]
            cp_meta = next(
                (cp for cp in (meta.get("checkpoint_graph") or {}).get("checkpoints", [])
                 if isinstance(cp, dict) and cp.get("id") == cp_id),
                None,
            )
            if cp_meta is None:
                raise RuntimeError(f"current checkpoint {cp_id!r} missing from packet")
            repair_cap = min(
                int(repair_cap) if repair_cap is not None else int(cp_meta["risk_budget"]["max_repair_rounds"]),
                int(cp_meta["risk_budget"]["max_repair_rounds"]),
            )
        if repair_cap is not None and repair_used >= int(repair_cap):
            next_state = "BLOCKED"
    elif not validation_pass:
        # Mandatory validation failed; transition to CHANGES_REQUESTED
        # so the builder can repair. Only BLOCK if the failure is hard or the
        # funded repair envelope is exhausted.
        next_state = "CHANGES_REQUESTED"
        repair_cap = limits_mod.effective_cap("repair_round", meta)
        repair_used = int(state.get("repair_round") or 0)
        if state_mod.is_program_state(state):
            program_state = state.get("program") or {}
            cp_id = (program_state.get("current_checkpoints") or [None])[0]
            cp_meta = next(
                (cp for cp in (meta.get("checkpoint_graph") or {}).get("checkpoints", [])
                 if isinstance(cp, dict) and cp.get("id") == cp_id),
                None,
            )
            if cp_meta is None:
                raise RuntimeError(f"current checkpoint {cp_id!r} missing from packet")
            repair_cap = min(
                int(repair_cap) if repair_cap is not None else int(cp_meta["risk_budget"]["max_repair_rounds"]),
                int(cp_meta["risk_budget"]["max_repair_rounds"]),
            )
        if repair_cap is not None and repair_used >= int(repair_cap):
            next_state = "BLOCKED"
    elif outcome_requested == "blocked":
        next_state = "BLOCKED"
    elif outcome_requested == "stopped":
        next_state = "STOPPED"
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
        "protected_drift_recovery": (
            protected_drift_recovery
            if protected_drift_recovery is not None
            else ({"result": "refused", "reason": protected_drift_recovery_error}
                  if protected_drift_recovery_error else {"result": "not_applicable"})
        ),
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
        "candidate_identity_reproof": identity_reproof,
        "program_source_ceiling_check": program_source_check or {"result": "not_applicable"},
        "additional_review_required": bool(meta.get("additional_review_required")) or bool(sensitive_findings),
        "timestamp": util.utc_now_iso(),
        "builder_agent": "of-builder",
        "next_state": next_state,
        "agent_summary": (agent_result.get("summary") if agent_result else None),
        "blocker_reason": (agent_result.get("blocker_reason") if agent_result else None),
        "escalation_recommended": agent_result.get("escalation_recommended") is True,
        "escalation_reason": (agent_result.get("escalation_reason") if agent_result else None),
    }

    # Validate the complete authoritative artifact before either persistence
    # path. The identity-reproof breach path intentionally bypasses the clean
    # worktree assertion, but it must never bypass the public receipt schema.
    receipts.validate_receipt_contract(receipt)

    # 21. Persist atomically. An identity-reproof failure is written
    # directly: the clean-candidate assertion inside receipts.write_receipt
    # cannot hold for a tree that validation tampered with, and the
    # breach record in the receipt is precisely the evidence that keeps
    # the run terminal (next_state=BLOCKED, no review can claim it).
    if identity_reproof["result"] != "pass":
        util.atomic_write_json(
            receipts.receipt_path(canonical_repo, run_id), receipt, mode=0o600
        )
    else:
        receipts.write_receipt(canonical_repo, run_id, receipt)

    # 22-24. Apply finalizer-derived state and the top-level transition in
    # ONE STATE_TXN-backed mutation.  Previously the derived counters were
    # saved while the run was still BUILDING and the transition happened
    # afterward; a crash between those writes made replay of the same claimed
    # pass increment no_progress_streak a second time. The audit-trail event
    # is appended AFTER the transition succeeds so the event chain can never
    # claim a transition that did not happen, and an unexpected state
    # (concurrent mutation by a different actor) fails closed instead of
    # silently no-op'ing.
    cur = state_mod.load_verified(canonical_repo, run_id)
    program_block: dict[str, Any] | None = None
    if program_source_check is not None and state_mod.is_program_state(cur):
        candidate_block = cur.get("program") or {}
        counters = candidate_block.get("cumulative_counters")
        if isinstance(counters, dict):
            counters["files_changed_unique"] = program_source_check["files_changed_unique"]
            counters["diff_lines_total"] = program_source_check["diff_lines_total"]
            program_block = candidate_block

    if cur.get("state") == next_state:
        # Idempotent replay: a previous successful finalizer already advanced
        # the state; we must not transition again but we still need to record
        # the audit-trail event for THIS invocation.
        pass
    elif transitions.is_valid(cur.get("state"), next_state):
        if next_state == "CHANGES_REQUESTED" and repair_causes:
            funded = state_mod.transition_funded_repair(
                canonical_repo,
                run_id,
                packet=meta,
                actor=actor,
                commit_sha=candidate_sha,
                allowed_sources=frozenset({"BUILDING"}),
                claimed_reason=(
                    "build finalization requested repair: "
                    + "+".join(repair_causes)
                    + "; repair entitlement claimed atomically"
                ),
            )
            next_state = str(funded.get("state") or "")
            if next_state == "CHANGES_REQUESTED" and not funded.get("repair_claimed"):
                raise RuntimeError(
                    "build repair entitlement was not funded despite available preflight"
                )
        else:
            state_mod.transition(
                canonical_repo, run_id,
                to_state=next_state,
                actor=actor,
                reason=f"finalizer next_state={next_state}",
                commit_sha=candidate_sha,
                no_progress_streak=no_progress_streak,
                build_pass_count=int(new_build_pass_count),
                program_block=program_block,
            )
    else:
        raise RuntimeError(
            f"build finalizer cannot transition {cur.get('state')!r} -> {next_state!r}; "
            "concurrent state mutation must be reconciled before finalization"
        )

    # 25. Append event AFTER the transition has durably succeeded.
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
            "protected_drift_recovered": protected_drift_recovery is not None,
            "original_candidate_sha": original_candidate_sha,
            "scope_findings": len(scope_findings),
        },
    )

    if next_state == "CHANGES_REQUESTED":
        # Single-mode post-hook (mirrors review_finalize): the generic FSM has
        # no CHANGES_REQUESTED -> BUILDING edge, so a run left resting in
        # CHANGES_REQUESTED could never be claimed again. Move single-mode
        # runs back to READY_TO_BUILD so the next build pass is reachable.
        # PROGRAM runs keep CHANGES_REQUESTED because the unified program
        # claim owner atomically claims the next builder from that state.
        # Both scope drift and validation failure have already funded exactly
        # one repair round through the shared owner above.
        cur_after = state_mod.load_verified(canonical_repo, run_id)
        if (
            not state_mod.is_program_state(cur_after)
            and cur_after.get("state") == "CHANGES_REQUESTED"
        ):
            try:
                state_mod.transition(
                    canonical_repo, run_id,
                    to_state="READY_TO_BUILD",
                    actor="build_finalize",
                    reason="build validation retry; ready for next build",
                )
            except transitions.InvalidTransitionError:
                now = state_mod.load_verified(canonical_repo, run_id)
                if (now or {}).get("state") != "READY_TO_BUILD":
                    raise

    return receipt
