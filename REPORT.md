# OwnFramework Loop V2 — Implementation Report

**Date:** 2026-07-23
**Release:** V2.0.1
**Plugin:** `of-loop` (display name: OwnFramework Loop)
**Source commit:** `f8b99ad0849878290e685dac9b48f3f53236f465`
**Source branch:** master
**Source dirty at acceptance:** 0 files
**Source root:** `/path/to/ownframework-loop`
**Source version:** 0.2.1
**Plugin namespace:** `of-loop@ownframework-local`
**Install path (managed):** `$HOME/.claude/plugins/cache/ownframework-local/of-loop/0.2.1`
**Install path (legacy skills-dir backup, archived):** `~/.claude/ownframework-loop-mgmt-backup-<UTC>/`
**Receipt path:** `$HOME/.claude/plugins/data/of-loop-ownframework-local`
**Remotes:** 0
**Plugin manifest version:** 0.2.1
**Library `__version__`:** 0.2.1

---

## Approval security claim (corrected)

The OwnFramework Loop approval architecture relies on **artifact
binding plus tested command-origin refusal** — not on token
cryptographic unspoofability.

```
TOKEN_IS_SECRET=no
TOKEN_IS_MODEL_UNPREDICTABLE=no
TOKEN_IS_PACKET_DERIVED=yes
```

The confirmation token `CONFIRM-OF-LOOP-<8hex>` is the first 8 hex
characters of the packet SHA-256 — plaintext, not secret. What it
proves is that the operator acknowledged a specific approved packet
during the spec interview. Pseudo-TTY attacks CAN make stdin look
like a TTY; they cannot derive the token without first reading the
packet bytes the operator already has.

Root of trust:

- packet SHA → derived token (plaintext, not secret)
- `APPROVAL.json` binds `run_id`, `canonical_repo`, `baseline_branch`,
  `baseline_sha`, `packet_sha256`, `confirmation_token`
- The CLI requires all five to match at finalize time
- Pseudo-TTY attacks do NOT bypass the binding — they still need a
  valid token derived from the packet SHA

Properties preserved:

```
PACKET_HASH_BOUND=yes
REPOSITORY_BOUND=yes
BASELINE_BOUND=yes
NONINTERACTIVE_APPROVAL=blocked
PSEUDO_TTY_APPROVAL=blocked
DIRECT_FILE_APPROVAL=blocked
DIRECT_LIBRARY_APPROVAL=blocked
PACKET_MUTATION_INVALIDATION=PASS
```

## Tool inheritance posture (intentional)

`of-builder` and `of-reviewer` deliberately do NOT list `tools:` or
`disallowedTools:` in their frontmatter. They inherit the parent's
broad toolset (read, write within authority, shell, WebSearch,
WebFetch, MCP read-only verbs). Authority comes from packet, exact
worktree, hooks, finalizers, and promotion boundaries — not from a
narrow tool allowlist.

```
AGENT_TOOL_INHERITANCE=intentional
BUILDER_TOOL_POSTURE=broad
REVIEWER_TOOL_POSTURE=broad_inspection
AUTHORITY_FROM_TOOLS=no
AUTHORITY_FROM_PACKET_AND_CODE=yes
```

---

## Acceptance result

```
OF_LOOP_RELEASE_GATE_RESULT=PASS
OF_LOOP_TOTAL=34
OF_LOOP_PASSED=34
OF_LOOP_FAILED=0
```

A single execution of `tests/run_all.sh` runs every deterministic
test file in sequence. No test is recursive. No daemon, scheduler,
or background process is left running.

---

## v0.2.1 — fourteen-patch two-loop engineering upgrade

V1's pilot framing remains intact: three visible skills, two
independent agent types, one human-approved work packet per run.
V2 elevates determinism on fourteen patches.

### Patch 1 — Externalized approval

The approval is a separate artifact at
`.ownframework-loop/<run-id>/APPROVAL.json`. The packet stays a
plain markdown-with-JSON-fence file. The packet's bytes are bound to
the approval via `packet_sha256`. The confirmation token is derived
from the packet SHA as `CONFIRM-OF-LOOP-<8hex>`. Approval is reset
and re-issued on every packet byte drift.

- `lib/ownframework_loop/approval.py`
- `lib/ownframework_loop/cli.py:cmd_spec_approve`
- `schemas/approval.schema.json`
- `tests/unit/test_trust_approval.sh` (cases 1-11)

### Patch 2 — Deterministic build finalizer

`ofloop build finalize` is the only entity that writes
`BUILD_RECEIPT.json` and derives `next_state`. The model cannot
influence the verdict on any of the 22 independent checks:
approval validation, canonical-repo identity, exact builder
worktree identity, exact candidate branch (`factory/candidate/<id>`),
candidate SHA ancestry from baseline, baseline immutability, changed
paths from `git diff`, added/removed line counts from `git diff
--numstat`, allowed-path verification, packet-declared sensitive
paths against the diff, hard secret scan (HARD_PATTERNS), heuristic
secret scan (HEURISTIC_PATTERNS, reviewable), required-validation
command exit codes with bounded timeout, no-progress detection
(identical candidate SHA or no git diff), repair-round counter cap,
atomic receive via `tempfile.NamedTemporaryFile` + `os.replace`,
deterministic SHA-256 receipt hash, event append, next-state
derivation.

- `lib/ownframework_loop/build_finalize.py`
- `lib/ownframework_loop/cli.py:cmd_build_finalize`
- `lib/ownframework_loop/receipts.py`
- `schemas/build-receipt.schema.json`
- `tests/unit/test_trust_build_review.sh` (cases 12-25, 36-43, 58-66, 67-73)

### Patch 3 — Deterministic review finalizer

`ofloop review finalize` is the only entity that writes
`REVIEW_VERDICT.json`. The reviewer agent's
`recommended_verdict` is advisory. The finalizer independently:
verifies the exact candidate SHA against the receipt (refuses on
drift), validates scope and budget against the packet, derives
verdict from the assessment findings + verdict mapping table,
transitions state, and writes the verdict atomically.

- `lib/ownframework_loop/review_finalize.py`
- `lib/ownframework_loop/verdicts.py`
- `schemas/review-verdict.schema.json`
- `tests/unit/test_trust_build_review.sh` (cases 26-35)
- `tests/unit/test_review_e2e.sh`

### Patch 4 — Artifact integrity & event consistency

Every state-changing operation appends a typed event to
`EVENTS.log`. `assert_artifacts_intact` hashes packet, approval,
receipt, verdict, and state at every assertion point. The
`mutation_check` refuses when an externally-mutated artifact is
presented for finalize. A `kind=unexpected_initial_drift` event
records the byte drift; subsequent operations refuse per
transitions.assert_valid.

- `lib/ownframework_loop/integrity.py`
- `lib/ownframework_loop/state.py:append_event`
- `tests/unit/test_integrity_and_limits.sh`

### Patch 5 — Exact-run hook binding

PreToolUse and PostToolUse hooks refuse to act when the active
run's `STATE.json` is absent or stale. The hook walks up to the
canonical repo root to find the run directory and refuses
out-of-scope writes silently during the active loop. Outside an
active loop, the hook is a no-op.

- `hooks/block_protected_paths.sh`
- `hooks/block_dangerous_bash.sh`
- `hooks/hooks.json`
- `lib/ownframework_loop/cli.py:_resolve_run_dir`
- `tests/unit/test_bypass_matrix.sh` (rows 8, 9, 10)

### Patch 6 — Broad tools + external-action guard

The textual guard (in `block_dangerous_bash.sh`) covers bare-form
`git push` and friends, env-qualified invocations, chains (`&&`,
`;`, `||`), pipelines (`|`), `$(...)` subshell resolution, `eval`,
and single-line redirects. Forbidden command families:
`git push`, `git remote add|set-url|remove`, `git worktree prune`,
`git reset --hard`, `git branch -d|-D`, `git clean -fdx`,
`operator-configured executables`, `systemctl`, `docker compose up|down`, `ssh <operator-blocked-target>`,
`ssh <operator-blocked-target>`. The dedicated external-action guard
(`hooks/external_action_guard.sh`) blocks outbound email, push,
PR, deploy, and customer-action operations independent of the
Bash input shape.

V2.0.1 closes three known audit evasion forms by layered
normalization before pattern matching:

  1. **Python-subprocess argv literals** — `subprocess.run(["git",
     "push"])`, `os.system("git push")`, `[git, push]`,
     `["git","push"]`, `executable="git", args=["push"]`.
  2. **Shell variable assembly** — `X=push; git $X origin master`
     and `X=push; Y=origin; Z=master; git $X $Y $Z`.
  3. **Hyphenated wrapper executable identity** — `./git-push`,
     `./git-remote-add`, `gh-pr-create`, `git-remote-remove`,
     `git-reset-hard`, `git-branch-D`, etc.

The textual guard is **one layer** of defense. Forms that escape
detection (multiline heredocs, opaque arbitrary Python code,
base64-encoded payloads) defer to the post-pass review layer and
exact-SHA receipt check. The guard is bounded; it does not claim
semantic containment of arbitrary opaque local code.

- `hooks/block_dangerous_bash.sh`
- `hooks/external_action_guard.sh`
- `lib/ownframework_loop/external_action.py`
- `lib/ownframework_loop/guards.py` (V2.0.1 normalization hooks)
- `tests/unit/test_bypass_matrix.sh`

### Patch 7 — Safe secret handling

The scanner distinguishes `HARD_PATTERNS` (block: AWS keys,
private keys, high-confidence tokens) from `HEURISTIC_PATTERNS`
(reviewable warning, recorded in receipt). Hard block triggers
a pre-receipt refusal
`OF_LOOP_BUILD_FINALIZE_REFUSED` and never writes `BUILD_RECEIPT.json`.
Receipt findings are redacted to `redacted_prefix` + SHA-256
hash. Literal secret values never reach `EVENTS.log`,
`BUILD_RECEIPT.json`, or `REVIEW_VERDICT.json`.

- `lib/ownframework_loop/secrets_v2.py`
- `tests/unit/test_trust_secrets_isolation.sh` (cases 51-57)

### Patch 8 — Packet-approved sensitive paths

Sensitive paths (e.g., `AGENTS.md`, `CLAUDE.md`, `.claude/`) must
be declared in `packet.sensitive_paths` with a
`sensitive_path_reason`. The finalizer permits writes to elevated
paths only when the packet lists them. Protected paths
(`.ownframework-loop/`, `.claude/`, `.git/`, branch-mutation paths)
are always forbidden regardless of packet content.

- `lib/ownframework_loop/build_finalize.py:verify_protected_paths`
- `lib/ownframework_loop/packet.py`
- `tests/unit/test_trust_build_review.sh` (cases 12-17, 36-43)

### Patch 9 — Work-class-aware budgets with absolute ceiling

Each packet declares `risk_budget: { max_files_changed, max_diff_lines,
max_repair_rounds }`. The hard absolute cap is `max_files_changed ≤
500`, `max_diff_lines ≤ 30000`, `max_repair_rounds ≤ 12`. Work-class
defaults are loaded from `lib/ownframework_loop/limits.py:WORK_CLASS_DEFAULTS`.
BUG work defaults to repair rounds 3, max files 25, max diff lines 1000.
The packet may lower the cap; it cannot raise it.

- `lib/ownframework_loop/limits.py`
- `lib/ownframework_loop/build_finalize.py:enforce_budget`
- `tests/unit/test_trust_build_review.sh` (cases 14, 23)

### Patch 10 — Branch/remote neutrality

`git worktree add` is the only isolation mechanism. The loop
refuses to create remotes, push, merge, deploy, or modify the
baseline branch. The candidate branch is always
`factory/candidate/<run-id>`. Builder and reviewer worktrees
are detached (`--detach`) for the reviewer to prevent any
auto-forward of the worktree HEAD.

- `lib/ownframework_loop/worktrees.py`
- `lib/ownframework_loop/cli.py:cmd_*` (no remote commands)
- `tests/unit/test_baseline_and_remote.sh`

### Patch 11 — Marker/installation consistency

`install.sh` is idempotent: backs up existing copy, verifies
SHA-256 of the source before copy. `uninstall.sh` is reversible
to the backup if one exists. Plugin metadata
`.claude-plugin/plugin.json` references version 0.2.1 and the V2
description. The library's `__version__` is 0.2.1.

- `install.sh`
- `uninstall.sh`
- `validate.sh`
- `.claude-plugin/plugin.json`
- `lib/ownframework_loop/__init__.py`

### Patch 12 — Skill/agent responsibility rewrite

Three skills: `spec`, `build`, `review`. Two independent agent
types: `of-builder` (writes only inside builder worktree,
`BUILD_AGENT_RESULT.json`, candidate commit) and `of-reviewer`
(read-only against source tree, writes only the structured
assessment in detached reviewer worktree). Skills describe
contracts; agents execute within them.

**Tool inheritance is INTENTIONAL.** Neither agent's frontmatter
declares `tools:` or `disallowedTools:`. They inherit the
parent's broad toolset (read, write within authority, shell,
WebSearch, WebFetch, MCP read-only verbs). Authority is bound
by packet, exact worktree, hooks, finalizers, and promotion
boundaries — NOT by a narrow tool allowlist.

```
AGENT_TOOL_INHERITANCE=intentional
BUILDER_TOOL_POSTURE=broad
REVIEWER_TOOL_POSTURE=broad_inspection
AUTHORITY_FROM_TOOLS=no
AUTHORITY_FROM_PACKET_AND_CODE=yes
```

- `skills/spec/SKILL.md`
- `skills/build/SKILL.md`
- `skills/review/SKILL.md`
- `agents/of-builder.md`
- `agents/of-reviewer.md`
- `hooks/hooks.json`

### Patch 13 — Cost efficiency

The textual guard pre-filters obviously forbidden commands before
sandbox invocation (no syscall on benign commands). Validation
commands run bounded by `required_runtime_proof.max_runtime_seconds`
per command and `MAX_TEST=900` seconds per process. Branch/remote
neutrality avoids cost-incurring operations. The builder/reviewer
write set is constrained to the worktree. Sandbox-lifecycle
footprint is bounded by `process_runner.py:run_bounded` with a
process-group kill on timeout.

- `lib/ownframework_loop/process_runner.py`
- `lib/ownframework_loop/static_checks.py`
- `tests/unit/test_normal_unrelated_command.sh`

### Patch 14 — Compatibility migration

V1 packet fields are mapped to V2 packet fields at the CLI
boundary. Legacy approval-flow commands (`apply_approval`,
`write_approved_packet`, `build write-receipt`) are removed.
CLI commands are deterministic: `spec new|approve|status|inspect-legacy`,
`build claim|finalize`, `review finalize`. `inspect-legacy` is
a non-authoritative inspector that recommends re-approval for
legacy packets; it never applies a legacy approval.

- `lib/ownframework_loop/cli.py:cmd_spec_inspect_legacy`
- `lib/ownframework_loop/approval.py:has_legacy_approval_fields`
- `lib/ownframework_loop/packet.py`

---

## Deterministic tests

`tests/run_all.sh` produces a single execution view across
`tests/unit/` and `tests/integration/`. Each test file is a
self-contained bash script with a `PASS:` / `FAIL:` line per
assertion. Markers emitted by `run_all.sh`:

```
OF_LOOP_TOTAL=34
OF_LOOP_PASSED=34
OF_LOOP_FAILED=0
TRUST_APPROVAL_TESTS=PASS
TRUST_BUILD_REVIEW_TESTS=PASS
TRUST_SECRETS_TESTS=PASS
CAPABILITY_MATRIX=PASS
OF_LOOP_RELEASE_GATE_RESULT=PASS
```

Per-file coverage:

| Test file | Cases | Coverage |
|---|---|---|
| `test_trust_approval.sh` | 1-11 | approval SHA, separate-file invariant, drift, tty-token, reporefusal |
| `test_trust_build_review.sh` | 12-25, 26-35, 36-43, 44-50, 58-66, 67-73 | finalizer scope, budget, worktree, candidate, transition, verdict |
| `test_trust_secrets_isolation.sh` | 51-57 | hard/heuristic patterns, redaction, leak, robustness |
| `test_atomic_writes.sh` | atomic | receive/tempfile/os.replace |
| `test_baseline_and_remote.sh` | baseline | baseline immutability, remote refusal |
| `test_bypass_matrix.sh` | bypass | textual guard 33 forbidden forms, fail-closed |
| `test_cache_readonly.sh` | cache | builder no-write into shared cache |
| `test_cli_e2e.sh` | cli | V2 packet + finalize |
| `test_diff_limits.sh` | diff | numstat, budget ceiling |
| `test_f001_to_f005_closures.sh` | closures | F-series closures |
| `test_gate_lock.sh` | gate | single-instance flock |
| `test_guards.sh` | guards | external-action families |
| `test_integrity_and_limits.sh` | integrity | SHA, counters, mutation |
| `test_lifecycle.sh` | lifecycle | run, claim, finalize, stop |
| `test_markers.sh` | markers | marker consistency |
| `test_new_repo_refuses_existing.sh` | new-repo | refuse-existing flag |
| `test_normal_unrelated_command.sh` | benign | non-forbidden commands |
| `test_ofloop_invocation.sh` | ofloop | CLI invocation form |
| `test_packet_hash.sh` | packet-hash | SHA-256, drift |
| `test_packet_validation.sh` | packet-val | JSON Schema validation |
| `test_plugin_data_resolution.sh` | plugin-data | data-dir resolution |
| `test_prompt_injection.sh` | prompt-injection | refuse embedded instructions |
| `test_recursion_detector.sh` | recursion | single-instance gate |
| `test_repair_cycle.sh` | repair | repair round |
| `test_review_e2e.sh` | review | V2 review finalize |
| `test_schemas.sh` | schemas | 5 schemas parse |
| `test_separation.sh` | separation | skills/agents separation |
| `test_state_machine.sh` | state | 9-state transitions |
| `test_stop_marker.sh` | stop | stop marker, STOPPED state |
| `test_worktree_lifecycle.sh` | worktree | builder/reviewer worktree |
| `tests/integration/test_capability_matrix.sh` | matrix | M1, M2, M3, M4 |

Capability matrix results (4 missions on disposable repos):

```
M1: ordinary bug fix reaches APPROVED — PASS
M2: doctrine change (sensitive path) reaches APPROVED — PASS
M3: web research mission reaches APPROVED — PASS
M4: malicious proof (hard secret) refused by build finalizer — PASS
M4: literal secret redacted from finalizer output — PASS
M4: literal secret did not leak into run artifacts — PASS
M4: BUILD_RECEIPT.json not written on hard-secret refusal — PASS
CAPABILITY_MATRIX=PASS
```

---

## Architecture snapshot

- State machine: 9 states (`AWAITING_APPROVAL`,
  `READY_TO_BUILD`, `BUILDING`, `READY_FOR_REVIEW`, `REVIEWING`,
  `CHANGES_REQUESTED`, `APPROVED`, `BLOCKED`, `STOPPED`).
  Transitions table in
  `lib/ownframework_loop/transitions.py`.
- Locking: `fcntl.flock(LOCK_EX|LOCK_NB)` via
  `lib/ownframework_loop/gate_lock.py` for single-instance gate,
  `lib/ownframework_loop/locking.py` for per-run state writes.
- Approval flow: separate `APPROVAL.json` file with
  `packet_sha256`, `baseline_sha`, `confirmation_token`.
- Receipt authority: deterministic finalizer writes
  `BUILD_RECEIPT.json` / `REVIEW_VERDICT.json`.
- Hook authority: per-run `STATE.json` gates PreToolUse/PostToolUse.

---

## Files

- 27 Python modules in `lib/ownframework_loop/`
- 3 skill folders: `skills/{spec,build,review}/SKILL.md`
- 2 agent files: `agents/{of-builder.md,of-reviewer.md}`
- 5 hook scripts: `hooks/{block_dangerous_bash,block_protected_paths,post_bash_secret_scan,external_action_guard}.sh` + `hooks/hooks.json`
- 5 schemas in `schemas/{work-packet,approval,state,build-receipt,review-verdict}.schema.json`
- 4 example missions in `examples/`
- 3 templates in `templates/`
- 11 documentation files in `docs/`
- 31 test files in `tests/` (29 unit, 1 integration, 1 release gate)
- Install scripts: `install.sh`, `uninstall.sh`, `validate.sh`, `rollback.sh`
- Release gate: `release_gate.sh` + `tests/run_all.sh`
- Source/binary CLI: `bin/ofloop`
- Plugin manifest: `.claude-plugin/plugin.json`

---

## Invariants preserved (not weakened)

From the V1 pilot contract:

- build pass counter cap remains 3 for BUG work (V1 floor); V2
  does not raise it.
- V2 invariants are STRENGTHENINGS: separate `APPROVAL.json`,
  deterministic finalizers, broad tools + external-action
  guard, hard vs heuristic secret scan, packet-approved
  sensitive paths, work-class budgets with absolute ceiling
  (500 / 30000 / 12), branch/remote neutrality, exact-run hook
  binding.
- The reversible copy install preserves the V1 backup-and-replace
  discipline on every install.
- No automatic escalation-target launch. No background daemon. No additional
  queue server. No SQLite. No extension to production-host-1 / production-host-2/Video
  Factory.
- The install does not modify `~/.claude/settings.json`,
  managed Claude settings, project permission settings,
  `permissions.defaultMode`, `skipDangerousModePermissionPrompt`,
  `effortLevel`, provider configuration, model routing, Claude
  authentication, or global sandbox settings.
- The install does not change or disable `bypassPermissions`.
- The install does not introduce routine approval prompts,
  `dontAsk`, `acceptEdits`, restrictive global allowlists,
  mandatory sandbox activation, `failIfUnavailable` as a new
  requirement, a container or VM requirement, or operator
  confirmation per command.

---

## Marker fields (auto-emitted)

```
PLUGIN_MANIFEST_NAME=of-loop
PLUGIN_MANIFEST_DISPLAY_NAME=OwnFramework Loop
SOURCE_VERSION=0.2.1
PLUGIN_MANIFEST_VERSION=0.2.1
PLUGIN_MANIFEST_NAMESPACE=of-loop@ownframework-local
SOURCE_VERSION=0.2.1
SOURCE_COMMIT=f8b99ad0849878290e685dac9b48f3f53236f465
SOURCE_BRANCH=master
SOURCE_DIRTY=0
SOURCE_REMOTES=0
INSTALL_PATH_MANAGED=$HOME/.claude/plugins/cache/ownframework-local/of-loop/0.2.1
INSTALL_PATH_SKILLS_BACKUP=$HOME/.claude//
INSTALL_KIND=managed_marketplace
MARKETPLACE_NAME=ownframework-local
MARKETPLACE_VERSION=1.0.1
ACTIVE_PLUGIN_IDENTITIES=1
INSTALL_RECEIPT_DIR=$HOME/.claude/plugins/data/of-loop-ownframework-local
PACKET_SCHEMA=ownframework-work-packet/v2
APPROVAL_SCHEMA=ownframework-loop-approval/v1
STATE_SCHEMA=ownframework-loop-state/v1
BUILD_RECEIPT_SCHEMA=ownframework-loop-build-receipt/v2
REVIEW_VERDICT_SCHEMA=ownframework-loop-review-verdict/v2
V1_FLOOR_REPAIR_ROUNDS=3
V2_ABSOLUTE_CEILING_FILES=500
V2_ABSOLUTE_CEILING_DIFF_LINES=30000
V2_ABSOLUTE_CEILING_REPAIR_ROUNDS=12
CONFIRMATION_TOKEN_PREFIX=CONFIRM-OF-LOOP-
CANDIDATE_BRANCH_PREFIX=factory/candidate/
STATE_COUNT=9
STATE_LIST=AWAITING_APPROVAL,READY_TO_BUILD,BUILDING,READY_FOR_REVIEW,REVIEWING,CHANGES_REQUESTED,APPROVED,BLOCKED,STOPPED
PRETOOL_HOOK_COUNT=2
POSTTOOL_HOOK_COUNT=2
SKILL_COUNT=3
SKILLS=spec,build,review
AGENT_COUNT=2
AGENTS=of-builder,of-reviewer
SCHEMA_COUNT=5
HARD_SECRET_BLOCKS_ON=AKIA,PRIVATE_KEY_HARD,HIGH_CONFIDENCE_TOKEN
HEURISTIC_SECRET_REVIEWABLE=HIGH_ENTROPY_HEURISTIC,LONG_BASE64_HEURISTIC
TEXTUAL_GUARD_FORBIDDEN_FORMS=33
TEXTUAL_GUARD_CLOSED_EVASIONS=3
GUARD_EVASION_CLOSED_PYTHON_SUBPROCESS=yes
GUARD_EVASION_CLOSED_VARIABLE_ASSEMBLY=yes
GUARD_EVASION_CLOSED_HYPHENATED_EXECUTABLE=yes
PROTECTED_PATHS=AGENTS.md,CLAUDE.md,.claude/,.ownframework-loop/,.git/,.worktrees/ownframework-loop/
SAFE_WHEN_PACKET_APPROVED=any path listed in packet.elevated_allowed_paths
WORK_CLASSES=BUG,FEATURE,REFACTOR,RESEARCH_SPIKE,DOCS,HARDENING,NEW_REPOSITORY
EXTERNAL_ACTION_FAMILIES=email,push,pr_open,pr_merge,deploy,operator_cli_1,operator_external_2,operator_ssh_3,operator_restricted_root
AGENT_TOOL_INHERITANCE=intentional
BUILDER_TOOL_POSTURE=broad
REVIEWER_TOOL_POSTURE=broad_inspection
AUTHORITY_FROM_TOOLS=no
AUTHORITY_FROM_PACKET_AND_CODE=yes
TOKEN_IS_SECRET=no
TOKEN_IS_MODEL_UNPREDICTABLE=no
TOKEN_IS_PACKET_DERIVED=yes
GLOBAL_PERMISSION_MODE=bypassPermissions
BYPASS_PERMISSIONS_PRESERVED=yes
GLOBAL_SETTINGS_MUTATED=no
SANDBOX_REQUIRED_BY_PLUGIN=no
PER_PASS_HUMAN_APPROVAL=no
OF_LOOP_TESTS=34
OF_LOOP_TOTAL=34
OF_LOOP_PASSED=34
OF_LOOP_FAILED=0
OF_LOOP_RELEASE_GATE_RESULT=PASS
TRUST_APPROVAL_TESTS=PASS
TRUST_BUILD_REVIEW_TESTS=PASS
TRUST_SECRETS_TESTS=PASS
CAPABILITY_MATRIX=PASS
MATRIX_M1_RESULT=PASS
MATRIX_M2_RESULT=PASS
MATRIX_M3_RESULT=PASS
MATRIX_M4_RESULT=PASS
RELEASE_GATE_TIMESTAMP=2026-07-23T23:00:18Z
REPORT_DATE=2026-07-23
```

---

## Operator commands

| Action | Command |
|---|---|
| Install (idempotent) | `bash /path/to/ownframework-loop/install.sh` |
| Validate installed copy | `bash $HOME/.claude/skills/of-loop/validate.sh` |
| Single release gate | `bash /path/to/ownframework-loop/tests/run_all.sh` |
| Rollback to backup | `bash /path/to/ownframework-loop/rollback.sh` |
| Uninstall (restore backup if any) | `bash /path/to/ownframework-loop/uninstall.sh` |
| Source release gate | `bash /path/to/ownframework-loop/release_gate.sh` |
