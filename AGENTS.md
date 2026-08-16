# AGENTS.md

This file is the **agent-operating contract** for the
`ownframework-loop` repository. It governs how an autonomous or
human-supervised coding agent (Claude Code, Codex, or another supported
adapter host) makes changes in this repository. It is doctrine, not a lane
prompt.

The contract here is **self-contained**. It does not depend on any
private repository, private phase identifier, or private cross-repo
doctrine to be interpretable. An external contributor can read this
file and follow it without any access outside this repo.

---

## Scope

This contract covers work in **this repository only**:

- Deterministic source under `lib/`, `bin/`, `schemas/`, `templates/`,
  `tests/`, `examples/`, and `docs/`.
- Agent-host integration under `skills/`, `agents/`, `hooks/`,
  `.agents/skills/`, `adapters/`, and `.claude-plugin/`.
- CI and repository automation under `.github/workflows/`.
- Public-surface files (`README.md`, `AGENTS.md`, `CONTRIBUTING.md`,
  `SECURITY.md`, `CHANGELOG.md`, `LICENSE`, `THIRD_PARTY_NOTICES.md`,
  adapter/architecture documentation, and agent-host metadata).
- Validation and release scripts (`install.sh`, `uninstall.sh`,
  `rollback.sh`, `validate.sh`, `release_gate.sh`).

The canonical remote for this repository is configured under the
project maintainer's GitHub namespace and is recorded in
`.git/config`. The local clone is the source of truth for what is
currently checked in; pushes are an explicit human-controlled event
that the loop never performs on its own.

---

## Core versus adapter authority

OwnFramework Loop's deterministic protocol is agent-neutral. The core owns:

- work-packet parsing and validation;
- interactive human approval and packet-hash binding;
- lifecycle transitions and locks;
- scope, runtime, and repair budgets;
- candidate Git SHA identity;
- exact-SHA verdict binding;
- terminal-state semantics and the boundary before human promotion.

Agent adapters may provide skills, agents, hooks, discovery, installation,
and host-specific enforcement. They must not create a parallel approval,
state, repair, candidate, verdict, or promotion path.

Claude Code is the stable/reference adapter and currently has stronger native
hook/interception hardening. Experimental adapters must not claim equivalent
host enforcement without live evidence.

---

## What an agent may do in this repository

An agent operating on this repository may:

- Inspect, edit, refactor, test, commit, and push coherent validated
  work when appropriate to complete an assigned task.
- Run the loop's local validation lane: `validate.sh`,
  `release_gate.sh`, the focused test suite, adapter conformance, and
  `git diff --check`.
- Run the loop's hooks and helper scripts in the working copy without
  touching system-wide install paths unless an explicit isolated install
  proof is part of the task.

What an agent may **not** do without explicit operator authorization:

- Force-push, push to `--all`, push `--tags`, push `--mirror`, push
  to non-named branches, or perform destructive history rewrites.
- Delete or rewrite prior commits for aesthetics.
- Bypass textual/mechanical command guardrails by indirection
  (`eval`, hidden Python `subprocess`, variable assembly).
- Modify `.git/` metadata directly.
- Edit authoritative run artifacts (`STATE.json`, `BUILD_RECEIPT.json`,
  `REVIEW_VERDICT.json`, `WORK_PACKET.md`, `APPROVAL.json`,
  `EVENTS.log`, `LOCK`, `STOP`) by direct write — those go through
  the `ofloop` CLI/core.
- Create an adapter-specific approval or lifecycle truth that can diverge
  from the deterministic core.
- Inject real customer, prospect, vendor, payroll, bank, tax, legal,
  employee, or production data, real tokens, live payment instruments,
  production secrets, or `.env*` files into the repository.

Reporting fields such as `COMMIT_MADE`, `PUSH_MADE`, and
`REMOTE_TARGETS` document what occurred; they are not permission
gates.

---

## Repository-local engineering rules

These rules apply to **work in this repository**. They are either
product-envelope rules (what this repo's runtime must not do) or
engineering quality rules (how work in this repo should be done).

### Canonical remote policy

This repository has a canonical remote configured under the project
maintainer's GitHub namespace. The operating agent commits locally and
pushes to the canonical remote when coherent validated work is ready,
unless the operator explicitly excludes the push.

The expected closeout field is `PUSH_MADE=yes` when a push occurred,
`PUSH_MADE=no` when the work stayed local. Local-only runs (commits
without a push) are explicitly authorized and do not require a remote
to be configured.

Reverting this policy to a local-only stance is an explicit
task-scope event and is called out in the closeout block when
applied.

### Synthetic / non-customer data only

- No real customer, prospect, vendor, payroll, bank, tax, legal, or
  employee data.
- No real tokens, no live payment instruments, no production
  secrets, no `.env*` in source.
- Fixtures under `tests/`, `examples/`, and any synthetic seed data
  are the only acceptable source of test data.

### No public side effects from normal tests

Normal tests must not:

- Publish, deploy, or call outbound network services except explicit CI
  package/discovery checks against public package registries.
- Send mail, post to social media, push notifications, or trigger
  customer-facing flows.
- Modify the system beyond a temporary scratch directory, isolated test HOME,
  and the repository worktree.

### Public action

- No public deploy, newsletter, social post, customer-facing or vendor-facing
  outbound from ordinary repository authoring activity.
- Publishing artifacts from this repo happens through an explicit
  maintainer-authorized release lane, not as part of an ordinary
  authoring commit.

### Loop / install / rollback scripts

- `install.sh`, `uninstall.sh`, `rollback.sh`, `release_gate.sh`,
  `validate.sh`, and the helpers under `bin/`, `lib/`, `scripts/`,
  and `hooks/` are the canonical local surfaces for the loop.
- The loop runs in the working copy. It is **not** edited by
  hand-editing an installed copy elsewhere on disk — installed copies
  are regenerated from this repo.

### Hooks, skills, adapters, and templates

- Hooks under `hooks/` and templates under `templates/` are part of
  the loop's local reproduction. They are version-controlled here.
- Claude's stable plugin skill surface remains under `skills/` and
  `.claude-plugin/` for backward compatibility.
- Portable host-neutral Agent Skills live under `.agents/skills/`.
- Adapter metadata/docs live under `adapters/` and `docs/architecture/`.
- Installed copies elsewhere are regenerated from this repo or through the
  documented host installer/discovery mechanism.

---

## Validation contract

Before declaring any change complete, an agent must prove:

1. `./validate.sh` — the canonical proof lane for the loop.
2. Where the change touches `release_gate.sh` or `rollback.sh`, the
   focused test suite covers the boundary.
3. Adapter changes run the adapter conformance/portability/doctor checks.
4. `git diff --check` — no whitespace or conflict markers.

At release/promotion boundaries, `./release_gate.sh` must pass in a suitable
host environment. GitHub Actions may separate cross-platform source validation
from host-pressure release gating because live runner load is an environmental
property, not a source-correctness assertion.

If any required check fails, the change is not done.

When the change touches the public-surface set (`README.md`,
`AGENTS.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`,
`LICENSE`, `THIRD_PARTY_NOTICES.md`, `.claude-plugin/`, `.agents/skills/`,
`adapters/`, `docs/architecture/`, or `.github/workflows/`), also run the
checkout-portability/public-surface scan, README/link checks where applicable,
and the standard secret scan.

---

## Commit / push discipline

- One local commit per coherent slice.
- Commit message style: `ownframework-loop: <verb> <slice>`.
- Push to the canonical remote when coherent validated work is ready,
  unless the operator explicitly excludes the push. `PUSH_MADE=yes`
  is the expected closeout field when the work was pushed. Local-only
  commits (`PUSH_MADE=no`) are explicitly authorized and do not
  require the absence of a remote.
- Force-push, `--tags`, `--all`, `--mirror`, pushes to non-named
  branches, and destructive history rewrites remain explicit
  task-scope concerns and must be called out in the closeout block
  when used.

---

## Reporting

Every agent task that touches this repo reports using a compact,
evidence-oriented closeout. The closeout lists what was done, what
was proven, what was not done, and what is recommended next. It does
not contain giant logs, raw bodies, secrets, or free-form text outside
the structured fields.

---

## See also

- `README.md`, `CHANGELOG.md`, `THIRD_PARTY_NOTICES.md`,
  `CONTRIBUTING.md`, `SECURITY.md`, `LICENSE`.
- `docs/architecture/`, `docs/ADAPTER_DEVELOPMENT.md`,
  `docs/ARCHITECTURE.md`, `docs/STATE_MACHINE.md`,
  `docs/SECURITY_MODEL.md`, `docs/OPERATOR_RUNBOOK.md`.
- `docs/history/` — preserved engineering snapshots from earlier
  releases, kept for context only.
