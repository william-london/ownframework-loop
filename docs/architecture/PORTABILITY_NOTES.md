# Portability notes

## Portable core

The work packet and approval binding, lifecycle transitions, budgets, worktree/candidate Git SHA, exact-SHA review/verdict binding, terminal state, and promotion boundary are host-neutral.

## Host-specific integration

Claude Code remains the stable reference adapter because it has a mature plugin surface, custom agents, and deterministic hooks already used by OwnFramework Loop.

Codex is experimental: it can consume the portable Agent Skills contract, but the repository does not claim Claude-equivalent hard enforcement until a real Codex environment proves it.

## Future adapters

Copilot, Cursor, Gemini CLI, OpenCode, or other hosts should reuse the same core/capability contract rather than fork the state machine. New adapters start experimental and must pass conformance before being advertised as supported.

Mixed-agent build/review is structurally possible because the handoff is deterministic evidence—approved packet hash, candidate Git SHA, and SHA-bound verdict—not shared model context. Automatic cross-vendor spawning is intentionally out of scope for v0.4.0.
