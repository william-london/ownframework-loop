---
name: of-loop-build
description: Execute one bounded OwnFramework Loop build pass using deterministic core preparation and pass-scoped semantic output.
---

# Portable build adapter

Claim through the core, consume `ofloop build prepare`, consume
`ofloop build agent-skeleton`, engineer only in the returned worktree, fill
only the returned pass-scoped semantic result, then call deterministic
`ofloop build finalize`.

Never invent branch/baseline/worktree/checkpoint/scratch identity. A replayed
claim reuses the same pass. Never approve, edit protected protocol state, push,
merge, deploy, publish, mutate remotes, or bypass budgets.
