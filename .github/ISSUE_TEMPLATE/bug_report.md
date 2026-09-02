---
name: Bug report
about: Report a reproducible OwnFramework Loop defect
labels: bug
---

## What happened?

Describe the observed behavior and what you expected instead.

## Reproduction

Provide the smallest safe reproduction you can. Use synthetic data only; do not paste
tokens, customer data, private repository contents, or other secrets.

## Environment

- OwnFramework Loop version / commit:
- OS:
- Python version:
- Agent host + version (Claude Code, Codex, other):
- Adapter, if relevant:

## Evidence

Include the focused validation result, relevant refusal/error marker, or exact failing
command. Prefer the smallest decisive excerpt over large raw logs.

## Boundary affected

Check any that apply:

- [ ] Work packet / execution seal
- [ ] State / events / locking / lifecycle
- [ ] Builder / candidate SHA
- [ ] Exact-SHA review / verdict
- [ ] Repair / retry / runtime / cost limits
- [ ] Supervisor / restart recovery
- [ ] Capability / runner-profile binding
- [ ] Adapter discovery / install
- [ ] Sandbox / secret / external-effect guard
- [ ] Release gate / CI
- [ ] Documentation or template only
