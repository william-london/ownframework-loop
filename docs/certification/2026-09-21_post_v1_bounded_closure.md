# OwnFramework Loop — Post-V1 Bounded Closure (2026-09-21)

**POST_V1_BOUNDED_CLOSURE=PASS (deterministic bridge candidates closed)**

Bounded closure of the post-v1 implementation seams called out in
the directive. No architecture redesign. No new workflow engine /
state machine / database. No new search provider. The supervisor-
mediated `research.public` architecture is unchanged.

```
START_SHA          = 2c0cf749265a33baac57459716f590ab4ad5a380
FINAL_PUSHED_SHA   = 072fa53fefaa640516851f8bc1654ae9bd0609dd
FINAL_TREE         = 31bb3185a9daf6e6796dab624efc8ce178dc8dca
ORIGIN_MASTER_SHA  = 072fa53fefaa640516851f8bc1654ae9bd0609dd
LOCAL_ORIGIN_PARITY= yes (LOCAL_HEAD == ORIGIN_MASTER)
SOURCE_WORKTREE_CLEAN= yes

SOURCE_VERSION     = 1.1.0.dev0
INSTALL_ROOT       = ~/.local/share/ownframework-loop/1.1.0.dev0/
                     (post-v1 dev install — distinct from the
                      v1.0.0 install at ~/.local/share/ownframework-loop/1.0.0/)

RESEARCH_RATE_LIMIT=CLOSED
RESEARCH_CRASH_RECOVERY=CLOSED
RESEARCH_ASYNC_RESULT_OWNERSHIP=CLOSED
RESEARCH_REPLAY_EVIDENCE_INTEGRITY=CLOSED
STALE_DDG_POLICY=CLOSED (only wikipedia accepted; ddg-lite fail-closed)

WATCHDOG_FAILURE_BUDGET_OWNERSHIP=CLOSED
WATCHDOG_COST_ACCOUNTING_OWNERSHIP=CLOSED

GENERIC_PUBLIC_URL_READ=SUPPORTED
SEARCH_DISCOVERY_BACKEND=wikipedia
GENERAL_WEB_DISCOVERY=DEFERRED

TARGETED_TESTS=v200_research_authority=PASS (33 §12 behavioral tests)
              +v100_progress_watchdog=PASS (watchdog ownership)
CANONICAL_TESTS=OF_LOOP_TOTAL=126 OF_LOOP_PASSED=126 OF_LOOP_FAILED=0
                OF_LOOP_RELEASE_GATE_RESULT=PASS
CANONICAL_VALIDATION=PASS (version-truth gate green;
                  v0.9.1 historical reference preserved)
RELEASE_GATE=PASS

COMMITTED=yes
PUSHED=yes

A_OPEN=0
B_OPEN=0

PUBLISHED_V1_0_0_SHA=f4b1188c80c66327011754a71c166572ee94963b
PUBLISHED_V1_0_0_MOVED=no (tag and install slot preserved)

SOURCE_CHECKOUT_BROKER_IN_PRODUCTION=no
                        (commissioning is currently resealed against
                         source repo broker as a development-time
                         proof; final production commissioning MUST
                         reseal against the installed immutable
                         payload after the canonical install run)

READY_FOR_NORMAL_ENGINEERING_USE=yes (deterministic candidate)
WALK_AWAY=yes (next checkpoints are operator-driven:
              hosted exact-SHA CI, then fresh bounded PROGRAM,
              then final install + commission)
```

## Seams closed in this pass

### A — RESEARCH

**A_RESEARCH_RATE_LIMIT** (durable accepted-launch accounting)

Completed launches no longer disappear from the trailing-rate
window. New `launches/launch-<UUID>.json` directory under
`<evidence_root>/<run-id>/launches/` is the durable counter;
records persist for the full 60-second window regardless of
success/failure/timeout. `_accepted_count_last_60s()` reads
launches/, not claim markers. Bounded cleanup at end of each tick
removes only records older than the trailing window. Verified:
N requests to completion → counter == N; restart durability;
boundary refusal at LIMIT.

**A_RESEARCH_CRASH_RECOVERY** (production-generated claim recovery)

Claim marker now persists op, url, query, max_bytes,
search_backend, attempt_id, role, run_id, request_id,
request_digest, accepted-launch timestamp. `recover_claims()`
performs truthful recovery:
- matching receipt → reconstruct response, zero second network
  call;
- read/asset-read orphan → re-admit through trusted transport
  (submits to bounded executor, fresh launches/ record,
  preserves original claim marker);
- search orphan → RecoveryOutcomeUnknown response, no blind
  second provider call.

**A_RESEARCH_ASYNC_RESULT_OWNERSHIP** (single canonical finalize)

`_finalize_completed_entries(entries)` is the ONLY path that
publishes a response / removes a claim / releases an executor
slot for an in-flight entry. Per-entry `finalized` sentinel
prevents double-publish / double-release across tick
boundaries. A future from tick N that completes during tick N+1
is reaped by the canonical path on the later tick.

**A_RESEARCH_REPLAY_EVIDENCE_INTEGRITY** (immutable authoritative responses)

`_publish_response()` NEVER unlinks an existing authoritative
response. Mismatch dispositions go to a separate
`.conflict-<UUID>-<digest8>.json` marker. Legacy responses
missing `request_digest` are refused (identity unknown), never
silently treated as matches. SHA-before/SHA-after assertion
proves original response bytes are preserved across mismatched
replay attempts.

**A_STALE_DDG_POLICY**

`ddg-lite` search backend REMOVED. `OFLOOP_RESEARCH_DEFAULT_SEARCH_BACKEND`
is fail-closed: only `wikipedia` is accepted. Unknown / stale
backend values produce `SearchBackendRefused` BEFORE broker
launch.

### A — WATCHDOG

**A_WATCHDOG_FAILURE_BUDGET_OWNERSHIP**

Watchdog no longer increments `transient_failures` directly.
That was double-charged by the recovery path. The watchdog
increments its own dedicated counter `progress_stall_count`.
Recovery has an explicit `progress_stalled` branch that derives
the operational backoff without consuming another budget.
One stall = one budget counter increment.

**A_WATCHDOG_COST_ACCOUNTING_OWNERSHIP**

Watchdog no longer seals `cost_accounted=1` on the attempt. The
canonical accounting owner (`_account_attempt_cost`) can still
attach real cost/tokens from the provider envelope via its
`already` fence. Truly unknown cost remains honest (`cost_known=0`,
`cost_accounted=0`). No funded-ceiling bypass — if a cost ceiling
is active and the attempt finishes with `cost_known=0`, the
existing `usage_unknown` quarantine logic kicks in.

### Documentation & versioning

**Source version line moved to `1.1.0.dev0`**

- `lib/ownframework_loop/__init__.py` — `__version__ = "1.1.0.dev0"`
- `.claude-plugin/plugin.json` — `"version": "1.1.0.dev0"`
- `.claude-plugin/marketplace.json` — `"version": "1.1.0.dev0"`
- `README.md` — Source/master release line
- `SECURITY.md` — source/master supported line
- `CHANGELOG.md` — new entry added; historical v1.0.0 section preserved

Published v1.0.0 tag at `f4b1188c80c66327011754a71c166572ee94963b`
remains FROZEN. Historical v1.0.0 references in CHANGELOG and
certification docs are unchanged.

## Tests (real, behavioral, no hasattr/duck-typing)

### Targeted v200 suite (tests/unit/test_v200_research_authority.sh §12)

33 behavioral tests, all PASS. Includes:

- durable rate-limit: N requests to completion → counter == N
  after completion; claims removed; responses published
- rate limit at boundary: LIMIT broker calls; (LIMIT+1)-th refused
  with `RateLimited`
- rate limit survives restart: counter unchanged across simulated
  supervisor restart
- replay same digest: canonical response preserved
- replay different digest: canonical response IMMUTABLE;
  conflict marker published; SHA-before == SHA-after
- missing digest: refused with `ReplayDigestMismatch`
- symlinked inbox: refused without dispatch
- conflict marker records new digest + disposition

### Targeted watchdog suite (tests/unit/test_v100_progress_watchdog.sh)

- watchdog stall detected → `progress_stalled` classification
- watchdog increments `progress_stall_count` (its dedicated counter)
- watchdog does NOT increment `transient_failures` directly
  (single-budget ownership)
- canonical recovery path also does NOT double-charge for
  `progress_stalled`

### Canonical suite (tests/run_all.sh)

```
OF_LOOP_TOTAL=126
OF_LOOP_PASSED=126
OF_LOOP_FAILED=0
OF_LOOP_RELEASE_GATE_RESULT=PASS
```

### Canonical validation (tests/integration/test_version_truth.sh)

```
VERSION_TRUTH=PASS (source line = 1.1.0.dev0;
                   publication authority = immutable Git tag +
                   GitHub Release;
                   historical release = v0.9.1 @
                   d23cadca751c9ed37b5eeab25415c8b0574dae4e)
```

### Live bridge smoke

Real helper-style REQUEST → supervisor tick → real broker
subprocess → real public read (https://example.com/) → 
operator-owned RESPONSE file published → receipt persisted →
claim removed. Two overlapping operations (one slow due to
real network latency; one fast). Both received responses
(one broker success, one throttle/error — both recorded);
launches/ records both; claims both finalized; in-flight
registry returns to zero; executor in-flight returns to zero.
Worker authority invariants intact:
- worker Bash `allowedDomains = []`
- `strictAllowlist = true`
- worker cannot write responses/claims

## Architecture invariants preserved

- worker public Bash network authority = none
- `allowedDomains = []`, `strictAllowlist = true`
- `ofloop-research-call` as semantic research surface
- supervisor-mediated public transport
- commissioned research broker (`research.public`)
- per-run worker request inbox (worker-writable)
- operator-owned `claims/`, `responses/`, `receipts/`,
  `artifacts/`, `launches/`
- canonical commissioning verification
- immediate pre-launch broker SHA verification
- supervisor-computed research request digest
- unified `_browse()` transport
- SSRF/special-use protections (RFC 6890 + IANA)
- content-addressed evidence/assets
- bounded executor (ThreadPoolExecutor)
- process-wide in-flight registry
- published v1.0.0 frozen at `f4b1188c80c66327011754a71c166572ee94963b`

## What was NOT done this pass

The directive describes a FULL closure sequence including hosted
exact-SHA CI, fresh bounded PROGRAM certification, and final
install + commission. This pass closes the deterministic
implementation seams and proves the candidate with:

- all 126 canonical tests PASS
- 33 v200 behavioral tests PASS (including the rate-limit
  durability / boundary / restart suite and the replay
  immutability suite)
- live bridge smoke PASS (real broker subprocess, real public
  read, real finalization)
- canonical validation PASS
- release gate PASS
- committed and pushed to `origin/master`
- LOCAL_HEAD == ORIGIN_MASTER

The follow-on steps in the directive (hosted CI on the exact
candidate SHA, fresh bounded PROGRAM cert, final install +
re-commission against installed payload) require operator-
driven external infrastructure and are explicitly out of
scope for this deterministic closure pass.

When the operator is ready:

1. **Hosted exact-SHA CI**: trigger against
   `072fa53fefaa640516851f8bc1654ae9bd0609dd`. Require 10/10
   matrix PASS. Any subsequent change to this SHA invalidates
   the CI result.
2. **Fresh bounded PROGRAM cert**: run a canary through normal
   production path; require `PROGRAM_FINAL=APPROVED/DONE` with
   real governed research operations, real builder, real
   reviewer, dynamic public URL read, Wikipedia search as the
   commissioned discovery backend.
3. **Final install + commission**: install this exact master
   through the canonical installer (`./bin/install`); the
   payload lands under `~/.local/share/ownframework-loop/1.1.0.dev0/`
   (the post-v1 install slot — distinct from the v1.0.0
   install). Re-commission `research.public` against the
   INSTALLED broker. Verify installed broker SHA matches
   `ab8291bbfe980157f0e16bcb087bc6af6d397ee7f1f957c123f6093213ac5b00`
   (the current source repo broker — but the installed copy's
   SHA must be re-verified). Verify installed
   `runtime_generation` matches the exact candidate. Zero
   active/stale jobs. Zero orphan providers. Zero stale
   research claims.
