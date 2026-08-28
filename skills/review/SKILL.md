---
name: review
description: OwnFramework Loop — one bounded exact-SHA review pass. Claims atomically, consumes deterministic reviewer preparation, materializes a pass-scoped assessment, invokes a fresh of-reviewer, then deterministically finalizes and advances PROGRAM when appropriate.
user-invocable: true
---

# /of-loop:review — one exact-SHA review pass

The parent is a thin coordinator. It does not review source itself and does not
own candidate/worktree/state identity.

## Fast paths

1. Resolve canonical repo and read `ofloop spec status <repo> <run-id>`.
2. If state is `APPROVED`, `BLOCKED`, `STOPPED`, or
   `AWAITING_APPROVAL`: emit the reviewer marker and stop.
3. If state is `READY_TO_BUILD`, `BUILDING`, or `CHANGES_REQUESTED`: emit
   the reviewer marker and wait; do not invoke a reviewer.
4. Only `READY_FOR_REVIEW` or replayed `REVIEWING` may proceed.

## Reviewer wait semantics (v0.5.0)

For an unstarted run with internal state `AWAITING_APPROVAL` / `READY_TO_START`:

  * Reviewer WAITS. The builder owns first execution start.
  * Reviewer does NOT create the execution seal independently.
  * After the build is finalized with a receipt, the reviewer proceeds
    with normal exact-SHA review.

No human approval ceremony is required. The first build claim auto-seals.

## Pass responsibilities

1. Re-prove current packet bytes, approval binding, and authoritative build
   receipt.
2. Claim via `ofloop review claim <repo> <run-id> --actor reviewer`.
   A replayed `REVIEWING` claim is the same pass and MUST NOT increment budget.
3. Run `ofloop review prepare <repo> <run-id>`. This is the sole owner of
   exact candidate SHA, frozen branch/baseline, reviewer worktree, receipt
   identity, and pass-scoped assessment path.
4. Run `ofloop review assessment-skeleton <repo> <run-id>` without
   `--overwrite`.
5. Invoke one fresh `of-reviewer` with exactly the prepared context.
6. The reviewer is source-read-only and fills only the exact pass-scoped
   semantic assessment.
7. Call `ofloop review finalize <repo> <run-id> <assessment_path>`.
8. Emit `ofloop review marker <repo> <run-id>`.

## PROGRAM mode

An `APPROVED` review routes through the single deterministic PROGRAM
advancement helper. If another checkpoint is claimable, top-level state becomes
`READY_TO_BUILD`; otherwise the run is terminal `APPROVED`.

The reviewer lane remains scheduled during `READY_TO_BUILD`, `BUILDING`, and
`CHANGES_REQUESTED`; these are wait states, not reviewer terminal states.

## Prohibitions

No raw reviewer worktree creation/re-pin/removal; no candidate selection; no
direct state/verdict/event writes; reviewer agent never calls finalizer; no
self-approval; no push, merge, deploy, publish, remote creation, or external
effect.

## Canonical scheduling UX

```
/loop /of-loop:review <run-id>
```

The operator supplies no cadence, candidate, worktree, claim, preparation,
skeleton, finalizer, or checkpoint-advance commands.
