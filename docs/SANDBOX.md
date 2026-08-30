# Claude Semantic-Worker Sandbox

OwnFramework Loop 0.8.4 makes sandbox activation a property of the
commissioned Claude supervisor runner, not an operator precondition.

## Commissioned unattended BUILD / REVIEW contract

Each fresh supervisor-spawned Claude semantic pass is launched with inline
Claude settings equivalent to:

```json
{
  "sandbox": {
    "enabled": true,
    "failIfUnavailable": true,
    "autoAllowBashIfSandboxed": true,
    "allowUnsandboxedCommands": false
  },
  "permissions": {
    "deny": ["WebFetch", "WebSearch"]
  },
  "disableBypassPermissionsMode": "disable",
  "autoMemoryEnabled": false
}
```

The runner also:

- loads only the trusted user settings source, excluding project/local Claude
  settings from client repositories;
- supplies the OwnFramework Loop plugin explicitly;
- uses strict MCP configuration with an empty MCP set;
- disables Chrome and session persistence;
- exposes only `Read,Edit,Write,NotebookEdit,Bash,Glob,Grep`;
- refuses `OFLOOP_CLAUDE_EXTRA_ARGS` values that try to replace
  authority-sensitive settings, MCP, tool, plugin, remote, browser, or
  permission flags.

If Claude's Bash sandbox cannot be activated, the semantic pass fails rather
than silently falling back to unsandboxed Bash.

## What this boundary means

The sandbox is an OS/runtime boundary for Bash commands and their child
processes in a commissioned semantic pass. It complements, rather than
replaces:

- protected-path hooks;
- external-action classification;
- execution-seal and packet authority;
- exact candidate-SHA finalization;
- clean reviewer worktree proof;
- operator-owned promotion.

Loop does not claim that arbitrary same-user software is transformed into a
separate untrusted OS principal.

## Network and research

Sealed BUILD/REVIEW workers do not receive WebSearch, WebFetch, inherited MCP
servers, browser tools, or nested Agent/Task orchestration. Research and
external integrations belong before the PROGRAM is minted or after Loop has
stopped, under operator/governor authority.

## Interactive sessions

Foreground/manual Claude sessions are useful debugging and operator surfaces,
but they are not automatically equivalent to the commissioned supervisor
envelope. The 0.8.4 containment claim applies to supervisor-spawned semantic
passes.
