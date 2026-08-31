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

`/of-loop:build <run-id>` and
`/of-loop:review <run-id>` remain useful foreground/debug UX.

The old `ofloop loop run` implementation is retired because it drove
finalizers without a real semantic builder/reviewer process. It is not an
unattended execution path.


## Operational ceilings

The supervisor carries bounded operational policy separately from protocol
truth. Enqueue defaults currently provide:

- configurable bounded host concurrency (default 1), with one active semantic
  owner per run/workspace;
- up to 3 infrastructure failures before quarantine;
- bounded transient-failure retry/circuit-breaker policy;
- no wall-clock ceiling by default;
- no model-cost ceiling by default;
- no provider-token ceiling by default.

Wall-clock, cost, and token ceilings are deliberately off unless funded. A
long sealed PROGRAM must be able to run to completion; unattended progress is
bounded by meaningful-progress protections (per-checkpoint and cumulative
pass/repair caps, no-progress detection, the identical-finding repetition
fuse, and failure-class retry policy), not by resource conservation.

When an operator wants a hard spend line, `--max-wall-seconds`,
`--max-cost-usd`, and `--max-total-tokens` are configurable at enqueue time.
Repository common-dir identity is provenance/grouping, not a repository-wide
mutex. The scheduler excludes only an already-owned candidate workspace.
Therefore two or more runs may execute concurrently in different candidate
branches of one repository, including runs that intentionally modify the same
logical path. Per-run BUILD/REVIEW handoff remains strictly sequential.

`--max-wall-seconds` defaults to the packet's declared
`risk_budget.max_runtime_seconds` when present, so a human-approved whole-run
envelope is honored. A ceiling violation sets supervisor state to QUARANTINED;
it does not manufacture `BLOCKED` or alter the deterministic engineering
verdict. Zero-cost semantic replay/finalization is still allowed when a worker
already completed its artifact before a supervisor restart. Unknown model cost
only quarantines while a cost ceiling is actually active.

## Restart ownership

A RUNNING job records the live worker PID. Worker processes are launched in
their own process group. A second supervisor process sharing the same SQLite database cannot duplicate a
live RUNNING job owner. Other eligible jobs may still run concurrently up to the
configured host ceiling when their workspace identities are distinct.

After supervisor restart:

1. a still-live worker remains owned and is not duplicated;
2. a dead worker makes the same job QUEUED;
3. dispatch replays the same core claim;
4. a complete semantic artifact is finalized with zero additional model call;
5. an incomplete artifact launches a fresh worker for the same claimed pass.

Timeout first sends SIGTERM to the process group, waits briefly, then uses
SIGKILL only when needed.

## Platform service

The canonical `install-supervisor.sh` wrapper commissions the durable service
from the installed vendor-neutral core.

On macOS, `install-supervisor-macos.sh` installs a per-user `launchd` agent
named `com.ownframework.loop-supervisor`. The generated
service uses the exact `ofloop` executable path selected at installation and
runs `ofloop supervisor serve` independently of any terminal working
directory.

Installation/refresh is guarded by two read-only, fail-closed ledger probes:

1. **live semantic work** — replacement is refused while a semantic worker
   is live (RUNNING job with an alive/unknown worker pid, or a non-terminal
   attempt of one);
2. **runtime-generation dependency** — every job binds the runtime
   generation that enrolled it (clean Git full SHA, dirty-source SHA-256, or installed-payload SHA-256). Replacement is refused while any non-terminal enrolled
   job (QUEUED, BACKOFF, RUNNING, QUARANTINED-but-resumable) is bound to a
   generation different from the incoming runtime. Terminal (DONE/RETIRED) jobs never block a normal install. Legacy unfinished
   rows whose generation cannot be proven fail closed until an explicit
   operator re-enqueue/resume binds them to the intended runtime generation.

A sealed unfinished PROGRAM can therefore never silently switch runtime
generations between passes. Deliberate migration is explicit and clearly
unsafe: `OFLOOP_ALLOW_RUNTIME_GENERATION_MIGRATION=1` bypasses the
generation probe (the live-work probe has its own override,
`OFLOOP_ALLOW_SUPERVISOR_SWAP_WITH_ACTIVE_WORK=1`). After such a migration,
bound runs fail closed on the generation mismatch at serve time, and
`ofloop supervisor resume` is the operator act that rebinds a run to the
new generation (previous binding reported).

Operational budget ceilings (cost/token/wall) are disabled by default for
fresh/missing schema fields. Existing rows are never silently reinterpreted:
the historical exact $25 / unlimited-token / 8-hour tuple is ambiguous and is
preserved with an operator-visible warning until explicitly re-registered.

On Linux, `install-supervisor-linux.sh` installs a per-user systemd unit named
`ownframework-loop-supervisor.service`. Both platform implementations persist
the same runtime-generation/provenance contract and call the same shared
runtime-dependency probe.

Use `uninstall-supervisor.sh` to remove the commissioned platform service.
Durable supervisor state/evidence is preserved.

## Semantic-pass context, delegation, and timing

Every BUILD and REVIEW semantic pass is a fresh non-interactive Claude Code
process. Passes do not share a conversation window. Continuity is durable:
the sealed packet, exact worktree, checkpoint/AC ids, build receipt, review
verdict, and deterministic repair_context carry forward what the next pass
needs.

repair_context is deterministic transport from one of two authoritative
sources, named by `source_kind`: `review_verdict` (a fresh CHANGES_REQUESTED
review of the exact current candidate) or `build_receipt` (the deterministic
build finalizer's own failed-validation evidence). A stale verdict after a
post-review validation failure is legitimate and falls through rather than
hard-stopping the run.

The commissioned runner uses Claude Code's native `--restricted` mode and
does not expose Agent, Task, Skill, WebSearch, WebFetch, browser, or MCP
capabilities inside a semantic pass. Builder tools are
`Read,Edit,Write,NotebookEdit,Bash,Glob,Grep`; reviewer tools are
`Read,Bash,Glob,Grep`.

The pass starts in `dontAsk` permission mode with that exact tool set
pre-approved. Sandboxed Bash auto-runs, so ordinary authorized engineering does
not wait for a human permission prompt. Out-of-contract calls are denied rather
than escalated.

The supervisor main print-mode worker does not receive a --max-turns flag.
Pass duration is controlled by the packet/supervisor wall-clock timeout below.

For v3 packets, risk_budget.max_pass_runtime_seconds is the semantic worker
timeout authority. A positive supervisor serve --timeout-seconds value can
only narrow it. If neither is declared, the historical 3600-second fallback
fuse applies to both single and PROGRAM passes; a long PROGRAM funds wider
passes through its packet budget (up to 28800 seconds per pass) rather than
by widening the default fuse.

## Live read-only observability

Supervisor status opens an existing SQLite ledger in read-only mode; observing an older run never performs schema or data migration.


ofloop supervisor status exposes raw progress telemetry without mutating the
run: worker/execution elapsed seconds, time since the job row changed,
worker-log byte/mtime activity, recent attempt history, cost/token telemetry,
current core checkpoint state, worktree identity/cleanliness, and candidate
diff summary.

There is no deliberate delay between an actionable BUILD finalization and the
next REVIEW dispatch, or between a review-driven repair and the next BUILD.
The serve loop sleeps only while IDLE or while explicit backoff policy applies.
Foreground host-adapter pass markers follow the same rule: whenever the next
semantic action is available, the cross-role ready state reschedules with zero
delay; a pre-start run is STARTABLE for the builder lane and WAIT for the
reviewer lane, never STOP.
