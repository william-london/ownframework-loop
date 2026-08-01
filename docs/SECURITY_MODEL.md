# Security Model

## Threat model

The OwnFramework Loop is designed for a single operator (operator) running
locally on Mac. Threats considered:

1. **A model prompt-injection attempt from inside the repo** that tries to
   expand authority, change the target, request secrets, disable hooks, or
   push / deploy.
2. **A run drift** — the model continues past its intent and writes to
   tracked files outside the packet's allowed paths.
3. **A concurrent transition race** between builder and reviewer.
4. **A stale review** where the reviewer approves a candidate that has
   already moved past the SHA they were given.
5. **An unattributed baseline change** — another tool mutates the repo
   while a loop is running.
6. **A reviewer-induced mutation** of tracked source.
7. **Secret-shaped content** in code or commits.
8. **An autonomous external action** (push, merge, deploy, remote create).
9. **A direct APPROVAL.json forgery** — a process that writes a valid-
   looking approval without going through the operator-facing CLI.
10. **A pseudo-TTY or noninteractive approval attempt** — a tool that
    tries to feed the confirmation token back through a programmatic
    channel.

## Defense layers

### 1. Deterministic hooks

Hooks are evaluated by Claude Code, not by the model. The model cannot
opt out.

- `PreToolUse` on Bash blocks forbidden command patterns
  (`git push`, `git merge`, `git reset --hard`, `git clean`,
  `git remote add`, `systemctl`, `docker compose up|down`,
  `ssh production-host-1|production-host-2`, <operator-blocked-executable>). Patterns are compiled
  regexes; chains like `git status && git push` are split on `&&`, `||`,
  `;`, `|` before matching.
- `PreToolUse` on Write|Edit|MultiEdit|NotebookEdit blocks protected
  paths when an OwnFramework Loop run is active in the current cwd.
- `PostToolUse` on Bash scans command output for secret patterns.

The hook is **scoped to active runs**. It does not interfere with
ordinary Claude use outside `.ownframework-loop/<run-id>/` or
`.worktrees/ownframework-loop/<run-id>/`.

The textual guard applies layered normalizations before pattern
matching:

  1. Bash top-level command-line extraction.
  2. Shell-quote stripping (`'foo'` / `"foo"` → `foo`).
  3. Backslash-escape stripping (shell artifacts in nested-quote argv).
  4. Python-subprocess argv literal normalization:
     `["git","push"]` and `[git,push]` and `subprocess.run("git push")`
     and `os.system("git push")` are recognized as
     `git push`.
  5. Shell variable-assignment resolution:
     `X=push; git $X origin master` is recognized as
     `git push origin master`.
  6. Hyphenated wrapper executable identity normalization:
     `./git-remote-add`, `git-push`, `gh-pr-create`, etc. are mapped
     to the space-separated canonical form (`git remote add`,
     `git push`, `gh pr create`) before pattern matching.

The textual guard is **one layer** of defense. Forms that cannot be
safely interpreted pre-execution (multiline heredocs, opaque Python
dynamic code, base64-encoded payloads) defer to the post-pass review
layer and the exact-SHA receipt check.

### 2. State machine guardrails

The state machine rejects every transition not in the allowed map.
Terminal states cannot be reopened without explicit operator action.

### 3. File locking

`STATE.json` and `EVENTS.log` are written under `fcntl.flock` on the
run's `LOCK` file. Concurrent mutations are serialized.

### 4. Atomic JSON writes

Every structured artifact is written via temp file + `fsync` + `os.replace`.
A partial write cannot leave a half-written `STATE.json`.

### 5. Restrictive file modes

`STATE.json`, `BUILD_RECEIPT.json`, `REVIEW_VERDICT.json`, `EVENTS.log`,
`APPROVAL.json`, and `STOP` are created with mode `0600`.

### 6. Agent-level tool inheritance

`of-builder` and `of-reviewer` deliberately do NOT list `tools:` or
`disallowedTools:` in their frontmatter. They inherit the parent's
broad toolset (read, write within authority, shell, WebSearch,
WebFetch, MCP read-only verbs).

This is intentional. Authority comes from packet, exact worktree,
hooks, finalizers, and promotion boundaries — not from a narrow tool
allowlist.

```
AGENT_TOOL_INHERITANCE=intentional
BUILDER_TOOL_POSTURE=broad
REVIEWER_TOOL_POSTURE=broad_inspection
AUTHORITY_FROM_TOOLS=no
AUTHORITY_FROM_PACKET_AND_CODE=yes
```

### 7. Packet hash binding (artifact binding)

Approval binds to the SHA-256 of the packet bytes. Any drift between
approval and pass execution invalidates the approval and the build
finalizer returns `OF_LOOP_BUILD_FINALIZE_REFUSED` with reason
`approval invalid: packet SHA drift`.

### 8. Exact-SHA review

The reviewer can only write a verdict for the SHA in `BUILD_RECEIPT.json`.
Drift between review start and verdict write is detected and recorded
as `STALE_CANDIDATE`.

### 9. Tracked-mutation detection

The reviewer records `HEAD` before and after its pass. Any drift is
recorded as `BLOCKED` with the changed paths.

### 10. Approval-security boundaries

v0.3.5 (AUD2-P0-1) shrinks the approval architecture to a single
authoritative path: **a genuine interactive TTY plus a typed
confirmation token**. There is no automation override, no operator
marker, no developer escape. A model cannot approve its own packet
under any input.

The approval architecture relies on **artifact binding plus
genuine-TTY plus typed-token refusal** — not on token cryptographic
unspoofability.

| Property | Source |
|---|---|
| `PACKET_HASH_BOUND` | `packet_sha256` in APPROVAL.json must equal SHA-256 of current packet bytes |
| `REPOSITORY_BOUND` | `canonical_repo` must resolve to active canonical repo |
| `BASELINE_BOUND` | `baseline_sha` must match current HEAD of canonical branch |
| `ALLOWED_APPROVAL_METHODS={"tty_confirmation"}` | The set is enforced by `validate_approval_shape`, `validate_approval_binding`, and `request_human_approval` |
| `TTY_DEVICE_MUST_BE_CANONICAL` | `_is_interactive_tty` rejects pipes, file redirects, and pseudo-ttys whose device path is not `/dev/tty*` |
| `NONINTERACTIVE_APPROVAL=blocked` | CLI raises `OF_LOOP_APPROVAL_TTY_REQUIRED` when stdin is not a canonical TTY |
| `PSEUDO_TTY_APPROVAL=blocked` | `_is_interactive_tty` rejects pseudo-ttys whose slave path is synthetic `/dev/ttysXXXXXXXX` (the `pty.openpty()` pattern). Only `/dev/tty`, `/dev/ttysNNN`, and `/dev/ttyNN` match |
| `DIRECT_FILE_APPROVAL=blocked` | Direct `APPROVAL.json` forgery refuses at build finalizer ("builder worktree missing") |
| `DIRECT_LIBRARY_APPROVAL=blocked` | `request_human_approval` has no `assume_tty` parameter; the function unconditionally calls `_is_interactive_tty` and `_read_tty_confirmation` |
| `CLI_OVERRIDE_REMOVED` | `--assume-tty` argparse option was removed in v0.3.5; `OFLOOP_ACTOR` env no longer default-actor |
| `PACKET_MUTATION_INVALIDATION=PASS` | Any byte mutation after approval invalidates the recorded SHA |
| `TOKEN_SECRECY_CLAIM=absent` | The token is derived from the packet SHA (plaintext); it is not a secret |
| `APPROVAL_METHOD_FABRICATION=blocked` | `validate_approval_shape` rejects `operator_marker` and `operator_explicit_override` outright |

The **confirmation token is**:

  ```
  CONFIRM-OF-LOOP-<8hex>
  ```

where `<8hex>` is the first 8 hex characters of the packet SHA-256.
Both the packet bytes and the SHA are not secret (they are the
plaintext and its checksum). What the token proves is that the
operator **acknowledged a specific approved packet**, not that the
operator is cryptographically unspoofable.

A pseudo-TTY that opens a `/dev/ttysXXXXXXXX` slave via
`pty.openpty()` would previously pass `isatty()`. v0.3.5 rejects
this at the device-path layer: `_is_canonical_tty_device` accepts
only literal `/dev/tty`, `/dev/ttysNNN`, or `/dev/ttyNN`. A child
subprocess cannot manufacture a canonical device path because the
kernel allocates pseudo-ttys in a synthetic range.

The root of trust is therefore:

  - packet SHA → derived token (plaintext, not secret);
  - APPROVAL.json binds run_id, canonical_repo, baseline_branch,
    baseline_sha, packet_sha256, confirmation_token together;
  - the CLI requires all five to match at finalize time;
  - **the only path to write APPROVAL.json is through a genuine
    canonical TTY plus the typed token**, with no CLI flag, env
    variable, library parameter, or fabricated method able to
    bypass either requirement.

Required for any approval:

- `TOKEN_IS_SECRET=no` — public.
- `TOKEN_IS_MODEL_UNPREDICTABLE=no` — predictable from packet bytes.
- `TOKEN_IS_PACKET_DERIVED=yes` — derived from packet SHA.
- `APPROVAL_REQUIRES_CANONICAL_TTY=yes` — stdin and stdout must
  both resolve to a `/dev/tty*` device; pseudo-ttys are rejected.
- `APPROVAL_REQUIRES_TYPED_TOKEN=yes` — the typed token must
  match the deterministic derivation; no automated fill-in is
  accepted (a parent process typing into the master fd is not
  accepted because the kernel sees the child as the writer).

A future hardware-backed approval mode (e.g., Touch ID / Secure
Enclave-attested token) may be documented as optional high-assurance
work. It is **not** required for this release and **not** claimed.

### 11. External-action guard

The dedicated `external_action_guard.sh` hook classifies every
PreToolUse call during an active run:

  - `ALLOW` for ordinary engineering tools.
  - `ALLOW_WITH_DIAGNOSTIC` for read-only MCP verbs.
  - `BLOCK:<code>` for: email/SMS/DM, calendar mutation,
    payment/charge/refund, public publish, GitHub PR/merge,
    production deploy, destructive cloud mutation,
    customer-system mutation.

The guard runs the same layered normalizations as the bash guard
(Python-subprocess argv normalization, variable-assignment
resolution, hyphenated-wrapper identity normalization).

The guard is **bounded in scope**. It does not pretend to prove the
semantics of arbitrary Turing-complete local programs. Forms that
escape detection defer to the post-pass review layer and exact-SHA
receipt checks.

### 12. Honest guarantee

```
DETERMINISTIC_INTERNAL_AUTHORITY=
  packet, approval, state, SHA, worktree, receipt, verdict, transitions

EXTERNAL_ACTION_GUARD=
  strong layered prevention of direct and tested accidental forms

ARBITRARY_PROGRAM_SEMANTIC_CONTAINMENT=
  not claimed without an OS sandbox or isolated runtime
```

OwnFramework Loop does **not** claim semantic containment of
arbitrary opaque local code. The textual guard covers direct and
tested accidental forms. Programs that bypass textual detection
(by intent or by direct injection) defer to the post-pass verification
layer + exact-SHA receipt + finalizer.

### 13. Prompt-injection classification

The contract requires that repository content, issue text, logs,
webpages, generated documents, test output, comments, and commit
messages are treated as **untrusted data**. Findings from this content
are never allowed to:

- change the target repository,
- expand allowed paths,
- grant push or deploy authority,
- request secrets,
- modify the work packet,
- disable hooks,
- change the model route,
- create a remote,
- bypass human approval.

A fixture test enforces a representative malicious embedded instruction
and verifies the system does not act on it.

### 14. Local-only default

The default approved roots are explicit and configurable. New
repositories default to `classification: local_only`. A packet for a
local-only repository blocks remote creation, push, and PR creation.

## Why a packet cannot grant authority

The skill layer refuses to write a packet whose `merge_authority`,
`deploy_authority`, `push_authority`, or `external_action_authority`
is anything other than `human_only`, `delegated`, or `none`. The CLI
rejects bad values at parse time. Hooks refuse push/merge/deploy
regardless of what the packet says.

## Why escalation is not wired

`OFLOOP_ESCALATION_TRIGGER=manual_triggered_escalation`. The loop emits a durable
recommendation in `REVIEW_VERDICT.json` and `EVENTS.log` when an
escalation condition is observed. operator invokes escalation as a separate
manual lane. The loop never calls escalation automatically.

## Auditability

Every state transition, every receipt write, every verdict write, every
stop request, every amendment, and every hook-block event appears in
`EVENTS.log`. The events are append-only. They are not deleted by the
loop. They are not edited by the loop.

## Tooling autonomy posture

```
GLOBAL_PERMISSION_MODE=bypassPermissions
BYPASS_PERMISSIONS_PRESERVED=yes
GLOBAL_SETTINGS_MUTATED=no
SANDBOX_REQUIRED_BY_PLUGIN=no
BUILDER_TOOL_SURFACE=broad
REVIEWER_INSPECTION_TOOL_SURFACE=broad
WEBSEARCH_AVAILABLE=yes
WEBFETCH_AVAILABLE=yes
PER_PASS_HUMAN_APPROVAL=no
```

operator's deliberate posture is `bypassPermissions` + broad tools +
no per-pass prompts. OwnFramework Loop is built to operate under
that posture. The plugin does NOT modify any of these settings
(`~/.claude/settings.json`, `~/.claude.json`, managed settings,
project permission settings, sandbox settings, effort settings,
provider settings, model settings).


## v0.3.0 PROGRAM mode protections

PROGRAM mode extends the security model with three additional invariants:

1. **Frozen graph SHA** — `checkpoint_graph_sha256` is captured at
   `program init` and recorded in `state.program`. Any subsequent
   initialization attempt with a different graph SHA is refused
   (`program_graph_sha_drift`). This prevents post-approval widening
   (e.g., adding new checkpoints or raising caps after some CPs are
   already approved).

2. **Per-checkpoint approval guard** — `program.checkpoints[CP-N].state`
   is finalised to `APPROVED` only after at least one build pass and
   at least one review pass are recorded in the per-checkpoint counters.
   The model cannot bulk-finalise without going through the bounded
   builder/reviewer/finalizer cycle. The nonterminal exception
   (`nonterminal_cp_approval_refused`) is raised at finalize time.

3. **Cumulative source ceilings** — Even with per-checkpoint caps
   satisfied, the program-level cumulative caps (sum of approved-CP
   exact caps) and global source ceilings (500 files, 30,000 diff lines)
   are re-checked at every checkpoint finalization. Exceeding a
   cumulative cap is a hard `STOPPED` outcome and requires a new
   packet/program.

These invariants are deterministic in the Python core (no model
judgment) and are exercised by the integration tests in
`tests/integration/test_program_mode.sh`.


## v0.3.5 approval boundary

Production approval requires a genuine interactive TTY plus typed
confirmation token. There is no override:

- `request_human_approval` has no `assume_tty` parameter and accepts no
  automation override.
- The only valid `approval_method` is `tty_confirmation`.
- `--actor` records attribution but is not authority; the actor does
  not bypass the TTY requirement.
- `OFLOOP_ACTOR` is unset by default and is recorded as attribution.
- A non-interactive subprocess (stdin=/dev/null, pipe, or non-TTY pty)
  is refused.
- `--assume-tty` has been removed from the CLI entirely.

A model or subprocess cannot satisfy this gate by supplying a flag,
environment variable, generated token, prewritten JSON, or direct
library call.
