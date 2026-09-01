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

 Docker is available only through a canary-proven, commissioned drop-in broker executable named
`docker`; the exact broker path/digest is operator evidence and the semantic worker may not redirect it. The broker is
responsible for enforcing a narrower container authority than the host daemon.

## Local services

`local.http-service` is explicit and fail-closed. Loop does not silently set
Claude's native `allowLocalBinding`: that primitive has historically widened
network authority on macOS. A host may enable it only through an operator-owned
commissioned provider plus core-receipted canary evidence for the exact Claude/sandbox generation.

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

## Privileged canary commissioning

`container.docker` and `local.http-service` are unavailable until the
operator runs a trusted canary through:

```bash
ofloop capabilities commission container.docker
ofloop capabilities commission local.http-service
```

The host manifest names a private, operator-owned `canary_executable` (and
for Docker, the exact private broker executable). Core executes the fixed
canary protocol and writes protected commissioning evidence under the Loop
state root. Evidence binds capability-contract revision, semantic runtime
fingerprint, platform/architecture, provider/broker path+digest, canary
path+digest/kind/version/result, and host-manifest SHA-256. Copying the current
runtime fingerprint into JSON is not commissioning.

Source/CI tests use deterministic fake providers/canaries. They prove the
protocol; they do not claim that William's physical Mac, Docker daemon, or
local-binding provider has been commissioned.

## Run-level binding and drift

Before the first provider execution, stable authority is written to
`CAPABILITY_BINDING.json`. Every later BUILD/REVIEW/repair attempt re-resolves
and must exact-match it before provider release. The binding includes requested
capabilities, contract revision, host-manifest hash, runtime/platform identity,
resolved executable path/version/SHA, trusted asset identity, effective network
domains, stable filesystem/sandbox authority, privileged commissioning evidence
identity, and runner-profile identity.

Repository-scoped mutable builder caches and pass-ephemeral reviewer cache paths
are intentionally excluded. Tool/manifest/profile/network/privileged evidence
drift fails operationally before a model call and never silently rebinds an
existing run.

## Reviewer cache isolation

Builder package/browser caches are durable but repository-scoped. Reviewers use
pass-ephemeral writable caches so exact-SHA validation cannot persist poisoned
tool state into a later attempt. Trusted global assets remain read-only.

## Host IPC environment

Semantic workers unconditionally scrub daemon/agent selectors including
`DOCKER_HOST`, `DOCKER_CONTEXT`, `CONTAINER_HOST`, `PODMAN_HOST`,
`KUBECONFIG`, `SSH_AUTH_SOCK`, and `GPG_AGENT_INFO`. Docker commands are
also refused by the Bash guard unless `container.docker` was actually resolved.

## Operator preflight

No model call is required to inspect this layer:

```bash
ofloop capabilities fingerprint
ofloop capabilities probe
ofloop capabilities preflight /path/to/repo toolchain.python package.uv
```

`probe` and `profile` are read-only. `preflight` resolves the exact requested
set using the semantic resolver. `commission` is the explicit trusted mutation
that runs and receipts privileged canary evidence. Resolution includes
executable/version/digest, filesystem/cache, effective network, canary evidence,
runner profile, and HOME-access checks. A missing
capability therefore fails before provider execution.
