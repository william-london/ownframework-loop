#!/usr/bin/env bash
# Case 30: wrong worktree cleanup refusal.
# Case 31: exact reviewer worktree cleanup.
# Case 29: reviewer tracked mutation detection.

set -uo pipefail
. "$(dirname "$0")/../_helpers.sh"

python3 - <<'PY'
import sys, os, tempfile, subprocess
from pathlib import Path
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get("OFLOOP_LIB", "/path/to/ownframework-loop/lib"))
from ownframework_loop import worktrees, worktrees as wt

def git(*args, cwd=None):
    return subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True, check=False)

with tempfile.TemporaryDirectory() as td:
    d = Path(td)
    git("init", "-b", "master", cwd=d)
    git("config", "user.email", "t@t", cwd=d)
    git("config", "user.name", "t", cwd=d)
    (d / "README.md").write_text("init")
    git("add", ".", cwd=d)
    git("commit", "-m", "init", cwd=d)

    run_id = "run-wt-test"

    # 1. Add builder worktree.
    bwt = worktrees.add_builder_worktree(d, run_id, branch=f"factory/candidate/{run_id}")
    assert Path(bwt["path"]).exists(), f"builder worktree not created: {bwt}"
    print(f"  PASS: builder worktree created at {bwt['path']}")

    # 2. Add reviewer worktree at the candidate SHA.
    head = git("rev-parse", "HEAD", cwd=d).stdout.strip()
    rwt = worktrees.add_reviewer_worktree(d, run_id, candidate_sha=head)
    assert Path(rwt["path"]).exists(), f"reviewer worktree not created: {rwt}"
    assert rwt["head"].startswith(head[:7]), f"reviewer HEAD mismatch: {rwt}"
    print(f"  PASS: reviewer worktree pinned at exact SHA {head[:12]}")

    # 3. Cleanup the wrong path should refuse.
    wrong = d / "totally-not-our-worktree"
    wrong.mkdir()
    ok, msg = worktrees.cleanup_reviewer_worktree(d, run_id + "-other")
    assert not ok, f"cleanup of nonexistent run should refuse, got: {msg}"
    print(f"  PASS: cleanup of unrelated run refuses ({msg})")

    # 4. Track-mutation detection: simulate the reviewer HEAD changing.
    before = worktrees.record_worktree_status(d, run_id, role="reviewer", stage="start")
    # Force reviewer HEAD to move by checking out a different commit inside the worktree.
    # We will create a new commit on the candidate branch first.
    (bwt_path := Path(bwt["path"]) / "x.txt").write_text("added by builder")
    git("add", ".", cwd=bwt["path"])
    git("commit", "-m", "second", cwd=bwt["path"])
    # Refresh the reviewer worktree to the new HEAD.
    new_head = git("rev-parse", "HEAD", cwd=bwt["path"]).stdout.strip()
    worktrees.add_reviewer_worktree(d, run_id, candidate_sha=new_head)
    after = worktrees.record_worktree_status(d, run_id, role="reviewer", stage="end")
    diff = worktrees.diff_tracked_mutation(before, after)
    # The reviewer worktree HEAD did change — but the change was due to a legitimate refresh.
    # Mutation detection records the raw fact; downstream logic classifies the verdict.
    assert before["head"] != after["head"]
    assert diff["mutated"] is True
    print("  PASS: reviewer HEAD drift detected via mutation check")

    # 5. Cleanup the run-specific reviewer worktree only.
    ok, msg = worktrees.cleanup_reviewer_worktree(d, run_id)
    assert ok, f"cleanup failed: {msg}"
    assert not Path(rwt["path"]).exists()
    print(f"  PASS: run-specific reviewer worktree cleaned ({msg})")

    # 6. Cleanup the builder worktree.
    ok, msg = worktrees.cleanup_builder_worktree(d, run_id)
    assert ok, f"builder cleanup failed: {msg}"
    assert not Path(bwt["path"]).exists()
    print(f"  PASS: run-specific builder worktree cleaned ({msg})")

print("ALL PASS")
PY
