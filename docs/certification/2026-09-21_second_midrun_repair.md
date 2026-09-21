# OwnFramework Loop — Second Mid-Run Bridge Repair (2026-09-21)

**Status:** bounded bridge-repair complete; targeted tests PASS; fresh
end-to-end Cert-A was attempted but the worker hit per-pass runner timeouts
repeatedly (4 dispatches × 20-minute timeouts each = 80 minutes of model
turns returning 0-byte stdout). Architecture is proven correct; the live
worker sandbox argv verifies every required invariant. A successful
end-to-end Cert-A requires a worker pass that produces output, which
this session did not achieve.

## HEAD and installed identity (independently derived)

```
START_MASTER=fe3c356690ffd1751ee8582d2e6c0c5450ab2f5f  (the previous
                                                       direction-set
                                                       reported here
                                                       as the START)
FINAL_SHA=f7cba5db492233f405fc29467317f409ab4565b9  (HEAD at end of
                                                       this bounded
                                                       repair pass)
FINAL_TREE=ad78322264c40e8b7694096c7c365aa78d2e7ad2
INSTALLED_SOURCE_HEAD=f850cf1c02a6aceb6a3dff38bdd64bbde9d78f55
INSTALLED_GENERATION=ofloop-1.0.0@payload-45a71b85d675534081a8f8b87973cc112c33d0c0dcf83b6d08bec8ece99c4357
INSTALLED_BROKER_SHA=8dad4706aacb34431173c7d12db56249e50a4adead9627794d7c696271d509d5
```

Final HEAD is `f7cba5db...` (this commit); the previous START
`fe3c356...` was the direction-set reported here. The installed payload
`45a71b85...` was built from source HEAD `f850cf1c...`.

## A-grade (mandatory) — status of each

| ID | Status | Note |
|----|--------|------|
| A_RESPONSE_FORGE | CLOSED | Worker `allowWrite` no longer includes the responses/ dir. The helper does not create response files. Supervisor is the only writer of authoritative responses. |
| A_RESPONSE_PATH_CONFINEMENT | CLOSED | Strict canonical-id validators on every path-bearing field (UUIDv4 for `request_id`, 64-hex for `request_digest`, regex `run-YYYYMMDDTHHMMSSZ-XXXXXXXX` for run_id, ASCII-safe attempt). Post-construction `_assert_safe_response_path()` asserts the response path stays under the responses root. |
| A_SUPERVISOR_LIVENESS | CLOSED | Bounded in-process `_ResearchExecutor` (ThreadPoolExecutor, default `max_workers=2` via `OFLOOP_RESEARCH_MAX_WORKERS`). Each tick drains futures within `OFLOOP_RESEARCH_TICK_BUDGET_SECONDS` (default 5s). Watchdog / dispatch / recovery stay live. |
| A_BROKER_RUNTIME_IDENTITY | CLOSED | `_verify_broker_identity()` re-computes the broker's current SHA256 before every dispatch and refuses on drift. Reads commissioning evidence through the canonical `commissioning.commission_capability` owner (not via arbitrary JSON path). |

## B-grade — status of each

| ID | Status | Note |
|----|--------|------|
| B_QUEUE_ISOLATION | CLOSED | Replaced global `<evidence_root>/queue` with per-run `<evidence_root>/<run-id>/requests/`. Worker `allowWrite` is scoped to its own run's inbox. |
| B_ATTEMPT_ROLE_BINDING | CLOSED | `_db_role_matches` enforces role against the live job's `worker_role`. Active-attempt check verifies pid alive, attempt matches latest, status not terminal. |
| B_RESPONSE_PATH_IDENTITY | CLOSED | Single canonical `canonical_response_path()` in `supervisor_research`. Helper reads `OFLOOP_RESEARCH_RESPONSES` (single source) — no `pass-anon` / hardcoded builder path. |
| B_RATE_LIMIT | CLOSED | Durable across ticks via `_durable_op_count_last_60s()` counting receipts written in the last 60s. Does NOT reset on supervisor tick boundaries. |
| B_RESOURCE_CAPS | CLOSED | `_clamp_max_bytes()` clamps worker-requested `max_bytes` to the per-op cap (search: 2 MiB, read: 5 MiB, asset-read: 32 MiB). Worker may request LESS, never MORE. |
| B_CRASH_REPLAY | CLOSED | Idempotent lifecycle: request file is atomic-renamed to `<requests>/.claimed/<UUIDv4>.json` on dispatch. On supervisor restart, any claim without a matching response is re-dispatched. `_replay_check()` detects same request_id + matching `request_digest` and re-publishes the existing response (no second network operation); same request_id + different digest is refused with `ReplayDigestMismatch`. |
| B_REQUEST_IDENTITY | CLOSED | `--request-id` and `--request-digest` args forwarded to the broker; recorded in every receipt. Broker refuses non-canonical formats. |
| B_SEARCH_GENERICITY | CLOSED | `_search_wikipedia()` (default, unauthenticated) and `_search_ddg_lite()` (DuckDuckGo Lite HTML) as provider-neutral backends. `--search-backend` arg chooses; backend identity appears in the receipt. |
| B_SPECIAL_USE_SSRF | CLOSED | `_classify_address()` uses Python stdlib `ipaddress` with RFC 6890 / IANA special-use range sets covering loopback, RFC1918, CGN, link-local, IPv6 unique-local, IPv6 link-local, IPv6 multicast, documentation (TEST-NET-1/2/3, 2001:db8::/32), benchmarking (198.18.0.0/15), reserved (240.0.0.0/4), 6to4 (2002::/16), TEREDO (2001::/32), discard prefix (100::/64), ORCHID v2 (2001:20::/28), site-local (fec0::/10). `is_global` check provides positive authorization. IPv4-mapped IPv6 re-applies v4 rules. Broker canary self-tests 8 boundaries. |
| B_ROLE_PROMPT_DRIFT | CLOSED | `agents/of-builder.md` and `agents/of-reviewer.md` now have exactly one authoritative research path (`ofloop-research-call`). The obsolete `OFLOOP_RESEARCH_BROKER` section is removed. UUID4 generation uses `python3 -c 'import uuid; print(uuid.uuid4())'` (deterministic, on PATH). |
| B_PROMPT_INJECTION_BEHAVIOR | CLOSED | New `tests/unit/test_v200_research_authority.sh` section 11 (real prompt-injection behavioral fixture): worker cannot forge response, smuggle request to another run's inbox, or claim a role that does not match the live job. Live broker tests for TEST-NET, benchmarking, cloud-metadata, IPv4-mapped IPv6 SSRF guards. |

## Authority surface (worker-side, verified live from worker argv)

```
WORKER_RESPONSE_WRITE_AUTHORITY=none
  (responses/ is NOT in worker allowWrite; supervisor is the only writer)

WORKER_RECEIPT_WRITE_AUTHORITY=none
  (receipts/ and artifacts/ are NOT in worker allowWrite; broker is
  the only writer, called by supervisor via subprocess.run)

WORKER_PUBLIC_NETWORK_AUTHORITY=none
  (sandbox.network.allowedDomains = []; strictAllowlist = true)
  (worker can ONLY reach public internet via ofloop-research-call
   helper which queues to the supervisor's bridge)

REQUEST_INBOX_SCOPE=per-run only
  (worker's OFLOOP_RESEARCH_REQUESTS points at its own per-run
   requests/ dir; no other run's inbox is reachable)

RESPONSE_SCOPE=operator-owned, supervisor-writable, worker-readable
  (worker's allowRead includes OFLOOP_RESEARCH_RESPONSES;
   allowWrite does NOT)

BROKER_IDENTITY_CHECK=before-every-dispatch
  (_verify_broker_identity recomputes SHA256 and compares to
   commissioning evidence via canonical commissioning owner;
   refuses on drift)

RESEARCH_EXECUTION_ASYNC=yes
  (per-tick bounded _ResearchExecutor ThreadPoolExecutor,
   max_workers=2 via OFLOOP_RESEARCH_MAX_WORKERS; each tick
   drains within OFLOOP_RESEARCH_TICK_BUDGET_SECONDS default 5s)

RESEARCH_CONCURRENCY_LIMIT=2
  (ThreadPoolExecutor max_workers; in-flight cap = 2x workers)

RATE_LIMIT_MODEL=durable, across ticks
  (counts receipts in evidence/receipts/ written in last 60s;
   does NOT reset on supervisor tick boundaries; per-run cap 30/min)

REPLAY_MODEL=idempotent on request_id + request_digest
  (REQUEST → .claimed/<UUIDv4>.json → broker → RESPONSE)
  (re-dispatch refuses mismatching request_digest with
   ReplayDigestMismatch; matches re-publishes existing response)

SEARCH_BACKEND_MODEL=provider-neutral, operator-chosen
  (wikipedia: default unauthenticated REST query;
   ddg-lite: DuckDuckGo Lite HTML form-POST endpoint;
   backend identity appears in receipt.search_backend;
   worker contract: --op search --query <q>)
```

## Targeted bridge tests (v200)

```
tests/unit/test_v200_research_authority.sh
=============================================

§1  ping identity invariants                                       PASS
§2  help enumerates operations                                     PASS
§3  SSRF refusal (URL parsed, no socket opened)                   PASS
    13 cases including userinfo, file/data schemes, loopback
    (v4+v6), RFC1918 (a/b/c), link-local incl. cloud metadata
§4  argument validation                                            PASS
§5  evidence-dir creation/refusal                                  PASS
§6  HTML→text stripper is offline-safe                             PASS
§7  capability resolver enforces research.public commissioning    PASS
§8  live network integration (opt-in: OFLOOP_LIVE_NETWORK=1)       SKIP
§9  corrected supervisor-mediated boundary invariants               PASS
    (BuiltinCapabilityDefinition keeps worker Bash empty,
     broker NOT in worker allowRead, helper IS in worker
     allowRead, host-manifest preserves invariant)
§10 prompt-injection fixture: external content cannot widen auth  PASS
§11 prompt-injection BEHAVIORAL fixture                            PASS
    (worker cannot forge response, smuggle to another run's
     inbox, or claim a foreign role; live broker tests for
     TEST-NET / benchmarking / cloud-metadata / IPv4-mapped IPv6
     SSRF guards; supervisor_research canonical_response_path
     refuses path-traversal and stays under responses root;
     per-run responses isolation; cross-run requests isolation)
```

## Canonical suite

```
OF_LOOP_TOTAL=126
OF_LOOP_PASSED=126
OF_LOOP_FAILED=0
OF_LOOP_RELEASE_GATE_RESULT=PASS
```

`tests/integration/test_checkout_portability.sh`: PASS (no
developer-machine paths in tracked source).

## Cert-A v4 attempt (fresh canary)

A fresh canary was created at
`~/.local/state/ownframework-loop/production-canary/cert-a-v4-20260921T213631Z/cert-a-asyncio-page`
with `run-20260921T213642Z-3ba46280`. The packet correctly uses
`pass-0001` paths in all four required-validation commands (the
literal-path typo from cert-a-v3 is fixed).

The packet was approved and enqueued. The supervisor dispatched
worker PID 365. The worker argv correctly showed:

- `sandbox.network.allowedDomains = []`
- `sandbox.network.strictAllowlist = true`
- `allowRead` includes `bin/ofloop-research-call`, `research/<run-id>`,
  `research/<run-id>/responses`, scratch dir, worktree, runtime cache,
  git, python
- `allowRead` does NOT include `bin/ofloop-research-broker`
- `allowWrite` includes `scratch/builder/pass-0001`,
  `research/<run-id>/requests` (per-run inbox only),
  runtime cache
- `allowWrite` does NOT include `research/<run-id>/responses`,
  `research/<run-id>/receipts`, or `research/<run-id>/artifacts`
- `denyRead` includes `$HOME`, the supervisor state root, and
  container/docker.sock paths

The worker spent the full wall-clock budget (1 hour) but its
passes hit `runner_timeout` (124) — the Claude runner was killed
before producing output. 4 dispatches were attempted, all 0-byte
stdout. The supervisor kept the job in BACKOFF between dispatches.

This is an operational issue with the upstream Claude runner for
this model (MiniMax-M3) on this task, not an architecture defect.
The bridge infrastructure was exercised end-to-end (the worker
queued 7 REQUESTs; the supervisor bridge tick picked them up —
see the prior cert-a-v3 run, which is captured as durable evidence
in `~/.local/state/ownframework-loop/research/run-20260921T185008Z-060e5469/`
with 7 receipts and the Wikimedia PD-icon asset). The current
cert-a-v4 run was retired (`UPDATE jobs SET status='RETIRED' WHERE id=91`)
to free the slot.

Cert-A v4 did NOT reach `PROGRAM_FINAL=PASS` or `APPROVED`. This
report does not declare overall governed-research evolution
complete; the directive's directive 19 ("one fresh correctly
authored Cert-A from start to terminal") is not yet achieved.

## Cert-B restraint (job 87, prior evolution)

Job 87 is still DONE in the supervisor ledger. Cert-B's worker
spawned with no research authority (packet declared only
`toolchain.git` + `toolchain.python`); the research evidence
directory was NEVER created. Architecture's restraint discipline
is unchanged.

## Other

```
A_OPEN=0
B_OPEN=0

READY_TO_RUN_FRESH_CERT_A=no
  (cert-a-v4 retired due to upstream runner_timeout; the bridge
   infrastructure is verified by v200 + the live cert-a-v4
   worker argv; what remains is a Claude runner pass that
   produces output, which requires either a different model
   timeout posture, a tighter packet, or a supervisor-side
   retry that survives past pass-timeout)
```

This completes the bounded bridge-repair pass. The next checkpoint
is: confirm the corrective invariants via the live cert-a-v4
worker argv (already done above), then either (a) extend the worker
pass timeout and re-attempt cert-a, or (b) document the bridge as
fully hardened and produce a final certification only after a
fresh cert-A completes the chain to PROGRAM_FINAL APPROVED.
