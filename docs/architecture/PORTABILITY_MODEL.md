# Portability model

OwnFramework Loop separates the deterministic engineering protocol from the UX of any one coding-agent host.

The project was originally developed around a Claude Code loop workflow. Claude Code remains the stable reference adapter because its plugin, skill, agent, hook, and command-interception surfaces can provide the richest native experience. Portability is additive: the core does not require those Claude-specific capabilities.

## Three compatibility layers

### 1. Deterministic protocol core

This is the portability floor.

A coding agent can participate if its host can operate in a Git checkout and invoke the supported `ofloop` CLI. The core owns:

- work-packet validation;
- interactive human approval and packet-hash binding;
- lifecycle state;
- locks and budgets;
- isolated candidate handling;
- exact candidate Git SHA;
- exact-SHA review/verdict binding;
- repair accounting and terminal semantics;
- the boundary before human promotion.

A host does not need a plugin marketplace, native subagents, Agent Skills, hooks, or a built-in loop command to be protocol-compatible.

### 2. Portable Agent Skills

Hosts that understand Agent Skills / `SKILL.md` can consume the portable semantic wrappers under `.agents/skills/`.

Those skills describe SPEC, BUILD, REVIEW, and STATUS while delegating state authority to the same deterministic core. They are an interoperability convenience, not a second execution engine.

A host that does not implement Agent Skills can use the same files as the reference for a thin wrapper or prompt surface.

### 3. Native host adapters

Named adapters may add host-specific UX and enforcement without changing protocol authority.

Examples:

- Claude Code: plugin packaging, namespaced commands, custom agents, hooks, command interception, native loop-oriented workflow.
- Codex: portable Agent Skills and adapter distribution, currently experimental.

Native features can make an adapter easier to install, more automated, or more hardened. They do not change what the core owns.

## Compatibility levels

- **portable** — the vendor-neutral CLI contract is available. This is not a claim about a specific host's native features.
- **experimental** — a named host adapter exists, but one or more live-host or hard-enforcement claims remain incomplete.
- **stable** — a named adapter has documented UX, deterministic conformance, live-host proof, and maintained compatibility.

`protocol_compatible=true` means the adapter reuses the shared packet/state/SHA/verdict protocol.

`hardened=true` is a stronger host-specific claim. It requires deterministic host primitives for the declared hard rails. Protocol compatibility does not imply hardening.

`live_verified=true` applies to named hosts that have been exercised in a real supported environment. The abstract `generic-cli` portability floor intentionally remains `live_verified=false` because it names no single host.

## Generic host rule

A future host integration should start from `generic-cli`, not from Claude or Codex internals.

If the host can:

1. read repository context;
2. invoke local commands;
3. work inside the core-selected Git worktree;
4. produce a candidate commit;
5. review an exact candidate SHA;

then it can integrate with OwnFramework Loop without forking approval, state, repair, candidate, or verdict semantics.

The adapter can then add native skills, commands, agents, hooks, or installers only where the host genuinely supports them.

## What portability does not promise

OwnFramework Loop does not claim that every coding agent exposes identical controls, security boundaries, or automation primitives.

In particular:

- a plain CLI-capable host may be protocol-compatible but not hardened;
- a host without command interception cannot be described as enforcing the same rails as Claude Code;
- a host without Agent Skills may require a thin wrapper or explicit instructions;
- host authentication, model quality, context limits, and provider behavior remain outside the deterministic core.

The compatibility promise is therefore about a shared engineering protocol, not identical vendor behavior.
