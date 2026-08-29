# Changelog

All notable current-release changes to OwnFramework Loop are documented here.
The complete historical changelog through 0.5.2 is preserved at
[`docs/history/CHANGELOG-through-0.5.2.md`](docs/history/CHANGELOG-through-0.5.2.md).

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
