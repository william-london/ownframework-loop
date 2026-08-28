---
name: build
description: OwnFramework Loop — build pass. One invocation performs at most one bounded build or repair pass. Validates APPROVAL.json, claims the build, runs deterministic build preparation (branch, baseline, worktree), materializes the BUILD_AGENT_RESULT skeleton, invokes a fresh `of-builder` agent, then calls the deterministic build finalizer. Safe to invoke under `/loop`.
user-invocable: true
---

# /of-loop:build — one bounded build or repair pass

The build skill is a thin workflow coordinator. It performs at most one
build pass per invocation. It MUST be invocable by `/loop` (do not add
any frontmatter that prevents that). It invokes a fresh `of-builder`
agent via the Agent tool and never performs the entire build procedure
in this parent session.

## Pass responsibilities

1. Validate the target repository (canonical repo resolved via `git
   rev-parse --show-toplevel`).
2. Validate the work packet is present and validates against the V3
   schema (PROGRAM) or V2 (SINGLE).
3. Validate that APPROVAL.json exists and binds to the current packet
   bytes (canonical repo, baseline branch, baseline SHA, packet SHA,
   confirmation token, candidate_branch).
4. Validate the current state allows a build claim
   (`READY_TO_BUILD` or `CHANGES_REQUESTED`).
5. Claim the build atomically (`READY_TO_BUILD/CHANGES_REQUESTED ->
   BUILDING`) and increment `build_pass_count`. Use `ofloop build
   claim <repo> <run-id>`.
6. Run `ofloop build prepare <repo> <run-id>` to deterministically
   resolve and create/reuse the builder worktree at
   `.worktrees/ownframework-loop/<run-id>/builder` on the candidate
   branch (resolved via `branch_resolver`, honoring
   `packet.target.candidate_branch_prefix` or the
   `factory/candidate/<run-id>` default). The prepare step is the
   single source of truth for worktree path, candidate branch, baseline
   SHA, current checkpoint, work_unit_id, packet SHA, and approval SHA.
7. Verify the canonical branch is clean and untouched by anyone other
   than this run.
8. Materialize the `BUILD_AGENT_RESULT.json` skeleton at the run
   scratch path via `ofloop build agent-skeleton <repo> <run-id>`. Pass
   the schema-conformant path and the prepared context to the agent.
9. Invoke a fresh `of-builder` agent through the Agent tool, providing
   the prepared context (worktree, branch, baseline_sha, cp_id,
   work_unit_id, agent_result_path). The agent fills the runtime-
   dependent keys in place and never renames top-level keys.
10. Collect the agent's semantic `BUILD_AGENT_RESULT.json`. The agent
    does NOT write the authoritative build receipt.
11. Call `ofloop build finalize <repo> <run-id> <agent-result.json>`.
    The finalizer independently verifies the candidate SHA, ancestry,
    branch, diff counts, allowed/protected/elevated paths, secret
    patterns, runs validations, and writes the authoritative
    `BUILD_RECEIPT.json`. The model cannot influence the finalizer's
    verdict on any of these checks.
12. Emit the operator marker.

## No-work fast paths

- If the run is in a terminal state (APPROVED / BLOCKED / STOPPED),
  emit the stop marker and do not invoke the agent.
- If the run is in REVIEWING (waiting for the reviewer), emit the
  wait marker and do not invoke the agent.
- If no APPROVAL.json is present, refuse with a clear error and do
  not invoke the agent.

## What the build skill MUST NOT do

- Merge, push, create a remote, deploy, or operate on production.
- Reset, stash, clean, revert, or commit unrelated work.
- Modify protected paths unless explicitly listed in the packet's
  `elevated_allowed_paths` (and only when the packet is approved).
- Silently broaden scope or add work units the operator did not request.
- Approve its own work.
- Write the authoritative build receipt.
- Run a second build pass inside one invocation.
- Issue raw `git worktree add`, `git worktree remove`, or `git branch`
  for ordinary pass setup. The `ofloop build prepare` step is the
  sole owner of worktree creation and branch resolution. v0.4.3.

## Operator marker

After the pass, emit:

```
OF_LOOP_OPERATOR_MARKER
OF_LOOP_RUN_ID=<run-id>
OF_LOOP_ROLE=builder
OF_LOOP_STATE=<state>
OF_LOOP_ACTION=RESCHEDULE|STOP
OF_LOOP_NEXT_DELAY_MINUTES=<int>
OF_LOOP_REASON=<short>
```

Scheduling policy:

| State after pass | Action | Next delay |
|---|---|---|
| `READY_TO_BUILD`, `BUILDING`, `CHANGES_REQUESTED` | RESCHEDULE | 0 |
| `READY_FOR_REVIEW` | RESCHEDULE | 10 |
| `REVIEWING` | RESCHEDULE | 15 |
| `APPROVED`, `BLOCKED`, `STOPPED`, `AWAITING_APPROVAL` | STOP | 0 |

## CLI surface used by the build skill (v0.4.3)

- `ofloop spec status <repo> <run-id>` — initial check
- `ofloop build claim <repo> <run-id>` — atomic claim
- `ofloop build prepare <repo> <run-id>` — deterministic
  branch/baseline/worktree preparation; sole owner of worktree add
- `ofloop build agent-skeleton <repo> <run-id>` — materializes the
  schema-conformant BUILD_AGENT_RESULT.json skeleton
- `ofloop build finalize <repo> <run-id> <agent-result.json>` — finalizer
- `ofloop build marker <repo> <run-id>` — emit marker

The skill uses the `lib/ownframework_loop/` Python library directly for
packet validation, approval binding, and worktree creation. It never
edits `STATE.json` directly.

## Anti-patterns

- Performing the build inside the parent conversation instead of a fresh agent.
- Letting the builder agent create a remote or push to one.
- Letting the builder agent write a build receipt for a candidate that
  does not exist in the worktree.
- Letting the build session continue past one pass when launched under `/loop`.
- Trusting a model-authored `next_state` from the agent result.
- Issuing more than one build pass per invocation. (v0.3.7 F-5-01: a single
  pass may produce MULTIPLE files / MULTIPLE commits / a coherent subsystem so
  long as `risk_budget` is honoured — the cap is the packet budget, not a
  per-pass file count.)
- Letting the parent model issue raw `git worktree add`, `git worktree
  remove`, or invent the candidate branch. v0.4.3.

## Canonical scheduling UX (v0.4.3)

The supported scheduling invocation is the bare slash command — no
cadence grammar, no `15m`, no cron syntax:

```
/loop /of-loop:build <run-id>
```

The operator does not type an interval. Native Claude `/loop` defaults
to `10m` cadence, which is acceptable for both lanes. If a different
cadence is required, the operator types it explicitly
(e.g. `/loop 15m /of-loop:build <run-id>`).


## PROGRAM mode (v3 packets)

When `WORK_PACKET.md` has `execution_mode: program`, the operator (NOT
this skill) drives the checkpoint graph via:

  - `ofloop program init <repo> <run-id>` — materialise `program` state
  - `ofloop loop run <repo> [mission]` — drive one checkpoint per pass

This skill remains the single pass-per-invocation entry for one
checkpoint. It does NOT replace the orchestrator and MUST NOT be
parallelized into a multi-checkpoint loop within one invocation.

The per-checkpoint cumulative ceilings are derived at program init
from the smaller of (a) the packet-level global risk_budget and (b)
the sum of per-checkpoint risk_budgets. The effective cumulative cap
NEVER exceeds the human-approved packet-level envelope. v0.4.3.
