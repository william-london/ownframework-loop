# OwnFramework Loop — Validation Environment Final Closure (2026-09-22)

**VALIDATION_ENVIRONMENT_FINAL_CLOSURE=PASS**

```
START_SHA                  = d4af9e3a4ba31b49b02ab807fcb3b5ac38e9a0f8
FINAL_PUSHED_SHA           = d67af5ff159a59fa0a0ef8adcf384ea60c0dafa0
FINAL_TREE                 = (hosted CI green at this SHA)
ORIGIN_MASTER_SHA          = d67af5ff159a59fa0a0ef8adcf384ea60c0dafa0
LOCAL_ORIGIN_PARITY        = yes (LOCAL_HEAD == ORIGIN_MASTER after push)

CANONICAL_TESTS            = OF_LOOP_TOTAL=135 OF_LOOP_PASSED=135
                             OF_LOOP_FAILED=0
RELEASE_GATE               = PASS

HOSTED_CI_RUN_NUMBER       = 511 (10/10 matrix PASS on the exact SHA)
HOSTED_CI_RUN_ID           = 35785229071
HOSTED_CI_SHA              = d67af5ff159a59fa0a0ef8adcf384ea60c0dafa0
HOSTED_CI_BRANCH           = hardening/validation-env-final-closure-2026-09-22-v2
HOSTED_CI_URL              = https://github.com/william-london/ownframework-loop/actions/runs/35785229071
HOSTED_CI_JOBS             = codex-adapter-static, security,
                             core (ubuntu-latest, 3.12), core (ubuntu-latest, 3.13),
                             core (macos-latest, 3.12), core (macos-latest, 3.13),
                             release-gate (3.12), release-gate (3.13),
                             claude-adapter, adapter-contract — all 10 success

INSTALLED_SHA              = d67af5ff159a59fa0a0ef8adcf384ea60c0dafa0
INSTALLED_GENERATION       = ofloop-1.1.0.dev0@payload-4c906085dcc4e3497d9f5e3eb08a21e478ab1e4a254510ed3da27f2c6bed44bc

GREENFIELD_4_REPO          = (fresh, unrelated, post-remediation)
                             /private/var/folders/r5/_0bfjyj129953ndp19ms9j9r0000gn/T/ofloop-greenfield-4.XXXXXX.TMF0jPdD1Q/repo/repo
GREENFIELD_4_RUN_ID        = run-20260922T210439Z-583ff7a2
GREENFIELD_4_BASELINE_SHA  = 40cc891ea3a178fb31e780e43d35e8b135efb2ae
GREENFIELD_4_CANDIDATE_SHA = 353f8be26a47c6b3384f50c14590ec551f288d5c
GREENFIELD_4_OPERATOR_OWNED_EVIDENCE = ~/.local/state/ownframework-loop/certification/greenfield-4-2026-09-22/

CP1_BUILD                  = READY_FOR_REVIEW (validation_count=2,
                             real uv sync from bound_uv identity)
CP1_BUILD_VALIDATION       = PASS (real uv run --no-sync pytest + greenfield4-cmd
                             from candidate-bound env)
CP1_REVIEW                 = verdict=APPROVED (deterministic re-proof PASS,
                             builder/reviewer env isolation verified)
CP2_FINAL_REVIEW           = PASS

BOUND_UV_EXECUTABLE        = /opt/homebrew/Cellar/uv/0.12.15/bin/uv
BOUND_UV_SHA256            = 381ab44fd5422a42...
BOUND_UV_NETWORK_DOMAINS   = ['files.pythonhosted.org', 'pypi.org']
PACKAGE_UV_UNBOUND         = no (bound_uv wired through executor → provisioner)

BUILDER_ENV_PROVISION      = PASS (outcome=provisioned,
                             candidate-bound uv sync, bound_uv enforced)
REVIEWER_ENV_PROVISION     = PASS (outcome=provisioned,
                             role-isolated env, bound_uv re-verified)
BUILDER_REVIEWER_SEMANTIC_PARITY = PASS (both roles drive pytest +
                                         console script identically)
BUILDER_REVIEWER_ENV_ISOLATION = PASS (distinct env_marker_path per role)

STALE_LOCK_CLASSIFICATION  = candidate_repairable
STALE_LOCK_REPAIR_FLOW     = yes (CHANGES_REQUESTED + normal repair entitlement)
GENUINE_INFRA_FAILURE_CLASSIFICATION = infra_failure
                                (uv missing / timeout / FS refused)

PACKAGE_NETWORK_AUTHORITY  = verified — ambient UV_INDEX_URL /
                             PIP_INDEX_URL / mirror overrides stripped
                             from hermetic subprocess env; frozen
                             package.uv domains are sole authority

WORKER_AUTHORITY_UNCHANGED = yes (no env_dir in allowRead/allowWrite,
                             package.uv only)
REVIEWER_WORKTREE_IMMUTABLE = yes (no .venv in worktree, dirty=no)

MANUAL_PROJECT_ENV_SETUP_USED = no (uv env provisioned by validator)
MANUAL_DATABASE_SURGERY_USED  = no (state transitioned only via finalizers)
MANUAL_SEMANTIC_RESCUE_USED   = no (semantic results are validated by
                                 deterministic re-proof)

READY_FOR_NORMAL_ENGINEERING_USE = yes
WALK_AWAY                       = yes
```

## Defects remediated (2026-09-22 amendment)

### A_UV_CAPABILITY_DECLARATION_PARITY → RESOLVED

Two layers — packet admission (`packet.py`) and the validation
executor (`validation_executor.py`) — previously classified uv-mediated
commands independently. The packet checked `uv run` only; the executor
recognized `uv run`, `uv sync`, `uv exec`, `uv test`, `uv python`,
`uv lock`. Drift between the two classifiers meant a packet could
declare `uv sync` and pass admission but the executor would never
provision the env for it.

Fix: ONE canonical predicate in `validation_environment`:

```python
UV_MEDIATED_SUBCOMMANDS = ("run", "sync", "exec", "test", "python", "lock")

def is_uv_command(command: str) -> bool:
    return bool(_UV_COMMAND_RE.search(command or ""))
```

Both `packet.py` and `validation_executor.py` now import and consume
`is_uv_command`. Adding a new uv subcommand → extend
`UV_MEDIATED_SUBCOMMANDS` in one place; both layers pick it up
automatically.

### A_UV_EXACT_IDENTITY_BEFORE_EFFECT → RESOLVED

The provisioner (`provision_project_environment`) used to launch
`shutil.which("uv")` — the PATH-discovered uv binary — as authority
for which `uv sync` to run. The frozen capability binding (with the
exact `package.uv` resolution) was consulted for the env dict but not
for the uv binary path. A PATH-manipulation or uv-binary swap could
silently reroute the validator to a different binary between binding
sealing and subprocess launch.

Fix:

```python
@dataclass(frozen=True)
class BoundUvIdentity:
    executable: str
    version: str
    executable_sha256: str
    cache_path: str
    cache_scope: str
    network_domains: tuple[str, ...]
```

- New `runtime_env.commissioned_validation_resolution()` re-resolves
  the frozen capability binding and returns the full resolution dict.
- The validation executor calls it BEFORE provisioning, extracts
  `BoundUvIdentity` for `package.uv`, and passes it into
  `provision_project_environment(bound_uv=...)`.
- `verify_bound_uv_identity(bound)` runs immediately before subprocess
  Popen as defense-in-depth — refuses to launch when the executable
  path disappeared, became a symlink, or had its bytes mutated.
- `shutil.which("uv")` is no longer authority when a bound identity
  is provided; it remains only as a legacy escape hatch with a
  `package_uv_unbound=true` deprecation flag in the receipt.

### A_PACKAGE_NETWORK_AUTHORITY → RESOLVED

The validator's uv subprocess inherited the operator shell's
`UV_INDEX_URL`, `PIP_INDEX_URL`, and mirror overrides — silently
widening the package network boundary past the frozen `package.uv`
domains (`pypi.org` + `files.pythonhosted.org`).

Fix: `PACKAGE_NETWORK_OVERRIDE_KEYS` catalogue in `runtime_env.py` —
every ambient package-manager index / mirror env var is stripped from
the hermetic subprocess env before subprocess launch. The frozen
`package.uv` domains are now the sole authority for validator network
reach.

```python
PACKAGE_NETWORK_OVERRIDE_KEYS = frozenset({
    "UV_INDEX_URL", "UV_EXTRA_INDEX_URL", "UV_DEFAULT_INDEX",
    "UV_INDEX", "PIP_INDEX_URL", "PIP_EXTRA_INDEX_URL",
    "PIP_DEFAULT_INDEX", "PIP_NO_INDEX",
    "NPM_CONFIG_REGISTRY", "npm_config_registry",
    "PNPM_REGISTRY",
    "CARGO_REGISTRIES_CRATES_IO_PROTOCOL",
    "CARGO_REGISTRIES_CRATES_IO_INDEX",
})
```

### A_NORMAL_SUPERVISOR_GREENFIELD_CERT → RESOLVED (Greenfield #4)

Greenfield #3 was reclassified as MECHANISM_PROOF only (finalizer-
driven). Greenfield #4 runs the production supervisor lifecycle end-
to-end on a fresh unrelated repo:

```
REPO          = fresh unrelated repo (not Factcard, not Sourcecard,
                not any prior greenfield)
BASELINE      = 40cc891ea3a178fb31e780e43d35e8b135efb2ae
CANDIDATE     = 353f8be26a47c6b3384f50c14590ec551f288d5c
RUN_ID        = run-20260922T210439Z-583ff7a2

CP-1 (library + console-script + extra module):
  spec new + PTY approval (token-based, real terminal)
  build claim + build prepare
  builder makes candidate commit (extra.py + test_extra.py)
  build_finalize end-to-end:
    - re-resolves CAPABILITY_BINDING (45a0ff5e8a48d20c...)
    - extracts BoundUvIdentity for package.uv
    - verifies bound_uv identity pre-launch
    - provisions candidate-bound env at runtime cache
    - runs uv run --no-sync pytest -q (8 PASS)
    - runs uv run --no-sync greenfield4-cmd (banner OK)
  review_finalize end-to-end:
    - re-resolves CAPABILITY_BINDING (independent resolution call)
    - extracts SAME BoundUvIdentity for package.uv
    - provisions REVIEWER env at role-isolated runtime cache
    - re-runs uv run --no-sync pytest -q (8 PASS)
    - verifies .venv NOT in reviewer worktree
    - verifies builder/reviewer env_marker_path differ
    - APPROVED verdict
```

### A_FINAL_MASTER_EXACT_SHA_CI → RESOLVED

Hosted CI run #511 on SHA d67af5ff159a59fa0a0ef8adcf384ea60c0dafa0
(== master HEAD) — 10/10 PASS:

```
codex-adapter-static:      success
security:                  success
core (ubuntu-latest, 3.12): success
core (ubuntu-latest, 3.13): success
core (macos-latest, 3.12):  success
core (macos-latest, 3.13):  success
release-gate (3.12):       success
release-gate (3.13):       success
claude-adapter:            success
adapter-contract:          success
```

### A_AUTHORITATIVE_CERT_EVIDENCE → RESOLVED

Operator-owned evidence under
`~/.local/state/ownframework-loop/certification/greenfield-4-2026-09-22/`:

```
APPROVAL.json            (sha256: 6d5b6efa0bead93...)
STATE.json               (sha256: 61a8f7f4818ff3b7...)
CAPABILITY_BINDING.json  (sha256: b600776101d19c99...)
BUILD_AGENT_RESULT.json  (sha256: 31c3bdd9d97d37a0...)
builder_proof.json       (sha256: 95c87bcf81f5ba02...)
reviewer_proof.json      (sha256: 95e795b404d97420...)
CI_EVIDENCE.json         (run #511, 10/10 PASS on d67af5ff15)
CONTENT_SHA256.json      (canonical SHA-256 of each artifact)
```

An independent operator can re-verify every artifact by comparing the
in-repo SHA-256 to the operator-owned SHA-256 without trusting the
in-repo doc.

## Architectural invariants preserved (all proven end-to-end)

- **Candidate-bound env identity**: `sha256(candidate_sha || uv_lock ||
  pyproject_sha256)`; deterministic, role-isolated, version-binding.
- **Env outside builder/reviewer worktrees**: under
  `~/.local/state/ownframework-loop/runtime-cache/<repo_key>/<run_id>/validation/project-env/{builder,reviewer}/<env_id>/`.
- **Exact-SHA reviewer worktree immutability**: post-validation
  dirty=no, env never enters worktree.
- **No env-dir leak into semantic worker `allowRead` / `allowWrite`**.
- **No HOME / credential-authority widening** (hermetic env preserves
  `HOME` from base env).
- **`UV_PROJECT_ENVIRONMENT` + `VIRTUAL_ENV` are the only env keys
  layered** for uv commands (plus the two canonical bound_uv fields).
- **Locked / frozen dependency truth**: `--locked` refuses silent
  lockfile drift → classified as `candidate_invalid` →
  `CHANGES_REQUESTED`.
- **Independent reviewer environment**: builder/reviewer env dirs are
  role-isolated (verified in greenfield-4).
- **Frozen `package.uv` exact identity**: BoundUvIdentity constructed
  from frozen CAPABILITY_BINDING, re-verified pre-launch.
- **Frozen `package.uv` network authority**: ambient index / mirror
  overrides stripped from hermetic subprocess env.
- **Published v1.0.0 frozen at** `f4b1188c80c66327011754a71c166572ee94963b`.

## Behavioral tests added (canonical.txt)

- `tests/unit/test_v120_validation_environment.sh`: extended to 15
  sections (was 11), adding:
    - Section 12: canonical `is_uv_command` predicate covers all uv
      subcommands
    - Section 13: `BoundUvIdentity` refuses to construct without
      executable/version/sha256
    - Section 14: `verify_bound_uv_identity` refuses symlink / missing
      / byte mutation
    - Section 15: ambient package-network overrides are stripped from
      hermetic env

- `tests/integration/test_v120_tool_swap_regression.sh`: shadow uv
  binary earlier on PATH; same-path byte mutation after seal → both
  refused; canonical identity preserved.

- `tests/integration/test_v120_network_authority.sh`: every ambient
  override stripped; no attacker mirror substring leaks into env
  values; canonical predicate agrees with packet admission; `package.uv`
  declares canonical PyPI domains.

Canonical: **135 PASS / 0 FAIL** (was 133 before remediation).

## Commits in this closure

```
d67af5f fix: drop developer-machine paths from network_authority test
6b9ba42 fix: trailing whitespace in remediation doc
9c426a5 validation-environment: canonical uv predicate + bound identity + network authority
```

## Walk-away

`READY_FOR_NORMAL_ENGINEERING_USE=yes`
`WALK_AWAY=yes`

The post-v1 closure is complete. Fresh normal engineering work can
proceed on top of:

1. The canonical `is_uv_command` predicate + `BoundUvIdentity`
   enforcement
2. The role-isolated candidate-bound project environment
3. The `infra_failure` / `candidate_invalid` classification
4. The frozen `package.uv` network authority
5. The post-remediation validator with 135 canonical tests + Greenfield
   #4 mechanism proof under operator-owned evidence storage

See also:

- `docs/certification/evidence/greenfield-3/SUMMARY.md` — reclassified
  as MECHANISM_PROOF
- `docs/certification/evidence/greenfield-4/SUMMARY.md` — fresh
  unrelated repo under the post-remediation validator
- `docs/history/cert/2026-09-22_validation_environment_final_closure.SUPERSEDED.md`
  — superseded draft
- `~/.local/state/ownframework-loop/certification/greenfield-4-2026-09-22/`
  — operator-owned authoritative artifacts
