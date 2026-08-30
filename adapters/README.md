# Agent Host Adapters

OwnFramework Loop core, installed runtime, and durable supervisor are
vendor-neutral. Adapters add optional host-specific UX.

Current adapters:

- [claude-code](claude-code/) — stable/live/hardened Claude integration and the
  first production semantic runner.
- [generic-cli](generic-cli/) — vendor-neutral portability contract.
- [codex](codex/) — experimental Agent Skills integration.

Adapters do not own execution sealing, lifecycle state, repair/checkpoint
counters, exact candidate SHA, verdict finalization, runtime generation, or
promotion.

Install core first (or let the adapter installer idempotently ensure it):

```bash
bash install.sh
bash install-adapter.sh claude-code
# or
bash install-adapter.sh codex
```

Removing an adapter preserves the core runtime.

See `docs/architecture/ADAPTER_CONTRACT.md` and
`docs/ADAPTER_DEVELOPMENT.md`.
