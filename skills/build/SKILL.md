---
name: build
description: OwnFramework Loop — build pass. One invocation performs at most one bounded build or repair pass. Validates state, claims the build, invokes a fresh `of-builder` agent, writes a build receipt, transitions atomically. Safe to invoke under `/loop`.
user-invocable: true
---

# /of-loop:build — one bounded build or repair pass

The build skill is a thin workflow coordinator. It performs at most one
build pass per invocation. It MUST be invocable by `/loop` (do not add any
frontmatter that prevents that). It invokes a fresh `of-builder` agent via
the Agent tool and never performs the entire build procedure in this parent
session.

## Pass responsibilities

1. Validate the target repository identity (cwd is the canonical repo).
2. Validate the work packet is present and approved.
3. Recompute the packet SHA-256 and reject if it has changed since approval.
4. Validate the current state allows a build claim
   (`READY_TO_BUILD` or `CHANGES_REQUESTED`).
5. Claim the build atomically (`READY_TO_BUILD -> BUILDING`,
   `CHANGES_REQUESTED -> BUILDING`), increment `build_pass_count`.
6. Create or reuse the builder worktree at
   `.worktrees/ownframework-loop/<run-id>/builder` on branch
   `factory/candidate/<run-id>`.
7. Verify the baseline is clean and untouched by anyone other than this run.
8. Invoke a fresh `of-builder` agent through the Agent tool, providing the
   packet metadata, current state, build-receipt slot, and the worktree path.
9. After the agent returns, inspect and validate the resulting candidate
   (commit exists, files_changed within budget, no protected-path edits,
   no secret-shaped content).
10. Compute `BUILD_RECEIPT.json` (schema in `schemas/build-receipt.schema.json`).
11. Transition to `READY_FOR_REVIEW`, `BLOCKED`, or `STOPPED`.
12. Emit the operator marker.

## What the build skill MUST NOT do

- Merge, push, create a remote, deploy, or operate on production.
- Reset, stash, clean, revert, or commit unrelated work.
- Modify protected paths (`AGENTS.md`, `CLAUDE.md`, `.claude/`,
  `.ownframework-loop/`, `state/`, etc.).
- Silently broaden scope or add work units the operator did not request.
- Approve its own work.
- Run a second build pass inside one invocation.

## Operator marker

After the pass, emit:

```
OF_LOOP_OPERATOR_MARKER
OF_LOOP_RUN_ID=<run-id>
OF_LOOP_ROLE=builder
OF_LOOP_STATE=<state>
OF_LOOP_ACTION=RESCHEDULE|STOP
OF_LOOP_NEXT_DELAY_MINUTES=<int>
OF_LOOP_REASON=<short>
```

Scheduling policy:

| State after pass | Action | Next delay |
|---|---|---|
| `READY_TO_BUILD`, `BUILDING`, `CHANGES_REQUESTED` | RESCHEDULE | 0 |
| `READY_FOR_REVIEW` | RESCHEDULE | 10 |
| `REVIEWING` | RESCHEDULE | 15 |
| `APPROVED`, `BLOCKED`, `STOPPED`, `AWAITING_APPROVAL` | STOP | 0 |

## CLI surface used by the build skill

- `ofloop spec status <repo> <run-id>` — initial check
- `ofloop build claim <repo> <run-id>` — atomic claim
- `ofloop build write-receipt <repo> <run-id> <receipt.json>` — receipt
- `ofloop build marker <repo> <run-id>` — emit marker

The skill uses the `lib/ownframework_loop/` Python library directly for
packet hashing, baseline checks, and worktree creation. It never edits
`STATE.json` directly.

## Anti-patterns

- Performing the build inside the parent conversation instead of a fresh agent.
- Letting the builder agent create a remote or push to one.
- Letting the builder agent write a build receipt for a candidate that does
  not exist in the worktree.
- Letting the build session continue past one pass when launched under `/loop`.
