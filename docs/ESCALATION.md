# Escalation

When the deterministic finalizer cannot reach a verdict on its own (e.g. a
must-fix needs human judgment, an external system is required, or the
packet's `escalation_conditions` are met), the agent can request an
escalation and supply a reason. The finalizer records these on the
artifact.

The loop does **not** invoke any external human or external tool itself.
Escalation is a deterministic, in-artifact signal — the finalizer writes
the escalation fields and the verdict, and the operator decides what to
do manually.

See the packet schema for `escalation_conditions` (a list of strings
the agent may include to declare when escalation is appropriate).

The build receipt and review verdict carry:

- `escalation_recommended` (boolean)
- `escalation_reason` (string)

The finalizer sets these from the model-supplied agent result / assessment
(or, if absent, `false` / `None`). The model cannot influence the
finalizer's verdict on any of the deterministic checks; it can only
record its own recommended escalation.

## Operator workflow on escalation

1. Read the escalation reason from the receipt or verdict.
2. Decide whether to amend the packet, manually investigate, or override.
3. There is no automated hand-off. All escalation is operator-driven.
