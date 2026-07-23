# Architecture — OwnFramework Loop V2

## 0. CLI invocation contract

The CLI shim `bin/ofloop` is a Python script (shebang `#!/usr/bin/env python3`).
The supported invocations are exactly:

```bash
./bin/ofloop                       # executable-bit + shebang (preferred)
python3 bin/ofloop                 # explicit interpreter
ofloop                             # when bin/ is on PATH
```

The following form is **NOT supported** and is an outright mistake:

```text
NOT SUPPORTED — would produce SyntaxError: bash runs Python source as bash
```

Rationale: `bin/ofloop` is a Python source file. Invoking it through a
Bash interpreter produces a `SyntaxError`. A test in
`tests/unit/test_ofloop_invocation.sh` proves that the broken form fails
(non-zero exit) while every documented form succeeds.

The README, runbooks, and templates use `./bin/ofloop` and `python3 bin/ofloop`
only. If you find a reference to `bash bin/ofloop` in the source tree or docs,
it is a bug.

## 1. Purpose

A reusable Claude Code plugin that provides a strong, affordable, generic
two-loop engineering system for OwnFramework. Approved missions cover new
repositories, new systems, features, bugs, debugging, hardening, refactoring,
tests, documentation, CI repair, bounded runtime-sensitive candidate work,
and implementation of tracked contracts.

## 2. Components

```
.claude-plugin/plugin.json     # plugin manifest (name: of-loop)
skills/spec/SKILL.md           # /of-loop:spec — interactive packet + approval
skills/build/SKILL.md          # /of-loop:build — one bounded build pass
skills/review/SKILL.md         # /of-loop:review — one exact-SHA review pass
agents/of-builder.md           # builder agent (writes source)
agents/of-reviewer.md          # reviewer agent (read-only against source)
hooks/hooks.json               # PreToolUse + PostToolUse hooks
hooks/*.sh                     # hook implementations (Python-backed)
bin/ofloop                     # CLI shim around lib/ownframework_loop
lib/ownframework_loop/         # Python core, stdlib only
schemas/                       # JSON Schema for all structured artifacts
templates/                     # packet, policy, per-repo loop.yaml
examples/                      # example packets
docs/                          # operator + architecture docs
tests/                         # deterministic fixture + integration tests
install.sh                     # atomic copy installer with backup
uninstall.sh / rollback.sh     # removal + recovery
validate.sh                    # local preflight
release_gate.sh                # end-to-end PASS/FAIL
```

## 3. Runtime shape

Per-run state lives inside the canonical repo:

```
<canonical-repo>/
├── .ownframework-loop/<run-id>/
│   ├── WORK_PACKET.md       # approved mission
│   ├── STATE.json           # current state (one of 9)
│   ├── BUILD_RECEIPT.json   # {candidate_sha, ...}
│   ├── REVIEW_VERDICT.json  # {verdict, findings, ...}
│   ├── EVENTS.log           # append-only JSON Lines
│   ├── STOP                 # optional stop marker
│   └── LOCK                 # flock target
└── .worktrees/ownframework-loop/<run-id>/
    ├── builder/             # branch: factory/candidate/<run-id>
    └── reviewer/            # detached HEAD at candidate_sha
```

`.ownframework-loop/` and `.worktrees/ownframework-loop/` are excluded from
Git through `git/info/exclude` (added by the skill at run creation; never
modifies the repo's tracked `.gitignore`).

## 4. State machine

Nine states; transitions enforced in `lib/ownframework_loop/transitions.py`.

```
AWAITING_APPROVAL -> READY_TO_BUILD | BLOCKED | STOPPED
READY_TO_BUILD    -> BUILDING | BLOCKED | STOPPED
BUILDING          -> READY_FOR_REVIEW | BLOCKED | STOPPED
READY_FOR_REVIEW  -> REVIEWING | BLOCKED | STOPPED
REVIEWING         -> APPROVED | CHANGES_REQUESTED | BLOCKED | STOPPED
                   | READY_FOR_REVIEW  (candidate changed during review)
CHANGES_REQUESTED -> READY_TO_BUILD | BLOCKED | STOPPED
APPROVED          -> (terminal)
BLOCKED           -> (terminal)
STOPPED           -> (terminal)
```

All transitions are atomic under `fcntl.flock`. Any transition not listed
is rejected with `InvalidTransitionError`.

## 5. Skill flow

### `/of-loop:spec`

1. Investigate target repository (layout, conventions, expectations).
2. Ask minimum required product questions (via `AskUserQuestion`).
3. Draft `WORK_PACKET.md` with a JSON metadata block in a triple-backtick
   fence (no YAML dependency).
4. Print the packet path and request explicit approval.

### `/of-loop:spec approve <run-id>`

1. Re-validate packet.
2. Stamp `human_approved: true`, `approved_packet_sha256`, `approved_at`,
   `approved_actor`.
3. Rewrite the packet atomically.
4. Transition `AWAITING_APPROVAL -> READY_TO_BUILD`.

### `/of-loop:build <run-id>`

1. Validate state, packet, baseline identity.
2. Claim (`READY_TO_BUILD | CHANGES_REQUESTED -> BUILDING`).
3. Create or reuse the builder worktree at
   `.worktrees/ownframework-loop/<run-id>/builder` on branch
   `factory/candidate/<run-id>`.
4. Invoke a fresh `of-builder` agent via the Agent tool.
5. Validate the resulting candidate (SHA exists, diff within budget,
   no protected-path edits, no secret-shaped content).
6. Write `BUILD_RECEIPT.json` through `ofloop build write-receipt`.
7. Transition to `READY_FOR_REVIEW | BLOCKED | STOPPED`.
8. Emit the operator marker.

### `/of-loop:review <run-id>`

1. Validate state, packet, receipt.
2. Pin the candidate SHA. Create or refresh the reviewer detached worktree.
3. Transition `READY_FOR_REVIEW -> REVIEWING`.
4. Invoke a fresh `of-reviewer` agent via the Agent tool.
5. Verify reviewer did not mutate tracked source.
6. Write `REVIEW_VERDICT.json` through `ofloop review write-verdict`.
7. Transition to `APPROVED | CHANGES_REQUESTED | BLOCKED | READY_FOR_REVIEW`.
8. Emit the operator marker.

## 6. Deterministic enforcement

- **File locking**: `STATE.json` writes under `fcntl.flock` (POSIX advisory
  lock) on `.ownframework-loop/<run-id>/LOCK`.
- **Atomic JSON writes**: temp file, `fsync`, then `os.replace`.
- **Hook layer**:
  - `PreToolUse` on Bash refuses forbidden commands
    (`git push`, `git merge`, `git reset --hard`, `git clean`,
    `git remote add`, `systemctl`, `docker compose up|down`, `ssh horus`,
    `ssh firelove`, `hermes`).
  - `PreToolUse` on Write|Edit|MultiEdit|NotebookEdit refuses protected
    paths when an OwnFramework Loop run is active in the current cwd.
  - `PostToolUse` on Bash scans command output for secret patterns.
- **Reviewer read-only**: `disallowedTools: WebFetch, WebSearch, Edit,
  Write, NotebookEdit`. Bash tool is restricted to a read-only allowlist
  (see `lib/ownframework_loop/guards.py`).

## 7. Cost control

- Per-pass model budget tracked by the parent `/loop` session.
- Per-pass hard timeout enforced by the CLI: `max_pass_runtime_seconds`.
- Hard cap `MAX_DIFF_LINES=400`, `MAX_FILES_CHANGED=12` enforced
  by the build skill before writing the receipt.
- Hard cap `MAX_REPAIR_ROUNDS=3` enforced by the build skill before
  claiming a packet.

## 8. Failure modes (selected)

- Packet SHA drift after approval -> `BLOCKED_PACKET_CHANGED_AFTER_APPROVAL`
  (transition to `AWAITING_APPROVAL`, both loops stop).
- Reviewer mutation of tracked source -> verdict is `BLOCKED` with
  changed paths recorded; no auto-cleanup beyond the reviewer worktree.
- Reviewer SHA drift during review -> `STALE_CANDIDATE`, transition to
  `READY_FOR_REVIEW` so the loop re-pins.
- Forbidden command attempted -> hook blocks at the tool boundary;
  no opportunity for the model to suppress.
- Dirty unattributed baseline -> build refuses with `WRONG_REPOSITORY`.

## 9. Why this design

- **Three visible skills**: smallest inspectable surface.
- **Two visible loops**: one builder tab, one reviewer tab per repo.
- **Two fresh agents per pass**: builder and reviewer never share context.
- **`fcntl.flock` over STATE.json**: zero external dependencies.
- **Deterministic hooks over prompt-time instructions**: instructions can
  be ignored; hooks cannot.
- **Exact-SHA reviewer**: prevents approving a candidate the reviewer did
  not actually review.
- **Human merge and deploy**: no autonomous external action.
