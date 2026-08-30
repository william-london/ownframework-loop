# State Machine

OwnFramework Loop uses exactly **nine** states. Any state transition
not listed in the allowed map is rejected by `lib/ownframework_loop/transitions.py`.

## States

| State | Meaning |
|---|---|
| `AWAITING_APPROVAL` | Historical internal initial-state name. Operator meaning: `READY_TO_START`. A valid packet exists; no approval ceremony is required. The first legitimate BUILD start creates the immutable execution seal. |
| `READY_TO_BUILD` | The execution seal exists and the packet/source identity is bound. Builder may claim the next pass. |
| `BUILDING` | The builder has claimed this pass. Reviewer cannot start. |
| `READY_FOR_REVIEW` | The builder produced a candidate SHA. Reviewer may claim the next pass. |
| `REVIEWING` | The reviewer has claimed this pass. Builder cannot claim. |
| `CHANGES_REQUESTED` | The reviewer returned a verdict with must-fix findings. Builder will repair. |
| `APPROVED` | Protocol-approved and eligible for operator promotion outside Loop. In PROGRAM mode, an approved checkpoint may advance the host run back to `READY_TO_BUILD` when more checkpoints are claimable. |
| `BLOCKED` | Terminal in single-run mode. In PROGRAM mode it may return only to `READY_TO_BUILD` when unfinished checkpoint work remains; it can never jump to `APPROVED`. |
| `STOPPED` | Terminal and absorbing in every mode. The operator explicitly stopped the loop; no single-run or PROGRAM escape is permitted. |

## Allowed transitions

```text
AWAITING_APPROVAL -> READY_TO_BUILD
AWAITING_APPROVAL -> BLOCKED
AWAITING_APPROVAL -> STOPPED

READY_TO_BUILD    -> BUILDING
READY_TO_BUILD    -> BLOCKED
READY_TO_BUILD    -> STOPPED

BUILDING          -> READY_FOR_REVIEW
BUILDING          -> BLOCKED
BUILDING          -> STOPPED

READY_FOR_REVIEW  -> REVIEWING
READY_FOR_REVIEW  -> BLOCKED
READY_FOR_REVIEW  -> STOPPED

REVIEWING         -> APPROVED
REVIEWING         -> CHANGES_REQUESTED
REVIEWING         -> BLOCKED
REVIEWING         -> STOPPED
REVIEWING         -> READY_FOR_REVIEW   # candidate changed during review

CHANGES_REQUESTED -> READY_TO_BUILD
CHANGES_REQUESTED -> BLOCKED
CHANGES_REQUESTED -> STOPPED
```

`APPROVED` and `BLOCKED` are terminal in single-run mode. PROGRAM continuation is a narrow extension: when unfinished checkpoint work remains, the host run may continue to `READY_TO_BUILD` through `state.program_transition()`. `STOPPED` is always absorbing. Once a PROGRAM has no claimable checkpoint, terminal host states have no outbound edge.

`CHANGES_REQUESTED` has two intentional origins. A deterministic build
finalizer may enter it when required validation fails; this is a
`BUILD_VALIDATION_RETRY`, so the next builder may claim another build without
any reviewer pass or `repair_round` increment. A reviewer may also enter it
with a `CHANGES_REQUESTED` verdict; that is a `REVIEW_FUNDED_REPAIR`, and the
review finalizer atomically claims one repair entitlement before the next
builder can claim its pass. The `repair_round` counter therefore means
reviewer-funded repairs only.

## Concurrency

Every transition acquires an exclusive `fcntl.flock` on
`.ownframework-loop/<run-id>/LOCK` before reading or writing `STATE.json`.
Concurrent state mutations are serialized; the loser of the race retries on
the next supervisor dispatch tick or a deliberate foreground supervisor/dispatch invocation.

## Event log

Every transition appends a JSON Lines record to `EVENTS.log`:

```json
{
  "ts": "2026-07-23T05:30:00Z",
  "run_id": "run-20260723T052959Z-abc12345",
  "event_type": "state_transition",
  "old_state": "BUILDING",
  "new_state": "READY_FOR_REVIEW",
  "actor": "of-builder",
  "commit_sha": "a1b2c3d4...",
  "reason": "candidate produced"
}
```

`EVENTS.log` is append-only. Truncation is a hard error detected by the
post-pass validation.

## Terminal triggers (BLOCKED or STOPPED)

- Wrong repository, wrong branch, or unexpected remote.
- Dirty unattributed baseline.
- Packet/source identity drifted after the execution seal.
- Protected-path violation.
- Prohibited command attempted (`git push`, `git merge`, etc.).
- Maximum repair rounds reached.
- Same `finding_id` repeated.
- Two consecutive no-progress passes.
- Invalid receipt (e.g., candidate SHA does not exist).
- Stale review (SHA drifted between review start and verdict).
- Test infrastructure failure.
- Ambiguous product decision.
- Missing irreducible access.
- Runtime deployment required (out of scope for V2).
- Authority outside the packet (e.g., attempting to push to a remote).
- Budget or runtime limit.


## PROGRAM mode

When a packet declares `execution_mode: program`, the host run still uses the
same nine top-level states. `STATE.json` changes to
`ownframework-loop-state/v2` by adding a frozen `program` object to the
normal host state shape; PROGRAM initialization does not replace the host
history/counter model.

A checkpoint is **not** a second nested copy of the host FSM. Each entry in
`program.checkpoints` carries its id, build/review/repair counters,
no-progress counter, candidate/receipt/verdict evidence hashes, an optional
last-evidence replay binding, and one terminal marker (empty, `APPROVED`,
`BLOCKED`, or `STOPPED`).

`program.current_checkpoints` identifies the claimable checkpoint and
`program.finalized_checkpoints` records immutable terminal evidence.
Cumulative counters and packet-derived ceilings remain inside the same frozen
PROGRAM object.

PROGRAM review approval is owned by
`program.advance_after_review_approval()`. It finalizes the current
checkpoint, selects the next dependency-ready checkpoint, then performs the
host transition atomically through `state.program_transition()`. Normal
checkpoint continuation therefore does **not** mutate a second FSM through
`state.save()`.

PROGRAM invariants include:

1. A checkpoint cannot finalize `APPROVED` without at least one build and one
   review pass.
2. The checkpoint graph SHA, baseline SHA, and candidate branch are frozen at
   first-start materialization and later drift is refused.
3. Source accounting is absolute baseline-to-current-candidate evidence and is
   checked against PROGRAM cumulative ceilings.
4. The exact reviewed candidate SHA must match the candidate bound in host
   state before checkpoint advancement.

## PROGRAM continuation transitions

In PROGRAM mode, `state.program_transition()` is the only host-FSM extension. With more claimable checkpoints it permits review advancement (including `REVIEWING` → `READY_TO_BUILD`) and the narrow `APPROVED`/`BLOCKED` → `READY_TO_BUILD` continuation cases. `BLOCKED` can never jump to `APPROVED`, and `STOPPED` can never escape. When no checkpoint remains claimable, terminality is enforced exactly as in single-run mode.
