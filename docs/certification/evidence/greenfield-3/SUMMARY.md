# Greenfield Certification #3 — Authoritative Evidence Summary

## Identification

- certification name: ofloop-cert-greenfield-3 (2026-09-22)
- certification type: greenfield end-to-end PROGRAM (two checkpoints) → PROGRAM_FINAL APPROVED
- fixture upstream project: ownframework-loop at SHA e703b29ad7e091384ae59bb1fdc0cc5c9e393043
- fixture physical path: /var/folders/r5/_0bfjyj129953ndp19ms9j9r0000gn/T/ofloop-greenfield-3.XXXXXX.5rVEDtIA6f/repo
- FIXTURE_BASELINE_SHA (greenfield-3 initial empty master): ace9dbbf7f7e76dd628bb2ea1a2937ea09f42748
- candidate SHA at PROGRAM_FINAL (master HEAD after CP work): f0f55b91c1c7e5fe02b7773253803e3ae579885f
- run id: run-20260922T195103Z-c5ef6cb6
- authoritative artifacts:
  - APPROVAL.json
  - BUILD_RECEIPT.json
  - REVIEW_VERDICT.json
  - STATE.json
  - research-evidence/receipts/op-*.json (2 broker receipts)

## Outcome

- final STATE.state: APPROVED
- REVIEW_VERDICT.verdict: APPROVED
- REVIEW_VERDICT.recommended_next_state: APPROVED
- REVIEW_VERDICT.review_scope: program_final
- All 4 acceptance criteria passed (AC-1, AC-2, AC-3, AC-4).
- 0 hard secrets; 0 protected findings; 0 scope findings across all builds + reviews.
- research.public broker receipts: 2 (Wikipedia search + dynamic URL read of example.com).

## Required proof recorded

- REAL_UV_PROJECT_ENV_TEST=PASS — production validator drove real uv sync
- EXTERNAL_PROJECT_ENV_CREATED=yes — validator-owned, outside worktree
- PROJECT_ENV_OUTSIDE_WORKTREE=yes
- PYTEST_FROM_EXTERNAL_ENV=yes — validator ran uv run --no-sync pytest -q
- CONSOLE_SCRIPT_FROM_EXTERNAL_ENV=yes — validator ran uv run --no-sync greenfield3-cmd
- GLOBAL_PYTEST_REQUIRED=no
- GLOBAL_SAMPLECMD_REQUIRED=no
- WORKTREE_DOT_VENV_CREATED=no
- REVIEWER_WORKTREE_DIRTY=no
- BUILDER_ENV_PROVISION=PASS
- REVIEWER_ENV_PROVISION=PASS
- BUILDER_REVIEWER_SEMANTIC_PARITY=PASS
- STALE_LOCK_CLASSIFICATION=candidate_repairable
- STALE_LOCK_REPAIR_FLOW=yes
- GENUINE_INFRA_FAILURE_CLASSIFICATION=infra_failure
- VALIDATION_INFRA_FAILURE=yes
- CHANGES_REQUESTED=no (for infra)
- REPAIR_ROUND_BURNED=no (for infra)
- WORKER_AUTHORITY_UNCHANGED=yes
- HOSTED_CI_RUN_NUMBER=35772295182 (10/10 PASS)
- HOSTED_CI_SHA=e703b29ad7e091384ae59bb1fdc0cc5c9e393043

## Architecture invariants preserved (proven during greenfield-3)

- Candidate-bound env identity: derived from candidate SHA + uv.lock + pyproject.toml
- Env lives outside builder + reviewer Git worktrees (under supervisor runtime cache)
- Exact-SHA reviewer worktree remains immutable (verified via dirty_status)
- No env_dir leak into semantic worker allowRead / allowWrite
- HOME preservation through hermetic_subprocess_env
- VIRTUAL_ENV + UV_PROJECT_ENVIRONMENT are the only env keys layered for uv commands
- Locked / frozen dependency truth (--locked refused drift)
- Independent reviewer environment (role-isolated env_dir)
- Published v1.0.0 frozen at f4b1188c80c66327011754a71c166572ee94963b
