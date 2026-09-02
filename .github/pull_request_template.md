## Why

What problem does this change solve?

## Scope

What changed, and what is explicitly out of scope?

## Evidence

- [ ] Focused tests for the changed boundary pass.
- [ ] `./validate.sh` passes when required by scope.
- [ ] `./release_gate.sh` passes at a release/promotion boundary.
- [ ] `git diff --check` passes.
- [ ] No real secrets, customer data, or private infrastructure references were introduced.

List the decisive markers or commands:

```text
<evidence>
```

## Adapter changes

If this PR changes or adds an agent adapter:

- Adapter / host:
- Host version tested:
- Proposed maturity: experimental / stable
- `protocol_compatible`:
- `hardened`:
- `live_verified`:
- Conformance result:
- Live discovery/lifecycle proof:
- Known enforcement differences:

- [ ] The adapter reuses the deterministic `ofloop` core.
- [ ] It does not create its own execution-seal/state/repair/candidate/verdict path.
- [ ] Public support claims match the evidence above.

## Authority / compatibility

- [ ] First-start execution sealing remains deterministic and packet-bound.
- [ ] Exact candidate SHA remains the BUILD/REVIEW handoff.
- [ ] Promotion and unrelated external effects remain human/operator-owned.
- [ ] Existing supported adapter UX is preserved, or a breaking change is explicitly justified.

## Public-surface check

If public docs, templates, adapter metadata, skills, CI, or contributor files changed:

- [ ] Checkout-portability scan passes.
- [ ] Secret/public-surface scan passes.
- [ ] No unsupported adapter/runtime maturity claim was added.
- [ ] No stale execution path, private host path, or historical wording was reintroduced.
