# Agent Skills portability

OwnFramework Loop uses Agent Skills as a portable presentation layer while keeping protocol authority in the deterministic core.

The canonical host-neutral skills live under `.agents/skills/`:

- `of-loop-spec`
- `of-loop-build`
- `of-loop-review`
- `of-loop-status`

They describe how an agent participates while delegating approval, state transitions, candidate identity, verdict identity, and repair accounting to `ofloop`.

Claude Code remains the stable reference adapter and keeps its public plugin-compatible skill surface under `skills/`; those files may use Claude-specific extensions and are not replaced by the portable copies.

Codex is represented by the portable Agent Skills plus repository `AGENTS.md`. Live Codex discovery/execution remains a separate proof before `live_verified` may become true.

Skills guide behavior; they are not the security boundary. Core validation, Git identity, approval binding, locks/state transitions, and host-specific enforcement provide mechanical authority.
