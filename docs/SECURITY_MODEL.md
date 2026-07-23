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
and `STOP` are created with mode `0600`.

### 6. Agent-level tool restrictions

`of-reviewer` has `disallowedTools: WebFetch, WebSearch, Edit, Write,
NotebookEdit`. The reviewer can only emit a verdict through the CLI.

### 7. Packet hash binding

Approval binds to the SHA-256 of the packet bytes. Any drift between
approval and pass execution invalidates the approval.

### 8. Exact-SHA review

The reviewer can only write a verdict for the SHA in `BUILD_RECEIPT.json`.
Drift between review start and verdict write is detected and recorded
as `STALE_CANDIDATE`.

### 9. Tracked-mutation detection

The reviewer records `HEAD` before and after its pass. Any drift is
recorded as `BLOCKED` with the changed paths.

### 10. Prompt-injection classification

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

### 11. Local-only default

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
