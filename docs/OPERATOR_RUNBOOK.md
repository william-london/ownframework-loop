# OPERATOR_RUNBOOK

Canonical operator workflow for OwnFramework Loop.

## Operator flow

1. Create spec: /of-loop:spec <mission>.
2. Launch builder lane: /loop /of-loop:build <run-id>.
3. Launch reviewer lane: /loop /of-loop:review <run-id>.
4. Observe state read-only.
5. After terminal APPROVED, decide promotion outside Loop.

## Internal vs operator-facing state

Internal state AWAITING_APPROVAL is preserved for backward compatibility.
The operator-facing meaning is READY_TO_START - the run is startable; no
human approval ceremony is required.

## First-start execution seal

The first build claim invocation creates the immutable execution seal:

  * binding_method = build_start
  * binding_kind = execution_seal
  * binds: run_id, packet SHA, canonical repo, baseline branch, baseline SHA,
    candidate branch, packet schema, packet metadata.

There is no separate approval step. The operator first build claim IS the
authorization to execute the exact bounded packet locally.

## What the operator does NOT do

- No human approval ceremony.
- No confirmation token.
- No program init.
- No manual loop run.
- No manual build claim or finalize or review claim or finalize invocation.
- No manual STATE.json edits.
- No manual receipt or verdict or scratch edits.
- No manual checkpoint advancement.
- No remote mutation.

## Promotion outside Loop

APPROVED means the work is eligible for operator promotion. It does NOT
authorize automatic promotion. Operator promotion is the only authority to:

- merge the candidate branch,
- publish to remote,
- deploy to production,
- create or mutate remotes.

## External authority

Guards refuse ref-mutating subcommands.

Guards refuse publish-to-remote, merge-branch, branch-delete subcommands.

Guards refuse destructive systemctl operations.

Guards refuse human approval command invocation by Claude.

Guards are tool-surface guardrails, not OS sandbox.
Claude policy forbids routing around refusals.

REMOTE_COUNT=0 guarantees no remote destination.
