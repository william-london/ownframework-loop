# OwnFramework Loop adapter contract

OwnFramework Loop is an execution-sealed engineering protocol. An adapter gives
a coding-agent host a native way to participate; it does not own protocol
authority.

Claude Code remains the stable/reference adapter. `generic-cli` defines the
portable floor. Codex remains experimental until live host evidence closes its
host-specific claims.

## Core authority

The deterministic core owns:

- work-packet parsing and validation;
- spec-time source baseline capture;
- first-start execution sealing;
- lifecycle transitions and locks;
- scope/runtime/repair/checkpoint budgets;
- candidate branch/worktree identity;
- exact candidate Git SHA and build receipt;
- exact-SHA review/verdict binding;
- crash reconciliation;
- terminal semantics and the promotion boundary.

Adapters call supported `ofloop` surfaces. They must not directly author or
patch `STATE.json`, the compatibility-named execution binding
(`APPROVAL.json`), `BUILD_RECEIPT.json`, `REVIEW_VERDICT.json`, locks, or event
logs in real runs.

## Adapter operations

- **SPEC** — turn a mission into a bounded validated packet and return a run ID
  plus the canonical builder/reviewer launch commands.
- **BUILD** — invoke the shared build-claim/preparation/finalization path. First
  build start may create the execution seal.
- **REVIEW** — wait until review is claimable, inspect the exact candidate SHA,
  and return semantic review input through the supported deterministic path.
- **STATUS** — display core-owned state/evidence without mutating it.

There is no adapter-specific approval capability in normal operation. The
historical TTY pre-seal is compatibility-only and may not become a parallel
start/state/PROGRAM initialization path.

## Minimum host contract

A host does not need native plugins, hooks, Agent Skills, subagents, or a built-
in loop command. The portability floor requires only that it can:

1. operate in a Git checkout;
2. invoke supported local `ofloop` commands;
3. use the core-selected builder/reviewer surfaces;
4. produce/inspect exact Git SHAs;
5. fill semantic result artifacts at exact paths returned by deterministic
   preparation.

The host must not reconstruct baseline SHA, candidate branch, worktree,
checkpoint identity, or pass-scoped result paths from prose.

## Capability declaration

Adapters declare capabilities such as maturity, Agent Skills, native hooks,
subagents, command interception, installation mode, protocol compatibility,
hardening, and live verification.

- `protocol_compatible=true` means the adapter participates in the shared
  execution-seal/state/SHA/verdict protocol.
- `hardened=true` means the named host provides additional deterministic
  enforcement for its declared hard rails. It does not mean OS sandboxing.
- `live_verified=true` requires real evidence in that named host.

## Maturity

- **portable** — vendor-neutral CLI compatibility floor.
- **experimental** — named adapter exists, but live/hard-enforcement evidence is
  incomplete.
- **stable** — documented native UX, deterministic conformance, maintained
  compatibility, and live host proof.
- **planned** — design intent only.

## Non-negotiable adapter rule

Adapt the host to the core. Do not fork the core into host-specific execution
sealing, lifecycle state, repair counters, candidate identity, verdict identity,
or promotion authority.

See [`PORTABILITY_MODEL.md`](PORTABILITY_MODEL.md) and
[`CAPABILITY_MATRIX.md`](CAPABILITY_MATRIX.md).
