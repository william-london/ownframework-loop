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
field optional for compatibility. `default` means no Loop model pin: use the
commissioned runner environment's effective model selection or provider
default, never interactive host-settings inheritance. Packet `network_read_allowlist` is only
the packet-specific portion of read authority; capability contracts may add
their exact required read hosts.
The effective union and runner-profile identity are sealed into the immutable
run-level capability binding before provider execution.

If preflight fails, the adapter must report the unavailable capability and stop
or revise the unstarted specification. It must never compensate by reopening
HOME, injecting host paths, weakening the sandbox, or inventing Docker/socket
authority. Privileged capabilities are available only after explicit
operator-owned canary commissioning.

## Pre-v1 PROGRAM validation-scope closure

The Taskbox source-isolated semantic certification against Loop
`4a39633e564c81358268f06bb3c73a1b7b53b5f8` exposed one avoidable planning
symptom: a validation that belonged to a later checkpoint had been authored in
top-level `required_validation`, so the earlier checkpoint had to satisfy a
future condition.

The exact historical packet/adapter provenance is no longer available, so this
document does not invent a producer. Current source at that exact Loop SHA
already states the correct rule in both shipped SPEC adapters:

- top-level `required_validation` is a global gate and must be satisfiable from
  the first checkpoint onward;
- a known later-only validation belongs in the owning checkpoint's
  `required_validation` (and later checkpoints when continuous proof is
  intended);
- the rule is part of the PROGRAM readiness contract before enqueue.

Arbitrary shell-command chronology is semantic. Deterministic core code must
not pretend it can infer whether an arbitrary command becomes meaningful only
at CP-N; doing so would create false refusals and operator friction. The
correct owner is therefore the semantic SPEC-authoring boundary, while the
core continues to enforce every mechanically knowable packet invariant before
durable enqueue.

`tests/test_run_adapter_conformance.sh` pins this contract across both
`skills/spec/SKILL.md` and `.agents/skills/of-loop-spec/SKILL.md`. This is a
static contract test deliberately: there is no sound behavioral validator for
arbitrary command semantics. Removing or drifting the PROGRAM validation-scope
rule from either shipped adapter now fails deterministic validation.

Closure classification:

```text
B-SPEC-VALIDATION-SCOPE=REJECTED_AS_NOT_SOURCE_DEFECT
HISTORICAL_ROOT_OWNER=UNPROVEN_ARTIFACTS_UNAVAILABLE
CURRENT_SOURCE_OWNER=semantic SPEC-authoring boundary
CORE_STATIC_SHELL_SEMANTIC_INFERENCE=not_added
OPERATOR_CEREMONY_ADDED=no
```

This closure does not alter the historical Taskbox certification facts, does
not claim that the missing packet has been reconstructed, and does not weaken
fail-closed runtime behavior.
