# Test Suite

`canonical.txt` is the release-gate allow-list. Version-prefixed regression filenames
are intentionally retained as provenance for the boundary that introduced the test;
they are not active version forks and they are not temporary scripts.

The suite is organized by test role:

- `unit/` — focused deterministic contracts;
- `integration/` — cross-component lifecycle, recovery, platform, and authority proofs;
- `canary/` — bounded commissioned/runtime proof helpers;
- adapter conformance files at `tests/` root — portable host-contract checks.

Shell is used where a test must exercise real process, Git, filesystem, installer, or
service-manager boundaries. Python owns deterministic library behavior. Do not add
one-off debug scripts, captured production data, generated logs, or local-machine
artifacts to this tree.

Run the maintained gates from repository root:

```bash
./validate.sh
./release_gate.sh
```

A new regression belongs in `canonical.txt` only when it protects a maintained product
contract. Historical commentary may explain why a test exists, but current public
behavior belongs in active documentation rather than stale release narrative.
