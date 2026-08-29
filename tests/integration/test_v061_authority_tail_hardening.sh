#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$TMP" <<'PY'
import json
import sys
from pathlib import Path
from ownframework_loop import integrity, receipts, state, worktrees, git_checks, limits, util

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
PY

# Static guards pin exact-branch and per-validation semantics.
grep -Fq 'candidate_branch = git_checks.require_current_branch(builder_wt)' "$ROOT_DIR/lib/ownframework_loop/build_finalize.py"
if grep -Fq 'or f"factory/candidate/{run_id}"' "$ROOT_DIR/lib/ownframework_loop/build_finalize.py"; then
  fail "build finalizer still fabricates branch identity"
fi
grep -Fq 'v.get("expected_exit_code")' "$ROOT_DIR/lib/ownframework_loop/build_finalize.py"
grep -Fq 'v.get("expected_marker")' "$ROOT_DIR/lib/ownframework_loop/build_finalize.py"
grep -Fq 'v.get("expected_marker")' "$ROOT_DIR/lib/ownframework_loop/review_finalize.py"
grep -Fq 'reviewer path {wt} is not a registered worktree' "$ROOT_DIR/lib/ownframework_loop/worktrees.py"

echo "V061_AUTHORITY_TAIL_HARDENING=PASS"
