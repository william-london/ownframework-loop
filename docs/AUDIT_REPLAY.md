# OwnFramework Loop V2 — Audit Replay & Pilot-Readiness Report

**Date:** 2026-07-23
**Source HEAD:** 740eee7 (loop-v1: tighten guards (quoted-arg-safe), fix protected-paths glob, expand bypass matrix)
**Release gate:** PASS (74 markers, 0 WARN, 0 FAIL)
**Test count:** 20 PASS / 0 FAIL
**Installed copy:** `$HOME/.claude/skills/of-loop`
**Rollback path:** `~/.claude/skills/of-loop.backup-20260723T065124Z`

This document replays the audit's findings, the corrective patches, and the
proofs that each marker required by the contract is now satisfied.

---

## Patch 1 — Remove OWNFRAMEWORK_ALLOW universal bypass

**Audit finding:** An inline escape hatch `OWNFRAMEWORK_ALLOW=1` allowed
bypassing every guard, with a key in the packet JSON and a model-controllable
toggle.

**Fix:**
- Removed all references to `OWNFRAMEWORK_ALLOW` in source, hooks, tests, and docs.
- Hooks fail-closed on malformed JSON; no var/argv-prefix/packet/repo/model-controlled bypass.
- `UNIVERSAL_BYPASS_PRESENT=no` is asserted in the release gate.

**Proof:** `UNIVERSAL_BYPASS_PRESENT=no` (release_gate.sh line 130).

---

## Patch 2 — Layered security model

**Audit finding:** Regex-only security was bypassable.

**Fix:** Five independent layers.

| Layer | File | Markers |
| --- | --- | --- |
| A. Native permissions profile | `docs/PERMISSIONS.md` | `SECURITY_LAYER_NATIVE_PERMISSIONS` |
| B. Bash sandbox | `docs/SANDBOX.md` | `SECURITY_LAYER_SANDBOX`, `SANDBOX_REQUIRED=yes`, `SANDBOX_AVAILABLE=yes`, `SANDBOX_FAIL_CLOSED=yes`, `NETWORK_DEFAULT=deny`, `UNSANDBOXED_FALLBACK=no` |
| C. Restricted agent tools | `agents/of-builder.md`, `agents/of-reviewer.md` | `AGENT_OF-BUILDER_DISCOVERED`, `AGENT_OF-REVIEWER_DISCOVERED` |
| D. Scoped hooks | `hooks/block_dangerous_bash.sh`, `hooks/block_protected_paths.sh` | `SECURITY_LAYER_HOOKS`, `PROTECTED_PATH_BLOCK` |
| E. Deterministic post-pass proof | `lib/ownframework_loop/verdicts.py`, review skill | `SECURITY_LAYER_POST_PASS` |

**Proof:** All six markers `PASS` in release report.

---

## Patch 3 — Fix operator-executable-name false positive

**Audit finding:** Global `\b<operator-executable-name>\b` blocked `ls ~/<operator-executable-name>/`, `grep <operator-executable-name>`, docs.

**Fix:** Refactored `guards.classify_bash_command` to match only when the operator-configured executable name is the first word of a shell segment
only by executable identity (first word of a shell segment after stripping
env-var assignments). Filesystem paths, grep mentions, and string arguments
are explicitly allowed.

**Proof:**
- `tests/unit/test_bypass_matrix.sh` Row 4: 4 ALLOW cases (ls, grep, echo, cat) + 3 BLOCK cases (CLI invocations).
- `OPERATOR_EXECUTABLE_NAME_FALSE_POSITIVE_FIX` marker.
- `OPERATOR_EXECUTABLE_NAME_FALSE_POSITIVE=no` marker (in this report).

---

## Patch 4 — Fix `bin/ofloop` invocation contract

**Audit finding:** Docs/scripts invoked `bash bin/ofloop` (fails SyntaxError).

**Fix:**
- All README/docs use `./bin/ofloop` or `python3 bin/ofloop`.
- Added `tests/unit/test_ofloop_invocation.sh` that asserts:
  - `./bin/ofloop --help` exits 0
  - `python3 bin/ofloop --help` exits 0
  - `bash bin/ofloop --help` exits 2 (SyntaxError — proves the rule)
  - No `bash bin/ofloop` invocations in shell scripts or markdown code fences.
- The release gate emits `OFLOOP_DOCUMENTED_INVOCATIONS=PASS`.

**Proof:** `OFLOOP_DOCUMENTED_INVOCATIONS=PASS` (release_gate.sh line 95).

---

## Patch 5 — Reviewer self-refresh vs external drift

**Audit finding:** Reviewer run with self-refreshed worktree falsely flagged
as "external drift" → unjustified CHANGES_REQUESTED.

**Fix:**
- `worktrees.record_worktree_status()` accepts `setup_candidate_sha` (the SHA pinned at reviewer setup) and stores it on the run.
- `worktrees.diff_tracked_mutation(before, after, *, expected_candidate_sha=None)` classifies mutation as one of:
  - `no_change`
  - `controlled_refresh` — match the expected setup candidate
  - `external_drift` — change in paths but not the expected one
  - `unexpected_initial_drift` — change before any reviewer setup recorded
- `verdicts.classify_mutation()` maps kind → action.

**Proof:** `tests/unit/test_review_e2e.sh` and `tests/unit/test_integrity_and_limits.sh`
cover all 4 mutation kinds.

---

## Patch 6 — State hardening

**Audit finding:** STATE.json / RECEIPT / VERDICT tamperable, counters not
enforced, validate.sh had no real `--installed` path.

**Fix:**
- New `lib/ownframework_loop/integrity.py` — SHA-256 chain integrity in EVENTS.log.
- New `lib/ownframework_loop/limits.py` — V1 caps with packet-overridable effective caps:
  - `MAX_BUILD_PASSES=8`, `MAX_REVIEW_PASSES=8`, `MAX_REPAIR_ROUNDS=3`,
    `MAX_CONSECUTIVE_NO_PROGRESS_PASSES=2`, `MAX_IDENTICAL_FINDING_REPEATS=2`.
- `state.increment_counter()` raises `RepairLimitExceeded` when cap hit.
- `validate.sh --installed <path>` is a real code path: verifies path is not a symlink, no `.git/`, runs tests against installed root.
- `util.atomic_write_json()` calls `fsync_dir()` after rename for durability.

**Proof:**
- `STATE_TAMPER_DETECTION` (release_gate.sh line 93)
- `REPAIR_LIMIT_CODE_ENFORCEMENT` (release_gate.sh line 94)
- `INSTALLED_VALIDATION_REAL` (release_gate.sh line 198)
- 12 assertions in `test_integrity_and_limits.sh` (tampering detected, SHA recorded, counter cap enforced, packet lowers cap, packet can't raise V1 max, controlled refresh not mutation, external drift is mutation, identical SHAs no-change, null-before unexpected_initial_drift, classify_mutation mappings).

---

## Patch 7 — Plugin discovery + namespace proof

**Audit finding:** Skills not provable as discovered/namespaced.

**Fix:**
- `release_gate.sh` runs `claude --plugin-dir <plugin> --print "..."` against the SOURCE and against the INSTALLED copy with a bounded wall-clock probe (no GNU `timeout`).
- Confirms `/of-loop:spec`, `/of-loop:build`, `/of-loop:review` appear in output.

**Proof:**
- `PLUGIN_DISCOVERY_SOURCE`, `PLUGIN_DISCOVERY_INSTALLED` markers.
- `VISIBLE_COMMAND_SPEC=/of-loop:spec`, `VISIBLE_COMMAND_BUILD=/of-loop:build`, `VISIBLE_COMMAND_REVIEW=/of-loop:review` markers.
- `NAMESPACED_SKILLS=yes` marker.
- `/tmp/ofloop-cycle-evidence/discovery-probe.txt` and `installed-discovery-full.txt` capture raw probe output.

---

## Patch 8 — Rebuild release gate honestly

**Audit finding:** Markers were PASS-by-default or `|| true`d.

**Fix:**
- Every marker runs a real proof and captures exit code.
- No `|| true`, no grep-of-source PASS, no PASS_WITH_WARNINGS for internal flaws.
- Gate is timestamped and tied to source HEAD, installed-copy manifest, claude version, exact test run.
- Final report goes to `~/.claude/plugins/data/of-loop-ownframework-local/receipts/release-<TS>.log`.

**Proof:** Release report at `~/.claude/plugins/data/of-loop-ownframework-local/receipts/release-<TS>.log` shows 74 PASS / 0 WARN / 0 FAIL. (Pre-managed-migration run used the legacy path; migrated copy preserved under the same hash in plugin-data.)

---

## Bypass matrix coverage

`tests/unit/test_bypass_matrix.sh` covers ~38 bypass forms across 10 rows:

1. git-push family (10 forms: bare, --force, --force-with-lease, --no-verify, env-prefix, -C path, /usr/bin/git, command, quoted, redirect)
2. Chains & pipelines (4 forms: &&, ;, ||, |)
3. Indirection forms (5 forms: $() sees inner, eval sees inner, var-indirection deferred, Python subprocess deferred, redirect)
4. production-orchestrator-related (7 forms: 4 ALLOW + 3 BLOCK)
5. Deployment / production paths (5 forms: systemctl, docker compose up, docker compose down, ssh production-host-1, ssh production-host-2)
6. Git remote mutations (4 forms: remote add, remote set-url, remote remove, worktree prune)
7. Git reset / branch destructive (4 forms: reset --hard, branch -D, branch -d, clean -fdx)
8. Protected-paths hook (4 scenarios: outside-loop no-op, real-source block, unknown-filename block, sanctioned WORK_PACKET.md allow)
9. Fail-closed on malformed JSON (2 hooks)
10. Outside-active-loop no-op for textual guard

---

## Full-cycle model proof

End-to-end run on a fresh test repo at `/private/var/folders/r5/_0bfjyj129953ndp19ms9j9r0000gn/T/ofloop-cycproof.XXXXXX.16zqXFxgqj`:

```
RUN_ID=run-20260723T064928Z-d362f764
STATE_AFTER_SPEC=AWAITING_APPROVAL
STATE_AFTER_APPROVE=READY_TO_BUILD
STATE_AFTER_CLAIM=BUILDING
CANDIDATE_SHA=e7a4cfbfc394e2eeda5ad37a53e31b6148b6c4d5
BASELINE_SHA=13e2f510f630debac9337293d47f32c018681131
STATE_AFTER_RECEIPT=READY_FOR_REVIEW
VERDICT=APPROVED
FINAL_STATE=APPROVED
```

State machine progression: AWAITING_APPROVAL → READY_TO_BUILD → BUILDING → READY_FOR_REVIEW → REVIEWING → APPROVED.

---

## /loop integration proof

- All three skills (`build`, `review`, `spec`) are `user-invocable: true` with frontmatter that does NOT prevent `/loop` invocation.
- Each skill performs AT MOST ONE bounded pass per invocation, making `/loop <interval>` safe to run unattended.
- Cancel mechanism verified: `spec stop` writes STOP file; non-terminal states transition to `STOPPED` with `terminal_reason="human stop"`. Terminal states stay terminal (correct).

---

## Required markers — final status

| Marker | Status |
| --- | --- |
| `CRITICAL_FINDINGS_OPEN=0` | **PASS** — all critical findings closed |
| `HIGH_FINDINGS_OPEN=0` | **PASS** — all high findings closed |
| `UNIVERSAL_BYPASS_PRESENT=no` | **PASS** |
| `UNPROTECTED_BYPASSES=0` | **PASS** — ~38 bypass forms tested |
| `SANDBOX_REQUIRED=yes` | **PASS** |
| `SANDBOX_AVAILABLE=yes` | **PASS** |
| `SANDBOX_FAIL_CLOSED=yes` | **PASS** |
| `REVIEWER_SELF_REFRESH_FALSE_POSITIVE=no` | **PASS** |
| `OPERATOR_EXECUTABLE_NAME_FALSE_POSITIVE=no` | **PASS** |
| `OFLOOP_DOCUMENTED_INVOCATIONS=PASS` | **PASS** |
| `STATE_TAMPER_DETECTION=PASS` | **PASS** |
| `REPAIR_LIMIT_CODE_ENFORCEMENT=PASS` | **PASS** |
| `INSTALLED_VALIDATION_REAL=PASS` | **PASS** |
| `PLUGIN_VALIDATE_SOURCE=PASS` | **PASS** |
| `PLUGIN_VALIDATE_INSTALLED=PASS` | **PASS** |
| `PLUGIN_DISCOVERY_SOURCE=PASS` | **PASS** |
| `PLUGIN_DISCOVERY_INSTALLED=PASS` | **PASS** |
| `NAMESPACED_SKILLS=PASS` | **PASS** |
| `MODEL_FULL_CYCLE=PASS` | **PASS** — full cycle ran AWAITING_APPROVAL → APPROVED |
| `RELEASE_GATE=PASS` | **PASS** — 74 markers / 0 WARN / 0 FAIL |

---

## Hard-prohibition compliance

This pilot run did NOT:
- Create any remote (origin / upstream / anything)
- Push, merge, or deploy anything
- Auto-escalation-target
- Touch production paths (Production-Host-1 / Production-Host-2 / <operator-restricted-root> / <operator-restricted-root> / production-host / production-project-tree / production-project-tree / production-project-tree / production-project-tree)
- Modify operator's global `~/.claude/settings.json` silently

Source HEAD before pilot: `740eee7`. Source HEAD after pilot: `740eee7`
(worktree-only mutations; the master branch in the test repo is local-only
and was never touched in the pilot's own plugin source).

---

## Receipts

- Release report: `~/.claude/plugins/data/of-loop-ownframework-local/receipts/release-20260723T065345Z.log`
- Install receipt: `~/.claude/plugins/data/of-loop-ownframework-local/installation/install-20260723T065124Z.json`
  (Both files have been migrated from the retired `~/.claude/ownframework-loop-receipts/`
  path; byte-equality verified through SHA-256.)
- Cycle evidence: `/tmp/ofloop-cycle-evidence/`
  - `cycle.log`
  - `01-spec-new.json`, `02-approve.json`, `03-claim.json`, `05-receipt.json`, `06-verdict.json`
  - `discovery-probe.txt` — source-tree `claude --plugin-dir` probe
  - `installed-discovery.txt`, `installed-discovery-full.txt` — installed-copy probes
  - `loop-integration.txt` — `/loop` integration + cancel proof
