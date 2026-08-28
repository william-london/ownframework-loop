# Security

OwnFramework Loop is an early public project. The state machine,
packet binding, exact-SHA review, serialized transitions, and adapter
conformance boundaries are implemented and tested, but the project makes
no claim of guaranteed correctness, guaranteed safety, or guaranteed
coverage against arbitrary real-world inputs.

## Supported release posture

- The currently supported release line is **0.5.1**.
- Earlier release lines (0.2.x, 0.3.x) are preserved in the
  git history but are no longer receiving fixes.

## Human-gate security boundary

OwnFramework Loop's human approval gate is a workflow/authority boundary,
not a privilege sandbox against arbitrary code already running with the same
OS user and unrestricted filesystem/shell access.

The portable core requires an interactive TTY confirmation and binds the
resulting approval artifact to the exact packet bytes/hash. Hardened adapters
add host-native enforcement on top of that. The Claude Code reference adapter,
for example, uses a PreToolUse Bash guard to refuse direct agent-issued
`ofloop spec approve` commands during the loop.

Those controls are meaningful, deterministic guardrails, but they do not turn
a same-user coding agent into an untrusted operating-system principal. A host
that does not expose equivalent enforcement is reported as less hardened in
the adapter capability matrix rather than being described as equally safe.

Similarly, `hardened=yes` in adapter metadata means the adapter has additional
mechanical host controls for its declared workflow rails. It does **not** mean
the adapter is an adversarial sandbox or can contain arbitrary malicious code
with the operator's own privileges.

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
  version, agent host and version, such as Claude Code or Codex).

## Response posture

The project is maintained on a best-effort basis. We will
acknowledge new reports as time permits, but no formal response
SLA is committed. Critical defects that affect core invariants
(human approval binding, exact-SHA review, state serialization,
repair/terminal limits, or the no autonomous push / merge / deploy
boundary) will be prioritized.

## Scope notes

The following are intentionally **out of scope** for security
reports:

- Hypothetical AI safety or autonomy claims about the workflow's
  *philosophy*. The project makes narrow, verifiable claims about
  its code behaviour, not broad claims about autonomous AI.
- Behaviour of third-party agent plugins, hooks, skills, or host
  configuration outside this repository.
- Behaviour of customer code that the loop is asked to work on.
- Claims that a same-user process with unrestricted shell/filesystem
  authority is not equivalent to an OS sandbox; the project explicitly
  documents that boundary above. Concrete bypasses of declared deterministic
  adapter/core checks are still in scope.
