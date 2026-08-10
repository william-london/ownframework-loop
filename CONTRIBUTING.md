# Contributing to OwnFramework Loop

Thanks for your interest in OwnFramework Loop. This project is a
small, focused workflow for Claude Code, and the most useful
contributions are tightly scoped.

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
4. **Use canonical scripts and commands.** `install.sh`,
   `uninstall.sh`, `rollback.sh`, `validate.sh`, `release_gate.sh`,
   and the helpers under `bin/`, `lib/`, `scripts/`, and `hooks/` are
   the canonical local surfaces. Prefer them over ad-hoc shell.
5. **Keep the public surface coherent.** Public-surface files are
   `README.md`, `AGENTS.md`, `CONTRIBUTING.md`, `SECURITY.md`,
   `CHANGELOG.md`, `LICENSE`, `THIRD_PARTY_NOTICES.md`, and
   `.claude-plugin/plugin.json`. If your change touches any of these,
   re-run the public-leak scan and confirm no private references
   have been introduced.

## Tests

- `./validate.sh` is the canonical validation lane.
- `./release_gate.sh` is the canonical release-gate lane.
- The focused test suite under `tests/` covers each boundary.
- `git diff --check` must report no whitespace or conflict markers.

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
- Heavyweight external dependencies. OwnFramework Loop currently
  uses only the Python standard library and the public Claude Code
  plugin API.
