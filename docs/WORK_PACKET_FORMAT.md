# Work Packet Format

`WORK_PACKET.md` is the durable mission contract for an OwnFramework Loop
run. It combines human-readable Markdown with a strict JSON metadata block.

The parser is `lib/ownframework_loop/packet.py`. Current supported packet
schemas are v1 (legacy), v2 (single-mode/current compatibility), and v3
(PROGRAM-capable).

## Human boundary and execution binding

The human supplies or approves the mission content **before execution starts**.
Normal current operation does not require `ofloop spec approve`.

At the first legitimate build start, the deterministic core creates the
immutable execution seal (historically stored as `APPROVAL.json`) with:

- exact packet SHA-256;
- canonical repository path;
- spec-time baseline branch and exact SHA;
- deterministic candidate branch;
- packet schema and risk metadata;
- PROGRAM graph provenance when applicable.

After the seal exists, packet drift is refused. Changed mission or scope
requires a new run.

The historical TTY pre-seal remains compatibility-only and must not be
presented as the normal operator flow.

## Core metadata

All current packets carry:

- `schema`
- `packet_id`
- `created_at`
- `work_class`
- `risk_class`
- `title`
- `target.repo` (absolute path)
- `target.branch`
- `target.classification`
- non-empty `acceptance_criteria`
- `non_goals`
- non-empty `allowed_paths`
- non-empty `protected_paths`
- non-empty `work_units`
- `merge_authority`
- `deploy_authority`
- `push_authority`
- `external_action_authority`

v3 PROGRAM packets may additionally define `execution_mode=program` and a
finite `checkpoint_graph`.

## Required validation

`required_validation` commands are executable policy. Deterministic build and
review finalizers therefore classify them through the command guard before
execution, run them only in the prepared worktree, impose a bounded timeout,
and capture exact exit status.

A packet must never use required-validation as a disguised external-action,
promotion, deployment, or remote-mutation channel.

## Stable IDs

Use stable IDs across repair rounds:

- `AC-N` acceptance criteria;
- `NG-N` non-goals;
- `UNIT-N` work units;
- `CP-N` PROGRAM checkpoints;
- stable review finding IDs.

## Promotion authority

Starting a run or reaching `APPROVED` does not grant push, merge, deploy,
publish, payment, message-sending, or unrelated external authority. Promotion
remains outside Loop.

## Repository classification is spec-time identity

`target.classification` describes the repository as it exists when the mission is finalized:

- `local_only` — no configured Git remote is part of the run baseline.
- `github_private` — the project is intentionally backed by a private GitHub repository before the run is minted.
- `github_public` — the project is intentionally backed by a public GitHub repository before the run is minted.

When a GitHub review surface is part of the project's operating model, establish that remote, push/prove the intended baseline, and only then create the Loop run. Do not create a `local_only` run and attach a remote afterward.

The executable core already refuses a `local_only` target that has configured remotes. If repository remote topology changes after `spec new` but before first execution, the clean normal path is to stop the never-started run and create a fresh run from the final repository identity/baseline.
