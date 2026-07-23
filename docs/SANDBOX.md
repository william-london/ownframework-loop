# Claude Bash Sandbox — Required for Supervised V1 Pilot

> The OwnFramework Loop V1 supervised-local-only pilot REQUIRES Claude's
> Bash sandbox to be enabled with `failIfUnavailable=true`. The first
> pilot runs with `network=deny` as a default.

## Activation steps (session-only — does not modify global settings)

Per official Claude Code documentation, the sandbox is enabled per
session by passing the appropriate flag at launch. We document the
activation path; the loop refuses to start without it.

```bash
# Activate per-session. Safe — does NOT modify ~/.claude/settings.json.
claude --plugin-dir /Users/mr.ms.london/.claude/skills/of-loop \
      --sandbox \
      --sandbox-fail-if-unavailable \
      --network-default deny
```

The `--sandbox-fail-if-unavailable` flag (or its equivalent documented
setting) ensures the session **fails closed** if the sandbox cannot be
activated — never silently falling back to unsandboxed execution.

## Filesystem write scope

When the sandbox is active, writes are confined to:

- The approved builder worktree (`.worktrees/ownframework-loop/<run-id>/builder/`).
- The per-run loop state directory (`.ownframework-loop/<run-id>/`).
- Temporary directories explicitly granted by the user.

Any attempt to write outside these paths is refused at the OS layer
and triggers `SANDBOX_VIOLATION` in the event chain.

## Network default

For the first supervised pilot, `network=deny` is the default. This
forces the loop to prove itself in a fully air-gapped mode before any
network access is granted.

## Why this matters

The textual hook cannot be 100% reliable against shell indirection
forms. The sandbox is the OS-level safety net. The post-pass
verification catches any remaining violations before acceptance.
Together, they cover the bypass surface that the textual hook alone
cannot.

## Required markers

The release gate emits:

- `SANDBOX_REQUIRED=yes`
- `SANDBOX_AVAILABLE=yes`
- `SANDBOX_FAIL_CLOSED=yes`
- `NETWORK_DEFAULT=deny`
- `UNSANDBOXED_FALLBACK=no`

These markers are emitted by `release_gate.sh` after consulting the
session's documented configuration. If the markers are absent, the
release gate fails.
