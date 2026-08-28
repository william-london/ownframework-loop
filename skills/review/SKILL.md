---
name: review
description: OwnFramework Loop — review pass. One invocation reviews and proves one exact candidate SHA. Validates APPROVAL.json and the build receipt, creates a detached reviewer worktree at the candidate SHA, invokes a fresh `of-reviewer` agent (broad inspection tools), collects a semantic assessment, then calls the deterministic review finalizer. Safe to invoke under `/loop`.
user-invocable: true
---

# /of-loop:review — one exact-SHA review pass

The review skill is a thin workflow coordinator. It performs at most one
review pass per invocation, reviewing exactly one candidate SHA. It MUST
be invocable by `/loop`. It invokes a fresh `of-reviewer` agent through
the Agent tool and never performs the entire review procedure in this
parent session.

## Pass responsibilities

1. Validate the target repository (canonical repo resolved via `git
   rev-parse --show-toplevel`).
2. Validate the run ID and read the current state.
3. Read the approved work packet, recompute SHA-256, refuse on hash drift.
4. Validate that APPROVAL.json exists and binds to the current packet
   bytes (canonical repo, baseline branch, baseline SHA, packet SHA,
   confirmation token).
5. Read `BUILD_RECEIPT.json` and pin the candidate SHA.
6. Create or refresh the reviewer detached worktree at the exact
   candidate SHA (path: `.worktrees/ownframework-loop/<run-id>/reviewer`).
7. Transition to `REVIEWING`, increment `review_pass_count`.
8. Invoke a fresh `of-reviewer` agent with the packet, the SHA, the
   receipt, the reviewer worktree path, and the approval summary.
9. Collect the agent's semantic `REVIEW_AGENT_ASSESSMENT.json`. The
   agent does NOT write the authoritative verdict.
10. Call `ofloop review finalize <repo> <run-id> <assessment.json>`.
    The finalizer independently verifies the candidate SHA, runs
    validations, scans for secrets, classifies findings, and writes
    the authoritative `REVIEW_VERDICT.json`. The model cannot
    influence the finalizer's verdict on any of these checks.
11. Emit the operator marker.

## No-work fast paths

- If the run is in a terminal state (APPROVED / BLOCKED / STOPPED),
  emit the stop marker and do not invoke the agent.
- If the run is in BUILDING (waiting for the builder), emit the
  wait marker and do not invoke the agent.
- If no build receipt is present, refuse with a clear error.
- If no APPROVAL.json is present, refuse with a clear error.

## Verdicts (the deterministic finalizer writes the verdict)

- `APPROVED` — the candidate satisfies every acceptance criterion,
  respects every non-goal, no must-fix findings, all required
  validations pass, no hard secrets, no protected-path mutations.
  Transition to `APPROVED`.
- `CHANGES_REQUESTED` — there are must-fix findings or required
  validations failed. Transition to `CHANGES_REQUESTED` and
  increment `repair_round`.
- `BLOCKED` — irreducible problem (hard secret, protected-path edit,
  scope violation, packet SHA drift, canonical branch drift). Transition
  to `BLOCKED`.
- `HUMAN_REVIEW_REQUIRED` — semantic review found something that
  needs an operator. The finalizer downgrades this to `BLOCKED`.
- `STALE_CANDIDATE` — the candidate SHA drifted. Transition to
  `READY_FOR_REVIEW` so the loop rebuilds the reviewer worktree.

## What the review skill MUST NOT do

- Edit source intentionally. The reviewer agent may only write
  `REVIEW_AGENT_ASSESSMENT.json` to `.ownframework-loop/<run-id>/`
  (via the CLI's permitted scratch path).
- Repair source. If a finding requires a fix, the assessment records
  it as a must_fix finding; the finalizer decides the verdict.
- Commit, push, merge, deploy, or change the work packet.
- Approve a SHA different from the one in `BUILD_RECEIPT.json`.
- Write the authoritative review verdict.
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
- `ofloop review finalize <repo> <run-id> <assessment.json>` — finalizer
- `ofloop review marker <repo> <run-id>` — emit marker

## Tracked-mutation detection

The finalizer records `reviewer_worktree.head` before and after the
review pass. If the HEAD changes during review (and the change is not
a controlled re-pin to the same candidate SHA), the finalizer
classifies the verdict as `BLOCKED` and records the changed paths.
The reviewer may not delete or prune arbitrary worktrees; only the
run-specific reviewer worktree may be cleaned up by an explicit
operator command.



## Canonical scheduling UX (v0.4.3)

The supported scheduling invocation is the bare slash command — no
cadence grammar, no `15m`, no cron syntax:

```
/loop /of-loop:review <run-id>
```

The operator does not type an interval. Native Claude `/loop` defaults
to `10m` cadence, which is acceptable for both lanes. If a different
cadence is required, the operator types it explicitly
(e.g. `/loop 15m /of-loop:review <run-id>`).

## PROGRAM mode (v3 packets)

The review pass is identical for single-mode and program-mode packets
— the determinist finalizer asserts the same SHA. PROGRAM-mode drives
the pass through `ofloop loop run`, which calls `ofloop review
finalize` once per claimable checkpoint. This skill MUST NOT run more
than one review pass per invocation regardless of mode.
