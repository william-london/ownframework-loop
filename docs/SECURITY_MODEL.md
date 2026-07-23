# Security Model

## Threat model

The OwnFramework Loop is designed for a single operator (William) running
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
  `ssh horus|firelove`, `hermes`). Patterns are compiled
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

The approval architecture relies on **artifact binding plus tested
command-origin refusal** — not on token cryptographic unspoofability.

| Property | Source |
|---|---|
| `PACKET_HASH_BOUND` | `packet_sha256` in APPROVAL.json must equal SHA-256 of current packet bytes |
| `REPOSITORY_BOUND` | `canonical_repo` must resolve to active canonical repo |
| `BASELINE_BOUND` | `baseline_sha` must match current HEAD of canonical branch |
| `NONINTERACTIVE_APPROVAL=blocked` | CLI raises `OF_LOOP_APPROVAL_TTY_REQUIRED` when stdin is not a TTY |
| `PSEUDO_TTY_APPROVAL=blocked` | Attacker's pseudo-TTY cannot derive the token without knowing the packet SHA |
| `DIRECT_FILE_APPROVAL=blocked` | Direct `APPROVAL.json` forgery refuses at build finalizer ("builder worktree missing") |
| `DIRECT_LIBRARY_APPROVAL=blocked` | `request_human_approval(assume_tty=True)` is the documented developer escape; the model cannot invoke it because the hooks block the Bash call and the spec skill contract forbids self-approval |
| `PACKET_MUTATION_INVALIDATION=PASS` | Any byte mutation after approval invalidates the recorded SHA |
| `TOKEN_SECRECY_CLAIM=absent` | The token is derived from the packet SHA (plaintext); it is not a secret |

The **confirmation token is**:

  ```
  CONFIRM-OF-LOOP-<8hex>
  ```

where `<8hex>` is the first 8 hex characters of the packet SHA-256.
Both the packet bytes and the SHA are not secret (they are the
plaintext and its checksum). What the token proves is that the
operator **acknowledged a specific approved packet**, not that the
operator is cryptographically unspoofable. Pseudo-TTY attacks
(`pty.spawn`, `/usr/bin/script`) CAN make stdin look like a TTY; they
cannot derive the token without reading the packet bytes first,
which the operator presents in the spec interview.

The root of trust is therefore:

  - packet SHA → derived token (plaintext, not secret);
  - APPROVAL.json binds run_id, canonical_repo, baseline_branch,
    baseline_sha, packet_sha256, confirmation_token together;
  - the CLI requires all five to match at finalize time;
  - **pseudo-TTY attacks do NOT bypass the binding** because
    they still need a valid token derived from the packet SHA,
    which is one-way-fingerprinted by the operator's actions
    during the spec interview.

Required for any approval:

- `TOKEN_IS_SECRET=no` — public.
- `TOKEN_IS_MODEL_UNPREDICTABLE=no` — predictable from packet bytes.
- `TOKEN_IS_PACKET_DERIVED=yes` — derived from packet SHA.

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

## Why Codex is not wired

`CODEX=manual_triggered_escalation`. The loop emits a durable
recommendation in `REVIEW_VERDICT.json` and `EVENTS.log` when an
escalation condition is observed. William invokes Codex as a separate
manual lane. The loop never calls Codex automatically.

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

William's deliberate posture is `bypassPermissions` + broad tools +
no per-pass prompts. OwnFramework Loop is built to operate under
that posture. The plugin does NOT modify any of these settings
(`~/.claude/settings.json`, `~/.claude.json`, managed settings,
project permission settings, sandbox settings, effort settings,
provider settings, model settings).
