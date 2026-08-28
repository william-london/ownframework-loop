# AGENTS.md

This is the repository-local operating contract for coding agents working on
`ownframework-loop`. It is public, self-contained doctrine for this repository;
it does not depend on private infrastructure or private policy files.

## Product intent

OwnFramework Loop is a deterministic engineering protocol for AI coding agents.
The normal operator experience is deliberately low-friction:

```text
spec → builder lane + reviewer lane → terminal result → operator promotion
```

There is no mandatory approval ceremony, confirmation token, manual PROGRAM
initialization, manual claim/finalize sequence, or checkpoint babysitting.

The first legitimate execution start creates an immutable execution seal that
binds the exact packet and spec-time source baseline. Promotion and external
effects remain outside Loop authority.

## Scope

This contract covers this repository only, including:

- deterministic source under `lib/`, `bin/`, `schemas/`, `templates/`;
- tests and validation under `tests/`, `validate.sh`, `release_gate.sh`;
- Claude integration under `skills/`, `agents/`, `hooks/`, `.claude-plugin/`;
- portable host-neutral skills under `.agents/skills/`;
- adapter metadata/docs under `adapters/` and `docs/architecture/`;
- public project surfaces such as `README.md`, `SECURITY.md`, `CHANGELOG.md`;
- CI under `.github/workflows/`.

## Core versus adapter authority

The deterministic core owns:

- work-packet parsing and validation;
- spec-time baseline capture;
- first-start execution sealing;
- lifecycle transitions and locking;
- scope/runtime/repair budgets;
- candidate branch/worktree identity;
- exact candidate Git SHA;
- build receipts and exact-SHA verdict binding;
- crash reconciliation and terminal semantics;
- the boundary before operator promotion.

Adapters may provide host-specific skills, agents, hooks, installers, discovery,
and loop UX. They must not create a parallel execution-seal, state, repair,
candidate, verdict, or promotion truth.

Claude Code is the stable/reference adapter. `generic-cli` is the portability
floor. Codex remains experimental until live host evidence justifies stronger
claims.

## Authority boundaries

A run start authorizes bounded local engineering only. It never grants authority
to:

- push, merge, deploy, publish, or create/change unrelated remotes;
- send email/SMS/DMs or mutate customer systems;
- charge, refund, or make payments;
- perform unrelated external effects.

`APPROVED` means protocol-approved and eligible for operator promotion. It is
not promotion authority.

The historical `APPROVAL.json` filename is a compatibility detail. For current
runs it normally stores an execution seal (`approval_method=build_start`,
`binding_kind=execution_seal`). Do not interpret compatibility field names such
as `approved_at` as proof that a human typed a token.

## What an agent may do in this repository

An agent may:

- inspect, edit, refactor, test, and commit coherent validated work;
- use GitHub Actions as independent public validation compute;
- run `./validate.sh`, `./release_gate.sh`, focused tests, adapter conformance,
  `git diff --check`, and secret scans;
- update public documentation when behavior changes;
- use supported repository APIs/tooling when the operator explicitly asks for
  repository maintenance.

An agent may not:

- deliberately route around a guard refusal using `eval`, encoded commands,
  hidden Python subprocess construction, aliases, or equivalent indirection;
- force-push, mirror-push, rewrite history, or delete unrelated branches without
  explicit scope;
- hand-edit `.git/` metadata;
- directly author authoritative run artifacts such as `STATE.json`,
  execution-binding `APPROVAL.json`, `BUILD_RECEIPT.json`,
  `REVIEW_VERDICT.json`, `EVENTS.log`, locks, or stop markers in production
  workflows;
- create adapter-specific lifecycle truth;
- inject real customer/prospect/payment/secrets data into this repository.

Tool-surface guards are guardrails, not an OS sandbox. Same-user arbitrary-code
containment is not claimed. A guard refusal is still a boundary and must not be
treated as a puzzle to bypass.

## Repository-local engineering rules

### Source of truth

`master` is the canonical product branch. Keep source, tests, docs, adapter
metadata, and installed-version truth coherent.

For risky repository surgery, a temporary validation branch/PR may be used to
exercise GitHub Actions before fast-forwarding the exact validated commit to
`master`. Temporary validation branches are not a second product branch.

### Synthetic/non-customer data only

Normal tests and fixtures use synthetic data only. Do not add real tokens,
customer/prospect records, bank/payment data, production secrets, or `.env*`
files.

### No public side effects from tests

Normal tests must not deploy, publish, send messages, mutate customer systems,
or perform production cloud changes. Public package discovery/install checks in
CI are allowed where explicitly part of adapter validation.

### Deterministic protocol ownership

Do not reconstruct from prose what deterministic preparation already returns.
In particular, the model/adapter must not invent:

- baseline SHA;
- candidate branch;
- builder/reviewer worktree paths;
- checkpoint/work-unit identity;
- pass-scoped semantic-result paths.

Consume the exact supported core/CLI outputs.

### Sealed-run immutability

Before first start, packet editing is allowed through supported spec surfaces.
After the execution seal exists, packet/source identity is immutable. A changed
mission requires a fresh run; do not reopen a sealed run through a re-approval
cycle.

## Validation contract

Before declaring repository work complete:

1. `./validate.sh` passes.
2. `./release_gate.sh` passes at release boundaries.
3. Adapter changes pass adapter conformance/portability/doctor checks.
4. `git diff --check` is clean.
5. Public-surface changes pass checkout portability and secret/public-surface
   checks.
6. Runtime authority/concurrency changes have behavioral regression coverage,
   including both success/failure process exit codes where concurrency matters.

GitHub Actions is an independent compatibility/pressure surface, not the sole
release authority. A release should have both coherent source validation and
cross-platform CI evidence.

## Commit and publication discipline

- Prefer one coherent commit per release/hardening slice.
- Commit messages should describe the product behavior changed.
- Never intentionally bypass a Loop/host guard to publish.
- If a local agent cannot push because a guard withholds that authority, stop and
  hand the operator the exact command rather than disguising it.
- Repository APIs may be used directly when the operator explicitly delegates
  repository maintenance to the system performing the change; this is separate
  from a governed Loop run's no-push authority.

## Reporting

Closeouts should distinguish:

- source/runtime behavior actually proven;
- tests executed and their exact results;
- CI results;
- installed parity when relevant;
- known limitations or unproven claims;
- whether promotion/publication occurred.

Do not turn weak grep checks or final counter values into stronger concurrency or
security claims than they prove.

## See also

- `README.md`
- `SECURITY.md`
- `docs/SECURITY_MODEL.md`
- `docs/OPERATOR_RUNBOOK.md`
- `docs/architecture/`
- `docs/ADAPTER_DEVELOPMENT.md`
- `CHANGELOG.md`
