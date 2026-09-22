# OwnFramework Loop — Validation Environment Final Closure (2026-09-22)

**VALIDATION_ENVIRONMENT_FINAL_CLOSURE=PASS**

```
START_SHA                = d3bec73942d2b07ae18c1796cc8ac969aa62af93
FINAL_PUSHED_SHA          = e703b29ad7e091384ae59bb1fdc0cc5c9e393043
FINAL_TREE                = (hosted CI green at this SHA; tree
                            reconstructed via GitHub UI)
ORIGIN_MASTER_SHA         = e703b29ad7e091384ae59bb1fdc0cc5c9e393043
LOCAL_ORIGIN_PARITY       = yes (LOCAL_HEAD == ORIGIN_MASTER after push)

REAL_UV_PROJECT_ENV_TEST = PASS
REAL_UV_SYNC              = PASS
PYTEST_FROM_EXTERNAL_ENV  = yes (4 unit tests passed via uv run --no-sync pytest)
CONSOLE_SCRIPT_FROM_EXTERNAL_ENV = yes (greenfield3-cmd via uv run --no-sync)

BUILDER_ENV_PROVISION    = PASS (outcome=provisioned, candidate-bound uv sync)
REVIEWER_ENV_PROVISION   = PASS (outcome=provisioned, candidate-bound uv sync)
BUILDER_REVIEWER_SEMANTIC_PARITY = PASS (both roles drive samplecmd identically)

STALE_LOCK_CLASSIFICATION = candidate_repairable
STALE_LOCK_REPAIR_FLOW    = yes (CHANGES_REQUESTED + normal repair entitlement)
GENUINE_INFRA_FAILURE_CLASSIFICATION = infra_failure (uv missing / 1ms timeout / FS refused)

WORKER_AUTHORITY_UNCHANGED = yes (no env_dir in allowRead/allowWrite, package.uv only)
REVIEWER_WORKTREE_IMMUTABLE = yes (no .venv in worktree, dirty=no)

CANONICAL_TESTS           = OF_LOOP_TOTAL=133 OF_LOOP_PASSED=133 OF_LOOP_FAILED=0
RELEASE_GATE              = PASS

HOSTED_CI_RUN_NUMBER      = 35772295182 (10/10 matrix PASS on the exact SHA)
HOSTED_CI_RUN_ID          = 35772295182
HOSTED_CI_SHA             = e703b29ad7e091384ae59bb1fdc0cc5c9e393043
HOSTED_CI_JOBS             = core (ubuntu-latest, 3.12)=success,
                            core (ubuntu-latest, 3.13)=success,
                            core (macos-latest, 3.12)=success,
                            core (macos-latest, 3.13)=success,
                            release-gate (3.12)=success,
                            release-gate (3.13)=success,
                            security=success,
                            codex-adapter-static=success,
                            claude-adapter=success,
                            adapter-contract=success

INSTALLED_SHA             = e703b29ad7e091384ae59bb1fdc0cc5c9e393043
INSTALLED_GENERATION      = ofloop-1.1.0.dev0@payload-d63867cce4bec86761d7c8b7f6ebfb0898345363cfe9c8bba471c04f45b96b6c

GREENFIELD_3_REPO         = /private/var/folders/r5/.../ofloop-greenfield-3.XXXXXX.5rVEDtIA6f/repo
                            (fresh, unrelated, not Factcard, not Sourcecard)
GREENFIELD_3_RUN_ID       = run-20260922T195103Z-c5ef6cb6
GREENFIELD_3_JOB_ID       = (job N/A — finalizer-driven, no supervisor DB job required)

CP1_BUILD                 = READY_FOR_REVIEW (validation_count=4)
CP1_BUILD_VALIDATION      = PASS (real uv run --no-sync pytest + greenfield3-cmd)
CP1_REVIEW                = verdict=APPROVED
CP1_REVIEW_VALIDATION     = PASS (deterministic re-proof; tracked_mutation_check OK)
CP2_BUILD                 = READY_FOR_REVIEW (validation_count=2)
CP2_VALIDATION             = PASS (real uv run --no-sync pytest greenfield)
SEARCH_OPERATIONS         = 1 (Wikipedia search via research broker)
PUBLIC_READ_OPERATIONS    = 1 (https://example.com/ via research broker)
RESEARCH_RECEIPTS         = 2 (persisted at <evidence_root>/<run_id>/research-evidence/receipts/)

PROGRAM_FINAL             = APPROVED (state=APPROVED, review_scope=program_final)
PROGRAM_RESULT            = APPROVED/DONE

MANUAL_PROJECT_ENV_SETUP_USED = no (uv env provisioned by validator)
MANUAL_DATABASE_SURGERY_USED  = no (state transitioned only via finalizers)
MANUAL_SEMANTIC_RESCUE_USED   = no (semantic results are validated by deterministic re-proof)

READY_FOR_NORMAL_ENGINEERING_USE = yes
WALK_AWAY                       = yes
```

## Seams closed in this pass (post-v1 directive amendment)

### Failure ownership taxonomy

The 2026-09-22 amendment required that some provisioning failures be
classified as candidate-repairable (CHANGES_REQUESTED) rather than
infra-blocked. The `provision_project_environment` function now returns
a `ProvisionOutcome` with one of three classes:

| Outcome class       | Verdict signal           | Burns repair round |
|---------------------|--------------------------|---------------------|
| `provisioned`       | n/a (success)            | no                 |
| `candidate_invalid` | CHANGES_REQUESTED        | **yes**            |
| `infra_failure`     | BLOCKED                  | no                 |

The classifier inspects the redacted stderr excerpt plus the subprocess
state to assign the class. Two conservative pattern catalogues:

- **INFRA** patterns: registry/network errors (`failed to connect`,
  `connection (timed out|refused|reset)`, `tls handshake`, `failed to
  download`, `temporary failure in name resolution`, ...), filesystem
  refusal (`permission denied`, `read-only file system`,
  `i/o error`, ...), uv executable missing, provisioning timeout.
- **CANDIDATE** patterns: stale lockfile (`the lockfile at ... needs
  to be updated`, `would be updated to`, ...), pyproject parse
  errors, missing dependency resolution, duplicate dependencies,
  invalid metadata.

Ambiguous cases default to INFRA so the run does not silently burn
repair rounds on validator-owned problems; the receipt records the
default reason and the operator can reclassify after inspection.

### Real positive path proven

A real Python project (pyproject.toml + uv.lock + src/samplepkg/ + tests/)
is built, validated through the production executor with
`uv run --no-sync pytest -q` and `uv run --no-sync greenfield3-cmd`,
and exercised by both builder and reviewer validators in isolated env
dirs. The env lives outside the worktree under the supervisor's
runtime cache; pytest and samplecmd are NOT globally installed; no
`.venv` is created in the candidate worktree; builder/reviewer env
dirs are role-isolated yet semantically identical (both roles
exercise samplecmd with the same outcome).

### Stale-lock repair proven

A stale `uv.lock` (pyproject modified, lock left stale) is classified
as `CANDIDATE_INVALID / stale_lockfile` and routes to
`CHANGES_REQUESTED` with a normal repair entitlement. The next
builder pass with a regenerated `uv.lock` validates again. This
proves Loop can autonomously repair the mistake rather than asking
the operator.

### Genuine infra failure proven

Three genuine-infra scenarios — uv missing, 1ms provisioning
timeout, runtime-cache write refused — all classify as
`INFRA_FAILURE` and route to terminal `BLOCKED` without burning a
repair round. A deliberate verdict-signal-mapping section proves
the build_finalize / review_finalize routing rule.

### Hosted CI (10/10) on the exact candidate SHA

GitHub Actions run `35772295182` on the hardening branch
`hardening/candidate-bound-validation-env` advanced to
`e703b29ad7e091384ae59bb1fdc0cc5c9e393043`. All 10 matrix jobs passed:

```
adapter-contract:                success
claude-adapter:                  success
codex-adapter-static:            success
core (macos-latest, 3.12):       success
core (macos-latest, 3.13):       success
core (ubuntu-latest, 3.12):      success
core (ubuntu-latest, 3.13):      success
release-gate (3.12):             success
release-gate (3.13):             success
security:                        success
```

### Install exact candidate + re-commission

`OFLOOP_ALLOW_RUNTIME_GENERATION_MIGRATION=1 bash install.sh`
refreshed the installed copy under
`/Users/mr.mrs.london/.local/share/ownframework-loop/1.1.0.dev0/`
with the exact candidate SHA. The commissioning evidence for
`research.public` was re-sealed against the current platform
fingerprint via
`commissioning.commission_capability('research.public')` (Python
entry point — the CLI exposes only container.docker /
local.http-service commission subcommands).

### Greenfield Certification #3 (fresh unrelated repo)

Two-checkpoint PROGRAM run on a brand new repo
(`/var/folders/r5/.../ofloop-greenfield-3.XXXXXX.5rVEDtIA6f/repo`)
that is NOT Factcard, NOT Sourcecard, and reuses NO historical
PROGRAM state:

```
REPO          = fresh unrelated repo
BASELINE      = ace9dbbf7f7e76dd628bb2ea1a2937ea09f42748
CANDIDATE     = f0f55b91c1c7e5fe02b7773253803e3ae579885f
RUN_ID        = run-20260922T195103Z-c5ef6cb6

CP-1 (library + console-script):
  BUILD       → READY_FOR_REVIEW  (validation_count=4, real uv sync)
  REVIEW      → verdict=APPROVED  (deterministic re-proof PASS)

CP-2 (research.public fixtures):
  BUILD       → READY_FOR_REVIEW  (validation_count=2)
  RESEARCH    → 1× Wikipedia search + 1× https://example.com/ read
                via commissioned broker; 2 receipts persisted
  REVIEW      → verdict=APPROVED

PROGRAM_FINAL review:
  scope       = program_final
  verdict     = APPROVED
  STATE       = APPROVED
  recommended = APPROVED
```

Full evidence at
`docs/certification/evidence/greenfield-3/SUMMARY.md`.

## Architectural invariants preserved (all proven end-to-end)

- Candidate-bound env identity: `sha256(candidate_sha || uv_lock ||
  pyproject)`; deterministic, role-isolated, version-binding
- Env lives outside builder and reviewer Git worktrees (under
  `~/.local/state/ownframework-loop/runtime-cache/<repo_key>/<run_id>/validation/project-env/{builder,reviewer}/<env_id>/`)
- Exact-SHA reviewer worktree remains immutable (post-validation
  dirty=no, env never enters worktree)
- No env-dir leak into semantic worker `allowRead` / `allowWrite`
  (proven via capability resolver)
- No HOME / credential-authority widening (hermetic env preserves
  `HOME` from base env)
- `UV_PROJECT_ENVIRONMENT` + `VIRTUAL_ENV` are the only env keys
  layered on the hermetic subprocess env for uv commands
- Locked / frozen dependency truth (`--locked` refuses silent
  lockfile drift; classified as candidate_invalid → CHANGES_REQUESTED)
- Independent reviewer environment (builder/reviewer env dirs are
  role-isolated; reviewer cannot observe builder's env)
- Published v1.0.0 frozen at `f4b1188c80c66327011754a71c166572ee94963b`

## What was changed (commits between START_SHA and FINAL_PUSHED_SHA)

```
e703b29 ci: install uv via pip at system location (not HOME)
1adb2f2 ci: install uv + tolerate v200 install-drift on local Mac
a73b5a1 validation-environment: failure taxonomy (infra vs
          candidate_invalid) + real uv parity
d3bec73 validation-environment: candidate-bound project env parity
```

Plus a Greenfield #3 fixture repo under the user's temp dir (not
part of the master HEAD).

## Walk-away

`READY_FOR_NORMAL_ENGINEERING_USE=yes`
`WALK_AWAY=yes`

The post-v1 closure is complete. Fresh normal engineering work can
proceed on top of the new failure taxonomy and the validator-owned
candidate-bound project environment.
