# Compact evidence: ofloop-cert-mature-requests-20260917

Historical authoritative reconstruction from surviving evidence.
This summary replaces the deleted physical fixture repository.
Fields not provable from surviving evidence are written as UNPROVEN.

## Identification

- certification name: ofloop-cert-mature-requests-20260917
  (the original mature Requests certification attempt; NOT the
  R3 final form — this is the first attempt whose packet entered
  the durable supervisor and was rejected by the schema validator
  before any semantic dispatch. The historical defect was that
  invalid pre-seal packet values reached execution.)
- certification type: mature Requests certification (original
  attempt — pre-validation gap; packet reached durable supervisor
  and was refused at dispatch)
- fixture upstream project: requests (https://github.com/psf/requests)
- fixture baseline SHA: dae7ef63b4df6eded86637f251fc4e3a06c3b479
  (Bump https://github.com/astral-sh/ruff-pre-commit (#7616))
- fixture physical path: (retired-fixture-path)

## Certification timing

- certification run id: run-20260917T141722Z-27eebb9e
- certification start time: 2026-09-17T14:17:22Z (UTC; embedded in run id)
  = 2026-09-17T10:17:22-04:00 (EDT)
- job created_at (DB): 2026-09-17T14:18:30Z
- job updated_at (DB): 2026-09-17T14:19:27Z (very short — refused at dispatch)
- supervising session at cert time: UNPROVEN
  (the session that ran `ofloop spec new` for this fixture is not
  in surviving transcripts. The current session ce3c8771 only
  references this fixture in retrospective cleanup context.)

## Loop source at cert time

- CERTIFICATION_LOOP_SOURCE_HEAD: UNPROVEN
  - The closest pre-cert-time commit in ownframework-loop is
    7bc21c72db5f3d0a3e650455bcf1858cced8388e
    ("test: make semantic contract fixture portable",
     2026-09-16T23:44 EDT) — same commit as the greenfield cert.
  - The cert DEFINITELY did not use 9db9a37, which was committed at
    2026-09-18T16:34 EDT (well after this cert at 10:17 EDT
    2026-09-17).

## Runtime generation

- CERTIFICATION_RUNTIME_GENERATION:
  ofloop-0.9.1@payload-a8dfc79668aa4b9597928a4acf200cc77f5a35ffbeb91bcf87c03d0bb27b9afc
  - Source: production supervisor DB jobs.runtime_generation for job 65.
  - Same payload as the greenfield cert (job 64) at the time —
    consistent with the same source HEAD having been installed.
  - Bound at cert time and never reopened (terminal QUARANTINED).

## Supervisor job

- supervisor job id: 65
- run id: run-20260917T141722Z-27eebb9e
- repository: (retired-fixture-path)
- execution mode: SINGLE
- candidate branch: factory/candidate/run-20260917T141722Z-27eebb9e
- terminal supervisor state: QUARANTINED
- last_failure_class: invariant
- last_failure_reason: dispatch_refused
- last_error (DB):
  DispatchError: ofloop build claim (retired-fixture-path)
  run-20260917T141722Z-27eebb9e --actor ofloop-supervisor failed
  rc=4: packet invalid:
    schema: $.work_class: value 'MATURE_FEATURE' not in enum;
    schema: $.required_validation.0.kind: value 'scoped' not in enum;
    schema: $.required_validation.1.kind: value 'scoped' not in enum

## Verdict

- terminal engineering state/verdict: FAIL — packet schema validator
  rejected the MATURE_FEATURE work_class and scoped required_validation
  kinds before any semantic dispatch
- operator intervention count: 0
- actual FAIL reason:
  The packet's work_class was set to MATURE_FEATURE which is not in
  the validator enum at the source HEAD used for this cert. The
  required_validation entries used kind=scoped which is not in the
  validator enum either. The packet reached the durable supervisor
  (sealed) and was refused at dispatch (pre-execution gate).
- key certification conclusion:
  This cert EXPOSED the schema validator gap — invalid pre-seal
  packet values were able to enter the durable supervisor. The
  durable supervisor correctly refused them at dispatch (rc=4),
  preventing any semantic attempt against an invalid packet. The
  cert therefore demonstrated:
  1. The validator gap existed (it accepted MATURE_FEATURE at
     packet-build time).
  2. The durable supervisor correctly refused to dispatch an
     invalid packet.
  Both behaviors were captured in this cert.

## Historical role

This was the original mature Requests certification attempt. It
was NOT the R3 form — it was the run that revealed the pre-seal
validation gap that R3 was meant to harden. R3 itself is not
represented here; the r2 retry (see the next summary) is the
follow-up that exercised the runtime_generation_mismatch surface
after the schema validator was tightened.

## Retirement

- retirement date: 2026-09-18
- retirement Loop source HEAD: 512ac0a75c6dc3f993c2d868978d48dae904897a
- retirement lineage:
  512ac0a7 v0.9.1 closure n: redact retired-fixture absolute paths in evidence
  33ce788b v0.9.1 closure n: compact evidence for retired cert fixtures
  6448a991 v0.9.1 closure n: lifecycle helper failure-path defects (B1 + B2)
  9db9a37c v0.9.1 closure m13: bash || REMOVE_OUT="" clobber fix
- surviving authoritative evidence:
  - production DB row jobs.id=65 (QUARANTINED)
  - this committed summary
