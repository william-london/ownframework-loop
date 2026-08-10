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

This repository is self-contained: a fresh `git clone` of
`william-london/ownframework-loop` is the entire deliverable. There
is no private sibling repository, no parent marketplace catalog, and
no William-specific filesystem assumption.

### A. Direct local trial (`--plugin-dir`, session-local)

Use Anthropic's `--plugin-dir` flag to point Claude Code at the
cloned ownframework-loop repository. The skills, agents, and hooks
are loaded for the duration of that Claude session only — nothing is
written to `~/.claude/`.

**`--plugin-dir` is session-local.** A subsequent plain `claude`
invocation without `--plugin-dir` will NOT have the loop loaded,
even from the same shell. Either keep the same Claude session open
or re-launch with `--plugin-dir` on every invocation.

```bash
# 1. Clone ownframework-loop somewhere stable
git clone https://github.com/william-london/ownframework-loop.git /path/to/ownframework-loop

# 2. cd into the TARGET repository you want the loop to operate on
cd /path/to/your-target-repository

# 3. launch claude with ownframework-loop as the ONLY plugin directory
claude --plugin-dir /path/to/ownframework-loop
```

Do not pass the target repository as a `--plugin-dir`. The target
repository is the working directory, not a plugin.

Inside the Claude Code session:

```
/of-loop:spec "add a per-IP rate limit to /api/sync"
/of-loop:spec approve <run-id>
/loop /of-loop:build <run-id>
/loop /of-loop:review <run-id>
```

This is the recommended path for first-time evaluation.

### B. Persistent installation (managed marketplace)

This repository ships a self-contained Claude Code marketplace at
`.claude-plugin/marketplace.json`. `install.sh` registers the
marketplace and installs the plugin through the official plugin
manager.

```bash
git clone https://github.com/william-london/ownframework-loop.git
cd ownframework-loop
bash install.sh
```

What `install.sh` does:

1. Verifies the source is a clean git checkout on a tracked branch.
2. Registers the `ownframework` marketplace pointing at the clone.
3. Runs `claude plugin install of-loop@ownframework --scope user`.
4. Captures a payload manifest at the installed cache root so
   post-install tampering is detectable.

After install:

```bash
claude plugin list                  # shows of-loop@ownframework
claude plugin marketplace list      # shows ownframework -> <clone path>
```

To uninstall:

```bash
bash uninstall.sh                   # removes the plugin only
REMOVE_MARKETPLACE=1 bash uninstall.sh   # also removes the marketplace
```

### C. Running on a target repository

The correct way to launch Claude on a target repository depends
entirely on which install path you used in A or B. The two cases
behave very differently.

#### Direct trial (Path A) — `--plugin-dir` is session-local

You are already inside the target repository. You launched Claude
with `claude --plugin-dir /path/to/ownframework-loop`. That Claude
session has the loop loaded.

**Stay in that Claude session.** If you exit Claude and start a new
plain `claude` invocation, the loop will NOT be loaded. A new session
must again be launched with `--plugin-dir`:

```bash
cd /path/to/your-target-repository
claude --plugin-dir /path/to/ownframework-loop
```

The plugin is NOT registered with the manager in Path A; only the
specific Claude process you started with `--plugin-dir` saw it.

#### Persistent install (Path B) — plugin available normally

You ran `bash install.sh` from a clone of this repository, which
registered the `ownframework` marketplace and installed
`of-loop@ownframework` via the official plugin manager. The plugin
is now part of your Claude environment.

Open Claude in any target repository with a plain launch:

```bash
cd /path/to/your-target-repository
claude
```

The loop skills (`/of-loop:spec`, `/of-loop:build`, `/of-loop:review`)
are available because the plugin is registered globally for your
user account, not because of any flag on this particular invocation.

### D. Verifying an install

Both scripts run from the repository root and require no external
services.

```bash
bash validate.sh
bash release_gate.sh
```

Stable expected markers (the exact strings the canonical scripts
emit on success):

* `OF_LOOP_FAILED=0`
* `OF_LOOP_RELEASE_GATE_RESULT=PASS`
* `RELEASE_GATE=PASS`

The total test count is intentionally not pinned here; it changes as
new tests are added.

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

Current release line: **0.3.8**

This is the first hardened public release. The state machine, packet binding,
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
