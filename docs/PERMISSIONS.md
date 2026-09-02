# Commissioned Claude Semantic-Worker Permission Contract

OwnFramework Loop 0.9.1 is designed for SPEC -> unattended BUILD/REVIEW/repair -> human merge.

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

`--restricted` excludes user/project/local settings. Pass settings and role instructions are supplied explicitly by the installed core. Optional interactive host adapters do not widen the commissioned runner.

MCP discovery uses `--strict-mcp-config` with an explicit empty `{"mcpServers":{}}` config, because `--tools` does not govern MCP tools.

## Sandbox

Per-pass CLI settings enforce:

- sandbox enabled;
- fail if unavailable;
- automatic approval for sandboxed Bash;
- no unsandboxed-command escape;
- strict packet-bound network read allowlist (empty by default);
- operator-home and supervisor-state-root read deny with narrow current-pass/runtime re-opens plus, when required, one exact private adapter credential file;
- directory-wide adapter auth re-opens are rejected;
- reviewer worktree deny-write;
- commissioned provider/auth/model values live in a private 0600 service-env file rather than launchd/systemd definitions;
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
