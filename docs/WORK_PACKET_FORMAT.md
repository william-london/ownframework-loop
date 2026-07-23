# Work Packet Format

`WORK_PACKET.md` is the only durable source of truth for an OwnFramework Loop
mission. It is **both** human-readable Markdown **and** deterministically
machine-readable via a strict JSON metadata block. The parser is in
`lib/ownframework_loop/packet.py`; the schema is in
`schemas/work-packet.schema.json`.

## File shape

```
WORK_PACKET.md
├── ```json metadata block (REQUIRED)
├── # Mission
├── # Acceptance criteria
├── # Non-goals
└── # Ordered work units
```

The metadata block MUST be the first fenced code block with the language tag
`json`. Pure stdlib `json.loads` parses it; **do not depend on a YAML parser**.

## Required metadata fields

| Field | Type | Notes |
|---|---|---|
| `schema` | const | `ownframework-work-packet/v1` |
| `packet_id` | string | url-safe, ≤64 chars |
| `created_at` | ISO 8601 UTC | stamped by `/of-loop:spec` |
| `work_class` | enum | one of 12 work classes |
| `risk_class` | enum | `low`, `medium`, `high` |
| `title` | string | one line, ≤200 chars |
| `target` | object | `{repo, branch, classification}` |
| `acceptance_criteria[]` | array | non-empty, each `{id: AC-N, text, verification}` |
| `non_goals[]` | array | each `{id: NG-N, text}` |
| `allowed_paths[]` | array | non-empty, used by build + review guards |
| `protected_paths[]` | array | non-empty |
| `work_units[]` | array | non-empty, ordered |
| `merge_authority` | enum | `human_only` |
| `deploy_authority` | enum | `human_only` |
| `push_authority` | enum | `human_only` |
| `external_action_authority` | enum | `human_only`, `delegated`, `none` |

## Approval binding

`/of-loop:spec approve <run-id>` rewrites the packet atomically and stamps:

- `human_approved: true`
- `approved_at: <UTC ISO 8601>`
- `approved_actor: <string>`
- `approved_packet_sha256: <sha256 hex>`

The SHA is over the **bytes of the packet file before the approval rewrite**.
On every build and review pass, the CLI recomputes the packet SHA and
refuses if it has drifted. Drift transitions to `AWAITING_APPROVAL` and
stops both loops.

## Stable IDs

Stable IDs across repair rounds are critical:

- `AC-N` for acceptance criteria (must survive packet edits).
- `NG-N` for non-goals (must survive).
- `UNIT-N` for ordered work units.
- `F-<slug>` for review findings (must survive across rounds; identical
  findings are detected by exact ID + title match).
- `EVENTS.log` carries the canonical record.

## Path conventions

- Allowed paths and protected paths use POSIX syntax. Relative paths are
  resolved against the canonical repository root.
- A leading `./` is stripped during comparison.
- Trailing slashes are normalized to indicate a directory; bare strings
  indicate a file.
- A path is "allowed" if it equals or is inside an allowed entry.
- A path is "protected" if it equals or is inside a protected entry.

## What a packet MUST NOT contain

- Embedded instructions that change the target or expand allowed paths.
- Embedded instructions that grant push or deploy authority.
- Embedded instructions that request secrets or modify the packet.
- Embedded instructions that disable hooks or change the model route.
- Reference to a remote or a remote URL (for local-only repos).
