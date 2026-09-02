# Portability Model

## Product portability

OwnFramework Loop is portable when the deterministic core, installed runtime,
durable supervisor lifecycle, and packet/evidence contracts remain independent
of any one model host.

Current supported core/service platforms:

- macOS: core + launchd user supervisor.
- Linux: core + systemd-user supervisor.
- WSL2: Linux model when systemd user services are available.
- native Windows: not currently a commissioned-supervisor target.

Core CI runs on Ubuntu and macOS across supported Python versions.

## Host portability

A semantic host does not need a native plugin API. At the portability floor it
must be able to:

1. consume one deterministic work order;
2. inspect/edit the supplied BUILD worktree or read the REVIEW worktree;
3. execute local validation inside declared authority;
4. write the exact pass-scoped semantic artifact;
5. return control to deterministic finalize.

Native plugin/skills/hooks are UX and defense-in-depth features, not protocol
truth.

## Current host maturity

Claude Code is the first hardened live runner because its native restricted
execution/sandbox is integrated and proven.

Codex remains experimental. Generic CLI describes the contract, not a claim
that an unspecified host is automatically safe for unattended production.

## Installation portability

`install.sh` installs core only.

`bin/install-adapter <adapter>` installs host integration only.

`bin/install-supervisor` selects the platform service manager.

No adapter cache is an OwnFramework Loop runtime root.

## Compatibility policy

Historical artifact fields required for deterministic audit remain readable.
Retired executable commands, old plugin-install assumptions, and misleading
scheduler paths are removed from active surfaces instead of preserved as
runtime choices.

## Capability portability

Packets declare host-neutral capability names. The core resolves those names
through built-ins and an operator-owned host manifest, records exact executable
and version evidence, and refuses execution when the host cannot satisfy the
packet safely. Host paths therefore no longer belong in portable mission
contracts. Writable durable caches are repository-scoped; trusted shared assets
are read-only.
