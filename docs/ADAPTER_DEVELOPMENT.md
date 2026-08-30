# Developing an OwnFramework Loop Adapter or Runner

## Start from the core contract

Do not copy Claude-specific implementation unless the target host genuinely has
the same primitive.

First prove the target can consume OwnFramework Loop's deterministic work order
and semantic-result contract without reimplementing state or promotion.

## Adapter versus runner

An **adapter** adds host UX/distribution: plugin, skills, hooks, commands,
discovery.

A **runner** is the supervisor-executable semantic process implementation.

A host may have one, both, or neither.

## Never reimplement

Adapters/runners must not own:

- packet validation;
- execution sealing;
- state transitions;
- worktree/candidate selection;
- exact-SHA verdict identity;
- repair/checkpoint counters;
- runtime generation;
- promotion.

## Evidence levels

- `experimental`: static/distribution or partial host evidence.
- `portable`: abstract vendor-neutral contract.
- `stable`: documented host integration.
- `live_verified`: real supported-host lifecycle observed.
- `hardened`: unattended security/authority boundary mechanically proven.

Do not inherit a stronger label from another adapter.

## Required checks

Run:

```bash
bash tests/test_run_adapter_conformance.sh
bash validate.sh
bash release_gate.sh
```

Add focused adapter/runner tests and a real disposable lifecycle before claiming
live support.

A useful change should answer:

- Which generic core contract does it consume?
- Which host-native primitive does it use?
- What authority remains deterministic-core-owned?
- What evidence justifies the advertised maturity?
