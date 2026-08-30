# Commissioned Claude Semantic-Worker Permission Contract

OwnFramework Loop 0.8.4 owns the permission/tool envelope for unattended
supervisor-spawned BUILD/REVIEW passes.

## Fixed built-in tool set

```text
Read,Edit,Write,NotebookEdit,Bash,Glob,Grep
```

`--tools` is the structural availability boundary. `--allowedTools`
pre-approves that same already-restricted local set so headless workers do not
stop for ordinary engineering prompts.

`OFLOOP_CLAUDE_ALLOWED_TOOLS` does not widen this surface.

## Settings and MCP sources

The worker loads trusted user settings but excludes project/local target-repo
settings. The OwnFramework Loop plugin is supplied explicitly.

MCP discovery uses strict mode with an empty explicit configuration, so
user/project/plugin MCP servers cannot silently grant additional capabilities
inside the sealed pass.

## Sandbox

Per-invocation CLI settings enforce:

- sandbox enabled;
- fail if unavailable;
- no unsandboxed-command escape;
- strict empty-domain Bash network allow-list;
- role-specific filesystem write policy.

Claude Code 2.1.219+ is required because strict sandbox network allow-list
enforcement is part of the commissioned boundary.

## Authority-sensitive overrides

`OFLOOP_CLAUDE_EXTRA_ARGS` is convenience only. The supervisor refuses
attempts to replace settings sources, sandbox settings, tool lists, MCP config,
plugin roots, permission modes, browser/remote surfaces, or session authority.

## External effects

Executable Loop packets retain:

```text
merge_authority=human_only
push_authority=human_only
deploy_authority=human_only
external_action_authority=none
promotion_policy=human_gate
```

Research/integrations happen before the PROGRAM is minted or after Loop stops.
Promotion remains outside Loop.
