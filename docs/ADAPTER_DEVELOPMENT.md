# Developing an OwnFramework Loop adapter

OwnFramework Loop separates deterministic protocol authority from agent-host UX. An adapter should be thin: it teaches a host how to participate while reusing the same packet, approval, state, Git-SHA, repair, and verdict machinery.

Read [`architecture/ADAPTER_CONTRACT.md`](architecture/ADAPTER_CONTRACT.md) first.

## What the core owns

Packet parsing, TTY-bound approval binding, lifecycle transitions, locks, budgets, worktree/candidate identity, exact-SHA verdict binding, repair counters, events/receipts, and terminal states.

## What adapters may provide

- discoverable Agent Skills or host-native commands;
- host-specific agents/subagents;
- host-specific hooks or command interception;
- installer/discovery helpers;
- adapter-specific doctor checks;
- presentation of spec/build/review/status operations.

## What adapters must never reimplement

Do not implement a second approval mechanism, state machine, packet hash, repair counter, candidate identity store, verdict identity store, or promotion mechanism. Do not directly mutate protected run artifacts.

## Capability declaration

Add the adapter to `lib/ownframework_loop/adapters.py`. Capability values describe verified host behavior, not aspiration.

- `protocol_compatible` means the adapter participates in the shared core protocol.
- `hardened` means the host exposes deterministic enforcement primitives for the adapter's declared hard rails.
- `live_verified` means the adapter has been exercised in a real supported host.

## Conformance

A new adapter must prove that it cannot approve its own packet, does not directly own protected run state, hands candidate/review identity through exact Git SHAs, leaves repair/terminal semantics to the core, and gains no push/merge/deploy authority from the loop.

Run `tests/run_adapter_conformance.sh` plus the full repository gates. New adapters start experimental and become stable only after live host verification, conformance coverage, installation/discovery proof, and documented enforcement differences.
