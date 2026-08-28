# OPERATOR_RUNBOOK

Canonical operator workflow for OwnFramework Loop.

## 1. Human-originated specification

Create and inspect the mission:

```text
/of-loop:spec <mission>
```

SPEC is the human boundary. The packet must describe the intended local
engineering work, scope, validation, budgets, and non-goals.

There is no mandatory approval command or confirmation token after a valid
packet exists.

## 2. Unattended mode (canonical for background work)

Enqueue the existing run:

```bash
ofloop supervisor enqueue /absolute/path/to/repo <run-id> \
  --max-cost-usd 25 \
  --max-wall-seconds 28800
```

Start the execution clock:

```bash
ofloop supervisor serve
```

The supervisor is independent of the shell working directory because every job
stores an absolute repository path.

While idle it makes zero model calls. For actionable work it asks the
deterministic dispatch boundary for exactly one BUILD or REVIEW work order,
launches one fresh runner process, finalizes deterministically, and immediately
asks core what is next.

Operational status / morning evidence:

```bash
ofloop supervisor status /absolute/path/to/repo <run-id>
```

Status combines supervisor queue/retry/cost evidence with a read-only snapshot
of core state, candidate SHA, pass counters, PROGRAM checkpoint, and latest
review verdict.

On macOS, after commissioning the exact checkout:

```bash
bash install-supervisor-macos.sh
```

This installs a per-user `launchd` service so the supervisor is independent of
an open terminal or Claude session.

## 3. Interactive foreground mode

For debugging or hands-on sessions, the existing Claude UX remains:

```text
/loop /of-loop:build <run-id>
/loop /of-loop:review <run-id>
```

These are adapters over the same deterministic core, not the durable execution
clock.

## First-start execution seal

The first legitimate build start creates the immutable execution seal:

- `binding_method=build_start`
- `binding_kind=execution_seal`
- binds exact packet bytes/SHA, canonical repo, spec-time baseline branch/SHA,
  candidate branch, packet metadata, and PROGRAM provenance.

Internal state name `AWAITING_APPROVAL` and historical file
`APPROVAL.json` remain compatibility names for existing runs. Operator-facing
meaning is `READY_TO_START`.

## Promotion boundary

`APPROVED` means eligible for human/operator promotion. Loop and its
supervisor do not push, merge, deploy, publish, pay, send messages, or mutate
unrelated remote systems.

## Retired path

`ofloop loop run` is intentionally retired. It previously drove finalizers
without a real semantic builder/reviewer process and is not a supported
unattended architecture.
