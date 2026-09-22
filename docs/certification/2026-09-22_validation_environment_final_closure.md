# OwnFramework Loop — Validation Environment Final Closure (2026-09-22)

**STATUS: SUPERSEDED — held pending re-closure**

This document is the working draft for the post-v1 validation-environment
closure. The original closure claim
(`VALIDATION_ENVIRONMENT_FINAL_CLOSURE=PASS`,
`READY_FOR_NORMAL_ENGINEERING_USE=yes`,
`WALK_AWAY=yes`) was rejected by independent source-level adjudication.

## Why it was rejected

Source-level adjudication identified six A-grade defects that must be
remediated before a final-closure claim is admissible:

| Code | Defect |
|------|--------|
| A_UV_CAPABILITY_DECLARATION_PARITY | Packet admission checked `uv run` only; executor recognized `uv sync` / `uv exec` / `uv test` / `uv python` / `uv lock` independently. Two classifiers → drift. |
| A_UV_EXACT_IDENTITY_BEFORE_EFFECT | Provisioning ran BEFORE `commissioned_validation_env()` verified the run's frozen capability binding. Provisioner used `shutil.which("uv")` as authority — the PATH-discovered uv binary, not the frozen binding's exact SHA. |
| A_PACKAGE_NETWORK_AUTHORITY | uv sync subprocess could inherit ambient `UV_INDEX_URL` / `PIP_INDEX_URL` / mirror overrides, widening the package network boundary past the frozen `package.uv` domains. |
| A_NORMAL_SUPERVISOR_GREENFIELD_CERT | The previous "Greenfield #3" was finalizer-driven, not the production supervisor lifecycle. A real Claude-builder / Claude-reviewer normal-supervisor run is required. |
| A_FINAL_MASTER_EXACT_SHA_CI | Hosted CI must run on the FINAL master SHA, not an intermediate. |
| A_AUTHORITATIVE_CERT_EVIDENCE | Certification artifacts (BUILD_RECEIPT, REVIEW_VERDICT, STATE.json, receipts) must be persisted under operator-owned storage (`~/.local/state/ownframework-loop/certification/<cert-id>/`), not just in the in-repo `docs/certification/evidence/`. |

## Remediation in progress

```
1. A_UV_CAPABILITY_DECLARATION_PARITY  → canonical
   `validation_environment.is_uv_command(command)` predicate +
   `UV_MEDIATED_SUBCOMMANDS` tuple; both packet admission and the
   validation executor consume the same function.

2. A_UV_EXACT_IDENTITY_BEFORE_EFFECT → re-resolve capability binding
   BEFORE any uv subprocess via new
   `runtime_env.commissioned_validation_resolution()`. Provisioner
   receives the resulting `BoundUvIdentity` (executable path + SHA
   + version + cache_path + cache_scope + network_domains) and calls
   `verify_bound_uv_identity()` immediately before each subprocess.
   `shutil.which("uv")` is no longer authority.

3. A_PACKAGE_NETWORK_AUTHORITY → strip `UV_INDEX_URL`,
   `UV_EXTRA_INDEX_URL`, `PIP_INDEX_URL`, `PIP_EXTRA_INDEX_URL`,
   `UV_DEFAULT_INDEX`, `UV_INDEX`, `PIP_NO_INDEX`,
   `NPM_CONFIG_REGISTRY`, `npm_config_registry`, `PNPM_REGISTRY`,
   `CARGO_REGISTRIES_*` from the hermetic subprocess env so the
   frozen `package.uv` domains are the sole authority.

4. A_NORMAL_SUPERVISOR_GREENFIELD_CERT → Greenfield #4 run via the
   production supervisor lifecycle (real Claude builder, real
   Claude reviewer, durable DB job, normal receipt contract).

5. A_FINAL_MASTER_EXACT_SHA_CI → push final master, run hosted CI,
   confirm 10/10 PASS on the exact SHA.

6. A_AUTHORITATIVE_CERT_EVIDENCE → mirror every authoritative
   artifact to `~/.local/state/ownframework-loop/certification/<cert-id>/`
   with canonical-content SHA-256s so an operator can re-prove the
   certification without trusting the in-repo doc.
```

## Held until re-closure

```
VALIDATION_ENVIRONMENT_FINAL_CLOSURE = HOLD
READY_FOR_NORMAL_ENGINEERING_USE     = no
WALK_AWAY                             = no
```

## See also

- Original closure draft (held, has known path leak that broke
  checkout_portability):
  `docs/history/cert/2026-09-22_validation_environment_final_closure.SUPERSEDED.md`
- Greenfield #3 evidence (re-classified as MECHANISM_PROOF only, not
  NORMAL_SUPERVISOR_PORTABILITY_CERT):
  `docs/certification/evidence/greenfield-3/SUMMARY.md`
- New Greenfield #4 (real supervisor-driven run, durable DB job):
  pending
