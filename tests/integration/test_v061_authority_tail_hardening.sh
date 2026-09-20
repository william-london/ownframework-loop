#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$TMP" <<'PY'
import json
import os
import sys
from pathlib import Path
from ownframework_loop import (
    guards, integrity, receipts, state, worktrees, git_checks, limits, util,
    validation_executor, review_finalize,
)

root = Path(sys.argv[1])

# State tampering must not be laundered by a later ordinary event.
repo = root / "state-repo"
repo.mkdir()
rid = "run-authority-tail"
st = state.initial_state(rid)
state.save(repo, rid, st)
sp = state.state_path(repo, rid)
doc = json.loads(sp.read_text())
doc["last_actor"] = "tampered"
sp.write_text(json.dumps(doc, indent=2, sort_keys=True))
try:
    state.append_event(
        repo, rid, event_type="should_refuse", old_state=None,
        new_state=None, actor="test"
    )
except integrity.TamperingDetected:
    pass
else:
    raise SystemExit("append_event laundered tampered STATE.json")

# PROGRAM-style locked reads must also refuse tampered state.
try:
    with state._locked_state(repo, rid):
        pass
except integrity.TamperingDetected:
    pass
else:
    raise SystemExit("_locked_state accepted tampered STATE.json")

# Receipt writer must treat unknown cleanliness as refusal, not clean.
repo2 = root / "receipt-repo"
repo2.mkdir()
rid2 = "run-receipt-unknown"
wt = util.builder_worktree(repo2, rid2)
wt.mkdir(parents=True)
orig_reg = worktrees.is_registered_worktree
orig_head = git_checks.current_head
orig_branch = git_checks.current_branch
orig_status = git_checks.dirty_status
try:
    worktrees.is_registered_worktree = lambda *_a, **_k: True
    git_checks.current_head = lambda *_a, **_k: "a" * 40
    git_checks.current_branch = lambda *_a, **_k: "factory/candidate/" + rid2
    git_checks.dirty_status = lambda *_a, **_k: "unknown"
    try:
        receipts._assert_exact_clean_builder_candidate(
            repo2, rid2, {
                "candidate_sha": "a" * 40,
                "candidate_branch": "factory/candidate/" + rid2,
            }
        )
    except RuntimeError as exc:
        assert "cleanliness is unknown" in str(exc)
    else:
        raise SystemExit("receipt writer accepted unknown cleanliness")
finally:
    worktrees.is_registered_worktree = orig_reg
    git_checks.current_head = orig_head
    git_checks.current_branch = orig_branch
    git_checks.dirty_status = orig_status

assert limits._absolute_cap("build_pass_count") == util.ABSOLUTE_BUDGET_CEILING["max_build_passes"]

# Authority JSON readers refuse symlinks and loose mode.
private = root / "private.json"
util.atomic_write_json(private, {"x": 1}, mode=0o600)
assert util.read_private_json(private)["x"] == 1
private.chmod(0o644)
assert util.read_private_json(private, default=None) is None
private.chmod(0o600)
target = root / "target.json"; target.write_text('{"x":1}'); target.chmod(0o600)
private.unlink(); private.symlink_to(target)
assert util.read_private_json(private, default=None) is None

# dirty_classification preserves an explicit unknown result on probe failure.
orig_run = git_checks.run_subprocess
class P:
    returncode = 1
    stdout = ""
    stderr = "boom"
git_checks.run_subprocess = lambda *a, **k: P()
try:
    assert git_checks.dirty_classification(root)["status"] == "unknown"
finally:
    git_checks.run_subprocess = orig_run

assert guards.classify_bash_command(
    "env git commit -m hidden", role="reviewer"
)["severity"] == "forbidden"
assert guards.classify_bash_command(
    "echo $(git branch hidden)", role="reviewer"
)["severity"] == "forbidden"
assert guards.classify_bash_command(
    "env FOO=bar pytest -q", role="reviewer"
)["severity"] == "allowed"
assert guards.classify_bash_command(
    "sudo true", role="builder"
)["severity"] == "forbidden"
assert guards.classify_bash_command(
    "echo $(sudo true)", role="builder"
)["severity"] == "forbidden"

# Validation exit-code and marker semantics are behavioral authority, not
# implementation-text contracts. Exercise the canonical executor directly
# while isolating unrelated capability/policy plumbing.
validation_cwd = root / "validation-cwd"
validation_cwd.mkdir()
orig_policy = validation_executor.validation_policy.classify_required_validation
orig_env = validation_executor.runtime_env.commissioned_validation_env
try:
    validation_executor.validation_policy.classify_required_validation = (
        lambda *_a, **_k: {"allowed": True}
    )
    validation_executor.runtime_env.commissioned_validation_env = (
        lambda *_a, **_k: dict(os.environ)
    )
    accepted = validation_executor.run_required_validation(
        cwd=validation_cwd,
        validation={
            "name": "expected-exit-and-marker",
            "command": "printf 'EXPECTED_MARKER\\n'; exit 7",
            "kind": "fast",
            "expected_exit_code": 7,
            "expected_marker": "EXPECTED_MARKER",
        },
        timeout_seconds=5,
        canonical_repo=validation_cwd,
        run_id="run-validation-authority",
        packet={},
    )
    assert accepted["exit_code"] == 7, accepted
    assert accepted["expected_exit_code"] == 7, accepted
    assert accepted["marker_match"] is True, accepted
    assert accepted["passed"] is True, accepted

    marker_fail = validation_executor.run_required_validation(
        cwd=validation_cwd,
        validation={
            "name": "missing-marker",
            "command": "printf 'OTHER_MARKER\\n'; exit 7",
            "kind": "fast",
            "expected_exit_code": 7,
            "expected_marker": "EXPECTED_MARKER",
        },
        timeout_seconds=5,
        canonical_repo=validation_cwd,
        run_id="run-validation-authority",
        packet={},
    )
    assert marker_fail["exit_code"] == 7, marker_fail
    assert marker_fail["marker_match"] is False, marker_fail
    assert marker_fail["passed"] is False, marker_fail
finally:
    validation_executor.validation_policy.classify_required_validation = orig_policy
    validation_executor.runtime_env.commissioned_validation_env = orig_env

# Review-finalizer validation is also behavioral: drive finalize_review through
# its deterministic authority preconditions and use a sentinel executor to
# prove a declared required_validation reaches the canonical executor. The
# sentinel fires before verdict persistence, so this fixture does not duplicate
# the wider review lifecycle tests.
review_repo = root / "review-validation-repo"
review_repo.mkdir()
review_rid = "run-review-validation-authority"
review_run_dir = review_repo / ".ownframework-loop" / review_rid
review_run_dir.mkdir(parents=True)
(review_run_dir / "WORK_PACKET.md").write_text("fixture\n", encoding="utf-8")
review_assessment_path = root / "review-assessment.json"
review_assessment_path.write_text("{}\n", encoding="utf-8")
review_wt = review_repo / ".worktrees" / "ownframework-loop" / review_rid / "reviewer"
review_wt.mkdir(parents=True)
baseline = "b" * 40
candidate = "c" * 40
candidate_branch = "factory/candidate/" + review_rid
validation_decl = {"name": "review-required", "command": "true", "kind": "fast"}
packet_meta = {"required_validation": [validation_decl]}
approval_doc = {
    "baseline_sha": baseline,
    "candidate_branch": candidate_branch,
}
receipt_doc = {
    "schema": "ownframework-loop-build-receipt/v2",
    "candidate_sha": candidate,
    "candidate_branch": candidate_branch,
    "baseline_sha": baseline,
}
assessment_doc = {
    "schema": "ownframework-loop-review-agent-assessment/v1",
    "run_id": review_rid,
    "candidate_sha_claimed": candidate,
    "acceptance_results": [],
    "non_goal_results": [],
    "findings": [],
    "recommended_verdict": "APPROVED",
}

class ReviewValidationReached(RuntimeError):
    pass

def validation_sentinel(**kwargs):
    assert kwargs["validation"] == validation_decl, kwargs
    assert kwargs["cwd"] == review_wt, kwargs
    raise ReviewValidationReached("review-finalizer-reached-validation-executor")

saved = []
def patch(obj, name, value):
    saved.append((obj, name, getattr(obj, name)))
    setattr(obj, name, value)

try:
    patch(review_finalize.packet_mod, "parse_packet_file", lambda *_a, **_k: (packet_meta, "packet-hash"))
    patch(review_finalize.packet_mod, "validate_packet_for_approval", lambda *_a, **_k: [])
    patch(review_finalize.approval, "load_approval", lambda *_a, **_k: approval_doc)
    patch(review_finalize.approval, "validate_approval_binding", lambda *_a, **_k: (True, "ok"))
    patch(review_finalize.state_mod, "load_verified", lambda *_a, **_k: {"state": "REVIEWING"})
    patch(review_finalize.state_mod, "is_program_state", lambda *_a, **_k: False)
    patch(review_finalize.receipts, "load_receipt", lambda *_a, **_k: receipt_doc)
    patch(review_finalize.util, "sha256_file", lambda *_a, **_k: "receipt-hash")
    patch(review_finalize.git_checks, "is_git_repo", lambda *_a, **_k: True)
    patch(review_finalize.git_checks, "commit_exists", lambda *_a, **_k: True)
    patch(review_finalize.git_checks, "current_head", lambda *_a, **_k: candidate)
    patch(review_finalize.git_checks, "dirty_status", lambda *_a, **_k: "clean")
    patch(review_finalize.git_checks, "dirty_classification", lambda *_a, **_k: {"status": "clean", "porcelain": []})
    patch(review_finalize.worktrees, "is_registered_worktree", lambda *_a, **_k: True)
    patch(review_finalize.util, "reviewer_worktree", lambda *_a, **_k: review_wt)
    patch(review_finalize, "_ancestor_of", lambda *_a, **_k: True)
    patch(review_finalize, "_candidate_branch_contains", lambda *_a, **_k: True)
    patch(review_finalize, "_read_json", lambda *_a, **_k: assessment_doc)
    patch(review_finalize, "_assessment_schema_ok", lambda *_a, **_k: (True, []))
    patch(review_finalize.assessment_mod, "build_skeleton", lambda *_a, **_k: assessment_doc)
    patch(review_finalize.assessment_mod, "FIXED_KEYS", frozenset())
    patch(review_finalize.program_mod, "resolve_effective_required_validation", lambda *_a, **_k: [validation_decl])
    patch(review_finalize.validation_executor, "run_required_validation", validation_sentinel)
    try:
        review_finalize.finalize_review(
            canonical_repo=review_repo,
            run_id=review_rid,
            assessment_path=review_assessment_path,
            actor="reviewer",
        )
    except ReviewValidationReached as exc:
        assert "review-finalizer-reached-validation-executor" in str(exc)
    else:
        raise SystemExit("review finalizer did not execute required validation")
finally:
    for obj, name, original in reversed(saved):
        setattr(obj, name, original)
PY

echo "V061_AUTHORITY_TAIL_HARDENING=PASS"
