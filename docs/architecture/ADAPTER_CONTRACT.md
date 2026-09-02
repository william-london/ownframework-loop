# OwnFramework Loop Adapter and Runner Contract

## Core rule

OwnFramework Loop core is canonical. A host adapter or semantic runner may
participate in a run; it may not reimplement protocol authority.

## Semantic runner contract

The durable supervisor selects a registered runner by ID.

A runner receives one deterministic BUILD or REVIEW work order containing exact
repo/run/worktree/pass identity and the pass-scoped semantic artifact path.

It may:

- inspect the exact prepared context;
- perform the semantic implementation/review permitted by its role;
- write the supplied semantic result;
- return operational usage/result evidence.

It may not choose or mutate:

- canonical repository/baseline;
- worktree/branch identity;
- execution seal;
- lifecycle state;
- candidate SHA;
- pass/repair/checkpoint counters;
- deterministic receipt/verdict;
- promotion authority.

Adding a runner must not require a provider-specific fork of dispatch or the
supervisor FSM.

## Host adapter contract

Adapters may provide:

- plugins/extensions;
- Agent Skills;
- custom agents;
- hooks;
- host discovery/install;
- foreground/debug commands.

Adapters consume supported `ofloop` surfaces. They do not become the durable
execution clock.

## Current adapters/runners

Adapter availability and durable-runner availability are separate claims.

- `claude-code`: stable, live-verified, hardened adapter **and** the only
  currently registered production supervisor runner.
- `generic-cli`: vendor-neutral portability floor; no registered supervisor
  runner implementation.
- `codex`: experimental Agent Skills adapter; no registered supervisor runner
  implementation until authenticated lifecycle/containment proof exists.

The supervisor refuses an unregistered runner at enqueue before durable job
creation.

## Promotion

No adapter/runner receives push, merge, deploy, publish, payment, messaging, or
unrelated remote mutation authority from an executable packet.

Terminal APPROVED remains a human promotion gate.
