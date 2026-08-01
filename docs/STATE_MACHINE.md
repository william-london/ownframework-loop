# State Machine

OwnFramework Loop V2 uses exactly **nine** states. Any state transition
not listed in the allowed map is rejected by `lib/ownframework_loop/transitions.py`.

## States

| State | Meaning |
|---|---|
| `AWAITING_APPROVAL` | Initial state. The work packet exists but has not been approved. |
| `READY_TO_BUILD` | The work packet is approved. Builder may claim the next pass. |
| `BUILDING` | The builder has claimed this pass. Reviewer cannot start. |
| `READY_FOR_REVIEW` | The builder produced a candidate SHA. Reviewer may claim the next pass. |
| `REVIEWING` | The reviewer has claimed this pass. Builder cannot claim. |
| `CHANGES_REQUESTED` | The reviewer returned a verdict with must-fix findings. Builder will repair. |
| `APPROVED` | Terminal. The human merges. |
| `BLOCKED` | Terminal (no outbound edges except to a fresh run via teardown). The human reads the events and decides. |
| `STOPPED` | Terminal (no outbound edges except to a fresh run via teardown). The human explicitly stopped the loop. |

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

`APPROVED`, `BLOCKED`, and `STOPPED` are terminal. Reopening a terminal
state is not in V2 and would require explicit operator action plus an
auditable event.

## Concurrency

Every transition acquires an exclusive `fcntl.flock` on
`.ownframework-loop/<run-id>/LOCK` before reading or writing `STATE.json`.
Concurrent state mutations are serialized; the loser of the race retries
on the next `/loop` tick.

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
- Packet SHA-256 changed after approval.
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


## v0.3.0 PROGRAM mode

When a packet declares `execution_mode: program`, the state schema is v2
and the canonical state machine remains the same nine states, but each
checkpoint inside `program.checkpoints` carries its own per-checkpoint
state field with the same vocabulary. The orchestrator drives one
checkpoint per pass; transitions between checkpoints do NOT go through
the host FSM (the host FSM still governs the overall run state, but
checkpoint internal state is set via `state.save()` directly to avoid
bouncing through CHANGES_REQUESTED/APPROVED gates).

Per-checkpoint state is one of:

- `READY_TO_BUILD` — current checkpoint, ready to claim
- `BUILDING` — checkpoint builder has claimed this pass
- `READY_FOR_REVIEW` — checkpoint produced a candidate SHA
- `REVIEWING` — checkpoint reviewer has claimed this pass
- `APPROVED` — checkpoint terminal (good)
- `BLOCKED` — checkpoint terminal (needs human)
- `CHANGES_REQUESTED` — checkpoint reviewer returned must-fix findings

The orchestrator guarantees invariants on the per-checkpoint lifecycle:

1. A checkpoint that is `APPROVED` MUST have at least one build pass and
   at least one review pass recorded in `program.checkpoints[CP-N].counters`
   before finalize. Otherwise `nonterminal_cp_approval_refused` is raised.
2. The checkpoint graph SHA is frozen at `program init` time. Re-running
   init with a different graph SHA is refused (`program_graph_sha_drift`).
3. The source-tree accounting (unique changed files, diff lines) is computed
   baseline->final per checkpoint AND cumulatively across the program.
   Cumulative caps come from the sum of approved-checkpoint exact caps.


## v0.3.5: program-mode transitions

In program-mode, the orchestrator may legitimately transition
`APPROVED` → `READY_TO_BUILD` when another checkpoint is claimable.
This extension is invoked only by `state.program_transition()` and
requires `has_more_checkpoints=True` to be passed. Once the program is
fully terminated (no more checkpoints), the run is terminal and the
transition is refused.
