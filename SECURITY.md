# Security

OwnFramework Loop is an early public project. It implements deterministic
workflow/integrity controls around packet binding, source identity, candidate
SHA, serialized lifecycle transitions, bounded repairs, exact-SHA review, and
adapter conformance. It does not claim universal correctness, universal safety,
or OS-level containment of arbitrary same-user code.

## Supported release posture

- The currently supported release line is **0.8.4**.
- Earlier 0.2.x/0.3.x/0.4.x/0.5.0-0.5.4 behavior remains in Git history for
  compatibility/audit context but is not the current product contract.

## Current execution-start boundary

Normal operation has no mandatory approval ceremony.

The first legitimate execution start creates an immutable execution seal that
binds:

- exact work-packet bytes / SHA-256;
- canonical repository identity;
- spec-time baseline branch and exact baseline SHA;
- deterministic candidate branch;
- relevant packet metadata and PROGRAM provenance.

The historical `APPROVAL.json` filename and `tty_confirmation` method are kept
for backward compatibility. New runs normally use:

```text
approval_method=build_start
binding_kind=execution_seal
```

Compatibility field names such as `approved_at` are not evidence that a person
typed a confirmation token.

A run start authorizes bounded local engineering only. It does not grant push,
merge, deploy, publish, payment, message sending, remote mutation, or unrelated
external-action authority.

## Tool-surface hardening and supervised worker isolation

The project does not claim that an arbitrary same-user program becomes an
untrusted OS principal. The narrower commissioned-supervisor contract is
stronger: each unattended Claude BUILD/REVIEW pass is launched with Claude
Code's Bash sandbox enabled with `failIfUnavailable=true` and
`allowUnsandboxedCommands=false`. Project/local Claude settings and inherited
MCP servers are excluded; browser/web/task orchestration tools are not exposed
to the semantic worker.

This OS/runtime boundary is layered with the adapter hooks. The hooks continue
to block direct and normalized external-effect forms, while the deterministic
core re-proves exact source/candidate identity and refuses unauthorized effects
before accepting evidence.

Interactive/foreground Claude sessions do not automatically inherit the exact
commissioned-supervisor envelope. A coding agent must never intentionally route
around a guard refusal using indirection such as hidden subprocess construction,
aliases, encoded commands, or dynamic shell assembly.

`hardened=true` describes these deterministic host/runtime rails for the
declared workflow; it is not a claim of universal arbitrary-code containment.

## Core security-relevant invariants

Security-sensitive defects include violations of:

- exact packet/source execution binding;
- spec-time source-drift refusal;
- execution-seal immutability;
- serialized first-start/build/review claims;
- protected-path and scope enforcement;
- exact candidate SHA and clean-worktree receipts;
- exact-SHA review/verdict identity;
- exact-current-pass crash reconciliation;
- repair/checkpoint/global budget enforcement;
- fail-closed terminal semantics;
- no autonomous push/merge/deploy/publish/payment/customer-effect authority.

## Reporting a vulnerability

Please report suspected vulnerabilities privately to:

**williamlondon@ownframework.com**

Do not open a public GitHub issue for an undisclosed vulnerability. Public
disclosure should wait until a fix or mitigation is available.

Please include:

- short description;
- affected release/commit SHA;
- minimal reproduction;
- environment details (OS, Python, agent host/version);
- whether the issue affects deterministic core authority, an adapter rail, or a
  documentation/claim mismatch.

## Response posture

The project is maintained on a best-effort basis with no formal response SLA.
Defects affecting core authority/integrity boundaries are prioritized.

## Scope notes

The following are intentionally out of scope as standalone reports:

- broad philosophical claims about autonomous AI;
- behavior of unrelated third-party plugins/hosts outside this repository;
- behavior of arbitrary customer code the loop is asked to edit;
- the observation that same-user arbitrary code is not equivalent to an OS
  sandbox (the project documents that explicitly).

Concrete bypasses of declared deterministic checks or materially false public
security claims remain in scope.
