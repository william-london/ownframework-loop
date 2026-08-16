---
name: of-loop-spec
description: Create, inspect, amend, stop, or hand off human approval for an OwnFramework Loop work packet.
---

# OwnFramework Loop — spec

This skill is a host adapter over the deterministic `ofloop` core.

## Rules

- Never approve your own packet.
- Never write `STATE.json`, `APPROVAL.json`, `REVIEW_VERDICT.json`, event logs, or lock files directly.
- Never manufacture the TTY confirmation token.
- Never add push, merge, deploy, publish, send, payment, or unrelated remote authority.

## New specification

1. Confirm the working directory is the target Git repository.
2. Inspect only enough repository context to draft an accurate bounded packet.
3. Use `ofloop spec new <repo> "<mission>"` (or `./bin/ofloop ...` in a source checkout) to create the run.
4. Draft `WORK_PACKET.md` using the repository schema and packet conventions.
5. Surface the exact human approval command: `ofloop spec approve <repo> <run-id>`.
6. Stop and wait for the human TTY approval. The model must not execute approval for the human.

Use supported CLI commands for status, amendment, stop, abandon, and legacy inspection. Once approval exists and its binding validates, hand off to `of-loop-build`.
