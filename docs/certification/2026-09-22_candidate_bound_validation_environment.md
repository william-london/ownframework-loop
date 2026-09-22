# OwnFramework Loop — Candidate-Bound Validation Environment Parity (2026-09-22)

**CANDIDATE_BOUND_VALIDATION_ENVIRONMENT_PARITY=PASS**

Bounded closure of the candidate-bound validation environment parity
seam. No architecture redesign. No new workflow engine / state machine
/ database. The deterministic validator gains one owner of the project
environment that `uv run` requires; every existing authority invariant
is preserved or tightened.

```
START_SHA                 = f6724aab5571ebf4dba4a2a0b392f44dd35b21d1
HEAD                      = <this commit>
SOURCE_VERSION            = 1.1.0.dev0
SOURCE_TREE               = <this commit's git rev-parse HEAD^{tree}>
LOCAL_ORIGIN_PARITY       = yes (LOCAL_HEAD == ORIGIN_MASTER after push)
SOURCE_WORKTREE_CLEAN     = yes

VALIDATION_ENVIRONMENT_AUTHORITY=CLOSED
CANDIDATE_BOUND_ENVIRONMENT=CLOSED
PROVISIONER_OUTSIDE_WORKTREE=CLOSED
PROVISIONER_IDEMPOTENT=CLOSED
INFRA_FAILURE_DISTINCT_FROM_VALIDATION_FAILED=CLOSED
INFRA_FAILURE_BURNS_NO_REPAIR_ROUND=CLOSED
UV_RUN_NO_SYNC_HONORS_PROVISIONER=CLOSED
WORKER_AUTHORITY_UNCHANGED=CLOSED
HOME_NEVER_REOPENED=CLOSED
REVIEWER_WORKTREE_IMMUTABLE=CLOSED

TARGETED_TESTS=test_v120_validation_environment=PASS (28 behavioral tests)
CANONICAL_TESTS=OF_LOOP_TOTAL=129 OF_LOOP_PASSED=129 OF_LOOP_FAILED=0
                OF_LOOP_RELEASE_GATE_RESULT=PASS
CANONICAL_VALIDATION=PASS
RELEASE_GATE=PASS
COMMITTED=yes
PUSHED=yes (canonical master, LOCAL_HEAD == ORIGIN_MASTER)
A_OPEN=0
B_OPEN=0

PUBLISHED_V1_0_0_SHA=f4b1188c80c66327011754a71c166572ee94963b
PUBLISHED_V1_0_0_MOVED=no (tag and install slot preserved)
READY_FOR_NORMAL_ENGINEERING_USE=yes (deterministic candidate)
WALK_AWAY=yes (next checkpoints are operator-driven: hosted
              exact-SHA CI 10/10, fresh unrelated Greenfield
              Certification #3)
```

## Seams closed in this pass

### A — VALIDATION ENVIRONMENT AUTHORITY

**A_VALIDATION_ENVIRONMENT_AUTHORITY** (deterministic validator owns
a candidate-bound project environment)

New `lib/ownframework_loop/validation_environment.py` is the sole
authority for the project environment that `uv run` (and any uv
subcommand that requires it) needs to execute candidate code. The
validator provisions the environment exactly once per
`(candidate_sha, uv_lock_sha256, pyproject_sha256)` identity into a
path that lives outside the builder and reviewer Git worktrees:

`<runtime_cache>/<repo_key>/<run_id>/validation/project-env/{builder,reviewer}/<env_id>/`

The provisioner runs

```
uv sync --project <candidate_worktree> \
         --python-preference only-system \
         --locked
```

so any registry drift fails closed against the candidate's lockfile
instead of silently mutating the worktree, and so the env is
reproducible across hosts.

### B — ENV IDENTITY & ISOLATION

**B_CANDIDATE_BOUND_ENVIRONMENT** (identity binds candidate SHA +
project metadata/lock identity)

`candidate_bound_environment_id()` derives a deterministic 64-hex id
from the candidate SHA, the lock file SHA-256 (or absent-marker), and
the pyproject.toml SHA-256. Two unrelated candidates never share an
env; the same candidate, lock, and metadata always produce the same
env id (idempotent re-validation).

**B_PROVISIONER_OUTSIDE_WORKTREE**

The env path is derived from the supervisor-owned runtime cache and
never from the worktree. `tests/unit/test_v120_validation_environment.sh`
§2 proves the env dir is NOT inside the builder worktree, the
reviewer worktree, the canonical `.worktrees/` parent, the canonical
`.ownframework-loop/` parent, or the canonical repo root. Builder
and reviewer env dirs are role-isolated so the reviewer's exact-SHA
worktree can never accidentally observe the builder's freshly-synced
env.

### C — FAILURE-ENVELOPE SEPARATION

**C_INFRA_FAILURE_DISTINCT_FROM_VALIDATION_FAILED** (infra failures
must not burn semantic repair rounds)

`validation_executor.run_required_validation()` distinguishes two
failure envelopes:

  - `validation_failed`: candidate code did not satisfy the
    packet-declared command. Burns a repair round; transition to
    `CHANGES_REQUESTED` so the next builder pass can fix it.
  - `infra_failure`: validator-owned infrastructure could not satisfy
    the run (uv missing, `uv sync` timeout, locked lockfile drift,
    missing executable path). Terminal `BLOCKED`; does NOT burn a
    repair round; does NOT transition to `CHANGES_REQUESTED`.

The separation is enforced by `build_finalize.py` and
`review_finalize.py` before any repair-round accounting runs:

```python
if infra_failure_count > 0:
    next_state = "BLOCKED"  # terminal, no repair round
```

A redacted `infra_failure` envelope block is recorded on both
`BUILD_RECEIPT.json` (`infra_failure.count`, `infra_failure.marker_path`,
`infra_failure.burns_repair_round=false`) and `REVIEW_VERDICT.json`
(the symmetric fields). Schemas updated.

### D — RUNNER PROVENANCE

**D_UV_RUN_NO_SYNC_HONORS_PROVISIONER**

The validation executor layers `UV_PROJECT_ENVIRONMENT=<env_dir>` and
`VIRTUAL_ENV=<env_dir>` into the hermetic subprocess env ONLY for
subprocesses whose command invokes `uv run` (or `uv sync`/`uv exec`/
`uv test`/`uv python`/`uv lock`). Non-uv commands receive the
standard hermetic env unchanged. `command_uses_uv_run` is exposed as
a public classifier for upstream callers; tests in
`test_v120_validation_environment.sh` §7 prove the classifier covers
every supported uv subcommand and never mis-classifies a non-uv
command.

`uv run --no-sync` therefore succeeds against the validator-owned env
exactly when (and only when) the validator has provisioned that
candidate env. The validator never relies on uv's auto-sync, so the
candidate worktree never gains an in-tree `.venv`.

### E — SECURITY INVARIANTS

**E_WORKER_AUTHORITY_UNCHANGED**

`test_v120_validation_environment.sh` §5 proves the candidate-bound
env dir is NEVER added to any worker's `allowRead` or `allowWrite`.
The env is validator-owned; the worker's Bash sandbox, filesystem
authority, and network authority are unchanged from the post-v1
closure baseline.

**E_HOME_NEVER_REOPENED**

`test_v120_validation_environment.sh` §6 proves the validator's
hermetic subprocess env preserves `HOME` from the base env. The
deterministic validator never reopens HOME for tool discovery
(preserving the post-v1 contract).

**E_REVIEWER_WORKTREE_IMMUTABLE**

The reviewer exact-SHA worktree never sees a `.venv/` (env lives
elsewhere) and never sees a candidate-bound env_dir in its `allowRead`
(proven by §2 and §5). Post-validation cleanliness checks remain
green; reviewer verdict binding is unchanged.

## Tests (real, behavioral, no hasattr/duck-typing)

### Targeted v120 suite (`tests/unit/test_v120_validation_environment.sh`)

28 behavioral tests across 11 sections:

- env identity binds (candidate SHA + uv.lock + pyproject.toml)
- env lives outside builder and reviewer worktrees (8 invariants)
- provisioning is idempotent (3 invariants)
- provisioning failure → infra_failure (5 invariants)
- env_dir is not in any worker's allowRead/allowWrite (2 invariants)
- validator never reopens HOME (1 invariant)
- command_uses_uv_run classifier (10 cases, 1 invariant)
- env_overrides exports documented keys (1 invariant)
- infra_failure marker is private (0600) and atomic (3 invariants)
- project_environment_status rejects tampered markers (1 invariant)
- project_environment_dir is pure (no I/O on derivation) (2 invariants)

### Canonical suite (`tests/run_all.sh`)

```
OF_LOOP_TOTAL=129
OF_LOOP_PASSED=129
OF_LOOP_FAILED=0
OF_LOOP_RELEASE_GATE_RESULT=PASS
```

### Canonical validation (`tests/integration/test_version_truth.sh`)

```
VERSION_TRUTH=PASS (source line = 1.1.0.dev0;
                   publication authority = immutable Git tag +
                   GitHub Release;
                   historical release = v0.9.1 @
                   d23cadca751c9ed37b5eeab25415c8b0574dae4e)
```

### Release gate

```
RELEASE_GATE=PASS
```

## Architecture invariants preserved

- worker public Bash network authority = none
- `allowedDomains = []`, `strictAllowlist = true`
- per-run evidence dir + supervisor-mediated research transport
- commissioned `research.public` capability (unchanged)
- supervisor-computed research request digest
- unified `_browse()` transport
- SSRF/special-use protections (RFC 6890 + IANA)
- content-addressed evidence/assets
- bounded executor (ThreadPoolExecutor)
- process-wide in-flight registry
- published v1.0.0 frozen at `f4b1188c80c66327011754a71c166572ee94963b`
- `CAPABILITY_ENV_ALLOWED_KEYS` (only 6 non-secret identity keys)
- HOME preservation through `hermetic_subprocess_env`

## Files changed

```
CHANGELOG.md                                                              (modified)
docs/architecture/HOST_CAPABILITIES.md                                    (modified)
lib/ownframework_loop/build_finalize.py                                   (modified)
lib/ownframework_loop/review_finalize.py                                  (modified)
lib/ownframework_loop/validation_environment.py                          (NEW)
lib/ownframework_loop/validation_executor.py                              (modified)
schemas/build-receipt.schema.json                                         (modified)
schemas/review-verdict.schema.json                                        (modified)
tests/canonical.txt                                                       (modified)
tests/unit/test_v120_validation_environment.sh                            (NEW)
```

## What was NOT done this pass

The directive describes a FULL closure sequence including hosted
exact-SHA CI 10/10, fresh unrelated Greenfield Certification #3, and
final install + commission. This pass closes the deterministic
implementation seams and proves the candidate with:

- all 129 canonical tests PASS (1 new test added: v120)
- 28 v120 behavioral tests PASS across 11 sections
- canonical validation PASS
- release gate PASS
- committed and pushed to `origin/master`
- LOCAL_HEAD == ORIGIN_MASTER

The follow-on steps in the directive (hosted CI on the exact
candidate SHA, fresh Greenfield #3, final install + re-commission)
require operator-driven external infrastructure and are explicitly out
of scope for this deterministic closure pass. They are walk-away
checkpoints for the operator, listed in the summary header above.
