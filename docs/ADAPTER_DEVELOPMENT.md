# Developing an OwnFramework Loop adapter

OwnFramework Loop separates deterministic protocol authority from agent-host UX.
An adapter should be thin: teach a host how to participate while reusing the
same packet, execution-binding, state, Git-SHA, repair, receipt, and verdict
machinery.

Read:

- [`architecture/ADAPTER_CONTRACT.md`](architecture/ADAPTER_CONTRACT.md)
- [`architecture/PORTABILITY_MODEL.md`](architecture/PORTABILITY_MODEL.md)
- [`architecture/CORE_INVARIANTS.md`](architecture/CORE_INVARIANTS.md)

## Start from the generic portability floor

Before copying Claude- or Codex-specific integration code, prove the host can:

1. operate in a Git checkout;
2. invoke local `ofloop` commands;
3. use core-selected builder/reviewer surfaces;
4. produce/inspect exact Git SHAs;
5. fill semantic result artifacts at exact paths returned by preparation.

If those conditions hold, the host can be protocol-compatible without native
Agent Skills, hooks, subagents, marketplace support, or a built-in loop command.

## What the core owns

- packet parsing/validation;
- spec-time baseline snapshot;
- first-start execution sealing;
- lifecycle transitions and locks;
- scope/runtime/repair/checkpoint budgets;
- candidate branch/worktree identity;
- exact-SHA receipts/verdicts;
- crash reconciliation;
- terminal semantics and promotion boundary.

## What adapters may provide

- discoverable Agent Skills or host-native commands;
- host-specific agents/subagents;
- host-specific hooks/command interception;
- installer/discovery helpers;
- adapter-specific doctor checks;
- native loop/retry/session UX.

## What adapters must never reimplement

Do not implement a second execution-seal mechanism, lifecycle state machine,
packet hash store, repair counter, candidate identity store, verdict identity
store, crash-recovery truth, or promotion mechanism.

A native host loop may repeatedly invoke the shared core, but it must not become
a second lifecycle authority.

## Normal start contract

Normal adapters do not ask for a separate approval/token step.

```text
SPEC → first BUILD claim auto-seals → BUILD/REVIEW lifecycle
```

The historical TTY pre-seal may remain compatibility-only. An adapter must not
make it mandatory or give it a parallel PROGRAM initialization/state path.

## Exact preparation contract

Do not derive worktree/branch/checkpoint/result paths from examples. Consume
`ofloop build prepare` / review preparation outputs exactly. Pass-scoped semantic
result paths are authoritative outputs, not naming conventions for adapters to
reconstruct.

## Capability declaration

Add a named adapter only when there is concrete integration evidence.

- `protocol_compatible`: participates in the shared core protocol.
- `hardened`: named host exposes extra deterministic enforcement for declared
  rails; this is not an OS-sandbox claim.
- `live_verified`: named adapter has been exercised in a real supported host.

The abstract `generic-cli` entry represents a portability floor and therefore
has no named-host live claim.

## Conformance

A new adapter must prove that it:

- uses the shared execution-start path;
- never directly authors protected run state/evidence;
- uses exact candidate/review SHAs;
- leaves repair/terminal semantics to the core;
- gains no push/merge/deploy/external-effect authority from Loop state;
- does not reconstruct deterministic paths/identity from prose.

Run `tests/run_adapter_conformance.sh` plus the full repository gates.

## Contribution questions

A useful adapter change should answer:

- Which host/version was tested?
- Does it work at the generic CLI layer first?
- Which native features are added beyond the portability floor?
- Which rails are mechanical versus instruction-only?
- Can the host discover portable skills directly?
- What evidence justifies `live_verified=true`?
- Which capability remains weaker than the Claude reference adapter?
