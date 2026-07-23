# Changelog

All notable changes to OwnFramework Loop are documented here.

## v0.2.0 — 2026-07-23

Two-loop engineering for specification, isolated building, exact-SHA
review, repair, and proof. V2 elevates the determinism of the V1 pilot
on fourteen patches.

### Patch summary

1. **Externalized approval** — `APPROVAL.json` is a separate artifact
   at `.ownframework-loop/<run-id>/APPROVAL.json`, never embedded in
   the packet. Packets remain pure markdown + JSON. The packet SHA is
   bound to the approval via `packet_sha256`; `confirmation_token`
   is derived from the packet SHA as `CONFIRM-OF-LOOP-<8hex>`.
2. **Deterministic build finalizer** — `ofloop build finalize` is
   the only entity that writes `BUILD_RECEIPT.json`. The model
   cannot influence the verifier verdict on any of the 22
   independent checks (approval validation, worktree identity,
   exact candidate branch, candidate SHA ancestry, baseline immutability,
   scope, hard-secret scan, validation commands, no-progress, repair
   limits, atomic write, event append, next-state derivation).
3. **Deterministic review finalizer** — `ofloop review finalize` is
   the only entity that writes `REVIEW_VERDICT.json`. The reviewer
   agent's `recommended_verdict` is advisory only; the finalizer
   validates the exact candidate SHA, scope, and budget against the
   packet, then derives verdict from independent checks.
4. **Artifact integrity & event consistency** — every state-changing
   operation appends a typed event to `EVENTS.log`; `assert_artifacts_intact`
   verifies byte-level SHA equality for packet, approval, receipt,
   verdict, and state; external mutation registers as an integrity
   event.
5. **Exact-run hook binding** — hooks refuse to act on tools when
   the `STATE.json` of the active run is absent or stale. The hook
   walks up to find the run directory and refuses out-of-scope writes
   silently during the active loop.
6. **Broad tools + external-action guard** — the textual guard
   blocks `git push`/`git remote *`/`docker compose`/`systemctl`
   and SSH access to Horus / FireLove. Detection covers bare forms,
   chains (`&&`, `;`, `||`), pipelines (`|`), `$(...)` and `eval`,
   and single-line redirects. Variable indirection is deferred to
   the sandbox + post-pass review layers. Hermes, Kanban, Linear,
   Windmill, and SQLite are not added.
7. **Safe secret handling** — secret scanner distinguishes
   `HARD_PATTERNS` (block: AWS keys, private keys, high-confidence
   tokens) from `HEURISTIC_PATTERNS` (reviewable warning, recorded
   in receipt). Hard block triggers pre-receipt refusal
   `OF_LOOP_BUILD_FINALIZE_REFUSED`. Receipt findings are redacted
   to `redacted_prefix` + SHA-256; literal values never reach
   `EVENTS.log`, `BUILD_RECEIPT.json`, or `REVIEW_VERDICT.json`.
8. **Packet-approved sensitive paths** — sensitive paths must be
   declared in `packet.sensitive_paths` with `sensitive_path_reason`.
   The finalizer permits writes to elevated paths only when the
   packet lists them; protected paths (e.g., `.ownframework-loop/`)
   are always forbidden.
9. **Work-class-aware budgets with absolute ceiling** — each packet
   declares a `risk_budget` sub-key. The hard caps are
   `max_files_changed ≤ 500`, `max_diff_lines ≤ 30000`,
   `max_repair_rounds ≤ 12`. The V1 V1 cap floor is preserved
   (e.g., repair rounds 3 for BUG work, default). A work-class table
   provides sensible defaults per work class.
10. **Branch/remote neutrality** — `git worktree add` is the only
    isolation mechanism. The loop does not create remotes, never
    pushes, never merges, never deploys. The push/merge/deploy
    authority stays with the human. The candidate branch is
    always `factory/candidate/<run-id>`.
11. **Marker/installation consistency** — `install.sh` is idempotent
    (backs up existing copy, verifies SHA-256 of the source before
    copy); `uninstall.sh` is reversible to the backup if one exists.
    Plugin metadata in `.claude-plugin/plugin.json` references
    version 0.2.0.
12. **Skill/agent responsibility rewrite** — three skills
    (`spec`, `build`, `review`) and two independent agent types
    (`of-builder`, `of-reviewer`). Skills describe contracts;
    agents execute within them. Neither agent has WebFetch,
    WebSearch, Write, or push authority.
13. **Cost efficiency** — the textual guard pre-filters obviously
    forbidden commands before sandbox invocation. The finalizer
    runs validations bounded by per-validation timeout
    (`max_runtime_seconds`). Branch/remote neutrality avoids
    cost-incurring operations.
14. **Compatibility migration** — V1 packet fields are mapped to V2
    packet fields at the CLI boundary; legacy approval-flow
    commands (`apply_approval`, `write_approved_packet`,
    `build write-receipt`) are removed; CLI commands
    (`spec new|approve|status|inspect-legacy`, `build claim|finalize`,
    `review finalize`) are deterministic.

### Deterministic tests

- 73 tests across `tests/unit/test_trust_*.sh` covering approval,
  build, review, secrets, packet hashing, integrity, transitions,
  worktree lifecycle, bypass matrix, CLI E2E, and capability
  matrix.
- Capability matrix runs 4 end-to-end missions (M1 ordinary bug
  fix, M2 repository doctrine change, M3 web research, M4
  malicious proof with hard secret) on disposable repos.

### Release gate

`tests/run_all.sh` produces `OF_LOOP_RELEASE_GATE_RESULT=PASS` when
all 34 test files pass: trust (33 unit), capability matrix
(4 missions). One command — no test recursion.

## v0.1.4 — 2026-07-22

Recursion repair and gate containment.

- Removed reverse-orchestrator edge in
  `tests/unit/test_plugin_data_resolution.sh`: it no longer
  launched `release_gate.sh`. Receipts use the shared
  `ownframework_loop.plugin_data.write_receipt()` helper.
- `release_gate.sh` is now a thin wrapper around
  `ownframework_loop.release_gate_runtime`, which acquires an
  authoritative `fcntl.flock(LOCK_EX|LOCK_NB)` on a stamp file
  before any test invocation, so a second `release_gate.sh` run
  in a `worktree`-mounted repo cannot produce two parallel
  receipt writers.
