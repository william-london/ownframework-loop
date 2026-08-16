# Changelog

## 0.4.0 — Agent-Agnostic Core (2026-08-10)

**Scope.** OwnFramework Loop is now structured as a deterministic, human-gated engineering protocol with agent-host adapters. Claude Code remains the stable reference adapter and preserves the public v0.3.8 command/install experience.

**Agent-neutral protocol**

- Added a public adapter contract and capability model separating deterministic core authority from host-specific agent UX.
- Added portable Agent Skills under `.agents/skills/` for spec, build, review, and status.
- Added deterministic `ofloop adapter list/show/doctor` inspection without provider API calls or credential ownership.
- Added adapter conformance tests that enforce vendor-neutral core imports and preserve the stable Claude skill/plugin surface.

**Claude Code compatibility**

- Claude Code remains the stable/reference adapter with `of-loop@ownframework`, `/of-loop:spec`, `/of-loop:build`, `/of-loop:review`, custom agents, and native hooks.
- The Claude Bash guard now explicitly blocks agent invocation of the human-only `ofloop spec approve` command during an active run.

**Codex portability**

- Added an experimental Codex adapter surface using the portable Agent Skills plus repository `AGENTS.md`.
- Codex remains `hardened=false` and `live_verified=false` until a real Codex environment proves discovery and a disposable lifecycle. Static files alone are not treated as live support.

**Cross-platform approval correction**

- Interactive approval now recognizes standard Linux `/dev/pts/N` terminals in addition to macOS/BSD and Linux console TTY families.
- Documentation now states the correct security boundary: TTY confirmation is the portable interactive operator mechanism, while hardened adapters separately block agent invocation of the approval command.

**CI / contributor surface**

- Added Linux + macOS GitHub Actions coverage across Python 3.12 and 3.13, adapter conformance, portability/doctor checks, and Gitleaks.
- Added public adapter-development documentation so future host integrations can reuse the same core rather than fork the state machine.

**Non-goals.** v0.4.0 does not add automatic cross-vendor agent spawning, an always-on orchestrator, provider credential storage, or loop-owned push/merge/deploy authority.


## 0.3.8 — First Public Release / Distribution & Release-Gate Hardening (2026-08-10)

**Scope.** This is a packaging and distribution hardening pass over the
0.3.7 public-release commit. No core state-machine, packet-binding,
exact-SHA review, or authority semantics have changed.

**Distribution hardening**

- **Self-contained public marketplace.** This repository now ships its
  own `.claude-plugin/marketplace.json` declaring a marketplace named
  `ownframework` with a single plugin entry `of-loop`. A first-time user
  no longer depends on a parent repository, sibling catalog, or any
  private OwnFramework infrastructure.
- **Rewritten `install.sh`.** The installer registers the marketplace
  pointing at the local clone (`claude plugin marketplace add <path>`)
  and installs through the official plugin manager
  (`claude plugin install of-loop@ownframework --scope user`). The
  previous `ownframework-local` marketplace name and the implicit
  `~/.claude/skills/of-loop` skills-dir copy are no longer assumed.
- **Rewritten `uninstall.sh`.** The uninstaller removes the plugin
  via the official plugin manager and optionally removes the
  marketplace registration (`REMOVE_MARKETPLACE=1`).
- **`rollback.sh` scoped to its actual support surface.** The script
  now documents that it only restores timestamped skills-dir backup
  directories produced by historical versions of the installer. For
  managed installs, the canonical rollback is to install a different
  version through the marketplace.

**Release-gate hardening**

- **`lib/ownframework_loop/release_gate_runtime.py` preflight repaired.**
  The expected release branch now defaults to `master` (was `main`).
  Remote presence is no longer a preflight failure condition; the
  reported `SOURCE_REMOTES` field reflects the actual remote count.
  Dirty source and a wrong release branch still fail closed. The
  `OFLOOP_RELEASE_GATE_EXPECTED_BRANCH` environment variable overrides
  the default branch.
- **Five-test preflight regression.** `tests/integration/test_release_gate_preflight.sh`
  was added and added to `tests/canonical.txt`. It proves clean-master
  + remote-OK PASSES, dirty FAILS, wrong-branch FAILS, override WORKS,
  and multi-remote does not fail.

**Public-surface cleanup**

- README, AGENTS.md, and all current-facing docs have been re-scanned
  for stale `OwnFramework Loop V1` / `OwnFramework Loop V2` generational
  branding; all hits have been replaced with the timeless
  `OwnFramework Loop` name. Version-marker code comments and
  CHANGELOG history were preserved.
- AGENTS.md no longer references a private-mission "Phase 10 evidence"
  section; the public-leak scan instruction is now self-contained.
- The root-level `REPORT.md` and `LOOP_REPAIR_MISSION_REPORT.md` have
  been removed; their byte-identical copies remain in
  `docs/history/` with a `docs/history/README.md` explaining their
  preserved-engineering-snapshot status.
- `THIRD_PARTY_NOTICES.md` no longer claims a "clean-room
  implementation"; it states the factual relationship with the
  upstream Finn-loop project and retains the required MIT attribution.
- The root `LICENSE` is the canonical Apache License 2.0 text from
  apache.org, verbatim. The customized Appendix boilerplate is gone;
  no `NOTICE` file was added.

**Version surfaces updated to 0.3.8**

- `.claude-plugin/plugin.json`
- `.claude-plugin/marketplace.json`
- `lib/ownframework_loop/__init__.py` (`__version__`)
- `README.md` project status
- `SECURITY.md` supported release posture

## 0.3.7 — Plumbing-Autonomy Closeout (2026-08-02)

**Highlights** (seven narrow plumbing repairs; large real-repository testing remains a separate exercise):

- **Repair 1 (F-1-01) — PROGRAM checkpoints**: `state.program_transition()` no longer calls `set()` on the dict records that `finalize_checkpoint()` stores. Checkpoint IDs are extracted explicitly from `{fc["id"]}` with `isinstance(fc, dict)` / `isinstance(cid, str)` guards. The bare `except Exception` that silently swallowed the TypeError and forced `has_more_cps=False` (which broke the program-mode APPROVED → READY_TO_BUILD escape hatch after the first checkpoint) is removed. The frozen approved checkpoint graph is preserved, dependency-ready checkpoints are selected deterministically, and the run advances automatically after a checkpoint finalizes.
- **Repair 2 (F-2-01 / F-2-02 / F-2-03) — Monotonic terminal precedence**: `STOPPED` is absorbing at the FSM level (no single-mode or program-mode escape). `BLOCKED` cannot transition to `APPROVED` in either mode. `APPROVED` is reachable only from a legal review state. `transitions.assert_valid_program()` gains a `bound_candidate_sha` keyword that pins the transition to the exact candidate SHA, preventing stale or overwritten candidates from being re-approved.
- **Repair 3 (F-3-01) — Per-packet repair ceiling**: `limits.packet_lowers_cap()` no longer raises when the packet declares a budget higher than the V1 emergency cap. `MAX_REPAIR_ROUNDS` (and the build/review/no-progress siblings) is now an emergency fuse (`32`), not a floor. `effective_cap()` precedence is: packet override → `util.ABSOLUTE_BUDGET_CEILING` → V1 fuse. The absolute ceiling was raised to `32` so values 2 / 6 / 12 / 25 all work; `MAX_CP_REPAIR_ROUNDS` and `work-packet.schema.json` were lifted in lockstep.
- **Repair 4 (F-4-01) — Progress-sensitive continuation**: `build_finalize` no-progress comparison now uses the full candidate SHA (`last_candidate != candidate_sha`) instead of the lossy 7-character prefix. Productive passes (any new SHA) continue indefinitely; only identical-no-progress stops at the configured threshold (default `limits.MAX_CONSECUTIVE_NO_PROGRESS_PASSES=8`).
- **Repair 5 (F-5-01) — Substantial builder passes**: `of-builder` and `skills/build/SKILL.md` document that a single pass may produce multiple files, multiple commits, or a coherent subsystem so long as `risk_budget` is honoured. The cap is the packet budget, not a per-pass file count.
- **Repair 6 (F-6-01) — `ofloop doctor`**: `cli.cmd_doctor` called `_reconcile_crashes()` with 7 positional args but the function accepts 6. The extra `packet_path` argument is removed; the remaining six args line up with the signature.
- **Repair 7 (F-7-01) — Canonical gate coverage**: `tests/integration/test_program_mode.sh` and the new `tests/integration/test_plumbing_autonomy.sh` are added to `tests/canonical.txt`. `test_repair_round_budget.sh` now drives `max_repair_rounds` over `{2, 6, 12, 25}` (was `{1, 2, 3}`).

**Real-world autonomy is unchanged at this layer.** These are plumbing repairs required before the system can be trusted to drive large real-repository missions end-to-end; the system is not yet proven on such missions by these fixture tests. The next step is real use, not another audit.

## 0.3.5 — Security and State Stabilization (2026-07-31)

**Highlights**:
- **Repair 1 (AUD2-P0-1)**: Approval boundary restored. `--assume-tty` removed;
  `OFLOOP_ACTOR` no longer grants authority; only `tty_confirmation` is a
  valid `approval_method`. Production approval requires a genuine interactive
  TTY plus typed confirmation token. There is no automation override.
- **Repair 2 (A1-001/A1-004/A1-005)**: One authoritative PROGRAM transition
  path via `state.program_transition()`. No terminal state may silently return
  to an active state. `is_stop_requested()` probe at every orchestration
  boundary.
- **Repair 3 (A1-002)**: Event-chain append is atomic. The previous-chain
  read, chain-hash computation, and write all happen inside one flock.
- **Repair 4 (F-4-01)**: PROGRAM repair-round accounting is functional for
  every approved budget (1, 2, 3). Source-evidence SHA per-checkpoint replay
  guard. Post-hook transition CHANGES_REQUESTED → READY_TO_BUILD.
- **Repair 5 (F-4-02)**: Worktree creation is serialized per
  (repo, run_id, role) via flock. Benign-race re-check after failed add.
- **Repair 6 (A3-001)**: Bash guard processes complete multi-line input.
  `_split_command_chain` splits on newlines first, then on shell-chain
  operators within each line.
- **Repair 7 (A6-F01..A6-F11)**: Canonical test gate is trustworthy. Portable
  ROOT in v-tests. Real lifecycle and PTY approval E2E. Pass markers replaced
  with assertions. `set -e` in test scripts. Static-checks scan expanded.
  Source/install parity check is automatic. Canonical allow-list with
  timeout per test.

**What v0.3.5 does NOT change**:
- No new schemas, public commands, agent roles, checkpoint types, daemons,
  queues, or deployment authority.
- No redesign of SINGLE or PROGRAM mode.
- No replacement automation override.

## 0.3.4 — Hook bytecode closeout (2026-07-31)

**Scope:** narrow, terminal release-closeout patch on top of v0.3.3.
Hook behavior is unchanged. Only Python launch boundaries are touched.

**Repair:**

- **Hook bytecode suppression.** Every runtime Claude Code hook script
  exports `PYTHONDONTWRITEBYTECODE=1` at the top and invokes `python3 -B`
  at every Python launch boundary:
  - `hooks/block_dangerous_bash.sh` (6 launch sites)
  - `hooks/block_protected_paths.sh` (8 launch sites)
  - `hooks/external_action_guard.sh` (6 launch sites)
  - `hooks/post_bash_secret_scan.sh` (3 launch sites)

  As a result, plugin activation no longer writes `.pyc` files or
  `__pycache__/` directories into the active managed cache. The terminal
  bytecode condition is now satisfied.

**What v0.3.4 does NOT change:**

- hook policy semantics (allow / deny / scan / external-action rules);
- JSON parsing, stdin/stdout handling, exit codes, fail-closed posture;
- hook configuration and matchers in `hooks/hooks.json`;
- the v0.3.3 installed-cache discovery, bytecode-free validation, and
  structural manifest count truth;
- the v0.3.2 unified PROGRAM claim accounting and payload boundary;
- public command surface (`/of-loop:spec`, `/of-loop:build`,
  `/of-loop:review`);
- packet, state, or worktree schemas.

**Scope guard:** this is a patch release. No new packet schema, no new
state schema, no new public slash command, no new agent role, no new
checkpoint type, no new counter category, no registry framework, no
daemon, no external queue, no auto-push/deploy, no generalized
abstraction layer, no broad PROGRAM-mode refactor.


## 0.3.3 — Terminal-closeout: installed-cache discovery + bytecode-free validation + manifest count truth (2026-07-31)

**Scope:** narrow, terminal release-closeout patch on top of v0.3.2. No new
phase, no architectural change.

**Repairs:**

- **Repair A — active installed-cache discovery.** `validate.sh --installed`
  now resolves the live active install via `claude plugin list --json`
  rather than the legacy `~/.claude/skills/of-loop` path. Three forms:
  - `bash validate.sh --installed`            (live registry)
  - `bash validate.sh --installed <path>`     (explicit)
  - `bash validate.sh --installed=<path>`     (explicit, equals form)

  The legacy `~/.claude/skills/of-loop` path is a rolled-back backup
  artifact and is NEVER auto-selected as the active install.

- **Repair B — bytecode-free validation.** Every outer Python launch
  boundary in `validate.sh`, `install.sh`, and `tests/run_all.sh` is now
  prefixed with `PYTHONDONTWRITEBYTECODE=1` and uses `python3 -B`.
  Validation no longer creates `.pyc` files inside the cache tree it is
  inspecting (so payload-manifest tampering checks never see
  self-inflicted bytecode).

- **Repair C — structural manifest count truth.** New
  `scripts/manifest_count_check.py` reports authoritative counts:
  - `PAYLOAD_MANIFEST_HEADER_LINES`
  - `PAYLOAD_MANIFEST_FILE_ENTRIES`
  - `INSTALLED_ACTIVE_FILES`

  and asserts `PAYLOAD_MANIFEST_FILE_ENTRIES == INSTALLED_ACTIVE_FILES`
  (and that the declared `# file_count=` header matches). A truncated or
  over-large manifest fails closed.

- **Repair D — version bump.** All canonical version surfaces now read
  `0.3.3`: `lib/ownframework_loop/__init__.py`, `.claude-plugin/plugin.json`,
  and `.claude-plugin/marketplace.json`. v0.3.1 and v0.3.2 history is
  unchanged.

**Scope guard:** v0.3.2 unified PROGRAM claim accounting and v0.3.2
payload boundary are preserved unchanged. No new packet schema, no new
state schema, no new public slash commands, no new agent roles, no
registry framework, no daemon, no auto-push/deploy, no generalized
abstraction layer.



## 0.3.2 — Terminal repair: unified PROGRAM claims + payload boundary (2026-07-31)

Repairs the two blockers that caused the v0.3.1 terminal closeout to
correctly return FAIL. No telemetry, no scoping, no workflow changes —
only the two engineering defects and their directly required tests,
release evidence, version surfaces, and installation cleanup.

### Fixed (Blocker 1: unified PROGRAM claim accounting)
- `lib/ownframework_loop/program.py` — new `claim_build_pass`,
  `claim_review_pass`, `claim_repair_round` and the private
  `_unified_claim_pass` are the **only** functions allowed to mutate
  program-build counters. They perform per-cp cap, cumulative cap,
  top-level mirror, and persistence under one flock via
  `state._locked_state` so a crash between any two writes cannot
  desync the three counters.
- New `ClaimRefused` exception class (subclass of `ProgramStateError`)
  carrying a stable code and human message.
- New `_bump_counter_one` is the single source of truth for cap
  enforcement. Both `_unified_claim_pass` and the legacy
  `increment_cp_counter` route through it.
- `lib/ownframework_loop/cli.py` — `cmd_build_claim` and
  `cmd_review_claim` now detect program-mode state and route to
  `program.claim_build_pass` / `program.claim_review_pass`. Single-mode
  V1 path unchanged.
- `lib/ownframework_loop/orchestrator.py` — removed the duplicate
  `increment_cp_counter` calls (the unified claim already incremented).
- `lib/ownframework_loop/review_finalize.py` — repair-round increments
  now route through `program.claim_repair_round` in program mode.
- `lib/ownframework_loop/state.py` — new `_locked_state`,
  `_write_state_locked`, `_append_event_locked` helpers. Re-entrant
  flock acquisition is avoided by callers holding one flock and using
  the locked helpers.

### Fixed (Blocker 2: deterministic payload boundary)
- `install.sh` — `PALOAD_FILES` `find` now excludes `__pycache__/`,
  `*.pyc`, `*.pyo`, `*.pyd`, `.git/`, `.ownframework-loop/`, `logs/`
  from the staged payload. The manifest therefore contains only
  artifact-stable source files.
- `bin/ofloop` — sets `PYTHONDONTWRITEBYTECODE=1` via
  `os.environ.setdefault` before any other import, so installed
  invocations never write `__pycache__/*.pyc` into the cache.
- `scripts/verify_payload_manifest.py` — new `DISPOSABLE_GLOBS` and
  `USER_STATE_GLOBS` classification. Active-payload boundary check
  fails closed on stale-removed manifest entries, unauthorised extra
  files, and user-state files appearing in the active payload.
  Disposable bytecode is reported as runtime cache, not tampering.

### Added (tests)
- `tests/integration/test_v032_unified_claim.sh` — 13 connected tests
  proving 9 cumulative claims succeed / 10th refused, per-cp caps,
  repair caps, CLI vs direct path equivalence, orchestrator no
  double-increment, replay idempotency, invalid-state refusal, V1
  unchanged, post-approval graph drift refusal.
- `tests/integration/test_v032_bytecode_boundary.sh` — 10 connected
  tests proving install.sh manifest excludes bytecode, launcher
  sets `PYTHONDONTWRITEBYTECODE=1`, validator classifies bytecode
  as disposable, rejects stale/injected active files, rejects user-
  state files in active payload, detects SHA-256 tampering, and
  ignores bytecode mutation.

### Notes
- v0.3.1 history is preserved. The 5 `FINAL_SOURCE_PROMOTIONS=5`
  process defect is recorded as historical fact; v0.3.2 produces
  exactly one source promotion and one active installation.
- All v0.3.2 tests are added to the canonical release gate exactly
  once (no duplicate test execution).

## 0.3.0 — Program mode + checkpoints (2026-07-30)
### Added
- v3 packet schema (`ownframework-work-packet/v3`) with `execution_mode`,
  `checkpoint_graph`, and `promotion_policy` fields.
- `lib/ownframework_loop/program.py` — owns the finite checkpoint DAG,
  per-checkpoint counters, cumulative caps, global source ceilings,
  automatic advancement, nonterminal approval guards, and source-tree
  accounting.
- v2 state schema (`ownframework-loop-state/v2`) with optional `program`
  block. v1 single-mode state remains the default when `program` is absent.
- `ofloop program init` and `ofloop program status` subcommands.
- `ofloop loop run` dispatches to single-mode or program-mode based on
  the packet.
- `test_program_mode.sh` end-to-end integration test (2 checkpoints → APPROVED).
### Notes
- v1/v2 packets remain backward-compatible.
- The orchestrator still refuses to start without an operator approval
  marker; program init is also gated on a valid APPROVAL.json binding.
All notable changes to OwnFramework Loop are documented here.


## 0.3.1 — Crash reconciliation + lifecycle truth + schema truth (2026-07-31)

### Added
- `lib/ownframework_loop/reconcile.py` — deterministic automatic crash
  reconciliation. Invoked at the start of every orchestrator resume
  (single-mode and program-mode) and by `ofloop doctor`. Handles 7 crash
  boundaries (build receipt, build transition, review verdict, review
  transition, checkpoint advancement, checkpoint transition, final
  integrated verdict). Idempotent. Stale artifacts (whose implied
  transition is no longer reachable from the current state per the
  state machine) are SKIPPED — the orchestrator overwrites them.
- `lib/ownframework_loop/schema_validate.py` — real JSON-schema
  validation against the actual schemas in `schemas/` (work-packet v1/v2/v3,
  state v1/v2, approval, build-receipt, review-verdict). Uses `jsonschema`
  Draft202012Validator.
- `scripts/verify_payload_manifest.py` — verifies the installed cache
  matches the recorded `.payload.manifest` (file list + per-file SHA-256).
- `install.sh` now writes `.payload.manifest` after the managed install
  succeeds, capturing every regular file in the cache tree with its SHA-256.
- `validate.sh --installed` fails closed if the manifest is missing,
  any listed file is missing, or any file's SHA-256 has drifted.

### Changed
- `lib/ownframework_loop/integrity.py` — `compute_event_chain_hash`
  rewritten as a non-self-referential iterative SHA-256 chain
  (`chain_hash_n = SHA(prev_chain || event_n_stripped)`). The chain
  hash no longer depends on its own value.
- `lib/ownframework_loop/state.py` — `_compute_chain_hash_for_append`
  rewritten to match the verifier's iterative model. `append_event`
  placeholder length fixed to 64 chars so writer/verifier bytes
  match. `run_dir` accepts `Path|str`.
- `lib/ownframework_loop/reconcile.py` — `_live_process` probes flock
  with non-blocking `LOCK_EX` instead of mere LOCK file existence
  (LOCK files persist across normal operations and are not by
  themselves a live-process indicator).
- `rollback.sh` — replaced `mapfile` (bash 4+) with a bash 3.2
  compatible read loop so it works on macOS default Bash.
- `validate.sh` — added `reconcile` to the Python library imports
  smoke check; payload-manifest verification added to the
  `--installed` block.
- `schemas/state-v2.schema.json` — checkpoint `candidate_sha`,
  `build_receipt_sha256`, `verdict_sha256` accept null (the engine
  initializes these as None until a checkpoint has been worked on).
- `schemas/approval.schema.json` — `confirmation_token` maxLength
  raised to 64 (engine emits 24-char tokens).

### Fixed
- Pre-existing latent bug in event-chain hash self-reference that
  caused any state-saved event after the first one to fail chain
  verification on the next read.
- Rollback was broken on macOS (default Bash 3.2) because it relied
  on `mapfile`.
- Validate.sh previously masked `cmd && ok` failures (no `-e`,
  `set -uo pipefail` only); the script no longer applies this
  anti-pattern.

### Notes
- The public command surface remains: `/of-loop:spec`, `/of-loop:build`,
  `/of-loop:review`. Internal deterministic CLI subcommands (`ofloop
  build claim`, `ofloop build finalize`, `ofloop review claim`,
  `ofloop review finalize`, `ofloop program init`, `ofloop program
  status`, `ofloop loop run`, `ofloop doctor`) are unchanged and
  continue to support the slash commands without requiring manual
  operator invocation.
- The release gate (42 tests across unit, integration, smoke) passes
  with `OF_LOOP_RELEASE_GATE_RESULT=PASS`.

## v0.2.1 — 2026-07-23

Managed-marketplace convergence, known guard-evasion repair,
approval-claim correction.

- **Managed marketplace install**: `install.sh` now invokes
  `claude plugin install of-loop@ownframework-local --scope user`
  through the local marketplace catalog at
  `projects/.claude-plugin/marketplace.json`. The skills-dir copy
  path under `~/.claude/skills/of-loop` is removed at install time
  and archived to `~/.claude/ownframework-loop-mgmt-backup-<UTC>/`
  for rollback. Legacy `uninstall.sh` is rewritten to call the
  managed uninstall; persistent plugin data is preserved.
- **Three guard evasions closed**:
  1. Python-subprocess: `python3 -c "import subprocess; subprocess.run(['git','push'])"`
     — closed by command-text decomposition of `-c` payload; the
     interpreter inspects bounded literal subprocess/os.system/exec
     calls and refuses on a forbidden action.
  2. Variable assembly: `X=push; Y=origin; Z=master; git $X $Y $Z`
     — closed by Bash top-level command-line extraction before
     normalization, so variable expansion is recognized as a
     candidate git invocation with action category "git_push".
  3. Hyphenated executable form:
     `./git-remote-add origin https://x`
     — closed by basename normalization of the resolved
     executable identity. A hyphenated wrapper named
     `git-remote-add` is normalized to category `remote_add`
     and refused.
- **Approval claim correction**: the documentation now correctly
  states `TOKEN_IS_SECRET=no`, `TOKEN_IS_PACKET_DERIVED=yes`.
  The `CONFIRM-OF-LOOP-<8hex>` token is derived from the packet
  SHA-256 (plaintext) and proves packet acknowledgement, not
  secrecy. The architectural root of trust is artifact binding
  (packet SHA + canonical_repo + baseline_sha + confirmation_token)
  plus tested command-origin refusal, not token cryptographic
  unspoofability.
- **Agent-tool posture clarification**: the absence of `tools:`
  and `disallowedTools:` in `agents/of-builder.md` and
  `agents/of-reviewer.md` is intentional. Authority comes from
  packet, exact worktree, hooks, finalizers, and promotion
  boundaries — not from a narrow tool allowlist.
- **Multiple stale cache directories (0.1.1, 0.1.2, 0.1.3, 0.1.4,
  0.2.0) are normal**: they are Claude-managed orphan/grace-period
  artifacts; manual cache deletion is forbidden.
- **VERSION**: bumped source, plugin manifest, marketplace
  catalog, library `__version__`, hook manifest. The V2
  architecture designation remains. 0.2.1 is a release inside V2.

## v0.2.0 — 2026-07-23

Two-loop engineering for specification, isolated building, exact-SHA
review, repair, and proof. V2 elevates the determinism of the V1 pilot
on fourteen patches.

### Patch summary

1. **Externalized approval** — `APPROVAL.json` is a separate artifact
   at `.ownframework-loop/<run-id>/APPROVAL.json`, never embedded in
   the packet. Packets remain pure markdown + JSON. The packet SHA is
   bound to the approval via `packet_sha256`; `confirmation_token`
   is derived from the packet SHA as `CONFIRM-OF-LOOP-<8hex>`.
2. **Deterministic build finalizer** — `ofloop build finalize` is
   the only entity that writes `BUILD_RECEIPT.json`. The model
   cannot influence the verifier verdict on any of the 22
   independent checks (approval validation, worktree identity,
   exact candidate branch, candidate SHA ancestry, baseline immutability,
   scope, hard-secret scan, validation commands, no-progress, repair
   limits, atomic write, event append, next-state derivation).
3. **Deterministic review finalizer** — `ofloop review finalize` is
   the only entity that writes `REVIEW_VERDICT.json`. The reviewer
   agent's `recommended_verdict` is advisory only; the finalizer
   validates the exact candidate SHA, scope, and budget against the
   packet, then derives verdict from independent checks.
4. **Artifact integrity & event consistency** — every state-changing
   operation appends a typed event to `EVENTS.log`; `assert_artifacts_intact`
   verifies byte-level SHA equality for packet, approval, receipt,
   verdict, and state; external mutation registers as an integrity
   event.
5. **Exact-run hook binding** — hooks refuse to act on tools when
   the `STATE.json` of the active run is absent or stale. The hook
   walks up to find the run directory and refuses out-of-scope writes
   silently during the active loop.
6. **Broad tools + external-action guard** — the textual guard
   blocks `git push`/`git remote *`/`docker compose`/`systemctl`
   and SSH access to production-host-1 / production-host-2. Detection covers bare forms,
   chains (`&&`, `;`, `||`), pipelines (`|`), `$(...)` and `eval`,
   and single-line redirects. Variable indirection is deferred to
   the sandbox + post-pass review layers. production-orchestrator, Kanban, Linear,
   Windmill, and SQLite are not added.
7. **Safe secret handling** — secret scanner distinguishes
   `HARD_PATTERNS` (block: AWS keys, private keys, high-confidence
   tokens) from `HEURISTIC_PATTERNS` (reviewable warning, recorded
   in receipt). Hard block triggers pre-receipt refusal
   `OF_LOOP_BUILD_FINALIZE_REFUSED`. Receipt findings are redacted
   to `redacted_prefix` + SHA-256; literal values never reach
   `EVENTS.log`, `BUILD_RECEIPT.json`, or `REVIEW_VERDICT.json`.
8. **Packet-approved sensitive paths** — sensitive paths must be
   declared in `packet.sensitive_paths` with `sensitive_path_reason`.
   The finalizer permits writes to elevated paths only when the
   packet lists them; protected paths (e.g., `.ownframework-loop/`)
   are always forbidden.
9. **Work-class-aware budgets with absolute ceiling** — each packet
   declares a `risk_budget` sub-key. The hard caps are
   `max_files_changed ≤ 500`, `max_diff_lines ≤ 30000`,
   `max_repair_rounds ≤ 12`. The V1 V1 cap floor is preserved
   (e.g., repair rounds 3 for BUG work, default). A work-class table
   provides sensible defaults per work class.
10. **Branch/remote neutrality** — `git worktree add` is the only
    isolation mechanism. The loop does not create remotes, never
    pushes, never merges, never deploys. The push/merge/deploy
    authority stays with the human. The candidate branch is
    always `factory/candidate/<run-id>`.
11. **Marker/installation consistency** — `install.sh` is idempotent
    (backs up existing copy, verifies SHA-256 of the source before
    copy); `uninstall.sh` is reversible to the backup if one exists.
    Plugin metadata in `.claude-plugin/plugin.json` references
    version 0.2.0.
12. **Skill/agent responsibility rewrite** — three skills
    (`spec`, `build`, `review`) and two independent agent types
    (`of-builder`, `of-reviewer`). Skills describe contracts;
    agents execute within them. Neither agent has WebFetch,
    WebSearch, Write, or push authority.
13. **Cost efficiency** — the textual guard pre-filters obviously
    forbidden commands before sandbox invocation. The finalizer
    runs validations bounded by per-validation timeout
    (`max_runtime_seconds`). Branch/remote neutrality avoids
    cost-incurring operations.
14. **Compatibility migration** — V1 packet fields are mapped to V2
    packet fields at the CLI boundary; legacy approval-flow
    commands (`apply_approval`, `write_approved_packet`,
    `build write-receipt`) are removed; CLI commands
    (`spec new|approve|status|inspect-legacy`, `build claim|finalize`,
    `review finalize`) are deterministic.

### Deterministic tests

- 73 tests across `tests/unit/test_trust_*.sh` covering approval,
  build, review, secrets, packet hashing, integrity, transitions,
  worktree lifecycle, bypass matrix, CLI E2E, and capability
  matrix.
- Capability matrix runs 4 end-to-end missions (M1 ordinary bug
  fix, M2 repository doctrine change, M3 web research, M4
  malicious proof with hard secret) on disposable repos.

### Release gate

`tests/run_all.sh` produces `OF_LOOP_RELEASE_GATE_RESULT=PASS` when
all 34 test files pass: trust (33 unit), capability matrix
(4 missions). One command — no test recursion.

## v0.1.4 — 2026-07-22

Recursion repair and gate containment.

- Removed reverse-orchestrator edge in
  `tests/unit/test_plugin_data_resolution.sh`: it no longer
  launched `release_gate.sh`. Receipts use the shared
  `ownframework_loop.plugin_data.write_receipt()` helper.
- `release_gate.sh` is now a thin wrapper around
  `ownframework_loop.release_gate_runtime`, which acquires an
  authoritative `fcntl.flock(LOCK_EX|LOCK_NB)` on a stamp file
  before any test invocation, so a second `release_gate.sh` run
  in a `worktree`-mounted repo cannot produce two parallel
  receipt writers.

## 0.3.6 — Static-Check Compatibility Closeout (2026-08-01)

**Highlights**:
- v0.3.6 is a narrow closeout, not an architecture phase.
- Removes dynamic `eval` execution from the multiline bash guard test.
  Forbidden tokens are decoded via Python `chr()` / string concatenation
  and treated purely as JSON string data. The test NEVER executes them
  via `eval`/`source`/`bash -c`/`sh -c`.
- The canonical static call-graph scanner remains strict. No allow-list
  was added; the scanner continues to flag `eval`/`nohup`/`disown` and
  recursive release-hierarchy invocations as `unsafe-orchestration`.
- Guard runtime semantics are unchanged. The hook, classifier, and
  sentinel behavior are identical to v0.3.5.
- No approval, state, PROGRAM, concurrency, or authority behavior changed.
- v0.3.5 remains preserved as the failed installed release attempt.
  v0.3.4 cache and history are unmodified.

**New artifacts**:
- `tests/integration/test_scanner_regression.sh` — proves the scanner
  catches reintroduced `eval`, direct recursive release-gate calls, and
  reverse orchestration dependencies, while the repaired multiline test
  produces zero edges.
- `tests/integration/_helpers/scan_json.py`,
  `tests/integration/_helpers/edge_count.py`,
  `tests/integration/_helpers/full_scan.py` — small Python drivers used
  by the regression suite to invoke the scanner.

**Repaired**:
- `tests/integration/test_hook_multiline_bash.sh` — uses Python JSON
  serializer (`json.dumps`) to build hook stdin payloads. Decoded
  adversarial command strings remain test data only.
