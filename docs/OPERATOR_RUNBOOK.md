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

## 2. Approve the packet (HUMAN ONLY)

The approval is **human-only** and **must be performed by you** in your
normal interactive Terminal. Do NOT delegate this to any agent, script,
pty helper, pexpect, tmux injection, AppleScript, or subprocess
wrapper. The hardened adapter refuses all such indirections.

Open the packet, read the metadata and the Markdown body. When satisfied,
in your Terminal run the canonical approval command (replace SPEC with
the spec subcommand):

```
ofloop SPEC approve /path/to/target-repo <run-id>
```

The CLI prompts you for a confirmation token derived from the packet
SHA-256. Type the token; the CLI writes APPROVAL.json and the run
transitions to READY_TO_BUILD.

## 2.5. PROGRAM mode (multi-checkpoint)

For v3 PROGRAM packets, the program init subcommand (replace PROGRAM
with the program subcommand) materializes the per-checkpoint graph. The
same two /loop lanes drive the run; the Claude-native review finalize
automatically advances to the next checkpoint after an APPROVED review.
No loop-run subcommand invocation is required from the operator.

After the final checkpoint is APPROVED, the top-level state transitions
to terminal APPROVED and both lanes exit.

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

Both sessions run via Claude Code's `/loop` command. The operator
types no cadence, no cron expression, no worktree command, no branch
command, no build-claim / finalize / skeleton / loop-run command.
Those are internal protocol surfaces invoked by the skills; they are
not part of the operator-facing UX.

Each pass spawns a fresh agent through the Agent tool, so the parent
`/loop` context never carries build state.

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
