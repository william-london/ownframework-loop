# Codex Escalation

`CODEX=manual_triggered_escalation`. The loop does not call Codex. Codex
is invoked by the operator as a separate manual lane when a durable
escalation marker appears.

## Trigger conditions

The review verdict or `EVENTS.log` carries a Codex escalation
recommendation when any of the following is observed:

- Maximum repair rounds reached (`repair_round >= max_repair_rounds`).
- The same `finding_id` repeats twice in a row.
- Builder and reviewer materially disagree on approach (verdict is
  `HUMAN_REVIEW_REQUIRED`, not `CHANGES_REQUESTED`).
- Authentication or authorization change is present.
- Secret or credential architecture change is present.
- Customer data boundary change is present.
- Database migration is present.
- Destructive data operation is present.
- Concurrency or race-condition uncertainty is unresolved.
- Cross-runtime architecture change is present.
- Production infrastructure change is present.
- Deployment or rollback ambiguity is present.
- The candidate exceeds approved diff or file limits.
- The reviewer cannot prove root-cause correctness.

The verdict sets `codex_escalation_recommended: true` and supplies a
`codex_reason`.

## Operator runbook

1. Open Codex in a separate session.
2. Provide Codex with:
   - `WORK_PACKET.md` (or its metadata block),
   - `BUILD_RECEIPT.json`,
   - `REVIEW_VERDICT.json`,
   - the candidate SHA and the reviewer worktree path,
   - any `EVENTS.log` records relevant to the escalation.
3. Codex returns a manual investigation. Its findings are advisory.
4. You decide what to do:
   - Accept Codex's recommendation and amend the packet.
   - Override Codex and proceed.
   - Stop the run.
5. Record the outcome in `EVENTS.log` via:
   ```bash
   ofloop spec amend <repo> <run-id> "codex recommendation: <one line>"
   ```

## What Codex MUST NOT do

- Call back into the OwnFramework Loop.
- Modify `STATE.json`, `BUILD_RECEIPT.json`, `REVIEW_VERDICT.json`,
  or `WORK_PACKET.md`.
- Trigger push, merge, deploy, or remote creation.
- Decide for the operator.

## Why this lane exists

Codex is a separate review tool with different model assumptions. It
catches failure modes the M3 reviewer may miss (long-running
concurrency, cross-language APIs, migration ordering, etc.). The loop
emits the marker; the operator decides whether to invoke Codex. The
two are independent and observable.
