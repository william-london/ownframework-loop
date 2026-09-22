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

Per-pass scratch remains under the runtime cache. Durable package caches are
repository-scoped so repeated passes do not repeatedly download the same
artifacts. Cross-repository writable caches are intentionally forbidden:
a compromised client repository must not be able to poison another client's
future executable/package cache.

Browser binaries are NOT a cache. They live in one shared immutable asset
root (`default_browser_asset_dir()`), provisioned exactly once by the
operator and runtime-proven by the real browser canary. Every role consumes
that root READ-ONLY (PLAYWRIGHT_BROWSERS_PATH bound to it, browser GC
disabled for workers), so Chromium is never re-downloaded per pass and no
worker write can touch the proven binaries. The runtime proof is private and
freshness-bound to the current platform/runtime fingerprint and the exact
asset bytes (Merkle digest); any drift stales it automatically until the
canary re-proves it.

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

For an unfinished run that is deliberately quarantined because the trusted host
capability identity changed, the only supported recovery is the explicit
operator action `ofloop supervisor resume <repo> <run-id>
--rebind-capabilities`. It requires a dead, unambiguous worker, a valid packet
and approval, and a newly runtime-proven capability resolution. The migration
publishes immutable old/new binding snapshots and an auditable migration record
before replacing the active binding. It does not change engineering state,
candidate identity, pass or repair counters, or cost/token accounting. Accepted
semantic artifacts retain their original capability receipt provenance and may
be replayed only after their existing identity gates pass. Ordinary `resume`
without the explicit flag remains strict and never silently rebinds capability
authority. The supported operator lifecycle is serialized per run while this
operation is in flight: ordinary resume, explicit capability rebind, retirement,
enqueue, and PROGRAM continuation cannot race a stale QUARANTINED eligibility
snapshot. Runtime-generation migration remains a separate supervisor concern.

Migration history is crash-recoverable from the directory/snapshot publication
prefix through the PREPARED and COMPLETE record states. A retry validates every
existing artifact and continues only when its sequence, old binding, new
binding, and chain digest are exact; contradictory files, symlinks, or an
unexplained active binding fail closed.

## Reviewer cache isolation

Builder package caches are durable but repository-scoped. Reviewers use
pass-ephemeral writable caches so exact-SHA validation cannot persist poisoned
tool state into a later attempt. Trusted global assets — including the shared
immutable browser asset root, which builder and reviewer BOTH read — remain
read-only for every role; the reviewer's own mutable metadata stays ephemeral.
Inventory, preflight, and resolution all distinguish PROVISIONABLE/RESOLVABLE
(Playwright tooling present, assets installable) from RUNTIME-PROVEN (the
canary empirically launched the exact browser from the exact shared asset
root under the current platform/runtime); `available` means the latter only.

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


## Strict runner-profile commissioning

A runner profile that names a model is quality-strict and must use a pinned
provider model identity; moving Claude aliases such as `sonnet`, `opus`,
`haiku`, `best`, `default`, `opusplan`, and `[1m]` selectors are not
immutable model identity and are refused in strict profiles.

Commissioned Claude workers run in restricted mode and intentionally exclude
interactive user/project/local settings, including `~/.claude/settings.json`.
Those files are not model authority for unattended execution. A current packet
should name `runner_profile` explicitly; `default` means no Loop model pin.
The commissioned runner environment may select the model (for example through
`ANTHROPIC_MODEL`), otherwise Claude's provider default applies. It never means
"reread my interactive Claude model." A specific MiniMax, Qwen, Claude, or
other model exposed through the commissioned Claude CLI belongs in an
operator-owned named profile.

Provider routing/authentication is separate from packet authority. A
launchd/systemd supervisor that needs `ANTHROPIC_BASE_URL`, authentication,
`ANTHROPIC_MODEL`/default-model aliases, or `CLAUDE_CONFIG_DIR` may receive
only the supervisor's explicit allowlisted keys through a private JSON file
referenced by `OFLOOP_SERVICE_ENV_FILE`. The file is required to be an
operator-owned regular file under a private directory with mode 0600-or-stricter
and unknown keys fail closed. Packets never carry these secrets or endpoints.

A profile that also requests explicit effort requires a current-runtime
attestation before execution:

```bash
ofloop capabilities attest-effort <profile>
ofloop capabilities preflight /path/to/repo <capability>... --runner-profile <profile>
```

The attestation is private and binds the exact runner-profile identity plus the
current byte-bound Claude runtime fingerprint. A Claude update or profile change
stales it and requires explicit re-attestation. Preflight is execution-ready
proof: requested browser capabilities must already have a valid exact-asset
runtime canary proof, and strict effort must already be attested.

## Candidate-bound validation project environment

The `package.uv` capability only governs uv-as-package-manager: it provides
the executable, the network authority, and a per-(repo, run) `UV_CACHE_DIR`
that the supervisor externalizes out of the worktree. A separate, validator-
owned layer handles the *project environment* itself (the `.venv`-equivalent
`uv run` activates).

The validator owns the project environment instead of letting uv auto-sync
it next to the candidate. The environment:

- Lives under the supervisor-owned runtime cache, OUTSIDE the builder and
  reviewer Git worktrees:
  `<runtime_cache>/<repo_key>/<run_id>/validation/project-env/{builder,reviewer}/<env_id>/`
- Is identified by `sha256(candidate_sha || uv.lock_sha256 ||
  pyproject.toml_sha256)`. Different candidate, lock, or metadata produces a
  different env identity; the same triple produces the same env identity.
- Is provisioned exactly once per identity. The provisioner runs
  `uv sync --project <candidate_worktree> --python-preference only-system
  --locked`. The `--locked` flag refuses silent lockfile drift; the
  pinned `--python-preference` makes the env reproducible across hosts.
- Is bound into the validator subprocess env via `UV_PROJECT_ENVIRONMENT`
  + `VIRTUAL_ENV` only. The worker's allowRead/allowWrite is unchanged;
  the env dir is validator-owned and never leaks into worker authority.
- Survives across validations of the same candidate. A re-validation of
  the same candidate (same SHA + same lock + same metadata) reuses the
  cached env without re-running `uv sync`. A re-validation after a
  lockfile change produces a fresh env identity.

A `uv run` (or any `uv sync` / `uv exec` / `uv test` / `uv python` /
`uv lock`) invocation against an unprovisioned env is refused before the
subprocess is launched: the executor classifies the missing
provisioning as `infra_failure`, records a redacted `infra_failure` marker
under the runtime cache, and short-circuits to terminal `BLOCKED` without
burning a semantic repair round. The candidate author cannot fix infra
failures; the validator owner must.

The validator never reopens HOME, never widens any worker's authority
surface, and never lets the in-worktree `.venv` appear (the env path is
a different filesystem location entirely).
