# Troubleshooting

## The plugin does not appear in Claude Code

```bash
ls -la /Users/mr.mrs.london/.claude/skills/of-loop
ls /Users/mr.mrs.london/.claude/skills/of-loop/skills
```

If missing, run:

```bash
bash /Users/mr.mrs.london/projects/plugins/ownframework-loop/install.sh
```

Inside the Claude session, run `/reload-plugins`.

## A hook blocks a benign command

1. Identify the hook output (Claude Code prints the block reason).
2. Run the command through `ofloop` first. The CLI uses the same
   guards as the hooks, so what passes the CLI passes the hooks.
3. If you must run a one-shot command outside the guardrails, prefix
   it with `OWNFRAMEWORK_ALLOW=1` (only for the operator; documented
   in `hooks/block_dangerous_bash.sh`). Do not use this prefix for
   push, merge, deploy, or remote creation — those are forbidden
   structurally, not by prefix.

## State transitions fail with "invalid transition"

Read `EVENTS.log` to see the last state. The state machine is
documented in `docs/STATE_MACHINE.md`. The transition must be in the
allowed map; otherwise the CLI rejects it.

## Packet validation fails

Run the validator explicitly:

```bash
python3 -c "
import sys; sys.path.insert(0, '/Users/mr.mrs.london/.claude/skills/of-loop/lib')
from ownframework_loop import packet
meta, _ = packet.parse_packet_file(__import__('pathlib').Path('WORK_PACKET.md'))
print(packet.validate_packet_metadata(meta))
"
```

The validator lists each missing or invalid field with the field name.
Fix the metadata block; do not edit `STATE.json` directly.

## The reviewer cannot find a SHA

The reviewer worktree is detached at the candidate SHA. If git cannot
resolve the SHA, the receipt is invalid. Check:

```bash
git -C <repo> cat-file -e <candidate_sha>
```

If the SHA does not exist, the build never committed, or the receipt
references a wrong SHA. Rebuild and re-receipt.

## Build refuses with "dirty baseline"

The repo has uncommitted changes that do not belong to this run.

```bash
git -C <repo> status --porcelain
```

If the changes belong to this run, complete or revert them. If they
are unattributed work, stop and ask the operator — do not reset, stash,
clean, or revert.

## Build refuses with "wrong repository"

The current working directory is not the canonical repo, or the branch
is not `master`, or the repo has remotes that the packet forbids.

```bash
ofloop doctor <repo>
```

## Reviewer returns `STALE_CANDIDATE`

The candidate SHA drifted between review start and verdict write.
The loop re-pins to the current SHA on the next pass. No action
required unless this persists.

## Reviewer returns `BLOCKED` with tracked mutation

The reviewer changed tracked source during its pass. The verdict
records the changed paths. The run is blocked. Inspect
`REVIEW_VERDICT.json` and the changed paths. Restart the reviewer
pass only after manual inspection.

## The smoke budget is exceeded

`TOTAL_MODEL_SMOKE_BUDGET_USD=3.00` is a hard ceiling for the
bounded real-model smoke. If exceeded, the smoke aborts. Re-run after
inspecting the artifact.

## The release gate fails

`release_gate.sh` runs the deterministic fixtures, the validator, and
the plugin-load smoke. A failure includes the failing test name and
the expected vs. actual markers. Repair the failing component and
re-run.
