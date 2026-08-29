# Durable Supervisor Architecture

OwnFramework Loop has one engineering state machine and one durable execution
clock.

## Authority split

The deterministic core owns packet validation, execution sealing, lifecycle
state, checkpoint selection, pass counters, worktrees, candidate identity,
exact-SHA review, reconciliation, finalizers, and terminal semantics.

`dispatch.py` is the sole typed work-order boundary for unattended hosts. It
serializes reconciliation plus the existing claim/prepare/skeleton owners and
returns exactly one of:

- `BUILD`
- `REVIEW`
- `WAIT`
- `TERMINAL`

The supervisor does **not** map Loop states to engineering actions itself.

`supervisor.py` owns only operational concerns:

- queue membership;
- one-worker claiming;
- provider/process lifetime;
- infrastructure retry/backoff;
- quarantine;
- runner identity;
- observed model cost;
- idle polling.

SQLite is therefore an operational ledger, not protocol truth.

## Normal unattended flow

```text
human / spec
    |
    v
WORK_PACKET + spec-time source snapshot
    |
    v
ofloop supervisor enqueue <repo> <run-id>
    |
    v
supervisor -> dispatch claim
                 |
                 +-- BUILD -> fresh builder process -> semantic result
                 |              |
                 |              v
                 |          deterministic build finalize
                 |
                 +-- REVIEW -> fresh reviewer process -> semantic assessment
                 |               |
                 |               v
                 |           deterministic review finalize
                 |
                 +-- WAIT -> no model call
                 |
                 +-- TERMINAL -> DONE
```

The loop continues through repair rounds and PROGRAM checkpoints because the
core returns the next dispatch decision after every deterministic finalization.

## Human boundary

SPEC remains human-originated. Normal execution has no approval ceremony or
confirmation token. The first legitimate build start creates the immutable
execution seal.

Terminal `APPROVED` still does not grant push, merge, deploy, publish,
payment, messaging, or remote mutation authority. Promotion remains outside
Loop.

## Claude reference runner

The first live runner launches one fresh non-interactive Claude Code process
for one semantic pass. It runs inside the exact deterministic worktree and
receives the exact work order. It must not call claim, prepare, finalize, push,
merge, deploy, or create remotes.

Runner/provider failure is infrastructure failure, not semantic `BLOCKED`.
The supervisor retries the same claimed pass within a bounded infrastructure
budget, then quarantines the job without inventing a protocol verdict.

## Interactive compatibility

`/loop /of-loop:build <run-id>` and
`/loop /of-loop:review <run-id>` remain useful foreground/debug UX.

The old `ofloop loop run` implementation is retired because it drove
finalizers without a real semantic builder/reviewer process. It is not an
unattended execution path.


## Operational ceilings

The supervisor carries bounded operational policy separately from protocol
truth. Enqueue defaults currently provide:

- one global active worker per supervisor database;
- up to 3 infrastructure failures before quarantine;
- an 8-hour wall-clock ceiling from first execution;
- a $25 observed/estimated model-cost ceiling.

The cost and wall ceilings are configurable at enqueue time. A ceiling
violation sets supervisor state to QUARANTINED; it does not manufacture
`BLOCKED` or alter the deterministic engineering verdict. Zero-cost semantic
replay/finalization is still allowed when a worker already completed its
artifact before a supervisor restart.

## Restart ownership

A RUNNING job records the live worker PID. Worker processes are launched in
their own process group. A second supervisor process sharing the same SQLite
database will not start another job while a live RUNNING owner exists.

After supervisor restart:

1. a still-live worker remains owned and is not duplicated;
2. a dead worker makes the same job QUEUED;
3. dispatch replays the same core claim;
4. a complete semantic artifact is finalized with zero additional model call;
5. an incomplete artifact launches a fresh worker for the same claimed pass.

Timeout first sends SIGTERM to the process group, waits briefly, then uses
SIGKILL only when needed.

## macOS service

The repository ships `install-supervisor-macos.sh`, which installs a per-user
`launchd` agent named `com.ownframework.loop-supervisor`. The generated
service uses the exact `ofloop` executable path selected at installation and
runs `ofloop supervisor serve` independently of any terminal working
directory.

Use `uninstall-supervisor-macos.sh` to remove the launch agent.

## Semantic-pass context, delegation, and timing

Every BUILD and REVIEW semantic pass is a fresh non-interactive Claude Code
process. Passes do not share a conversation window. Continuity is durable:
the sealed packet, exact worktree, checkpoint/AC ids, build receipt, review
verdict, and deterministic repair_context carry forward what the next pass
needs.

The reference runner exposes Claude Code's Agent and Skill tools alongside the
normal engineering tool set. Subagent delegation is optional and should be
used when it improves a complex pass, not as busy work. The same semantic-role
authority continues to apply to delegated work.

The supervisor main print-mode worker does not receive a --max-turns flag.
Agent-file maxTurns applies only when that custom agent is invoked through
Claude's agent mechanism.

For v3 packets, risk_budget.max_pass_runtime_seconds is the semantic worker
timeout authority. A positive supervisor serve --timeout-seconds value can
only narrow it. If neither is declared, the historical 3600-second fallback
applies.

## Live read-only observability

ofloop supervisor status exposes raw progress telemetry without mutating the
run: worker/execution elapsed seconds, time since the job row changed,
worker-log byte/mtime activity, recent attempt history, cost/token telemetry,
current core checkpoint state, worktree identity/cleanliness, and candidate
diff summary.

There is no deliberate delay between an actionable BUILD finalization and the
next REVIEW dispatch, or between a review-driven repair and the next BUILD.
The serve loop sleeps only while IDLE or while explicit backoff policy applies.
