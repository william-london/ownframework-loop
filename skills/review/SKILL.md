---
name: review
description: OwnFramework Loop — review pass. One invocation reviews and proves one exact candidate SHA. Validates state, creates a detached reviewer worktree at the candidate SHA, invokes a fresh `of-reviewer` agent, writes a structured verdict, transitions atomically. Safe to invoke under `/loop`.
user-invocable: true
---

# /of-loop:review — one exact-SHA review pass

The review skill is a thin workflow coordinator. It performs at most one
review pass per invocation, reviewing exactly one candidate SHA. It MUST be
invocable by `/loop`. It invokes a fresh `of-reviewer` agent through the Agent
tool and never performs the entire review procedure in this parent session.

## Pass responsibilities

1. Validate the target repository identity (cwd is the canonical repo).
2. Validate the run ID and read the current state.
3. Read the approved work packet, recompute SHA-256, refuse on hash drift.
4. Read `BUILD_RECEIPT.json` and pin the candidate SHA.
5. Create or refresh the reviewer detached worktree at the exact candidate SHA
   (path: `.worktrees/ownframework-loop/<run-id>/reviewer`).
6. Transition to `REVIEWING`, increment `review_pass_count`.
7. Invoke a fresh `of-reviewer` agent with the packet, the SHA, the receipt,
   and the reviewer worktree path.
8. After the agent returns, validate the verdict against
   `schemas/review-verdict.schema.json`. Run stale-SHA checks.
9. Atomically write `REVIEW_VERDICT.json` via the CLI.
10. Transition to `APPROVED`, `CHANGES_REQUESTED`, `BLOCKED`, or `READY_FOR_REVIEW`
    (only when the candidate changed during review).
11. Emit the operator marker.

## Verdicts

- `APPROVED` — the candidate satisfies every acceptance criterion and respects
  every non-goal. Transition to `APPROVED`.
- `CHANGES_REQUESTED` — there are must-fix findings; transition to
  `CHANGES_REQUESTED` and increment `repair_round`.
- `BLOCKED` — the pass cannot proceed (e.g., test infrastructure failure,
  missing required access, ambiguous product decision). Transition to `BLOCKED`.
- `HUMAN_REVIEW_REQUIRED` — the reviewer cannot rule conclusively; defer to
  the operator. Transition to `BLOCKED`.
- `STALE_CANDIDATE` — the candidate SHA drifted between the reviewer starting
  and writing the verdict. Do NOT approve. Transition to `READY_FOR_REVIEW`
  so the loop rebuilds the reviewer worktree at the new SHA.

## What the review skill MUST NOT do

- Edit source intentionally. The reviewer may only write
  `REVIEW_VERDICT.json` and append to `EVENTS.log` in the run directory.
- Repair source. If a finding requires a fix, the verdict is `CHANGES_REQUESTED`.
- Commit, push, merge, deploy, or change the work packet.
- Approve a SHA different from the one in `BUILD_RECEIPT.json`.
- Run a second review pass inside one invocation.

## Operator marker

```
OF_LOOP_OPERATOR_MARKER
OF_LOOP_RUN_ID=<run-id>
OF_LOOP_ROLE=reviewer
OF_LOOP_STATE=<state>
OF_LOOP_ACTION=RESCHEDULE|STOP
OF_LOOP_NEXT_DELAY_MINUTES=<int>
OF_LOOP_REASON=<short>
```

Scheduling policy:

| State after pass | Action | Next delay |
|---|---|---|
| `READY_FOR_REVIEW` | RESCHEDULE | 0 |
| `BUILDING`, `REVIEWING` | RESCHEDULE | 15 |
| `APPROVED`, `BLOCKED`, `STOPPED`, `AWAITING_APPROVAL`, `READY_TO_BUILD`, `CHANGES_REQUESTED` | STOP | 0 |

## CLI surface used by the review skill

- `ofloop spec status <repo> <run-id>` — initial check
- `ofloop review write-verdict <repo> <run-id> <verdict.json>`
- `ofloop review marker <repo> <run-id>` — emit marker

## Tracked-mutation detection

Before invoking the reviewer agent and after the verdict is written, record
`reviewer_worktree.head`. If the HEAD changes during review, classify the
verdict as `BLOCKED` and record the changed paths. Do NOT delete or prune
arbitrary worktrees; only the run-specific reviewer worktree may be cleaned
up by an explicit operator command.

## Anti-patterns

- Running the review inside the parent conversation.
- Approving a candidate SHA that is not in `BUILD_RECEIPT.json`.
- Editing source through any means while reviewing.
- Reporting a verdict without performing every acceptance check.
