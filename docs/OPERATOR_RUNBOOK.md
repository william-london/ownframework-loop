# Operator Runbook

Canonical operation for the vendor-neutral OwnFramework Loop runtime.

## 1. Install core

```bash
bash install.sh
```

This installs the versioned core and managed `ofloop` launcher. It does not
require an agent host.

Optional adapter:

```bash
bash install-adapter.sh claude-code
# or
bash install-adapter.sh codex
```

## 2. Commission durable service

```bash
bash install-supervisor.sh
```

The wrapper selects launchd on macOS and systemd-user on Linux.

Commissioning is explicit. Installing the core alone does not start a
background service.

The current production semantic runner is Claude Code. If Claude is present,
commissioning requires 2.1.248+; newer compatible versions are accepted.

Linux/WSL2 Claude commissioning also proves `bubblewrap` and `socat` are
available and bubblewrap can create the required sandbox. On Ubuntu 24.04+
AppArmor user-namespace policy may require the documented bubblewrap profile.

A supervisor may be commissioned idle-only when no semantic runner is present.
It makes no model calls while idle.

## 3. Human-originated SPEC

Create and inspect the mission using a supported adapter/core workflow.

The packet defines:

- repo and baseline;
- execution mode/checkpoints;
- allowed/protected paths;
- acceptance criteria/non-goals;
- validation;
- finite execution/source budgets;
- optional exact-host `network_read_allowlist`;
- human-only promotion authority.

There is no normal second approval/token ceremony. First actionable BUILD start
creates the immutable execution seal.

## 4. Enqueue

```bash
ofloop supervisor enqueue <repo> <run-id>
```

The default runner is currently `claude-code`. Runner selection is explicit
when another registered live runner exists:

```bash
ofloop supervisor enqueue <repo> <run-id> --runner <runner-id>
```

Once the durable service is commissioned, no terminal session needs to remain
open.

## 5. Observe

```bash
ofloop supervisor status <repo> <run-id>
```

Status is read-only. It exposes queue/retry/cost/token evidence, core state,
PROGRAM checkpoint, exact candidate SHA, worktree identity/cleanliness, recent
semantic attempts, logs, runtime generation, and quarantine reason.

It never advances state or publishes candidate work.

## 6. Execution behavior

For actionable work the supervisor:

1. asks deterministic dispatch for the next BUILD/REVIEW order;
2. prepares exact worktree/pass artifact;
3. launches one fresh semantic runner;
4. finalizes deterministically;
5. immediately asks dispatch what is next.

BUILD/REVIEW/repair/checkpoint advancement continue without routine human
permission prompts.

Operational failures are classified separately from engineering review:

- deterministic invariant/runner configuration failure: quarantine;
- ordinary infrastructure failure: bounded retry;
- recognized transient provider/network failure: bounded exponential backoff
  and recovery cycles;
- unknown configured cost/token evidence: fail closed where the ceiling makes
  that evidence authoritative.

## 7. Claude commissioned boundary

Claude 2.1.248+ runs with:

- `--restricted`;
- `--permission-mode dontAsk`;
- exact role tool list;
- sandbox fail-if-unavailable;
- no unsandboxed-command escape;
- strict MCP isolation;
- packet-bound network read domains;
- credential scrubbing.

Allowed local operations execute without prompts. Anything outside the sealed
capability set is denied rather than escalated to a human.

## 8. Runtime refresh

A later:

```bash
bash install.sh
```

refreshes an already-commissioned service only after the shared runtime
dependency probe proves replacement safe.

It refuses:

- live/ambiguous semantic work;
- unreadable/missing commissioned ledger;
- unfinished jobs bound to another generation;
- unfinished legacy jobs with no generation binding.

DONE and RETIRED enrollment do not block normal refresh.

## 9. Historical enrollment retirement

A preserved QUARANTINED enrollment can be retired through the supported
supervisor lifecycle. Retirement changes supervisor enrollment only; target
repository/run artifacts remain unchanged.

RETIRED enrollment is not schedulable and ordinary resume refuses it.

## 10. Foreground/debug operation

```bash
ofloop supervisor serve
```

runs the same durable execution clock in the foreground.

Claude adapter users may also invoke `/of-loop:build` and
`/of-loop:review` for focused foreground debugging. Those commands are
adapter UX, not canonical scheduling.

## 11. Promotion

Terminal APPROVED means eligible for human inspection/merge.

Loop does not push, merge, deploy, publish, pay, send messages, or mutate
unrelated remote systems.

## 12. Uninstall

Adapter only:

```bash
bash uninstall-adapter.sh claude-code
bash uninstall-adapter.sh codex
```

Supervisor only:

```bash
bash uninstall-supervisor.sh
```

Core:

```bash
bash uninstall.sh
```

Core uninstall preserves durable supervisor state/evidence and independently
owned adapter data unless those surfaces are explicitly removed first.
