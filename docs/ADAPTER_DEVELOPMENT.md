# Developing an OwnFramework Loop adapter

OwnFramework Loop separates deterministic protocol authority from agent-host UX. An adapter should be thin: it teaches a host how to participate while reusing the same packet, approval, state, Git-SHA, repair, and verdict machinery.

Read [`architecture/ADAPTER_CONTRACT.md`](architecture/ADAPTER_CONTRACT.md) and [`architecture/PORTABILITY_MODEL.md`](architecture/PORTABILITY_MODEL.md) first.

## Start from the generic portability floor

Before copying Claude- or Codex-specific integration code, verify that the host can satisfy the `generic-cli` contract:

1. operate in a Git checkout;
2. invoke local `ofloop` commands;
3. work in the core-selected builder/reviewer surfaces;
4. produce or inspect exact Git commit SHAs;
5. return semantic build/review results through supported core paths.

If those conditions hold, the host can be protocol-compatible even when it has no native Agent Skills, hooks, subagents, marketplace, or loop command.

Then add only the host-native conveniences that are real and evidence-backed.

## What the core owns

Packet parsing, TTY-bound approval binding, lifecycle transitions, locks, budgets, worktree/candidate identity, exact-SHA verdict binding, repair counters, events/receipts, and terminal states.

## What adapters may provide

- discoverable Agent Skills or host-native commands;
- host-specific agents/subagents;
- host-specific hooks or command interception;
- installer/discovery helpers;
- adapter-specific doctor checks;
- presentation of spec/build/review/status operations;
- host-native loop/retry UX when the host provides it.

## What adapters must never reimplement

Do not implement a second approval mechanism, state machine, packet hash, repair counter, candidate identity store, verdict identity store, or promotion mechanism. Do not directly mutate protected run artifacts.

A native host loop may repeatedly invoke the shared core, but it must not become a second source of lifecycle truth.

## Capability declaration

Add a named adapter to `lib/ownframework_loop/adapters.py` only when the repository has a concrete host integration to describe. Capability values represent verified host behavior, not aspiration.

- `protocol_compatible` means the adapter participates in the shared core protocol.
- `hardened` means the host exposes deterministic enforcement primitives for the adapter's declared hard rails.
- `live_verified` means the named adapter has been exercised in a real supported host.

The abstract `generic-cli` entry is different: it represents the vendor-neutral portability floor and intentionally makes no named-host live claim.

## Agent Skills are optional

If a host supports Agent Skills / `SKILL.md`, prefer the portable semantic source under `.agents/skills/` and add only a thin host wrapper when necessary.

If it does not support Agent Skills, use those files as the behavioral reference. Do not fork their state semantics into a host-specific orchestration engine.

## Conformance

A new adapter must prove that it cannot approve its own packet, does not directly own protected run state, hands candidate/review identity through exact Git SHAs, leaves repair/terminal semantics to the core, and gains no push/merge/deploy authority from the loop.

Run `tests/run_adapter_conformance.sh` plus the full repository gates. Named adapters start experimental and become stable only after live host verification, conformance coverage, installation/discovery proof, and documented enforcement differences.

## Good adapter contribution

A useful adapter PR should answer:

- What host and exact version were tested?
- Does it work at the generic CLI layer first?
- Which native features are added beyond the portability floor?
- Which hard rails are deterministic versus instruction-only?
- Can the host discover the portable skills directly?
- What live proof justifies `live_verified=true`?
- What capability remains weaker than the Claude reference adapter?

This makes it possible to add support for new coding-agent hosts without turning OwnFramework Loop into a collection of vendor-specific state machines.
