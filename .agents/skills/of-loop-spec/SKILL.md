---
name: spec
description: OwnFramework Loop - create, inspect, amend, or stop a run. Returns the supervisor-first unattended handoff plus optional foreground/debug commands.
user-invocable: true
---

# OwnFramework Loop - spec

This skill is a host adapter over the deterministic ofloop core.

## Rules

- Never approve your own packet.
- Never write STATE.json, APPROVAL.json, REVIEW_VERDICT.json, event logs, or lock files directly.
- Never manufacture the TTY confirmation token.
- Never add push, merge, deploy, publish, send, payment, or unrelated remote authority.

## New specification (normal flow)

1. Confirm the working directory is the target Git repository.
2. Resolve repository identity BEFORE creating the run:
   * inspect configured Git remotes;
   * decide the packet classification from actual current state, not intended future state;
   * `local_only` means no configured remote;
   * when a private GitHub review surface is part of the project, create/configure it, push the intended baseline, prove local/remote parity, and use `github_private` before `ofloop spec new`;
   * do not mint a local-only run and add a remote afterward.
3. Inspect only enough repository context to draft an accurate bounded packet.
4. Use ofloop spec new <repo> "<mission>" to create the run.
5. Draft WORK_PACKET.md using the repository schema and packet conventions.
5. Validate the packet shape with the supported validator.
6. Return to the operator:

   * repo
   * run_id
   * packet_sha256
   * spec_baseline_branch / spec_baseline_sha
   * execution_mode / checkpoint_count
   * canonical unattended enqueue: ofloop supervisor enqueue <repo> <run-id>
   * canonical status: ofloop supervisor status <repo> <run-id>
   * execution clock when not already running as a service: ofloop supervisor serve
   * optional FOREGROUND / DEBUG builder: /loop /of-loop:build <run-id>
   * optional FOREGROUND / DEBUG reviewer: /loop /of-loop:review <run-id>

7. STOP. Normal background operation is supervisor-first. Enqueue the run; an
   already commissioned supervisor service consumes it, or `ofloop supervisor
   serve` may run the execution clock manually. The first actionable BUILD
   creates the immutable execution seal automatically.

## Internal vs operator-facing state

Internal storage name AWAITING_APPROVAL is preserved for backward
compatibility. The operator-facing meaning is READY_TO_START (the run is
startable; no approval ceremony is required).

## Compatibility-only: legacy TTY pre-seal

The optional historical TTY pre-seal command remains as backward-compatible /
optional strict pre-seal. It is NOT required by the normal workflow and must
NOT appear in operator instructions.

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
