# Claude Code Adapter

Claude Code is OwnFramework Loop's first stable, live-verified, hardened
semantic runner and an optional interactive adapter.

It is **not** the owner of the OwnFramework Loop core runtime or durable
scheduler.

## Install

```bash
./install.sh
./bin/install-adapter claude-code
```

The adapter installs the `of-loop@ownframework` Claude plugin. The core remains
in OwnFramework Loop's versioned user-data runtime.

## Interactive surfaces

- `/of-loop:spec`
- `/of-loop:build`
- `/of-loop:review`
- custom Claude agents/hooks

BUILD/REVIEW slash commands are foreground/debug coordinators. Canonical
unattended scheduling is supervisor enqueue + durable service.

## Commissioned runner

Claude Code 2.1.248+ is required for the hardened unattended boundary.
Commissioned passes use native restricted mode, dontAsk, exact role tools,
fail-closed sandboxing, strict MCP isolation, credential scrubbing, and frozen
packet network-read authority.

Interactive plugin capability is broader than commissioned runner authority.
Do not infer supervisor permissions from an ordinary Claude session.
