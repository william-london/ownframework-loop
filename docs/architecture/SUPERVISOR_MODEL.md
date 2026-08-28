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
