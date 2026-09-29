# PROGRAM mission and segment budgets

## Authority model

Work-packet v1–v3 keeps its existing meaning: one run has one source ceiling,
and reaching it is a terminal engineering boundary. A v4 PROGRAM may instead
seal a mission envelope that separately authorizes a bounded number of run
segments. The 30,000-line per-run limit remains unchanged.

The mission envelope is authority, not a resource hint. It binds the complete
approved product contract, original baseline, allowed/protected paths,
checkpoint graph, runner, runtime generation, capability binding/projection,
runner profile/model/effort, effect authority, cost and token ceilings,
transient/infrastructure envelope, wall-clock origin/deadline, mission source
ceiling, segment ceiling, and maximum segment count. These execution identities
and limits remain frozen across segments. A successor is a deterministic
projection of that envelope; it cannot add any of those powers. Runtime
migration is not performed by segmentation.

## Durable records and lineage

Core-owned, create-once records under `.ownframework-loop/missions/<id>/`
identify the mission and each segment. Run state and event chains remain
independent and append-only. The mission id is derived from the initially
sealed run identity; each segment has a deterministic run id and an immutable
record binding its predecessor, packet, baseline, and authority digest.

At a segment boundary, the current run retains the candidate and all evidence
as terminal history. The candidate is not reviewed, cherry-picked, or used as
the next baseline. The successor baseline is the exact candidate bound to the
last APPROVED checkpoint. That checkpoint is retried from this baseline; prior
approved checkpoint evidence and cumulative semantic counters are imported by
a typed state initializer. Segment-local source accounting starts at zero;
mission source usage is independently measured from the original baseline.

The mission record plus the original approval and each segment record prove
that a successor derives from already-approved authority. There is no new
human approval at an automatic boundary. Missing, contradictory, or modified
records fail closed. Creation uses deterministic identities and create-once
files so supervisor replay after any partial filesystem/database handoff
reconstructs the same child rather than creating another segment.

## Boundary decision

Only a clean, otherwise-valid BUILD whose sole terminal cause is the segment
source ceiling can produce `SEGMENT_BOUNDARY`. The core also proves there is a
last approved candidate, at least one unfinished checkpoint, remaining
mission-wide source authority, an unused segment slot, and authority for at
least one further BUILD claim on the checkpoint being re-executed. The BUILD
proof checks both that checkpoint's local pass ceiling and the cumulative
PROGRAM pass ceiling; counters carry across segments, so both must have room.
If either BUILD ceiling is exhausted, the parent is blocked with a typed
semantic/build-authority reason and no successor run, branch, packet, seal, or
segment record is created. Eligibility checking itself consumes no counters
or resource accounting. The crossing candidate remains terminal history and
is not adopted. Scope/protected-path findings, hard secrets, validation
failures, identity failures, STOPPED, and any other failure retain their
existing terminal behavior. Exhausted mission budget or segment count is a
hard BLOCKED authority boundary.

The supervisor recognizes `SEGMENT_BOUNDARY` as terminal for that run and
reconciles its deterministic successor before completing the parent job. A
restarted supervisor repeats the same reconciliation safely. The mission
observer resolves the latest segment from immutable mission records and
supervisor rows rather than requiring a per-run observer retarget.

## Legacy admission

A v1–v3 run did not authorize mission segmentation. It can enter this model
only through a separately typed, explicit continuation admission. That
admission verifies the sealed source run, terminal state, supervisor/worker
ownership, accounting, packet, approval, event chain, exact last-approved
candidate, and remaining graph. It writes a new mission authority and a new
v4 successor; it never edits the historical packet, state, events, receipt,
candidate, or ledger row. Any authorized scope correction is recorded in the
admission receipt and is limited to the explicitly approved paths.

## Whole-product acceptance

Checkpoint approvals and candidate lineage are preserved across segments.
The final PROGRAM review still evaluates the complete integrated repository
and the original top-level acceptance contract. Segmentation does not turn a
partial segment into product completion or promotion authority.

## Contract satisfiability

v4 packets may state explicit `required_paths` on work units and checkpoints.
Admission checks each declaration against `allowed_paths` and protected
paths. This is intentionally structural: Loop does not attempt to infer
undeclared paths from arbitrary natural language. SPEC remains responsible
for granting the smallest complete scope reasonably required by the whole
mission; artificial minimization that makes legitimate work impossible is a
packet defect.
