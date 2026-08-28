# Generic CLI host adapter

`generic-cli` is OwnFramework Loop's vendor-neutral portability floor. It is not
a plugin for a particular AI product; it defines the minimum deterministic
contract for any coding-agent host that can operate a Git checkout and invoke
local commands.

## Minimum host capabilities

A generic host can participate when it can:

- read the target repository and supported Loop status/evidence;
- invoke local `ofloop` commands;
- edit/commit in the builder worktree selected by the core;
- inspect an exact candidate Git SHA;
- fill semantic build/review artifacts at exact paths returned by deterministic
  preparation.

No vendor API, plugin marketplace, native subagent system, hook API, or built-in
loop command is required for protocol compatibility.

## Normal lifecycle

```text
SPEC
→ first BUILD claim auto-seals packet/source identity
→ BUILD prepare/skeleton/agent/finalize
→ REVIEW prepare/assessment/finalize
→ bounded repair/checkpoint progression
→ terminal result
```

There is no mandatory approval/token step and no normal `program init` step.
The historical TTY pre-seal exists only for compatibility.

## What the host must not own

A generic host must not:

- directly edit `STATE.json`, execution-binding `APPROVAL.json`, receipts,
  verdicts, locks, or event logs;
- choose/reconstruct baseline SHA, candidate branch, worktree, checkpoint, or
  pass-scoped result path;
- push, merge, deploy, publish, send, charge, create/change unrelated remotes,
  or reinterpret `APPROVED` as promotion authority.

Promotion remains outside Loop.

## Exact build semantic-result contract

Do **not** assume a fixed scratch path.

Canonical sequence:

```text
ofloop build claim <repo> <run-id>
ofloop build prepare <repo> <run-id>
# consume exact builder_worktree / candidate_branch / agent_result_path returned
ofloop build agent-skeleton <repo> <run-id>
# agent fills only the exact returned pass-scoped semantic result
ofloop build finalize <repo> <run-id> <agent_result_path>
```

The authoritative finalizer independently verifies Git identity, clean worktree,
scope, budgets, validations, packet/source binding, and writes
`BUILD_RECEIPT.json`. The agent never writes the receipt.

Review follows the same principle: consume deterministic preparation and exact
candidate identity rather than reconstructing paths from prose.

## Portable skills

Hosts that understand Agent Skills can consume:

```text
.agents/skills/of-loop-spec/SKILL.md
.agents/skills/of-loop-build/SKILL.md
.agents/skills/of-loop-review/SKILL.md
.agents/skills/of-loop-status/SKILL.md
```

Hosts without Agent Skills may use those files as semantic reference for a thin
wrapper. Do not copy them into a second lifecycle engine.

## Inspect the contract

```bash
./bin/ofloop adapter show generic-cli
./bin/ofloop adapter doctor generic-cli
```

Expected posture:

```text
maturity=portable
protocol_compatible=true
hardened=false
live_verified=false
```

`live_verified=false` is intentional because `generic-cli` names no specific
host.

See also:

- [`../../docs/architecture/PORTABILITY_MODEL.md`](../../docs/architecture/PORTABILITY_MODEL.md)
- [`../../docs/architecture/ADAPTER_CONTRACT.md`](../../docs/architecture/ADAPTER_CONTRACT.md)
- [`../../docs/ADAPTER_DEVELOPMENT.md`](../../docs/ADAPTER_DEVELOPMENT.md)
