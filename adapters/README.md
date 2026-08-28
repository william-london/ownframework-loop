# Agent adapters

Adapters connect coding-agent hosts to the same OwnFramework Loop deterministic
protocol.

- [`claude-code/`](claude-code/) — stable/reference adapter with native plugin,
  skills, agents, and tool-surface hooks.
- [`generic-cli/`](generic-cli/) — vendor-neutral portability floor.
- [`codex/`](codex/) — experimental Agent Skills adapter; live lifecycle proof
  remains separate evidence.

Adapters do not own execution sealing, lifecycle state, repair/checkpoint
counters, baseline/candidate/worktree identity, exact-SHA verdict identity,
crash reconciliation, or promotion.

Normal lifecycle semantics are shared:

```text
SPEC → first BUILD start auto-seals → BUILD/REVIEW → terminal result
```

See [`docs/architecture/ADAPTER_CONTRACT.md`](../docs/architecture/ADAPTER_CONTRACT.md)
and [`docs/ADAPTER_DEVELOPMENT.md`](../docs/ADAPTER_DEVELOPMENT.md).
