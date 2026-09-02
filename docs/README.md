# Documentation

OwnFramework Loop documentation is organized around current operator and protocol
surfaces on `master`.

## Start here

- [`GETTING_STARTED.md`](GETTING_STARTED.md) — install, commission, enqueue, and inspect a first bounded run.
- [`OPERATOR_RUNBOOK.md`](OPERATOR_RUNBOOK.md) — day-to-day operation and recovery.
- [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — common refusal and runtime diagnostics.

## Architecture and authority

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — high-level runtime structure.
- [`architecture/`](architecture/) — detailed portable architecture contracts.
- [`STATE_MACHINE.md`](STATE_MACHINE.md) — lifecycle and transition doctrine.
- [`SECURITY_MODEL.md`](SECURITY_MODEL.md) — trust, sandbox, and authority boundaries.
- [`PERMISSIONS.md`](PERMISSIONS.md) — permission model.
- [`SANDBOX.md`](SANDBOX.md) — semantic-worker containment.
- [`AUDIT_REPLAY.md`](AUDIT_REPLAY.md) — evidence and replay semantics.

## Extension and operations

- [`ADAPTER_DEVELOPMENT.md`](ADAPTER_DEVELOPMENT.md) — adapter contract and contribution guidance.
- [`ESCALATION.md`](ESCALATION.md) — operator escalation boundaries.

Historical release detail belongs in `../CHANGELOG.md`, `history/`, and GitHub Releases.
Current product claims belong in the active files above; retired execution paths should
not be preserved as current operating instructions.
