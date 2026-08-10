# AGENTS.md — OwnFramework Loop

This file is the **agent-operating contract** for the OwnFramework
Loop repository. It is doctrine, not a lane prompt.

The owner-authorized harness autonomy doctrine established in the
OwnFramework Cockpit repository (`AGENTS.md` §1,
phase0-a0-6c-owner-autonomy-doctrine-correction-v1) is the
controlling reference for agent authority in this repo. This file
extends that doctrine with the rules specific to OwnFramework Loop.

## Standing harness authority

This repo inherits the six-axis operating model (CAPABILITY,
SPECIALIZATION, OWNERSHIP, AUTHORITY, TASK_INTENT, EVIDENCE) and the
four invariants (specialization is not a capability limit; ownership
is not exclusive execution right; preferred path is not a mandatory
blocking path; governance is not permission denial). The operating
agent (Claude Code, Hermes, or William) works under standing
harness authority:

- May inspect, edit, refactor, test, commit, and push coherent work
  when appropriate to complete the assigned task, unless William
  excludes the effect.
- May run the loop's local validation lane (`validate.sh`,
  `release_gate.sh`, the focused test suite) when needed.
- May run the loop's hooks / scripts in the working copy without
  touching system-wide install paths.

Reporting fields (COMMIT_MADE, PUSH_MADE, REMOTE_TARGETS) document
what occurred; they are not permission gates.

## Repo-specific rules (preserve)

The following rules apply to **work in this repository**. They are
either product-envelope rules (what this repo's runtime must not
do) or engineering quality rules (how work in this repo should be
done).

### Canonical remote policy

As of 2026-08-10 this repo has a canonical remote configured under
the `PepasLokasTv` GitHub org. The operating agent commits locally and
pushes to the canonical remote when coherent validated work is ready,
unless William excludes the push.

The expected closeout field is `PUSH_MADE=yes` when a push occurred,
`PUSH_MADE=no` when the work stayed local. Local-only runs (commits
without a push) are explicitly authorized and do not require a remote
to be configured.

Reverting this policy to a local-only stance is an explicit task-scope
event and is called out in the closeout block when applied.

### Synthetic / non-customer data

- No real customer / prospect / vendor / payroll / bank / tax /
  legal / employee data, no real tokens, no live payment
  instruments, no production secrets, no `.env*` in source.
- Fixtures under `tests/`, `examples/`, and any synthetic seed
  data are the only acceptable source of test data.

### Public action

- No public deploy, no newsletter, no social, no customer-facing or
  vendor-facing outbound from this repo's authoring activity.
- Publishing artifacts from this repo happens through an explicit
  owner-authorized release lane, not as part of an ordinary
  authoring commit.

### Loop / install / rollback scripts

- `install.sh`, `uninstall.sh`, `rollback.sh`, `release_gate.sh`,
  `validate.sh`, and the helpers under `bin/`, `lib/`, and
  `scripts/` are the canonical local surfaces for the loop.
- The loop runs in the working copy. It is **not** edited by
  hand-editing an installed copy elsewhere on disk.

### Hooks and templates

- Hooks under `hooks/` and templates under `templates/` are part of
  the loop's local reproduction. They are version-controlled here;
  installed copies elsewhere are regenerated from this repo.

## Validation contract

Before declaring any change complete:

1. `validate.sh` — the canonical proof lane for the loop.
2. Where the change touches `release_gate.sh` or rollback, the
   focused test suite covers the boundary.
3. `git diff --check` — no whitespace / conflict markers.

If any fails, the change is not done.

## Commit / push discipline

- One local commit per coherent slice.
- Commit message style: `ownframework-loop: <verb> <slice>`.
- Push to the canonical remote when coherent validated work is ready,
  unless William excludes the push. `PUSH_MADE=yes` is the expected
  closeout field when the work was pushed. Local-only commits
  (`PUSH_MADE=no`) are explicitly authorized and do not require the
  absence of a remote.
- Force-push, `--tags`, `--all`, `--mirror`, pushes to non-named
  branches, and destructive cleanup remain explicit task-scope
  concerns and must be called out in the closeout block when used.

## Reporting

Every agent task that touches this repo reports using the marker
block format from `ownframework-cockpit/AGENTS.md` §8 — `RESULT`,
`LANE`, `FILES_CHANGED`, `COMMANDS_RUN`, `VALIDATION_RESULTS`,
`RUNTIME_MUTATED`, `DOCKER_MUTATED`, `WEBHOOK_MUTATED`,
`EMAIL_SENT`, `CUSTOMER_DATA_USED`, `RAW_BODY_PRINTED`,
`SECRETS_PRINTED`, `COMMIT_MADE`, `PUSH_MADE`, `REMOTE_TARGETS`,
`AUTHORIZED_EFFECTS`, `ACTUAL_EFFECTS`, `BLOCKERS`,
`RECOMMENDED_NEXT_STEP`.

No giant logs. No raw bodies. No secrets. No free-form text outside
the markers.

## See also

- `README.md`, `CHANGELOG.md`, `THIRD_PARTY_NOTICES.md`,
  `LOOP_REPAIR_MISSION_REPORT.md`, `REPORT.md`, `docs/`.
- `ownframework-cockpit/AGENTS.md` for the canonical doctrine
  reference.
