# Codex adapter — experimental

The Codex adapter demonstrates that OwnFramework Loop's protocol is not tied to Claude Code.

It is designed to use the portable Agent Skills under `.agents/skills/` plus the repository's `AGENTS.md`, while reusing the same deterministic `ofloop` core as the Claude reference adapter.

## Install

From a clone of this repository:

```bash
bash install-adapter.sh codex
```

The installer is deliberately separate from Claude's `install.sh`. It installs:

- the exact committed OwnFramework Loop source tree under user-local data;
- a managed `ofloop` launcher under `~/.local/bin` by default;
- `of-loop-spec`, `of-loop-build`, `of-loop-review`, and `of-loop-status` under `~/.agents/skills` by default.

All destinations support explicit environment overrides for isolated testing. Existing unmanaged skills, launchers, or install roots are refused rather than overwritten.

Remove the adapter with:

```bash
bash uninstall-adapter.sh codex
```

Restart Codex after installation so its skill inventory can refresh.

## Maturity

`experimental`

GitHub CI installs the current Codex CLI package and proves the adapter's distribution, static contract, portable skill layout, CLI/doctor surface, and shared-core conformance. That is **not** treated as live Codex support.

A real authenticated Codex environment must still prove skill discovery and a disposable spec/build/review lifecycle before the adapter may set `live_verified=true` or claim Claude-equivalent hardening.

The adapter does not own approval, lifecycle state, repair counters, candidate identity, verdict identity, or promotion. It receives no push, merge, deploy, publish, or external-action authority from OwnFramework Loop.
