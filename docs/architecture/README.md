# Architecture Index

OwnFramework Loop's architecture is vendor-neutral. The deterministic core and
durable supervisor are canonical; agent hosts integrate through adapters and a
semantic-runner registry.

Read:

- [../ARCHITECTURE.md](../ARCHITECTURE.md) — product-level architecture.
- [CORE_INVARIANTS.md](CORE_INVARIANTS.md) — deterministic authority.
- [SUPERVISOR_MODEL.md](SUPERVISOR_MODEL.md) — durable queue/process/runtime generation.
- [ADAPTER_CONTRACT.md](ADAPTER_CONTRACT.md) — host/runner boundary.
- [PORTABILITY_MODEL.md](PORTABILITY_MODEL.md) — cross-host/platform portability.
- [CAPABILITY_MATRIX.md](CAPABILITY_MATRIX.md) — current adapter evidence.
- [AGENT_SKILLS.md](AGENT_SKILLS.md) — optional skill surfaces.

Claude Code is currently the first production-hardened/live semantic runner.
That fact does not make Claude the product identity or the owner of core state,
installation, scheduling, or promotion.
