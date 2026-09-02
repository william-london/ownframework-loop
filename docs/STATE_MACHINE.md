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
BUILDING          -> CHANGES_REQUESTED   # deterministic build-validation retry
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

There is intentionally NO generic `CHANGES_REQUESTED -> BUILDING` FSM edge
in `transitions.ALLOWED`. The two paths that legitimately cross that edge
are both owner-scoped and crash-bounded; neither exposes a generic
transition available to arbitrary callers:

* **SINGLE mode.** The deterministic build/review finalizers and the
  foreground `build transition` owner each apply a post-hook that returns
  the run to `READY_TO_BUILD` inside the same finalize sequence (with the
  reviewer-funded repair entitlement claimed atomically by
  `state.transition_funded_repair`, exposed for the review lane as
  `state.transition_review_rejection_with_repair`), so the next build claim
  normally starts from a generic-FSM state. If a SINGLE run crashes
  between the funded-repair transaction and that post-hook, the SINGLE
  atomic claim owner (`state.claim_single_pass`, `pass_kind="build"`) may
  recover through a narrow owner-only `CHANGES_REQUESTED -> BUILDING`
  edge; the regular `transitions.assert_valid()` check is intentionally
  skipped for that one case so a stranded SINGLE run remains claimable
  without re-charging `repair_round`. The reconciler (`reconcile.py`,
  action `complete_single_mode_changes_requested_post_hook`) handles the
  normal crash recovery by completing the missing post-hook back to
  `READY_TO_BUILD`; the claim-owner recovery edge is the second-line
  fallback when reconciliation has not yet run.

* **PROGRAM mode.** The unified claim owner
  (`program.claim_build_pass` / `program.claim_review_pass` via
  `program._unified_claim_pass`) performs the claim edge
  (`CHANGES_REQUESTED -> BUILDING`) atomically under the run lock with an
  explicit `_CLAIM_OWNER_EDGES` whitelist. PROGRAM runs legitimately
  rest in `CHANGES_REQUESTED` between claim rounds; only the unified
  claim owner, never a generic FSM transition, advances the host state.

Both paths flow through their owner functions under flock with the run
lock, counter funding, and STATE/EVENTS integrity verified in the same
`STATE_TXN`. Generic `state.transition()` callers cannot reach
`CHANGES_REQUESTED -> BUILDING`; the FSM rejects the edge.

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

STATE ownership is structural, not a blacklist. Every protocol-authoritative
field (`STATE_OWNER_FIELDS`: identity, FSM counters, review fuses, candidate
SHA, termination, the frozen `program` object, spec baselines) is owned by a
named owner, and generic caller `extras` are structurally incapable of
writing STATE.json at all — diagnostics travel through `append_event()`
extras instead. Authoritative updates flow exclusively through the transition
owners (`state.transition()`, `state.program_transition()`,
`state.transition_funded_repair()`) via their explicit typed owner
parameters; the funded-repair owner has no generic extras channel at all and
resets the no-progress fuse inside its atomic mutation. `state.save()` is
CREATION-ONLY: once durable state exists it refuses unconditionally, which
structurally eliminates stale read→save lost-update windows.
`state.atomic_patch()` is the crash-atomic read-modify-write owner for
explicitly enlisted NON-authoritative fields only (one flock hold, one
write-ahead `STATE_TXN`, no window between read and commit). Funded repair is
ONE atomic mutation: the rejection state and the repair entitlement commit in
a single `STATE_TXN`, and repair-cap exhaustion seals `BLOCKED` in that same
transaction, so an unfunded claimable `CHANGES_REQUESTED` can never exist —
not even across a crash.

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
