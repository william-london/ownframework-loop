---
name: of-loop-build
description: Execute a bounded OwnFramework Loop build pass against a human-approved work packet and hand the exact candidate Git SHA to the deterministic core.
---

# OwnFramework Loop — build

The deterministic core owns scope, lifecycle state, repair counters, candidate identity, and terminal semantics.

## Preconditions

- The run has a valid human approval binding.
- The core reports a build-eligible state.
- Respect allowed/protected paths, file/line/runtime budgets, repair ceilings, and required validation.

## Build pass

1. Read the approved packet and run status through supported `ofloop` commands.
2. Work only in the isolated builder worktree selected by the core.
3. Make the smallest coherent implementation that satisfies the approved acceptance criteria.
4. Run the validation required by the packet/current pass.
5. Commit the candidate inside the isolated worktree when required by the core contract.
6. Finalize through the supported `ofloop` build path so the exact candidate SHA is recorded by the core.
7. Stop when the state becomes review-ready, blocked, stopped, or terminal.

Never approve packets, directly edit protected run state, push, merge, deploy, publish, alter remotes, or bypass repair budgets. The reviewer target is the exact Git SHA recorded by the core, not an uncommitted worktree.
