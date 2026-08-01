#!/usr/bin/env bash
# v0.3.5 (F-4-02): worktree creation concurrency E2E.
#
# Spawn N=4 concurrent add_builder_worktree and N=4 concurrent
# add_reviewer_worktree against the same run. Assert: one canonical
# worktree per role, deterministic serialization, no cryptic errors.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=_helpers.sh
source "$HERE/../_helpers.sh"

: "${PYTHONPATH:=$ROOT/lib}"
export PYTHONPATH

T="$(make_tmp_repo)"
RID="run-wt-conc-$$"

python3 - "$T" "$RID" "$ROOT" <<'PYEND'
import sys, os, json, subprocess
from pathlib import Path
sys.path.insert(0, sys.argv[3] + "/lib")
from ownframework_loop import worktrees as wt_mod

repo = Path(sys.argv[1])
rid = sys.argv[2]

results_builder = []
def call_builder():
    try:
        r = wt_mod.add_builder_worktree(repo, rid, branch="builder-cp-1-r0")
        return ("ok", r.get("existed"), (r.get("head") or "")[:12])
    except wt_mod.WorktreeError as e:
        return ("err", str(e)[:80], "")

import concurrent.futures
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as ex:
    futs = [ex.submit(call_builder) for _ in range(4)]
    for f in futs:
        results_builder.append(f.result())

# Check no cryptic CalledProcessError leaked through
errs = [r for r in results_builder if r[0] == "err"]
if errs:
    print("FAIL: builder errors:", errs)
    sys.exit(1)

# Check git worktree list: exactly one matching entry
out = subprocess.run(["git", "-C", str(repo), "worktree", "list", "--porcelain"],
                     capture_output=True, text=True, check=True).stdout
matches = [line for line in out.split("\n") if rid in line]
if len(matches) != 1:
    print("FAIL: expected 1 builder worktree entry, got", len(matches))
    sys.exit(1)

# Now reviewer
results_reviewer = []
def call_reviewer():
    base_sha = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"],
                              capture_output=True, text=True, check=True).stdout.strip()
    try:
        r = wt_mod.add_reviewer_worktree(repo, rid, candidate_sha=base_sha)
        return ("ok", r.get("existed"), (r.get("head") or "")[:12])
    except wt_mod.WorktreeError as e:
        return ("err", str(e)[:80], "")

with concurrent.futures.ThreadPoolExecutor(max_workers=4) as ex:
    futs = [ex.submit(call_reviewer) for _ in range(4)]
    for f in futs:
        results_reviewer.append(f.result())

errs = [r for r in results_reviewer if r[0] == "err"]
if errs:
    print("FAIL: reviewer errors:", errs)
    sys.exit(1)

out = subprocess.run(["git", "-C", str(repo), "worktree", "list", "--porcelain"],
                     capture_output=True, text=True, check=True).stdout
matches = [line for line in out.split("\n") if rid in line]
# 1 builder + 1 reviewer = 2 entries
if len(matches) != 2:
    print("FAIL: expected 2 total worktree entries (1 builder + 1 reviewer), got", len(matches))
    sys.exit(1)

print("BUILDER_RESULTS", json.dumps(results_builder))
print("REVIEWER_RESULTS", json.dumps(results_reviewer))
print("WT_LIST_MATCHES", len(matches))
print("WORKTREE_CONCURRENCY=PASS")
PYEND
