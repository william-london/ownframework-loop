# Compact evidence: ofloop-cert-greenfield-20260917

Historical authoritative reconstruction from surviving evidence.
This summary replaces the deleted physical fixture repository.
Fields not provable from surviving evidence are written as UNPROVEN.

## Identification

- certification name: ofloop-cert-greenfield-20260917
- certification type: greenfield bootstrap baseline (a freshly
  initialized empty Loop candidate repository was commissioned and
  exercised end-to-end through the durable supervisor against an
  external human request)
- fixture upstream project: ownframework-loop
- FIXTURE_BASELINE_SHA: b168fc497dd23307344d7f67a3eb821800ab36a2
  (loop-v1: minimal bootstrap baseline; the only surviving commit
  in the now-retired fixture repo; the repo at retirement contained
  only a README.md because the cert-time work was pushed onto a
  candidate branch and later consolidated/cleaned upstream)
- fixture physical path: (retired-fixture-path)

NOTE on FIXTURE_BASELINE vs CERTIFICATION_CANDIDATE_RESULT:

- FIXTURE_BASELINE = the state of the fixture repo at retirement
  (= the empty-bootstrap baseline; contains only README).
- CERTIFICATION_CANDIDATE_RESULT = the work the cert produced
  before the fixture was retired (= the full local CLI follow-up
  tracker implementation on candidate branch
  factory/candidate/run-20260917T131150Z-64f56e4c with 48/48
  product tests passing and reviewer verdict APPROVED).

These two facts are not in conflict; they are different time slices
of the same fixture.

## Certification timing

- certification run id: run-20260917T131150Z-64f56e4c
- certification start time: 2026-09-17T13:11:50Z (UTC; embedded in run id)
  = 2026-09-17T09:11:50-04:00 (EDT)
- job created_at (DB): 2026-09-17T13:13:01Z
- job execution_started_at (DB): 2026-09-17T13:13:07Z (within ~6 s)
- job updated_at (DB): 2026-09-17T13:42:21Z
- supervising session at cert time: UNPROVEN (the session that
  ran `ofloop spec new` for this fixture is not in surviving
  transcripts; only the forensic 156fcee0 session at
  2026-09-17T14:09Z that inspected the fixture afterwards
  survives)

## Loop source at cert time

- CERTIFICATION_LOOP_SOURCE_HEAD: UNPROVEN
  - The closest pre-cert-time commit in ownframework-loop is
    7bc21c72db5f3d0a3e650455bcf1858cced8388e
    ("test: make semantic contract fixture portable",
     2026-09-16T23:44 EDT).
  - The cert DEFINITELY did not use 9db9a37, which was committed
    at 2026-09-18T16:34 EDT (well after this cert at 09:11 EDT
    on 2026-09-17).

## Runtime generation

- CERTIFICATION_RUNTIME_GENERATION:
  ofloop-0.9.1@payload-a8dfc79668aa4b9597928a4acf200cc77f5a35ffbeb91bcf87c03d0bb27b9afc
  - Source: production supervisor DB jobs.runtime_generation for
    job 64.

## Supervisor job

- supervisor job id: 64
- run id: run-20260917T131150Z-64f56e4c
- repository: (retired-fixture-path)
- execution mode: SINGLE
- candidate branch: factory/candidate/run-20260917T131150Z-64f56e4c
- candidate SHA: f075e638ff84d660d2904a4bbf5cd54db35ccb8b
- dispatch_count: 3
- max_wall_seconds: 604800
- max_total_cost_usd: 25
- terminal supervisor state: DONE

## Human request (the cert's product brief)

The cert-time human request, reconstructed from the surviving
builder attempt transcript:

- a small local CLI follow-up tracker;
- features: contacts, scheduling, due items, completion, export;
- constraints: local/simple, no cloud, reliable, testable,
  documented;
- explicit acceptance criteria AC-1 through AC-6 (six ACs covering
  storage lifecycle, contact validation, scheduling, due listing,
  completion, export roundtrip, CLI integration, and corrupt-storage
  error path).

## Cert result

- terminal engineering state/verdict: APPROVED
- operators involved: one builder, one reviewer
- zero repairs; zero operator interventions
- product tests: 48/48 PASS
- final cost: approximately 8.1806355 USD
  - BUILD cost: 3.3946909999999986
  - REVIEW cost: 4.785944500000001
- BUILD result (from supervisor stdout event log):
  - added_lines: 1868
  - files_changed: 18
  - hard_secret_blocks: 0
  - protected_findings: 0
  - scope_findings: 0
  - validation_count: 1
  - ok: true
  - next_state: READY_FOR_REVIEW
- REVIEW result:
  - must_fix_count: 0
  - validation_pass: true
  - verdict: APPROVED
- TERMINAL state: APPROVED

## Key certification conclusion

The greenfield cert demonstrated that a freshly initialized empty
Loop candidate repository can be commissioned against a real
human product brief, run end-to-end through the durable
supervisor, and reach APPROVED with one builder + one reviewer,
zero repairs, 48/48 product tests passing, and an authoritative
candidate SHA on the dedicated candidate branch. The fixture
repo's later empty-bootstrap README reflects the fixture's
post-certification cleaned state, not the cert-time work.

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
  - supervisor stdout log lines 32419-32421 (BUILD/REVIEW/TERMINAL
    events for run-20260917T131150Z-64f56e4c with candidate_sha
    f075e638... and verdict APPROVED)
  - builder attempt log:
    worker-logs/d5b71fc1d6e4d5a4/run-20260917T131150Z-64f56e4c/job-64-builder-attempt-b7b0a278d90e433f9d7107c87761bb6e.out
  - reviewer attempt log:
    worker-logs/d5b71fc1d6e4d5a4/run-20260917T131150Z-64f56e4c/job-64-reviewer-attempt-ea8cf390d3c54ba5b7cbc91331ec35ef.out
  - this committed summary
