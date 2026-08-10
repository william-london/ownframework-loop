# OwnFramework Loop

OwnFramework Loop is a human-gated engineering workflow for Claude Code
that turns an approved work packet into bounded build/review cycles with
exact-SHA verification and manual promotion.

It is built for engineering work where the cost of an unauthorized
change exceeds the cost of one extra review. Every state transition is
serialized, every review evaluates the exact candidate SHA, and the
human — not the loop — merges, deploys, and promotes.

---

## Why it exists

Long engineering missions tend to drift in three ways:

1. **Scope drift** — an ambitious prompt becomes an unbounded task.
2. **Trust drift** — a reviewer approves the *idea* of a change rather
   than the exact bytes that will land.
3. **Authority drift** — automation starts merging, deploying, or
   pushing on its own.

OwnFramework Loop binds each of those down:

- The mission becomes an explicit, human-approved work packet.
- The reviewer evaluates the exact candidate commit SHA, not a
  re-described intent.
- The loop never pushes, merges, deploys, or talks to a queue server.

If you want autonomous-software-company output, this is not that
project. If you want a disciplined, human-controlled workflow that
makes one approved engineering unit land safely per cycle, read on.

---

## How it works

```
        mission
          |
          v
   spec / work packet
          |
          v
   explicit human approval
          |
          v
        builder
          |
          v
   exact-SHA reviewer
          |
          +--> APPROVED    --> human merges / deploys
          |
          +--> CHANGES_REQUESTED --> repair loop --> builder
          |
          +--> BLOCKED / STOPPED  --> human decides
```

Two terminal tabs. Three commands. No daemon. No queue server. The
human is always the merge and deploy authority.

---

## Quickstart

```bash
# 1. Install. install.sh is a bash script with a bash shebang, so
#    it is invoked explicitly via `bash`.
bash /path/to/ownframework-loop/install.sh

# 2. Open Claude Code inside a target repository
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

# 6. Wait for APPROVED, BLOCKED, or STOPPED.
# 7. Merge manually.
```

The install script copies this repository into a managed location and
registers the skills, agents, hooks, and `ofloop` CLI. It does not
require any private OwnFramework infrastructure to operate.

---

## Commands

### Skills

- `/of-loop:spec` — interactive packet creation and human approval gate
- `/of-loop:build` — one bounded build or repair pass (safe under `/loop`)
- `/of-loop:review` — one exact-SHA review pass (safe under `/loop`)

### Agents

- `of-builder` — implements or repairs one approved work unit per pass
- `of-reviewer` — proves one exact candidate SHA per pass, read-only

### CLI

The `ofloop` CLI is the deterministic surface for state transitions:

```
ofloop spec    new | status | approve | amend | stop | abandon <repo> <run-id>
ofloop build   claim | transition | write-receipt | marker <repo> <run-id>
ofloop review  write-verdict | marker <repo> <run-id>
ofloop doctor  <repo> [--run-id <id>]
ofloop new-repo <root> <project> [--init-baseline]
```

Direct edits to authoritative artifacts (`STATE.json`, `BUILD_RECEIPT.json`,
`REVIEW_VERDICT.json`, `WORK_PACKET.md`, `APPROVAL.json`, `EVENTS.log`)
are refused by the hooks — those files must be written through `ofloop`.

---

## Core invariants

1. **Human approval binds the packet.** Approval binds to the SHA-256
   of the packet bytes. Any drift invalidates approval and transitions
   the run back to `AWAITING_APPROVAL`.
2. **The reviewer evaluates the exact candidate SHA.** The reviewer
   reads `BUILD_RECEIPT.json`, then evaluates the SHA named there —
   nothing else. A different SHA is a different candidate.
3. **State transitions are serialized.** All `STATE.json` writes go
   through `ofloop` under `fcntl.flock`. Concurrent writers cannot
   corrupt state.
4. **The loop does not push, merge, or deploy.** Those are human
   actions. The repository's own hooks refuse push and merge mutations
   from inside a loop run.
5. **STOPPED and BLOCKED are deterministic terminal states.** They are
   not retried by the loop. A human decides what happens next.
6. **Reviewer source is read-only.** The reviewer may only write
   `REVIEW_VERDICT.json` and append to `EVENTS.log`. Source under
   review cannot be modified by the reviewer.
7. **Escalation is operator-driven.** When an artifact carries an
   escalation marker, the operator decides what to do manually.

See `docs/STATE_MACHINE.md`, `docs/SECURITY_MODEL.md`, and
`docs/OPERATOR_RUNBOOK.md` for the full contract.

---

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
├── docs/                    # architecture, security model, runbook, history
├── CONTRIBUTING.md
├── SECURITY.md
├── CHANGELOG.md
├── THIRD_PARTY_NOTICES.md
├── install.sh
├── uninstall.sh
├── rollback.sh
├── validate.sh
└── release_gate.sh
```

---

## Requirements

- **Claude Code** — 2.1 or newer
- **Python** — 3.12 or newer (the runtime uses only the standard library)
- **POSIX file locking** — `fcntl.flock` is required for serialized state
- **Bash** — for `install.sh`, `validate.sh`, `release_gate.sh`, and the
  canonical test suite

OwnFramework Loop introduces no third-party Python package, no npm
dependency, no system service, and no network dependency.

---

## Project status

Current release line: **0.3.7**

This is an early public release. The state machine, packet binding,
exact-SHA review, and serialized transitions have been exercised
against a focused test suite. Performance and behaviour against large
real-world repositories is an empirical matter — the loop makes no
claim of guaranteed-correctness, guaranteed-safety, or guaranteed
coverage. Read `CHANGELOG.md` for the historical release-by-release
record.

Earlier engineering snapshots (the v0.2.x implementation report and
the v0.3.0 loop-repair mission report) are preserved under
`docs/history/` for context only; current authoritative behaviour is
defined by `README.md`, `CHANGELOG.md`, and the test suite.

---

## Contributing

See [`CONTRIBUTING.md`](./CONTRIBUTING.md) for the supported
contribution flow, including how to run validation, how to scope a
change, and what license contributions are accepted under.

## Security

See [`SECURITY.md`](./SECURITY.md) for the responsible-disclosure
contact and the project's security posture.

## License

Apache License 2.0. See [`LICENSE`](./LICENSE) for the full text and
[`THIRD_PARTY_NOTICES.md`](./THIRD_PARTY_NOTICES.md) for attribution
to upstream MIT works used as architectural inspiration only.
