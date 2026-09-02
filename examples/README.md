# Packet Examples

These files are completed work-packet examples. They complement, rather than
duplicate, `../templates/`:

- `templates/` answers **what fields do I fill in?**
- `examples/` answers **what does a coherent completed packet look like?**

Every packet example is parsed and validated by the canonical public-contract
test. If the executable packet contract changes and an example becomes stale,
CI fails.

Current examples:

- `bug-fix.md` — bounded single-run bug fix;
- `hardening.md` — bounded hardening change;
- `tracked-contract.md` — work constrained by an external contract;
- `new-repository.md` — explicit local-only repository bootstrap;
- `program.md` — modern v3 PROGRAM with checkpoint-scoped acceptance,
  capabilities, an explicit runner profile, cumulative budgets, and human
  promotion.

Newly authored current packets should write `runner_profile` explicitly.
`"default"` intentionally accepts the registered runner's provider default;
it does not inherit an interactive Claude `settings.json`. Use an
operator-owned named profile when a specific model is required.
