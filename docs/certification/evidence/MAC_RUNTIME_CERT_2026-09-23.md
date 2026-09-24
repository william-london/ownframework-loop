---
schema: ofloop-mac-runtime-cert/v1
certified_at_iso: 2026-09-24T04:34:00Z
---

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
SOURCE_SHA                 = 91b4adb4ef0acab06d186767fd65b25bfb1bf061
SOURCE_TREE                = 377def8191047000387953eb6aaeb82ee2647ada
ORIGIN_MASTER_SHA          = 91b4adb4ef0acab06d186767fd65b25bfb1bf061
LOCAL_MASTER_SHA           = 91b4adb4ef0acab06d186767fd65b25bfb1bf061
MASTER_PARITY              = yes
WORKTREE_CLEAN             = yes

SOURCE_VERSION             = 1.1.0.dev0
INSTALLED_VERSION          = 1.1.0.dev0
INSTALLED_SOURCE_PARITY    = yes
```

## Runtime Generation

```
SOURCE_RUNTIME_GENERATION =
  (computed in-tree from git-head + source tree + manifest)

INSTALLED_RUNTIME_GENERATION =
  ofloop-1.1.0.dev0@payload-8ff925c18ba5e9123f2c206f2ec1155daa572d3ce92ce329c21468f8a04ccb8b

SUPERVISOR_RUNTIME_GENERATION =
  ofloop-1.1.0.dev0@payload-8ff925c18ba5e9123f2c206f2ec1155daa572d3ce92ce329c21468f8a04ccb8b

RUNTIME_GENERATION_PARITY = yes
```

## Claude Adapter / Runner Profile

```
CLAUDE_ADAPTER_IDENTITY = claude-code (stable, hardened,
                               supervisor_runner_supported,
                               native_hooks, native_subagents,
                               skills_supported)
CLAUDE_RUNTIME_IDENTITY = /Users/mr.mrs.london/.local/share/claude/versions/2.1.280
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
SUPERVISOR_PROCESS_IDENTITY  = PID 9416 / launch-commissioned-supervisor.py
                               under
                               /Users/mr.mrs.london/.local/share/ownframework-loop/1.1.0.dev0/
                               (verified post-restart)
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
  /Users/mr.mrs.london/.local/share/ownframework-loop/1.1.0.dev0/bin/ofloop-research-broker
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
RUNTIME_DOCTOR      = PASS  (ofloop doctor /Users/mr.mrs.london/projects/ownframework-loop
                              -> ok=true, current_branch=master, status=clean)
```

## Defects

```
HOST_COMMISSIONING_DEFECTS_FOUND = 0
LOOP_IMPLEMENTATION_DEFECTS_FOUND = 0
SOURCE_REPAIRS_REQUIRED          = 0
SOURCE_REPAIR_COMMITS            = none
```

## Host-Identity Determinism

```
FINAL_SOURCE_SHA         = 91b4adb4ef0acab06d186767fd65b25bfb1bf061
FINAL_ORIGIN_MASTER_SHA  = 91b4adb4ef0acab06d186767fd65b25bfb1bf061
FINAL_LOCAL_MASTER_SHA   = 91b4adb4ef0acab06d186767fd65b25bfb1bf061
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
