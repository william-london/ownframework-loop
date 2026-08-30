# Commissioned Claude Semantic-Worker Sandbox

OwnFramework Loop 0.8.4 uses Claude Code's native shared-machine controls instead of recreating them.

## Native boundary

Every supervisor-spawned BUILD/REVIEW pass requires Claude Code 2.1.248+ and starts with:

- `--restricted`;
- `--permission-mode dontAsk`;
- fail-closed Bash sandboxing;
- `allowUnsandboxedCommands=false`;
- strict empty Bash network allowlist;
- strict empty MCP configuration;
- Chrome disabled;
- session persistence disabled.

Restricted mode excludes user/project/local settings and confines built-in file tools to the pass working directory. Loop supplies only the pass-specific CLI settings and its explicit plugin.

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

Semantic BUILD/REVIEW passes have no outbound network. Research, dependency provisioning, package acquisition, and external integrations belong to the automated pre-SPEC/bootstrap phase. A sealed pass should not discover that it needs the internet after SPEC approval.

## Scope

This is the commissioned unattended worker contract. Interactive Claude sessions are not equivalent evidence.
