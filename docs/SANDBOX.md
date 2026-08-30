# Commissioned Claude Semantic-Worker Sandbox

OwnFramework Loop 0.8.4 uses Claude Code's native shared-machine controls instead of recreating them.

## Native boundary

Every supervisor-spawned BUILD/REVIEW pass requires Claude Code 2.1.248+ and starts with:

- `--restricted`;
- `--permission-mode dontAsk`;
- fail-closed Bash sandboxing;
- `allowUnsandboxedCommands=false`;
- strict packet-bound Bash network allowlist (empty by default);
- strict empty MCP configuration;
- Chrome disabled;
- session persistence disabled.

Restricted mode excludes user/project/local settings and confines built-in file tools to the pass working directory. Loop supplies only pass-specific runtime settings and role instructions; the optional interactive Claude plugin is not the owner of the commissioned core runtime.

## Zero routine prompts

`dontAsk` is paired with an explicit pre-approved tool set and `sandbox.autoAllowBashIfSandboxed=true`. Allowed local engineering actions run without human prompts. Anything outside the sealed set is denied, not escalated.

This is intentionally not `bypassPermissions`: Claude Code's native restricted mode refuses bypassPermissions. The operational goal is the same—no human in the BUILD/REVIEW loop—but with a real isolation boundary.

## Role-specific capabilities

Builder:

```text
Read,Edit,Write,NotebookEdit,Bash,Glob,Grep
```

Reviewer:

```text
Read,Bash,Glob,Grep
```

Reviewer source immutability is therefore structural. Sandboxed Bash may write only the pass semantic-result directory/runtime cache, and reviewer Bash is deny-write for the exact-SHA worktree.

## Bash read and credential boundary

Bash denies reads of the operator home directory and re-opens only the current worktree, current semantic-result directory, runtime cache, required Git metadata, and the trusted Loop runtime payload.

The supervisor sets `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`, and sandbox credential rules deny common GitHub/npm/PyPI/container tokens. Model authentication remains available to the Claude process itself, not to its Bash children.

## Network

Semantic BUILD/REVIEW passes have no broad internet. Sandboxed Bash may reach only exact hostnames frozen in the packet's `network_read_allowlist`; omission/empty means zero egress. This is intended for dependency/download reads, not search, browsing, publishing, deployment, or remote mutation. The SPEC author derives the smallest required list from the declared toolchain before sealing.

## Scope

This is the commissioned unattended worker contract. Interactive Claude sessions are not equivalent evidence.

## Platform prerequisites

- macOS: Claude's native sandbox uses the platform sandbox implementation.
- Linux/WSL2: commissioned Claude execution requires `bubblewrap` and `socat`.
  The Linux service installer also performs a real bubblewrap usability probe
  and refuses commissioning when the native boundary cannot arm.

A missing Linux sandbox prerequisite is an installation/configuration defect,
not a reason to fall back to unsandboxed unattended execution.
