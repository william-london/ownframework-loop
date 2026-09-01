# Host Capability Plane

OwnFramework Loop packets declare portable semantic capability names. They do
not declare host filesystem paths, sockets, credentials, or vendor-specific
runtime locations.

## Authority model

```text
WORK_PACKET capability names
        |
        v
trusted capability resolver
        |
        +-- executable + version proof
        +-- exact read/write paths
        +-- repository-scoped writable caches
        +-- trusted read-only host assets
        +-- derived network hosts
        +-- sandbox-specific safe primitives
        |
        v
CAPABILITY_RESOLUTION receipt
        |
        v
restricted semantic worker
```

Resolution is fail-closed. An unavailable capability stops before Claude is
launched; the model cannot widen its own host authority.

## Cache model

Per-pass scratch remains under the runtime cache. Durable package/browser
caches are repository-scoped so repeated passes do not repeatedly download the
same artifacts. Cross-repository writable caches are intentionally forbidden:
a compromised client repository must not be able to poison another client's
future executable/package cache.

A host manifest may point a capability at a trusted global asset store. Those
assets are read-only to semantic workers.

## HOME

The worker still denies HOME broadly. A system tool discovered outside HOME is
resolved to its exact executable. A tool that resolves under HOME requires an
operator-owned host-manifest entry with explicit read paths. PATH discovery is
therefore no longer treated as proof of sandbox usability.

## Docker

`container.docker` is privileged. The resolver never exposes
`/var/run/docker.sock`, OrbStack's daemon socket, Podman/containerd sockets, or
a Claude `excludedCommands` escape.

Docker is available only through a commissioned drop-in broker executable named
`docker`, recorded with an operator proof in the host manifest. The broker is
responsible for enforcing a narrower container authority than the host daemon.

## Local services

`local.http-service` is explicit and fail-closed. Loop does not silently set
Claude's native `allowLocalBinding`: that primitive has historically widened
network authority on macOS. A host may enable it only through an operator-owned
commissioned provider/proof after the exact Claude/sandbox generation has been
tested.

## Host manifest

Default:

```text
$XDG_STATE_HOME/ownframework-loop/host-capabilities.json
```

or:

```text
~/.local/state/ownframework-loop/host-capabilities.json
```

The file must be a regular non-symlink owned by the supervisor user and must
not be group/world writable.

Example custom tool:

```json
{
  "schema": "ownframework-loop-host-capabilities/v1",
  "capabilities": {
    "toolchain.custom": {
      "kind": "tool",
      "executable": "/opt/tools/custom/bin/custom",
      "version_args": ["--version"],
      "read_paths": ["/opt/tools/custom"]
    }
  }
}
```

The manifest is operator authority. Repository content cannot edit it from a
semantic worker because the supervisor state root remains denied.

## Privileged proof binding

For `container.docker` and `local.http-service`, `proof` is not a free-form
attestation. It must equal the current semantic runtime fingerprint, which binds
platform/architecture and the commissioned Claude executable/version. Changing
Claude Code or the host invalidates the privileged grant until it is re-tested
and re-commissioned. Resolved executable bytes are SHA-256 digested into the
attempt receipt.

## Reviewer cache isolation

Builder package/browser caches are durable but repository-scoped. Reviewers use
pass-ephemeral writable caches so exact-SHA validation cannot persist poisoned
tool state into a later attempt. Trusted global assets remain read-only.

## Host IPC environment

Semantic workers unconditionally scrub daemon/agent selectors including
`DOCKER_HOST`, `DOCKER_CONTEXT`, `CONTAINER_HOST`, `PODMAN_HOST`,
`KUBECONFIG`, `SSH_AUTH_SOCK`, and `GPG_AGENT_INFO`. Docker commands are
also refused by the Bash guard unless `container.docker` was actually resolved.
