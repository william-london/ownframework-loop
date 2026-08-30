# OwnFramework Loop

Source/master release line: **0.8.4**

Latest published GitHub Release: **v0.6.0**. The 0.8.x source line is not yet
tagged or published; publication follows integration, exact-head hosted CI, and
the commissioned PROGRAM canary.

OwnFramework Loop is a vendor-neutral, execution-sealed engineering runtime for
autonomous coding agents.

A human defines the SPEC and owns final promotion. Between those boundaries, a
durable supervisor can drive bounded BUILD, REVIEW, repair, and PROGRAM
checkpoint advancement without routine permission prompts or terminal
babysitting.

The deterministic core owns packet authority, source identity, worktrees,
state, exact candidate SHA, evidence, retry/repair budgets, runtime-generation
binding, and promotion boundaries. Agent hosts are adapters.

## Canonical operating model

```text
human SPEC
   |
   v
sealed WORK_PACKET
   |
   v
ofloop supervisor enqueue
   |
   v
durable supervisor
   |
   +--> BUILD semantic pass
   |       |
   |       v
   |    deterministic finalize
   |       |
   +<-- REVIEW exact SHA
   |       |
   |       v
   |    deterministic verdict/finalize
   |       |
   +<-- bounded repair / next PROGRAM checkpoint
   |
   v
APPROVED | BLOCKED | STOPPED
   |
   v
human merge / promotion
```

The supervisor is the canonical execution clock. Interactive agent commands are
optional foreground/debug adapters; they are not the scheduler.

## Install

### 1. Install the core

From a Git checkout or source release:

```bash
bash install.sh
```

The core installs to a versioned user data directory and creates a managed
`ofloop` launcher in `~/.local/bin` by default.

The core install is independent of Claude Code, Codex, or any other agent host.

### 2. Optional host adapter

Claude Code:

```bash
bash install-adapter.sh claude-code
```

Codex:

```bash
bash install-adapter.sh codex
```

Adapters provide host-specific UX only. Installing or removing an adapter does
not own or remove the core runtime.

### 3. Commission the durable supervisor

```bash
bash install-supervisor.sh
```

Platform selection is automatic:

- macOS: per-user launchd service.
- Linux: per-user systemd service. A successful commission proves the user
  service is active now; post-logout/boot persistence is reported diagnostically
  and is not implied unless the host is already configured for user-service
  persistence. Loop does not silently enable privileged linger configuration.
- WSL2: Linux path when systemd user services are available. The Loop user
  service may run while the WSL instance exists; it does not keep the WSL VM
  alive by itself.
- native Windows: not currently a commissioned-supervisor target.

A fresh core install never creates a background service implicitly. Once a
service is deliberately commissioned, later core installs safely refresh that
service to the new runtime generation.

## Normal workflow

Create/inspect the SPEC using your chosen adapter or the core surfaces. Then:

```bash
ofloop supervisor enqueue <repo> <run-id>
ofloop supervisor status <repo> <run-id>
```

If the durable service is commissioned, it consumes the queue automatically.
For foreground operational debugging, `ofloop supervisor serve` runs the same
execution clock in the current shell.

Normal execution does not require a second approval ceremony after the bounded
packet is ready. First legitimate BUILD start creates the immutable execution
seal.

Terminal `APPROVED` means eligible for human promotion. Loop never interprets
APPROVED as authority to push, merge, deploy, publish, pay, send messages, or
mutate unrelated external systems.

## Agent adapters

The core is canonical. Current adapters are:

| Adapter | Status | Role |
| --- | --- | --- |
| Claude Code | stable, live-verified, hardened | first production semantic runner; optional interactive plugin UX |
| Generic CLI | portable contract | vendor-neutral host floor |
| Codex | experimental | portable Agent Skills; live lifecycle hardening not yet claimed |

Claude Code is the first production-hardened runner, not the identity of
OwnFramework Loop.

The supervisor already selects semantic runners through a runner registry.
Adding another live runner must not fork the deterministic dispatch/state
machine.

See:

- `adapters/README.md`
- `docs/architecture/ADAPTER_CONTRACT.md`
- `docs/architecture/PORTABILITY_MODEL.md`
- `docs/ADAPTER_DEVELOPMENT.md`

## Claude Code runner

The commissioned Claude runner currently requires Claude Code **2.1.248 or
newer**. Newer compatible versions are supported; this is a minimum capability
floor, not a pin.

Commissioned BUILD/REVIEW passes use Claude-native controls:

- `--restricted`;
- `--permission-mode dontAsk`;
- exact pre-approved role-specific tools;
- fail-closed sandboxing;
- no unsandboxed-command escape;
- strict MCP isolation;
- no browser/web/subagent surface;
- credential scrubbing;
- packet-bound network read allowlist.

Builder tools:

```text
Read,Edit,Write,NotebookEdit,Bash,Glob,Grep
```

Reviewer tools:

```text
Read,Bash,Glob,Grep
```

The reviewer therefore has no Edit/Write/NotebookEdit source surface.

On Linux/WSL2, Claude's native sandbox requires `bubblewrap` and `socat`.
Supervisor commissioning checks those prerequisites and refuses early if the
sandbox cannot arm. On macOS the native Claude sandbox uses the platform
sandbox implementation.

Claude plugin commands such as `/of-loop:build` and `/of-loop:review` remain
available for foreground/debug work after installing the Claude adapter. They
are not the canonical unattended scheduling mechanism.

## Network authority

`network_read_allowlist` is optional frozen SPEC authority for sandboxed
semantic Bash.

Example:

```json
{
  "network_read_allowlist": [
    "registry.npmjs.org",
    "pypi.org",
    "files.pythonhosted.org"
  ]
}
```

Only exact lowercase hostnames are accepted. No scheme, port, path, or wildcard
is allowed. Empty/omitted means zero outbound network.

The list is mapped directly into the semantic runner's native network sandbox.
It is intended for dependency/download reads, not search, publishing,
deployment, push, or remote mutation.

## Runtime and crash safety

The durable supervisor provides:

- exact runtime-generation binding to serving payload bytes;
- fail-closed cross-generation replacement guards for unfinished work;
- non-destructive RETIRED supervisor enrollment for preserved historical runs;
- exact semantic-attempt ledger and worker logs;
- bounded infrastructure/transient recovery;
- write-ahead STATE/EVENTS recovery;
- verified authority-bearing state reads;
- exact-SHA reviewer preparation;
- no duplicate semantic-worker ownership;
- disposable runtime-cache cleanup after durable DONE.

Runtime refresh/uninstall safety is shared across macOS and Linux rather than
implemented separately by each service manager.

## Repository layout

```text
bin/                         deterministic CLI entrypoint
lib/ownframework_loop/       core protocol + supervisor + runner registry
schemas/                     packet/state/receipt/verdict contracts
templates/                   packet and semantic-result templates
docs/architecture/           vendor-neutral architecture
adapters/                    host adapter contracts/docs
.agents/skills/              portable Agent Skills
.claude-plugin/              optional Claude Code adapter manifest
skills/ agents/ hooks/       Claude adapter surfaces
install.sh                   vendor-neutral core installer
install-adapter.sh           optional host-adapter installer
install-supervisor.sh        platform-neutral service commissioning
install-supervisor-macos.sh  launchd implementation
install-supervisor-linux.sh  systemd-user implementation
tests/                       canonical + adapter/platform regressions
```

## Validation

Source tree:

```bash
bash validate.sh
bash release_gate.sh
```

Installed core:

```bash
bash validate.sh --installed
```

Adapter inspection:

```bash
ofloop adapter list
ofloop adapter doctor generic-cli
ofloop adapter doctor claude-code
ofloop adapter doctor codex --allow-unverified
```

GitHub Actions runs the canonical gates on Ubuntu and macOS with Python 3.12
and 3.13, plus release gates, security checks, Claude adapter validation, and
Codex static distribution proof.

## Compatibility principle

Compatibility data required to read historical Loop artifacts remains.
Deprecated executable paths that can misroute current agents do not.

Current product behavior is defined by the deterministic core, active
architecture docs, canonical tests, and current adapter contracts—not by old
conversation patterns or historical plugin-era workflows.

## License

See `LICENSE`.
