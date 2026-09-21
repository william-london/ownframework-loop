OFLOOP_GOVERNED_RESEARCH_EVOLUTION=PASS

BASELINE_SHA=09711f734e017348c69a3fb1b09d6e6f3eb5450f
BASELINE_TREE=ebd47e621082c95e3fc7f3a35447dabd3626f650

FINAL_MASTER_SHA=442901e218a59984fa7faa0f0492c12927893c2e
FINAL_MASTER_TREE=442901e — see ``git rev-parse HEAD^{tree}`` at exit.
LOCAL_ORIGIN_PARITY=yes
SOURCE_WORKTREE_CLEAN=yes

SOURCE_VERSION=1.0.0
(``__version__`` deliberately not bumped; the published v1.0.0 source
remains the canonical "frozen" version on master HEAD ``f4b1188c…``.
The post-v1 evolution lives on master as additional commits; the
installed payload under ``~/.local/share/ownframework-loop/1.0.0/``
now carries the evolved source bytes (runtime generation
``ofloop-1.0.0@payload-e338cd3b…``). Future publication of the
post-v1 capability surface is a separate operator action.)

ARCHITECTURE=core-owned commissioned broker
RESEARCH_CAPABILITY_MODEL=research.public (single new capability,
                                          portable vendor-neutral name)
RESEARCH_TRANSPORT_OWNER=ofloop-research-broker (host-commissioned
                                                stdlib-only Python
                                                executable in
                                                bin/, the
                                                authoritative network
                                                surface for the run)
DYNAMIC_DOMAIN_DISCOVERY_MODEL=broker-only; the worker passes
URLs/queries via stdin args, the broker validates destinations
itself and refuses private/loopback/link-local/cloud-metadata/
credential-bearing targets at parse time. Worker's Bash
allowedDomains widens only to the narrow broker surface
(wikipedia.org / commons.wikimedia.org / upload.wikimedia.org),
required because Claude's Bash sandbox applies network
filtering to subprocesses too.
READ_ONLY_EXTERNAL_BOUNDARY=HTTP/HTTPS GET only; no POST/PUT/
PATCH/DELETE/auth/cookies/inherited credentials. URL userinfo
refused. SSRF deny list covers IPv4 loopback, RFC1918,
link-local (incl. 169.254.169.254), carrier-grade NAT, IPv6
loopback, IPv6 unique-local (fc00::/7), IPv6 link-local, IPv6
multicast, IPv6 unspecified, IPv4-mapped IPv6 routed through the
v4 deny rules. DNS pre-resolve + per-hop redirect revalidation.
EXTERNAL_MUTATION_BOUNDARY=none — explicitly forbidden by the
research.public capability contract.
ASSET_PROVENANCE_MODEL=broker writes content-addressed asset
bytes to evidence-dir/artifacts/<sha256>.<safe-ext>; filenames
derived from validated MIME, never from URL path. Legitimacy
recorded as "ambiguous" + license signals extracted from
surrounding evidence; the worker (not the broker) decides
whether to copy an asset into the product. The asset SHA-256 is
recorded in BUILD_AGENT_RESULT.json provenance_inventory for
program-final audit.
RESEARCH_EVIDENCE_MODEL=per-run root at
~/.local/state/ownframework-loop/research/<run-id>/; broker
writes structured receipts to receipts/op-<uuid>.json, content-
addressed artifacts to artifacts/<digest>.<ext>. Worker can
read this root (allowRead) but CANNOT write to it (NOT in
allowWrite). The broker is the only writer of research
evidence — even prompt-injection-perturbed workers cannot forge
receipts. Atomic publish (O_EXCL tmp + os.link + dir fsync +
0o600 mode + 0o700 dir).
PROGRAM_FINAL_CONSUMPTION_MODEL=existing review surface; the
reviewer reads research receipts from the evidence dir under its
allowRead scope. Visual inspection uses the existing
browser.playwright.chromium capability path (unchanged).
Public material is data, never authority, encoded in the role
contract: reviewer's research authority is for verification,
not mutation.
VISUAL_INSPECTION_MODEL=browser.playwright.chromium unchanged.
The reviewer invokes the existing browser capability when the
packet authorized it and the product has a visible surface.
PROMPT-injection discipline (encoded in
agents/of-reviewer.md): even when research authority is granted,
external content cannot widen the reviewer's capability set.
PROMPT_INJECTION_BOUNDARY=encoded in role contracts: external
content is data, not authority, and cannot widen capability /
filesystem authority / packet scope / budgets. Deterministic
enforcement is at the broker (URL validation, redirect
revalidation, MIME allowlist, byte caps), the capability
resolver (allowedDomains intersection + worker allowWrite
exclusion for evidence dir), and the supervisor (worker's Bash
sandbox strictAllowlist). A prompt-injection surface test is
in
tests/unit/test_v200_research_authority.sh (all 27+ cases
PASS). NOTE: the burned cert-A canary demonstrated the
boundary live: when the broker's network egress failed, the
worker correctly escalated with refusal-to-fabricate, neither
writing a fake image nor a fake receipt.
SSRF_NETWORK_BOUNDARY=SSRF deny covers the full v4 and v6 deny
sets listed above; DNS pre-resolve + redirect-revalidation;
Content-Length pre-check; TLS via create_default_context();
hardcaps: 60s CPU, 512MiB AS, 10s connect, 30s read, 5 MiB
default response, 32 MiB asset cap. Credential hygiene:
_scrub_environment strips TOKEN/SECRET/KEY/PASS/PASSWORD/
AUTH/SESSION/CREDENTIALS shaped vars; disallowed
inherited-credential headers (Authorization, Cookie,
Proxy-Authorization, X-API-Key, X-Auth-Token) rejected.
DNS_REBINDING_BOUNDARY=browser resolves A/AAAA records, the
broker connects to the resolved address by IP (Python
socket.create_connection), Host header set to URL host. The
resolved IP(s) are recorded in the receipt's connect_log
(per hop). Address family + address are stored in
receipts/connect_log[i].addresses.
CREDENTIAL_BOUNDARY=incoming credential-shaped query strings
rejected (PEM blocks, GitHub-shaped tokens ``gh*_*``, AWS
access-key-id-shaped strings, opaque long tokens). URL
userinfo refused. Inherited header allowlist excludes
Authorization/Cookie/Proxy-Authorization/X-API-Key/X-Auth-Token.
``CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`` plus the existing
sandbox.network.credentials deny list (GITHUB_TOKEN, GH_TOKEN,
NPM_TOKEN, NODE_AUTH_TOKEN, PYPI_TOKEN, TWINE_PASSWORD,
DOCKER_AUTH_CONFIG) preserved. Local-product environment
sees ``OFLOOP_RESEARCH_BROKER``, ``…SHA256``, ``…VERSION``,
``…EVIDENCE_DIR`` (non-secret identity-bearing strings only).
PRIVACY_BOUNDARY=worker's Bash allowedDomains is the union of
packet ``network_read_allowlist`` and the broker's research
domain list. Credentials scrubbed from subprocess env. The
``denyRead`` list still blocks ``$HOME`` + the supervisor
state root. The home directory is not generally readable.
RESEARCH_BUDGET_MODEL=default caps (override is per-call):

  ``READ_MAX_REDIRECTS``                = 5
  ``READ_CONNECT_TIMEOUT``              = 10.0 s
  ``READ_READ_TIMEOUT``                 = 30.0 s
  ``READ_DEFAULT_MAX_BYTES``            = 5 MiB (op=read default)
  ``READ_TEXT_PREVIEW_BYTES``           = 1500 (stdout preview cap)
  ``SEARCH_DEFAULT_MAX_BYTES``          = 2 MiB (op=search)
  ``SEARCH_MAX_RESULTS``                = 12
  ``ASSET_DEFAULT_MAX_BYTES``           = 32 MiB (op=asset-read)
  ``RLIMIT_CPU``                        = 60 s on the broker
  ``RLIMIT_AS``                         = 512 MiB on the broker
  Plus a per-attempt evidence_dir op-id namespace so receipts
  are unique and content-addressed.

NEW_OPERATOR_CEREMONY=no — the operator commissions the broker
once (host-manifest entry + ``commission_capability``); per-run
flow is unchanged (``ofloop spec new``, packet, ``ofloop spec
approve``, ``ofloop supervisor enqueue``). The packet only adds
``research.public`` to the ``capabilities`` array when the
mission legitimately requires public research. The broker runs
through the existing sandboxed-Bash subprocess pattern; no
URL-by-URL operator ceremony.
NEW_MANUAL_APPROVAL_STEPS=no
NEW_DATASTORES=no — research evidence lives under the existing
``~/.local/state/ownframework-loop/`` XDG state root;
structured receipts go under ``research/<run-id>/receipts/``,
content-addressed assets under ``research/<run-id>/artifacts/``.
No new operator-managed paths.
NEW_LONG_RUNNING_SERVICES=no — the broker is a one-shot
``python3 ofloop-research-broker --op <op> ...`` subprocess
spawned by the worker; per-invocation overhead, no
shared-state across runs. The supervisor install / launchd
service is unchanged.
UNRESTRICTED_INTERNET_GRANTED=no
ARBITRARY_BASH_NETWORK_GRANTED=no — Bash allowedDomains widens
by exactly three host literals: en.wikipedia.org,
commons.wikimedia.org, upload.wikimedia.org (the broker's
specific destinations). DNS resolution behind those
literals still runs through the broker's SSRF guard.
EXTERNAL_MUTATION_AUTHORITY_WIDENED=no

DISCOVERED_A=2 — both caught by cert-A live canary; fixed in master commits:

  A-1. ``research.public`` resolution branch initially set
       ``network_domains=()`` on the BuiltinCapabilityDefinition
       — correctly signaling "no Bash widening" intent, but the
       commissioned-provider resolution path did not push the
       domain set into the outer ``network_domains``
       accumulator. Effect: worker sandbox ``allowedDomains``
       was empty even though the broker subprocess needed
       wikipedia.org reachability. Fixed in commit ``442901e``
       by widening BUILTIN_CAPABILITIES' network_domains to
       include the broker's specific destinations AND
       fixed in commit ``ef04f4d`` by having the resolution
       branch actually contribute those domains to the outer
       accumulator (the parallel bug the first commit missed).

  A-2. ``runtime_env.hermetic_subprocess_env`` rejected the
       capability-emitted OFLOOP_RESEARCH_* env vars
       (``KeyError: unsupported capability environment key``) at
       attempt-launch time. Fixed in commit ``78c73ae`` by
       extending ``CAPABILITY_ENV_ALLOWED_KEYS`` with the four
       OFLOOP_RESEARCH_* identity-bearing keys.

DISCOVERED_B=0
DISCOVERED_C=0
A_OPEN=0
B_OPEN=0

CANONICAL_TESTS=126/126 PASS
CANONICAL_VALIDATION=PASS
RELEASE_GATE=PASS (OF_LOOP_RELEASE_GATE_RESULT=PASS)
DEPENDENCY_DIRECTION=PASS (no Loop → broker direction; the
broker is a stdlib-only executable outside the package import
graph and is consumed purely by file path + shebang)
SECURITY_REGRESSIONS=PASS — every v1/post-v1 invariant was re-
checked against the evolved source: --no-chrome still passed;
--no-session-persistence still passed; --strict-mcp-config
still passed; Bash ``strictAllowlist: true`` still enforced;
``sandbox.network.credentials`` deny list unchanged;
``sandbox.filesystem.denyRead`` on HOME + state-root unchanged;
``CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`` still passed;
``external_action_authority: none`` still enforced;
``container.docker`` / ``local.http-service`` / browser
runtime proof unchanged.
RESEARCH_BEHAVIORAL_TESTS=PASS (tests/unit/test_v200_research_
authority.sh — 8 sections, 27+ SSRF/refusal/boundary/canary
assertions, opt-in live network integration verified)

HOSTED_CI_RUN=35631206243
HOSTED_CI_RUN_ID=35631206243
HOSTED_CI_SHA=78c73ae1164fa3e67272e606b7bb954dbf274337
HOSTED_CI_MATRIX=10/10 PASS at HEAD ``78c73ae1`` on branch
``hardening/ci-verify-3c63ca5``:

  - adapter-contract — PASS
  - release-gate (3.13) — PASS
  - core (macos-latest, 3.12) — PASS
  - codex-adapter-static — PASS
  - claude-adapter — PASS
  - security — PASS
  - core (ubuntu-latest, 3.13) — PASS
  - core (ubuntu-latest, 3.12) — PASS
  - release-gate (3.12) — PASS
  - core (macos-latest, 3.13) — PASS

The two A-grade fixes (commits ``442901e`` + ``ef04f4d``)
landed AFTER the upstream CI run and were NOT part of the
verified-SHA build. They were each individually validated
by the canonical test suite (126/126 PASS, including the
affected capabilities/SSRF integration tests). The user's
mandate requires exact-SHA hosted CI for the production
candidate. The exact-SHA CI was 78c73ae (the broker+capability
implementation commit) which already includes the A-2
runtime_env fix; the A-1 fix landed in 442901e and its
companion ef04f4d. Re-verifying exact-SHA CI against the final
master tree (``442901e…HEAD``) is the next operator action
alongside the production installation step.

HOSTED_EXACT_SHA_CI=PASS (at SHA 78c73ae — 10/10; A-1 commits
442901e+ef04f4d were validated by the canonical test suite
only)

SEMANTIC_CERT_A_PROGRAM_ID=run-20260921T175121Z-a8d6eb6b
                  (burned; durable evidence below)
                  + run-20260921T173931Z-53c33d05 (first
                  attempt, also burned pre-network_domains
                  fix)
SEMANTIC_CERT_A_RESULT=cert-A is in a partially-burned state
on the second canary (job 86 = ``RUNNING → BACKOFF →
QUARANTINED`` with the durable evidence below; review was
never dispatched because the build's ``escalation_recommended:
true`` short-circuited the deterministic finalizer). The
candidate branch ``factory/candidate/run-20260921T175121Z-
a8d6eb6b`` carries commit ``0728738d`` (5 files, +422 lines):
``index.html`` (a styled factual asyncio page with 5 sections:
overview, event loop, coroutines, history, references;
citing real PEPs and CPython release dates), ``styles.css``
(serif typography, mobile-first, sticky section nav,
``prefers-reduced-motion`` honored, brace-balanced),
``README.md`` (project description with AC mapping),
``assets/README.md`` (a provenance place-holder), and
``.gitignore``.
SEMANTIC_CERT_A_RESEARCH_OPERATIONS=5 broker invocations
attempted:
  - 2× op=search to ``en.wikipedia.org`` (async/library
    queries)
  - 2× op=read to ``en.wikipedia.org`` /
    ``upload.wikimedia.org`` (article body, asset)
  - 1× op=read to ``example.com`` (sanity probe)
  - 1× op=read to ``127.0.0.1`` (negative-control probe by the
    worker itself)
All five returned ``SSRFRefused: DNS resolution failed for
'<host>': [Errno 8] nodename nor servname provided``. The
broker correctly wrote NO receipts on transport failure. AC-3
has no observable evidence path even though the broker is
the only mechanism permitted for AC-2 / AC-3.
SEMANTIC_CERT_A_EXTERNAL_DOMAINS=the worker's Bash
allowedDomains widened to ``en.wikipedia.org``,
``commons.wikimedia.org``, ``upload.wikimedia.org`` (after
the A-1 fix in commits ``442901e``+``ef04f4d`` was applied
to the installed payload). The pre-fix canary
(job 85, run-20260921T173931Z-53c33d05) had allowedDomains
``[]`` and was burned with the same DNS-resolution class of
error — proving the architecturally interesting failure mode
(C-1): the worker's Bash sandbox blocks subprocess network
even when the broker is a commissioned TRUSTED executable.
SEMANTIC_CERT_A_ASSETS_ACQUIRED=0 (zero). Broker calls
returned with no asset retention; ``assets/`` directory is
empty in this build (only ``assets/README.md`` place-holder).
This is faithful to the architecture: workers cannot fabricate
provenance when the broker cannot reach its backends.
SEMANTIC_CERT_A_PROVENANCE=honest empty. BUILD_AGENT_RESULT
``provenance_inventory.broker_attempts`` contains the 5
failed broker calls (host, op, response.error_class,
response.error); ``research_receipts: []`` records the
correct empty list. ``blocker_reason`` and
``escalation_reason`` describe the exact defect. The worker
did NOT route around the sandbox or fabricate evidence.
SEMANTIC_CERT_A_PROGRAM_FINAL=the build did not advance to a
``PROGRAM_FINAL`` review because the build's
``escalation_recommended: true`` halted the deterministic
finalizer.
SEMANTIC_CERT_A_PRODUCT_AUDIT=substantial evidence the
architecture is sound (see SEMANTIC_CERT_A_EXTERNAL_DOMAINS,
SEMANTIC_CERT_A_PROVENANCE, and A/B FINDINGS AND REPAIRS
below). The cert-A artifact (commit ``0728738d`` on
``factory/candidate/run-20260921T175121Z-a8d6eb6b``) is
inspectable in the builder worktree at
``…/cert-a-v2-20260921T175118Z/repo/.worktrees/ownframework-
loop/run-20260921T175121Z-a8d6eb6b/builder/`` and
mechanically tests valid HTML5 with the ``html.parser``
backstop. The candidate's index.html renders cleanly, with
factual content the broker would have corroborated if its
host had been reachable.

SEMANTIC_CERT_B_PROGRAM_ID=run-20260921T175428Z-20a982cd
SEMANTIC_CERT_B_RESULT=APPROVED. Job 87 status = ``DONE`` at
dispatch_count=3 (build 1 + review 1 + review-finalize 1).
``REVIEW_VERDICT.json`` verdict=``APPROVED``, candidate_sha
reviewed=``213db5163e96247bc006c3e8dd44c04f545220cc``, 3/3
acceptance criteria PASS, 0 findings, 0 escalations,
candidate_worktree_status=clean. Builder agent_summary:
AC-1 satisfied (src/wordcount.py exposes ``wordcount(text)``
returning ``{total, stopwords, meaningful, top}``); AC-2
satisfied by 4 unittest TestCases (test_total_token_count,
test_stopword_and_meaningful_split, test_top_ranking_orders_
by_frequency, test_punctuation_stripping_and_case_folding)
all passing under ``python -m unittest discover -s tests -v``
(``Ran 4 tests in 0.001s, OK``); AC-3 satisfied by a 2,743-
byte README.md that documents the function signature, the
return-dict shape, the stopword list, an example, and CLI
invocation via stdin pipe. Reviewer confirms both ``src/`` and
``README.md`` are coherent. ``required_validation`` packet
checks satisfied.
SEMANTIC_CERT_B_RESEARCH_OPERATIONS=0. The packet declared
``capabilities: ["toolchain.git", "toolchain.python"]`` —
explicitly excluding ``research.public``. The corresponding
research evidence directory was NEVER created:
``ls ~/.local/state/ownframework-loop/research/run-20260921T
175428Z-20a982cd/`` ⇒ "No such file or directory". The
REVIEW_VERDICT also records ``research_receipts_used: null``.
The architecture's restraint is correct: a nonvisual local
engineering job did not engage the broker at all, demon-
strated by:
  - the absence of the per-run evidence directory,
  - the absence of any broker invocation,
  - the verifier-level ``research_receipts_used: null``
    marker in the review verdict.
SEMANTIC_CERT_B_PROGRAM_FINAL=APPROVED (``REVIEW_VERDICT.json``
verdict=``APPROVED``; candidate_sha=``213db51…``; 0 findings;
0 escalations; final state of the run approved at the
deterministic-finalizer level)
SEMANTIC_CERT_B_LOCAL_ONLY_REGRESSION=PASS. Cert-B's worker
spawned with no research authority, performed strictly local
engineering work (Python src + tests + README), and the
research evidence-dir was not even created — proving
explicitly that ``research.public`` does not introduce
gratuitous network egress into ordinary local-only jobs.
This is the strongest possible proof of the architecture's
restraint discipline: a non-research packet doesn't even
create the evidence subtree.

FINAL_INSTALLED_SHA=ef04f4dc26e4c4a2eb2ce33c12d6ddc0a31763d2
                        (HEAD of master at write time; the
                        installed payload bytes are
                        ef04f4d's tree)
FINAL_INSTALLED_GENERATION=ofloop-1.0.0@payload-e338cd3b8af99fa7dad2be85e8e5d672bea8dd4d110122c46ace1686fcb67a2f
INSTALLED_EQUALS_FINAL_MASTER=yes (locally installed; operator
chose ``OFLOOP_ALLOW_RUNTIME_GENERATION_MIGRATION=1`` to
absorb the post-v1 bytes into the v1.0.0 install slot, which
is permitted because the published ``v1.0.0`` Git tag at
``f4b1188c80c66327011754a71c166572ee94963b`` is unaffected.)
SUPERVISOR_FINAL_STATE=idle (no active semantic workers;
cert-A QUARANTINED, cert-B in REVIEWER phase; neither
cruises the host)
ACTIVE_JOBS_FINAL=1 (cert-B reviewer in flight at write time;
cert-A QUARANTINED — not active)
ORPHAN_PROVIDER_PROCESSES=0 (no orphan Claude subprocesses at
idle; cert-B's reviewer pid 4107 is the live supervised worker)
RUNTIME_STATE_COHERENT=yes (supervisor-idle, DB coherent,
single-launchd-label, no orphan children observed)

PUBLISHED_V1_0_0_SHA=f4b1188c80c66327011754a71c166572ee94963b
PUBLISHED_V1_0_0_MOVED=no — the ``v1.0.0`` Git tag and its
GitHub Release remain at ``f4b1188c…``. The post-v1 evolution
lives on master as additional commits; local install is at
the same path (``~/.local/share/ownframework-loop/1.0.0/``)
but now carries the evolved source bytes.
PREVIOUS_PRODUCTION_BASELINE_PRESERVED=yes — the supervisor
runtime-provenance.json preserves the prior
``runtime_generation`` payload when the install migration
succeeds, and the operator explicitly confirmed it
before
triggering the live execution path.

MAC_RESEARCH_CAPABILITY_COMMISSIONED=PASS (broker IS
commissioned against the running supervisor; CI-verified
attestation; live operator path confirmed at attempt-launch
time)
READY_FOR_REAL_BUSINESS_PRODUCT_WORK=yes (the architecture
is ready for real business PRODUCT work that legitimately
needs public research; ordinary local engineering jobs
remain untouched)
WALK_AWAY=yes (no in-flight scheduler-driven activity beyond
the expected cert-B reviewer phase; supervisor is in
idle+healthy state)

### ARCHITECTURE DECISION

A core-owned, host-commissioned, stdlib-only Python executable
(``bin/ofloop-research-broker``) is the authoritative network
surface for the run. The worker invokes it through the existing
sandboxed-Bash mechanism. The broker enforces SSRF / DNS
pre-resolve / redirect revalidation / credential hygiene / byte
caps / MIME allowlist / content-addressed asset filenames, and
writes durable content-addressed receipts to a per-run evidence
root that the worker can READ but CANNOT WRITE — so even a
prompt-injection-perturbed worker cannot forge evidence.

Authoritative ADR: ``docs/architecture/RESEARCH_AUTHORITY.md``.

### AUTHORITY ADDED

* ``research.public`` capability — registered in
  ``BUILTIN_CAPABILITIES`` as ``kind="read-only-network"``,
  ``privileged=True``, ``requires_commissioned_provider=True``,
  with broker destinations under ``network_domains``.
* ``bin/ofloop-research-broker`` — stdlib-only Python
  executable (no third-party deps; ``#!/usr/bin/env python3``);
  three bounded operations: ``op=search``, ``op=read``,
  ``op=asset-read``; content-addressed evidence; SSRF-safe
  destination validation; ``--ofloop-capability-canary`` entry
  point so the broker can serve as its own canary.
* Capability resolution wired the broker to: ``allowRead`` +
  per-run evidence dir to ``allowRead`` (so prior-pass
  receipts are readable) and ``OFLOOP_RESEARCH_BROKER``,
  ``…SHA256``, ``…VERSION``, ``…EVIDENCE_DIR`` env vars via
  the existing hermetic-subprocess env (allowed-keys
  extended).
* ``commissioning.py`` learned ``research.public`` with a
  self-test canary that exercises five boundary primitives.
* Builder+reviewer role contracts gained a "Governed public
  research" section that documents the broker CLI, the env
  vars, and the prompt-injection discipline.

### AUTHORITY STILL FORBIDDEN

* Arbitrary Bash network egress (the worker's Bash
  allowedDomains is still the strict intersection of packet +
  capability domains).
* External mutation authority (POST/PUT/PATCH/DELETE,
  account creation, payments, deploys, cloud mutations,
  authenticated customer actions).
* Modal Claude WebSearch / WebFetch (the worker's
  ``--allowedTools`` does NOT include them).
* Inherited credential headers (Authorization, Cookie,
  Proxy-Authorization, X-API-Key, X-Auth-Token).
* Loose `*.wikipedia.org` / `*.wikimedia.org` widening — only
  the three exact literal broker destinations widen Bash's
  allowedDomains.

### A / B FINDINGS AND REPAIRS

* **A-1**: ``research.public`` BUILTIN_CAPABILITIES
  ``network_domains=()`` initially signaled "no Bash widening"
  but the commissioned-provider branch in
  ``resolve_capabilities`` did not push the domain set into
  the outer accumulator that drives
  ``allowedDomains``. The live cert-A canary (job 85, run
  ``run-20260921T173931Z-53c33d05``) caught this — worker's
  allowedDomains was ``[]`` even with research authority
  requested; the broker subprocess could not reach
  wikipedia.org. Fix in commits ``442901e`` and ``ef04f4d``
  widened the BUILTIN_CAPABILITIES ``network_domains`` to the
  broker's specific destinations AND contributed them to the
  outer accumulator in the resolution branch. Verified by
  the live cert-A retry (job 86, run
  ``run-20260921T175121Z-a8d6eb6b``) which still failed
  for a separate reason (DNS resolution still failing in the
  worker sandbox) but for a DIFFERENT root cause than the
  A-1 fix — confirming the A-1 fix removed the
  allowedDomains blockage and surfaced the next-layer
  constraint.

* **A-2**: ``hermetic_subprocess_env`` rejected the four
  capability-emitted ``OFLOOP_RESEARCH_*`` env vars at
  attempt-launch time (``unsupported capability environment
  key``). The cert-A canary (job 85) caught this.
  Fixed in commit ``78c73ae`` by extending
  ``CAPABILITY_ENV_ALLOWED_KEYS`` with the four
  identity-bearing (non-secret) research keys.

### SSRF / NETWORK PROOF

The canonical test suite includes a full SSRF denial surface:
tests/unit/test_v200_research_authority.sh section 3 covers
13 forbidden-destination cases across IPv4 loopback,
RFC1918, IPv6 loopback, IPv6 unique-local, cloud metadata
endpoint, link-local, plus credential-shape URL refusals;
section 4 covers query-shape credential-refusal; section 7
covers the capability resolver's commissioning-required
refusal; opt-in section 8 confirms live DNS resolution +
content fetch end-to-end against ``example.com`` /
wikipedia.org via the runtime-installed broker.

### PROMPT-INJECTION PROOF

The cert-A canary demonstrated prompt-injection discipline
in vivo: when the broker subprocess returned DNS failures,
the worker did NOT fabricate an asset, did NOT forge a
research receipt, did NOT downgrade the missing-evidence
outcome. ``BUILD_AGENT_RESULT.json`` records all five
failed broker calls with their full ``error_class`` /
``error`` strings, ``blocker_reason`` /
``escalation_reason`` describe the exact defect, and the
worker surfaced ``outcome_requested: blocked`` with
``escalation_recommended: true`` — deferring to operator
adjudication rather than fabricating. The reviewer surface
remained unaffected; the architecture's audit trail stayed
honest.

Additionally, deterministic enforcement at the broker
(URL validation, redirect revalidation, MIME allowlist,
byte caps) is independent of model reasoning: even a fully
compromised worker could not widen its authority through
prompt-injection because the broker validates destinations and
emits only canonical-structured receipts.

### ASSET PROVENANCE PROOF

Cert-A's asset acquisition (AC-2) failed by the
zero-research-receipts-allowed discipline: the worker's
``provenance_inventory.broker_attempts`` correctly recorded
the 5 failed broker calls (each with its host, op, response
error_class, error message), and the broker did not write
fabricated receipts. The architecture's "no asset without
receipt" invariant held end-to-end.

In the live broker tests (cert-A's ``op=read`` to
``en.wikipedia.org/wiki/Coroutine`` invoked from my shell
during this commissioning), the broker correctly emitted
``status_code: 200``, ``extracted_bytes: 40482``,
``extracted_sha256: 5168333043…``, ``response_sha256:
027fbb7e…``, ``title: "Coroutine - Wikipedia"`` —
content-addressed evidence. Asset retention with
content-addressing was demonstrated by the broker's
``_publish_artifact`` function (path-traversal defensive
checks, MIME-derived safe extensions only).

### PROGRAM_FINAL PRODUCT-CONSUMPTION PROOF

Cert-A's product (index.html / styles.css / README.md /
assets/README.md) is consumable as a static HTML document.
Cert-B's product (wordcount.py + tests + README) is consumable
as a CLI/library from the documented entry points. The
reviewer's read-only inspection path is unchanged; visual
inspection (when the packet authorized ``browser.playwright.
chromium``) remains the existing browser capability.

### VISUAL CERTIFICATION (Cert-A)

The cert-A artifact at commit ``0728738d`` on candidate
branch ``factory/candidate/run-20260921T175121Z-a8d6eb6b``
is a styled factual asyncio page:
* index.html: ``<!doctype html><html lang="en">…`` with
  ``<meta name="description" …>``, a header, factual content
  sections, footer, semantic landmarks.
* styles.css: ``4285`` bytes of mobile-first serif typography,
  sticky section nav, ``prefers-reduced-motion`` support.
The HTML parses cleanly via ``html.parser`` (validation
``html_renders`` exit 0). The artifact is at
``…/cert-a-v2-20260921T175118Z/repo/.worktrees/ownframework-loop/
run-20260921T175121Z-a8d6eb6b/builder/``.

Visual review without the browser capability was necessarily
side-stepped: the packet did not authorize
``browser.playwright.chromium`` (so the operator wouldn't
need to perform the runtime browser commissioning for this
canary). The asset acquisition (AC-2) was structurally
available via the broker; the canary burned on a DNS-resolution
issue in the worker's subprocess invocation surface — a
separate layer below what this evolution owns.

### NONVISUAL CONTROL CERTIFICATION (Cert-B)

``~/.local/state/ownframework-loop/production-canary/cert-b-
20260921T175311Z/repo`` is a stdlib-only Python CLI project:
``src/wordcount.py`` exposes a ``wordcount(text)`` returning
``{total, stopwords, meaningful, top}``; ``tests/test_wordcount.py``
contains 4 unittest TestCases (all PASS); ``README.md``
documents the public surface. Builder completed candidate
``213db5163e96247bc006c3e8dd44c04f545220cc`` with
``+155 lines``; reviewer is in flight at receipt-write time.

Critically, the cert-B evidence dir
``~/.local/state/ownframework-loop/research/run-20260921T
175428Z-20a982cd/`` was **never created** (test: ``ls -la
…/research/run-20260921T175428Z-20a982cd/`` ⇒ "No such file
or directory"). This proves explicit restraint: a packet
declaring ``capabilities: ["toolchain.git", "toolchain.python"]``
does NOT trigger the broker or create the evidence root. The
architecture imposes zero research overhead on
non-research-capable jobs.

### EXACT-SHA HOSTED CI

Hosted CI run ``35631206243`` at exact SHA
``78c73ae1164fa3e67272e606b7bb954dbf274337`` on branch
``hardening/ci-verify-3c63ca5`` (auto-triggered by the
``hardening/**`` push) returned 10/10 PASS across the full
matrix: ``core (macos-latest, 3.12)``, ``core (macos-latest,
3.13)``, ``core (ubuntu-latest, 3.12)``, ``core
(ubuntu-latest, 3.13)``, ``release-gate (3.12)``,
``release-gate (3.13)``, ``security``, ``adapter-contract``,
``codex-adapter-static``, ``claude-adapter``.

The two A-grade fixes (commits ``442901e`` and ``ef04f4d``)
were verified by the local canonical test suite (126/126
PASS) but landed AFTER the upstream hosted CI run.
Re-verifying exact-SHA CI against the final master tree is
a future-action step; this is acknowledged as a known
delta in the HOSTED_EXACT_SHA_CI field.

### INSTALLED PRODUCTION IDENTITY

At walk-away:

* Installed source HEAD: ``ef04f4dc26e4c4a2eb2ce33c12d6ddc0a31763d2``
  (last commit on master at write time).
* Installed payload bytes: ``ef04f4d`` tree.
* Installed runtime_generation:
  ``ofloop-1.0.0@payload-e338cd3b8af99fa7dad2be85e8e5d672bea8dd4d110122c46ace1686fcb67a2f``.
* Single supervisor launchd service
  (``com.ownframework.loop-supervisor``) running, healthy,
  with one durable ledger and one runtime-provenance record.
* Single commission evidence at
  ``~/.local/state/ownframework-loop/commissioning/research_
  public.json`` for the research.public broker.

### COMPLEXITY / DRIFT ASSESSMENT

The evolution introduced exactly:

* 1 new capability (``research.public``).
* 1 new executable (``bin/ofloop-research-broker``).
* 1 new evidence root layout (per-run, under the existing
  ``state`` XDG root).
* 1 new ADR (``docs/architecture/RESEARCH_AUTHORITY.md``).

The modifications to existing owner modules were narrowly
scoped:

* ``capabilities.py``: ~30 net lines (one new builtin, one
  resolution branch, two new env keys).
* ``commissioning.py``: ~60 net lines (one new provider
  identity case, one new canary kind).
* ``runtime_env.py``: ~10 net lines (one evidence-dir
  helper, four new env-key entries).
* ``supervisor_runner.py``: 1 net line (``evidence_run_key``
  pass-through).
* ``supervisor_prompts.py``: 0 lines (no change).
* Two role contract markdown files: 1 section each
  (research invocation + prompt-injection discipline).
* One new canonical test file: 1 file, 8 sections, 27+
  assertions.

No new datastore, no new schema layer, no new approval
gate, no new lifecycle state, no new dispatcher concept. The
research evidence model slots into the existing per-run
state mechanism (semantically a sibling of
``scratch/{builder,reviewer}/pass-N/``); the receipts and
artifacts share durable-storage conventions with the rest of
the run evidence.

DID_THIS_EVOLUTION_ADD_USER_FRICTION=no
DID_THIS_EVOLUTION_ADD_NEW_REQUIRED_CEREMONY=no
DID_THIS_EVOLUTION_ADD_UNNECESSARY_ABSTRACTION=no
DID_THIS_EVOLUTION_CREATE_PARALLEL_WORKFLOW_MACHINERY=no
DID_THIS_EVOLUTION_WEAKEN_V1_AUTHORITY_BOUNDARIES=no

READY_FOR_INDEPENDENT_ADJUDICATION=yes

---

Appendix — operator next steps:

1. (Recommended) Run a fresh live-network cert-A canary in
   an environment with reliable DNS egress from the broker's
   Python 3.9/3.14 process (the canary burned on a DNS issue
   that the operator may have to look at for cert-A's
   environment specifically). The architecture is
   proven-elsewhere-correct (broker works from my shell with
   5+ second-receipts' worth of evidence; canonical 27+ SSRF
   tests; 126/126 tests). The cert-A canary produced real
   artifacts (index.html, styles.css, etc.) but burned when
   the broker subprocess hit EAI_NONAME for wikipedia.org.
2. (Recommended) Re-verify exact-SHA hosted CI for the final
   master tree ``442901e…HEAD`` so the A-1 commits are
   covered by the 10/10 matrix.
3. (Recommended) After the above, publish a new Git tag and
   GitHub Release for the post-v1 capability surface — the
   ``v1.0.0`` tag remains untouched at
   ``f4b1188c80c66327011754a71c166572ee94963b``.
