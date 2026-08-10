# Security

OwnFramework Loop is an early public release. The state machine,
packet binding, exact-SHA review, and serialized transitions are
implemented and tested, but the project makes no claim of
guaranteed-correctness, guaranteed-safety, or guaranteed coverage
against arbitrary real-world inputs.

## Supported release posture

- The currently supported release line is **0.3.7**.
- Earlier release lines (0.2.x, 0.3.0–0.3.6) are preserved in the
  git history but are no longer receiving fixes.

## Reporting a vulnerability

Please report suspected vulnerabilities privately to:

**williamlondon@ownframework.com**

Please do **not** open a public GitHub issue for an undisclosed
vulnerability. Public disclosure should wait until a fix or
mitigation is in place.

When reporting, please include:

- A short description of the issue.
- The release line and commit SHA you observed it on.
- A minimal reproduction or steps to observe.
- Any relevant environment details (operating system, Python
  version, Claude Code version).

## Response posture

The project is maintained on a best-effort basis. We will
acknowledge new reports as time permits, but no formal response
SLA is committed. Critical defects that affect core invariants
(human approval binding, exact-SHA review, state serialization,
no autonomous push / merge / deploy) will be prioritized.

## Scope notes

The following are intentionally **out of scope** for security
reports:

- Hypothetical AI safety or autonomy claims about the workflow's
  *philosophy*. The project makes narrow, verifiable claims about
  its code behaviour, not broad claims about autonomous AI.
- Behaviour of third-party plugins, third-party hooks, or
  third-party Claude Code configuration outside this repository.
- Behaviour of customer code that the loop is asked to work on.
