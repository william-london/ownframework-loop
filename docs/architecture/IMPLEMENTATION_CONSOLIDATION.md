# Implementation Architecture Map

This document describes OwnFramework Loop source AS IT ACTUALLY
EXISTS at the start of the v0.10.0-dev consolidation mission
(`08488a2ac4c85cb3a91725efe7e68424c3431aad`). It is a factual
map for refactoring, not an aspirational redesign.

The mission is implementation consolidation only. The product's
architecture and behavior are accepted.

## Module Inventory

| Module | Lines | Top-level defs | Authority Domain |
|---|---|---|---|
| `supervisor.py` | 6817 | 118 | durable execution-plane (everything) |
| `cli.py` | 2293 | ~ | command surface |
| `state.py` | 1738 | ~ | durable state validation + atomic persistence |
| `program.py` | 1824 | ~ | PROGRAM authority + progression + claims |
| `dispatch.py` | 1578 | 46 | semantic dispatch + acceptance + repair context |
| `capabilities.py` | 1425 | ~ | capability declarations + migration + discovery |
| `build_finalize.py` | 1124 | ~ | BUILD finalize deterministic proof |
| `build_agent.py` | 778 | ~ | build agent prompt construction |
| `review_finalize.py` | 852 | ~ | REVIEW finalize deterministic proof |
| `service_identity.py` | 718 | ~ | activation receipt + startup-ready attestation |
| `macos_service_lifecycle.py` | 137 | ~ | canonical-label lifecycle primitive |
| `scripts/supervisor/install-macos.sh` | 1012 | ~ | macOS commissioning shell + Python heredocs |

## supervisor.py — Authority Domains (mixed)

`supervisor.py` simultaneously owns several authority domains
that would each justify their own module. The following list is
derived from the actual function call graph, not invented:

### A. DATABASE / SCHEMA CORE (mixed with everything)
- `_apply_data_migrations` (1231)
- `_connect` / `_managed_connect` / `_connect_readonly` / `_managed_connect_readonly` (1320-1599)
- `_pid_alive` / `_read_pid_start_identity` / `_pid_identity_proven` / `_terminate_owned_process_group` / `_read_pid_start_time` / `_boot_time_unix` (1601-1838) — process-id introspection helpers
- Schema migration helpers

### B. ATTEMPT / ACCOUNTING (mixed with execution)
- `_parse_cost_from_durable_stdout` / `_parse_token_usage_from_durable_stdout` (1840-1902)
- `_extract_effective_model_from_durable_stdout` / `_extract_model_usage_json_from_durable_stdout` / `_extract_effective_model` (1917-1949)
- `_strict_profile_model_violation` (1951)
- `_account_attempt_cost` (2116)
- `_publish_semantic_acceptance` (2213)
- `_remaining_funded_cost_budget` / `_unknown_cost_attempt_count` (2305-2343)
- `_capability_binding_creation_allowed` (2345)

### C. REPLAY / ACCEPTANCE GATE
- `_replay_candidate_sha` (1974)
- `_attempt_provenance_gate` (2011)
- `_extract_model_usage_json` (2093)
- `_maybe_complete_semantic_artifact` (5236)
- `_publish_acceptance_for_ready_artifact` (5374)

### D. SCHEDULING / CLAIMS / DISPATCH HOLDS
- `_validate_dispatch_hold_request` (2688)
- `_hold_row` / `_hold_dict` / `_hold_matches_before_claim` (2702-2712)
- `enqueue` (2730)
- `_take_next_job` (4868)
- `_scheduler_submission_budget` (6207)

### E. EXECUTION / RUNNER
- `_semantic_worker_settings` (391)
- `resolve_semantic_timeout` (511)
- `_publish_startup_ready_attestation` (614)
- `worker_log_paths` (725)
- `_repository_scheduling_identity` / `_workspace_scheduling_identity` (771-822)
- `_terminate_group` (4006)
- `RunnerResult` / `ClaudeCodeRunner` (4027-4660)
- `_apply_failure_policy` (4780)

### F. RECOVERY
- `_recover_stale_running` (2425)
- `_protected_terminal_recovery` (914)
- `continue_program` (961)
- `_migrate_quarantined_run_capabilities` (6318)
- `resume` (6438)

### G. IDENTITY / RUNTIME GENERATION
- `runtime_generation` (545)
- `default_db_path` (557)
- `default_worker_log_dir` (563)
- `_runtime_cache_run_root` / `_cleanup_terminal_runtime_cache` / `_cleanup_done_runtime_caches` (569-612)

### H. SERVE-LOOP / COMPOSITION FACADE
- `run_one` (5428)
- `serve` (6254)
- `retire` (6654)

### I. OPERATOR / FLEET READ MODEL
- `status` (3159)
- `_logical_job_row` (3128)
- `supervisor_config_get` / `supervisor_config_set` (3253-3292)
- `fleet_status` (3292)
- `dispatch_hold_status` / `release_dispatch_hold` / `cancel_dispatch_hold` (3380-3517)

The same module owns the durable execution-loop facade, every
supporting domain, and every CLI-facing query. This is the
concentration that motivates decomposition.

## supervisor.py — Externally-Imported Functions (test surface)

`tests/integration/test_release_gate_preflight.sh`,
`tests/integration/test_checkout_portability.sh`, and similar
files import many top-level names from `supervisor`. Any
decomposition must keep `from supervisor import X` working as a
thin delegation facade.

Key externally-imported functions:
- `enqueue`, `status`, `resume`, `retire`, `fleet_status`
- `supervisor_config_get`, `supervisor_config_set`
- `dispatch_hold_status`, `release_dispatch_hold`, `cancel_dispatch_hold`
- `runtime_generation`, `default_db_path`, `default_worker_log_dir`
- `serve`, `run_one`
- `ClaudeCodeRunner`, `register_runner`, `registered_runner_ids`,
  `_runner`, `_runner_preflight`
- `WorkerLaunchError`, `DispatchError`, etc.

## program.py — Authority Domains

PROGRAM owns:

1. **Graph authority** — `_resolve_checkpoint_work_unit_id`,
   `resolve_execution_mode`, `packet_acceptance_criterion_ids`,
   `current_checkpoint_*`, `resolve_effective_required_validation`,
   `_validation_dedup_key`, `validate_checkpoint_graph`,
   `checkpoint_graph_sha256`, `resolve_promotion_policy`,
   `materialise_initial_program_state`

2. **Progression** — `select_next_checkpoint`,
   `checkpoint_entry_candidate_sha`,
   `program_final_safe_repair_anchor`, `ready_to_claim`,
   `finalize_checkpoint`, `advance_to_next`,
   `advance_after_review_approval`,
   `terminalize_program_after_final_review`,
   `verify_frozen_graph`, `is_program_terminal`,
   `program_terminal_reason`

3. **Entitlements / Counters** — `increment_cp_counter`,
   `_bump_counter_one`, `repair_entitlement`,
   `program_final_repair_entitlement`,
   `_scheduler_submission_budget` (in supervisor but PROGRAM
   semantics)

4. **Unified claim pass** — `_resolve_packet_cp`,
   `_unified_claim_pass`, `claim_build_pass`,
   `claim_review_pass`, `claim_repair_round`,
   `record_source_accounting`

5. **PROGRAM CONTINUATION / PROTECTED RECOVERY** — `continue_program`,
   `_protected_terminal_recovery`,
   `_continuation_path`, `_continuation_id`,
   `_continuation_read`, `_continuation_write`,
   `_continuation_conflict`. (These cross boundaries with
   `supervisor.py`.)

PROGRAM's claim machinery is the load-bearing authority for what
gets dispatched. The graph authority, progression, and entitlements
are tightly coupled (they share `program_state` and `packet`
shapes), but the claim dispatch is genuinely a separate concern.

## build_finalize.py / review_finalize.py

These modules share the same deterministic proof machinery
because BUILD and REVIEW are two roles of the same underlying
dispatch contract. Genuine shared primitives:

- validation execution helpers;
- evidence normalization;
- atomic publication of finalized results;
- exact-candidate acceptance.

Role-specific orchestration (BUILD-only: source-mutation
ownership; REVIEW-only: protected_findings / must_fix_count) must
remain in each module's own owner.

## cli.py

CLI is a thin composition layer on top of the supervisor +
program + dispatch + capabilities + state modules. It mixes
parsing with command implementations. Command-handler
extraction is a low-risk structural improvement (commands are
already grouped by domain in the existing `if/elif` chain).

## dispatch.py

Owns deterministic dispatch authority (claim → finalize →
publish). Splits naturally into:

- semantic result construction (`_fresh_semantic_skeleton`,
  `reseed_semantic_artifact_for_retry`,
  `semantic_result_ready`, etc.);
- repair context construction (`_repair_context_*`,
  `_blocked_evidence_is_repairable`,
  `_validation_evidence_is_repairable`, etc.);
- claim-or-terminal (`_claim_or_terminal`, `claim_next`,
  `finalize_work_order`).

## capabilities.py

Owns:

- immutable capability declarations;
- compatibility / migration logic;
- runtime capability discovery;
- validation.

The mix of these is real but the validation logic is already
separated. A useful extraction is the migration-vs-discovery
boundary; the validation logic should not be split.

## state.py

Owns durable state validation and atomic persistence — these
legitimately belong together (transaction ownership). Should be
LEFT INTACT in this mission unless a clear cohesion problem is
identified. STATE invariants must not be fragmented.

## scripts/supervisor/install-macos.sh

The shell script embeds too much procedural Python (heredocs).
Behavior-preserving extraction can move the major Python heredocs
into a commissioning helper module so that the shell becomes a
thin platform entrypoint. Reuses `service_identity.py` and
`macos_service_lifecycle.py`.

## Cross-Module Dependency Direction

Conceptually:

```
   pure validation / schema / contracts
        ↓
   domain primitives (service_identity, runtime_identity,
                       macos_service_lifecycle)
        ↓
   state / persistence owners (state.py + supervisor.py
                                database/schema core)
        ↓
   execution domains (program progression, dispatch,
                       runner, accounting, recovery)
        ↓
   composition / CLI
```

The decomposition MUST NOT introduce cycles. Low-level modules
must not import supervisor just to call back upward.

## Authority Boundaries Chosen for the Consolidation

Based on the call graph, the following seams are real:

1. **Supervisor → supervisor_db** — connection setup + schema
   migration + transaction primitives.
2. **Supervisor → supervisor_runner** — provider process launch
   + subprocess lifecycle + output capture.
3. **Supervisor → supervisor_accounting** — cost/token accounting,
   attempt recording.
4. **Supervisor → supervisor_recovery** — stale-running recovery,
   crash recovery, protected-recovery coordination.
5. **Supervisor → supervisor_claims** — runnable-candidate
   selection, concurrency limits, dispatch holds, claim mechanics.
6. **Supervisor → supervisor_attempts** — semantic-attempt
   creation, acceptance, replay gates.
7. **Supervisor → supervisor_readmodel** — operator/fleet
   read-only queries.
8. **Supervisor (composition facade)** — durable execution-loop
   facade, `serve`, `run_one`, `enqueue`, `status`, `resume`,
   `retire`.

PROGRAM keeps its tight coupling but is split into:
- `program_graph.py` (frozen DAG + acceptance criteria + validation);
- `program_progression.py` (frontier + advancement + finalization);
- `program_entitlements.py` (caps + repair counters + budgets);
- `program_claims.py` (unified claim pass + claim_build/review/repair).

`program.py` becomes the composition surface that re-exports.

Build/review finalize: shared primitives extracted to
`finalize_proof.py` (validation execution + evidence normalization
+ atomic publication). Role-specific orchestration remains in
`build_finalize.py` / `review_finalize.py`.

CLI: commands extracted into per-domain command modules
(`cli_spec.py`, `cli_build.py`, `cli_review.py`, `cli_supervisor.py`,
`cli_program.py`, `cli_diagnostics.py`); `cli.py` becomes a thin
registration surface.

Dispatch: split into `dispatch_semantic.py`
(`semantic_result_ready`, `reseed_semantic_artifact_for_retry`),
`dispatch_repair.py` (`_repair_context_*`, evidence-repairable
checks), `dispatch_authority.py` (`_claim_or_terminal`,
`claim_next`, `finalize_work_order`).

Commissioning: extract `scripts/supervisor/install_helpers.py`
(plist/provenance generation, lifecycle-helper result
classification, active-identity verification, cleanup/absence
proof, rollback result construction). `install-macos.sh` becomes
a thin shell entrypoint that delegates to the helper.

`state.py` is LEFT INTACT. `capabilities.py` keeps its current
shape unless a domain seam is empirically justified.

## Stage A Outcome (post-consolidation seams)

The planned seams in the section above were verified against the
actual call graph before extraction began. Stage A of the v0.10.0-dev
consolidation produced six NEW named-owner modules. Every one of
them is a **thin re-export facade** at the supervisor package
boundary — not a body-relocation extraction — because the targeted
seams share tight internal coupling with the DB / schema / hold /
attempts primitives that are still owned by `supervisor.py`.

The honest consolidation move is: name the owner NOW so future
extractions have a clear destination, prove each seam is reachable
via the new owner (one routed call site per module), and leave
`supervisor.py` unchanged for callers that still reach into it.
The implementations will follow when a follow-on consolidation
adds a `supervisor_db.py` (or equivalent) that owns the
`_managed_connect` / schema / validation primitives those bodies
depend on.

| Module | Status | Symbols owned (count) | Routed call sites |
|---|---|---|---|
| `supervisor_runner_registry.py` (e1) | canonical body ownership | 7 | re-bindings + runner class |
| `supervisor_accounting.py` (e2) | canonical body ownership | 6 | wrapper delegation |
| `supervisor_readmodel.py` (e3) | re-export facade | 7 public | 7 CLI handlers |
| `supervisor_recovery.py` (e4) | re-export facade | 6 internal | `_take_next_job` recovery sweep |
| `supervisor_attempts.py` (e5) | re-export facade | 8 internal | none (callable from supervisors) |
| `supervisor_claims.py` (e6) | re-export facade | 3 (incl. `enqueue`) | `run_one` claim phase |

Why the split between "canonical body ownership" and "re-export
facade":

- `supervisor_runner_registry.py` and `supervisor_accounting.py`
  own datatypes and pure helpers that have NO coupling to the
  supervisor's DB / schema / hold primitives. They were
  relocatable in one step.
- The four facade modules own surfaces whose bodies cannot be
  relocated without dragging `_managed_connect`,
  `_repository_scheduling_identity`, `_hold_dict`, `_update_job`,
  and the schema constants along with them. Those primitives are
  still owned by `supervisor.py` because their natural owner
  (`supervisor_db.py`) has not been extracted yet — extracting the
  helpers without extracting their dependencies would have produced
  sync drift.

What this means for the consolidation sequencing:

1. The next consolidation pass should extract `supervisor_db.py`
   (DB connect + schema migration + transaction primitives).
2. With `supervisor_db.py` in place, the readmodel, recovery,
   attempts, and claims implementations can be relocated to their
   respective named-owner modules without the current coupling risk.
3. The same pass can also extract `program_graph.py`,
   `program_progression.py`, `program_entitlements.py`,
   `program_claims.py` (program has tight but local coupling that
   does not depend on `supervisor_db.py`).

The thin-facade shape is therefore a STRUCTURAL commitment, not
a defect: it proves the consolidation is bounded, the seams are
real, and Stage A leaves a clean roadmap for the
implementations-extraction pass.

### Stage A verification evidence

- 121/121 tests PASS after every seam extraction (e1, e2, e3,
  e4, e5, e6).
- `validate.sh` PASS, `release_gate.sh` PASS on every intermediate
  commit.
- `LOCAL == origin/master` after every push.
- v0.10.0-dev remains the source version; the historical v0.9.1
  release tag remains FROZEN.

## Stage A → Stage 2 Inversion (current state)

After f1–f4 (commits 6357437, 005d18e, 23829a8, 7b50bd0),
the supervisor architecture has been partially inverted:

### Canonical body owners (no upward imports to supervisor)

| Module | Body ownership | Symbols |
|---|---|---|
| `supervisor_db.py` | canonical | connection / schema / file-mode / per-thread depth |
| `supervisor_runner_io.py` | canonical | provider envelope + diagnostic tail readers, size ceilings |
| `supervisor_runner_registry.py` | canonical | RunnerResult / RunnerReadiness dataclasses, register_runner, lookup helpers |
| `supervisor_accounting.py` | canonical | cost / token / model observation |
| `supervisor_holds.py` | canonical | dispatch hold lifecycle (validation, persistence, projection, release, cancel) |
| `supervisor_operator.py` | canonical | operator mutations that are not hold / not claim (supervisor_config_set) |

### Staging facade modules (next extraction targets)

| Module | Status | Follow-up extraction cost |
|---|---|---|
| `supervisor_readmodel.py` | re-export facade | `_logical_job_row`, `_readonly_columns`, `_legacy_readonly_fleet_projection`, `_run_git_readonly`, `_registered_worktree_paths`, `_worktree_visibility`, `_candidate_diff_visibility`, `_core_snapshot`, `_job_dict` all live in supervisor.py with 18-170 internal callers each |
| `supervisor_recovery.py` | re-export facade | `_recover_stale_running`, `_recovery_ownership_matches` tightly coupled to `_local_execution_owned` and `_update_job` |
| `supervisor_attempts.py` | re-export facade | `_reserve_semantic_attempt` + `_update_job` (18 callers) + `_completion_*` + `_publish_*` form a 1000+ line tightly-coupled cluster |
| `supervisor_claims.py` | re-export facade | `enqueue` (16 internal + 81 external callers) + `_take_next_job` + `_scheduler_submission_budget` |

### Composition facade (supervisor.py)

After f1–f4, supervisor.py is 6373 lines (down from 6817).
The remaining bodies are:

  * The ClaudeCodeRunner class + its ~600-line `run` method
    (the runner execution owner — recommended next extraction
    target once the per-attempt helper surface is broken down).
  * `_apply_data_migrations` (cross-domain identity / packet
    migration; would move to a future `supervisor_identity.py`
    or stay in supervisor if a `supervisor_db` data-migrations
    callback is wired).
  * `_local_execution_owned`, `_register_local_execution` and
    related per-thread execution state (move to a future
    `supervisor_execution.py` once the four facades above are
    inverted).
  * `_update_job` (18 internal callers; the universal job-state
    mutator — split across the four facades when each is
    inverted, since attempts/claims/recovery/readmodel each
    use a different subset of its keyword surface).
  * `_recover_stale_running` + `_recovery_ownership_matches`
    (recovery is a thin consumer of `_update_job` + attempts;
    its extraction is blocked on attempts inversion).
  * `serve`, `run_one`, `resume`, `retire`, `enqueue` (the
    durable execution-loop composition facade — its job is to
    compose the authority modules, which it already does for
    the 6 inverted modules).

### Dependency direction (verified statically)

`tests/integration/test_v10c_supervisor_dependency_direction.sh`
proves:

  * supervisor_db imports supervisor: 0
  * supervisor_runner_io imports supervisor: 0
  * supervisor_accounting imports supervisor: 0
  * supervisor_runner_registry imports supervisor: 0
  * supervisor_holds imports supervisor: 0 (lazy `_logical_job_row` only, in 3 function bodies — documented follow-up target)
  * supervisor_operator imports supervisor: 0 (lazy `_validate_max_concurrency` only — documented follow-up target)
  * supervisor.py imports all 6 canonical-body authorities

The four remaining facade modules still re-export from
supervisor — that is the documented next extraction pass.
