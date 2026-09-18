# Compact evidence: ofloop-cert-mature-requests-20260917-r2

Historical authoritative reconstruction from surviving evidence.
This summary replaces the deleted physical fixture repository.
Fields not provable from surviving evidence are written as UNPROVEN.

## Identification

- certification name: ofloop-cert-mature-requests-20260917-r2
  (R2 retry of the mature Requests certification; same upstream
  baseline as the original attempt)
- certification type: mature Requests certification (R2 retry)
- fixture upstream project: requests (https://github.com/psf/requests)
- fixture baseline SHA: dae7ef63b4df6eded86637f251fc4e3a06c3b479
  (Bump https://github.com/astral-sh/ruff-pre-commit (#7616) —
  same baseline as the original R1 attempt; the R2 fixture was the
  same fixture material under a retry path)
- fixture physical path: (retired-fixture-path)

## Certification timing

- certification run id: run-20260918T013216Z-ebe04da7
- certification start time: 2026-09-18T01:32:16Z (UTC; embedded in run id)
  = 2026-09-17T21:32:16-04:00 (EDT) — late evening on 2026-09-17
- job created_at (DB): 2026-09-18T01:34:05Z
- job updated_at (DB): 2026-09-18T02:16:42Z
- supervising session at cert time: UNPROVEN

## CERTIFICATION_TIME_OUTCOME (the cert-time outcome)

- source mutations during the cert: 0
- execution mode: SINGLE
- candidate SHA: null (no candidate was produced)
- semantic attempts: 0 (no worker ever ran)
- funded cost: 0.0 USD
- job status at cert time: QUEUED (the valid enrolled job was not
  consumed by the durable supervisor)
- engineering state at cert time: AWAITING_APPROVAL
- product was never evaluated
- PROGRAM final review was not exercised
- operator intervention count: 0

The cert-time failure was a supervisor non-progress failure: the
valid enrolled job was not consumed because the commissioned
launchd supervisor was serving a stale or wrong runtime state /
a different supervisor DB. This non-progress was the canonical
event that later drove the commissioning-identity investigation
(ultimately the activation-receipt + startup-ready architecture
and the canonical-label lifecycle primitive were the resolution).

## LATER_PRESERVATION_STATE (post-certification DB evolution)

After the cert had already failed, the preserved job 67 was
later marked QUARANTINED through runtime_generation_mismatch as
Loop source and runtime moved past the cert-time generation:

- LATER supervisor state: QUARANTINED
- LATER last_failure_class: runtime_generation_mismatch
- LATER last_failure_reason (DB last_error):
  "runtime generation mismatch: job bound to
   ofloop-0.9.1@payload-8dafe59b8289fc9b385453b39ec2287df58ee624ff147d39f34a8050dbec0e02,
   serving runtime is
   ofloop-0.9.1@payload-91657b2491db994fd83c3e399c2d4fc48c27c20b6fdb2647db12b59112e1e4e0;
   refusing silent generation switch — operator migration required
   (supervisor resume rebinds the run)"

The original cert failure (supervisor non-progress) is NOT to be
rewritten as runtime_generation_mismatch. These are distinct events
at distinct times:

  t0 = 2026-09-18T01:32:16Z (cert run-id timestamp)
       CERTIFICATION_TIME_OUTCOME:
         no progress; job stayed QUEUED; no worker ran
  t1 = later, when source/runtime moved past the cert-time bound
       LATER_PRESERVATION_STATE:
         job transitioned QUEUED → QUARANTINED via the
         runtime_generation_mismatch surface (this surface was
         the very protection added by the commissioning-identity
         work that the cert-time failure motivated)

## Loop source at cert time

- CERTIFICATION_LOOP_SOURCE_HEAD: UNPROVEN
  - The closest pre-cert-time commit in ownframework-loop is
    0c7d460c010b36aa2f4e4c99eff23fdb73cf7daf
    ("v091 residual closure: program_final protection, atomic
     mirror, dedup-marker, budget math",
     2026-09-17T21:14 EDT).
  - The cert DEFINITELY did not use 9db9a37, which was committed
    at 2026-09-18T16:34 EDT (well after this cert at 21:32 EDT
    on 2026-09-17). The cert DEFINITELY did not use 07f19df or
    any commit after it (07f19df was committed at
    2026-09-18T13:41 EDT, well after this cert).

## Runtime generation

- CERTIFICATION_RUNTIME_GENERATION:
  ofloop-0.9.1@payload-8dafe59b8289fc9b385453b39ec2287df58ee624ff147d39f34a8050dbec0e02
  - Source: production supervisor DB jobs.runtime_generation for
    job 67 (the cert-time bound payload).
- LATER_SERVING_RUNTIME_GENERATION (post-cert, when QUARANTINE was
  applied):
  ofloop-0.9.1@payload-91657b2491db994fd83c3e399c2d4fc48c27c20b6fdb2647db12b59112e1e4e0
  - Source: supervisor stdout event for job 67 QUARANTINED action.

## Supervisor job

- supervisor job id: 67
- run id: run-20260918T013216Z-ebe04da7
- repository: (retired-fixture-path)
- execution mode: SINGLE
- candidate branch: factory/candidate/run-20260918T013216Z-ebe04da7
- dispatch_count: 1
- max_wall_seconds: 14400
- max_total_cost_usd: 25
- input_tokens / output_tokens / cache tokens: 0 / 0 / 0
- worker_pid at cert time: None (no worker ever ran)
- execution_started_at at cert time: None
- CURRENT terminal supervisor state (LATER_PRESERVATION_STATE):
  QUARANTINED
- LATER last_failure_class: runtime_generation_mismatch

## Verdict

- CERTIFICATION_TIME_OUTCOME: FAIL — supervisor non-progress.
  The valid enrolled job was not consumed. No semantic attempt
  occurred; engineering state remained AWAITING_APPROVAL; product
  was never evaluated; PROGRAM final review was not exercised.
- LATER_PRESERVATION_STATE: QUARANTINED via
  runtime_generation_mismatch as source/runtime moved past the
  cert-time bound. This later state is a separate event from the
  cert-time failure.
- operator intervention count at cert time: 0
- actual FAIL reason at cert time: supervisor non-progress; the
  valid enrolled job was not consumed by the commissioned launchd
  supervisor (stale/wrong runtime state or different supervisor
  DB at the time the cert was attempted). This non-progress was
  the canonical event that motivated the subsequent
  commissioning-identity investigation.

## Historical role

R2 retry of the mature Requests certification. The cert
demonstrated a supervisor non-progress failure mode where the
commissioned launchd supervisor did not consume the valid enrolled
job. This motivated the commissioning-identity work that produced
the activation-receipt + startup-ready architecture and the
canonical-label lifecycle primitive. The later QUARANTINED state
came through the runtime_generation_mismatch surface — the very
protection added by that commissioning-identity work.

## Retirement

- retirement date: 2026-09-18
- retirement Loop source HEAD: 512ac0a75c6dc3f993c2d868978d48dae904897a
- retirement lineage:
  512ac0a7 v0.9.1 closure n: redact retired-fixture absolute paths in evidence
  33ce788b v0.9.1 closure n: compact evidence for retired cert fixtures
  6448a991 v0.9.1 closure n: lifecycle helper failure-path defects (B1 + B2)
  9db9a37c v0.9.1 closure m13: bash || REMOVE_OUT="" clobber fix
- surviving authoritative evidence:
  - production DB row jobs.id=67 (CURRENT: QUARANTINED; cert-time:
    QUEUED with AWAITING_APPROVAL engineering state)
  - supervisor stdout log line 32430 (QUARANTINED event with the
    runtime_generation_mismatch payload pair)
  - this committed summary
