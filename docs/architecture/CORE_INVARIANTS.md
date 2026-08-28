# Core invariants

OwnFramework Loop's product identity is the deterministic protocol, not a
specific coding-agent vendor and not an approval ceremony.

The core preserves:

1. **Spec-time source snapshot** — new runs record the target branch and exact
   source SHA before execution starts.
2. **Atomic execution seal** — first legitimate execution start binds exact
   packet bytes, canonical repository, baseline branch/SHA, candidate branch,
   packet metadata, and PROGRAM provenance. No separate approval is required.
3. **No silent rebinding** — source movement, branch drift, tracked/staged dirty
   source, malformed binding evidence, or packet mutation fail closed.
4. **Serialized claims/transitions** — first start, build claims, review claims,
   lifecycle transitions, and event/state writes are lock-serialized.
5. **Bounded scope and budgets** — builders/reviewers operate inside packet
   paths, runtime limits, and finite repair/checkpoint envelopes.
6. **Deterministic candidate identity** — branch/worktree ownership belongs to
   the core and authoritative build evidence records an exact Git SHA.
7. **Exact-SHA review** — review binds to the exact candidate SHA, not arbitrary
   current filesystem state.
8. **Exact-pass crash recovery** — reconciliation may adopt only evidence for the
   currently claimed pass; stale prior-pass/checkpoint artifacts cannot advance
   a run.
9. **Fail-closed terminal semantics** — repair exhaustion/integrity failures stop
   or block rather than widening authority or inventing progress.
10. **No external-action authority from Loop state** — run start or `APPROVED`
    never grants push, merge, deploy, publish, send, payment, remote mutation,
    or unrelated customer-system authority.
11. **Operator promotion outside Loop** — promotion is a separate action after
    protocol approval.
12. **Adapter thinness** — adapters may improve UX/hardening but may not create a
    second execution-binding/state/repair/candidate/verdict truth.

The historical `APPROVAL.json` filename and `tty_confirmation` method remain
compatibility surfaces. New runs normally use `approval_method=build_start` and
`binding_kind=execution_seal`; compatibility names do not change the current
authority model.
