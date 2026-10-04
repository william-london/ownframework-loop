#!/usr/bin/env bash
# v1.1.2 — a semantic worker must never treat the other role's worktree as an
# independent evidence authority.
#
# Issue (test debt, plus one real structural gap). The post-HVAC audit could
# not prove whether a REVIEW worker could read the BUILDER worktree: the
# builder worktree appeared in neither the reviewer's allowRead nor its
# denyRead, and the disposition of an unlisted path belongs to the external
# Claude sandbox rather than to Loop. Adjudication found the invariant was
# true only INCIDENTALLY — a candidate repository under the operator's home
# directory is already covered by the broad denyRead of $HOME, so a repo at
# ~/projects/x happened to be safe. A repository checked out outside $HOME
# left the sibling worktree on unlisted ground.
#
# The deterministic path-policy owner is
# supervisor_runner._semantic_worker_settings. It now denies the sibling
# role's worktree explicitly, so the invariant holds wherever the repository
# lives. This can only REMOVE potential authority: the role's own worktree
# stays in allowRead, and a more-specific allowRead entry still wins.
#
# Required invariants proven here:
#   OWN WORKTREE         => readable for the role that owns it
#   SIBLING WORKTREE     => never in allowRead, for either role
#   SIBLING WORKTREE     => explicitly in denyRead, for either role
#   NO BROAD PARENT      => no allowRead entry is an ancestor of the sibling
#   NO PATH TRAVERSAL    => sibling reached via .. is still refused
#   ROLE CACHE           => per-role cache roots differ; neither contains the
#                           other role's worktree
#   REVIEWER CANDIDATE  => reviewer still cannot WRITE its own worktree
#   ISOLATION IS LOCATION-INDEPENDENT (repo under $HOME and outside it)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib:$ROOT_DIR/tests/helpers${PYTHONPATH:+:$PYTHONPATH}"
export OFLOOP_LIB="$ROOT_DIR/lib"
export PYTHONDONTWRITEBYTECODE=1
TMP="$(mktemp -d -t ofloop-v132-cross-role-isolation.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

python3 -B - "$TMP" "$ROOT_DIR" <<'PY'
from __future__ import annotations

import os
import sys
from pathlib import Path

root = Path(sys.argv[2])
sys.path.insert(0, str(root / "lib"))
from ownframework_loop import supervisor_runner as runner_mod, util  # noqa: E402

HOME = Path(os.path.expanduser("~")).resolve()

REPOS = {
    "repo_under_home": (HOME / "projects" / "ofloop-isolation-fixture").resolve(strict=False),
    "repo_outside_home": Path("/Volumes/ofloop-isolation-fixture").resolve(strict=False),
}


def settings(repo, run_id, role):
    own = util.builder_worktree(repo, run_id) if role == "builder" \
        else util.reviewer_worktree(repo, run_id)
    return own, runner_mod._semantic_worker_settings(
        canonical_repo=repo,
        run_id=run_id,
        role=role,
        worktree=own,
        semantic_path=repo / ".ownframework-loop" / run_id / "scratch" / "p" / "a.json",
        network_read_allowlist=[],
        capability_resolution={},
    )["sandbox"]["filesystem"]


def is_ancestor(candidate: Path, other: Path) -> bool:
    """True when `candidate` is a strict ancestor directory of `other`."""
    try:
        other.relative_to(candidate)
    except ValueError:
        return False
    return other != candidate


for label, repo in REPOS.items():
    for role in ("builder", "reviewer"):
        run_id = f"run-isolation-{role}"
        own, fs = settings(repo, run_id, role)
        sibling = util.reviewer_worktree(repo, run_id) if role == "builder" \
            else util.builder_worktree(repo, run_id)
        allow_read = {Path(p) for p in fs["allowRead"]}
        allow_write = {Path(p) for p in fs["allowWrite"]}
        deny_read = {Path(p) for p in fs["denyRead"]}
        deny_write = {Path(p) for p in fs.get("denyWrite") or []}

        # The role's own candidate worktree is exactly readable.
        assert own in allow_read, f"{label}/{role}: own worktree not readable"
        print(f"{label}/{role}/OWN_READABLE=PASS")

        # The sibling worktree is never readable, and is explicitly denied.
        assert sibling not in allow_read, f"{label}/{role}: sibling readable"
        assert sibling not in allow_write, f"{label}/{role}: sibling writable"
        assert sibling in deny_read, f"{label}/{role}: sibling not explicitly denied"
        print(f"{label}/{role}/SIBLING_DENIED=PASS")

        # No broad allowRead ancestor (worktrees dir, run dir, repo root)
        # re-opens the sibling. This is the "broad parent allowRead" vector.
        broad = [p for p in allow_read if is_ancestor(p, sibling)]
        assert not broad, f"{label}/{role}: broad allowRead ancestor grants sibling: {broad}"
        print(f"{label}/{role}/NO_BROAD_PARENT=PASS")

        # Path traversal through the own worktree cannot reach the sibling by
        # policy: the sibling's own path is denied regardless of how it is
        # spelled, and no allowRead entry contains it.
        traversed = (own / ".." / sibling.name).resolve(strict=False)
        assert traversed == sibling, "traversal spelling did not normalize to the sibling"
        assert traversed not in allow_read, f"{label}/{role}: traversal spelling readable"
        assert str(traversed) in {str(p) for p in deny_read}, \
            f"{label}/{role}: traversal spelling not denied"
        print(f"{label}/{role}/NO_PATH_TRAVERSAL=PASS")

        # Role-scoped runtime caches differ and contain no worktree at all.
        from ownframework_loop import runtime_env as runtime_env_mod
        b_cache = runtime_env_mod.runtime_cache_path(repo, run_id, "builder")
        r_cache = runtime_env_mod.runtime_cache_path(repo, run_id, "reviewer")
        assert b_cache != r_cache, "role runtime caches are not distinct"
        assert own not in b_cache.parents and own not in r_cache.parents, \
            "a role runtime cache is nested inside a worktree"
        print(f"{label}/{role}/ROLE_CACHE_ISOLATED=PASS")

        # The reviewer still cannot mutate its own candidate worktree.
        if role == "reviewer":
            assert own in deny_write, "reviewer may write its own candidate worktree"
            assert own not in allow_write, "reviewer own worktree in allowWrite"
            print(f"{label}/reviewer/CANDIDATE_READ_ONLY=PASS")

print("V132_CROSS_ROLE_WORKTREE_ISOLATION=PASS")
PY
