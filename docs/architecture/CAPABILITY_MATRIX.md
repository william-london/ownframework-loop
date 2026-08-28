# Adapter capability matrix

| Capability | Claude Code | Generic CLI host | Codex |
|---|---|---|---|
| Maturity | Stable / reference | Portable baseline | Experimental |
| Shared work-packet protocol | Yes | Yes | Yes |
| Automatic first-start execution seal | Core-owned | Core-owned | Core-owned |
| Spec-time baseline SHA/branch binding | Core-owned | Core-owned | Core-owned |
| Exact candidate SHA | Core-owned | Core-owned | Core-owned |
| Exact-SHA review contract | Yes | Yes | Yes |
| Core-owned repair/checkpoint budgets | Yes | Yes | Yes |
| Exact-pass crash reconciliation | Core-owned | Core-owned | Core-owned |
| Agent Skills | Yes | Optional / not required | Yes |
| Native custom agents/subagents | Yes | Not assumed | Not claimed |
| Native deterministic hooks | Yes | Not assumed | Not claimed |
| Hard command interception | Yes | Not assumed | Not claimed |
| Built-in/session loop integration | Yes | Not assumed | Not claimed |
| Managed OwnFramework installer | Yes | Source checkout | Yes, experimental adapter installer |
| Protocol compatible | Yes | Yes | Yes |
| Hardened | Yes, tool-surface rails | No named-host claim | No |
| OS sandbox / arbitrary same-user containment | No | No | No |
| Live host verification | Yes | Not applicable to abstract host | Pending real Codex proof |

The **Generic CLI host** column is the portability floor, not a claim that every
agent product behaves identically. Any host that can operate a Git checkout and
invoke supported local `ofloop` commands can integrate at this layer.

`hardened` describes additional deterministic host rails. It does not mean that
a same-user process with arbitrary code execution is contained like an OS
sandbox.

See [`PORTABILITY_MODEL.md`](PORTABILITY_MODEL.md).
