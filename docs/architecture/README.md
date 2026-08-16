# Adapter architecture

OwnFramework Loop separates a deterministic, agent-neutral engineering protocol from agent-host adapters.

- [`CORE_INVARIANTS.md`](CORE_INVARIANTS.md) — non-negotiable approval, SHA, repair, state, and promotion guarantees.
- [`ADAPTER_CONTRACT.md`](ADAPTER_CONTRACT.md) — core versus adapter responsibilities and capability model.
- [`CAPABILITY_MATRIX.md`](CAPABILITY_MATRIX.md) — current adapter maturity and host-enforcement differences.
- [`AGENT_SKILLS.md`](AGENT_SKILLS.md) — portable Agent Skills layout.
- [`PORTABILITY_NOTES.md`](PORTABILITY_NOTES.md) — what is portable now versus host-specific.

Claude Code is the stable reference adapter. Additional adapters must reuse the same core contract without weakening approval, exact-SHA review, repair budgets, terminal states, or human promotion.
