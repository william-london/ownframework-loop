---
name: spec
description: OwnFramework Loop — spec interview. Researches the target repo, asks only the minimum required questions, drafts a structured work packet, and waits for explicit human approval. Interactive only; never approve your own packet.
user-invocable: true
---

# /of-loop:spec — work packet creation and human approval gate

This skill is the human-facing entry point of the OwnFramework Loop. It is
interactive. It NEVER approves its own packet. Approval requires an explicit
William-issued `/of-loop:spec approve <run-id>` command.

## Usage

- `/of-loop:spec <mission>` — create a new work packet for the mission.
- `/of-loop:spec approve <run-id>` — flip `human_approved: true` on the packet and transition the run to `READY_TO_BUILD`.
- `/of-loop:spec status <run-id>` — print the current run state, packet summary, receipt presence, verdict, and stop flag.
- `/of-loop:spec amend <run-id> <requested change>` — record an amendment request against the packet (requires a re-approve).
- `/of-loop:spec stop <run-id>` — request stop; transitions any nonterminal state to `STOPPED`.
- `/of-loop:spec abandon <run-id>` — record STOP and transition to `STOPPED` for archival.

The skill uses the bundled CLI (`bin/ofloop`) for all state transitions and
packet parsing. The CLI is a Python source file invoked via `./bin/ofloop`
(executable bit + python shebang) or `python3 bin/ofloop`. Never invoke it
as `bash bin/ofloop` — that is `Bash interpreting Python source` and fails
with `SyntaxError`. Do NOT bypass the CLI to edit state files directly.
Direct edits of `STATE.json` are reserved for the CLI only.

## Behavior

### `spec <mission>`

1. Resolve the target repo. The current working directory must be the canonical
   repository on the `master` branch with no remote and a clean baseline.
2. Use `ofloop spec new <repo> "<mission>"` to create the run directory and
   write the initial `STATE.json` in `AWAITING_APPROVAL`.
3. Read the target repository to understand layout, conventions, and existing
   patterns. Investigate only what materially affects the packet.
4. Ask only questions that materially affect implementation. Use `AskUserQuestion`
   if you must ask more than one question at a time. Suggested product questions
   to ask (only the ones the code cannot answer):
   - Behavior forks that change acceptance criteria
   - Scope boundaries (what is explicitly out of scope)
   - Edge cases that flip the criteria (empty states, error handling)
   - Risk class / authority class (low / medium / high)
   - Required runtime proof, if any
5. Draft `WORK_PACKET.md` at
   `<repo>/.ownframework-loop/<run-id>/WORK_PACKET.md`. The metadata block must
   be valid JSON inside a fenced code block (```json ... ```). Follow
   `schemas/work-packet.schema.json`. Do NOT depend on a YAML parser.
6. Required fields include `schema`, `packet_id`, `created_at`, `work_class`,
   `risk_class`, `title`, `target`, `acceptance_criteria` with stable IDs,
   `non_goals` with stable IDs, `allowed_paths`, `protected_paths`, `work_units`,
   `merge_authority`, `deploy_authority`, `push_authority`,
   `external_action_authority`.
7. Required runtime proof: only set for work classes that explicitly need it
   (e.g., `DEBUG`, `RUNTIME_CANDIDATE`). The default is no runtime proof.
8. Circuit breakers: keep defaults (`MAX_REPAIR_ROUNDS=3`,
   `MAX_DIFF_LINES=400`, `MAX_FILES_CHANGED=12`, etc.) unless the packet
   explicitly lowers them. The packet MUST NOT silently raise any default above
   the V1 cap.
9. Append a readable Markdown body after the metadata block. The body must
   include `## Mission`, `## Acceptance criteria`, `## Non-goals`, and
   `## Ordered work units` sections.
10. Print the packet path and ask the operator to run
    `/of-loop:spec approve <run-id>` to bind approval. Do not approve the
    packet yourself.

### `spec approve <run-id>`

1. Re-validate the packet against `schemas/work-packet.schema.json`. Reject if
   invalid.
2. Compute the SHA-256 of the packet bytes. Stamp
   `approved_packet_sha256`, `approved_at`, `approved_actor`, and
   `human_approved: true` into the metadata.
3. Atomically rewrite the packet file with the new metadata.
4. Transition `AWAITING_APPROVAL -> READY_TO_BUILD`.
5. Emit an `OF_LOOPER_OPERATOR_MARKER` block:
   ```
   OF_LOOPER_RUN_ID=<id>
   OF_LOOPER_STATE=READY_TO_BUILD
   OF_LOOPER_ACTION=STOP
   OF_LOOPER_NEXT_DELAY_MINUTES=0
   OF_LOOPER_REASON=awaiting-loop-launch
   ```

### `spec status <run-id>`

Use `ofloop spec status <repo> <run-id>`. Print state, transitions count,
build/review pass counts, repair round, last actor, last candidate SHA,
stop flag, packet summary (title/work_class/risk/approval/sha), receipt and
verdict presence, and last verdict.

### `spec amend <run-id> <change>`

Record an amendment event with the requested change as the reason. Do NOT
modify the packet automatically. After amendment, the operator must edit the
packet manually and re-run `spec approve <run-id>`.

### `spec stop <run-id>`

Create `STOP` file with the operator-provided reason. Transition to `STOPPED`.
Builder and reviewer loops will exit on their next tick.

### `spec abandon <run-id>`

Same as `spec stop` but always records `abandoned` as the reason. The builder
worktree is left intact for manual inspection; the operator may run the
cleanup commands documented in `OPERATOR_RUNBOOK.md`.

## Invariants

- The skill never approves its own packet.
- The skill never transitions a terminal state.
- The skill never opens a remote, never pushes, never merges, never deploys.
- The skill refuses if the target is on the wrong branch, has uncommitted
  changes that don't belong to the run, or already has a remote when the
  packet declares `classification: local_only`.

## Anti-patterns to refuse

- Approving a packet without an explicit operator command.
- Editing `STATE.json` directly.
- Creating a remote to "make the loop easier".
- Silently lowering risk class to dodge review rigor.
- Adding work units the operator did not request.
