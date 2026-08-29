# Semantic canary harness

Disposable, fully isolated end-to-end canary for a future REAL
model-driven proof of the sealed loop (builder → exact-SHA reviewer →
repair → next checkpoint) against this source checkout.

`prepare_canary.sh` is PREPARE-ONLY: it creates a throwaway canonical
repo, a sealed run, and an enqueued supervisor job under an isolated
`XDG_STATE_HOME` + explicit `--db`. It never starts a supervisor, never
calls a model, and never touches the live commissioned supervisor or any
live run (those live under the default state root, which this harness
does not reference).

Run the preparation:

```
bash tests/canary/prepare_canary.sh
```

It prints `CANARY_READY` plus the exact deliberate command a human can
execute later to drive one supervisor pass with a real model, and the
command to destroy the canary without residue.

Safety contract of this directory:

- no `serve` / `serve --once` inside this script;
- no writes outside the canary root;
- the live runtime stays pinned to its commissioned installation.
