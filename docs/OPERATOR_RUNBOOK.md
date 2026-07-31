# Operator Runbook

This runbook is for operator. It assumes the plugin has been installed
via `install.sh`. If you have not installed it, see the README quickstart.

## 1. Create a mission

```bash
cd /path/to/target-repo
claude --plugin-dir $HOME/.claude/skills/of-loop
```

Inside the Claude session:

```text
/of-loop:spec "add a per-IP rate limit to /api/sync"
```

The skill investigates the repo, asks only the minimum required questions,
and writes a packet at:

```text
<target-repo>/.ownframework-loop/<run-id>/WORK_PACKET.md
```

The packet is `human_approved: false`. The loop cannot run until you
approve it.

## 2. Approve the packet

Open the packet, read the metadata and the Markdown body. When satisfied:

```text
/of-loop:spec approve <run-id>
```

Approval stamps `human_approved: true` and binds the SHA-256 of the
packet bytes. The run transitions to `READY_TO_BUILD`.

## 3. Start the two loops

Open two terminal tabs in the target repo (with the plugin loaded):

**Builder tab:**

```text
/loop /of-loop:build <run-id>
```

**Reviewer tab:**

```text
/loop /of-loop:review <run-id>
```

Both sessions run self-paced via Claude Code's `/loop` command. Each pass
spawns a fresh agent through the Agent tool, so the parent `/loop`
context never carries build state.

## 4. Watch the markers

Every pass emits a compact operator marker:

```text
OF_LOOP_OPERATOR_MARKER
OF_LOOP_RUN_ID=<run-id>
OF_LOOP_ROLE=builder|reviewer
OF_LOOP_STATE=<state>
OF_LOOP_ACTION=RESCHEDULE|STOP
OF_LOOP_NEXT_DELAY_MINUTES=<int>
OF_LOOP_REASON=<short>
```

At a terminal state (`APPROVED`, `BLOCKED`, `STOPPED`), the loop emits
`OF_LOOP_ACTION=STOP` and exits.

## 5. Inspect state at any time

```bash
ofloop doctor /path/to/target-repo --run-id <run-id>
```

Prints current state, packet summary, receipt presence, verdict, and
stop flag.

## 6. Stop a loop

Inside the spec session:

```text
/of-loop:spec stop <run-id> --reason "manual halt"
```

This writes `STOP` and transitions any nonterminal state to `STOPPED`.
The builder and reviewer loops exit on their next tick.

## 7. Inspect events

```bash
cat /path/to/target-repo/.ownframework-loop/<run-id>/EVENTS.log
```

Every transition, receipt, verdict, stop, and hook-block event appears
here. The file is append-only JSON Lines.

## 8. Amend a packet

```text
/of-loop:spec amend <run-id> "raise max_diff_lines to 600"
```

Records the amendment request. Edit `WORK_PACKET.md` manually, then
re-run `/of-loop:spec approve <run-id>`. The SHA changes; the previous
approval is invalidated.

## 9. Recover a crashed session

If a `/loop` session crashed mid-pass:

1. Inspect `EVENTS.log` for the last transition.
2. If the state is `BUILDING`, the next builder pass will see the
   state and refuse (no concurrent builder). Manually transition to
   `READY_FOR_REVIEW` only if a build receipt exists. Otherwise run:
   `ofloop build transition <repo> <run-id> --to READY_TO_BUILD --reason recovered`.
3. If the state is `REVIEWING`, the next reviewer pass will see the
   state and refuse (no concurrent reviewer). Manually transition to
   `READY_FOR_REVIEW` to force a fresh review:
   `ofloop build transition <repo> <run-id> --to READY_FOR_REVIEW --reason recovered`.

## 10. Resume after stop

`STOP` is terminal. To resume:

1. `rm <repo>/.ownframework-loop/<run-id>/STOP`
2. Transition back to `READY_TO_BUILD` or `READY_FOR_REVIEW` based on
   whether a build receipt exists.
3. Re-run `/of-loop:build <run-id>` or `/of-loop:review <run-id>`.

## 11. Archive a run

```text
/of-loop:spec abandon <run-id>
```

Records the abandonment. The state directory remains on disk for
auditability. You may remove it manually after inspection:

```bash
rm -rf /path/to/target-repo/.ownframework-loop/<run-id>
rm -rf /path/to/target-repo/.worktrees/ownframework-loop/<run-id>
```

## 12. Clean one run (without abandoning)

```bash
ofloop build transition <repo> <run-id> --to STOPPED --reason cleanup
```

Then remove the run directory and worktree. This is also how you
recover when the cleanup scope is bounded to one run.

## 13. Roll back the plugin

```bash
bash /path/to/ownframework-loop/rollback.sh
```

Restores the previous installed copy from the timestamped backup. The
backup directory is `~/.claude/skills/of-loop.backup-<timestamp>/`.

## 14. Inspect cost and pass counts

```bash
ofloop doctor <repo> --run-id <run-id>
```

Returns `build_pass_count`, `review_pass_count`, `transitions_count`,
`repair_round`, `no_progress_streak`, and `state`. Per-pass model
spend is visible in the Claude Code session transcript; the plugin
does not require a separate metering layer.

## 15. Use escalation-target as a manual inspector

When a verdict marks `escalation_recommended: true` or
`EVENTS.log` shows a known escalation trigger:

1. Open escalation-target in a separate session.
2. Provide it the packet SHA, the candidate SHA, the verdict, and the
   findings.
3. escalation-target returns a manual investigation. You decide what to do.

The loop does not call escalation-target.

## 16. Local-only repositories

A packet with `target.classification: local_only` cannot create a
remote, push, or open a PR. The CLI refuses to add a remote to a
local-only repo. Hooks block push and merge.

## 17. New repositories

Use `work_class: NEW_REPOSITORY`. The spec skill calls
`ofloop new-repo <root> <project> --init-baseline` to bootstrap.
operator must merge the candidate branch manually.

## 18. Runtime-sensitive candidate work

Use `work_class: RUNTIME_CANDIDATE`. The loop produces and proves a
candidate patch only. It does not deploy or mutate a live service.

## 19. Two projects without sharing worktrees or state

Each repo has its own:

- `.ownframework-loop/<run-id>/`
- `.worktrees/ownframework-loop/<run-id>/`
- `.claude/loop.yaml` (per-repo policy)

Open a separate pair of `/loop` tabs per project.

## 20. Stop conditions

Stop and inspect if any of:

- The state is `BLOCKED` and you do not know why.
- `EVENTS.log` shows a escalation-target escalation marker.
- The reviewer wrote `verdict: HUMAN_REVIEW_REQUIRED`.
- The packet SHA drifted after approval.
- Hooks are firing on benign commands (verify hook config, not the
  underlying command).
