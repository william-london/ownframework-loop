# Semantic canary harnesses

This directory intentionally contains two different proof levels.

## 1. Isolated source smoke canary

`prepare_canary.sh` is a disposable **single-run v2 source-lane smoke
harness**. It creates an isolated repository and isolated supervisor ledger and
prints a deliberate foreground `supervisor serve --once` command. It is useful
for checking one semantic BUILD/REVIEW/repair flow without touching a
commissioned service.

It does **not** prove PROGRAM checkpoint continuation, service restart/recovery,
installed-payload provenance, or terminal PROGRAM approval.

Preparation is model-free:

```bash
bash tests/canary/prepare_canary.sh
```

## 2. Final commissioned PROGRAM canary

`commissioned_program_canary.sh` is the final commissioning harness. It
refuses source-checkout runtimes and requires an installed managed core,
runtime-provenance record, supervisor ledger, and active launchd/systemd-user
service.

Its `prepare` command is **PREPARE-ONLY**: it does not enqueue work and does
not call a model. It creates a local-only v3 PROGRAM with two checkpoints and
an empty network allowlist.

CP-1 is deliberately staged to require one genuine
`CHANGES_REQUESTED -> repair -> APPROVED` cycle. The first builder is required
to keep deterministic validation green while leaving the reviewer-visible
`CANARY_REPAIR_REQUIRED` sentinel; the first reviewer must reject that
sentinel, and the funded repair removes it and implements the final behavior.
The first builder is also asked to execute a harmless `.invalid` HTTP
mutation negative-control that must be refused; final verification requires
the trusted Loop hook diagnostic for that run. CP-2 proves continuation after
a controlled supervisor restart.

Run later, after integration and commissioning:

```bash
# Model-free preparation.
bash tests/canary/commissioned_program_canary.sh prepare

# Register the checkpoint-boundary restart watcher with the native user service
# manager using the CANARY_ROOT printed above. The command returns only after a
# distinct, durable watcher is owned by that manager; this is control-plane
# recovery testing, not semantic intervention.
bash tests/canary/commissioned_program_canary.sh arm-restart <CANARY_ROOT>

# Deliberate paid-model start. This enrolls the prepared run into the already
# commissioned service.
bash tests/canary/commissioned_program_canary.sh start <CANARY_ROOT>

# Observe or verify.
bash tests/canary/commissioned_program_canary.sh status <CANARY_ROOT>
bash tests/canary/commissioned_program_canary.sh verify <CANARY_ROOT>
```

Lifecycle markers are exact:

- `CANARY_STATE=PREPARED` — setup succeeded; **not a pass**.
- `CANARY_STATE=STARTED` — real commissioned work was enrolled.
- `CANARY_STATE=IN_PROGRESS` — nonterminal work remains.
- `CANARY_STATE=TERMINAL_PASS` — every final evidence assertion passed.
- `CANARY_STATE=TERMINAL_FAIL` — a terminal state or evidence assertion failed.

A terminal pass requires zero duplicate/lost semantic attempts, zero wrong-SHA
reviews, exact repair/checkpoint accounting, stable runtime generation, valid
STATE/EVENT chain, coherent SQLite attempts, zero packet-authorized external
effects (empty network authority, no remote, external authority `none`), an
observed trusted-hook refusal, and final PROGRAM `APPROVED`.

The harness never publishes, pushes, merges, deploys, tags, or releases.
