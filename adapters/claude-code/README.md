# Claude Code adapter — stable reference

Claude Code remains OwnFramework Loop's stable reference adapter.

The existing public experience remains first-class:

- managed plugin `of-loop@ownframework`;
- `/of-loop:spec`;
- `/of-loop:build`;
- `/of-loop:review`;
- custom Claude agents;
- Claude hooks and command interception;
- direct `claude --plugin-dir /path/to/ownframework-loop` evaluation.

The actual plugin surfaces intentionally remain at the repository root (`.claude-plugin/`, `skills/`, `agents/`, and `hooks/`) for backward compatibility. They are not moved merely to make the adapter directory visually complete.

Claude-specific integration may be more hardened than other hosts, but approval, state, budgets, candidate SHA, verdict identity, and promotion remain deterministic-core concerns.
