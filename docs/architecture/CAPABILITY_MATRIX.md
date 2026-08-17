# Adapter capability matrix

| Capability | Claude Code | Generic CLI host | Codex |
|---|---|---|---|
| Maturity | Stable / reference | Portable baseline | Experimental |
| Shared work-packet protocol | Yes | Yes | Yes |
| Human TTY approval gate | Core-owned | Core-owned | Core-owned |
| Exact candidate SHA | Core-owned | Core-owned | Core-owned |
| Exact-SHA review contract | Yes | Yes | Yes |
| Core-owned repair budget | Yes | Yes | Yes |
| Agent Skills | Yes | Optional / not required | Yes |
| Native custom agents/subagents | Yes | Not assumed | Not claimed |
| Native deterministic hooks | Yes | Not assumed | Not claimed |
| Hard command interception | Yes | Not assumed | Not claimed |
| Built-in/session loop integration | Yes | Not assumed | Not claimed |
| Managed OwnFramework installer | Yes | Source checkout | Yes, experimental adapter installer |
| Protocol compatible | Yes | Yes | Yes |
| Hardened | Yes | No | No |
| Live host verification | Yes | Not applicable to abstract host | Pending real Codex proof |

The **Generic CLI host** column is the portability floor, not a claim that every agent product behaves identically. Any coding-agent host that can operate a Git checkout and invoke supported local `ofloop` commands can integrate at this layer. Host-native plugins, skills, hooks, subagents, and loop primitives are optional accelerators.

Agent-agnostic core does not imply identical host capabilities. An adapter may be protocol-compatible without being hardened to the same level as the Claude Code reference adapter.

See [`PORTABILITY_MODEL.md`](PORTABILITY_MODEL.md) for the three compatibility layers.
