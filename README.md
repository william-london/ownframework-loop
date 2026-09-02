# OwnFramework Loop

Source/master release line: **0.9.1**

Latest published GitHub Release: **v0.8.4** at
`134a7ce543e2d5858b3a4613c49d49959fe0b029`. The 0.9.1 source line is closed
and validated on `master`; GitHub Release publication is a separate
distribution step.

OwnFramework Loop is a vendor-neutral, execution-sealed engineering runtime for
autonomous coding agents.

Semantic work packets may also declare portable host capabilities (toolchains,
package managers, browser runtimes, local-service authority, or privileged
container authority). The trusted core resolves and receipts the exact host
implementation before launching the model; packets never gain authority by
naming arbitrary HOME paths or daemon sockets. See
`docs/architecture/HOST_CAPABILITIES.md`.

A human defines the SPEC and owns final promotion. Between those boundaries, a
durable supervisor can drive bounded BUILD, REVIEW, repair, and PROGRAM
checkpoint advancement without routine permission prompts or terminal
babysitting.

The deterministic core owns packet authority, source identity, worktrees,
state, exact candidate SHA, evidence, retry/repair budgets, runtime-generation
binding, and promotion boundaries. Agent hosts are adapters.

## Canonical operating model

v0.9.1 concurrency is workspace-scoped. Repository identity is the resolved Git
common directory used for provenance/grouping; execution ownership is that
repository identity plus the run-frozen candidate branch. Different candidate
workspaces in the same Git repository may run concurrently—even when they
modify the same logical paths. One run still owns exactly one semantic pass at
a time, and shared `git worktree` administration is briefly serialized.
`max_concurrency` is the operator's bounded host-resource ceiling. Human
promotion decides how divergent candidate histories are integrated.


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
./install.sh
```

The core installs to a versioned user data directory and creates a managed
`ofloop` launcher in `~/.local/bin` by default.

The core install is independent of Claude Code, Codex, or any other agent host.

### 2. Optional host adapter

Claude Code:

```bash
./bin/install-adapter claude-code
```

Codex:

```bash
./bin/install-adapter codex
```

Adapters provide host-specific UX only. Installing or removing an adapter does
not own or remove the core runtime.

### 3. Commission the durable supervisor

```bash
./bin/install-supervisor
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

| Adapter | Status | Durable supervisor runner | Role |
| --- | --- | --- | --- |
| Claude Code | stable, live-verified, hardened | yes | first production semantic runner; optional interactive plugin UX |
| Generic CLI | portable contract | no | vendor-neutral host floor |
| Codex | experimental | no | portable Agent Skills; live lifecycle hardening not yet claimed |

Claude Code is the first production-hardened runner, not the identity of
OwnFramework Loop. Adapter installation and durable-runner availability are
different contracts: installing the Codex adapter does not register a Codex
supervisor runner.

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
- packet- and capability-bound effective network allowlist;
- immutable run-level capability/environment binding;
- trusted named runner profiles for model/effort only;
- native per-pass cost narrowing when an operator funds a run ceiling.

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

### Model selection is packet/profile truth

Commissioned semantic workers intentionally do **not** inherit interactive
user/project/local Claude settings, including `~/.claude/settings.json`.
Restricted execution receives only Loop-owned worker settings. This prevents an
unreviewed local setting from silently changing model, tools, MCP, sandbox, or
other authority after a packet was prepared.

Every newly authored current packet should therefore carry `runner_profile`
explicitly. `"default"` means the operator intentionally accepts the live
runner's provider default; it does **not** mean "reuse whatever model my
interactive Claude session currently uses." To pin MiniMax, Qwen, Claude, or
another model reachable through the commissioned Claude CLI, put the exact
provider model selector in an operator-owned named runner profile and put only
that profile name in the packet. Provider endpoint/authentication and model
alias environment belong in the private commissioned service environment, not
in the packet.

A named profile is resolved and bound before provider execution. When it names
an explicit model, the provider-reported effective model must match or the pass
is refused as unproven/substituted quality.

See `templates/runner-profiles.example.json` and
`docs/architecture/HOST_CAPABILITIES.md`.

## Network and host capability authority

A packet may declare portable capability names and optional extra read-only
network hosts:

```json
{
  "capabilities": ["toolchain.python", "package.uv", "browser.playwright.chromium"],
  "runner_profile": "default",
  "network_read_allowlist": ["docs.example.com"]
}
```

Packets never contain Mac/Homebrew/runtime paths. The trusted host capability
plane resolves exact executables, versions, SHA-256 identities, trusted assets,
cache policy, privileged commissioning evidence, and capability-required
download domains before a model process can start.

Effective sandbox domains are the union of the packet's exact lowercase
`network_read_allowlist` and domains derived by the resolved capability
contracts. That effective set is frozen into `CAPABILITY_BINDING.json` at the
first semantic execution and must exact-match on every later BUILD/REVIEW/repair
attempt. Empty packet network authority therefore means "no extra packet
domains"; a declared package/browser capability may still contribute its
narrow required read endpoints.

Neither source grants WebSearch/WebFetch, MCP, push, publish, deploy, registry
publication, or remote mutation authority. Privileged capabilities such as
`container.docker` require operator-owned canary commissioning and remain
broker-only.

Use `ofloop capabilities probe`, `preflight`, `profile`, and
`commission` to inspect/commission the host layer without a semantic model
call. Physical-host commissioning is separate from source support.

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
bin/                         CLI + operator-facing setup commands
lib/ownframework_loop/       core protocol + supervisor + runner registry
schemas/                     packet/state/receipt/verdict contracts
templates/                   current packet and semantic-result templates
docs/architecture/           vendor-neutral architecture
adapters/                    host adapter contracts/docs
.agents/skills/              portable Agent Skills
.claude-plugin/              optional Claude Code adapter manifest
skills/ agents/ hooks/       Claude adapter surfaces
scripts/supervisor/          platform service implementation details
install.sh / uninstall.sh    vendor-neutral core lifecycle
validate.sh / release_gate.sh canonical validation entrypoints
tests/                       canonical + adapter/platform regressions
```

## Validation

Source tree:

```bash
./validate.sh
./release_gate.sh
```

Installed core:

```bash
./validate.sh --installed
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
