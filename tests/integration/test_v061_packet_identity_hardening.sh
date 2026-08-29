#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$TMP" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import packet, approval, verdicts, worktrees, git_checks, util

root = Path(sys.argv[1])

base = {
    "schema": "ownframework-work-packet/v2",
    "packet_id": "p1",
    "created_at": "2026-08-29T00:00:00Z",
    "work_class": "BUG",
    "risk_class": "low",
    "title": "x",
    "target": {"repo": str(root), "branch": "master", "classification": "github_public"},
    "acceptance_criteria": [{"id": "AC-1", "text": "x"}],
    "non_goals": [{"id": "NG-1", "text": "x"}],
    "allowed_paths": ["src/"],
    "protected_paths": [".git/"],
    "work_units": [{"id": "UNIT-1", "title": "x", "scope": "x"}],
    "merge_authority": "human_only",
    "deploy_authority": "human_only",
    "push_authority": "human_only",
    "external_action_authority": "none",
}
assert packet.validate_packet_metadata(base) == []

assert packet.validate_packet_metadata({**base, "allowed_paths": ["./src/", "tests/"]}) == []
for bad in ("../outside", "/tmp/outside", "src/../outside", "src\\outside", "src//x"):
    m = dict(base)
    m["allowed_paths"] = [bad]
    errs = packet.validate_packet_metadata(m)
    assert any("allowed_paths" in e for e in errs), (bad, errs)

# Approval binding must reject a packet targeting another repo even when the
# approval itself names the active canonical repo.
repo = root / "repo"
repo.mkdir()
packet_path = root / "WORK_PACKET.md"
packet_path.write_text("x", encoding="utf-8")
ap = {
    "schema": approval.SCHEMA_VERSION,
    "run_id": "run-packet-bind",
    "packet_sha256": util.sha256_text("x"),
    "approved_at": "2026-08-29T00:00:00Z",
    "approved_actor": "operator",
    "canonical_repo": str(repo.resolve()),
    "baseline_branch": "master",
    "baseline_sha": "a" * 40,
    "packet_schema": "ownframework-work-packet/v2",
    "approval_method": "build_start",
    "confirmation_token": approval.derive_confirmation_token(util.sha256_text("x")),
    "candidate_branch": "factory/candidate/run-packet-bind",
}
meta = dict(base)
meta["target"] = dict(base["target"])
meta["target"]["repo"] = str(root / "other")
orig_head = git_checks.current_head
try:
    git_checks.current_head = lambda *_a, **_k: "a" * 40
    ok, reason = approval.validate_approval_binding(
        canonical_repo=repo, run_id="run-packet-bind", approval=ap,
        packet=meta, packet_path=packet_path,
    )
    assert not ok and "target.repo" in reason
finally:
    git_checks.current_head = orig_head

# Verdict writer must refuse unknown reviewer cleanliness.
repo2 = root / "review"
repo2.mkdir()
rid = "run-review-unknown"
wt = util.reviewer_worktree(repo2, rid)
wt.mkdir(parents=True)
orig_reg = worktrees.is_registered_worktree
orig_head = git_checks.current_head
orig_commit = git_checks.commit_exists
orig_status = git_checks.dirty_status
try:
    worktrees.is_registered_worktree = lambda *_a, **_k: True
    git_checks.current_head = lambda *_a, **_k: "b" * 40
    git_checks.commit_exists = lambda *_a, **_k: True
    git_checks.dirty_status = lambda *_a, **_k: "unknown"
    try:
        verdicts._assert_exact_clean_review_candidate(
            repo2, rid, {"candidate_sha_reviewed": "b" * 40}
        )
    except RuntimeError as exc:
        assert "cleanliness is unknown" in str(exc)
    else:
        raise SystemExit("verdict writer accepted unknown cleanliness")
finally:
    worktrees.is_registered_worktree = orig_reg
    git_checks.current_head = orig_head
    git_checks.commit_exists = orig_commit
    git_checks.dirty_status = orig_status
PY

if grep -Fq 'return "UNIT-1"' "$ROOT_DIR/lib/ownframework_loop/build_agent.py"; then
  fail "builder skeleton still fabricates UNIT-1"
fi
grep -Fq 'packet target.repo does not match canonical repo' "$ROOT_DIR/lib/ownframework_loop/approval.py"
grep -Fq 'seal candidate_branch=' "$ROOT_DIR/lib/ownframework_loop/execution_start.py"

echo "V061_PACKET_IDENTITY_HARDENING=PASS"
