# Agent Host Adapters

OwnFramework Loop core, installed runtime, and durable supervisor are
vendor-neutral. Adapters add optional host-specific UX.

Current adapters:

| Adapter | Adapter maturity | Durable supervisor runner |
| --- | --- | --- |
| [claude-code](claude-code/) | stable / live / hardened | yes |
| [generic-cli](generic-cli/) | portable contract | no |
| [codex](codex/) | experimental Agent Skills | no |

Adapter support means the host can consume OwnFramework Loop contracts through
that integration surface. Durable supervisor support is a separate, stricter
claim. The current live runner registry contains only `claude-code`; installing
the Codex adapter does not make `--runner codex` executable.

Adapters do not own execution sealing, lifecycle state, repair/checkpoint
counters, exact candidate SHA, verdict finalization, runtime generation, or
promotion.

Install core first (or let the adapter installer idempotently ensure it):

```bash
./install.sh
./bin/install-adapter claude-code
# or
./bin/install-adapter codex
```

Removing an adapter preserves the core runtime.

See `docs/architecture/ADAPTER_CONTRACT.md` and
`docs/ADAPTER_DEVELOPMENT.md`.
