# Getting Started

This guide covers the shortest supported path from a clean source checkout to one
bounded OwnFramework Loop run.

## 1. Install the core

From a source checkout or source release:

```bash
./install.sh
```

The installer publishes the managed `ofloop` launcher to `~/.local/bin` by default.
Core installation does not silently create a background service.

## 2. Install an optional adapter

Claude Code:

```bash
./bin/install-adapter claude-code
```

Codex:

```bash
./bin/install-adapter codex
```

Adapters provide host-specific UX and distribution surfaces. They do not own the core
lifecycle or deterministic engineering state machine.

## 3. Commission the durable supervisor

```bash
./bin/install-supervisor
```

Commissioning selects the supported per-user service manager for the current host and
refuses if required runtime or sandbox prerequisites cannot be proven.

## 4. Define a bounded mission

Start from `templates/WORK_PACKET.md`. Replace every placeholder and validate the
packet against the schemas before execution. Make the following explicit:

- repository and exact expected baseline;
- allowed and protected paths;
- observable acceptance criteria;
- deterministic validation commands;
- pass, repair, cost, and runtime budgets;
- portable capability declarations;
- any packet-specific read-only network domains;
- human-only promotion authority.

Use synthetic or low-risk work for a first run. Promotion and unrelated external
effects remain outside Loop authority.

## 5. Enqueue and inspect

```bash
ofloop supervisor enqueue <repo> <run-id>
ofloop supervisor status <repo> <run-id>
```

The commissioned supervisor owns BUILD/REVIEW scheduling and bounded repair. Do not
run parallel hand-managed builder/reviewer loops for the same mission.

For foreground operational debugging, the same execution clock can be run with:

```bash
ofloop supervisor serve
```

## Completion boundary

A terminal `APPROVED` run is eligible for operator promotion. It is not authority to
push, merge, deploy, publish, pay, message, or mutate unrelated external systems.

Continue with [`OPERATOR_RUNBOOK.md`](OPERATOR_RUNBOOK.md) for normal operations and
recovery.
