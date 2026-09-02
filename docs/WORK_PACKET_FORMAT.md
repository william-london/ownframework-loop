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
  profile name. `default` intentionally accepts the live runner's provider
  default; a named profile may choose model/effort only and cannot express
  security-authority flags. Commissioned Claude workers do not inherit
  interactive `settings.json` model choice.

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

Top-level max_build_passes, max_review_passes, and max_repair_rounds are
cumulative PROGRAM envelopes. They are not per-checkpoint defaults. A declared
global repair allowance is invalid if the global build/review caps cannot
execute one initial pass per checkpoint plus those repairs.

For a long unattended PROGRAM, the normal high-autonomy choice is to set the
global pass/repair envelopes to the sums of the checkpoint-local envelopes
(subject to the v3 absolute ceiling), unless the operator intentionally wants
a tighter whole-program throttle.

risk_budget.max_pass_runtime_seconds is enforced for each semantic worker.
A positive supervisor --timeout-seconds is only a narrowing override.
