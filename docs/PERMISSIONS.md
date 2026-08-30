# Commissioned Claude Semantic-Worker Permission Contract

OwnFramework Loop 0.8.4 is designed for SPEC -> unattended BUILD/REVIEW/repair -> human merge.

## No human permission loop

Claude Code starts each semantic pass in native `--restricted` mode with `--permission-mode dontAsk`.

The exact tool set is pre-approved with `--allowedTools`, and sandboxed Bash auto-runs inside the OS boundary. Therefore ordinary authorized work does not prompt. Calls outside the sealed capability set are denied rather than asking the operator.

## Tool availability

Builder:

```text
Read,Edit,Write,NotebookEdit,Bash,Glob,Grep
```

Reviewer:

```text
Read,Bash,Glob,Grep
```

No WebSearch/WebFetch, Agent/Task, Skill, browser, promotion, deployment, or remote-mutation surface is present inside a semantic pass.

## Settings and MCP

`--restricted` excludes user/project/local settings. The Loop plugin and pass settings are supplied explicitly.

MCP discovery uses `--strict-mcp-config --mcp-config {}`, because `--tools` does not govern MCP tools.

## Sandbox

Per-pass CLI settings enforce:

- sandbox enabled;
- fail if unavailable;
- automatic approval for sandboxed Bash;
- no unsandboxed-command escape;
- strict empty network allowlist;
- operator-home read deny with narrow current-pass/runtime re-opens;
- reviewer worktree deny-write;
- credential environment-variable denies.

The worker environment also sets `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`.

## Human authority

The only intended human gates are:

1. SPEC/packet approval before execution.
2. Final merge/promotion after terminal APPROVED.

Executable packets remain:

```text
merge_authority=human_only
push_authority=human_only
deploy_authority=human_only
external_action_authority=none
promotion_policy=human_gate
```

Everything between those gates is expected to run unattended.
