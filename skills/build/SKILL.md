---
name: build
description: OwnFramework Loop — one bounded build/repair pass. Claims atomically, consumes deterministic preparation, materializes a pass-scoped semantic skeleton, invokes a fresh of-builder, and deterministically finalizes.
user-invocable: true
---

# /of-loop:build — one bounded build or repair pass

The parent is a thin coordinator. It does not engineer source and does not own
branch/worktree/state identity.

## Fast paths

1. Resolve canonical repo and read `ofloop spec status <repo> <run-id>`.
2. If state is `APPROVED`, `BLOCKED`, `STOPPED`, or
   `AWAITING_APPROVAL`: emit the builder marker and stop.
3. If state is `READY_FOR_REVIEW` or `REVIEWING`: emit the builder marker and
   do not invoke a builder.
4. Only `READY_TO_BUILD`, `CHANGES_REQUESTED`, or replayed `BUILDING` may
   proceed.

## Pass responsibilities

1. Re-prove current packet bytes and approval binding.
2. Claim via `ofloop build claim <repo> <run-id> --actor builder`.
   A replayed `BUILDING` claim is the same pass and MUST NOT increment budget.
3. Run `ofloop build prepare <repo> <run-id>`. This is the sole owner of
   baseline, candidate branch, checkpoint/work-unit identity, builder worktree,
   and pass-scoped result path.
4. Run `ofloop build agent-skeleton <repo> <run-id>` without `--overwrite`.
   Fresh claims get a new pass path; replayed claims retain the same path.
5. Invoke one fresh `of-builder` with exactly the prepared context.
6. The agent engineers only in the prepared worktree and fills only the exact
   pass-scoped semantic result.
7. Call `ofloop build finalize <repo> <run-id> <agent_result_path>`.
8. Emit `ofloop build marker <repo> <run-id>`.

## PROGRAM mode

Human approval materializes the frozen PROGRAM graph exactly once. There is no
normal operator `program init` or `ofloop loop run` step in Claude-native
operation. Each invocation performs one claimed pass for the current
checkpoint. After an approved review the deterministic core selects/advances
the next checkpoint.

## Prohibitions

No raw worktree/branch creation or removal; no direct state/receipt/event
writes; no self-approval; no scope/budget widening; no push, merge, deploy,
publish, remote creation, or external effect.

## Canonical scheduling UX

```
/loop /of-loop:build <run-id>
```

The operator supplies no cadence, branch, worktree, claim, preparation,
skeleton, finalizer, or checkpoint-advance commands.
