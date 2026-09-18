# Compact evidence: ofloop-cert-mature-requests-20260917

- certification type: mature Requests R3 fixture
- Loop source HEAD at cert time: 9db9a37 / closure m13
- runtime generation bound: ofloop-0.9.1@payload-a8dfc79668aa4b9597928a4acf200cc77f5a35ffbeb91bcf87c03d0bb27b9afc
- upstream baseline: astral-sh/ruff-pre-commit#7616
- local fixture HEAD: dae7ef63b4df6eded86637f251fc4e3a06c3b479
- run id: run-20260917T141722Z-27eebb9e
- supervisor job id: 65
- candidate branch: factory/candidate/run-20260917T141722Z-27eebb9e
- terminal status: QUARANTINED
- verdict reason: dispatch_refused — packet invalid: schema: $.work_class: value 'MATURE_FEATURE' not in enum; schema: $.required_validation.0.kind: value 'scoped' not in enum; schema: $.required_validation.1.kind: value 'scoped' not in enum
- operator intervention count: 0
- key validation result: packet schema validator rejected MATURE_FEATURE work_class before any semantic dispatch
- reason for FAIL: schema mismatch between mature R3 packet and the validator enum at HEAD 9db9a37
- fixture retirement date: 2026-09-18
- fixture retirement path: /Users/mr.mrs.london/projects/ofloop-cert-mature-requests-20260917
- DB row preserved: jobs.id=65 (status QUARANTINED, no semantic attempts)
