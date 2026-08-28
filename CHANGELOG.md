# Changelog

All notable current-release changes to OwnFramework Loop are documented here.
The complete historical changelog through 0.5.2 is preserved at
[`docs/history/CHANGELOG-through-0.5.2.md`](docs/history/CHANGELOG-through-0.5.2.md).

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
