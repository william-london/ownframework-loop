---
name: review
description: OwnFramework Loop - one bounded review pass. Waits until a build receipt exists, then performs exact-SHA review and transitions state via the deterministic review finalizer.
user-invocable: true
---

# /of-loop:review - one bounded review pass

The parent is a thin coordinator. It does not engineer source and does not own
branch/worktree/state identity.

## Fast paths (single source of truth)

| State | Action |
|-------|--------|
| APPROVED / BLOCKED / STOPPED | STOP |
| AWAITING_APPROVAL / READY_TO_START | WAIT - builder owns first start |
| READY_TO_BUILD / BUILDING / CHANGES_REQUESTED | WAIT - no reviewable receipt yet |
| READY_FOR_REVIEW / replayed REVIEWING | REVIEW - proceed |

## Pre-start semantics

For an unstarted run with state AWAITING_APPROVAL / READY_TO_START:

  * Reviewer WAITS. The builder owns first execution start.
  * Reviewer does NOT create the execution seal independently.
  * Reviewer does NOT call ofloop build claim.
  * Reviewer does NOT issue approval or token.

After the builder creates a build receipt and transitions state to
READY_FOR_REVIEW or CHANGES_REQUESTED, the reviewer proceeds with normal
exact-SHA review.

## Pass responsibilities

1. Re-prove current packet bytes and execution binding.
2. Claim via ofloop review claim <repo> <run-id> --actor reviewer.
   A replayed REVIEWING claim is the same pass and MUST NOT increment budget.
3. Run ofloop review prepare <repo> <run-id>.
4. Optionally materialize reviewer scratch via ofloop review assessment-skeleton.
5. Run ofloop review finalize <repo> <run-id> <assessment-path>.
6. Emit ofloop review marker <repo> <run-id>.

## Prohibitions

No raw worktree creation or removal; no direct state/receipt/verdict writes;
no scope/budget widening; no push, merge, deploy, publish, remote creation,
or external effect.

## Scheduling

Canonical unattended scheduling is `ofloop supervisor enqueue <repo> <run-id>`.
This skill represents one pass and may be invoked through a host adapter for
foreground/debug work. It is not the durable execution clock.

The operator supplies no cadence, claim, preparation, assessment-skeleton,
finalizer, or approval commands.
