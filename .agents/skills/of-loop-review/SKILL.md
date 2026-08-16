---
name: of-loop-review
description: Review the exact OwnFramework Loop candidate Git SHA and return a bounded verdict through the deterministic core without mutating source.
---

# OwnFramework Loop — review

The reviewer evaluates the exact candidate SHA named by the core, not an arbitrary live worktree.

1. Resolve the exact candidate Git SHA recorded by the core.
2. Inspect that commit against the approved baseline, packet, and acceptance criteria.
3. Run or inspect the required validation evidence without modifying source.
4. Produce a supported verdict: `APPROVED`, `CHANGES_REQUESTED`, `BLOCKED`, or `STOPPED` as defined by the current core schema.
5. Finalize through the supported `ofloop` review path so the verdict binds to the exact reviewed SHA.
6. Leave repair counters and lifecycle transitions to the core.

Do not edit source, approve a packet, directly edit protected state, push, merge, deploy, publish, mutate remotes, or reset repair budgets. Human promotion remains outside the loop even after `APPROVED`.
