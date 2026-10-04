# Work Packet Format

`WORK_PACKET.md` is the durable mission contract for an OwnFramework Loop
run. It combines human-readable Markdown with a strict JSON metadata block.

The parser is `lib/ownframework_loop/packet.py`. Current supported packet
schemas are v1 (legacy), v2 (single-mode/current compatibility), and v3
(PROGRAM-capable).

## Human boundary and execution binding

The human supplies or approves the mission content **before execution starts**.
Normal current operation does not require `ofloop spec approve`.

At the first legitimate build start, the deterministic core creates the
immutable execution seal (historically stored as `APPROVAL.json`) with:

- exact packet SHA-256;
- canonical repository path;
- spec-time baseline branch and exact SHA;
- deterministic candidate branch;
- packet schema and risk metadata;
- PROGRAM graph provenance when applicable.

After the seal exists, packet drift is refused. Changed mission or scope
requires a new run.

The historical TTY pre-seal remains compatibility-only and must not be
presented as the normal operator flow.

## Core metadata

All current packets carry:

- `schema`
- `packet_id`
- `created_at`
- `work_class`
- `risk_class`
- `title`
- `target.repo` (absolute path)
- `target.branch`
- `target.classification`
- non-empty `acceptance_criteria`
- `non_goals`
- non-empty `allowed_paths`
- non-empty `protected_paths`
- non-empty `work_units`
- `merge_authority`
- `deploy_authority`
- `push_authority`
- `external_action_authority`

v3 PROGRAM packets may additionally define `execution_mode=program` and a
finite `checkpoint_graph`.

Portable execution declarations include:

- `capabilities`: schema-optional semantic capability names such as
  `toolchain.python`, `package.uv`, or `browser.playwright.chromium`; never
  host paths;
- `runner_profile`: schema-optional for compatibility, but explicitly written
  in every newly authored current packet. It is a trusted operator/core-owned
  profile name. `default` means no Loop model pin: the commissioned runner
  environment may select the model (for example through `ANTHROPIC_MODEL`),
  otherwise the provider default applies. A named profile may choose
  model/effort only and cannot express security-authority flags. Commissioned
  Claude workers do not reread interactive `settings.json` model choice.

## Read-only network and capability authority

`network_read_allowlist` is optional frozen SPEC authority for packet-specific
sandboxed Bash reads. Each entry is an exact lowercase hostname with no scheme,
port, path, or wildcard.

Capabilities may contribute additional exact read domains needed by their
trusted contract (for example package registries or Playwright browser
downloads). The effective native `allowedDomains` set is:

```text
packet network_read_allowlist
UNION
resolved capability-derived domains
```

The first semantic execution binds that effective set together with stable
capability/tool/manifest/privileged-canary and runner-profile identity.
Every later pass must exact-match before model launch. Cache contents and
pass-ephemeral cache paths are not execution identity.

Neither source grants WebSearch/WebFetch, MCP, push, publish, deploy or remote
mutation. A newly required packet domain/capability/profile after sealing
requires a new mission rather than an interactive permission escalation.

## Required validation

`required_validation` commands are executable policy. Deterministic build and
review finalizers therefore classify them through the command guard before
execution, run them only in the prepared worktree, impose a bounded timeout,
and capture exact exit status.

A packet must never use required-validation as a disguised external-action,
promotion, deployment, or remote-mutation channel.

### Bounded end-to-end validation (local service, container, browser)

A packet that needs to prove a *running* product — a real containerized build,
a live local HTTP service, a browser journey — can express that today, but the
contract is a **foreground** one and the schema is deliberately minimal:

- `command` is the only field. There is no `cwd`, `env`, `network`, `setup`,
  `teardown`, or `service` field, and `additionalProperties: false` means none
  can be added without a packet-schema version bump. The command runs under
  `/bin/sh -c` in the prepared worktree, so relative paths, `cd`, and `VAR=value`
  prefixes are the levers.
- The timeout is **packet-level and shared**: `required_runtime_proof.max_runtime_seconds`
  (default 600s, ceiling 1800s) applies identically to every validation row. A
  fast unit suite and a full image-build-plus-journey draw from the same budget.
  Size it for the heaviest row.

Four constraints shape the supported pattern:

1. **Foreground ownership.** Required validation is a foreground contract.
   Each command is bounded in a fresh process group, and shell-level detachment
   primitives — `setsid`, `nohup`, `daemonize`, `disown`, `systemd-run`, and
   `launchctl bootstrap|kickstart|start|submit` — are refused outright.
2. **No escaped service ownership.** A direct child that exits 0 while
   descendants survive in its process group is scored `rc=125` and carries the
   `OFLOOP_PROCESS_GROUP_LEAK=refused` marker, so a validation cannot appear
   finished while work it started is still running. Keep the orchestrator
   attached so teardown happens inside the bounded lifecycle: prefer an
   **attached** `docker compose up` in the foreground process group over
   `up -d`, then run the journey, then `docker compose down` in the same
   command.
3. **The uv/local-bind interaction.** Loopback bind, inbound, and outbound are
   allowed for an ordinary validation. But when a command is classified as
   uv-mediated, a package proxy is engaged and the network profile is reduced
   to outbound-to-proxy only — **no** `network-bind`, **no** `network-inbound`.
   A uv-classified validation therefore cannot start or reach a local HTTP
   server. Drive the local server from a non-uv command, or provision
   dependencies in a separate validation row.
4. **Everything must already exist locally.** Validation egress is denied
   outside loopback, so a validation cannot `npm install` or
   `playwright install`. `browser.playwright.chromium` supplies browser
   *binaries* via the commissioned shared asset root for operator-side
   provisioning; it does not install a test runner. Every byte the journey
   needs must already be in the candidate repository or the frozen asset root.

Because of these, the recommended pattern is to keep the complexity in a
**tracked repository script** and have `required_validation` invoke it:

```json
{ "name": "clean_startup", "command": "bash scripts/verify_clean_checkout.sh",
  "kind": "full", "expected_exit_code": 0,
  "expected_marker": "CLEAN_CHECKOUT=PASS" }
```

The script owns the compose lifecycle, the health wait, the browser journey, and
deterministic teardown, with failures surfacing as a non-zero exit. A single
row then stays reviewable, the `expected_marker` gives the finalizer a positive
proof signal rather than exit-status-only, and the script is ordinary tracked
product source the builder can maintain and the reviewer can read. Do not embed
a large shell pipeline directly in `WORK_PACKET.md`.

The final whole-product review re-executes the effective validation contract in
a clean reviewer worktree at the exact candidate SHA, and at `program_final`
that contract is the union of the top-level list with every finalized
checkpoint's own `required_validation`. A startup proof belongs in the
top-level list when it must hold from the first checkpoint onward.

## Stable IDs

Use stable IDs across repair rounds:

- `AC-N` acceptance criteria;
- `NG-N` non-goals;
- `UNIT-N` work units;
- `CP-N` PROGRAM checkpoints;
- stable review finding IDs.

## Promotion authority

Starting a run or reaching `APPROVED` does not grant push, merge, deploy,
publish, payment, message-sending, or unrelated external authority. Promotion
remains outside Loop.

## Repository classification is spec-time identity

`target.classification` describes the repository as it exists when the mission is finalized:

- `local_only` — no configured Git remote is part of the run baseline.
- `github_private` — the project is intentionally backed by a private GitHub repository before the run is minted.
- `github_public` — the project is intentionally backed by a public GitHub repository before the run is minted.

When a GitHub review surface is part of the project's operating model, establish that remote, push/prove the intended baseline, and only then create the Loop run. Do not create a `local_only` run and attach a remote afterward.

The executable core already refuses a `local_only` target that has configured remotes. If repository remote topology changes after `spec new` but before first execution, the clean normal path is to stop the never-started run and create a fresh run from the final repository identity/baseline.

## Scope path notation

Loop scope is deterministic prefix matching, not a general glob engine. A single
trailing `/**` is accepted as a compatibility spelling for the same directory
prefix: `apps/**` and `apps` authorize exactly the same subtree. Other wildcard
forms are rejected at packet validation.

## PROGRAM checkpoint acceptance field

Use checkpoint field acceptance_criterion_ids. The stale/misnamed
acceptance_criteria checkpoint key is not executable and is rejected before
start.

When one checkpoint scopes acceptance IDs, every checkpoint must do so, and the
union must cover every top-level AC id.

## PROGRAM budget truth

Risk budgets are checked against executable ceilings before first semantic
execution. For v3, source-size ceilings are currently 500 changed files and
30,000 diff lines. Packet-wide cumulative build/review/repair envelopes may be
up to 128; checkpoint-local pass caps remain at most 32.

For v4 PROGRAMs, `mission_budget.segment_max_diff_lines` and
`risk_budget.max_diff_lines` bind the selected per-segment source limit. The
single v4 platform maximum is 100,000 diff lines per segment. The separately
sealed `mission_budget.mission_max_diff_lines` and
`checkpoint_graph.global_source_ceilings.max_baseline_to_final_diff_lines`
bind total source change from the original mission baseline, up to the finite
480,000-line v4 mission maximum. `max_segments` is finite (at most 16).
SPEC chooses appropriate packet values from the expected whole graph and
largest checkpoint; automatic segmentation never enlarges any of them.
Previously sealed v4 packets whose PROGRAM global source ceiling equals the
segment limit keep that exact narrower authority; new SPEC authoring binds it
to the mission-total envelope.

New v4 packets seal adaptive semantic-budget policy explicitly. It permits
one-claim redistribution within cumulative BUILD/REVIEW/REPAIR ceilings while
preserving future-checkpoint and final-review reserves. An absent policy on an
already-sealed v4 packet retains its original local-cap meaning.

Top-level max_build_passes, max_review_passes, and max_repair_rounds are
cumulative PROGRAM envelopes. They are not per-checkpoint defaults. A declared
global repair allowance is invalid if the global build/review caps cannot
execute one initial pass per checkpoint plus those repairs.

For a new unattended v4 PROGRAM, SPEC should choose generous but finite
cumulative pass/repair ceilings for substantive autonomous work; checkpoint
values are initial allocations under the explicitly sealed adaptive policy.
Routine operators do not tune these semantic budgets. v1-v3 and already-sealed
v4 packets keep their historical semantics.

risk_budget.max_pass_runtime_seconds is enforced for each semantic worker.
A positive supervisor --timeout-seconds is only a narrowing override.
