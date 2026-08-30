# Commissioned Claude Semantic-Worker Sandbox

OwnFramework Loop 0.8.4 makes sandbox activation a property of the durable
supervisor runner, not an operator ceremony.

## Unattended BUILD / REVIEW contract

The supervisor supplies CLI settings for every fresh semantic pass with:

- `sandbox.enabled=true`;
- `sandbox.failIfUnavailable=true`;
- `sandbox.allowUnsandboxedCommands=false`;
- `sandbox.network.strictAllowlist=true`;
- `sandbox.network.allowedDomains=[]`;
- role-specific filesystem write rules.

The strict network setting requires Claude Code 2.1.219 or later. The runner
proves the Claude Code version before accepting it.

Project and local settings from the target repository are excluded using the
Claude setting-source boundary. User/managed configuration remains a trusted
operator/organization boundary, but the Loop's CLI `--settings` supplies the
security-critical sandbox scalars.

## Tool and MCP boundary

A sealed semantic worker receives only:

```text
Read
Edit
Write
NotebookEdit
Bash
Glob
Grep
```

The runner does not expose WebSearch, WebFetch, browser integration, Agent/Task
orchestration, Skill, or other non-local built-ins.

MCP discovery is disabled with strict MCP configuration and an empty explicit
MCP config. This prevents user/project/plugin MCP servers from silently
expanding a sealed pass.

## Filesystem behavior

Builder Bash runs in the builder worktree and may write its pass-scoped semantic
result directory plus the Loop runtime cache. Reviewer Bash receives an
explicit deny-write rule for the exact-SHA reviewer worktree and may write only
its pass-scoped assessment/runtime cache surfaces.

Protected-path hooks and deterministic finalizers remain defense in depth.

## Scope of the claim

This is an OS/runtime boundary for commissioned semantic Bash plus a structural
Claude tool/MCP boundary. It is not a claim that arbitrary same-user software is
a separate untrusted OS principal.

Interactive Claude sessions are not automatically equivalent to the
commissioned supervisor envelope.
