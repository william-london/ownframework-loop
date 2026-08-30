# OwnFramework Loop

> Deterministic, execution-sealed engineering loops for AI coding agents.

OwnFramework Loop turns a bounded engineering mission into a repeatable
build/review protocol. It seals the exact work packet and source baseline when
execution starts, lets a builder work inside deterministic scope and budgets,
reviews the exact resulting Git SHA, bounds repair cycles, and stops before
promotion or external effects.

**Born on Claude Code. Not locked to Claude Code.**

## The operator experience

SPEC remains human-originated. After a valid packet exists, normal execution
has no approval ceremony.

### Unattended / background

```text
/of-loop:spec <mission>
        ↓
ofloop supervisor enqueue <repo> <run-id>
ofloop supervisor serve
        ↓
fresh builder only when BUILD is actionable
fresh reviewer only when REVIEW is actionable
        ↓
APPROVED | BLOCKED | STOPPED
        ↓
operator decides promotion outside Loop
```

The supervisor is a durable execution clock, not a second engineering state
machine. While idle it makes zero model calls. It asks the deterministic
dispatch boundary for one typed BUILD / REVIEW / WAIT / TERMINAL decision and
launches a fresh agent process only for semantic work.

### Interactive / foreground

Claude Code users may still run:

```text
/loop /of-loop:build <run-id>
/loop /of-loop:review <run-id>
```

Those commands remain useful foreground/debug UX over the same core; `/loop`
is not the canonical overnight scheduler.

There is **no mandatory approval command, confirmation token, `program init`,
manual claim/finalize ceremony, or manual checkpoint advancement**.

The first legitimate build start is the authorization to perform the exact
bounded local engineering mission. At that moment the deterministic core
creates an immutable execution seal that binds:

- exact `WORK_PACKET.md` bytes / SHA-256;
- canonical repository identity;
- spec-time baseline branch and exact baseline SHA;
- deterministic candidate branch;
- packet schema, scope, and risk metadata;
- PROGRAM graph provenance when PROGRAM mode is used.

Starting a run does **not** grant push, merge, deploy, publish, payment,
message-sending, remote mutation, or unrelated external-action authority.

## Why it exists

Coding agents are good at implementation. Long-running engineering work still
needs machine-readable answers to different questions:

- What exact mission and source baseline were sealed for execution?
- What paths and budgets apply?
- What immutable candidate SHA did the builder produce?
- Did the reviewer inspect that exact SHA?
- How many build/review/repair passes remain?
- Did a crash leave durable evidence that can be reconciled safely?
- Is the result merely protocol-approved, or actually promoted?

OwnFramework Loop makes those boundaries deterministic.

## Core protocol

```text
mission
  ↓
work packet
  ↓
execution seal (packet + source baseline + candidate branch)
  ↓
bounded builder
  ↓
exact candidate Git SHA + BUILD_RECEIPT
  ↓
exact-SHA reviewer + REVIEW_VERDICT
  ↓
APPROVED / CHANGES_REQUESTED / BLOCKED / STOPPED
  ↓
operator promotion outside the loop
```

Core invariants:

1. First execution start seals exact packet/source identity once.
2. Source movement between spec creation and first start is refused.
3. Packet mutation after sealing is refused; changed scope requires a new run.
4. Build/review claims are serialized and idempotent.
5. Builders operate only inside bounded packet scope and budgets.
6. Candidate identity is an exact Git SHA from a clean deterministic worktree.
7. Review binds to that exact SHA, not arbitrary current filesystem state.
8. Repair cycles and PROGRAM checkpoint budgets are finite.
9. Crash reconciliation adopts only exact current-pass evidence.
10. `APPROVED` never means permission to push, merge, deploy, publish, pay, send,
    or mutate unrelated external systems.

The historical `APPROVAL.json` filename and `tty_confirmation` method remain
compatibility surfaces for old runs/users. For new runs the file is an
**execution-binding artifact**, normally created with:

```text
approval_method=build_start
binding_kind=execution_seal
```

The compatibility field names do not imply that a human typed a token.

## Claude Code quickstart

Claude Code is the stable/reference adapter.

### Install

```bash
git clone https://github.com/william-london/ownframework-loop.git
cd ownframework-loop
bash install.sh
```

Verify:

```bash
claude plugin list
```

Then enter the repository you want to develop:

```bash
cd /path/to/target-repository
claude
```

Create a run:

```text
/of-loop:spec <mission>
```

Open two Claude sessions in the same target repository and launch:

```text
/loop /of-loop:build <run-id>
/loop /of-loop:review <run-id>
```

The builder owns first-start sealing. The reviewer waits until review is
claimable. In PROGRAM mode those same two lanes advance checkpoint by
checkpoint without operator protocol babysitting.

### Session-local evaluation

Without persistent installation:

```bash
git clone https://github.com/william-london/ownframework-loop.git /path/to/ownframework-loop
cd /path/to/target-repository
claude --plugin-dir /path/to/ownframework-loop
```

## PROGRAM mode

A v3 packet can contain a finite dependency-ordered checkpoint graph. The core
freezes that graph at execution start and owns:

- dependency-ready checkpoint selection;
- checkpoint-local build/review/repair counters;
- cumulative packet envelopes;
- one candidate branch across the run;
- exact checkpoint evidence;
- automatic approved-checkpoint advancement;
- fail-closed repair exhaustion;
- terminal program result.

Normal PROGRAM operation requires no separate initialization command.

## Portability model

OwnFramework Loop separates deterministic protocol authority from host UX.

### 1. Deterministic core

A host that can operate a Git checkout and invoke `ofloop` can participate.
The core owns execution sealing, packet validation, lifecycle state, locks,
budgets, candidate/worktree identity, receipts, exact-SHA verdicts, repair
accounting, crash reconciliation, and terminal semantics.

### 2. Portable Agent Skills

Host-neutral semantic wrappers live under:

```text
.agents/skills/of-loop-spec/
.agents/skills/of-loop-build/
.agents/skills/of-loop-review/
.agents/skills/of-loop-status/
```

### 3. Native adapters

Hosts may add plugins, commands, subagents, hooks, installation, or native loop
UX without creating a second execution-binding/state/SHA/verdict system.

| Agent host | Status | Surface |
|---|---|---|
| Claude Code | Stable / reference | Managed plugin, native skills/agents/hooks, `/loop` UX |
| Generic CLI host | Portable baseline | Git checkout + local `ofloop` contract |
| Codex | Experimental | Portable Agent Skills + adapter distribution; live lifecycle proof still required |

See:

- [`docs/architecture/CORE_INVARIANTS.md`](docs/architecture/CORE_INVARIANTS.md)
- [`docs/architecture/ADAPTER_CONTRACT.md`](docs/architecture/ADAPTER_CONTRACT.md)
- [`docs/architecture/PORTABILITY_MODEL.md`](docs/architecture/PORTABILITY_MODEL.md)
- [`docs/architecture/CAPABILITY_MATRIX.md`](docs/architecture/CAPABILITY_MATRIX.md)
- [`docs/architecture/AGENT_SKILLS.md`](docs/architecture/AGENT_SKILLS.md)
- [`docs/architecture/SUPERVISOR_MODEL.md`](docs/architecture/SUPERVISOR_MODEL.md)
- [`docs/ADAPTER_DEVELOPMENT.md`](docs/ADAPTER_DEVELOPMENT.md)

## Generic CLI contract

A generic host should consume deterministic outputs rather than reconstructing
paths or branches from prose. Typical build sequence:

```text
ofloop build claim <repo> <run-id>
ofloop build prepare <repo> <run-id>
ofloop build agent-skeleton <repo> <run-id>
# host fills the exact pass-scoped agent_result_path returned by preparation
ofloop build finalize <repo> <run-id> <agent_result_path>
```

The model/host does not choose baseline SHA, candidate branch, worktree,
checkpoint identity, or pass-scoped result path.

## Security boundary

OwnFramework Loop does not claim universal OS containment for arbitrary
same-user code. The commissioned unattended Claude supervisor does own a
narrower execution boundary for each semantic BUILD/REVIEW pass:

- Claude Bash sandbox enabled fail-closed;
- strict empty-domain Bash network allowlist;
- unsandboxed Bash escape disabled;
- Claude-native `--restricted` mode: user/project/local settings excluded and built-in file tools confined to the pass working directory;
- inherited MCP servers disabled with strict empty MCP configuration;
- browser, WebSearch/WebFetch, nested Agent/Task, Skill, and other non-local
  built-in surfaces absent from `--tools`;
- role-specific native tool sets (reviewer has no Edit/Write/NotebookEdit) plus Bash filesystem boundaries, including reviewer worktree deny-write;
- `dontAsk` + pre-approved sealed tools means no routine permission prompts;
- Bash sees no outbound network, no unsandboxed escape, a home-directory read deny with narrow pass re-opens, and scrubbed host credentials;
- authority-sensitive runner flags cannot be replaced through `OFLOOP_CLAUDE_EXTRA_ARGS`.

Mechanical hooks remain defense in depth, and deterministic exact-SHA/source/
effect checks remain authority after the worker exits. Interactive/foreground
Claude sessions are not automatically equivalent to this commissioned
supervisor envelope.

The strongest practical safety properties come from layered boundaries:

- no loop-owned external-action authority;
- packet/source execution binding;
- protected-path guards;
- clean exact-SHA build/review finalization;
- finite state/budget transitions;
- local-only packets and zero remotes when that is the target contract;
- operator-owned promotion.

See [`SECURITY.md`](SECURITY.md) and
[`docs/SECURITY_MODEL.md`](docs/SECURITY_MODEL.md).

## Validation

Canonical source validation:

```bash
./validate.sh
./release_gate.sh
```

Adapter conformance:

```bash
bash tests/run_adapter_conformance.sh
bash tests/integration/test_adapter_portability.sh
bash tests/integration/test_adapter_cli.sh
bash tests/integration/test_codex_adapter_install.sh
```

GitHub Actions runs the canonical suite on Linux and macOS across supported
Python versions, release gates, adapter conformance, real Claude plugin
validation/install proof, Codex distribution proof, and secret scanning.

## Requirements

Core/runtime:

- Python 3.12+
- Git
- Bash / POSIX-style environment
- macOS or Linux for the current lock/worktree runtime

Claude reference adapter:

- Claude Code 2.1+ for ordinary interactive adapter use
- Claude Code 2.1.248+ for the commissioned unattended supervisor
  (`--restricted` is the native shared-machine boundary)

## Project status

Current release line: **0.8.4**.

This remains an early public project. Correctness depends on the target
repository, mission, validation supplied by the packet, agent host, and local
environment. The project makes narrow deterministic claims about its own
protocol; it does not claim universal AI-agent safety or OS-level containment.

See [`CHANGELOG.md`](CHANGELOG.md) for release history.

## Contributing

Contributions are welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md) and
[`docs/ADAPTER_DEVELOPMENT.md`](docs/ADAPTER_DEVELOPMENT.md).

## License

Apache License 2.0. See [`LICENSE`](LICENSE) and
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
