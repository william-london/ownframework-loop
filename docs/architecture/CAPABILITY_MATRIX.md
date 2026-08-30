# Adapter Capability Matrix

| Capability | Claude Code | Generic CLI contract | Codex |
| --- | --- | --- | --- |
| Protocol compatible | Yes | Yes | Yes |
| Core/runtime owner | No | No | No |
| Durable scheduler owner | No | No | No |
| Semantic runner registered/live | Yes | Host-defined | Not yet |
| Live verified | Yes | N/A abstract contract | No |
| Hardened unattended boundary | Yes | Host-defined | No |
| Native plugin/skills | Plugin + skills | Not required | Agent Skills |
| Native hooks/interception | Yes | Not required | No equivalent claim |
| Exact-SHA review contract | Yes via core | Required | Required |
| Human promotion boundary | Yes | Required | Required |

The core/runtime/supervisor columns are deliberately absent: those capabilities
belong to OwnFramework Loop itself and are shared by every adapter.

Claude is the first production runner, not the reference identity that new
adapters should copy. New adapters start from the vendor-neutral contract and
add only host-specific surfaces they can actually prove.
