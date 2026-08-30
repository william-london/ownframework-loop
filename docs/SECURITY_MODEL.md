# Security Model

## Threat model

OwnFramework Loop is designed for a local operator using coding agents against
Git repositories. Relevant threats include:

1. prompt-injected repository content trying to expand authority;
2. source/path drift outside packet scope;
3. concurrent builder/reviewer/start races;
4. stale or mismatched candidate review;
5. canonical source movement between spec and execution start;
6. dirty/mutated reviewer or builder worktrees;
7. malformed/tampered protocol artifacts;
8. stale prior-pass/checkpoint evidence being adopted after a crash;
9. secret-shaped content in source/commits;
10. autonomous external actions such as push, merge, deploy, publish, payment,
    messaging, remote mutation, or customer-system mutation;
11. a same-user agent intentionally trying to route around host tool guards.

The project does not claim universal isolation for arbitrary same-user
software. Commissioned unattended semantic passes do use Claude Code's native
shared-machine boundary (`--restricted`) plus its Bash sandbox, strict network
policy, credential scrubbing, and role-specific tool availability.

## Defense layers

### 1. Execution seal and spec-time baseline binding

`spec new` records the target branch and exact baseline SHA. On first legitimate
execution start the core refuses if that source moved or became tracked/staged
dirty.

A new execution seal binds:

- run ID;
- exact packet SHA-256;
- canonical repository;
- baseline branch and SHA;
- candidate branch;
- packet schema/metadata;
- PROGRAM source provenance when applicable.

Normal new-run method:

```text
approval_method=build_start
binding_kind=execution_seal
```

The historical `APPROVAL.json` filename/schema and `tty_confirmation` method are
compatibility surfaces. They are not the current authority model.

Packet/source drift after sealing fails closed. Changed scope requires a fresh
run rather than a re-approval cycle.

### 2. Serialized authority transitions

The protocol uses filesystem locks to serialize:

- first execution start;
- execution-binding creation;
- lifecycle state writes;
- event-chain appends;
- single-mode build/review claims;
- PROGRAM claim/counter ownership;
- worktree ownership where applicable.

Concurrent callers must converge on one authoritative transition/pass rather
than duplicate budget consumption.

### 3. Atomic artifact writes

Structured protocol artifacts use temp-file + fsync + atomic replace semantics.
Partial writes must not leave half-written authoritative JSON.

Authoritative state/evidence files use restrictive modes where supported.

### 4. Scope, worktree, and exact-SHA binding

The core owns baseline/candidate branch/worktree identity. Models/adapters do not
invent those values.

Build finalization verifies the exact candidate context, including clean
worktree/branch/SHA identity, scope/protected paths, budgets, and required
validation before writing `BUILD_RECEIPT.json`.

Review is bound to the exact candidate SHA in the authoritative build receipt.
Dirty reviewer state or candidate drift fails closed.

### 5. Exact-pass crash reconciliation

Durable receipts/verdicts may be written immediately before a lifecycle
transition. Reconciliation therefore exists, but may adopt evidence only when:

- the run remains in the matching in-flight state;
- the artifact belongs to the exact currently claimed pass;
- packet/candidate identity still binds;
- the implied transition is valid.

Prior-pass or prior-checkpoint artifacts may remain as evidence but must never
advance a later checkpoint.

PROGRAM review recovery routes through the same checkpoint advancement/repair
accounting primitives as the normal review path.

### 6. PROGRAM graph/budget freezing

For v3 PROGRAM packets the core freezes:

- graph SHA;
- dependency order;
- candidate branch;
- source baseline provenance;
- checkpoint-local build/review/repair caps;
- cumulative packet ceilings;
- global source ceilings.

Checkpoint approval requires real build/review evidence. Repair exhaustion is
fail-closed. Approved checkpoint advancement is deterministic and operator-free;
final checkpoint approval yields terminal program `APPROVED`.

### 7. Commissioned semantic-worker isolation

The durable supervisor currently launches each production BUILD/REVIEW pass
through the registered Claude runner with Claude Code 2.1.248+ in native
`--restricted` mode. The supervisor/dispatch FSM itself is vendor-neutral. Built-in file tools are confined to
the pass working directory; user/project/local settings are not loaded.
Builder and reviewer receive different built-in tool sets, with reviewers
structurally lacking Edit/Write/NotebookEdit.

Bash runs inside Claude's OS sandbox with fail-if-unavailable, no unsandboxed
escape, strict frozen packet network read allowlist (empty by default), operator-home read denial with narrow
current-pass/runtime re-opens, and credential scrubbing/deny rules.
`--permission-mode dontAsk` plus explicit pre-approved sealed tools means
authorized work runs without routine human prompts while out-of-contract calls
are denied.

`PreToolUse`/`PostToolUse` hooks remain defense in depth for protocol/path
semantics that Claude's generic sandbox does not know, such as exact pass
scratch authority and Loop external-action classification. They are not the
primary OS isolation boundary.

### 8. External-action boundary

The loop's engineering authority does not include:

- Git push/merge/publish-to-remote;
- production deploy;
- public publishing;
- email/SMS/DM sending;
- calendar mutation;
- payment/charge/refund;
- destructive cloud/customer-system mutation;
- unrelated remote creation/mutation.

Packets may describe bounded engineering work, but Loop state or `APPROVED`
never grants those external effects. Promotion remains outside Loop.

### 9. Prompt-injection handling

Repository content, issue text, logs, webpages, generated docs, test output,
comments, and commit messages are untrusted data. They may not:

- change the target repository;
- widen paths/budgets;
- grant push/deploy/external authority;
- request or expose secrets;
- mutate the work packet after sealing;
- disable guards;
- invent new lifecycle transitions.

### 10. Local-only / no-remote hardening

Packets may classify a target as `local_only`. A target with zero remotes has an
additional practical boundary: there is no configured Git destination to push
to. This complements rather than replaces command/effect guards.

## Authority matrix

```text
PACKET_SOURCE_BINDING=deterministic
FIRST_START_SERIALIZATION=deterministic
BUILD_REVIEW_CLAIMS=serialized
CANDIDATE_SHA=exact
REVIEW_SHA=exact
CRASH_RECONCILIATION=exact_current_pass_only
PROGRAM_BUDGETS=finite
EXTERNAL_ACTION_AUTHORITY=outside_loop
CLAUDE_RESTRICTED_MODE=required_for_supervised_semantic_passes
BASH_SANDBOX=fail_closed
SEMANTIC_NETWORK_EGRESS=packet_network_read_allowlist_only
SEMANTIC_PERMISSION_PROMPTS=none_in_authorized_surface
TOOL_SURFACE_GUARDS=defense_in_depth
```

## Compatibility notes

The repository preserves historical names such as:

- internal state `AWAITING_APPROVAL` (operator-facing meaning:
  `READY_TO_START`);
- file `APPROVAL.json` (current normal meaning: execution seal);
- compatibility fields `approved_at`, `approved_actor`,
  `confirmation_token`;
- optional `tty_confirmation` pre-seal path for old users/runs.

Those names exist to avoid breaking old artifacts. Active product semantics do
not require a human approval/token ceremony.

## Auditability

Lifecycle transitions, counter changes, receipts, verdicts, stop requests,
reconciliation, and relevant guard events are recorded in durable run evidence.
The event log is append-only under its lock/chain contract.

Audit claims should distinguish what is mechanically proven from what is merely
instructional. A passing grep or final counter is not sufficient evidence of a
concurrency or security property unless the test exercises the behavioral path.

## Tooling autonomy posture

Interactive Claude sessions may use the broader plugin/agent surface. The
commissioned unattended supervisor intentionally does not: it uses Claude's
native restricted mode and role-specific local tools so SPEC approval can be
followed by unattended BUILD/REVIEW/repair without permission babysitting.

Research and external-service setup happen before the sealed PROGRAM is minted.
Dependency/download reads may occur during BUILD/REVIEW only to exact hostnames
frozen in the packet's `network_read_allowlist`; no runtime widening prompt is
available. Promotion remains after terminal APPROVED and human-owned.

Authority still comes from deterministic packet/source/worktree/SHA/state/
finalizer boundaries; the native sandbox limits what a compromised semantic
worker can reach while those deterministic checks decide what evidence counts.
