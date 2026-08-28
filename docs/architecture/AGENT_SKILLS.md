# Agent Skills portability

OwnFramework Loop uses Agent Skills as a portable presentation layer while
keeping protocol authority in the deterministic core.

Canonical host-neutral skills:

- `.agents/skills/of-loop-spec`
- `.agents/skills/of-loop-build`
- `.agents/skills/of-loop-review`
- `.agents/skills/of-loop-status`

They describe how an agent participates while delegating execution sealing,
state transitions, candidate/worktree identity, verdict identity, crash
reconciliation, and repair accounting to `ofloop`.

## Shared semantics

- **SPEC** creates/validates a bounded packet and returns a run ID plus canonical
  builder/reviewer launch commands. It does not require a normal approval step.
- **BUILD** treats the unstarted compatibility state as `READY_TO_START`; first
  build claim may create the immutable execution seal.
- **REVIEW** waits before first start and reviews only when a candidate is
  reviewable.
- **STATUS** is read-only and reports core-owned evidence.

Claude Code remains the stable/reference adapter and keeps its plugin-compatible
skill surface under `skills/`. Those files may use Claude-specific extensions,
but their lifecycle semantics must match the portable skills.

Codex uses the portable skills plus repository `AGENTS.md`; live Codex execution
remains a separate proof before `live_verified` can become true.

Skills guide behavior; they are not the security boundary. Mechanical authority
comes from execution binding, locks/state transitions, deterministic worktree/SHA
identity, finalizers, exact-pass reconciliation, host guards, and the promotion
boundary.
