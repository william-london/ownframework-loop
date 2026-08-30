# Claude Semantic-Worker Permission Contract

OwnFramework Loop 0.8.4 does not require the operator to export a special
permission-profile environment variable before an unattended run. The
commissioned supervisor owns the semantic worker's invocation contract.

## Tool surface

A supervisor-spawned BUILD/REVIEW pass receives exactly:

```text
Read
Edit
Write
NotebookEdit
Bash
Glob
Grep
```

It does not receive web/browser research tools, MCP servers, nested Agent/Task
orchestration, or promotion/deployment tools.

`--tools` is the structural built-in tool allow-list. `--allowedTools`
pre-approves the same narrow list so the non-interactive worker does not stop
for routine local engineering permissions.

## Settings sources

The worker reads the trusted user settings source for operator/authentication
configuration. Project and local settings from the client repository are not
loaded into the semantic worker. The Loop plugin is supplied explicitly.

MCP discovery is fail-closed through strict MCP configuration with an empty
explicit MCP config, so user/project/plugin MCP servers cannot silently expand
the sealed pass.

## Sandbox and bypass prevention

The supervisor overlays per-invocation settings that:

- enable Claude's Bash sandbox;
- fail if the sandbox is unavailable;
- permit automatic Bash approval only while sandboxed;
- disable unsandboxed-command escape;
- disable bypass-permissions mode;
- disable automatic memory;
- deny WebSearch and WebFetch as defense in depth.

Authority-sensitive command-line overrides are rejected before Claude starts.

## External effects

The packet authority for executable runs remains:

```text
merge_authority=human_only
push_authority=human_only
deploy_authority=human_only
external_action_authority=none
promotion_policy=human_gate
```

Tool restrictions and sandboxing are defense in depth. Deterministic finalizers
and exact-SHA review remain protocol authority, and promotion happens outside
Loop.

## Interactive sessions

These constraints describe the commissioned supervisor runner. An operator's
ordinary foreground Claude session may intentionally have a broader tool or MCP
surface and must not be represented as equivalent evidence.
