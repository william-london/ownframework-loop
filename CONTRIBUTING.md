# Contributing to OwnFramework Loop

Thanks for your interest in OwnFramework Loop. This project is a focused,
vendor-neutral execution-sealed engineering runtime for AI coding agents, and the most useful
contributions are tightly scoped and evidence-backed.

## Supported contribution flow

1. **Open an issue first.** Describe the problem or the proposed
   change in one or two paragraphs. Larger ideas should land as an
   issue before a pull request.
2. **Open a focused pull request.** One coherent change per PR.
   Avoid mixing refactors, feature work, and formatting in the same
   PR.
3. **Prove the change.** Run `./validate.sh` and the focused test
   suite for any boundary your change touches. Include the output in
   the PR description or attach it as a comment.
4. **Use canonical scripts and commands.** `install.sh` /
   `uninstall.sh` own the vendor-neutral core. Operator-facing adapter and
   supervisor lifecycle commands live under `bin/`; platform-specific service
   plumbing lives under `scripts/supervisor/`. `validate.sh`,
   `release_gate.sh`, and supported helpers under `bin/`, `lib/`,
   `scripts/`, and `hooks/` are canonical local surfaces. Prefer them over
   ad-hoc shell.
5. **Keep the public surface coherent.** Public-surface files include
   `README.md`, `AGENTS.md`, `CONTRIBUTING.md`, `SECURITY.md`,
   `CHANGELOG.md`, `LICENSE`, `THIRD_PARTY_NOTICES.md`, adapter and
   architecture docs, and the agent-host metadata under `.claude-plugin/`
   and `.agents/skills/`. If your change touches these, re-run the
   public-leak/checkout-portability checks and confirm no private or
   developer-machine references have been introduced.

## Tests

- `./validate.sh` is the canonical validation lane.
- `./release_gate.sh` is the canonical release-gate lane.
- The focused test suite under `tests/` covers each boundary.
- `git diff --check` must report no whitespace or conflict markers.
- Adapter work should run `tests/run_adapter_conformance.sh` and the relevant adapter portability/doctor checks.

If any of those fail, the change is not ready.

## Synthetic data only

Fixtures under `tests/` and `examples/` must use synthetic data only.
Do not introduce real customer, prospect, vendor, payroll, bank, tax,
legal, or employee data; real tokens; live payment instruments;
production secrets; or `.env*` files.

## Commit / push discipline

- One coherent commit per slice.
- Commit message style: `ownframework-loop: <verb> <slice>`.
- Force-push, `--all`, `--tags`, `--mirror`, pushes to non-named
  branches, and destructive history rewrites are explicit task-scope
  concerns and must be called out in the PR description.

## License of contributions

By submitting a contribution, you agree that your contribution is
licensed to the project under the Apache License 2.0
(see [`LICENSE`](./LICENSE)). The project does not require a
separate Contributor License Agreement for typical code,
documentation, and test contributions.

## Out of scope

- Changes that depend on private OwnFramework infrastructure or
  repositories outside this one.
- Autonomous-software-company framing or guarantees of correctness,
  safety, or coverage.
- Heavyweight provider SDK dependencies in the deterministic core.
  The core remains Python-standard-library based; agent-host adapters
  use their host's supported skill/plugin/instruction surfaces and
  must not create a second approval/state/SHA/verdict protocol.

## Agent adapters

New agent-host adapters must reuse the deterministic core rather than create a
parallel approval/state/SHA/verdict path. Read
[`docs/ADAPTER_DEVELOPMENT.md`](docs/ADAPTER_DEVELOPMENT.md) and
[`docs/architecture/ADAPTER_CONTRACT.md`](docs/architecture/ADAPTER_CONTRACT.md)
before opening a PR. New adapters begin experimental and should include a
capability declaration, deterministic conformance evidence, and live-host proof
appropriate to the support claim.
