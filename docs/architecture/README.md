# Adapter architecture

OwnFramework Loop separates a deterministic, agent-neutral engineering protocol
from agent-host adapters.

- [`CORE_INVARIANTS.md`](CORE_INVARIANTS.md) — non-negotiable execution-binding,
  source/SHA, repair, state, crash-recovery, and promotion guarantees.
- [`ADAPTER_CONTRACT.md`](ADAPTER_CONTRACT.md) — core versus adapter
  responsibilities and capability model.
- [`CAPABILITY_MATRIX.md`](CAPABILITY_MATRIX.md) — current adapter maturity and
  host-enforcement differences.
- [`AGENT_SKILLS.md`](AGENT_SKILLS.md) — portable Agent Skills layout and shared
  SPEC/BUILD/REVIEW/STATUS semantics.
- [`PORTABILITY_MODEL.md`](PORTABILITY_MODEL.md) — deterministic core, portable
  skills, and native-adapter layers.

Claude Code is the stable/reference adapter. Additional adapters must reuse the
same execution-start, packet/source binding, lifecycle state, exact-SHA review,
repair/checkpoint budgets, crash reconciliation, and operator-promotion
boundary.

Normal operation has no mandatory approval ceremony. Adapter convenience must
never reintroduce a second approval/state/PROGRAM truth.
