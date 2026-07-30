# First Pilot

## Scope

Phase 1 of the OwnFramework Loop rollout. One repository. One builder.
One reviewer. One work packet. Expected spend under $1.00. operator
supervised.

## Repository

Recommended first pilot: a small, low-risk repository that already has a
deterministic test suite. The pilot does NOT touch:

- `production-host-1`
- `production-host-2`
- `personal-project-tree`
- `personal-project-tree`
- `personal-project-tree`
- any production repository

A disposable fixture repository is acceptable. The fixture must live
under `/Users/mr.mrs.london/projects/<your-pilot-name>`.

## Work class

Choose ONE of:

- `TESTING` (e.g., add regression tests for an existing behavior)
- `DOCUMENTATION` (e.g., document a public API)
- `BUG` (small, contained)

Avoid `HARDENING`, `TRACKED_CONTRACT`, `RUNTIME_CANDIDATE`,
`NEW_REPOSITORY` for the first pilot.

## Setup

1. `bash /Users/mr.mrs.london/projects/plugins/ownframework-loop/install.sh`
2. `cd /Users/mr.mrs.london/projects/<your-pilot-name>`
3. `claude --plugin-dir /Users/mr.mrs.london/.claude/skills/of-loop`
4. Run `/of-loop:spec "..."` and answer the spec questions.
5. Inspect the generated `WORK_PACKET.md`. Tighten scope if needed.
6. `/of-loop:spec approve <run-id>`.

## Launch

Two terminal tabs:

**Builder:**

```text
/loop /of-loop:build <run-id>
```

**Reviewer:**

```text
/loop /of-loop:review <run-id>
```

## Pass criteria for the first pilot

- The packet reaches `APPROVED` in 1–2 repair rounds.
- operator manually merges the candidate branch (no autonomous merge).
- Zero autonomous push, merge, or deploy events.
- Zero secret / prompt-injection / scope-exceeded events.
- Zero stale-candidate review invalidations beyond 1.
- Mean repair rounds per work unit under 1.3.
- Total spend under $1.00.
- All deterministic fixture tests pass.

## Failure modes the first pilot should reveal

- A misnamed or missing skill (`/of-loop:build` does not resolve).
- A hook firing on a benign command (false positive).
- A packet the reviewer cannot prove (criteria too vague).
- A build receipt that the CLI rejects (schema mismatch).
- A reviewer mutation that triggers `BLOCKED`.
- A `/loop` self-paced session that does not stop on a terminal state.

If any of these occur, file them as findings, fix the plugin, and
re-run the pilot. Do not move to Phase 2 until Phase 1 passes cleanly.

## Promotion gates

After Phase 1 passes:

- Phase 2: 3–5 packets on the same repo (mixed work classes).
- Phase 3: one additional repository.
- Phase 4: 3–4 repositories. Only after measuring usage and stability.

Each phase requires operator-supervised observation.
