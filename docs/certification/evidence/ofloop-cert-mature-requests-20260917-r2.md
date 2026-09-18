# Compact evidence: ofloop-cert-mature-requests-20260917-r2

Historical authoritative reconstruction from surviving evidence.
This summary replaces the deleted physical fixture repository.
Fields not provable from surviving evidence are written as UNPROVEN.

## Identification

- certification name: ofloop-cert-mature-requests-20260917-r2
  (R2 retry of the mature Requests certification; same upstream
  baseline as the original attempt. This retry exercised the
  serve-time runtime_generation_mismatch protection after the
  source had moved past the cert-time generation.)
- certification type: mature Requests certification (R2 retry —
  pre-validation gap closed; runtime_generation_mismatch surfaced)
- fixture upstream project: requests (https://github.com/psf/requests)
- fixture baseline SHA: dae7ef63b4df6eded86637f251fc4e3a06c3b479
  (Bump https://github.com/astral-sh/ruff-pre-commit (#7616) —
  same baseline as the original R1 attempt; this was the same
  fixture material under a retry path)
- fixture physical path: (retired-fixture-path)

## Certification timing

- certification run id: run-20260918T013216Z-ebe04da7
- certification start time: 2026-09-18T01:32:16Z (UTC; embedded in run id)
  = 2026-09-17T21:32:16-04:00 (EDT) — late evening on 2026-09-17
- job created_at (DB): 2026-09-18T01:34:05Z
- job updated_at (DB): 2026-09-18T02:16:42Z
- supervising session at cert time: UNPROVEN
  (the session that ran `ofloop spec new` for this fixture is not
  in surviving transcripts.)

## Loop source at cert time

- CERTIFICATION_LOOP_SOURCE_HEAD: UNPROVEN
  - The closest pre-cert-time commit in ownframework-loop is
    0c7d460c010b36aa2f4e4c99eff23fdb73cf7daf
    ("v091 residual closure: program_final protection, atomic
     mirror, dedup-marker, budget math",
     2026-09-17T21:14 EDT).
  - The cert DEFINITELY did not use 9db9a37, which was committed at
    2026-09-18T16:34 EDT (well after this cert at 21:32 EDT
    2026-09-17). The cert DEFINITELY did not use 07f19df or any
    commit after it (07f19df was committed at 2026-09-18T13:41 EDT,
    well after this cert).
  - The cert's payload was bound BEFORE the next source movement
    that re-installed with the runtime_generation_mismatch payload
    (8dafe59b...) — the cert ran with its source HEAD, but the
    installed/serving payload was 8dafe59b... (a newer payload than
    the cert's bound payload a8dfc796...). The mismatch is what
    caused the QUARANTINE.

## Runtime generation

- CERTIFICATION_RUNTIME_GENERATION:
  ofloop-0.9.1@payload-8dafe59b8289fc9b385453b39ec2287df58ee624ff147d39f34a8050dbec0e02
  - Source: production supervisor DB jobs.runtime_generation for job 67.
  - This is the payload bound to the cert at enqueue time. The DB
    record of this payload is the canonical evidence that the cert
    was bound to this specific installed runtime.
  - Bound at cert time and never reopened (terminal QUARANTINED).

## Supervisor job

- supervisor job id: 67
- run id: run-20260918T013216Z-ebe04da7
- repository: (retired-fixture-path)
- execution mode: SINGLE
- candidate branch: factory/candidate/run-20260918T013216Z-ebe04da7
- terminal supervisor state: QUARANTINED
- last_failure_class: runtime_generation_mismatch
- last_failure_reason: runtime_generation_mismatch
- last_error (DB):
  runtime generation mismatch: job bound to
  ofloop-0.9.1@payload-8dafe59b8289fc9b385453b39ec2287df58ee624ff147d39f34a8050dbec0e02,
  serving runtime is
  ofloop-0.9.1@payload-91657b2491db994fd83c3e399c2d4fc48c27c20b6fdb2647db12b59112e1e4e0;
  refusing silent generation switch — operator migration required
  (supervisor resume rebinds the run)

## Verdict

- terminal engineering state/verdict: FAIL — runtime_generation_mismatch
  at serve time; bound payload and serving payload differed
- operator intervention count: 0
- actual FAIL reason:
  The cert's bound payload (8dafe59b...) and the supervisor's
  serving payload (91657b2491db994fd83c3e399c2d4fc48c27c20b6fdb2647db12b59112e1e4e0)
  were different. The serve-time check correctly refused the
  silent generation switch — a sealed unfinished job was protected
  against an unintentional payload rebind. Explicit operator
  migration via `supervisor resume` is the intended rebind path.
- key certification conclusion:
  This cert demonstrated the serve-time runtime_generation_mismatch
  protection is real and fail-closed. A bound run from a prior
  payload cannot silently switch generations; the supervisor
  refused and the job remained QUARANTINED pending operator
  rebind. The cert was the canonical evidence that this surface
  works end-to-end.

## Historical role

R2 retry of the mature Requests certification, after the schema
validator gap was closed. The cert succeeded packet validation but
hit the runtime_generation_mismatch surface because the source
movement between enqueue and serve installed a newer payload than
the cert had been bound to.

## Retirement

- retirement date: 2026-09-18
- retirement Loop source HEAD: 512ac0a75c6dc3f993c2d868978d48dae904897a
- retirement lineage:
  512ac0a7 v0.9.1 closure n: redact retired-fixture absolute paths in evidence
  33ce788b v0.9.1 closure n: compact evidence for retired cert fixtures
  6448a991 v0.9.1 closure n: lifecycle helper failure-path defects (B1 + B2)
  9db9a37c v0.9.1 closure m13: bash || REMOVE_OUT="" clobber fix
- surviving authoritative evidence:
  - production DB row jobs.id=67 (QUARANTINED)
  - this committed summary
