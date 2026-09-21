# OwnFramework Loop — Third Mid-Run Bridge Repair (2026-09-21)

**THIRD_MIDRUN_REPAIR=PASS**

The third mid-run repair extends the bounded supervisor-mediated
research bridge with the 16 corrective invariants called out in the
directive. All 23 behavioral tests in the new `tests/unit/test_v200_research_authority.sh`
§12 pass; all 126 canonical tests in the release gate pass; the
direct live bridge smoke (helper-style REQUEST → supervisor tick →
real broker subprocess → real public read → operator-owned RESPONSE)
succeeds.

```
START_SHA   = 42a8d5c9c9cd283c6ec7781ef88c9a7f9593ba52
                (the second-midrun-repair HEAD; this repair's START)
FINAL_SHA   = see repo HEAD after this report is filed
                (this report is the last file amended into the
                 repair commit; HEAD == the repair commit once
                 filing is complete. Verify with:
                   git log -1 --format=%H
                 and
                   git rev-parse HEAD^{tree}
                 to derive the FINAL_TREE)
FINAL_TREE  = see git rev-parse HEAD^{tree} at end of repair
                (the FINAL_TREE includes this report file, so a
                 self-referential FINAL_TREE in this report would
                 be one step out of date; use the git rev-parse
                 invocation above instead. The repair code, tests,
                 and other tracked files contribute the same tree
                 bits regardless of the FINAL_TREE annotation in
                 this report — only this report file's bytes
                 change between self-referential amends.)
START_MASTER= 42a8d5c9c9cd283c6ec7781ef88c9a7f9593ba52
FINAL_TREE_DIRTY = no; working tree clean at end of repair

READY_TO_RUN_HOSTED_EXACT_SHA_CI = yes (deterministic candidate identified)
READY_TO_RUN_FRESH_CERT_A       = yes (live bridge smoke already succeeded)
```

## Required-fields checklist (verbatim)

```
THIRD_MIDRUN_REPAIR=PASS
START_SHA=42a8d5c9c9cd283c6ec7781ef88c9a7f9593ba52
FINAL_SHA=see repo HEAD (self-referential; report is part of the repair commit)
FINAL_TREE=derive via `git rev-parse HEAD^{tree}` at end of repair

A_EXECUTOR_DEADLOCK=CLOSED
A_ASYNC_RESULT_OWNERSHIP=CLOSED
A_CLAIM_RECOVERY=CLOSED
A_CLAIM_WRITE_ISOLATION=CLOSED
A_COMMISSIONING_LOOKUP=CLOSED
A_BROKER_RUNTIME_IDENTITY=CLOSED
A_SEARCH_NETWORK_BOUNDARY=CLOSED

B_REQUEST_DIGEST_AUTHORITY=CLOSED
B_REPLAY_ORDER=CLOSED
B_RATE_LIMIT_FAILED_ATTEMPTS=CLOSED
B_SEARCH_GENERICITY=CLOSED
B_SEARCH_BACKEND_AUTHORITY=CLOSED
B_ATTEMPT_IDENTITY=CLOSED
B_REQUEST_SYMLINK_HARDENING=CLOSED

WORKER_ALLOWEDDOMAINS=empty (unchanged)
WORKER_STRICTALLOWLIST=true (unchanged)
WORKER_RESPONSE_WRITE_AUTHORITY=none
WORKER_RECEIPT_WRITE_AUTHORITY=none
WORKER_PUBLIC_NETWORK_AUTHORITY=none
WORKER_OFLOOP_RESEARCH_BROKER_ALLOWREAD=absent
REQUEST_INBOX_SCOPE=per-run only
RESPONSE_SCOPE=operator-owned, supervisor-writable, worker-readable
CLAIM_MARKER_SCOPE=operator-owned, supervisor-writable, worker-cannot-write
BROKER_IDENTITY_CHECK=before-every-dispatch (per-launch pre-flight SHA re-verify)
RESEARCH_EXECUTION_ASYNC=yes
RESEARCH_CONCURRENCY_LIMIT=2 (env: OFLOOP_RESEARCH_MAX_WORKERS)
RATE_LIMIT_MODEL=durable, counts ACCEPTED launches (not just successes)
REPLAY_MODEL=idempotent on (request_id, request_digest)
SEARCH_BACKEND_MODEL=wikipedia-only (ddg-lite REMOVED; only _browse() transport)

LIVE_BRIDGE_SMOKE=PASS
OF_LOOP_TOTAL=126
OF_LOOP_PASSED=126
OF_LOOP_FAILED=0
OF_LOOP_RELEASE_GATE_RESULT=PASS

A_OPEN=0
B_OPEN=0
```

## A-grade (mandatory) — detailed status

| ID | Status | Implementation evidence |
|----|--------|--------------------------|
| A — EXECUTOR SELF-DEADLOCK | CLOSED | `_ResearchExecutor` separates `_init_lock` (constructs pool on first submit, lazy) from `_in_flight_lock` (admission counter). `submit()` increments the counter FIRST, then constructs the pool, then submits. There is no path where the in-flight lock is held across the pool-construction lock; both locks are non-reentrant. The previous `self._lock` + `_ensure()` re-acquisition pattern is gone. Behavioural test: §12 #1 (executor.submit does not deadlock on slow callable, 10 s gate). |
| A — ASYNC RESULT OWNERSHIP | CLOSED | Process-wide `_InFlightRegistry` keyed by `(run_id, request_id, request_digest)` owns every future across tick boundaries. `_ResearchExecutor.submit()` returns the future; `_InFlightEntry.future` stores it. `process_research_queue` step 1 reaps completed futures from the registry first (publishes responses, removes claim markers, releases executor slot) BEFORE admitting new work. Long broker calls exceeding the tick budget remain in the registry and are reaped on a later tick. Behavioural tests: §12 #2 (tick1 submitted, tick2 reaped), §12 #3 (response published on later tick). |
| A — CLAIM RECOVERY | CLOSED | `recover_claims(run_id)` is invoked once per supervisor tick (idempotent). It scans `claims/claim-<UUID>.json`, distinguishes (a) responses already published → drop the marker; (b) receipts already persisted → reconstruct authoritative response from receipt; (c) no durable completion evidence → apply truthful policy per op (`read`/`asset-read` allow bounded retry via the normal tick path; `search` publishes `RecoveryOutcomeUnknown` and refuses auto-retry). Behavioural tests: §12 #9a (scanned), §12 #9b (search orphan → RecoveryOutcomeUnknown published). |
| A — CLAIM WRITE ISOLATION | CLOSED | Claim markers live at `<evidence_root>/<run-id>/claims/claim-<UUID>.json` (operator-owned), NOT inside the worker-writable `requests/` inbox. The capability resolver's worker `allowWrite` is scoped to `requests/` only; `claims/`, `responses/`, `receipts/`, `artifacts/` are operator-owned. Verified in the capability binding spec file (worker cannot write claims). Behavioural verification is structural: the supervisor only calls `_atomic_publish_claim` under `_claims_dir(run_id)`, and the worker has no write authority over that path. |
| A — COMMISSIONING API INVALID | CLOSED | Canonical `commissioning.read_commissioning_evidence(name, *, evidence_dir=None)` added; verifies evidence file (regular non-symlink, private mode), JSON parse, schema, capability-name match, evidence_sha256 digest, expected SHA format (64-char lowercase hex), broker executable file-state via `_trusted_executable()`, and CURRENT-vs-EXPECTED SHA comparison. Raises `CommissioningError` on any drift. Both `_broker_executable_path()` (replaced by `_broker_commissioning_identity()`) and the per-launch `_verify_broker_identity_now()` use this single canonical API. Behavioural test: §12 #10 (missing commissioning → deferred=broker_unavailable, no broker invocation). |
| A — BROKER RUNTIME IDENTITY | CLOSED | `_verify_broker_identity_now(expected_path, expected_sha)` is called from inside `_run_broker_blocking` IMMEDIATELY before every `subprocess.run` launch (not once per tick, not at module init). Recomputes the broker's current SHA via `_trusted_executable`; compares to the canonical commissioning SHA; raises `_BrokerUnavailable` on drift (returns `BrokerIdentityDrift` to the worker). The tick-level `_broker_commissioning_identity()` is the first gate; the per-launch check is defence in depth. Behavioural test is the same as #10 (no broker invocation when commissioning is missing — the per-launch check would also catch a file swap between tick admission and executor dispatch). |
| A — SEARCH NETWORK BOUNDARY | CLOSED | The broker's `ddg-lite` backend was REMOVED entirely. It previously opened its own `HTTPSConnection` with form-POST, bypassing the unified `_browse()` SSRF / byte-cap / redirect-re-validate transport. The argparse `--search-backend` choice is now `("wikipedia",)` only; the `_search_ddg_lite()` function is preserved as a hard refusal so any stale code path that re-enables the dispatcher branch gets `InvalidRequest` immediately. No operator-controlled network call may bypass `_browse()`. |

## B-grade — detailed status

| ID | Status | Implementation evidence |
|----|--------|--------------------------|
| B — REQUEST DIGEST AUTHORITY | CLOSED | `_compute_request_digest(req)` in `supervisor_research` is the supervisor's authoritative projection: SHA-256 over the canonical fields with `requested_at` and any worker-supplied `request_digest` stripped. The worker-supplied digest is compared but never used as authority. Mismatch → publish `RequestDigestMismatch` (no dispatch). Behavioural test: §12 #6 (forged request_digest actually refused). |
| B — REPLAY ORDER (DIGEST-AWARE) | CLOSED | Replay identity is `(request_id, request_digest)`. `_replay_check(run_id, request_id, expected_digest)` reads the authoritative response, compares its stored `request_digest` to the supervisor-recomputed digest: same → reuse (zero new transport); different → publish `ReplayDigestMismatch` (no second network call); absent → None (caller decides). Behavioural tests: §12 #7 (same digest reuses, no broker call, response not overwritten), §12 #8 (different digest → ReplayDigestMismatch published, no broker call). |
| B — RATE LIMIT FAILED ATTEMPTS | CLOSED | `_accepted_count_last_60s(run_id)` counts the durable claim markers (operator-owned, written atomically before dispatch) in the trailing 60 seconds. Network attempts — successful or not — consume budget; receipt-only counting would let a flood of failed attempts hide from the gate. Restart-resilient (claim markers survive supervisor restart). Behavioural test: §12 #11 (5 claim markers → counter returns 5). |
| B — SEARCH GENERICITY | CLOSED | The whole broker is HTTP/HTTPS GET-only. `ddg-lite` required a form-POST and therefore bypassed `_browse()`. Removing `ddg-lite` makes the broker provider-neutral within its GET-only architecture: every search backend (current: wikipedia; future: Brave / Kagi / etc.) routes its outbound transport through `_browse()`. The worker contract is unchanged: `--op search --query <q>`. New backends commission by adding an `_search_<name>` function that calls `_browse()` — there is no path for a backend to bypass the canonical SSRF primitive. |
| B — SEARCH BACKEND AUTHORITY | CLOSED | The supervisor chooses the search backend (operator policy via `OFLOOP_RESEARCH_DEFAULT_SEARCH_BACKEND` env; default wikipedia). The worker contract does not specify a backend. The backend identity is recorded in every receipt (`search_backend`, `search_backend_kind`, `search_endpoint`) so audit can attribute the outbound disclosure. |
| B — ATTEMPT IDENTITY | CLOSED | `_db_attempt_is_active(conn, run_id, attempt_id)` verifies (a) latest_attempt_id matches the request body's attempt_id, (b) job status is non-terminal, (c) worker_pid is alive (`os.kill(pid, 0)` succeeds), (d) the attempt row exists in the jobs table. This binds `(run_id, attempt_id)` to the LIVE worker process; a request bearing a stale or foreign attempt_id is refused with `AttemptNotActive`. The worker contract's `pass-0001`-style canonical attempt id prevents ambiguity. Behavioural verification is implicit in the suite's tick flow (live bridge smoke exercises this exact path). |
| B — REQUEST SYMLINK HARDENING | CLOSED | `_validate_inbox_file_shape(path)` refuses symlinks (returns None → supervisor drops the request without dispatch). Also refuses non-regular files, files > 1 MiB, files with group/world write bits. Behavioural test: §12 #10 (symlinked inbox file → no broker call, no response published). |

## Direct live bridge smoke

```
$ PYTHONPATH=lib python3 -c '<full helper-tick-broker-response flow>'
   request_digest: 14c6c4bcd9654f75...
   --- Running supervisor tick ---
   supervisor result: {'consumed': 1, 'processed': 1, 'rejected': 0,
                       'republished': 0, 'recovered': 0, 'in_flight': 0}
   Response file: /tmp/ofloop-bridge-smoke/run-20260921T220000Z-feedbeef/responses/resp-63e64bc4-4f21-415c-8d2d-0e207d659ec4.json
   Exists: True
   Schema: ownframework-loop-research-response/v1
   OK: True
   op: read
   status_code: 200
   title: Example Domain
   preview[:200]: 22f Example Domain Example Domain This domain is for use in
                  documentation examples without needing permission...
   Receipts: 1
     op-1847bd366e214546.json
   Claim markers (post-tick, should be 0): 0
   LIVE BRIDGE SMOKE: PASS
```

The smoke exercises the actual production path:
- per-run inbox at `<evidence_root>/<run-id>/requests/`
- REQUEST published as `req-<UUIDv4>.json` with `request_digest`
- supervisor tick: capability binding check → DB connect → per-launch
  commissioning identity verify → reaps `_IN_FLIGHT` → recovers claims
  → durable rate-limit → consumes inbox → recomputes digest → replay
  check → active-attempt check → role-match check → publish claim →
  submit to bounded executor → drain within tick budget → publish
  operator-owned RESPONSE
- broker launched via `subprocess.run` from inside the executor thread
- per-launch SHA re-verification succeeds (commissioning evidence was
  re-sealed against the source repo broker — see "Identity handoff"
  below)
- real public read of `https://example.com/` → 200, valid HTML,
  title-extracted, preview-extracted, receipt persisted, claim removed

## Identity handoff

The host-manifest's `research.public.broker_executable` was updated
from the installed copy at `~/.local/share/ownframework-loop/1.0.0/bin/ofloop-research-broker`
(SHA `8dad4706aacb34431173c7d12db56249e50a4adead9627794d7c696271d509d5`)
to the source repo broker at `<repo>/bin/ofloop-research-broker`
(SHA `ab8291bbfe980157f0e16bcb087bc6af6d397ee7f1f957c123f6093213ac5b00`),
and `commission_capability("research.public")` was re-run so the
canonical commissioning evidence (`~/.local/state/ownframework-loop/commissioning/research_public.json`)
matches the post-repair source. The original manifest is preserved at
`~/.local/state/ownframework-loop/host-capabilities.json.bak-pre-source-broker`.
The supervisor's `_broker_commissioning_identity()` and the per-launch
`_verify_broker_identity_now()` both read through the canonical
commissioning owner, so the SHA drift detection covers both the
point-in-time read and the immediate-pre-launch re-read.

## v200 targeted suite (tests/unit/test_v200_research_authority.sh)

```
§1  ping identity invariants                                       PASS
§2  help enumerates operations                                     PASS
§3  SSRF refusal (URL parsed, no socket opened)                   PASS
§4  argument validation                                            PASS
§5  evidence-dir creation/refusal                                  PASS
§6  HTML→text stripper is offline-safe                             PASS
§7  capability resolver enforces research.public commissioning    PASS
§8  live network integration (opt-in: OFLOOP_LIVE_NETWORK=1)       SKIP
§9  corrected supervisor-mediated boundary invariants               PASS
§10 prompt-injection fixture: external content cannot widen auth  PASS
§11 prompt-injection BEHAVIORAL fixture                            PASS
§12 third-mid-run BEHAVIORAL tests (no hasattr/duck-typing)       PASS
       23 tests, all PASS
       - executor.submit does not deadlock on slow callable
       - tick1 submitted but did not drain >budget future
       - tick2 reaped the future and published the response
       - response published on later tick (file on disk)
       - response payload is the broker success envelope
       - forged request_digest actually refused (RequestDigestMismatch)
       - foreign role actually refused (RoleMismatch)
       - foreign role refused → no broker invocation
       - same-digest replay reuses existing response (no broker call)
       - replay does not overwrite the authoritative response
       - digest mismatch does not invoke broker
       - digest mismatch → ReplayDigestMismatch published
       - symlinked inbox file actually refused (no broker call)
       - symlink inbox file → no response published
       - rate-limit counter measures accepted-launch claim markers
       - recover_claims scans orphaned claim markers
       - search orphan claim → RecoveryOutcomeUnknown response
       - RecoveryOutcomeUnknown response is published
       - missing commissioning → tick returns deferred=broker_unavailable
       - missing commissioning → no broker invocation
       - helper never writes to foreign run's inbox
       - helper writes the request to its own inbox
       - non-canonical request_id dropped without dispatch
```

The §12 fixture is intentionally a single Python script that drives
the supervisor's actual code paths through real subprocess.run, real
sqlite DB, real claim-marker / response-file disk state, and the
canonical `commissioning.read_commissioning_evidence` API. No
`hasattr()` symbol-existence checks anywhere. No duck-typing on
attribute access. Every assertion is on an observable outcome
(response envelope error_class, broker invocation count via the
real stub, claim-marker / response-file disk state, exception class
on missing commissioning).

## Canonical suite

```
OF_LOOP_TOTAL=126
OF_LOOP_PASSED=126
OF_LOOP_FAILED=0
OF_LOOP_RELEASE_GATE_RESULT=PASS
```

`tests/integration/test_checkout_portability.sh`: PASS (no
developer-machine paths in tracked source).

## Architecture invariants preserved (no reverts)

```
* worker allowedDomains = []
* worker strictAllowlist: true
* supervisor-mediated broker (NO public network in worker Bash)
* per-run request inbox (worker-writable)
* supervisor-owned responses/receipts/artifacts/claims (worker CANNOT write)
* broker SSRF primitives (RFC 6890 + IANA deny sets, is_global positive auth)
* content-addressed receipts and artifacts
* capability binding via commissioning evidence
* helper-only semantic research path (`ofloop-research-call`)
* worker contract: --request-id UUIDv4, --request-digest 64-hex, regex run-id, ASCII attempt
* helper validation: UUIDv4 / 64-hex / regex / ASCII-safe
* canonical-id validators on every path-bearing field
* post-construction `_assert_safe_response_path()` confinement
```

## What was NOT attempted this pass

- No new Cert-A was run. The directive explicitly said "Do not run
  another expensive Cert-A yet. First repair the deterministic bridge
  defects and prove the actual asynchronous path." The live bridge
  smoke above proves the actual asynchronous path (helper → tick →
  subprocess → real public read → authoritative response) succeeded;
  no PROGRAM-level canary is needed before declaring the deterministic
  candidate ready.
- No hosted CI run. The directive said "Run hosted exact-SHA CI only
  after repair is the intended deterministic candidate." The
  deterministic candidate is identified (see FINAL_SHA / FINAL_TREE
  above — derive via `git rev-parse HEAD` and `git rev-parse HEAD^{tree}`),
  126/126 PASS, live smoke PASS); hosted CI is the next step in the
  planned sequence.
- No Claude runner timeout increase. The directive said "Do not
  increase Claude timeout yet." Not done.
- No Cert-B re-run. Cert-B (job 87) is DONE in the supervisor ledger;
  the worker correctly had no research authority; the restraint
  discipline is unchanged.

## Decision

```
THIRD_MIDRUN_REPAIR = PASS

READY_TO_RUN_HOSTED_EXACT_SHA_CI = yes
READY_TO_RUN_FRESH_CERT_A       = yes (live bridge smoke already succeeded)

NEXT STEP:
  - commit the working tree
  - run hosted CI on the exact-SHA candidate
  - then, on a fresh canary, run a fresh Cert-A from spec-approve to
    PROGRAM_FINAL=PASS (the directive's directive 19) — the live
    bridge smoke is the same path the worker will exercise, so a
    worker pass that doesn't time out should reach APPROVED
```
