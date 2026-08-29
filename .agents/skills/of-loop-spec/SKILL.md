---
name: spec
description: OwnFramework Loop - create, inspect, amend, or stop an OwnFramework Loop run. Returns the run id plus the canonical builder/reviewer commands.
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
2. Inspect only enough repository context to draft an accurate bounded packet.
3. Use ofloop spec new <repo> "<mission>" to create the run.
4. Draft WORK_PACKET.md using the repository schema and packet conventions.
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
