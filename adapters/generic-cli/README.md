# Generic CLI Contract

`generic-cli` is the vendor-neutral host portability floor.

It is not a plugin and it is not a concrete production runner.

A compatible host can participate when it can consume deterministic work
orders, operate only in supplied worktrees, run local validation, and write the
one pass-scoped semantic result.

It must not reconstruct packet/state/candidate/promotion truth.

Canonical unattended cadence remains:

```text
durable supervisor -> dispatch -> registered runner -> deterministic finalize
```

A new concrete host should start here, implement/register a runner if it is to
be supervisor-driven, and advertise only the maturity it can prove.
