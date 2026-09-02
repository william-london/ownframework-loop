# First Pilot

The first pilot proves the current supervisor-first architecture, not the
historical plugin-driven `/loop` workflow.

## Target

Use one small disposable or low-risk Git repository with deterministic tests.
Do not use a production repository for the first live proof.

## Setup

From the OwnFramework Loop source checkout:

```bash
./install.sh
./bin/install-adapter claude-code
./bin/install-supervisor
```

Use another adapter only when that adapter is explicitly live-verified for the
pilot you intend to run.

## SPEC

Create one bounded packet. Prefer a small BUG, TESTING, or DOCUMENTATION mission.

Before execution, inspect:

- exact repo/baseline;
- allowed/protected paths;
- acceptance criteria;
- validation commands;
- pass/source budgets;
- network_read_allowlist;
- human-only promotion authority.

## Launch

```bash
ofloop supervisor enqueue <repo> <run-id>
ofloop supervisor status <repo> <run-id>
```

Do not launch separate builder/reviewer terminal loops. The commissioned
supervisor owns scheduling.

## Pass criteria

The pilot passes when:

- a real builder changes source in its prepared worktree;
- candidate work is committed with exact SHA evidence;
- a fresh real reviewer assesses that exact SHA;
- reviewer source remains read-only;
- bounded repair occurs naturally if requested;
- terminal state is APPROVED;
- no duplicate semantic worker appears;
- no unauthorized external effect occurs;
- no routine permission prompt requires an operator;
- cleanup leaves the supervisor healthy/IDLE;
- the operator performs final promotion manually.

## Failures worth fixing upstream

Treat these as framework findings, not reasons to babysit the run:

- stale/ambiguous runtime generation;
- service cannot survive shell closure/restart;
- model waits for permission inside authorized work;
- reviewer can mutate candidate source;
- pass cannot write its one semantic result;
- dependency domain was knowable at SPEC time but not authorized;
- duplicate worker/claim;
- restart cannot reconcile a proven partial state transaction;
- disposable runtime files accumulate indefinitely;
- docs/skills send the operator into retired `/loop` scheduling.

After the pilot passes cleanly, use real client-shaped PROGRAMs. Future Loop
changes should be driven by concrete project defects rather than speculative
hardening.
