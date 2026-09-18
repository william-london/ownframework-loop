# Compact evidence: ofloop-cert-mature-requests-20260917-r2

- certification type: mature Requests R2 retry fixture
- Loop source HEAD at cert time: 9db9a37 / closure m13
- runtime generation bound: ofloop-0.9.1@payload-8dafe59b8289fc9b385453b39ec2287df58ee624ff147d39f34a8050dbec0e02
- upstream baseline: same as r1 (dae7ef63)
- local fixture HEAD: dae7ef63b4df6eded86637f251fc4e3a06c3b479
- run id: run-20260918T013216Z-ebe04da7
- supervisor job id: 67
- candidate branch: factory/candidate/run-20260918T013216Z-ebe04da7
- terminal status: QUARANTINED
- verdict reason: runtime_generation_mismatch — job bound to ofloop-0.9.1@payload-8dafe59b..., serving runtime is ofloop-0.9.1@payload-91657b2491db994fd83c3e399c2d4fc48c27c20b6fdb2647db12b59112e1e4e0
- operator intervention count: 0
- key validation result: serve-time runtime_generation_mismatch protection correctly refused silent generation switch
- reason for FAIL: bound run was for prior payload; the next payload's serve refused to rebind without explicit operator migration (supervisor resume)
- fixture retirement date: 2026-09-18
- fixture retirement path: /Users/mr.mrs.london/projects/ofloop-cert-mature-requests-20260917-r2
- DB row preserved: jobs.id=67 (status QUARANTINED, no semantic attempts)
