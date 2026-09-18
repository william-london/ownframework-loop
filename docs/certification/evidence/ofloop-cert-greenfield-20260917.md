# Compact evidence: ofloop-cert-greenfield-20260917

Historical authoritative reconstruction from surviving evidence.
This summary replaces the deleted physical fixture repository.
Fields not provable from surviving evidence are written as UNPROVEN.

## Identification

- certification name: ofloop-cert-greenfield-20260917
- certification type: greenfield bootstrap baseline
- fixture upstream project: ownframework-loop
- fixture baseline SHA: b168fc497dd23307344d7f67a3eb821800ab36a2 (loop-v1: minimal bootstrap baseline)
- fixture directory contents at retirement: only README.md
  - README content (preserved via prior forensic transcript):
    "Minimal bootstrap baseline created by OwnFramework Loop."
- fixture physical path: (retired-fixture-path)

## Certification timing

- certification run id: run-20260917T131150Z-64f56e4c
- certification start time: 2026-09-17T13:11:50Z (UTC; embedded in run id)
  = 2026-09-17T09:11:50-04:00 (EDT)
- job created_at (DB): 2026-09-17T13:13:01Z
- job updated_at (DB): 2026-09-17T13:42:21Z
- filesystem creation time of fixture directory: 2026-09-17T09:13 EDT
- supervising session at cert time: UNPROVEN
  (the session that ran `ofloop spec new` for this fixture is not
  in surviving transcripts; only the forensic 156fcee0 session at
  2026-09-17T14:09Z that inspected the fixture afterwards survives)

## Loop source at cert time

- CERTIFICATION_LOOP_SOURCE_HEAD: UNPROVEN
  - The closest pre-cert-time commit in ownframework-loop is
    7bc21c72db5f3d0a3e650455bcf1858cced8388e
    ("test: make semantic contract fixture portable",
     2026-09-16T23:44 EDT).
  - The cert may have used master or a local branch checked out at
    this time. Surviving evidence does not pin which.
  - The cert DEFINITELY did not use 9db9a37, which was committed at
    2026-09-18T16:34 EDT (well after this cert).

## Runtime generation

- CERTIFICATION_RUNTIME_GENERATION:
  ofloop-0.9.1@payload-a8dfc79668aa4b9597928a4acf200cc77f5a35ffbeb91bcf87c03d0bb27b9afc
  - Source: production supervisor DB jobs.runtime_generation for job 64.
  - This payload was bound at cert time and never reopened (terminal DONE).

## Supervisor job

- supervisor job id: 64
- run id: run-20260917T131150Z-64f56e4c
- repository: (retired-fixture-path)
- execution mode: SINGLE
- candidate branch: factory/candidate/run-20260917T131150Z-64f56e4c
- terminal supervisor state: DONE

## Verdict

- terminal engineering state/verdict: PASS (DONE)
- operator intervention count: 0
- actual PASS reason: bootstrap baseline completed normally; the
  greenfield cert succeeded as documented in the fixture's README
  ("Minimal bootstrap baseline created by OwnFramework Loop").
- key certification conclusion: this certification demonstrated
  that a minimal bootstrap baseline repository can be created and
  registered as a Loop candidate without any prior source-tree
  content beyond a README. The resulting DB row is the canonical
  durable evidence that the greenfield cert ran and completed.

## Historical role

This cert was the greenfield-bootstrap baseline run that
demonstrated a fresh empty repository can be commissioned as a
Loop candidate. It is NOT the same as a mature Requests cert.

## Retirement

- retirement date: 2026-09-18
- retirement Loop source HEAD: 512ac0a75c6dc3f993c2d868978d48dae904897a
- retirement lineage:
  512ac0a7 v0.9.1 closure n: redact retired-fixture absolute paths in evidence
  33ce788b v0.9.1 closure n: compact evidence for retired cert fixtures
  6448a991 v0.9.1 closure n: lifecycle helper failure-path defects (B1 + B2)
  9db9a37c v0.9.1 closure m13: bash || REMOVE_OUT="" clobber fix
- surviving authoritative evidence:
  - production DB row jobs.id=64 (DONE)
  - this committed summary
  - forensic transcript 156fcee0-511d-446b-b710-186fd844728f
    (forensic inspection after cert, not the cert session itself)
