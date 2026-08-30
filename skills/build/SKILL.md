---
name: build
description: OwnFramework Loop - one bounded build or repair pass. Claims atomically, consumes deterministic preparation, materializes a pass-scoped semantic skeleton, invokes a fresh of-builder, and deterministically finalizes.
user-invocable: true
---

# /of-loop:build - one bounded build or repair pass

The parent is a thin coordinator. It does not engineer source and does not own
branch/worktree/state identity.

## Fast paths (single source of truth)

| State | Action |
|-------|--------|
| APPROVED / BLOCKED / STOPPED | STOP |
| READY_FOR_REVIEW / REVIEWING | WAIT |
| AWAITING_APPROVAL / READY_TO_START | STARTABLE; invoke ofloop build claim; first claim may auto-seal |
| READY_TO_BUILD / CHANGES_REQUESTED / replayed BUILDING | proceed normally |

Internal state AWAITING_APPROVAL is preserved for compatibility. The
operator-facing meaning is READY_TO_START (the run is startable; no approval
ceremony is required).

## Substantial passes (F-5-01 v0.3.7)

A bounded build pass is not required to be minimal. When the must-fix surface,
scope, or refactor cut spans multiple files, the builder may produce a coherent
substantial pass. The operator MUST NOT collapse or thin the change set to keep
the pass small.

## First-start execution seal (v0.5.x)

The first ofloop build claim invocation on an unstarted run creates the
immutable execution seal: binding_method=build_start,
binding_kind=execution_seal. The operator first build claim IS the
authorization to execute the exact bounded packet locally.

No prior human approval. No confirmation token. No program init. No legacy
sealing command. No ofloop loop run.

## Pass responsibilities

1. Re-prove current packet bytes and execution binding.
2. Claim via ofloop build claim <repo> <run-id> --actor builder.
   A replayed BUILDING claim is the same pass and MUST NOT increment budget.
3. Run ofloop build prepare <repo> <run-id>. This is the sole owner of
   baseline, candidate branch, checkpoint/work-unit identity, builder worktree,
   and pass-scoped result path.
4. Run ofloop build agent-skeleton <repo> <run-id> without --overwrite.
   Fresh claims get a new pass path; replayed claims retain the same path.
5. Invoke one fresh of-builder with exactly the prepared context.
6. The agent engineers only in the prepared worktree and fills only the exact
   pass-scoped semantic result.
7. Call ofloop build finalize <repo> <run-id> <agent_result_path>.
8. Emit ofloop build marker <repo> <run-id>.

## Prohibitions

No raw worktree/branch creation or removal; no direct state/receipt/event
writes; no self-approval; no scope/budget widening; no push, merge, deploy,
publish, remote creation, or external effect.

## Scheduling

Canonical unattended scheduling is `ofloop supervisor enqueue <repo> <run-id>`.
This skill represents one pass and may be invoked through a host adapter for
foreground/debug work (Claude: `/of-loop:build <run-id>`). It is not the
durable execution clock.

The operator supplies no cadence, branch, worktree, claim, preparation,
skeleton, finalizer, or checkpoint-advance commands.
