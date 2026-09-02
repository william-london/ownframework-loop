# Agent Skills

Portable skills are optional adapter UX over the deterministic core.

- `.agents/skills/` contains portable Agent Skills for hosts such as Codex.
- `skills/` contains Claude Code adapter skills.

Neither directory is the OwnFramework Loop scheduler or source of protocol
truth.

The durable supervisor owns unattended cadence and invokes a registered
semantic runner after deterministic dispatch/prepare.

A skill may coordinate supported CLI calls; it may not invent repository,
worktree, state, candidate, or promotion authority.

Claude skills may use Claude-specific metadata because they live in the Claude
adapter surface. Portable skills must not assume Claude plugin commands.


## Capability-aware specification

Spec adapters should expose portable capability names rather than host paths.
The normal operator discovery sequence is:

```text
ofloop capabilities probe
ofloop capabilities preflight <repo> <capability>...
ofloop capabilities profile <name>
```

Packets may request `capabilities`. Newly authored current packets write a
trusted `runner_profile` name explicitly even though the schema keeps the
field optional for compatibility. `default` means provider default, not
interactive host-settings inheritance. Packet `network_read_allowlist` is only
the packet-specific portion of read authority; capability contracts may add
their exact required read hosts.
The effective union and runner-profile identity are sealed into the immutable
run-level capability binding before provider execution.

If preflight fails, the adapter must report the unavailable capability and stop
or revise the unstarted specification. It must never compensate by reopening
HOME, injecting host paths, weakening the sandbox, or inventing Docker/socket
authority. Privileged capabilities are available only after explicit
operator-owned canary commissioning.
