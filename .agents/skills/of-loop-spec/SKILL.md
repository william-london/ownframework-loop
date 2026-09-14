---
name: spec
description: OwnFramework Loop - create, inspect, amend, stop, or launch a run. Human execution intent defaults to validated preflight + durable supervisor enqueue; draft-only intent never launches.
user-invocable: true
---

# OwnFramework Loop - spec

This skill is a host adapter over the deterministic ofloop core.

## Rules

- Never approve your own packet.
- Never write STATE.json, APPROVAL.json, REVIEW_VERDICT.json, event logs, or lock files directly.
- Never manufacture the legacy TTY confirmation token.
- Never add push, merge, deploy, publish, send, payment, or unrelated remote authority.
- Do not ask the operator to tune model, effort, retry, cost, token, wall-clock,
  concurrency, or provider flags when current trusted Loop configuration and
  packet defaults can decide them safely.
- A human request to **implement, build, fix, finish, execute, run, continue, or
  otherwise carry out** the mission is execution intent. Creating the packet is
  part of that one request; do not stop merely to hand the operator an enqueue
  command.
- A human request explicitly limited to **draft/spec/plan/inspect only** is
  draft-only intent. Never enqueue draft-only work.
- These intent rules apply whether this skill was invoked explicitly or the
  operator used a plain-language prompt asking the host agent to create a Loop
  packet.

## New specification (normal flow)

1. Confirm the working directory is the target Git repository.
2. Resolve repository identity BEFORE creating the run:
   * inspect configured Git remotes;
   * decide the packet classification from actual current state, not intended future state;
   * `local_only` means no configured remote;
   * when a private GitHub review surface is part of the project, create/configure it, push the intended baseline, prove local/remote parity, and use `github_private` before `ofloop spec new`;
   * do not mint a local-only run and add a remote afterward.
3. Inspect only enough repository context to draft an accurate bounded packet.
   For PROGRAM work, inspect enough of the complete mission/checkpoint graph to
   infer capabilities needed at **any** future checkpoint; authority cannot be
   widened silently after execution binding.
4. Use `ofloop spec new <repo> "<mission>"` to create the run.
5. Draft WORK_PACKET.md using the repository schema and packet conventions.
   Declare portable `capabilities` for host/tool needs instead of embedding
   machine paths or manually reconstructing tool-specific network topology
   (for example `toolchain.python`, `package.uv`,
   `browser.playwright.chromium`). Packets never carry raw runner flags.

   Always write `runner_profile` explicitly. Selection order is deterministic:
   * honor an operator-explicit profile when one was requested;
   * otherwise prefer the trusted workstation profile `primary` when
     `ofloop capabilities profile primary` resolves successfully;
   * otherwise use `default` without asking a tuning question. `default` means
     no Loop model pin and follows the commissioned service environment/provider
     default. The commissioned runner does not reread interactive
     user/project/local host settings as execution authority.

   Provider endpoint/auth belongs in the private commissioned service
   environment. Use `network_read_allowlist` only for packet-specific extra
   read hosts not already supplied by a capability contract. Never add a broad
   wildcard, scheme, port, path, publish endpoint, daemon socket, or unrelated
   host.
6. For PROGRAM packets with checkpoint-specific outcomes, keep the complete
   mission acceptance contract at top level and assign it deterministically
   with each checkpoint's `acceptance_criterion_ids`. If any checkpoint uses
   scoped AC ids, every checkpoint must declare a non-empty list and the union
   must cover every top-level AC id. Do not use `not_applicable` for future
   checkpoint criteria merely to satisfy coverage.
7. Validate the packet shape with the supported validator.
8. Preflight the **exact complete packet capability/profile envelope for both
   semantic roles** before launch:

   `ofloop capabilities probe`

   `ofloop capabilities preflight <repo> <capability>... --role builder --runner-profile <profile>`

   `ofloop capabilities preflight <repo> <capability>... --role reviewer --runner-profile <profile>`

   Do not weaken HOME/PATH, sandboxing, MCP, tools, or network authority to make
   preflight pass. Ordinary missing tools may be provisioned/commissioned through
   the trusted host capability mechanism when that is already within the human's
   execution intent. Privileged `container.docker` / `local.http-service` and
   browser runtime proof must use their supported trusted commissioning/canary
   flows. If satisfying a missing capability would require new production
   credentials, external mutation authority, or an unsupported safety bypass,
   stop and report the missing host prerequisite instead of launching.
9. If the request is **execution intent** and both role preflights pass, enqueue
   immediately using the core's established defaults:

   `ofloop supervisor enqueue <repo> <run-id>`

   Do not invent per-run tuning flags. Cost/token ceilings remain off unless the
   operator explicitly requested a hard ceiling; packet `risk_budget` supplies
   semantic and whole-run limits; the persistent supervisor configuration owns
   machine concurrency; the selected trusted runner profile owns model/effort.
   Then verify read-only with:

   `ofloop supervisor status <repo> <run-id>`

   An already commissioned launchd/systemd service consumes the job without an
   open terminal. Only use `ofloop supervisor serve` when no durable service is
   commissioned and the operator explicitly wants foreground/debug operation.
10. If the request is **draft-only intent**, do not enqueue. Return the packet
    identity and preflight/readiness findings only.
11. Return a concise result containing:

   * repo
   * run_id
   * packet_sha256
   * spec_baseline_branch / spec_baseline_sha
   * execution_mode / checkpoint_count
   * capabilities
   * runner_profile
   * builder/reviewer preflight result
   * `ENQUEUED=yes|no`
   * supervisor status when enqueued
   * foreground/debug commands only when relevant

Normal execution-intent operation is therefore one human request: SPEC ->
validate -> exact host preflight -> enqueue -> durable supervisor. The first
actionable BUILD creates the immutable execution seal automatically. There is
no routine operator ceremony between packet creation and unattended execution.

## Internal vs operator-facing state

Internal storage name AWAITING_APPROVAL is preserved for backward
compatibility. The operator-facing meaning is READY_TO_START (the run is
startable; no approval ceremony is required).

## Compatibility-only: legacy TTY pre-seal

The optional historical TTY pre-seal command remains as backward-compatible /
optional strict pre-seal. It is NOT required by the normal workflow and must
NOT appear in normal operator instructions.

## Packet immutability

Before first execution seal: packet amendments are supported through the
supported amendment surface.

After execution seal: packet is immutable. Changed mission/scope requires a
NEW RUN.

## Repository identity before execution

`target.classification` is spec-time repository identity, not a future deployment wish.
A run intended for a private GitHub-reviewed project should be created only after the private remote and baseline branch exist and local HEAD is proven equal to the intended remote baseline.

If remote topology/classification changes after `spec new` but before the first execution seal, prefer stopping the never-started run and creating a fresh run from the final repository state. Do not rely on the first BUILD claim to discover a preventable `local_only` + remote mismatch.

Current core execution already fails closed when a `local_only` packet has configured remotes. The spec workflow should prevent reaching that refusal in normal operation.

## PROGRAM autonomy preflight

Before a v3 PROGRAM is considered ready:

- use `acceptance_criterion_ids` on checkpoints; never emit checkpoint
  `acceptance_criteria`;
- declare the smallest portable `capabilities` set needed by the **whole
  PROGRAM lifetime**, not merely the first checkpoint, and preflight it for
  builder and reviewer before enqueue. Effective network read authority is the
  frozen union of packet-specific `network_read_allowlist` hosts and exact
  capability-derived hosts. An empty packet list therefore means no EXTRA
  packet domains, not necessarily zero domains when a declared package/browser
  capability requires narrow download endpoints;
- choose `runner_profile` only from trusted profiles exposed by
  `ofloop capabilities profile <name>`; explicit models must be pinned provider
  model IDs rather than moving aliases. An explicit effort also requires
  current runtime-bound operator attestation. Profile identity is run-bound and
  may select semantic model/effort only, never sandbox/tool/MCP/session authority;
- validate packet budgets against executable ceilings before first execution;
- treat top-level build/review/repair values as cumulative PROGRAM envelopes;
- unless intentionally throttling the whole PROGRAM, fund those global
  envelopes from the sums of checkpoint-local budgets;
- ensure a global repair allowance is realizable by the global build/review
  allowance;
- choose `max_pass_runtime_seconds` for the complexity of one semantic pass
  (up to 28800 per pass; the undeclared fallback fuse is 3600, so any pass
  that legitimately needs longer than one hour must declare its budget);
- declare `risk_budget.max_runtime_seconds` as the whole-run wall-clock
  envelope when the PROGRAM may legitimately run long (up to 2419200).
  `supervisor enqueue` consumes it as the operational wall ceiling; without
  it, no wall-clock ceiling applies and the run is bounded only by its
  semantic pass/repair/no-progress protections.

A packet that can only discover an impossible deterministic ceiling after a
model has already done work is a spec defect and must not be startable.

## Unattended budget semantics

Token ceilings are off by default and cost ceilings are off by default.
Unattended execution is bounded by meaningful-progress protections (pass and
repair caps, no-progress streak, identical-finding repetition fuse, failure-
class retry policy), not by token or cost conservation. Operators who want a
hard spend line may pass `--max-cost-usd` / `--max-total-tokens` /
`--max-wall-seconds` explicitly. When a positive aggregate cost ceiling is
funded, the supervisor also narrows each semantic pass with the exact remaining
durable run budget when the provider supports it; the Loop ledger remains the
canonical aggregate accounting source.
