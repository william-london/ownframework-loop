# OwnFramework Loop

> Human-gated engineering loops for AI coding agents.

OwnFramework Loop binds engineering work to a human-approved work packet, lets a coding agent build inside bounded scope, reviews the exact resulting Git commit, limits repair cycles, and leaves merge/deployment authority with the human.

Claude Code remains the **stable reference adapter**. v0.4.0 introduces an agent-neutral core/adapter contract and a portable Agent Skills layer so other coding agents can participate without creating a second state machine.

## Why it exists

Coding agents are useful at implementation, but long engineering missions still need an explicit answer to a different set of questions:

- What exact work did the human approve?
- What scope and risk budget apply?
- What immutable candidate did the builder produce?
- Did the reviewer inspect that exact candidate SHA?
- How many repair rounds are allowed?
- Is the result merely reviewed, or actually promoted?

OwnFramework Loop makes those boundaries explicit and machine-readable.

```text
mission
  ↓
work packet
  ↓
human approval + packet hash binding
  ↓
bounded builder
  ↓
exact candidate Git SHA
  ↓
exact-SHA reviewer
  ↓
APPROVED / CHANGES_REQUESTED / BLOCKED / STOPPED
  ↓
human promotion outside the loop
```

The loop never treats an `APPROVED` verdict as permission to push, merge, deploy, publish, or perform another external action.

## Agent support

| Agent host | Status | What is supported |
|---|---|---|
| **Claude Code** | **Stable / reference** | Managed plugin, `/of-loop:spec`, `/of-loop:build`, `/of-loop:review`, custom agents, native hooks, direct `--plugin-dir` evaluation |
| **Codex** | **Experimental** | Opt-in adapter installer, portable Agent Skills, repository `AGENTS.md`, and the same deterministic core; authenticated live lifecycle proof is still pending |

Agent-agnostic does **not** mean every host has identical enforcement. See [`docs/architecture/CAPABILITY_MATRIX.md`](docs/architecture/CAPABILITY_MATRIX.md) for the distinction between protocol compatibility and hardened host integration.

## Claude Code quickstart

Claude Code is still the simplest and most complete way to use OwnFramework Loop.

### Persistent install

```bash
git clone https://github.com/william-london/ownframework-loop.git
cd ownframework-loop
bash install.sh
```

Verify:

```bash
claude plugin list
```

You should see `of-loop@ownframework` version `0.4.0`.

Then open Claude in the repository you want to work on:

```bash
cd /path/to/your-target-repository
claude
```

The stable Claude commands remain:

```text
/of-loop:spec <mission>
/of-loop:spec approve <run-id>
/of-loop:build <run-id>
/of-loop:review <run-id>
```

`/of-loop:spec approve` only surfaces the operator command; the model does not perform approval. The human executes `ofloop spec approve <repo> <run-id>` from an interactive terminal.

### Session-local Claude evaluation

To try the plugin without installing it:

```bash
git clone https://github.com/william-london/ownframework-loop.git /path/to/ownframework-loop
cd /path/to/your-target-repository
claude --plugin-dir /path/to/ownframework-loop
```

`--plugin-dir` is session-local. If you exit and start a new Claude session, launch again with the flag. A plain later `claude` launch automatically includes OwnFramework Loop only after the persistent install path.

## Portable Agent Skills

The host-neutral skill descriptions live under:

```text
.agents/skills/of-loop-spec/
.agents/skills/of-loop-build/
.agents/skills/of-loop-review/
.agents/skills/of-loop-status/
```

They describe how an agent participates in the same protocol while delegating approval, lifecycle transitions, candidate identity, verdict identity, and repair accounting to `ofloop`.

The existing Claude plugin skills under `skills/` remain first-class and may use Claude-specific extensions. Portability is additive; it is not a lowest-common-denominator rewrite of the Claude adapter.

## Experimental Codex quickstart

Codex uses a separate opt-in adapter path so Claude users do not inherit provider-selection or configuration steps.

From a clone of this repository:

```bash
bash install-adapter.sh codex
```

By default this installs:

- the exact committed OwnFramework Loop core under user-local data;
- a managed `ofloop` launcher under `~/.local/bin`;
- `of-loop-spec`, `of-loop-build`, `of-loop-review`, and `of-loop-status` under `~/.agents/skills`.

The installer refuses unmanaged conflicts instead of overwriting them. Remove the adapter with:

```bash
bash uninstall-adapter.sh codex
```

Restart Codex after installation so skill discovery can refresh.

Inspect the installed adapter contract:

```bash
ofloop adapter show codex
ofloop adapter doctor codex --allow-unverified
```

If `~/.local/bin` is not already on your `PATH`, use the path printed by the installer or add it to your shell configuration.

Codex remains **experimental** and `live_verified=false` until a real authenticated Codex environment proves skill discovery and a disposable spec/build/review lifecycle. GitHub Actions currently proves the current Codex CLI installs, the adapter distribution installs/uninstalls cleanly, and the portable files conform to the same deterministic core contract; that is not presented as equivalent to live agent-host proof.

See [`adapters/codex/README.md`](adapters/codex/README.md) for the current boundary.

## Adapter inspection

The deterministic adapter CLI does not launch providers or store credentials:

```bash
./bin/ofloop adapter list
./bin/ofloop adapter show claude-code
./bin/ofloop adapter doctor claude-code
./bin/ofloop adapter show codex
```

## Architecture

The core/adapter split is intentionally small:

```text
                         OwnFramework Loop
                                │
                    deterministic protocol/core
                                │
          ┌─────────────────────┴─────────────────────┐
          │                                           │
  Claude Code adapter                         Codex adapter
  stable / hardened                           experimental
```

The core owns:

- work-packet validation;
- interactive approval and packet-hash binding;
- deterministic lifecycle transitions;
- locks and bounded budgets;
- isolated worktree/candidate handling;
- exact candidate Git SHA;
- exact-SHA review/verdict binding;
- repair accounting and terminal semantics;
- the boundary before human promotion.

Adapters own host-specific discovery, skills, agents, hooks, and installation UX. They do not get a parallel state machine.

Start with:

- [`docs/architecture/CORE_INVARIANTS.md`](docs/architecture/CORE_INVARIANTS.md)
- [`docs/architecture/ADAPTER_CONTRACT.md`](docs/architecture/ADAPTER_CONTRACT.md)
- [`docs/architecture/CAPABILITY_MATRIX.md`](docs/architecture/CAPABILITY_MATRIX.md)
- [`docs/architecture/AGENT_SKILLS.md`](docs/architecture/AGENT_SKILLS.md)
- [`docs/ADAPTER_DEVELOPMENT.md`](docs/ADAPTER_DEVELOPMENT.md)

## Core invariants

1. Approval is a human-operated boundary. The portable core requires interactive confirmation; hardened adapters additionally withhold the approval command from the agent tool surface.
2. Approval binds the exact work-packet bytes/hash.
3. Builders operate inside approved scope and budgets.
4. Candidate identity is an exact Git SHA.
5. Review binds to that exact SHA—not an arbitrary current worktree.
6. State transitions are serialized and deterministic.
7. Repair cycles are bounded.
8. Terminal states fail closed.
9. The loop does not gain push, merge, deploy, publish, send, payment, or unrelated remote authority.
10. Human promotion remains outside the loop.

## Methodology versus governance

OwnFramework Loop is designed to coexist with engineering methodologies and skill collections.

A methodology can answer:

> How should the agent engineer this change?

OwnFramework Loop answers:

> What exact work was approved, what immutable candidate was produced, what exact candidate was reviewed, how are repairs bounded, and is that candidate eligible for human promotion?

The two layers are complementary.

## Validation

Canonical source validation:

```bash
./validate.sh
./release_gate.sh
```

Stable release markers include:

```text
OF_LOOP_FAILED=0
OF_LOOP_RELEASE_GATE_RESULT=PASS
RELEASE_GATE=PASS
```

Adapter-specific conformance:

```bash
bash tests/run_adapter_conformance.sh
bash tests/integration/test_adapter_portability.sh
bash tests/integration/test_adapter_cli.sh
bash tests/integration/test_codex_adapter_install.sh
```

GitHub Actions runs the generic integration matrix on Linux and macOS with supported Python versions, the full release gate on dedicated Ubuntu jobs, a real Claude plugin distribution proof, and a current Codex CLI/static distribution proof. Real authenticated agent-host lifecycle proofs remain separate when they require an existing account session.

## Requirements

Core/runtime:

- Python 3.12+
- Git
- Bash / POSIX-style environment
- macOS or Linux for the current lock/worktree/runtime implementation

Claude reference adapter:

- Claude Code 2.1+ for the currently documented plugin workflow

Codex is required only when evaluating the experimental Codex adapter.

## Project status

Current release line: **0.4.0**

v0.4.0 broadens the architecture from a Claude-specific product identity to an agent-neutral protocol with Claude Code as the stable reference adapter. Codex remains experimental until live host evidence is completed.

This is still an early public project. Real-repository effectiveness depends on the task, repository, agent host, environment, and validation supplied by the operator.

See [`CHANGELOG.md`](CHANGELOG.md) for release history.

## Contributing

Contributions are welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md). Adapter contributors should also read [`docs/ADAPTER_DEVELOPMENT.md`](docs/ADAPTER_DEVELOPMENT.md).

## Security

See [`SECURITY.md`](SECURITY.md) for the supported release posture and responsible disclosure path.

## License

Apache License 2.0. See [`LICENSE`](LICENSE) and [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
