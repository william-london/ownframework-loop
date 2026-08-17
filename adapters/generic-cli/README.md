# Generic CLI host adapter

The `generic-cli` adapter is OwnFramework Loop's vendor-neutral portability floor.

It is **not** a plugin for a specific AI product. It defines the minimum integration contract for any coding-agent host that can operate in a Git checkout and invoke local commands.

## What a generic host needs

A host can participate through this adapter when it can:

- read the target repository and OwnFramework Loop run artifacts through supported interfaces;
- invoke the local `ofloop` CLI (or `./bin/ofloop` from a source checkout);
- edit and commit work in the bounded builder worktree selected by the core;
- review an exact Git commit SHA;
- return build/review results through the supported core paths.

No vendor API, plugin marketplace, native subagent system, hook API, or built-in loop command is required for protocol compatibility.

## What remains human-only

The agent must not:

- execute `ofloop spec approve` for the human;
- directly edit `STATE.json`, `APPROVAL.json`, `REVIEW_VERDICT.json`, locks, or event logs;
- push, merge, deploy, publish, send, charge, or widen remotes because a run exists;
- reinterpret `APPROVED` as promotion authority.

The human performs approval from an interactive terminal and separately decides whether to promote the reviewed candidate.

## Portable skills are optional acceleration

If the host understands Agent Skills / `SKILL.md`, point it at:

```text
.agents/skills/of-loop-spec/SKILL.md
.agents/skills/of-loop-build/SKILL.md
.agents/skills/of-loop-review/SKILL.md
.agents/skills/of-loop-status/SKILL.md
```

If the host does not implement Agent Skills, use those files as the semantic reference for a thin host-specific wrapper. Do not copy their behavior into a second state machine.

## Inspect the portability contract

From an OwnFramework Loop checkout:

```bash
./bin/ofloop adapter show generic-cli
./bin/ofloop adapter doctor generic-cli
```

The generic adapter is intentionally reported as:

```text
maturity=portable
protocol_compatible=true
hardened=false
live_verified=false
```

`live_verified=false` is not a failure here: `generic-cli` names no specific host. It is the baseline protocol surface that named adapters build on.

## Claude Code remains the reference experience

OwnFramework Loop was developed around a Claude Code loop workflow and remains optimized for Claude's native plugin, skills, agents, hooks, and command interception. The generic adapter exists so those vendor-specific advantages remain optional rather than becoming dependencies of the deterministic protocol.

See also:

- [`../../docs/architecture/PORTABILITY_MODEL.md`](../../docs/architecture/PORTABILITY_MODEL.md)
- [`../../docs/architecture/ADAPTER_CONTRACT.md`](../../docs/architecture/ADAPTER_CONTRACT.md)
- [`../../docs/ADAPTER_DEVELOPMENT.md`](../../docs/ADAPTER_DEVELOPMENT.md)
