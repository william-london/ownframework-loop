# Portability model

OwnFramework Loop separates deterministic engineering authority from the UX of
any one coding-agent host.

Claude Code remains the stable/reference adapter because its plugin, skills,
agents, hooks, and loop-oriented UX provide the richest native experience. The
core itself does not require Claude-specific capabilities.

## Three compatibility layers

### 1. Deterministic protocol core

This is the portability floor. A host that can operate a Git checkout and invoke
`ofloop` can participate.

The core owns:

- packet validation;
- spec-time baseline capture;
- automatic first-start execution sealing;
- lifecycle state and locking;
- bounded build/review/repair/checkpoint counters;
- candidate branch/worktree identity;
- exact candidate Git SHA and build receipt;
- exact-SHA review/verdict identity;
- crash reconciliation and terminal semantics;
- the boundary before operator promotion.

No mandatory confirmation token, approval ceremony, or PROGRAM-init ceremony is
part of the normal portable contract.

### 2. Portable Agent Skills

Hosts that understand Agent Skills / `SKILL.md` may consume:

```text
.agents/skills/of-loop-spec/
.agents/skills/of-loop-build/
.agents/skills/of-loop-review/
.agents/skills/of-loop-status/
```

Those files describe SPEC/BUILD/REVIEW/STATUS while delegating all authoritative
state and identity to the deterministic core. They are a presentation layer, not
a second execution engine.

### 3. Native host adapters

A named adapter may add host-specific UX/enforcement without changing protocol
authority.

Examples:

- Claude Code: managed plugin, native skills/agents/hooks, command interception,
  `/loop`-oriented UX.
- Codex: portable Agent Skills and adapter distribution; currently experimental.

Native features may make an adapter easier to install, more automated, or more
hardened. They do not get their own execution seal, lifecycle state, candidate
identity, or verdict machinery.

## Compatibility levels

- **portable** — vendor-neutral CLI contract is available.
- **experimental** — named adapter exists, but some live/hard-enforcement claims
  remain incomplete.
- **stable** — named adapter has documented UX, deterministic conformance, live
  host proof, and maintained compatibility.

`protocol_compatible=true` means the adapter reuses the shared
packet/execution-binding/state/SHA/verdict protocol.

`hardened=true` is a stronger host-specific claim about mechanical rails. It
never means arbitrary same-user code is OS-contained.

`live_verified=true` applies only to named hosts exercised in a real supported
environment. The abstract `generic-cli` portability floor intentionally has no
named-host live claim.

## Generic host rule

Start from `generic-cli`, not Claude/Codex internals.

A generic host should:

1. create/validate a spec using supported CLI/core surfaces;
2. call build claim (which may auto-seal first start);
3. consume `build prepare` output exactly;
4. use the returned worktree/branch/checkpoint/result-path identity verbatim;
5. commit the bounded candidate;
6. finalize build deterministically;
7. review the exact candidate SHA;
8. return semantic review data at the supported path;
9. leave promotion outside Loop.

Do not reconstruct pass-scoped scratch paths or branch/worktree names from
examples or documentation text.

## What portability does not promise

OwnFramework Loop does not claim every coding-agent host has identical command
interception, security boundaries, authentication, model quality, context
limits, or loop primitives.

The compatibility promise is a shared deterministic engineering protocol—not
identical vendor behavior.
