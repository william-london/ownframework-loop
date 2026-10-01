# PROGRAM authority, source budgets, and segmentation

## One sealed mission

A v4 PROGRAM seals one immutable mission: product scope and acceptance,
baseline, checkpoint graph, allowed/protected paths, capabilities, effect
authority, runner/profile, runtime identity, cumulative semantic ceilings,
source ceilings, and a finite segment count. The supervisor executes that
graph autonomously through ordinary run segments. A segment boundary is not a
new SPEC or approval boundary; it is a deterministic projection of authority
already sealed in the mission.

v1-v3 remain single-run contracts with their original 30,000 diff-line
ceiling. Existing sealed v4 packets likewise retain their exact values and
policy. The consolidated model below is for future v4 authoring and does not
rewrite historical packet meaning.

## Source authority

There are three distinct values:

| Authority | Meaning | v4 platform maximum |
| --- | --- | ---: |
| Segment source maximum | Maximum source diff attributable to one run segment | 100,000 lines |
| Packet-sealed segment limit | The packet's `mission_budget.segment_max_diff_lines`, also mirrored by `risk_budget.max_diff_lines` | At most 100,000 |
| Mission-total source envelope | `mission_budget.mission_max_diff_lines`, measured from the original mission baseline across all segments | 480,000 lines |

SPEC selects a finite segment limit from the largest substantive checkpoint,
repository and product size, versioned test/QA assets, and bounded repair
headroom. It selects a separate finite mission total for the full expected
PROGRAM, plus a finite `max_segments` no greater than 16. It must not divide
the envelope into equal checkpoint chunks if that would strand a legitimate
large checkpoint. Routine operators do not tune these values.

`risk_budget.max_diff_lines` equals the sealed segment limit. The PROGRAM
global source ceiling equals the mission-total envelope. The deterministic
core enforces both against candidate-tree accounting. Automatic segmentation
may consume only remaining sealed authority. It never raises the segment
maximum, mission total, or segment count. Mission-total exhaustion is a hard
BLOCKED authority boundary and requires a new human SPEC if work is to continue.

## Ordinary automatic segmentation

When an otherwise valid BUILD exceeds only its segment source limit, the run
may finish at `SEGMENT_BOUNDARY` only if the mission has an approved candidate,
an unfinished checkpoint, remaining mission source authority, and an unused
segment slot. The next segment starts from the exact last APPROVED candidate;
the unreviewed crossing candidate remains historical evidence and is not
adopted. Approved-prefix evidence and cumulative semantic accounting are
imported with create-once authority. No human ceremony is required because no
mission authority changes.

Missing, contradictory, or altered segment/mission evidence fails closed.
Supervisor replay recreates or recognizes the same deterministic child and
cannot create a second segment, reset counters, or silently change its baseline.
`PROGRAM_FINAL` remains mandatory and reviews the assembled whole product,
including inherited checkpoints.

## Adaptive semantic allocation

New v4 packets explicitly seal the adaptive semantic policy by default:

```json
{
  "schema": "ownframework-loop-semantic-budget-policy/v1",
  "reclaim_approved_checkpoint_capacity": true,
  "use_cumulative_slack": true
}
```

Checkpoint-local BUILD, REVIEW, and REPAIR values are initial allocations.
After local exhaustion, the claim owner may borrow one claim at a time from
unused capacity of already-approved checkpoints or sealed cumulative slack.
The cumulative mission ceilings remain hard and never increase. Durable
allocation evidence binds each claim and is replay-idempotent. Unfinished
checkpoint reserves, no-progress and repeated-finding fuses, STOPPED refusal,
scope/identity checks, and the final-review reserve (BUILD 1, REPAIR 1, REVIEW
2) remain in force. Existing v4 packets without the explicit policy keep their
historical local-cap behavior; v1-v3 are unchanged.

SPEC chooses generous but finite cumulative BUILD/REVIEW/REPAIR authority for
substantive autonomous work. It does not ask the operator to tune routine
semantic-pass counts or encode provider pricing in deterministic core policy.
Cost and token ceilings remain disabled unless the human explicitly requests
them under the existing authority doctrine.

## Runtime identity is orthogonal

`program_mission_runtime.py` owns the mission runtime identity, append-only
migration chain, binding receipts, and workerless runtime-generation
maintenance. Runtime changes do not alter product or execution authority.
They preserve capabilities, capability projection, runner/profile/model/
effort, semantic ceilings, source ceilings, effect authority, and candidate
truth. A live semantic worker or nonterminal attempt prevents migration. At a
quiescent supported boundary, only a newly commissioned generation with an
exactly re-proven frozen capability and runner identity may be appended and
bound. Crash replay reuses the same immutable record and receipt. The runtime
module does not select checkpoints, expand budgets, author packets, or decide
reviews.

## Human authority boundary

The PROGRAM runtime cannot create new product authority. A larger mission
source total, more allowed paths, new capabilities/effects, changed acceptance,
or materially wider product scope belongs to a fresh human-originated SPEC.
There is no source-budget or blocked-semantic-budget continuation workflow in
normal v4 execution, and no special continuation receives a larger platform
maximum. Historical continuation records already persisted in repositories
remain verifiable as evidence; their existence does not preserve a creation
command or change the semantics of new packets.

Approval and terminal engineering success do not grant merge, push, deploy,
publish, payment, message, or other promotion authority. Promotion remains a
separate human decision.
