## Why

What problem does this change solve?

## Scope

What changed, and what is explicitly out of scope?

## Evidence

- [ ] Focused tests for the changed boundary pass.
- [ ] `./validate.sh` passes when required by scope.
- [ ] `./release_gate.sh` passes at a release/promotion boundary.
- [ ] `git diff --check` passes.
- [ ] No real secrets/customer/private data are introduced.

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
- [ ] It does not create its own approval/state/repair/candidate/verdict path.
- [ ] Public support claims match the evidence above.

## Authority / compatibility

- [ ] Human approval remains outside agent authority.
- [ ] Exact candidate SHA remains the review handoff.
- [ ] Human promotion remains outside the loop.
- [ ] Existing Claude Code `/of-loop:spec`, `/of-loop:build`, and `/of-loop:review` compatibility is preserved, or a breaking change is explicitly justified.

## Public-surface check

If public docs, adapter metadata, skills, CI, or contributor files changed:

- [ ] Checkout-portability scan passes.
- [ ] Secret scan passes.
- [ ] No unsupported agent compatibility claim was added.
