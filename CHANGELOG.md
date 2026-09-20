# Changelog

All notable source/master release-line changes to OwnFramework Loop are documented here.

**Publication authority:** the immutable Git tag together with its corresponding
GitHub Release. Static source documentation does not claim live "latest
published release" state. Historical release **v0.9.1** remains frozen at
`d23cadca751c9ed37b5eeab25415c8b0574dae4e`. **v0.8.4**
(`134a7ce543e2d5858b3a4613c49d49959fe0b029`) remains the
immutable historical baseline of the previous published line.
The complete historical changelog through 0.5.2 is preserved at
[`docs/history/CHANGELOG-through-0.5.2.md`](docs/history/CHANGELOG-through-0.5.2.md).

## 1.0.0 - Stable Autonomous Engineering Runtime (2026-09-19)

- Deterministic packet and source authority with exact execution binding and
  exact-SHA build/review evidence.
- Durable autonomous supervisor with PROGRAM checkpoint progression and
  zero-routine-ceremony execution between human SPEC and human promotion.
- Crash/recovery safety and exact-once semantic attempt, cost, token, and replay
  accounting across bounded retries and repairs.
- Host capability and runtime-generation binding with fail-closed identity,
  sandbox, and commissioned-runtime checks.
- Whole-product PROGRAM final review, bounded repair continuity, and terminal
  truth that never turns APPROVED into autonomous promotion authority.
- Claude Code remains the stable, live-verified unattended semantic runner;
  the Generic CLI remains the portable vendor-neutral contract.
- Codex remains experimental/static-distribution proven with
  `CODEX_LIVE_VERIFIED=no`; no live certification is claimed.
- Source version truth is now independent from publication state: immutable Git
  tags plus GitHub Releases are publication authority.
- Release-candidate preparation changes version/publication surfaces only;
  runtime behavior, schema, FSM, packet contracts, and operator ceremony remain
  unchanged.

## 0.10.0.dev0 - Architectural Consolidation (in-progress, 2026-09-18)

- Source-quality consolidation; no product behavior change, no
  schema bump, no packet bump, no commissioning semantic change,
  no FSM change. Behavior-freeze preserved.
- macOS commissioning implementation extracted from install-macos.sh
  heredocs into scripts/supervisor/install_helpers.py
  (typed result classes, lifecycle-primitive drivers, classification
  helpers). Shell now delegates publication-files generation;
  v091m/v091n commissioning tests pass unchanged.
- finalize_proof.py: shared deterministic proof primitives
  (read_json, candidate_branch_contains, ancestor_of,
  path_in_list, classify_path_against_packet, strict_ceiling)
  extracted from build_finalize.py and review_finalize.py.
  Both finalizers now delegate to the canonical shared module.
- docs/architecture/IMPLEMENTATION_CONSOLIDATION.md: source
  map of supervisor.py / program.py / cli.py / dispatch.py /
  capabilities.py / state.py / build_finalize.py /
  review_finalize.py / install-macos.sh at the start of the
  consolidation series, with the authority boundaries the next
  refactor commits will extract.
- docs/certification/evidence: corrected historical evidence for
  greenfield cert (job 64, candidate SHA
  f075e638ff84d660d2904a4bbf5cd54db35ccb8b, reviewer verdict
  APPROVED, total cost ~$8.18) and mature R2 cert (CERT_TIME_
  OUTCOME = supervisor non-progress, LATER_PRESERVATION_STATE =
  QUARANTINED via runtime_generation_mismatch).
- New tests: test_v10a_install_helpers.sh (lifecycle driver +
  classification coverage) and test_v10b_finalize_proof.sh
  (shared primitives).
- Version-truth: source version is now **0.10.0.dev0** to
  distinguish development master from the FROZEN v0.9.1
  release tag.

## 0.9.1 - Host Capability Runtime (2026-09-01)

## 0.9.1 - Host Capability Runtime (2026-09-01)

- packets may declare portable semantic `capabilities`; the trusted runtime
  resolves exact host executables, versions, read/write paths and derived
  network authority before the model starts;
- every semantic attempt receives an immutable capability-resolution receipt
  referencing a run-level `CAPABILITY_BINDING.json`; stable capability,
  host-manifest, network, privileged-canary and runner-profile identity is
  exact-matched before every later model launch;
- `ofloop capabilities probe|preflight|fingerprint|profile|commission`
  exposes host inventory, named runner profiles, and trusted privileged-canary
  commissioning without a semantic model call;
- HOME remains broadly denied and tools discovered under HOME now require
  explicit operator commissioning instead of relying on contradictory PATH
  discovery;
- per-pass scratch is separated from durable repository-scoped package/browser
  caches, preventing repeated downloads without introducing cross-client
  writable-cache poisoning;
- privileged `container.docker` is broker-only: direct daemon sockets,
  inherited Docker/Kubernetes/agent IPC selectors, and unsandboxed Docker
  exceptions are never granted; conventional Docker/Podman/containerd daemon
  sockets are explicitly denied and the Bash guard requires the resolved
  privileged capability marker before Docker invocation, including common
  shell-wrapper forms;
- `local.http-service` is explicit and unavailable until a safe local-binding
  provider is commissioned/proven for the exact host runtime;
- privileged/local authority requires core-receipted trusted canary evidence
  bound to platform/architecture/Claude runtime, provider/broker identity and
  executable digests; a copied runtime fingerprint alone is insufficient;
- trusted named runner profiles can select only model/effort, are frozen into
  run identity, and cannot override sandbox/tool/MCP/session authority;
- funded supervisor runs propagate their exact remaining durable cost ceiling
  to Claude's native print-mode per-pass budget while aggregate Loop accounting
  remains canonical; reviewer tool caches remain pass-ephemeral;
- capability-resolution failures are terminalized as proven pre-provider
  semantic attempts instead of leaving a reserved attempt for stale recovery.

### Final-frontier seam repairs (post-publication 2026-09-02)

A post-publication adversarial seam sweep repaired five confirmed defects
without changing the frozen architecture:

- TOKENS_UNKNOWN terminalization now accounts the completed semantic attempt
  exactly once (live and crash-recovery paths): a proven provider cost lands
  in the durable ledger before quarantine, an unproven cost records honest
  `cost_known=0`, and the historical-cost gate counts TOKENS_UNKNOWN attempts
  so a funded cost ceiling still fails closed after resume;
- the authoritative secret scanner never follows symlinks; a changed symlink
  is scanned as its candidate bytes (the git-stored target path) instead of
  host bytes the candidate does not contain;
- a vanished/unreadable capability binding fails closed as
  `CapabilityBindingError`, and receipt reads translate binding failures into
  `CapabilityResolutionError` so replay/strict-profile gates keep their
  contractual refusal classification;
- the external-action guard honors the same `OFLOOP_PLUGIN_ROOT` fallback as
  its sibling guards, removing an inconsistent all-refuse posture for
  adapter/foreground lanes;
- capability-binding publication tightens a pre-existing run directory to
  private mode, matching the managed cache-root contract.

### Terminal source hardening

- semantic replay is authorized only after durable resource accounting and an
  explicit acceptance publication bound to the exact semantic artifact digest
  and role-specific candidate identity; drifted bytes or candidate identity
  fail closed without a second semantic charge;
- preflight output carries the same proved effort-attestation identity used at
  launch and marks explicit manifest/profile overrides as diagnostic rather
  than launch-parity evidence;
- redacted secret scanning refuses unreadable or oversized inputs instead of
  collapsing unknown scan state into a clean result;
- browser runtime proof binds the top-level Playwright version to the verified
  installed distribution identity and rejects contradictory proof;
- source authority, recovery, claim ownership, cost accounting, capability
  binding, browser identity, runner-profile truth, secret scanning, worktree
  ownership, and state/event integrity remain covered by the canonical
  multi-platform release gate.

### Public contract and runner normalization

- durable supervisor runner availability is now explicit and distinct from
  adapter installation; unsupported `--runner` values are refused before a
  job row can be created, while Codex remains an experimental foreground
  Agent-Skills adapter rather than an implied unattended runner;
- commissioned Claude model selection is documented as packet/profile truth:
  restricted workers do not inherit interactive `settings.json`; named
  operator profiles bind explicit model/effort policy before provider launch;
- Claude and Codex coordinator skills are parity-gated on critical authority
  doctrine so duplicated host UX cannot silently drift;
- packet examples are executable documentation validated by the current packet
  admission path, including a modern v3 PROGRAM example with checkpoint-scoped
  acceptance and runner/capability declarations.

### Repository hygiene

- operator-facing adapter and supervisor lifecycle commands live under `bin/`;
  platform-specific service implementations live under `scripts/supervisor/`;
  repository root retains only the deliberate core install, uninstall,
  validation, and release-gate entrypoints;
- maintained docs, templates, scripts, and tests now have explicit indexes;
  one-off implementation reports and retired policy examples are absent from
  the active repository surface while provenance-bearing regression names are
  retained.

## 0.9.0 - Bounded Multi-Repository Autonomy (2026-08-31)

Development line for bounded single-host multi-repository execution. Release
publication remains gated on deterministic tests, exact-head CI, and real
commissioning at N=4.

## 0.8.4 - Autonomous Runtime Portability and Containment (2026-08-30)

A post-closure adversarial sweep exercised failure/containment paths that the
successful 0.8.3 live PROGRAM canary did not.

### Vendor-neutral runtime topology

- `install.sh` now owns a versioned vendor-neutral OwnFramework Loop core;
  Claude/Codex integrations are optional adapters installed independently;
- the durable supervisor is commissioned from that core rather than a Claude
  plugin cache;
- `install-supervisor.sh` selects launchd on macOS or systemd-user on Linux;
- both platform installers use one shared read-only runtime-dependency probe for
  live-work and runtime-generation replacement safety;
- installed-core discovery/validation resolves from the managed `ofloop`
  launcher rather than an agent/plugin registry;
- Linux Claude commissioning proves Claude Code >=2.1.248, bubblewrap, socat,
  and a usable native sandbox before starting unattended work;
- adapter uninstall preserves the core; supervisor uninstall preserves
  ledger/evidence while removing service provenance.

### Dead-surface and runtime hygiene

- removed the retired pre-0.6 `ofloop loop run` orchestrator/parser;
- removed deprecated `build write-receipt` and `review write-verdict` parser
  stubs; deterministic finalize remains the sole receipt/verdict path;
- removed the legacy Claude skills-directory `rollback.sh` root command;
- verified recovery removes a dead `.EVENTS.log.append.tmp` under the run
  flock;
- durable DONE performs/retries disposable runtime-cache GC while QUARANTINED
  cache and durable worker/attempt evidence remain preserved.

### Crash-atomic protocol state

- STATE.json + EVENTS.log mutations now use a per-run write-ahead
  STATE_TXN.json intent and deterministic recovery;
- standalone EVENTS.log append is atomic old-or-new rather than an in-place
  JSONL tail write;
- critical semantic/execution call sites consume verified state instead of raw
  STATE.json bytes;
- caller event extras may not overwrite run/state/event-chain identity or spoof
  the internal state_txn_id recovery marker.

### Supervisor lifecycle parity

- the shared runtime-dependency probe treats DONE + RETIRED as
  non-runtime-dependent historical enrollment states for core install,
  launchd/systemd commissioning, and removal;
- retirement additionally refuses unresolved semantic_attempt rows even if the
  job-level worker PID is absent/dead.

### Sealed unattended Claude worker

- commissioned workers require Claude Code 2.1.248+ and use the native `--restricted` shared-machine boundary;
- Bash sandbox is fail-closed with a strict packet-bound network read
  allow-list (empty by default) and unsandboxed-command escape disabled;
- optional `network_read_allowlist` is frozen SPEC authority and maps directly
  to Claude's native `sandbox.network.allowedDomains`; exact hostnames only,
  no runtime prompt/widening;
- user/project/local settings are excluded by `--restricted`; built-in file tools are confined to the pass working directory;
- inherited MCPs are disabled with strict empty MCP configuration;
- builder and reviewer have different native tool sets: builders get Read/Edit/Write/NotebookEdit/Bash,Glob,Grep;
