# Templates

These files are maintained examples for OwnFramework Loop's public protocol surfaces.
They are not runtime state and do not become authority merely because they exist in a
checkout.

| Template | Purpose |
| --- | --- |
| `WORK_PACKET.md` | Human-readable work-packet scaffold with machine-validated metadata. |
| `BUILD_AGENT_RESULT.template.json` | Semantic BUILD result example. |
| `REVIEW_AGENT_ASSESSMENT.template.json` | Semantic REVIEW assessment example. |
| `repository-policy.example.json` | Machine-readable repository/operator policy example. |

Authoritative schemas live under `../schemas/`. Runtime-created artifacts live in a
run's managed state and are written only through supported OwnFramework Loop paths.

Provider-specific directories such as `.claude/` are adapter surfaces, not portable
Loop policy authority. Host paths, credentials, daemon sockets, and privileged
commissioning evidence likewise do not belong in these templates.
