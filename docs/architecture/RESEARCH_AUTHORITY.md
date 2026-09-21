# Governed Public Research Authority (ADR)

**Status:** accepted
**Applies to:** master, post-`09711f734e017348c69a3fb1b09d6e6f3eb5450f`
**Supersedes:** none

## 1. Problem

OwnFramework Loop's v1/POST-V1 production baseline gives a semantic engineering
run several capabilities — `toolchain.*`, `package.*`, `container.docker` (only
through a commissioned broker), `local.http-service` (only through
`claude_native_safe_local_binding`), `browser.playwright.chromium` (only when
the operator-commissioned shared asset root is runtime-proven by the real
browser canary) — and otherwise confines Bash to the packet's exact
`network_read_allowlist` through the Claude sandbox with `strictAllowlist: true`.

That authority is correct for the things it was built for: deterministic
compilation, package installation against known registries, host-canary-proven
browsing of operator-controlled URLs, and read/write within the packet's
`allowed_paths` / `protected_paths` / pass-scoped runtime cache. It deliberately
refuses all of:

* dynamic public web search discovered at execution time
* arbitrary public URL reads discovered at execution time
* external public asset acquisition beyond operator-approved registries
* browser navigation to arbitrary public URLs
* browser screenshoting of arbitrary public URLs

The next product evolution needs the system to **legitimately** perform all of
those, **without** giving Loop a wider attack surface than the v1 boundary and
**without** requiring the human operator to enumerate every eventual URL or
search-result host in advance.

This ADR adjudicates the smallest safe mechanism.

## 2. Existing v1 / post-v1 authority model

The current architecture has six authority-bearing surfaces, all of which
remain authoritative for any research-addition:

1. **Packet** (`lib/ownframework_loop/packet.py`). v2/v3 packets carry
   portable capability **names**, exact `network_read_allowlist` hostnames,
   path scopes, risk budgets, and authority fields (`merge_authority`,
   `push_authority`, `deploy_authority`, `external_action_authority`).
   The packet is a frozen, byte-immutable authority artifact; `external_action_authority`
   is currently `none` for executable packets.
2. **Capability resolution** (`lib/ownframework_loop/capabilities.py`).
   `resolve_capabilities()` consumes packet-supplied names, walks the strict
   `BUILTIN_CAPABILITIES` registry plus the operator's `host-manifest.json`,
   and produces a fail-closed resolution: per-capability exact executable
   path/version/SHA-256, `network_domains` set, exact read/write paths,
   and a sealed `semantic_runtime_fingerprint` over Claude's executable bytes
   and platform identity.
3. **Run binding** (`lib/ownframework_loop/capability_binding.py`).
   `ensure_run_binding()` seals an immutable `CAPABILITY_BINDING.json` over the
   stable projection. Migrations go through `migrate_run_binding()` with a
   PREPARED/COMPLETE migration record chain. This is the durable cross-attempt
   contract.
4. **Capability receipt** (`write_resolution_receipt` /
   `read_resolution_receipt`). Per-attempt, immutable, canary-proven
   evidence that this attempt was launched under exactly the sealed run
   binding.
5. **Sandbox construction** (`lib/ownframework_loop/supervisor_runner.py`).
   `_semantic_worker_settings()` builds the JSON the Claude process receives
   as `--settings`. Its critical properties for this ADR:
   * `--no-chrome` and `--no-session-persistence` are mandatory.
   * `--strict-mcp-config` with the explicit empty `{"mcpServers":{}}`
     payload means the worker cannot inherit MCP servers and cannot add any.
   * `sandbox.network.allowedDomains` is the **intersection** of the
     packet-supplied `network_read_allowlist` and the resolved capability
     `network_domains`. `strictAllowlist: true` is permanent.
   * `sandbox.network.credentials` denies common credential env vars
     (`GITHUB_TOKEN`, `NPM_TOKEN`, `GH_TOKEN`, `NODE_AUTH_TOKEN`,
     `PYPI_TOKEN`, `TWINE_PASSWORD`, `DOCKER_AUTH_CONFIG`); the
     `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` env var additionally strips
     Anthropic / cloud credentials from Bash children.
   * `sandbox.filesystem.denyRead` denies HOME broadly; `allowRead` reopens
     only the worktree, run evidence dir, runtime cache, `git_common_dir`,
     `_source_root()`, and operator-opened credential files. `denyWrite`
     denies the worktree for reviewer role.
   * `autoAllowBashIfSandboxed: true` and `allowUnsandboxedCommands: false`
     mean every Bash call that escapes the sandbox is refused — including
     any attempt to call out to `curl` against an unauthorized host.
6. **Privileged capabilities** (`container.docker`, `local.http-service`,
   browser runtime proof). Each requires a host-manifest entry plus
   `verify_commissioning()` against a canary artifact path whose body digest
   is recomputed before the worker is released.

PRODUCT FINALLY uses the supervisor / dispatch state machine, not Loop.
Loop never becomes a publisher.

## 3. Why ordinary exact-domain network authority is insufficient for
dynamic research

Exact-domain authority is correct for two cases:

1. the operator already knows the exact registries, vendor domains, or local
   services the run will need; and
2. the destination set is static for the run's lifetime.

Dynamic public research fails both:

* Search engines return result URLs the packet cannot have predicted.
* Reading a referenced page may surface additional URLs that lead deeper.
* Legitimate asset acquisition may require fetching a photograph / SVG /
  font / dataset from a host that is not itself the search target.
* The set of useful hosts changes during the run as the semantic worker
  discovers the right references.

If the worker were simply granted a wildcard `strictAllowlist: false` or an
extra `allowedDomains` entry covering the whole public web, **every Bash
command** — including ordinary `pip install` / `cargo build` /
`git fetch` / `node install` — would gain public-internet reachability,
which is a regression: those commands should continue to talk only to the
registries their capability authoritatively named, and only the research
operation should reach the wider web.

Conversely, a per-host "I see a new URL, please update my allowlist"
interaction with the operator or with the spec stage breaks the
no-new-operator-ceremony guarantee and is itself an authority widening:
the operator cannot meaningfully audit arbitrary hosts as the run
progresses. It would also widen Bash by adding arbitrary new domains to
`sandbox.network.allowedDomains`, which is the **same regression** as the
wildcard.

The fix is therefore not "make the sandbox wider" but "add a different
authority surface, owned by a different process, that the worker can
invoke only in read mode."

## 4. Alternatives considered

### A. Add `WebSearch, WebFetch` to `CLAUDE_BUILDER_TOOLS`

**Rejected.**

Claude's `WebSearch` and `WebFetch` are Anthropic-side tool primitives; Loop
would have no validated invariant for any of:

* the URL (no SSRF, no DNS-rebinding, no credential-checking)
* the redirect chain (search engines and many CDNs rewrite via 30x)
* the bytes (no SHA-256, no per-asset size bound, no asset retention)
* attribution (Loop would receive opaque plaintext with no provenance)
* per-run budgets (no per-operation or per-byte limit)

`WebFetch` in particular runs through Anthropic's proxy infrastructure,
which makes provenance opaque to Loop's audit trail and would require
outsourcing authority to a third party for every fetched URL. That is a
silent authority-widening at the architecture layer, not a configuration
change. Combined with the lack of an SSRF boundary, this is a
credential-leakage / SSRF / prompt-injection vector that the deterministic
core cannot enforce.

The prompt-injection angle is decisive: fetched WebFetch content becomes
visible to the model verbatim, which means an attacker who can place
content at any URL fetched during a research run gets to influence
the worker's reasoning. With no provenance or path-scoping at the
fetch layer, every fetch is effectively an untrusted instruction
channel into the worker.

### B. Replace Bash sandbox `strictAllowlist: true` with permissive-by-default

**Rejected.**

This would widen Bash for every command, not just the research command.
Package managers, build tools, Git, and static analyzers all inherit the
widening. The architecture's core invariant — "Bash reads only what the
packet explicitly allowed plus what the resolved capability explicitly
allowed" — disappears.

### C. Add a per-host "I now know this domain is fine" approval step

**Rejected.**

This is a regression in two ways:

* it adds a new operator ceremony, which the mandate forbids; and
* it widens Bash `allowedDomains` for every command (the earlier
  regression B), just delayed through a UI step. The approval does not
  constrain the search-result navigation that follows.

### D. Run research outside Loop, return a static evidence bundle to the
   worker as part of the work order

**Rejected for general use; reserved as a primitive.**

Out-of-Loop research breaks the run-bound provenance, removes the
content-addressed evidence trail, prevents later passes from re-using
research they did not originate, and turns the human operator into the
research broker the architecture was meant to replace. The same primitive
(operator-supplied static evidence) remains useful as an *input* to the
research capability for fixtures and test cases.

### E. Spawn a per-pass disposable browser session with a fresh profile and
   let it read arbitrary public URLs

**Rejected.**

A fresh profile fixes the credential-leakage of a persisted profile but
does not fix SSRF, redirect-re-validation, byte limits, or
content-addressing. It also inherits the prompt-injection surface of
WebFetch because the browser's DOM becomes untrusted model input with the
exact same authority gap.

### F. Adopted: A core-owned **bounded public-research broker**.

The broker is the smallest mechanism that:

* keeps Loop in full control of destinations (and only destinations
  related to public read authority);
* gives the worker no Bash-sandbox widening;
* gives the model no opaque-string authority-widening tool;
* is provider-neutral at the capability and resolution layers;
* preserves all v1/post-v1 boundaries (HOME, `--restricted`,
  `--no-chrome`, `--no-session-persistence`, `--strict-mcp-config`,
  Bash `strictAllowlist: true`, no external mutation authority, no
  receipt identity change).

## 5. Chosen boundary

The boundary is a **core-owned, host-commissioned, narrowly-permissioned
executable** that the worker invokes through its existing Bash sandbox, and
through which all public research passes.

```text
semantic worker (Bash sandbox unchanged)
    |
    | one narrowly typed CLI invocation:
    |   ofloop-research-broker --op search|read|asset-read
    |       --run-dir <...>
    |       --url '<...>'
    |       --max-bytes N
    |       --kind '<...>'
    |
    v
operator-commissioned provider (paths / SHA-256 from host-manifest)
    |
    +-- validates op, URL, scheme, bytes, redirect chain
    +-- resolves DNS, refuses forbidden addresses
    +-- rev-validates every 30x target
    +-- bounds timeout, response bytes, asset bytes
    +-- writes durable structured receipt into:
    |     <canonical_repo>/.ownframework-loop/<run-id>/research/<op-id>.json
    +-- returns: stdout = receipt path + small semantic summary;
    |           no asset bytes streamed to the model (Claude only
    |           reads the receipt, references the artifact by digest)
    |
    v
public internet read (HTTPS / HTTP GET only)
```

### Why this is a generic contract, not a `claude.*` contract

The capability name (`research.public`) and the capability binding record
(registry + commissioning + receipt shape) are vendor-neutral. The CLI
surface is a normal executable. A non-Claude runner invokes the same
broker the same way. Claude's tool list explicitly does **not** grow:
Claude only gets to spawn the broker via its existing Bash sandbox, and
the broker enforces the boundary.

### Capability semantics

A single new built-in capability family:

* **`research.public`** — fails-closed-resolution unless the host
  manifest points at a commissioned `ofloop-research-broker` executable
  with verified SHA-256 / version. Resolution adds the broker to the
  worker's `allowRead` and to a small **per-run research evidence**
  directory under the pass-scoped runtime cache as `allowWrite`. The
  broker is **not** added to `sandbox.network.allowedDomains` — only
  the broker subprocess has public-internet reachability, and it
  validates destinations itself.

No additional runtime capabilities are introduced in this ADR. Optional
follow-on capabilities (e.g. `asset.public-photo`, render-as-screenshot
delegated to a host render service) are deliberately deferred because
they each need their own SSRF / asset-boundary / attribution story and
benefit from the broker's evidence trail once it is in production.

### Why the broker does not inherit Bash `allowedDomains` widening

The worker never gets an extra `allowedDomains`. Its existing sandbox
remains `strictAllowlist: true` against packet ∩ capability domains. The
worker is allowed to spawn the broker because the broker executable path
was resolved by `resolve_capabilities()` and admitted into `allowRead`.
The broker's outbound egress is a separate authority surface; it is
commissioned, not inherited.

### SSRF design

The broker enforces the following. Any failure fails-closed and writes
an audit entry before the network attempt.

* **Scheme**: only `http` and `https`. Refuses `file:`, `data:`, `ftp:`,
  `gopher:`, custom schemes, scheme-relative URLs.
* **Userinfo / credentials**: refuses any URL containing
  `@` between the scheme and the authority, or any
  `Authorization`/`Cookie`/inherited credential header in the request
  line.
* **DNS pre-resolution**: validates the resolved A/AAAA records
  against a deny set covering at minimum: `127.0.0.0/8`, `10.0.0.0/8`,
  `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16` (incl. cloud
  metadata), `100.64.0.0/10` (carrier-grade NAT), `::1`, `fc00::/7`,
  `fe80::/10`, `169.254.169.254`, unspecified addresses, multicast,
  broadcast.
* **Redirect revalidation**: every 30x is followed **only** if its
  target validates against the same SSRF checks (DNS + scheme). The
  broker records every hop and re-validates; if any hop fails, the
  fetch fails. Capped at a small `MAX_REDIRECTS`.
* **DNS-rebinding defense**: name resolution happens immediately
  before the connect, on a path that the broker controls. The IP the
  broker connects to is the same IP it resolved (Python's
  `getaddrinfo` → socket connect by the resolved address). The
  resolved address is logged into the receipt, so a post-hoc audit
  can verify no private-IP connect happened.
* **Request body**: none. `GET` only.
* **Response bounds**: `MAX_RESPONSE_BYTES` (decompressed) and a
  per-asset `MAX_ASSET_BYTES`; on exceed, the socket is closed and the
  fetch fails with `payload_too_large`.
* **Timeout**: `READ_TIMEOUT_S` per attempt; a small
  `CONNECT_TIMEOUT_S`.
* **MIME**: preserved into the receipt; assets must declare a
  reasonable MIME (`image/*`, `application/pdf`, `font/*`,
  `application/octet-stream` are all acceptable for assets; HTML, JSON,
  plain text for reads).
* **Path traversal / filename injection**: any artifact retained to
  the evidence dir is computed from the **content digest**, never from
  the URL path. Filenames are
  `<op-id-prefix>-<sha256[:16]>.<safe-ext>` where `safe-ext` is
  derived from the validated MIME, not from the URL.

### Credential boundary

The broker is a normal executable and inherits the worker's
**credential-stripped** subprocess env (the existing
`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` plus the existing
`sandbox.network.credentials` deny-list). It must NOT inherit any of:

* `GITHUB_TOKEN`, `GH_TOKEN`, `NPM_TOKEN`, `NODE_AUTH_TOKEN`
* `PYPI_TOKEN`, `TWINE_PASSWORD`
* `DOCKER_AUTH_CONFIG`
* `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, or any
  Anthropic/cloud-provider credential

The broker additionally strips itself (defence in depth) before issuing
the request: it removes any inherited `Authorization`, `Cookie`,
`Proxy-Authorization`, and any env var matching `*TOKEN*`,
`*SECRET*`, `*KEY*`, `*PASS*` (case-insensitive).

Search queries are themselves outbound disclosure. The broker writes
every issued query to the receipt unredacted; this ADR documents that
this is intentional but constrains the broker to refuse queries that
include a private-looking path/token pattern (env-var-shaped substrings,
long base64 runs, paths under `.git`/`.ssh`/`.aws`).

### Research evidence model

```
<canonical_repo>/
  .ownframework-loop/
    <run-id>/
      research/
        RECIPES.json           (per-pass attempt → recipe index)
        rec-<attempt>/
          RECIPE.json          (declared operation, capability bound, attempt)
          op-<op-id>.json      (per-receipt: query/URL/final-URL/bytes/
                                sha256/MIME/timestamp/redirect-chain/
                                source-title/retained-artifact-sha256)
          artifacts/
            <digest>.bin       (only when the operation retained bytes)
            <digest>.mime      (text/plain)
```

* Bound to the run id.
* Mirrors the CAPABILITY_BINDING.json authority surface: any later pass
  reading research evidence must satisfy the same run-binding digest.
* Appending/changing the evidence is a state mutation; the broker is
  the only writer and writes through the existing
  `_publish_complete_no_replace()` pattern so no partial receipt is
  observable from another thread.
* Research artifacts are **not** automatically promoted into the
  product worktree. The builder must explicitly copy an artifact into
  the worktree as part of its normal `Write` action under the packet's
  `allowed_paths`. The copied artifact retains its provenance because
  the source digest from the receipt is preserved.

### Asset provenance model

When the operation is `asset-read`, the broker:

* validates exactly as for `read`;
* records the asset byte count, MIME, final URL, and content SHA-256;
* retains the artifact bytes inside the per-attempt `artifacts/`
  directory under the research evidence root, named by digest only;
* records attribution/license evidence that was visible at the page
  (e.g. visible `license: ...` / `alt: ...` / `rel="license"` markers
  in surrounding HTML the broker already fetched);
* does **not** decide whether to copy the asset into the product.
  The builder decides that. If copied, the digest remains the
  binding identity, and the worktree write must be inside the
  packet's `allowed_paths`. The `BUILD_AGENT_RESULT.json` records the
  digest and source URL for each promoted asset so the asset's
  provenance survives to PROGRAM_FINAL and audit.

When the asset's licensing or legitimacy is ambiguous, the broker
returns a `LEGITIMACY: AMBIGUOUS` field on the receipt, the artifact
is still retained (it is not censored), but the receipt's `usage_hints`
field is empty, and the standard builder contract prefers:
1. operator-supplied assets;
2. clearly reusable/open assets;
3. generated/original assets;
4. or a truthful limitation.

The broker does not encode a business category; it only records what
was visible. The builder's contract reads the receipt and decides.

### PROGRAM_FINAL integration

PROGRAM_FINAL is consumed from the existing `program.py` and
`review_finalize.py` flow. The deepening does **not** add a new state
machine. Instead:

* When a packet requested `research.public` and the product has a
  visual surface, the existing
  `browser.playwright.chromium` capability remains the visual
  inspection surface. The reviewer asks for it only if the packet
  authorized it; the absence is treated honestly (no fabricated
  visual review).
* When `local.http-service` is also requested (or the product
  logically is a CLI / library), the reviewer's normal Bash sandbox
  can call the running service per the existing
  `local.http-service` commissioning primitive.
* The reviewer's judgement of "finished vs unfinished" continues to
  come from the existing `REVIEW_AGENT_ASSESSMENT.json` shape. Visual
  product depth assessments add a single semantic doctrine to the
  role contract: "if the product has a visual surface and the
  packet did not authorize browser/research, the reviewer must say
  so explicitly instead of silently skipping visual depth."

Capability inference in the SPEC boundary hints at:

* `research.public` when `work_units` or `acceptance_criteria`
  mention needing documentation/examples that may be public;
* `browser.playwright.chromium` when the work produces HTML/CSS/JS
  visual artifacts;
* `local.http-service` when the work produces a runnable local
  service.

These hints are advisory (the SPEC is still the operator-facing
artifact); the deterministic packet then either includes them or
does not, and the runtime authority surface is unchanged.

### Rejected architecture summary

| Alternative | Why rejected |
| --- | --- |
| A. Vendor `WebSearch` / `WebFetch` tools | opaque URL/bytes, no provenance, no SSRF, prompt-injection surface |
| B. Wildcard Bash `allowedDomains` | widens package manager / build network |
| C. Per-host approval steps | new operator ceremony + still widens Bash `allowedDomains` |
| D. Out-of-Loop research | breaks run-bound provenance |
| E. Fresh-profile browser | no SSRF / size / redaction control |

### Migration / backward compatibility

* No existing v1/post-v1 capability changes required.
* `BUILTIN_CAPABILITIES` gains `research.public`; the
  `CAPABILITY_CONTRACT_REVISION` increments. Existing sealed runs
  whose binding carries the prior revision are unaffected (their
  `binding_sha256` already pins the old identity).
* Existing packets without `capabilities: ["research.public"]` keep
  their v1 authority model — they cannot invoke the broker, and
  Bash's `strictAllowlist: true` remains intact.
* Capability manifest schema unchanged. Host manifest gains an
  optional entry for `research.public`. The entry's provider must be
  the canonical `ofloop-research-broker`.

### No-new-operator-ceremony argument

Operationally, the change is:

* **Operator install**: install the canonical broker binary once.
  This is a one-time commissioning step analogous to the existing
  browser / Docker / local-http-service commissioning flow.
* **Operator daily use**: unchanged. The packet author chooses
  `capabilities: ["research.public"]` when needed; otherwise no
  change.
* **Operator during a run**: unchanged. The packet looks like any
  other packet; no URL-by-URL or search-by-search approval popup.

The only new operator surface is `host-capabilities.json` documenting
the broker executable and its commissioning evidence. That entry is
operator-owned, exactly like the Docker broker entry today.

## 6. Authority added (net new capability surface)

* `research.public` capability (commissioned via host manifest;
  same commissioning pattern as `container.docker` and
  `local.http-service`).
* A canonical `ofloop-research-broker` Python executable shipped in
  the same repository (separate file under
  `bin/ofloop-research-broker`), commissioned by the operator on
  install.
* A new `Broker` run-evidence dir under
  `.ownframework-loop/<run-id>/research/`. Writes to this dir are
  authorized only by the broker executable (the worker's Bash
  cannot directly write to it because the dir is `allowWrite`-only
  for the broker's runtime cache mapping and not surfaced to
  Claude's `--allowedTools`).

## 7. Authority still forbidden (preserved)

* `--no-chrome`, `--no-session-persistence`, `--strict-mcp-config`:
  unchanged.
* `--restricted` native isolation: unchanged.
* Bash `strictAllowlist: true`: unchanged. The new capability does
  not widen `allowedDomains`.
* `sandbox.network.credentials` deny list: unchanged. The broker
  inherits the scrubbed subprocess env.
* Bash `sandbox.filesystem.denyRead` on HOME + state root: unchanged.
* Browser `trust_asset` requirement: unchanged. Visual research
  reuses the existing commissioned browser capability.
* External mutation authority (`POST`, `PUT`, `PATCH`, `DELETE`,
  account-creation, payments, deploys, uploads, etc.): explicitly
  **not** granted by `research.public`.
* Docker raw socket / privileged container authority: unchanged.
* Package registry domain authorities: unchanged.

## 8. Security-test surface

The new `tests/unit/test_v200_research_authority.sh` covers the A–AJ
behavioural matrix from the directive. Tests are deterministic and
do not require real network egress: the broker is exercised against
synthetic destinations (loopback, RFC1918 ranges, IPv6 link-local,
cloud metadata endpoints, redirects into forbidden targets, oversized
payloads, malicious-content pages, agent userinfo, non-http schemes).

## 9. Out of scope (deferred)

* Authenticated public research.
* Render-as-screenshot via a host-side render service.
* `research.public.audio` / `research.public.video`.
* Image OCR / visual-diff / automated visual-regression in
  PROGRAM_FINAL.
* Crawling / recursive discovery of a site.

These are deferred not because they are impossible but because each
deserves its own ADR.
