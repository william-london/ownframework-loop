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

- `claude-code`: stable, live-verified, hardened; first production semantic
  runner and optional interactive plugin adapter.
- `generic-cli`: vendor-neutral portability floor.
- `codex`: experimental Agent Skills adapter; static/distribution evidence
  only until real lifecycle proof exists.

## Promotion

No adapter/runner receives push, merge, deploy, publish, payment, messaging, or
unrelated remote mutation authority from an executable packet.

Terminal APPROVED remains a human promotion gate.
