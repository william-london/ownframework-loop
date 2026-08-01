---
name: spec
description: Spec interview, packet writing, and approval flow for OwnFramework Loop V2. Drives /of-loop:spec (mission interview → packet), /of-loop:spec approve (TTY-bound human approval that binds the packet SHA), and /of-loop:spec abandon. Approval produces APPROVAL.json with approval_method=tty_confirmation only — there is no automation override. Subsequent lifecycle stages (build via /of-loop:build, review via /of-loop:review) consume the approved packet.
user-invocable: true
---

# /of-loop:spec — work packet creation and human approval gate

This skill is the human-facing entry point of the OwnFramework Loop. It is
interactive. It NEVER approves its own packet. Approval requires a real
human terminal interaction; the model cannot manufacture the typed
confirmation token.

## Usage

- `/of-loop:spec <mission>` — create a new work packet for the mission.
- `/of-loop:spec approve <run-id>` — operator-only command. The CLI prompts
  on a TTY with the run's packet SHA and a short confirmation token. The
  operator types the token back to authorize approval. The CLI writes
  `APPROVAL.json` (the packet bytes are NOT modified) and transitions to
  `READY_TO_BUILD`. THIS SKILL DOES NOT IMPLEMENT APPROVAL; it only prints
  the operator command and waits.
- `/of-loop:spec status <run-id>` — print current state, packet, approval,
  receipt, verdict, stop flag.
- `/of-loop:spec inspect-legacy <run-id>` — diagnose legacy V1 runs.
- `/of-loop:spec amend <run-id> <requested change>` — record amendment.
- `/of-loop:spec stop <run-id>` — request stop.
- `/of-loop:spec abandon <run-id>` — record STOP and archive.

The skill uses the bundled CLI (`bin/ofloop`) for all state transitions and
packet parsing. The CLI is a Python source file invoked via `./bin/ofloop`
(executable bit + python shebang) or `python3 bin/ofloop`. Never invoke it
as `bash bin/ofloop`.

## Behavior

### `spec <mission>`

1. Resolve the target repo. The current working directory must be a git
   repository (the canonical branch may be `master`, `main`, `develop`, or
   any other named branch — V2 has no master-only restriction).
2. Use `ofloop spec new <repo> "<mission>"` to create the run directory
   and write the initial `STATE.json` in `AWAITING_APPROVAL`.
3. Read the target repository to understand layout, conventions, and
   existing patterns. Investigate only what materially affects the packet.
4. Ask only questions that materially affect implementation. Use
   `AskUserQuestion` if you must ask more than one question at a time.
   Suggested product questions (only the ones the code cannot answer):
   - Work class (BUG / FEATURE / REFACTOR / HARDENING / etc.)
   - Behavior forks that change acceptance criteria
   - Scope boundaries (what is explicitly out of scope)
   - Edge cases that flip the criteria (empty states, error handling)
   - Risk class / authority class (low / medium / high)
   - Sensitive paths needing packet approval (AGENTS.md, CLAUDE.md, .claude/)
   - Required runtime proof, if any
5. Derive a work-class-aware budget. The default ranges are:
   - small (BUG / TESTING / DOCUMENTATION / CI_REPAIR): 12–25 files, 400–1,000 lines, 3–4 repair rounds
   - medium (FEATURE / DEBUG / HARDENING): 25–60 files, 1,000–3,000 lines, 4–5 repair rounds
   - large bounded (REFACTOR / TRACKED_CONTRACT / NEW_REPOSITORY): 60–150 files, 3,000–8,000 lines, 4–6 repair rounds
   The packet's `risk_budget` is human-approved; the spec skill proposes
   reasonable defaults that match the work class.
6. Draft `WORK_PACKET.md` at
   `<repo>/.ownframework-loop/<run-id>/WORK_PACKET.md`. The metadata
   block must be valid JSON inside a fenced code block
   (```json ... ```). Follow `schemas/work-packet.schema.json` (V2).
   Do NOT depend on a YAML parser.
7. Never include `human_approved`, `approved_packet_sha256`, `approved_at`,
   or `approved_actor` inside the packet metadata. Approval is a separate
   artifact.
8. Append a readable Markdown body after the metadata block. The body
   must include `## Mission`, `## Acceptance criteria`, `## Non-goals`,
   `## Work units`, `## Sensitive paths (if any)`, and `## Risks`.
9. Print the packet path and instruct the operator to run:
   `ofloop spec approve <repo> <run-id>`
   (or, in the v2 interactive session, `/of-loop:spec approve <run-id>`)
   to bind approval. The model does not run the approve command itself.

### `spec approve <run-id>`

**This skill does not implement approval.** It only prints the operator
command and waits.

1. Print the exact operator command:
   ```
   ofloop spec approve <repo> <run-id>
   ```
2. Explain that approval is the single human mission gate: the CLI
   requires a TTY, prints a short confirmation token derived from the
   packet SHA, and writes APPROVAL.json only after the operator types
   the token back.
3. Wait for `APPROVAL.json` to exist (poll with `ofloop spec status`).
4. Show status afterwards.

If the model is asked to approve its own packet, it MUST refuse. The
typed confirmation token is computed from the packet SHA and cannot be
synthesized from the model's own reasoning.

### `spec status <run-id>`

Use `ofloop spec status <repo> <run-id>`. Print state, transitions
count, build/review pass counts, repair round, last actor, last
candidate SHA, stop flag, packet summary (title/work_class/risk/sha),
approval summary (binding ok/confirmation token), receipt and verdict
presence, last verdict.

### `spec inspect-legacy <run-id>`

Use `ofloop spec inspect-legacy <repo> <run-id>`. Prints whether the
run still carries legacy V1 approval fields and whether the approval
binding is intact. If V1 fields are present, recommend re-approval.

### `spec amend <run-id> <change>`

Record an amendment event. Do NOT modify the packet automatically.
After amendment, the operator must edit the packet manually and rerun
the operator approval command.

### `spec stop <run-id>`

Create `STOP` file with the operator-provided reason. Transition to
`STOPPED`. Builder and reviewer loops will exit on their next tick.

### `spec abandon <run-id>`

Same as `spec stop` but always records `abandoned` as the reason. The
builder worktree is left intact for manual inspection.

## Invariants

- The skill never approves its own packet.
- The skill never transitions a terminal state.
- The skill never opens a remote, never pushes, never merges, never
  deploys, never sends email, never charges money.
- The skill refuses if the target is on the wrong branch for the
  packet, has uncommitted changes that don't belong to the run, or
  has a remote mismatch with the packet's `classification`.

## Anti-patterns to refuse

- Approving a packet without an explicit operator command.
- Editing `STATE.json` directly.
- Storing approval fields in the packet metadata (V1 mistake).
- Creating a remote to "make the loop easier".
- Silently lowering risk class to dodge review rigor.
- Adding work units the operator did not request.
- Setting an unbounded budget without explicit operator approval.


## PROGRAM mode (v3 packets)

For v3 packets with `execution_mode: program`, the spec skill ONLY
handles packet writing and APPROVAL.json (as usual). The check-point
graph is materialized by `ofloop program init` and consumed by
`ofloop loop run`. The spec skill never writes program state itself.
