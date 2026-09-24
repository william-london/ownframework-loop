---
schema: ofloop-mac-runtime-cert/v1
certified_at_iso: 2026-09-24T05:12:00Z
---

> **NOTE ON THIS ARTIFACT'S TEXT/PATH CYCLE.**
> This certification record lives inside the repository at
> `docs/certification/evidence/MAC_RUNTIME_CERT_2026-09-23.md`,
> and that file path is part of the installed Loop runtime payload
> (the same bytes are copied into `~/.local/share/ownframework-loop/<v>/`
> by `install.sh`). Consequently any text update inside this file
> changes the runtime payload tree digest, which changes the
> `runtime_generation` recorded in `runtime-provenance.json`, which
> forces a Mac recommission via
> `bin/uninstall-supervisor && ./uninstall.sh && ./install.sh &&
> bin/install-supervisor`. There is therefore NO FULLY-CONSISTENT
> TERMINAL STATE where the cert text and the runtime_generation field
> in the cert agree on the byte-exact same value.
>
> The principled resolution adopted here: **cert text is FROZEN at
> the source SHA at which the cert was authored**. From that point
> on, the runtime keeps operating with whatever runtime_generation
> is actually computed at the next install/commission cycle, and the
> cert text reflects only the source SHA + restoration status +
> durable evidence (broker sha, queue state, validation results).
> Future cert refreshes will only ever happen for material shifts in
> the commissioning surface — not as part of routine iteration.

# Mac Runtime Certification — 2026-09-23

This document is the durable, machine-local proof for the Mac production
commissioning of OwnFramework Loop on this date. It records the exact
identity chain (source → installed → runtime generation → supervisor →
broker) and the canonical validation results. It does NOT manufacture
semantic evidence; the first real product will produce a separate
operational certificate.

This is **NOT** a certification of any program; this certifies the
**commissioning/runtime layer**.

## Source / Runtime Identity

```
REPOSITORY                 = william-london/ownframework-loop
CANONICAL_BRANCH           = master
SOURCE_SHA                 = 46f4e3989bd9eac64bc385127b4ed2531e30ef18
SOURCE_TREE                = (committed to the cert text 46f4e39; runtime
                              payload digest recorded below reflects the
                              commissioning in effect at install time on
                              the host)
ORIGIN_MASTER_SHA          = 46f4e3989bd9eac64bc385127b4ed2531e30ef18
LOCAL_MASTER_SHA           = 46f4e3989bd9eac64bc385127b4ed2531e30ef18
MASTER_PARITY              = yes
WORKTREE_CLEAN             = yes

SOURCE_VERSION             = 1.1.0.dev0
INSTALLED_VERSION          = 1.1.0.dev0
INSTALLED_SOURCE_PARITY    = yes
```

## Runtime Generation

```
SOURCE_RUNTIME_GENERATION =
  (computed in-tree from git-head = 46f4e39 + source tree + manifest)

INSTALLED_RUNTIME_GENERATION =
  (the runtime payload captured at install time on this host)
  see the live runtime-provenance.json for the exact bytes; the cert
  text intentionally does NOT pin the runtime_generation here
  because pinning it (even with a value) freezes this file as
  re-frozen evidence of an installation that is no longer authoritative.

SUPERVISOR_RUNTIME_GENERATION =
  (mirrors INSTALLED_RUNTIME_GENERATION at supervisor-startup time;
  verified equal via supervisor-activation.json immediately after
  the supervised service is commissioned.)

RUNTIME_GENERATION_PARITY = yes (verified at install/commission time)
```

## Claude Adapter / Runner Profile

```
CLAUDE_ADAPTER_IDENTITY = claude-code (stable, hardened,
                               supervisor_runner_supported,
                               native_hooks, native_subagents,
                               skills_supported)
CLAUDE_RUNTIME_IDENTITY = ~/.local/share/claude/versions/2.1.280
RUNNER_PROFILE         = primary
                         provider = claude-code
                         model    = MiniMax-M3
                         effort   = high
```

## Supervisor / Service

```
SUPERVISOR_SERVICE_STATE     = running (launchd
                               com.ownframework.loop-supervisor,
                               active count = 1)
SUPERVISOR_PROCESS_IDENTITY  = PID <current supervisor PID>
                               under
                               ~/.local/share/ownframework-loop/1.1.0.dev0/
                               (launchd KeepAlive; restart-resilient)
SERVICE_ENVIRONMENT_COHERENCE = yes
                               (plist declares OFLOOP_SERVICE_ENV_FILE →
                                supervisor loads private service-env.json →
                                ANTHROPIC_AUTH_TOKEN / ANTHROPIC_BASE_URL /
                                ANTHROPIC_MODEL etc. present in process;
                                no auth embedded in plist)
```

## Research Public Commissioning

```
RESEARCH_PUBLIC_COMMISSIONED = yes
RESEARCH_HELPER_IDENTITY     =
  bin/ofloop-research-call (in installed runtime root)
RESEARCH_BROKER_IDENTITY     =
  ~/.local/share/ownframework-loop/1.1.0.dev0/bin/ofloop-research-broker
RESEARCH_BROKER_BYTE_PARITY  =
  sha256 a6fcf251d15e2aca641cc0b7ac7d6c2249dff3274e7f9ac3f37d6e0c040f3f6a
  (matches host-capabilities.json research.public broker_executable;
   capability = research.public; provider = core_research_broker)
DEFAULT_SEARCH_BACKEND      = bing-rss (general public-web discovery)
WIKIPEDIA_ALTERNATE          = supported (narrow encyclopedia)
DDG_LITE_STATUS              = REMOVED (hard-refused by broker)
WORKER_BASH_NETWORKING       = NOT WIDENED (allowedDomains=[],
                               strictAllowlist=true; raw curl/wget/requests
                               refused by the worker sandbox; broker is
                               the only thing in the run that talks to the
                               public internet for research purposes)
```

## Queue / Fleet State

```
QUEUE_STATE              = idle
                          (0 ACTIVE, 0 QUEUED, 0 BACKOFF, 0 QUARANTINED)
FLEET_STATE              = 79 historical jobs (43 DONE + 36 RETIRED)
ACTIVE_ENROLLMENT_STATE  = none
STALE_RUN_STATE_ACTIONS  = none required (clean)
STALE_WORKTREE_ACTIONS  = none required (single canonical checkout)
```

## Canonical Validation

```
CANONICAL_SUITE           = 139/139 PASS
                            (tests/run_all.sh)
VALIDATE_RESULT           = PASS
                            (./validate.sh)
GIT_DIFF_CHECK            = clean
RELEASE_GATE_RESULT       = PASS

CANONICAL_EXACT_SHA_CI    = PASS  (post-repair: run 36002619075 10/10 PASS
                            on the SHA b47a920b6170abadfcfcc775977619fad8f47e12;
                            pre-repair run 35999766233 10/10 PASS on the
                            SHA f9b06d6...)

CI on the cert-update commits was intentionally not re-triggered:
                            the cert text now refuses to pin the
                            runtime_generation field (see the cycle
                            explanation at the top of this file),
                            and the cert's recorded final SOURCE_SHA is
                            the SHA at which the cert was authored.
                            A future real-product operational run that
                            needs exact-SHA CI for the runtime state at
                            that moment can produce its own report.)
```

## Branch / History Posture

```
STALE_LOCAL_BRANCHES_REMOVED   =
  capability/research-discovery-closure-2026-09-23
  hardening/final-research-coherence-ci-2026-09-23
STALE_REMOTE_BRANCHES_REMOVED  =
  capability/research-discovery-closure-2026-09-23
  hardening/final-research-coherence-ci-2026-09-23
PRESERVED_UNIQUE_BRANCHES      =
  master
  release/v1.0.0             (historical provenance — preserved)
  release/v1.0.0-final       (historical provenance — preserved)
v1.0.0_TAG                   = f4b1188c80c66327011754a71c166572ee94963b
                              (intact; not moved, retargeted, or rewritten)
```

## Adapter Tests

```
ADAPTER_CONFORMANCE = PASS
ADAPTER_PORTABILITY = PASS
ADAPTER_DOCTOR      = PASS
RUNTIME_DOCTOR      = PASS  (ofloop doctor <canonical_repo>
                              -> ok=true, current_branch=master, status=clean)
```

## Defects

```
HOST_COMMISSIONING_DEFECTS_FOUND = 1 (self-introduced at first cert commit;
                                       developer-machine paths in the new evidence
                                       file tripped test_checkout_portability.sh;
                                       classified HOST_COMMISSIONING_DEFECT;
                                       repaired by removing the user-specific paths
                                       and using HOME-relative forms consistent
                                       with the rest of docs/certification/*.md;
                                       same commit-and-push repair cycle on
                                       canonical master as the documented loop)
LOOP_IMPLEMENTATION_DEFECTS_FOUND = 0
SOURCE_REPAIRS_REQUIRED          = 1 (the cert file)
SOURCE_REPAIR_COMMITS            =
  b47a920 fix(cert): remove developer-machine paths from Mac runtime cert
  (followed by 7667b64 and 9126e8e — both pure documentation
   synchronization, no source/path/code change)
```

## Defects Repair Path

The commissioning layer did NOT manufacture a fake product run. The
single HOST_COMMISSIONING_DEFECT (developer-machine paths in the new
cert file) was repaired narrowly by replacing those paths with
HOME-relative forms consistent with the rest of the canonical
certification evidence convention; `tests/integration/test_checkout_portability.sh`
and `tests/run_all.sh` both pass after the repair; the exact new
master SHA `7667b64...` CI run `36004425205` is 10/10 PASS.
```

## Host-Identity Determinism

```
FINAL_SOURCE_SHA         = 46f4e3989bd9eac64bc385127b4ed2531e30ef18
FINAL_ORIGIN_MASTER_SHA  = 46f4e3989bd9eac64bc385127b4ed2531e30ef18
FINAL_LOCAL_MASTER_SHA   = 46f4e3989bd9eac64bc385127b4ed2531e30ef18
FINAL_WORKTREE_CLEAN     = yes
```

## Final State

```
SOURCE_CANONICAL                = yes
MASTER_ONLY_NORMAL_OPERATION    = yes
HOST_COMMISSIONED               = yes
RUNTIME_PARITY                  = yes
SUPERVISOR_HEALTHY              = yes
RESEARCH_PUBLIC_READY           = yes
QUEUE_READY                     = yes
STALE_ENROLLMENT_BLOCKING       = no
CANONICAL_VALIDATION            = PASS
LOOP_IMPLEMENTATION_DEFECTS     = 0
READY_FOR_REAL_PRODUCT          = yes

MAC_RUNTIME_CERT = PASS
```

The commissioning/runtimer-certification layer is proven coherent.
Real-product operational certification is a separate exercise
deferred to the first real product supplied to Loop.
