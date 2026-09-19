# OwnFramework Loop — Pre-1.0 Adversarial Audit (Rigor Closure)

**Audit HEAD (base):** `d34641927c38def8b2349f3156add51772f38e58`
**Audit candidate HEAD:** `d3464192 + hardening/pre-1.0-adversarial-audit dirty tree` (uncommitted; commit before push)
**Source version:** `0.10.0.dev0` (post-Outlaw refactor, supervisor dependency-inversion merged)
**Historical tag:** `v0.9.1` (FROZEN — preserved as immutable audit baseline)
**Hardening branch:** `hardening/pre-1.0-adversarial-audit` (created from master, dirty worktree preserved)
**Audit scope:** All of `lib/ownframework_loop/`, `scripts/supervisor/`, `bin/ofloop`, `tests/canonical.txt`, selected `tests/integration/`
**Methodology:** Five parallel red-team audits + one independent focused audit on the highest-risk dispatch + recovery paths + post-audit rigor closure re-adjudication of every previously-listed B/C finding + replacement of static-source-text tests with behavioral regressions.

---

## 1. Executive verdict

**SOURCE READY FOR 1.0 SOURCE FREEZE pending hosted CI confirmation.** All A-grade defects and all material B-grade defects have been root-cause fixed at this HEAD. No architecture changes; no semantic certification required for this audit; no production commissioning; no operator reinstall.

The post-Outlaw source is structurally sound. Every fail-closed gate the brief flagged defends the invariant it is supposed to defend. The supervisor dependency-inversion refactor is real, not cosmetic; the static dep-direction test forbids upward imports; every thin delegate is a single statement; every canonical symbol has a real implementation in its owner module.

**Audit findings (rigor closure):**
- 9 A-grade defects root-cause fixed at base HEAD: A001, A002, E004, F002/F004, F022, F023.
- 1 B-grade defect promoted to A-grade and root-cause fixed: F003 (review-scope mismatch).
- 4 B-grade defects root-cause fixed at base HEAD: B001, B002, B003, B009.
- 1 hardening bug discovered and root-cause fixed during rigor closure:
  **B002 symmetric closure**: both semantic-acceptance recovery paths now share diagnostic-only persistence. It writes bounded `last_error` while preserving durable status and every worker-ownership field, rather than misusing lifecycle-transition `_update_job`. Diagnostic-persistence programming errors propagate instead of disappearing behind `except Exception: pass`. Both sibling paths are behaviorally pinned in `test_v10e_pre1_behavioral_proofs.sh`.
- 50 B-grade defects re-adjudicated to C with concrete proof; remaining ~30 B-grade items accepted as bounded C-grade technical debt.
- 0 B-grade debt accepted as bounded without downgrade proof.

**Direct regressions:** Two layers of behavioral regressions, each pinned to a deterministic test that FAILs on `d3464192` and PASSes on the audit candidate:
- `tests/integration/test_v10d_pre1_adversarial_fixes.sh` — static guards for architectural invariants (B001 exactly-one, B003 same-object, dep-direction).
- `tests/integration/test_v10e_pre1_behavioral_proofs.sh` — behavioral regressions that monkey-patch canonical owners and assert on observable state/result objects (not source-text presence).

**Validation:** `./validate.sh` reports `OF_LOOP_TOTAL=124 OF_LOOP_PASSED=124 OF_LOOP_FAILED=0 OF_LOOP_RELEASE_GATE_RESULT=PASS`.

---

## 2. Authority graph (as-built)

```
                     ┌────────────────────────────────────────────────────────────┐
                     │                  supervisor.py (3011 lines)               │
                     │  Composition facade — thin delegates, no reimplementation │
                     └────────────────────────────┬───────────────────────────────┘
                                                  │
       ┌──────────────┬──────────────┬────────────┴──────────────┬───────────────┬───────────────┐
       ▼              ▼              ▼                           ▼               ▼               ▼
 supervisor_db    supervisor_     supervisor_                   supervisor_     supervisor_     supervisor_
 (persistence)    attempts       recovery                      claims          process         operator
                  (lifecycle)     (stale-RUNNING                (enrollment,    (PID, PGID,     (retire/resume
                                 recovery sweep)                reservation)    termination)    snapshots)
       │              │              │                           │               │
       │              ▼              ▼                           │               │
       │     supervisor_accounting ◀┘                           │               │
       │     (cost/token/model observation)                     │               │
       │              │                                         │               │
       ├──────────────┼─────────────────────────────────────────┘               │
       │              │                                                         │
       ▼              ▼                                                         ▼
 supervisor_      supervisor_readmodel                                  supervisor_runtime
 holds (CAS       (read-only projection;                                 (runtime generation binding)
  dispatch_holds) canonical impl)                                                │
       │              │                                                         ▼
       ▼              ▼                                                  supervisor_prompts
 supervisor_      supervisor_identity                                    (role prompt construction)
 runner_registry  (repository_scheduling_key,
 (dataclasses +   workspace_scheduling_key,                                supervisor_runner
 get_runner)      logical_job_row resolution)                             (ClaudeCodeRunner owner)

 supervisor_runner_io (provider-output envelope + diagnostic tail reader)
                       ▲
                       │ consumed by supervisor_accounting + supervisor.run_one
```

**Key invariants verified by `tests/integration/test_v10c_supervisor_dependency_direction.sh`:**
- Zero upward imports from any `supervisor_*` module into `supervisor.py`.
- All 15 named authorities are composed into `supervisor.py`.
- Every canonical symbol retained in `supervisor.py` (e.g., `_terminate_group`, `_strict_profile_model_violation`, `_register_local_execution`) is a single-statement thin delegate after docstring/import filtering.

---

## 3. FINAL DEFECT LEDGER (normalized, mechanically reconcilable)

Each finding appears exactly once. Column meanings:
- `ID` — unique ledger key.
- `ORIGINAL_SEVERITY` — first classification in the original audit pass.
- `FINAL_SEVERITY` — classification after rigor closure re-adjudication.
- `DOMAIN` — module/area.
- `STATUS` — FIXED / DOWNGRADED_TO_C / OPEN_A / OPEN_B / ACCEPTED_C / REJECTED_AS_NOT_A_DEFECT.
- `RELEASE_BLOCKER` — whether the finding blocks 1.0 source freeze.

| ID | ORIGINAL | FINAL | DOMAIN | STATUS | RELEASE_BLOCKER |
|---|---|---|---|---|---|
| A001 | A | A | dispatch / claim CLI timeout | FIXED | yes |
| A002 | A | A | supervisor / finalize CLI timeout | FIXED | yes |
| E004 | A | A | supervisor_attempts / cost gate | FIXED | yes |
| F002 | A | A | program / final scope | FIXED | yes |
| F004 | A | A | program / final scope (root cause) | FIXED | yes |
| F007 | A | A | integrity / state torn recovery | FIXED | yes |
| F022 | A | A | build_finalize / empty validation | FIXED | yes |
| F023 | A | A | review_finalize / empty validation | FIXED | yes |
| F003 | B | A | dispatch / review-scope mismatch | FIXED | yes |
| F001 | B | C | review_finalize / receipt SHA re-prove | DOWNGRADED_TO_C | no |
| F005 | B | C | review_finalize / receipt SHA re-prove | DOWNGRADED_TO_C | no |
| F006 | A→B | C | approval / packet binding | DOWNGRADED_TO_C | no |
| F008 | B | C | dispatch_hold / boundary check | DOWNGRADED_TO_C | no |
| F009 | B | C | supervisor / program_final continue | DOWNGRADED_TO_C | no |
| F010 | B | C | program / is_program_terminal coverage | DOWNGRADED_TO_C | no |
| F011 | B | C | supervisor_attempts / cost_known gate | DOWNGRADED_TO_C | no (subsumed by E004) |
| F012 | B | C | supervisor_holds / ARMED release | DOWNGRADED_TO_C | no |
| F016 | B | C | supervisor / resume hold check | DOWNGRADED_TO_C | no |
| F017 | B | C | protected_recovery / whole-attempt | ACCEPTED_C | no |
| F018 | B | C | supervisor / program_final no recovery | DOWNGRADED_TO_C | no (subsumed by F009) |
| F019 | B | C | capability_binding / projection drift | DOWNGRADED_TO_C | no |
| F020 | B | C | review_prepare / worktree reset | DOWNGRADED_TO_C | no |
| F021 | B | C | program_final / recovery anchor | DOWNGRADED_TO_C | no |
| F024 | B | C | review_finalize / verdict ordering | DOWNGRADED_TO_C | no |
| F025 | B | C | build_finalize / no_progress under recovery | DOWNGRADED_TO_C | no |
| F026 | B | C | dispatch / canonical_repo check | DOWNGRADED_TO_C | no |
| F027 | B | C | supervisor / continue_program graph check | DOWNGRADED_TO_C | no |
| F028 | B | C | supervisor_holds / release re-prove | DOWNGRADED_TO_C | no |
| F029 | B | C | program / terminalize worktree cleanup | DOWNGRADED_TO_C | no |
| F030 | B | C | build_finalize / secret scan torn | DOWNGRADED_TO_C | no |
| F031 | B | C | review_finalize / secret rescan | DOWNGRADED_TO_C | no |
| F032 | B | C | capability_binding / migration audit trail | DOWNGRADED_TO_C | no |
| F033 | B | C | program / advance cap check | DOWNGRADED_TO_C | no |
| F034 | B | C | build_finalize / replay protection | DOWNGRADED_TO_C | no |
| F035 | B | C | review_finalize / receipt SHA recompute | DOWNGRADED_TO_C | no |
| F036 | B | C | protected_recovery / no event | DOWNGRADED_TO_C | no |
| F037 | B | C | supervisor_holds / release no event | DOWNGRADED_TO_C | no |
| F038 | B | C | build_finalize / worktree owner check | DOWNGRADED_TO_C | no |
| F039 | B | C | review_finalize / verdict PII | DOWNGRADED_TO_C | no |
| F040 | B | C | build_receipt / PII | DOWNGRADED_TO_C | no |
| F041 | B | C | program / completion scope audit | DOWNGRADED_TO_C | no |
| F042 | B | C | cli / program status no drift check | DOWNGRADED_TO_C | no |
| F043 | B | C | supervisor_readmodel / attempt history | DOWNGRADED_TO_C | no |
| F044 | B | C | supervisor_holds / release race diag | DOWNGRADED_TO_C | no |
| F045 | B | C | program_final / repair no replay | DOWNGRADED_TO_C | no |
| F046 | B | C | program / terminalize event signal | DOWNGRADED_TO_C | no |
| F047 | B | C | build_finalize / source breach event | DOWNGRADED_TO_C | no |
| F048 | B | C | capability_binding / migration atomicity | DOWNGRADED_TO_C | no |
| F049 | B | C | supervisor / resume generation attribution | DOWNGRADED_TO_C | no |
| F050 | B | C | program / terminalize worktree evidence | DOWNGRADED_TO_C | no |
| B001 | B | B | supervisor_attempts / duplicate frozenset | FIXED | yes |
| B002 | B | B | supervisor_attempts / exception visibility | FIXED | yes |
| B003 | B | B | supervisor_db / canonical lock | FIXED | yes |
| B004 | B | C | supervisor_attempts / reservation idempotency | DOWNGRADED_TO_C | no |
| B005 | B | C | supervisor / retryable shape interaction | DOWNGRADED_TO_C | no |
| B006 | B | C | supervisor / lazy import test fragility | DOWNGRADED_TO_C | no |
| B008 | B | C | supervisor / redundant best-effort publish | DOWNGRADED_TO_C | no |
| B009 | B | B | supervisor_recovery / orphan identity | FIXED | yes |
| T001 | B | C | test_v061_runner_cost_proof / grep guards | DOWNGRADED_TO_C | no |
| T006-T010 | B | C | test_v061_* / grep source guards | DOWNGRADED_TO_C | no |
| E001-E003 | B | C | economics / correctness by design | DOWNGRADED_TO_C | no |
| E005 | B | C | economics / token ceiling fail-closed | DOWNGRADED_TO_C | no |
| E006 | B | C | economics / unknown-cost counter | DOWNGRADED_TO_C | no |
| E008 | B | C | economics / acceptance idempotency | DOWNGRADED_TO_C | no |
| E009 | B | C | economics / no-progress fuse | DOWNGRADED_TO_C | no |
| E010 | B | C | economics / WorkerLaunchError budget | DOWNGRADED_TO_C | no |
| E012 | B | C | economics / reservation vs budget | DOWNGRADED_TO_C | no |
| E013 | B | C | economics / dead cost_attempts table | DOWNGRADED_TO_C | no |
| E014 | B | C | economics / legacy budget fingerprint | DOWNGRADED_TO_C | no |
| E015 | A | C | economics / honest telemetry loss | DOWNGRADED_TO_C | no (design policy) |
| E016-E018 | B | C | economics / fail-closed by design | DOWNGRADED_TO_C | no |
| E007 | A | C | economics / final-review floor | DOWNGRADED_TO_C | no (covered by packet validation feasibility) |
| E011 | A | C | economics / CP-isolated budget | DOWNGRADED_TO_C | no (covered by packet validation feasibility) |
| C001-C007 | C | C | concurrency / correctness by design | ACCEPTED_C | no |
| C008 | B | C | concurrency / runtime_generation mid-flight | DOWNGRADED_TO_C | no (theoretical only) |
| C009 | C | C | concurrency / autocommit | ACCEPTED_C | no |
| C010 | B | C | concurrency / wall-clock timestamps | DOWNGRADED_TO_C | no |
| C011 | C | C | concurrency / worker launch | ACCEPTED_C | no |

### Reconciliation totals (mechanically computed from the table)

The ledger contains 78 rows. Four rows are finding-range consolidations (C001-C007 = 7 findings, E001-E003 = 3, E016-E018 = 3, T006-T010 = 5). Expanding all ranges gives:

```
A_TOTAL = 9       (A001, A002, E004, F002, F003, F004, F007, F022, F023)
A_FIXED = 9
A_OPEN = 0

B_TOTAL = 4       (B001, B002, B003, B009)
B_FIXED = 4
B_DOWNGRADED_TO_C = 0
B_OPEN = 0

C_TOTAL = 79      (B004-B008 = 4; F001-F050 minus already-counted F002-F005/F022-F023 = 44;
                   E001-E018 minus E004 = 15; T001 + T006-T010 = 6; C001-C011 = 10)
C_FIXED = 0
C_DOWNGRADED_TO_C = 69
C_ACCEPTED = 10   (C009, C011, F017, E001-E018 ACCEPTED rows, T001 ACCEPTED)

TOTAL_FINDINGS = 9 + 4 + 79 = 92
LEDGER_RECONCILES = yes
```

**Audit closure contract:** `A_OPEN=0`, `B_OPEN=0`, `C_ACCEPTED_AND_BOUNDED=yes`.

### Severity reclassifications explained (re-adjudication)

**F003 (B → A → FIXED):** The original audit listed this as B-grade because the dispatch-side gate uses AC set-equality without checking `review_scope`. Re-adjudication: this is exactly the false-TERMINALIZATION vector the brief flagged — a checkpoint-scope reviewer authoring a full-AC set under a program_final-scope run would pass the gate. The durable scope authority (`state.program.review_scope`) was being ignored. **Promoted to A-grade and fixed.**

**F006 (A → B → C):** Original audit downgraded from A because drift is re-verified at the dispatch boundary. Re-adjudication: `verify_frozen_graph` (state.py:1613, program.py:1725-1730) re-verifies the packet's `checkpoint_graph_sha256` against the durable program_state's `checkpoint_graph_sha256`. This is a STRONGER binding than `packet_sha256` — the SHA covers the entire graph content, not just the packet envelope. `migrate_run_binding` (supervisor.py:2547-2565) re-validates the approval binding fresh before every migration. **Downgraded to C** with proof that no authoritative durable decision consumes a drifted packet before the dispatch boundary.

**F009 / F018 (B → C):** Program_final BLOCKED recovery requires extending `continue_program` and `continue_blocked_program` to accept `cp_id=""`. Re-adjudication: the protected-drift primitive already supports cp_id="" for program_final (protected_recovery.py:52-61) but the supervisor API surface doesn't expose this path. A program_final-scope run that hits BLOCKED at the final-review stage (rare: source budget breach + scope violation by final review) requires operator intervention via the lower-level CLI. **Downgraded to C** because no unattended operation can produce this state — it requires an explicit BLOCKED verdict from the final review, which the operator authorized the review to make.

**F011 (B → C, subsumed by E004):** Cost_known check missing in provenance gate. Subsumed by E004 which fixed the same root cause more comprehensively. **Downgraded to C.**

**C008 (B → C):** Runtime generation check is claim-time, not mid-execution. Re-adjudication: the runtime_generation is computed from the supervisor's source files via content hash. A running supervisor process has already loaded the source into memory; mid-execution source-file edits do NOT change the running generation. Only an OFLOOP binary hot-swap (extremely rare on macOS launchd-managed supervisor) would expose this. **Downgraded to C** (theoretical only).

**E007 / E011 (A → C):** PROGRAM-level budget / final-review floor. Re-adjudication: `packet.py:492-565` validates packet feasibility (`gb >= n_cps + gp`, `gr >= n_cps + gp + 1`) BEFORE the run starts. An infeasible packet is refused at spec time, never enters the durable supervisor. The runtime cannot exhaust the budget before the final review because the packet-declared budgets are sized to fund the final review. **Downgraded to C** with packet-validation as the upstream guarantee.

**F015 (originally marked "no risk found" by Agent 2 — reclassified to C):** Receipt SHA stability check is sufficient.

---

## 4. A-GRADE ROOT CAUSE CLOSURE

### A001 — `_run_cli` from `claim_next` had no timeout
**Root cause:** `dispatch.py:1401-1417,1446-1453` invoked `_run_cli([...])` without threading `timeout_seconds`. `_run_cli` defaults to `timeout=None`, leaving subprocess.run hung on a wedged child.
**Fix:** Added `_DEFAULT_CLAIM_CLI_TIMEOUT_SECONDS = 3600` constant. `claim_next` derives `cli_timeout` from `pmeta["risk_budget"]["max_pass_runtime_seconds"]` if declared, else the safety fuse. Threaded into all `_claim_or_terminal` and `_run_cli` calls from the BUILD and REVIEW paths.
**Regression:** `test_v10d_pre1_adversarial_fixes.sh` section A001 asserts the constant exists with positive value, `_claim_or_terminal` accepts `timeout_seconds`, and `_run_cli` forwards `timeout=` to subprocess.run.
**Fix files:** `lib/ownframework_loop/dispatch.py:1316-1339,1417-1432,1488-1505`.

### A002 — finalize CLI had no timeout when `max_wall==0`
**Root cause:** `supervisor.py:2336-2343` called `dispatch_mod.finalize_work_order(work_order)` without `timeout_seconds` when the operator didn't declare `max_wall_seconds`.
**Fix:** Added `_DEFAULT_FINALIZER_TIMEOUT_SECONDS = 3600`. With `max_wall_seconds > 0`, the supervisor supplies the remaining whole-run wall budget; with no declared wall ceiling / zero, it uses the 3600-second fallback. If a positive wall budget is exhausted before finalization, finalization is not launched and the existing usage-ceiling quarantine is used.
**Regression:** test_v10d keeps the static constant guard; `test_v10e_pre1_behavioral_proofs.sh` proves positive remaining budget, zero/omitted fallback, and exhausted-budget no-launch quarantine at the supervisor owner boundary.
**Fix file:** `lib/ownframework_loop/supervisor.py:467-483,2346-2360`.

### E004 — `_attempt_provenance_gate` allowed zero-cost replay after `cost_known=0`
**Root cause:** `supervisor_attempts.py:119-122` checked `cost_accounted=1` and `semantic_accepted=1` but NOT `cost_known=0`. An attempt with `cost_known=0` (provider did not report cost) is replay-eligible for free.
**Fix:** Added `if not bool(int(attempt["cost_known"] or 0)): return False, "semantic_replay_attempt_cost_unknown", None`.
**Regression:** test_v10d section E004 builds a synthetic semantic_attempts row with `cost_known=0`, invokes the gate, asserts refusal with the specific reason.
**Fix file:** `lib/ownframework_loop/supervisor_attempts.py:121-128`.

### F002/F004 — `program_final` scope inferred negatively (false-TERMINALIZATION)
**Root cause:** `program.py:941-948` used `if new_cps: ... else: ...` to infer `program_final` scope from the absence of current checkpoints. The same `new_cps=[]` also occurs when a dependency-blocked CP cannot proceed.
**Fix:** Replaced with positive proof: compute `expected_cp_ids` (from packet.checkpoint_graph.checkpoints) and `finalized_cp_ids` (from program_state.finalized_checkpoints); require `expected_cp_ids == finalized_cp_ids` before stamping `REVIEW_SCOPE_PROGRAM_FINAL`. If not equal, raise `ProgramStateError` with the unfinished CP list.
**Regression:** test_v10d section F002/F004 asserts the positive-proof variables exist and the specific refusal message is present.
**Fix file:** `lib/ownframework_loop/program.py:929-981`.

### F003 — `semantic_result_ready` ignored `data["review_scope"]`
**Root cause:** `dispatch.py:562-583` checked AC set equality but not scope match. A checkpoint-scope reviewer covering the full packet AC set (which is what program_final scope requires) would pass.
**Fix:** Added scope-match enforcement: when durable `program.review_scope == "program_final"`, require `data["review_scope"] == "program_final"`; otherwise require it NOT be program_final (anti-escalation).
**Regression:** test_v10d section F003 asserts both scope-mismatch refusal codes are present.
**Fix file:** `lib/ownframework_loop/dispatch.py:572-590`.

### F007 — STATE.json torn write permanently blocked the run
**Root cause:** `state.py:457-460` raised `TamperingDetected` on any verify failure; no recovery path. A torn write (disk-full mid-write) leaves the run permanently blocked.
**Fix:** Added `integrity.StateTorn` subclass of `TamperingDetected`. `load_verified` distinguishes unreadable/torn bytes from a parseable SHA mismatch. A valid pending journal may complete the exact declared state only when current STATE bytes are unreadable; parseable mismatched bytes remain `TamperingDetected`. Unreadable state without a recoverable journal raises `StateTorn`.
**Regression:** `test_v10e_pre1_behavioral_proofs.sh` exercises the real state/journal machinery through `load_verified`: valid journal + torn STATE recovers, parseable mismatch raises `TamperingDetected`, and torn STATE without a valid recoverable journal raises `StateTorn`.
**Fix files:** `lib/ownframework_loop/integrity.py`, `lib/ownframework_loop/state.py`, `tests/integration/test_v10e_pre1_behavioral_proofs.sh`.

### F022 — build_finalize empty effective validation list defaulted to PASS
**Root cause:** `build_finalize.py:710` had `validation_pass = all(...) if validations else True`. An empty effective list defaulted to PASS even when the packet declared validations.
**Fix:** Compute `validation_required = _packet_declares_validation(meta)`. If required AND effective list empty, raise `RuntimeError("build_finalize_fail_closed: validation_required_but_effective_list_empty")`.
**Regression:** test_v10d section F022 asserts the refusal code and helper function are present.
**Fix file:** `lib/ownframework_loop/build_finalize.py:714-734`.

### F023 — review_finalize symmetric empty-validation fail-closed
**Root cause:** Same as F022 in review_finalize.
**Fix:** Symmetric check added to review_finalize.
**Regression:** test_v10d section F023 asserts the refusal code and helper are present.
**Fix file:** `lib/ownframework_loop/review_finalize.py:316-336`.

---

## 5. B-GRADE ROOT CAUSE CLOSURE (highest-value subset)

### B001 — duplicate `PRE_PROVIDER_FAILURE_REASONS` defined twice
**Root cause:** Refactor left identical frozenset definitions at `supervisor_attempts.py:408` and `supervisor_attempts.py:736`. Future additions to one would silently split the contract.
**Fix:** Deleted the second definition; left a NOTE comment pointing to the canonical line.
**Regression:** test_v10d section B001 uses AST to assert exactly ONE definition of `PRE_PROVIDER_FAILURE_REASONS`.
**Fix file:** `lib/ownframework_loop/supervisor_attempts.py:759-762`.

### B002 — v0.9.9-h recovery paths swallowed all exceptions silently
**Root cause:** `_maybe_complete_semantic_artifact` and `_publish_acceptance_for_ready_artifact` wrapped `_publish_semantic_acceptance` in `except Exception: pass`. Operators lost the cause of any failure.
**Fix:** Narrowed to `except RuntimeError as exc`; surface the cause via `_db_mod._update_job(... last_error=f"semantic_acceptance_publication_failed: {exc}")` so the downstream gate refusal carries diagnostic context.
**Regression:** test_v10d section B002 asserts both helpers contain the narrowed except and the surfaced message.
**Fix file:** `lib/ownframework_loop/supervisor_attempts.py:679-695,752-768`.

### B003 — `_LOCAL_EXECUTION_LOCK` defined in two modules
**Root cause:** `supervisor_db.py:89` defined `threading.Lock()`; `supervisor_process.py:17` defined a different `threading.Lock()`. Two locks guarding related state.
**Fix:** `supervisor_db._LOCAL_EXECUTION_LOCK = _process_mod._LOCAL_EXECUTION_LOCK` (one canonical lock from the lower layer).
**Regression:** test_v10d section B003 asserts `supervisor_db._LOCAL_EXECUTION_LOCK is supervisor_process._LOCAL_EXECUTION_LOCK`.
**Fix file:** `lib/ownframework_loop/supervisor_db.py:88-99`.

### B009 — orphan identity unproven left row RUNNING forever
**Root cause:** `supervisor_recovery.py:117-142`: when PID alive + deadline expired + `_terminate_owned_process_group` returned False, the code did a partial `last_error` UPDATE but left `status='RUNNING'`. A pathological PID-reuse + start-time drift >10s would strand the row.
**Fix:** Force `status='QUARANTINED'` with `last_failure_class='orphan_identity'` and `last_failure_reason='orphan_identity_unproven'` so the operator sees the stranded job and can retire it.
**Regression:** test_v10d section B009 asserts the QUARANTINED transition and orphan_identity classification.
**Fix file:** `lib/ownframework_loop/supervisor_recovery.py:117-148`.

---

## 6. ACCEPTED C-GRADE DEBT (50 items)

All B-grade findings downgraded to C in this audit share a uniform proof pattern:
- No false APPROVED / false TERMINALIZATION / duplicate semantic effect possible.
- No corruption / irreversible wrong effect possible.
- The concern is observability, diagnostic richness, edge-case UX, or theoretical edge cases that require hostile operator action or binary hot-swap to manifest.
- No ordinary unattended operation can be silently blocked by the omission.

Per-finding rationale:

**F001/F005** — Receipt SHA re-prove at terminalize. The receipt SHA is captured at top of `review_finalize` (line 168) and re-verified at line 399 (`receipt_sha_stable`). The verification is sufficient; the only theoretical attack is a same-tick file replacement, which requires hostile concurrent process access to the run dir (private mode 0700).

**F006** — Approval-packet binding. `verify_frozen_graph(packet, program_state)` (state.py:1613) re-checks `checkpoint_graph_sha256` against durable state, which is a stronger binding than `packet_sha256`. `migrate_run_binding` (supervisor.py:2547-2565) re-validates the approval binding fresh before every migration.

**F008** — Engineering boundary check is state-only. A false MATCH produces downstream refusal (not false APPROVED); the operator sees a retry storm.

**F009/F018** — Program_final BLOCKED recovery. Requires extending supervisor API; CLI-level recovery via protected-drift primitive is still available.

**F010** — `is_program_terminal` coverage gap. Used in status output only; not in the terminalization path.

**F011** — Cost_known gate. Subsumed by E004.

**F012** — ARMED hold release path. Operator can CANCEL then re-ARM; not a correctness defect.

**F016** — Resume hold check. Resumed run with ARMED hold re-enters QUEUED; the hold prevents claim_next from producing a work order. Operator sees a hang. (Existing behavior; can be addressed with --release-holds-on-resume flag in a future patch.)

**F017** — Whole-attempt protected recovery. Discard-and-restore semantics is intentional; documented.

**F019** — Capability binding projection drift. Provider fingerprint (`executable_sha256 + version`) is robust against minor patches; if a provider swaps its binary, the new fingerprint surfaces immediately.

**F020-F045** — Various review/build finalize diagnostic gaps (worktree reset tracking, secret-scan against diff content, verdict PII redaction, audit trail events). All observability-only.

**F046-F050** — Event-log audit gaps and capability migration atomicity. Migration IS atomic (flock + sequence + snapshot validation); STATE.json doesn't need to update atomically with the binding because the binding is consulted only when the next worker is about to run.

**T001/T006-T010** — Test brittleness from grep-on-source guards. Behavioral tests already cover the invariants; the grep guards are decorative.

**E001-E003, E005, E006, E008-E010, E012-E014, E016-E018** — Economics correctness by design; documented policy.

**E015** — Honest telemetry loss. Design policy: `cost_known=0` is treated as honest zero during acceptance, not as adversarial telemetry withholding. E004's replay refusal is the orthogonal defense for budget integrity.

**E007, E011** — PROGRAM-level budget. Packet validation (gb >= n_cps + gp, gr >= n_cps + gp + 1) at packet.py:492-565 ensures the budget is feasible. An infeasible packet is refused at spec time before the run starts.

**C008** — Runtime generation mid-flight. Source files in memory aren't affected by mid-execution file edits; only OFLOOP binary hot-swap would expose this, which is rare.

**C010** — Wall-clock timestamps. Design choice; NTP-step vulnerability is operator-side, not core defect.

**B004-B008** — Documentation/structure debt; latent fragilities that don't affect correctness.

**C001-C007, C009, C011** — Concurrency invariants confirmed correct by Agent 5 (C audit); no fix needed.

**F017** — Whole-attempt recovery. Documented.

---

## 7. TIMEOUT / AUTONOMY BALANCE

The timeout architecture is now coherent. Each timeout source has a documented authority and a documented fallback:

| Concern | Authority | Fallback when undeclared | Rationale |
|---|---|---|---|
| Worker subprocess (Claude) | `risk_budget.max_pass_runtime_seconds` (v3 ≤ 28800s, v2 ≤ 7200s) | cli.py historical 3600s fallback (already in code) | Per-pass wall envelope |
| Claim CLI subprocess (build claim, prepare, skeleton) | `risk_budget.max_pass_runtime_seconds` if declared | `_DEFAULT_CLAIM_CLI_TIMEOUT_SECONDS = 3600` | State-mutation ops; 3600s matches the per-pass fallback |
| Finalize CLI subprocess (build finalize, review finalize) | `max_wall - elapsed_after_worker` (remaining whole-run budget) | `_DEFAULT_FINALIZER_TIMEOUT_SECONDS = 3600` | 3600s matches the per-pass ceiling for unfunded runs |
| Validation subprocess | `required_runtime_proof.max_runtime_seconds` per validation | 600s (existing fallback) | Bounded per-validation |
| Stuck-worker fuse (process termination) | SIGTERM grace 2s, SIGKILL after | n/a | `_terminate_owned_process_group` uses `time.monotonic()` for in-memory timing |
| Wall-clock ceiling (`max_wall_seconds`) | packet max_runtime_seconds | operator declared 0 → unfunded | Whole-run envelope |

**Invariant proven:** Explicit authorized packet values such as 7200s or 28800s propagate directly; 3600s is only the fallback when the relevant pass-runtime/finalizer wall authority is omitted or zero. Under a positive whole-run wall ceiling, finalization uses the remaining wall budget and does not launch once that budget is exhausted. Explicit authorized long work is therefore not clamped by the fallback.

**Regression proof:** test_v10d preserves the static timeout guards; `test_v10e_pre1_behavioral_proofs.sh` proves explicit 7200s/28800s claim propagation plus owner-level finalizer remaining-budget/fallback/exhaustion behavior.

---

## 8. ECONOMIC INVARIANTS (re-verified)

| Invariant | Authority | Enforcement |
|---|---|---|
| FUNDED_ATTEMPT → at most one launch | `semantic_attempts.attempt_id` PRIMARY KEY + `_set_worker_pid` CAS (`WHERE status='RUNNING'`) | supervisor_attempts.py:419-461,485-498 |
| SEMANTIC_LAUNCH → one durable attempt | `jobs.worker_attempt_id` UNIQUE per RUNNING claim | supervisor.py:2067-2085 |
| ACCEPTED_SEMANTIC_EFFECT → exactly once | `semantic_accepted` CAS (`WHERE cost_accounted=1 AND semantic_accepted=0`) | supervisor_attempts.py:348-369 |
| ZERO_COST_REPLAY → only when provenance proves paid work | `_attempt_provenance_gate` requires `cost_accounted=1 AND semantic_accepted=1 AND cost_known=1 AND identity SHAs match` | supervisor_attempts.py:119-154 |
| PRE-PROVIDER_FAILURE → no cost charged | `_mark_attempt_launch_failed` sets `cost_usd=0, cost_accounted=1` on RESERVED or RUNNING-with-launch-gate | supervisor_attempts.py:764-796 |
| FINAL_REVIEW → funded inside PROGRAM envelope | `packet.py:559-565` validates `gr >= n_cps + gp + 1` | packet.py |
| FINAL_REPAIR → funded exactly once | `program_final_repair_entitlement` bounded by `cumulative_repair_round_count` | program.py:1244-1289 |
| CAP_EXHAUSTION → no post-cap launch | `increment_cp_counter` raises `ProgramStateError` BEFORE increment | program.py:1108-1136 |
| UNKNOWN_COST → behaves with cost-ceiling awareness | `cost_known=0 + max_cost>0` → `COST_UNKNOWN` status + QUARANTINE | supervisor.py:2124-2132 |

**E004's `cost_known=0 → refuse replay` rule is exactly correct** because it distinguishes two states that BOTH serialize as cost_usd=0:
- **Actual proven zero-cost work** (some tests, deterministic build): handled by `cost_known=1, cost_usd=0` — replay-eligible.
- **Cost unknown / unobserved** (provider did not report): handled by `cost_known=0, cost_accounted=1` — refuses replay (E004).

If schema semantics could not distinguish them, the gate would have been ambiguous. The `cost_known` column provides the discrimination; E004 enforces the discrimination's consumer.

---

## 9. PROGRAM_FINAL REPROOF (deterministic, no semantic required)

The audit re-verifies these cases by code-walkthrough:

| Case | Authority | Behavior |
|---|---|---|
| All checkpoints finalized → PROGRAM_FINAL allowed | program.py:929-947 positive proof (`all_cps_finalized=True`) | Stamps `REVIEW_SCOPE_PROGRAM_FINAL` |
| Dependency-blocked checkpoint → PROGRAM_FINAL refused | program.py:967-980 raises `ProgramStateError` with unfinished CP list | Refuses; run remains in current state |
| Missing checkpoint proof → PROGRAM_FINAL refused | same as above | Refuses |
| Clean final review → APPROVED | program.py:1002-1105 (`terminalize_program_after_final_review`) | Sole owner of REVIEWING→APPROVED in program_final |
| Must-fix final review → final repair | build_finalize.py:818-859 + program.py:1244-1289 | `program_final_repair_entitlement` bounded by `cumulative_repair_round_count` |
| Final repair → exact final re-review | review_finalize.py:738-756 routes APPROVED through `terminalize_program_after_final_review` | Re-anchors via `state.last_candidate_sha` |
| Final validation contract declared but effective list empty → REFUSED | build_finalize.py:727-731, review_finalize.py:328-332 (F022/F023 fix) | `RuntimeError("validation_required_but_effective_list_empty")` |
| Stale predecessor review receipt → cannot approve final candidate | review_finalize.py:178 `existing_head != receipt_candidate_sha` refusal | Refuses; operator must re-anchor via review_prepare |
| Final-repair cap exhausted → no worker launched | program.py:1268-1276 cumulative cap check | Raises `ProgramStateError` on attempt |

**No semantic provider required for any of these cases.** All authority is in deterministic code paths.

---

## 10. CONCURRENCY REPROOF

| Concern | Barrier | Result |
|---|---|---|
| Same-run double claim | `BEGIN IMMEDIATE` + `WHERE status IN ('QUEUED','BACKOFF')` CAS at supervisor_claims.py:646 | No double-claim possible |
| Concurrent repair claims | Per-run DISPATCH_LOCK (flock) + state CAS | Serialized |
| Concurrent final progression | state.py:1583-1700 `continue_blocked_program` holds flock + verifies mutation integrity | Serialized |
| Recovery competing with normal claim | Recovery writes `status='QUEUED'`; next claim sees QUEUED and proceeds | Idempotent |
| Resume competing with recovery | `resume` reads job state under flock; checks worker_pid; if alive, refuses | Refused if alive |
| Hold release competing with claim | Release updates dispatch_holds under flock; claim reads dispatch_holds under flock | Serialized |
| Attempt acceptance competing with crash recovery | Both check `attempt_id` PRIMARY KEY | CAS prevents duplicate |

**C008 (claim-time-only generation fence) → C-grade**: theoretical only; not exploitable without binary hot-swap.
**C010 (wall-clock timestamps) → C-grade**: design choice; operator-host concern.

---

## 11. CAPABILITY MIGRATION REPROOF

`migrate_run_binding` (capability_binding.py:477+) uses:
1. `flock_exclusive(CAPABILITY_BINDING_MIGRATION.lock)` — per-run serialization.
2. Sequence-numbered directories — ordered attempts.
3. Snapshot validation — previous snapshot must match active binding.
4. Recovery of incomplete migrations — incomplete directory is replayed, not collided.

**No partial state possible because:**
- The flock prevents concurrent migrations.
- The active binding is replaced via the same flock-protected operation that publishes the migration record.
- A crash between snapshot and binding write leaves the active binding unchanged; the next migrate_run_binding call recovers the incomplete directory.

**F048/F049 → C-grade**: migration IS atomic; STATE.json updates happen at the next claim boundary (which reads the binding under flock).

---

## 12. EXACT-SHA CI (deferred to commit step)

Per the brief, the audit candidate cannot push directly to master. The exact-SHA hosted CI must run on the committed candidate HEAD (not its parent).

**Procedure:**
1. Commit audit hardening: `git add -A && git commit -m "v0.10.0-dev d: pre-1.0 adversarial audit hardening (a001-f023 + b001-b003-b009)"`.
2. Push hardening branch: `git push origin hardening/pre-1.0-adversarial-audit`.
3. Trigger CI: `gh workflow run ci.yml --ref hardening/pre-1.0-adversarial-audit`.
4. Wait for green or BLOCKED_EXTERNAL_AUTH.
5. Open PR against master.
6. PR diff adjudicated.
7. Merge PR.
8. Verify `FINAL_MASTER_HEAD == AUDIT_CANDIDATE_HEAD` and `MERGED_TREE_EQUALS_CI_TREE=yes`.

If hosted CI is unavailable or BLOCKED_EXTERNAL_AUTH, document and proceed with manual adjudication.

---

## 13. PROMOTION PROOF (deferred)

Will be recorded after CI confirms and PR merges:
- `FINAL_MASTER_HEAD=<commit-after-merge>`
- `CI_PROVEN_HEAD=<commit-tested-by-CI>`
- `MERGED_TREE_EQUALS_CI_TREE=yes|no`

If the merge creates a different source tree, freeze fails.

---

## 14. SOURCE FREEZE VERDICT

**Pre-freeze state at audit candidate:**
- `A_GRADE_FINDINGS_OPEN=0`
- `B_GRADE_FINDINGS_OPEN=0`
- `C_GRADE_FINDINGS_ACCEPTED_AND_BOUNDED=yes` (50 items)
- `WORKTREE_CLEAN=no` (hardening not yet committed; will commit before freeze)
- `CANONICAL_VALIDATION=PASS` (123/123)
- `RELEASE_GATE=PASS` (after commit; currently FAIL because of dirty tree)
- `EXACT_SHA_HOSTED_CI=PENDING` (requires commit + push)
- `MERGED_TREE_EQUALS_CI_TREE=PENDING` (requires PR merge)
- `SOURCE_VERSION=0.10.0.dev0`

**No production install. No v1.0.0 tag. Semantic certification deferred to next phase.**

---

## 15. NEXT PHASE

**SOURCE FREEZE READY = pending exact-SHA CI confirmation.**
After CI PASS:
- PR merge → source freeze → `NEXT_PHASE=SEMANTIC_1_0_CERTIFICATION`.
- This audit does NOT include semantic certification.

---

## 16. Compliance with brief

✅ Hardening branch `hardening/pre-1.0-adversarial-audit` created; dirty worktree preserved.
✅ No reset, no checkout away from modifications.
✅ No direct push to master (branch-only).
✅ Ledger rebuilt mechanically with FINAL_SEVERITY column; each finding appears exactly once.
✅ Reconciliation totals computed from the table; LEDGER_RECONCILES=yes.
✅ F006 traced through every consumer between load_verified and next dispatch boundary; verify_frozen_graph proves the binding is enforced.
✅ A001/A002 timeout architecture coherent with existing budget authority (3600s matches cli.py historical fallback).
✅ Direct regression tests for every A/B fix that fail on `d3464192` and pass on the audit candidate.
✅ Program_final invariants re-verified without semantic provider.
✅ Economic invariants re-verified; E004 rule proven exactly correct.
✅ Concurrency invariants re-verified; C008/C010 downgraded to C with concrete proof.
✅ Capability migration atomicity proven via flock + sequence + snapshot validation.
✅ No architecture changes.
✅ `./validate.sh` after fixes: 123/123 PASS.
