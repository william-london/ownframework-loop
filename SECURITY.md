# Security

OwnFramework Loop is an early public project. It implements deterministic
workflow/integrity controls around packet binding, source identity, candidate
SHA, serialized lifecycle transitions, bounded repairs, exact-SHA review, and
adapter conformance. It does not claim universal correctness, universal safety,
or OS-level containment of arbitrary same-user code.

## Supported release posture

- The source/master supported line in this repository is **0.9.1**.
- The latest published GitHub Release is **v0.8.4** at
  `134a7ce543e2d5858b3a4613c49d49959fe0b029`.
- **0.9.1** is the current development line and is not a published release until
  its promotion gates close.
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

## Tool-surface hardening and commissioned worker isolation

The project does not claim that arbitrary same-user software becomes a separate
untrusted OS principal. The narrower commissioned-supervisor contract is
stronger.

Every unattended Claude BUILD/REVIEW pass is launched with Claude Code's Bash
sandbox enabled and fail-closed. The runtime supplies
`sandbox.network.strictAllowlist=true` with the run-frozen effective domain set (packet `network_read_allowlist` union capability-derived read domains),
`allowUnsandboxedCommands=false`, and role-specific filesystem write policy.
`--restricted` is the native shared-machine boundary: user/project/local settings are excluded and built-in file tools are confined to the pass working directory. MCP discovery is strict with an empty explicit MCP configuration. Browser/web research, nested Agent/Task orchestration, Skill, and other non-local built-ins are not exposed through the semantic worker's `--tools` allow-list. Builder and reviewer use different native tool sets; reviewers do not receive Edit/Write/NotebookEdit.

The supervisor uses `--permission-mode dontAsk` together with an explicit pre-approved sealed tool set and sandbox auto-allow. Inside the authorized pass there are no routine human permission prompts; anything outside the sealed capability set is denied rather than escalated. Bash is additionally denied reads of both the operator home and the Loop supervisor state root (even when XDG_STATE_HOME is outside HOME), except for the current worktree, semantic artifact, per-run runtime cache, Git metadata, trusted Loop payload, and (where a host requires file-backed authentication) an exact private credential file. Directory-wide adapter auth re-opens are refused. `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` plus sandbox credential denies keep host credentials out of Bash children.

Commissioned service auth/model environment is stored in Loop's private state as `service-env.json` (0600 under a 0700 state directory). launchd/systemd definitions and runtime provenance contain only that file's path, never bearer-token values. On macOS Claude OAuth credentials remain in the encrypted Keychain; the installer does not reopen `~/.claude`. On Linux the installer may reopen only the exact private `.credentials.json` file documented by Claude Code.

The minimum commissioned-runner version is Claude Code 2.1.248 because `--restricted` is part of the boundary. Newer compatible versions are accepted. On Linux/WSL2, supervisor commissioning also proves `bubblewrap`, `socat`, and a usable bubblewrap sandbox before enabling the service. If the version/prerequisites cannot be proven or the sandbox cannot arm, semantic execution fails closed.

A first semantic execution also creates an immutable run-level capability
binding. Later attempts re-resolve and exact-compare authority-relevant host,
tool, manifest, privileged-canary, network, sandbox, and runner-profile
identity before releasing a provider child. Cache contents/pass-ephemeral cache
paths are deliberately excluded. Privileged Docker authority is broker-only:
raw daemon sockets, daemon/context selectors, alternate container-control
clients, and registry publication remain outside the worker envelope.

Adapter hooks remain a second boundary for direct/normalized command forms, and
the deterministic core re-proves exact source/candidate identity before
accepting evidence.

The native `allowedDomains` sandbox is a **host-reachability** boundary; it is
not, by itself, an HTTP-method authorization system. Loop's external-action
hook refuses direct curl/wget and common explicit Python/Node mutation forms,
while preserving loopback mutation for local engineering. That textual layer is
defense in depth, not a claim to parse arbitrary generated programs. A generic
proof that an arbitrary Bash child can never mutate an allowlisted host
requires the commissioned runtime/network boundary to provide method-aware
read-only egress (or equivalent enforcement); until then that stronger claim
remains commissioned-canary/integration work rather than ordinary-CI proof. Interactive/foreground Claude sessions do not automatically
inherit this exact commissioned envelope.

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
