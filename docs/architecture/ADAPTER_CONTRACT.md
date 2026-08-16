# OwnFramework Loop adapter contract

OwnFramework Loop is a human-gated engineering protocol. An adapter gives an AI coding-agent host a user-facing way to participate; it does not own protocol authority.

## Core authority

The deterministic core owns work-packet parsing/validation, human approval binding, lifecycle transitions, locks, risk/scope/runtime/repair budgets, isolated worktree/candidate handling, candidate Git SHA recording, exact-SHA verdict binding, events/receipts, terminal semantics, and the promotion boundary.

Adapters use supported `ofloop` interfaces for transitions. They must not directly author or patch `STATE.json`, `APPROVAL.json`, `REVIEW_VERDICT.json`, lock files, or event logs.

## Adapter operations

- **SPEC** — help the human turn a mission into a packet and surface the human approval command.
- **BUILD** — perform one bounded engineering pass and hand the candidate to the core.
- **REVIEW** — inspect the exact candidate Git SHA and return a verdict through the supported core path.
- **STATUS** — display core-owned run state/evidence.

Approval is intentionally not an adapter capability. The portable core requires an interactive TTY confirmation through the human-facing CLI; hardened adapters must additionally block the agent itself from invoking that approval command. TTY presence alone is not represented as an OS-level proof of human identity.

## Capability declaration

Each adapter declares: `adapter_id`, `display_name`, `maturity`, `agent_family`, skill/spec/build/review support, native hooks/subagents/session looping/hard-command interception, installation mode, `protocol_compatible`, `hardened`, and `live_verified`.

`protocol_compatible=yes` means the adapter participates in the shared packet/state/SHA/verdict protocol. `hardened=yes` is stronger: the host exposes deterministic enforcement primitives sufficient for its declared hard rails. Do not infer one from the other.

## Maturity

- **stable** — documented surface, deterministic conformance, live host verification, and maintained compatibility.
- **experimental** — real adapter contract, but one or more live-host or hard-enforcement guarantees remain weaker or unproven.
- **planned** — design intent only; not supported.

Claude Code is stable/reference. Codex begins experimental. Core modules must not import or require either vendor runtime.
