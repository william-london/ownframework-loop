# OwnFramework Loop V2

> Human-gated two-loop engineering for specification, isolated building,
> exact-SHA review, repair, and proof. Built for Claude Code 2.1+.

OwnFramework Loop is a Claude Code plugin that turns a one-line mission into
a single approved work packet, then drives one engineering unit at a time
through an independent reviewer until the packet is `APPROVED`, `BLOCKED`, or
`STOPPED`. Two terminal tabs. Three commands. No queue server. No daemon.
Human merges. Human deploys.

```
Human mission
    |
    v
/of-loop:spec      -- one interactive interview, one work packet, one approval
    |
    v
Builder session    --/loop /of-loop:build <run-id>--> candidate commit
    |
    v
Reviewer session   --/loop /of-loop:review <run-id>--> verdict
    |
    +---> builder repairs (if CHANGES_REQUESTED) -> back to builder
    +---> human merge (if APPROVED)
```

## Quickstart

```bash
# 1. Install (idempotent; backups the existing copy if present). install.sh
#    is a bash script with a bash shebang — invoked via `bash`.
bash /path/to/ownframework-loop/install.sh

# 2. Open Claude Code inside a target repo
cd /path/to/your-repository
claude --plugin-dir $HOME/.claude/skills/of-loop

# 3. Create the mission
/of-loop:spec "add a per-IP rate limit to /api/sync"

# 4. Review the packet at
#    .ownframework-loop/<run-id>/WORK_PACKET.md
#    Then approve it explicitly:
/of-loop:spec approve <run-id>

# 5. Open two terminal tabs and run:
/loop /of-loop:build <run-id>      # builder
/loop /of-loop:review <run-id>     # reviewer

# 6. Wait for APPROVED, BLOCKED, STOPPED, or an escalation marker.
# 7. Merge manually.
```

## Surface

Three skills:

- `/of-loop:spec` — interactive packet creation and human approval gate
- `/of-loop:build` — one bounded build or repair pass (safe under `/loop`)
- `/of-loop:review` — one exact-SHA review pass (safe under `/loop`)

Two agents:

- `of-builder` — implements or repairs one approved work unit per pass
- `of-reviewer` — proves one exact candidate SHA per pass, read-only

CLI:

- `ofloop spec new|status|approve|amend|stop|abandon <repo> <run-id>`
- `ofloop build claim|transition|write-receipt|marker <repo> <run-id>`
- `ofloop review write-verdict|marker <repo> <run-id>`
- `ofloop doctor <repo> [--run-id <id>]`
- `ofloop new-repo <root> <project> [--init-baseline]`

## Hard rules

- The canonical baseline branch is the repository's default branch; treat it as the only allowed final branch.
- Local-only repositories must stay local-only.
- The human merges. The human deploys. The loop never pushes, merges, or
  deploys.
- Escalation is operator-driven. When the artifact carries an escalation marker, the operator decides what to do manually. The loop does not invoke any external tool itself.
- All state transitions go through `ofloop` with a file lock. Direct edits
  of `STATE.json` are refused by the hooks.

## Repository layout

```
ownframework-loop/
├── .claude-plugin/plugin.json
├── skills/{spec,build,review}/SKILL.md
├── agents/{of-builder,of-reviewer}.md
├── hooks/{hooks.json,*.sh}
├── bin/ofloop
├── lib/ownframework_loop/   # Python stdlib core
├── schemas/                 # JSON Schema for packet, state, receipt, verdict
├── templates/               # packet + policy + per-repo loop.yaml
├── examples/                # bug, hardening, tracked contract, new repo
├── tests/                   # unit, integration, fixtures, smoke
├── docs/                    # ARCHITECTURE, OPERATOR_RUNBOOK, etc.
├── install.sh               # atomic copy with backup
├── uninstall.sh
├── rollback.sh
├── validate.sh
└── release_gate.sh
```

## V1 invariants

1. State machine has exactly 9 states:
   `AWAITING_APPROVAL`, `READY_TO_BUILD`, `BUILDING`, `READY_FOR_REVIEW`,
   `REVIEWING`, `CHANGES_REQUESTED`, `APPROVED`, `BLOCKED`, `STOPPED`.
2. The reviewer can only write `REVIEW_VERDICT.json` and append to
   `EVENTS.log`. Source tree is read-only.
3. The reviewer can only approve the exact SHA from `BUILD_RECEIPT.json`.
4. Packet approval binds to the SHA-256 of the packet bytes. Any drift
   invalidates approval and transitions to `AWAITING_APPROVAL`.
5. Concurrent `STATE.json` writes are serialized under `fcntl.flock`.

See `docs/STATE_MACHINE.md`, `docs/SECURITY_MODEL.md`, and
`docs/OPERATOR_RUNBOOK.md` for the full contract.

## License

Proprietary — OwnFramework internal. See `THIRD_PARTY_NOTICES.md` for
attribution to upstream MIT works used as architectural inspiration only.
