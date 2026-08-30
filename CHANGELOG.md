# Changelog

All notable current-release changes to OwnFramework Loop are documented here.
The complete historical changelog through 0.5.2 is preserved at
[`docs/history/CHANGELOG-through-0.5.2.md`](docs/history/CHANGELOG-through-0.5.2.md).

## 0.8.4 - Night-Shift Durability and Containment (2026-08-29)

A post-closure adversarial sweep exercised failure/containment paths that the
successful 0.8.3 live PROGRAM canary did not.

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

- canonical managed install.sh and uninstall.sh now treat DONE + RETIRED as
  non-runtime-dependent historical enrollment states, matching the dedicated
  supervisor installer;
- retirement additionally refuses unresolved semantic_attempt rows even if the
  job-level worker PID is absent/dead.

### Sealed unattended Claude worker

- commissioned workers require Claude Code 2.1.248+ and use the native `--restricted` shared-machine boundary;
- Bash sandbox is fail-closed with an empty strict network allow-list and
  unsandboxed-command escape disabled;
- user/project/local settings are excluded by `--restricted`; built-in file tools are confined to the pass working directory;
- inherited MCPs are disabled with strict empty MCP configuration;
- builder and reviewer have different native tool sets: builders get Read/Edit/Write/NotebookEdit/Bash/Glob/Grep; reviewers get Read/Bash/Glob/Grep only; no WebSearch/WebFetch, Agent/Task, Skill, browser, or nested orchestration inside the sealed pass;
- historical OFLOOP_CLAUDE_ALLOWED_TOOLS environment tuning cannot widen the
  product-owned semantic tool boundary;
- `--permission-mode dontAsk` plus pre-approved sealed tools and sandbox auto-allow eliminate routine permission prompts without using `bypassPermissions` (which restricted mode intentionally refuses);
- Bash read access denies the operator home except narrow current-pass/runtime re-opens, and subprocess credentials are scrubbed/denied;
- authority-sensitive extra CLI flags are refused before Claude starts.

Research/integrations remain outside sealed BUILD/REVIEW passes. Promotion and
external mutation remain operator-owned outside Loop.

### Regression proof

The canonical v0.8.4 tests fault-inject state/event crash windows, prove
unexplained tampering remains refused, verify authority-bearing state reads,
exercise the worker sandbox/settings/version boundary, prove RETIRED managed
lifecycle parity, and cover unresolved-attempt retirement refusal.

## 0.8.3 - Supervisor Enrollment Retirement (2026-08-29)

### Operator lifecycle for durable historical evidence

The previous 0.8.2 closure correctly failed closed on a preserved historical
QUARANTINED enrollment whose legacy supervisor ledger had no recorded
runtime_generation, but it exposed a real operator-friction defect: the only
way to install a new runtime was the explicit migration override, and that
override only unblocked one install — the same preserved row would block every
future normal refresh forever.

v0.8.3 closes this defect with a narrow, non-destructive supervisor-level
lifecycle:

- a new terminal enrollment status ``RETIRED`` records the operator's
  explicit acceptance of a historical enrollment as evidence rather than work;
- a new operator command ``ofloop supervisor retire <repo> <run-id>``
  transitions ``QUARANTINED -> RETIRED`` and refuses every other source state
  (QUEUEd, BACKOFF, RUNNING, DONE, RETIRED);
- a live or ambiguous semantic worker / attempt refuses retirement;
- retirement preserves the enrollment's ``runtime_generation`` verbatim
  (including legacy empty / UNBOUND), preserves ``total_cost_usd`` and
  ``latest_attempt_id``, preserves every ``semantic_attempts`` row, and never
  touches the target repository, ``.ownframework-loop`` artifacts,
  ``STATE.json``, ``EVENTS.log``, ``APPROVAL.json``, ``WORK_PACKET.md``,
  scratch evidence, or candidate refs;
- the installer generation probe now ignores only ``DONE`` and ``RETIRED``
  rows; QUEUED / BACKOFF / RUNNING / QUARANTINED with a foreign or unbound
  generation continue to refuse install;
- ordinary ``supervisor resume`` refuses ``RETIRED`` with a precise
  ``resume_refuses_retired_enrollment`` diagnostic; the architecture
  intentionally exposes no reactivation command;
- ordinary ``supervisor enqueue`` refuses to reactivate a ``RETIRED``
  enrollment through normal enqueue traffic;
- ``status`` exposes a ``retired_enrollment`` summary that surfaces the prior
  quarantine context and the preserved ``runtime_generation`` for operator
  auditing.

This eliminates the permanent override trap. Normal supervisor replacement no
longer requires ``OFLOOP_ALLOW_RUNTIME_GENERATION_MIGRATION=1`` merely because
a durable historical enrollment exists.

## 0.8.2 - Production Hardening Sweep (2026-08-29)

### Post-adjudication authority closure

- system temporary-directory prefixes are now only genuine external scratch
  allowances; they can never supersede canonical checkout, Loop run-root, or
  builder/reviewer worktree authority when a managed repository itself lives
  under a temporary root;
- canonical negative proofs cover historical/current pass scratch, reviewer
  source, canonical source, builder source, and genuine external scratch in
  temporary-root topologies;
- static unsafe-code findings are release-blocking, and the release gate reports
  STATIC_GATE=PASS only after the checker succeeds;
- installed-parity discovery uses the enabled `of-loop@ownframework` registry
  entry rather than the retired `ownframework-local` cache namespace.


v0.8.2 closes production-readiness defects found in a full source sweep after
the 0.8.1 runtime-generation closure.

### Runtime identity and migration truth

- runtime generations now identify actual serving bytes: clean Git source binds
  the full commit SHA, dirty Git source binds a full SHA-256 content identity,
  and installed/non-Git payloads bind a full path-independent SHA-256 payload
  identity;
- serving-runtime identity failure quarantines before semantic dispatch;
- unfinished legacy rows without a generation fail closed instead of silently
  adopting a new runtime;
- the historical exact $25 / unlimited-token / 8h tuple is preserved and
  flagged as ambiguous rather than silently rewritten;
- supervisor status opens the operational ledger read-only and cannot perform
  schema/data migrations merely because an operator is monitoring;
- a RUNNING job cannot be re-enqueued under a different/unbound runtime
  generation; same-generation re-enqueue remains an explicit operator path for
  updating operational ceilings while preserving worker ownership/backoff.

### Install/uninstall lifecycle safety

- managed install checks unfinished runtime dependencies before plugin cache
  mutation;
- runtime provenance takes ofloop_version from the exact installed payload and
  records source_version separately;
- supervisor replacement restores the previous plist/provenance/service if a
  new launchd bootstrap fails;
- managed uninstall refuses to destroy runtime bytes required by unfinished
  jobs unless the operator explicitly chooses migration;
- payload-manifest generation excludes its own manifest files.

### Semantic-lane hardening

- Write/Edit/NotebookEdit authority is bound to the explicit semantic-context
  run id; cross-run writes are refused and notebook_path is governed;
- active write calls with no path and active Bash calls with no command fail
  closed;
- Write/Edit runtime-cache exceptions are narrowed to the exact active
  repo/run/role cache;
- hermetic validation preserves project-supplied PYTEST_ADDOPTS while appending
  Loop cache-isolation controls.
- the external-action authority layer additionally fences common direct
  remote-effect surfaces (SSH/SCP/SFTP, workflow dispatch/mutation, Terraform
  destructive/state mutation, cloud object/control-plane mutations, and
  mixed-token MCP mutations) without conflating them with the structural Bash
  classifier;
- deterministic build/review validation now applies the external-action authority
  classifier before executing packet-declared shell, closing a core-path bypass
  for mutating remote HTTP outside Claude hooks.

### Proof

Additional production closure hardens commissioned-runtime lifecycle behavior when
the supervisor ledger is missing/unverifiable, aligns reviewer `/**` scope
classification with packet semantics, and ensures a funded whole-run wall budget
also bounds deterministic finalization after a semantic worker returns.

A new canonical production-hardening suite covers byte identity, dirty Git
identity, read-only status, runtime-identity failure, live re-enqueue refusal,
pytest-env compatibility, cross-run/NotebookEdit writes, empty Bash, launchd
rollback, uninstall dependency safety, and manifest self-exclusion. The prior
runtime-generation suite now proves unbound unfinished runs fail closed and
ambiguous historical limits are preserved/flagged.

## 0.8.1 - Runtime-Generation and Authority Closure (2026-08-29)

v0.8.1 closes the four remaining independent-adjudication findings against
0.8.0 without redesigning the architecture. Sealed execution, exact-SHA
review, immediate transitions, final-funded-repair reviewability, and all
human authority boundaries are unchanged.

### Runtime-generation contract (F1)

- every supervisor job row binds the runtime generation that enrolled it
  (`ofloop-<version>@<source-head16>` for git-backed installs,
  `ofloop-<version>@cache-<sha16(root)>` for installed caches);
- `run_one` fails closed (QUARANTINED, classification
  `runtime_generation_mismatch`) when asked to execute a job bound to a
  different generation — a sealed unfinished PROGRAM can never silently
  ride a runtime-generation change between passes;
- legacy unbound rows adopt the serving generation once at first contact
  (initial binding, recorded — never a mid-lifecycle switch);
- install/refresh refuses replacement while any non-terminal enrolled job
  (QUEUED, BACKOFF, RUNNING, QUARANTINED-but-resumable) is bound to a
  generation different from the incoming runtime; terminal (DONE) jobs
  never block a normal install;
- migration stays explicit and clearly unsafe:
  `OFLOOP_ALLOW_RUNTIME_GENERATION_MIGRATION=1` bypasses the generation
  probe; afterwards bound runs fail closed on serve and
  `ofloop supervisor resume` is the operator act that rebinds a run
  (previous binding reported as `runtime_generation_previous`);
- runtime generation is recorded in runtime-provenance.json and surfaced
  in supervisor status/enqueue output.

### Mutating-HTTP fail-closed (F2)

- external_action.py and guards.py now share ONE shell-chain parser
  (`;`, `&&`, `||`, `|`, newline; quote-aware; fd-redirect safe);
- mutating curl/wget forms are classified per segment, so
  `echo ok && curl -X POST https://api.example.com/x`,
  `true || curl ...`, piped and newline-hidden forms are refused;
- destination rule inside governed lanes: provably loopback -> allowed;
  external -> blocked; unresolved (`$URL` after normalization) or absent
  destination -> blocked fail-closed. Explicit localhost development and
  external GET/read research remain fully usable.

### Ledger migration semantics (F3)

- fresh DDL and all migrations now default budget ceilings to DISABLED
  (0); the retired `$25` / 8-hour conservation defaults can no longer be
  injected by schema evolution;
- a one-time `PRAGMA user_version`-gated data migration normalizes rows
  carrying the exact legacy-default fingerprint; explicitly configured
  historical limits do not match the fingerprint and are preserved.

### Run-id observability (F4)

- external-action diagnostics bind the exact semantic-context run id
  (previously the repo path); every non-allow decision is recorded with
  run_id + canonical_repo + tool + decision code;
- block reasons carry `[active run: <run-id>]` for refusal evidence.

### Tests

- `tests/integration/test_v080_runtime_generation.sh`: hermetic
  installer-guard matrix (RUNNING live worker; QUEUED/BACKOFF/QUARANTINED
  generation dependencies; dead-worker cross-check; DONE non-blocking;
  same-generation refresh; explicit migration override), generation
  binding/mismatch/adoption/resume-rebind behavior, and ledger
  default/migration semantics;
- `tests/integration/test_v080_http_mutation_diagnostics.sh`: chained and
  unresolved mutating-HTTP forms fail closed, loopback and read forms
  allowed, shared-parser identity/agreement, and run-id diagnostic
  binding.

## 0.8.0 - Final End-to-End Architecture Closure (2026-08-29)

v0.8.0 is the surgical closure pass adjudicating an independent source
review of 0.7.0. The deterministic Loop model, execution seal, exact-SHA
review, and all human authority boundaries are unchanged. Every fix below
is fail-closed on an authority boundary and behavior-preserving for
legitimate unattended work.

### Authority gates fail closed (findings 1, 5, 6, 12)

- external-action guard: a classifier crash, import failure, missing
  interpreter, empty tool name, or unrecognized decision now yields a
  BLOCK (previously the shell fallback could degrade to ALLOW);
- external-action coverage: gh pr/issue/repo/gist/api mutations,
  npm/pnpm/yarn/cargo/twine/helm/crane publishing, docker/compose push,
  mutating HTTP (curl/wget) toward non-loopback hosts, and compound MCP
  operation names containing any mutating verb are refused; loopback
  mutation (local dev servers, e2e) stays allowed;
- reviewer read-only policy: `git branch` admits listing forms only
  (creation/rename/delete/force-move refused), shell write redirects
  (`> f`, `>> f`, `&> f`, `cmd >& f`) are refused in the reviewer lane
  while `2>`/`2>&1` capture stays allowed, `find -delete/-exec/-ok`
  forms are refused, and the command-chain splitter no longer fragments
  `2>&1` into stray segments;
- spec approve now refuses packets that are not executable under the
  current authority contract (delegated authority / merge_on_approved)
  BEFORE the TTY confirmation gate; schemas keep the legacy values for
  audit parseability of historical packets and document them as
  non-executable;
- dead auto-promotion evaluators (`program.promotion_allowed`,
  `packet.packet_promotion_policy`) are removed; the retired legacy
  orchestrator keeps its explicit-refusal stubs.

### Program ceilings and sealing (findings 2, 4)

- PROGRAM global source ceilings (max_unique_changed_files /
  max_baseline_to_final_diff_lines) are now wired into live execution:
  build finalization re-measures the ABSOLUTE baseline-to-candidate
  accounting at every pass, persists it in the program counters, and
  blocks the run on breach. Additive per-pass accounting (which
  double-counted files touched by multiple passes) is removed;
- build finalization re-proves candidate identity AFTER the packet
  validation commands run (builder HEAD, worktree cleanliness, canonical
  branch pinned at baseline). A candidate or canonical branch mutated by
  validation fails closed to BLOCKED with a `candidate_identity_reproof`
  evidence block in the receipt instead of an opaque finalize crash.

### Repair funding and terminalization (findings 3, 16)

- the final funded repair round always reaches its review: build
  finalization no longer blocks on `repair_round >= cap` (that starved
  the repaired candidate of its earned review). Repair envelopes are
  enforced fail-closed AT CLAIM TIME in both modes; an exhausted
  envelope seals BLOCKED before any unfunded builder pass can start;
- broad `except Exception: pass` around repair/terminal transitions is
  narrowed to tolerate only the idempotent already-at-target case; any
  other FSM failure surfaces instead of silently desyncing the run.

### Supervisor safety (findings 7, 8, 9, 10)

- macOS supervisor install/refresh refuses while a semantic worker is
  live (RUNNING job with alive/unknown worker pid, or non-terminal
  attempt); durable QUEUED/BACKOFF state survives a swap safely. An
  explicit operator override exists for stuck-worker recovery;
- a funded wall ceiling now clamps the timeout of the pass actually
  launched to the remaining wall budget, not only the between-pass
  checks;
- resume preserves the funded wall-clock origin by default
  (`--reset-execution-clock` grants a fresh one explicitly;
  `--keep-execution-clock` remains accepted as a no-op);
- a repeated enqueue preserves every configured operational ceiling;
  only explicit values (including an explicit `<= 0` disable) overwrite
  the envelope. Unspecified envelope arguments are `None` sentinels.

### Schema/envelope/template truth (findings 11, 13, 14)

- v2 packet schema budget maxima now equal the executable runtime
  envelope (max_files_changed 500, max_diff_lines 30000); schema-valid
  packets the runtime refuses are no longer possible;
- the no-progress emergency fuse agrees across default, absolute
  envelope, and both schemas (8);
- templates no longer reintroduce retired architecture: WORK_PACKET.md
  drops the schema-invalid `human_approved` key and uses engine-default
  fuse values; loop.yaml drops the retired polling interval keys.

### Tests

- new negative authority-boundary suite
  (`tests/integration/test_v072_authority_negative.sh`): fail-closed
  hook paths, external-action coverage matrix, reviewer mutation-form
  refusals, non-executable-packet approval refusal, hermetic installer
  live-work guard proof, envelope preservation;
- new execution-closure suite
  (`tests/integration/test_v072_execution_closure.sh`): final-funded-
  repair reachability, claim-time exhaustion sealing, identity-reproof
  BLOCKED path, PROGRAM ceiling enforcement with absolute accounting,
  wall-time clamping, schema/envelope agreement probes;
- new disposable semantic-canary harness (`tests/canary/`) for a future
  deliberate real-model test; it prepares only and never touches the
  live supervisor.

## 0.7.0 - Final Autonomy Architecture Pass (2026-08-29)

v0.7.0 is the final surgical architecture pass before sealed PROGRAMs run
fully unattended. The deterministic Loop model, execution seal, exact-SHA
review, and all human authority boundaries are unchanged. What changes is
everything that accidentally stopped, slowed, or crippled unattended
engineering progress.

### Budget and limit model (no accidental global stops)

- token ceilings remain disabled by default; cost ceilings are now disabled
  by default too (`--max-cost-usd <= 0`); unattended runs are bounded by
  pass/repair caps, no-progress detection, the new identical-finding
  repetition fuse, and failure-class retry policy, not by resource
  conservation;
- `supervisor enqueue` now consumes packet `risk_budget.max_runtime_seconds`
  as the operational wall-clock envelope (previously validated but never
  used). Without a declared envelope or explicit flag, no wall-clock ceiling
  applies. Explicit operator flags always win;
- v3 programs may declare up to 2,419,200 s whole-run and 28,800 s per-pass
  runtime envelopes; the v2 single-run pass ceiling is raised to 7,200 s so
  packets can no longer only narrow below the 3,600 s fallback;
- the 3,600 s per-pass fallback fuse is preserved for both modes as
  stuck-worker protection; long PROGRAM passes fund wider budgets through
  risk_budget.max_pass_runtime_seconds;
- unknown model cost no longer quarantines a run unless a cost ceiling is
  active (live completion and crash recovery both record COST_UNKNOWN at
  zero and continue).

### Repair continuity (no dead-end quarantines)

- repair context now resolves from two deterministic sources: a fresh
  CHANGES_REQUESTED review verdict, or the BUILD_RECEIPT evidence when the
  deterministic build finalizer itself routed the run back for failed
  required validation. A stale verdict after a post-review validation
  failure no longer raises a dispatch invariant error (which hard-quarantined
  the run unrecoverably);
- cap-exhausted build/review claims seal the run BLOCKED (a legitimate
  engineered terminal) and dispatch converts the sealed state to TERMINAL,
  so the supervisor completes cleanly instead of looping quarantine/resume.

### No-progress protection

- the previously declared-but-dead identical-finding fuse is now enforced:
  a verbatim-repeating must-fix set across consecutive reviews BLOCKs at
  `risk_budget.max_identical_finding_repeats` (default 8). The streak resets
  on PROGRAM checkpoint advancement.

### Transition immediacy

- foreground lane markers no longer insert 10-minute idle gaps between a
  completed build and an available review (or vice versa): cross-role ready
  states reschedule with zero delay; AWAITING_APPROVAL is STARTABLE for the
  builder lane (never STOP) and WAIT for the reviewer lane.

### Worker capability and authority boundary

- the protected-paths write guard now uses the v0.6.1 explicit
  execution-context contract; the stale `.ownframework-loop/` ancestor
  heuristic no longer blocks ordinary operator/maintenance sessions. In-lane
  allowances add the supervisor runtime-cache root and system scratch dirs;
- reviewer lanes may now run the project's validation toolchain (pytest,
  npm/npx/pnpm/yarn/bun/node/deno, make/cmake/ctest, just, cargo/rustc, go,
  mvn/gradle/java, uv/pip/poetry/pdm, docker, curl/wget, common local DB
  CLIs, playwright). Source mutation remains impossible: git mutation
  commands stay outside the allowlist, forbidden patterns still apply, and
  the finalizer still refuses a verdict from a non-clean reviewer worktree;
- the allowed tool surface adds NotebookEdit and task-management tools
  alongside the existing Agent/Skill delegation surface;
- the external-action guard now intercepts MCP tool calls in semantic lanes:
  read-only MCP verbs pass, unknown/mutating verbs are refused, so
  operator-granted MCP access stays inside the external authority boundary;
- registry publishing joins the forbidden list for all lanes: docker push,
  docker compose push, npm/pnpm/yarn publish, cargo publish, twine upload.
  Local container orchestration for dev services remains legitimate;
- stale documentation claiming local `docker compose up` was forbidden is
  corrected to match the actual policy.

## 0.6.3 - PROGRAM Autonomy Preflight + Worker Headroom (2026-08-29)

v0.6.3 closes integration gaps surfaced by the first real unattended
client-shaped PROGRAM before another model pass can waste time on them.

### Pre-execution contract hardening

- v3 schema and runtime agree on 500 changed files / 30,000 diff lines;
- impossible risk budgets are rejected at packet validation, before first model
  execution;
- checkpoint acceptance scoping uses acceptance_criterion_ids; the stale
  acceptance_criteria checkpoint key is rejected;
- v3 packet-wide cumulative build/review/repair envelopes may be up to 128 so
  long PROGRAMs can fund checkpoint-local repair budgets;
- global repair allowances must be realizable by the global build/review
  envelope.

### Semantic worker capability

- the Claude reference runner now includes Agent and Skill, allowing bounded
  subagent delegation when it materially improves a pass;
- builder/reviewer prompts make fresh-context semantics explicit and keep one
  parent responsible for the coherent artifact;
- custom-agent maxTurns is raised to 160 for foreground/custom-agent use;
- the unattended main print-mode runner still has no CLI max-turn cap;
- v3 max_pass_runtime_seconds is now enforced by the supervisor and may be up
  to 14,400 seconds; a supervisor CLI timeout can only narrow it.

### Monitoring

- supervisor status adds worker/execution elapsed time, time since last job
  update, worker-log byte/mtime activity, and packet pass-time policy on top of
  existing attempt/core/worktree/diff telemetry.

### Release truth

Canonical source, Claude plugin metadata, marketplace metadata, README,
SECURITY, and this changelog report 0.6.3.

## 0.6.2 - Scope Suffix Compatibility (2026-08-29)

v0.6.2 closes a pre-execution packet-scope mismatch surfaced by a real
client-shaped PROGRAM specification.

### What changed

- packet scope remains deterministic prefix matching, not arbitrary globbing;
- a single trailing `/**` is now accepted as an exact compatibility spelling
  for the same directory prefix (`apps/**` == `apps`);
- arbitrary wildcard forms such as `apps/*` or interior glob syntax are
  rejected by packet metadata validation rather than silently accepted;
- allowed, protected, elevated, and sensitive path classification now share
  the same scope-entry semantics;
- this prevents a packet that visibly authorizes `apps/**` from later
  classifying `apps/web/...` as out-of-scope at deterministic finalization.

No authority is widened: `dir/**` authorizes exactly the same subtree as
`dir`. Existing literal file and directory-prefix declarations retain their
prior behavior.

### Release truth

Canonical source, Claude plugin metadata, marketplace metadata, README,
SECURITY, and this changelog report 0.6.2.

## 0.6.1 - Semantic Build Finalizability Recovery (2026-08-28)

v0.6.1 is a behavior-preserving bugfix line that closes a real unattended
commissioning seam surfaced by a live practice run.

### What changed

A `BUILD_AGENT_RESULT.json` that is structurally complete is now REQUIRED to
be paired with a structurally finalizable builder worktree before the
dispatch layer will report `semantic_result_ready`. A complete semantic
artifact over a dirty worktree (e.g. uncommitted modifications, generated
out-of-scope artifacts left as untracked state) is no longer replay-finalized
across retries; instead the supervisor dispatches a fresh semantic builder
for the SAME claimed pass — same run id, same pass number, same checkpoint,
same candidate branch, same worktree, same semantic artifact path.

The deterministic builder finalize still refuses dirty worktrees by design
and that refusal is preserved as-is.

The builder role contract (`agents/of-builder.md`) was surgically hardened so
that `outcome_requested: candidate_ready` cannot legitimately mean
"semantic work complete but filesystem still dirty." A required
pre-`candidate_ready` checklist now requires `git status --porcelain` to be
empty in the exact supplied builder worktree, with a generic invariant that
applies to arbitrary toolchains (npm/package-lock.json, pip hash files,
Cargo.lock, poetry.lock, go.sum, gradle caches, `.pytest_cache`, `__pycache__`,
`dist/`, `build/`, `target/`, etc. are examples, not the rule).

The supervisor recovery contract preserves zero-model crash replay
(`COMPLETE semantic artifact + clean/finalizable worktree` -> deterministic
replay finalize, cost $0, no new semantic worker) and changes only the
dirty-worktree path (`COMPLETE semantic artifact + dirty/non-finalizable
worktree` -> fresh semantic builder for the SAME pass, no new pass, no
new candidate branch, no increment to `repair_round`, no fabrication of
`CHANGES_REQUESTED` or `BLOCKED`).

The deterministic core remains deterministic: it does not auto-stage,
auto-commit, or silently clean the builder worktree. The semantic builder
owns engineering filesystem correction; the core owns finalization refusal.

Sealed `WORK_PACKET.md` immutability is preserved: the packet's
`allowed_paths` cannot be widened after execution seal to repair an
incident like this one. Changed scope after sealing requires a new run.

### Operational retry and usage telemetry

A real PROGRAM benchmark exposed that the supervisor's original operational
retry policy treated every non-successful runner result as the same failure
class. v0.6.1 now keeps engineering truth unchanged while making the execution
clock more informative and less brittle:

- classified transient provider/network failures have an independent bounded
  retry streak and exponential backoff;
- obvious runner configuration failures and deterministic dispatch/invariant
  refusals quarantine immediately instead of burning three indistinguishable
  retries;
- ordinary unclassified runner failures retain the conservative infrastructure
  retry ceiling;
- status exposes the latest five semantic attempts, durable log paths, failure
  class/reason, and a direct quarantine reason;
- status now makes isolated candidate work visible without changing promotion:
  canonical checkout identity, exact builder/reviewer worktree identity and
  cleanliness, candidate branch, and a bounded local diff summary are returned
  as read-only evidence;
- provider-reported input/output/cache token telemetry is accounted exactly
  once under the same semantic-attempt identity fence as model cost;
- fresh repair builders receive deterministic context from the exact prior
  `CHANGES_REQUESTED` review verdict (failed acceptance results, findings,
  validation evidence, failure reason, and reviewed candidate SHA), so the
  model can reason from the reviewer evidence instead of rediscovering it;
- an optional per-run token ceiling is available without making token telemetry
  an authority source; unknown token usage fails closed only when that ceiling
  is explicitly enabled.

This changes only operational scheduling/telemetry. BUILD/REVIEW authority,
checkpoint progression, candidate identity, review verdicts, and promotion
remain owned by the deterministic core.

### Autonomous runner readiness

A second source sweep removed an unnecessary operator-recovery seam around
launchd runner availability. Unpinned services now wait automatically when the
Claude CLI is temporarily absent, without creating semantic attempts, consuming
retry counters, or starting the operational wall clock. The service rechecks
and continues automatically when Claude becomes discoverable. Explicitly
commissioned OFLOOP_CLAUDE_BIN remains fail-closed and never falls back to a
different executable.

This is operational self-healing only; it does not change packet authority,
engineering passes, review evidence, or promotion.

Known-cost classified provider/network outages now also have a bounded circuit
breaker. The ordinary transient streak still applies; after it is exhausted,
Loop can cool down for 10 minutes and retry automatically for two recovery
cycles by default. The circuit never resets model cost, token usage, or the
run wall-clock ceiling, and exhaustion still ends in quarantine.

On macOS, canonical `install.sh` now also refreshes an already-commissioned
launchd supervisor to the newly installed cache payload. It never creates a
background service implicitly, and the supervisor installer accepts a separate
source-provenance root so installed runtime identity and Git source SHA remain
both explicit.

### PROGRAM checkpoint acceptance scoping

The final unattended rehearsal exposed a PROGRAM friction point: every
checkpoint historically had to semantically cover every top-level acceptance
criterion, including criteria belonging to future checkpoints.

v0.6.1 now supports optional checkpoint `acceptance_criterion_ids`:

- top-level acceptance criteria remain the frozen mission contract;
- once checkpoint scoping is used, every checkpoint declares a non-empty
  AC-id list and their union covers the full packet AC set;
- BUILD/REVIEW work orders surface the current checkpoint and exact AC ids;
- semantic readiness and deterministic review finalization enforce that same
  scoped set;
- REVIEW_VERDICT records the checkpoint and exact expected AC ids;
- legacy PROGRAM packets without mappings preserve historical behavior.

This removes the need for fake `not_applicable` results or one giant shared
criterion without changing checkpoint ordering, exact-SHA review, budgets,
authority, or promotion.

### What did NOT change

- The v0.6.0 release tag and GitHub Release were not modified.
- v0.6.0 commissionining evidence is unaffected.
- Finalizer dirty-worktree enforcement is unchanged.
- Repair-round counter, candidate branch, and checkpoint semantics are
  unchanged for legitimate reviewer feedback flows.

## 0.6.0 - Durable Supervisor Architecture (2026-08-28)

- Replaced the legacy `ofloop loop run` unattended orchestrator with a
  typed dispatch boundary (`lib/ownframework_loop/dispatch.py`) and a
  durable supervisor (`lib/ownframework_loop/supervisor.py`).
- One fresh Claude Code process per semantic BUILD or REVIEW pass.
- Vendor-neutral semantic-runner registry; `claude-code` is the first live
  implementation.
- SQLite is operational truth only: queue, retries, backoff, worker PID,
  cost attempts, operational ceilings.
- Required-validation shell authority is mechanically classified before
  execution.
- Exact-once model-cost accounting via stable attempt digests.
- Crash/restart reconciliation preserves live workers and requeues dead
  ones without duplicating a pass.
- macOS launchd installer pins exact runtime executables (Python, ofloop,
  Claude) and persists a runtime provenance record.
- Promotion policy enforced as `human_gate`; `external_action_authority`
  must be `none`; `merge_on_approved` is retired from current execution.
- CLI: `ofloop dispatch claim|finalize`, `ofloop supervisor
  enqueue|status|serve|resume`.

## 0.5.4 - Public Architecture Consolidation (2026-08-28)

This release consolidates the no-ceremony execution-seal architecture into one
runtime and one public contract before the first real 11-checkpoint benchmark.

### Runtime hardening

- `execution_start.ensure_executable()` now routes both new-seal and
  existing-seal activation through one `_activate_sealed_run()` helper.
- Activation transition failures are no longer swallowed. A partial start leaves
  durable seal/PROGRAM evidence and returns failure; retry validates/reuses that
  evidence and completes activation.
- Git tracked/staged cleanliness inspection fails closed if the underlying
  `git status` probe itself fails.
- Existing spec-time baseline, execution-seal immutability, exact-source binding,
  and legacy no-snapshot refusal remain intact.

### Behavioral pressure tests

- Added canonical v0.5.4 execution-start pressure coverage for activation fault
  propagation/recovery.
- Added real concurrent first-start proof with both process return codes,
  fresh+replay behavior, one seal, and one build pass.
- Added real concurrent single-mode build and review claim proofs requiring both
  processes to succeed and exactly one pass to be consumed.
- Added a canonical public-contract truth gate so active docs/skills cannot
  silently reintroduce mandatory approval wording or the obsolete fixed builder
  semantic-result path.

### Public architecture truth

Active public documentation now describes one normal workflow:

```text
/of-loop:spec <mission>
→ /loop /of-loop:build <run-id>
→ /loop /of-loop:review <run-id>
→ APPROVED | BLOCKED | STOPPED
→ operator promotion outside Loop
```

Normal operation requires no separate approval command, confirmation token,
manual PROGRAM initialization, manual claim/finalize plumbing, or checkpoint
babysitting.

The historical `APPROVAL.json` filename and `tty_confirmation` method remain
compatibility surfaces. New runs normally use
`approval_method=build_start` / `binding_kind=execution_seal`.

Security documentation also states the actual guarantee: host command guards
are mechanical tool-surface rails, not an OS sandbox for arbitrary same-user
code. A coding agent must never intentionally route around a guard refusal.

### Adapter and portability cleanup

- Core invariants, adapter contract, portability model, capability matrix, Agent
  Skills doctrine, adapter-development guide, and adapter index now share the
  same execution-sealed protocol terminology.
- Generic CLI documentation consumes deterministic preparation outputs and the
  exact pass-scoped `agent_result_path`; the old fixed
  `scratch/builder/BUILD_AGENT_RESULT.json` contract is removed.

### Release truth

Canonical source, Claude plugin metadata, marketplace metadata, README,
SECURITY, and this changelog report 0.5.4. Historical release notes remain
preserved under `docs/history/`.

## Historical releases

For 0.5.2 and earlier release notes, see
[`docs/history/CHANGELOG-through-0.5.2.md`](docs/history/CHANGELOG-through-0.5.2.md).
