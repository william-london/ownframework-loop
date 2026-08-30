# OPERATOR_RUNBOOK

Canonical operator workflow for OwnFramework Loop.

## 1. Human-originated specification

Create and inspect the mission:

```text
/of-loop:spec <mission>
```

SPEC is the human boundary. The packet must describe the intended local
engineering work, scope, validation, budgets, and non-goals.

There is no mandatory approval command or confirmation token after a valid
packet exists.

## 2. Unattended mode (canonical for background work)

The commissioned Claude runner requires Claude Code 2.1.248+ and uses native
`--restricted` mode with `dontAsk`, role-specific pre-approved tools, strict
MCP isolation, and fail-closed sandboxing. Authorized semantic work therefore
does not stop for routine permission prompts.

Packet `network_read_allowlist` is the only post-SPEC outbound network
authority for semantic Bash. It is frozen with SPEC and enforced by Claude's
native strict network allowlist; empty means zero egress.

Enqueue the existing run:

```bash
ofloop supervisor enqueue /absolute/path/to/repo <run-id> \
  --max-cost-usd 25 \
  --max-total-tokens 0 \
  --max-infra-failures 3 \
  --max-transient-failures 8 \
  --max-wall-seconds 28800
```

Start the execution clock:

```bash
ofloop supervisor serve
```

The supervisor is independent of the shell working directory because every job
stores an absolute repository path.

While idle it makes zero model calls. For actionable work it asks the
deterministic dispatch boundary for exactly one BUILD or REVIEW work order,
launches one fresh runner process, finalizes deterministically, and immediately
asks core what is next.

If an unpinned/idle-only service cannot currently discover Claude on its
launchd PATH, the job enters a self-healing RUNNER_WAIT backoff. That wait
creates no semantic attempt, consumes no retry counter or model budget, and
does not start the run wall-clock ceiling. The service rechecks automatically
and continues the same claimed pass when Claude becomes available; no manual
supervisor resume is required.

An explicitly commissioned OFLOOP_CLAUDE_BIN remains strict runtime authority.
If that exact pinned executable disappears, Loop quarantines rather than
silently switching to another Claude binary.

Operational status / morning evidence:

```bash
ofloop supervisor status /absolute/path/to/repo <run-id>
```

Status combines supervisor queue/retry/cost/token evidence with a read-only
snapshot of core state, candidate SHA, pass counters, PROGRAM checkpoint, and
latest review verdict. It also returns the five most recent semantic attempts,
durable stdout/stderr paths, classified failure evidence, and a derived
quarantine reason.

Candidate work is intentionally isolated from the canonical checkout. Status
therefore also exposes:

- canonical checkout path/branch/HEAD;
- exact builder and reviewer worktree paths, registration, HEAD, branch, and
  cleanliness;
- frozen baseline SHA and candidate branch;
- whether the candidate is already the canonical checkout HEAD;
- an exact local candidate-diff summary (changed paths plus line/file counts)
  when baseline and candidate SHAs are both available.

These observations are read-only. Status never publishes a branch, advances
the canonical checkout, promotes a candidate, or deletes a worktree. This is
why an operator can see useful candidate evidence even while the normal VS Code
checkout remains on the untouched baseline.

PROGRAM acceptance is checkpoint-aware. Top-level `acceptance_criteria`
remain the complete frozen mission contract. A checkpoint may declare
`acceptance_criterion_ids` to identify exactly which of those criteria are
reviewed at that checkpoint. If any checkpoint uses the mapping, every
checkpoint must declare a non-empty mapping and the union must cover the full
top-level AC set. Older PROGRAM packets with no mapping retain the legacy
all-criteria-per-checkpoint behavior.

Operational failures are not all treated alike:

- deterministic dispatch/invariant and obvious runner-configuration failures
  quarantine immediately;
- ordinary unclassified runner failures use the bounded
  `max_infra_failures` streak;
- recognized transient provider/network failures use a separate
  `max_transient_failures` streak with exponential backoff. By default, when
  that streak is exhausted the supervisor opens a 10-minute circuit and
  retries the same pass automatically; two bounded recovery cycles are allowed
  before final transient quarantine. Cost, token, and wall-clock ledgers are
  never reset by this recovery;
- unknown model cost still fails closed;
- unknown token usage fails closed only when the operator explicitly enabled a
  token ceiling.

Token telemetry is provider-reported operational evidence. The default
`--max-total-tokens 0` disables the token ceiling, which is useful for
subscription/prepaid runners where USD cost is not the scarce resource.

On macOS, after commissioning the exact checkout:

```bash
bash install-supervisor-macos.sh
```

This installs a per-user `launchd` service so the supervisor is independent of
an open terminal or Claude session. After a supervisor has been commissioned
once, later canonical `install.sh` runs on macOS automatically refresh that
existing service to the newly installed cache payload and preserve source-SHA
provenance. A plugin install never creates a new launchd service implicitly.

## 3. Interactive foreground mode

For debugging or hands-on sessions, the existing Claude UX remains:

```text
/loop /of-loop:build <run-id>
/loop /of-loop:review <run-id>
```

These are adapters over the same deterministic core, not the durable execution
clock.

## First-start execution seal

The first legitimate build start creates the immutable execution seal:

- `binding_method=build_start`
- `binding_kind=execution_seal`
- binds exact packet bytes/SHA, canonical repo, spec-time baseline branch/SHA,
  candidate branch, packet metadata, and PROGRAM provenance.

Internal state name `AWAITING_APPROVAL` and historical file
`APPROVAL.json` remain compatibility names for existing runs. Operator-facing
meaning is `READY_TO_START`.

## Promotion boundary

`APPROVED` means eligible for human/operator promotion. Loop and its
supervisor do not push, merge, deploy, publish, pay, send messages, or mutate
unrelated remote systems.

## Retired path

`ofloop loop run` is intentionally retired. It previously drove finalizers
without a real semantic builder/reviewer process and is not a supported
unattended architecture.
