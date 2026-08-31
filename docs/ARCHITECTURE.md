# OwnFramework Loop Architecture

## Product identity

OwnFramework Loop is a vendor-neutral deterministic engineering runtime.

It is not a Claude Code plugin with portability added later. Claude Code is one
host adapter and currently the first production-hardened semantic runner.

The architecture has four layers:

```text
SPEC / human authority
        |
deterministic core
        |
durable supervisor + runner registry
        |
host semantic runner / optional UX adapter
```

Only the bottom layer is vendor-specific.

## 1. Deterministic core

`lib/ownframework_loop/` owns engineering authority and durable truth:

- WORK_PACKET parsing/validation;
- repository identity and spec-time baseline;
- immutable first-start execution seal;
- lifecycle state and event evidence;
- PROGRAM checkpoint graph;
- pass/repair/source/runtime budgets;
- deterministic builder/reviewer worktree preparation;
- exact candidate SHA;
- build receipt and review verdict finalization;
- scope/protected-path/secret/external-action enforcement;
- write-ahead state/event recovery;
- runtime-generation identity;
- promotion boundary.

A semantic model may provide implementation or review judgment. It cannot
authoritatively choose the repo, baseline, worktree, candidate SHA, lifecycle
transition, budget expansion, or promotion.

## 2. Durable supervisor

`supervisor.py` owns operational continuity, not engineering truth.

Responsibilities:

- persistent queue;
- bounded concurrent semantic workers across distinct candidate workspaces;
- exactly one active semantic pass per run/workspace;
- runner selection through the runner registry;
- exact runtime-generation binding;
- semantic-attempt ledger;
- process ownership;
- bounded retry/backoff;
- cost/token telemetry;
- wall-clock enforcement;
- RUNNER_WAIT when a commissioned runner is unavailable;
- quarantine/retirement enrollment lifecycle;
- live read-only status.

The supervisor asks deterministic dispatch what action is next. It does not
invent BUILD/REVIEW transitions itself.

Repository identity is the resolved Git common directory. It groups shared Git
provenance but is not a global execution mutex. Workspace identity is repository
identity plus the frozen candidate branch. Distinct workspaces in one repository
may execute concurrently and may intentionally edit the same logical paths;
their files/refs remain isolated until human promotion. The same workspace and
the same run never have overlapping semantic owners. Shared Git worktree
registration/removal is briefly serialized because it mutates common Git
administration state.

Canonical unattended sequence:

```text
supervisor
  -> dispatch claim
  -> deterministic prepare/skeleton
  -> one fresh semantic runner
  -> deterministic finalize
  -> dispatch next
  -> ...
  -> terminal
```

## 3. Runner registry

Semantic execution is selected by runner ID. The registry is vendor-neutral;
dispatch and the supervisor FSM do not import provider state machines.

Current live production runner:

```text
claude-code
```

Additional runners may be registered only when they can consume the same
deterministic work order and return the same pass-scoped semantic artifact
without reimplementing core authority.

The default runner can remain `claude-code` while it is the only hardened live
runner. That default is operational policy, not product identity.

## 4. Host adapters

Adapters provide host UX/distribution features such as:

- plugins/extensions;
- Agent Skills;
- custom agents;
- hooks;
- host-specific install/discovery;
- interactive SPEC/build/review commands.

Adapters never own:

- execution seal;
- lifecycle state;
- candidate identity;
- repair counters;
- runtime-generation contract;
- final verdict authority;
- merge/deploy/promotion.

### Claude Code

Claude adapter surfaces live under:

- `.claude-plugin/`;
- `skills/`;
- `agents/`;
- `hooks/`;
- `adapters/claude-code/`.

Interactive `/of-loop:build` and `/of-loop:review` are foreground/debug
coordinators. They are not the durable scheduler.

The commissioned Claude runner is intentionally narrower than the interactive
plugin surface.

### Portable Agent Skills / Codex

`.agents/skills/` carries portable skills. Codex consumes those skills through
its experimental adapter.

### Generic CLI

`generic-cli` is the vendor-neutral portability floor: a host that can invoke
the deterministic CLI, edit a prepared worktree, run validation, and write the
one supplied semantic result can participate without native plugin APIs.

## Installation architecture

Installation ownership is intentionally separated:

```text
install.sh
  -> versioned OwnFramework Loop core
  -> managed ofloop launcher

install-adapter.sh <host>
  -> optional host integration only

install-supervisor.sh
  -> platform service manager
  -> exact installed core
```

The core runtime never lives inside an adapter/plugin cache.

### macOS

`install-supervisor-macos.sh` creates a per-user launchd service.

### Linux

`install-supervisor-linux.sh` creates a per-user systemd service.

Both use the same read-only runtime dependency probe before replacement or
uninstall. Service-manager code therefore cannot define different generation
semantics.

## Runtime generation

A supervisor job binds the exact generation that enrolled it:

- clean Git payload: version + exact HEAD;
- dirty Git payload: version + digest of HEAD/diff/untracked bytes;
- installed/non-Git payload: version + deterministic payload-tree digest.

Unfinished QUEUED/BACKOFF/RUNNING/QUARANTINED enrollment cannot silently cross
generations. DONE and explicitly RETIRED historical enrollment do not block
ordinary refresh.

Unsafe migration remains an explicit operator recovery action, never routine
installation behavior.

## Semantic worker boundary

A commissioned Claude pass uses native restricted execution with exact
role-specific tools and no routine permission prompts.

Builder may modify only its prepared source worktree and pass result artifact.
Reviewer has no built-in source editing tools and its exact-SHA worktree is
deny-write at the Bash sandbox layer.

Packet `network_read_allowlist` is the only post-SPEC outbound read authority
for semantic Bash. Remote mutation remains outside Loop.

## State and crash consistency

STATE.json and EVENTS.log are a coupled authoritative history.

State mutation uses write-ahead `STATE_TXN.json`; verified reads recover only a
proven declared transaction and otherwise fail closed on integrity mismatch.

Atomic append temp files are non-authoritative and disposable. Runtime cache is
also non-evidence; durable worker logs and semantic-attempt rows are evidence.

## Human boundaries

Normal workflow has two intended human authority boundaries:

1. define/inspect the SPEC before execution;
2. merge/promote after terminal APPROVED.

Everything between them is designed to run unattended.

APPROVED never grants push, merge, deploy, publish, payment, messaging, or
unrelated external-system mutation authority.
