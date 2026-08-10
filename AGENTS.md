# AGENTS.md

This file is the **agent-operating contract** for the
`ownframework-loop` repository. It governs how an autonomous or
human-supervised agent (Claude Code or otherwise) makes changes in this
repository. It is doctrine, not a lane prompt.

The contract here is **self-contained**. It does not depend on any
private repository, private phase identifier, or private cross-repo
doctrine to be interpretable. An external contributor can read this
file and follow it without any access outside this repo.

---

## Scope

This contract covers work in **this repository only**:

- Source under `lib/`, `bin/`, `hooks/`, `skills/`, `agents/`,
  `schemas/`, `templates/`, `tests/`, `examples/`, `docs/`.
- Public-surface files (`README.md`, `AGENTS.md`, `CONTRIBUTING.md`,
  `SECURITY.md`, `CHANGELOG.md`, `LICENSE`, `THIRD_PARTY_NOTICES.md`,
  `.claude-plugin/plugin.json`).
- Validation and release scripts (`install.sh`, `uninstall.sh`,
  `rollback.sh`, `validate.sh`, `release_gate.sh`).

The canonical remote for this repository is configured under the
project maintainer's GitHub namespace and is recorded in
`.git/config`. The local clone is the source of truth for what is
currently checked in; pushes are an explicit human-controlled event
that the loop never performs on its own.

---

## What an agent may do in this repository

An agent operating on this repository may:

- Inspect, edit, refactor, test, commit, and push coherent validated
  work when appropriate to complete an assigned task.
- Run the loop's local validation lane: `validate.sh`,
  `release_gate.sh`, the focused test suite, `git diff --check`.
- Run the loop's hooks and helper scripts in the working copy without
  touching system-wide install paths.

What an agent may **not** do without explicit operator authorization:

- Force-push, push to `--all`, push `--tags`, push `--mirror`, push
  to non-named branches, or perform destructive history rewrites.
- Delete or rewrite prior commits for aesthetics.
- Bypass the textual command guardrails by indirection
  (`eval`, hidden Python `subprocess`, variable assembly).
- Modify `.git/` metadata directly.
- Edit authoritative run artifacts (`STATE.json`, `BUILD_RECEIPT.json`,
  `REVIEW_VERDICT.json`, `WORK_PACKET.md`, `APPROVAL.json`,
  `EVENTS.log`, `LOCK`, `STOP`) by direct write — those go through
  the `ofloop` CLI.
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

- Publish, deploy, or call outbound network services.
- Send mail, post to social media, push notifications, or trigger
  customer-facing flows.
- Modify the system beyond a temporary scratch directory and the
  repository worktree.

### Public action

- No public deploy, no newsletter, no social, no customer-facing or
  vendor-facing outbound from this repository's authoring activity.
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

### Hooks and templates

- Hooks under `hooks/` and templates under `templates/` are part of
  the loop's local reproduction. They are version-controlled here.
- Installed copies elsewhere are regenerated from this repo.

---

## Validation contract

Before declaring any change complete, an agent must prove:

1. `./validate.sh` — the canonical proof lane for the loop.
2. Where the change touches `release_gate.sh` or `rollback.sh`, the
   focused test suite covers the boundary.
3. `git diff --check` — no whitespace or conflict markers.

If any of those fail, the change is not done.

When the change touches the public-surface set (`README.md`,
`AGENTS.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`,
`LICENSE`, `THIRD_PARTY_NOTICES.md`, `.claude-plugin/plugin.json`),
also re-run the full public-leak scan (Phase 10 evidence below)
and the README internal-link check.

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
- `docs/ARCHITECTURE.md`, `docs/STATE_MACHINE.md`,
  `docs/SECURITY_MODEL.md`, `docs/OPERATOR_RUNBOOK.md`.
- `docs/history/` — preserved engineering snapshots from earlier
  releases, kept for context only.
