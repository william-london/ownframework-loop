#!/usr/bin/env bash
# Public active-contract truth gate. Historical CHANGELOG/docs/history are excluded.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

ACTIVE_FILES=(
  README.md
  AGENTS.md
  SECURITY.md
  docs/ARCHITECTURE.md
  docs/STATE_MACHINE.md
  docs/SECURITY_MODEL.md
  docs/PERMISSIONS.md
  docs/SANDBOX.md
  docs/OPERATOR_RUNBOOK.md
  docs/WORK_PACKET_FORMAT.md
  docs/ADAPTER_DEVELOPMENT.md
  docs/architecture/README.md
  docs/architecture/CORE_INVARIANTS.md
  docs/architecture/ADAPTER_CONTRACT.md
  docs/architecture/PORTABILITY_MODEL.md
  docs/architecture/CAPABILITY_MATRIX.md
  docs/architecture/AGENT_SKILLS.md
  docs/architecture/SUPERVISOR_MODEL.md
  adapters/README.md
  adapters/generic-cli/README.md
  examples/README.md
  skills/spec/SKILL.md
  skills/build/SKILL.md
  skills/review/SKILL.md
  .agents/skills/of-loop-spec/SKILL.md
  .agents/skills/of-loop-build/SKILL.md
  .agents/skills/of-loop-review/SKILL.md
  .agents/skills/of-loop-status/SKILL.md
  schemas/approval.schema.json
  schemas/work-packet.schema.json
  schemas/work-packet-v3.schema.json
  schemas/state.schema.json
  schemas/state-v2.schema.json
  schemas/build-receipt.schema.json
  schemas/review-verdict.schema.json
  tests/canary/README.md
)

for f in "${ACTIVE_FILES[@]}"; do
  [[ -f "$ROOT_DIR/$f" ]] || fail "active contract file missing: $f"
done

# Stale mandatory-approval/product-contract phrases that must never return to
# active docs. Historical release notes remain outside this gate.
FORBIDDEN=(
  "Human-gated engineering protocol"
  "human-approved work packet"
  "human-operated approval gate"
  "interactive human approval and packet-hash binding"
  "Human TTY approval gate"
  "The loop cannot run until you approve it"
  "surface the human approval command"
  "The human performs approval from an interactive terminal"
  "interactive approval and packet-hash binding"
  "SPEC approval"
)

for phrase in "${FORBIDDEN[@]}"; do
  for f in "${ACTIVE_FILES[@]}"; do
    if grep -Fq "$phrase" "$ROOT_DIR/$f"; then
      fail "stale public-contract phrase in $f: $phrase"
    fi
  done
done
pass "active public contracts contain no stale mandatory-approval doctrine"

# Retired /loop was an execution clock. /of-loop:* remains a current adapter UX,
# so reject only the standalone /loop token across active current surfaces.
for f in "${ACTIVE_FILES[@]}"; do
  if grep -Eq '(^|[^A-Za-z0-9_-])/loop([[:space:]]|$)' "$ROOT_DIR/$f"; then
    fail "active public contract advertises retired standalone /loop scheduler: $f"
  fi
done
pass "active current contracts contain no retired standalone /loop scheduler"

STATE_DOC="$ROOT_DIR/docs/STATE_MACHINE.md"
grep -Fq 'state.program_transition()' "$STATE_DOC" || fail "state-machine doctrine omits atomic PROGRAM host transition owner"
grep -Fq 'not** mutate a second FSM' "$STATE_DOC" || fail "state-machine doctrine does not reject obsolete nested-FSM model"
if grep -Fq 'checkpoint internal state is set via `state.save()` directly' "$STATE_DOC"; then
  fail "state-machine doctrine still describes obsolete checkpoint state.save lifecycle"
fi
pass "state-machine doctrine matches current host-FSM + PROGRAM-object model"

APPROVAL_SCHEMA="$ROOT_DIR/schemas/approval.schema.json"
grep -Fq '"build_start"' "$APPROVAL_SCHEMA" || fail "approval schema omits current build_start execution binding"
if grep -Fq '"operator_marker"' "$APPROVAL_SCHEMA"; then
  fail "approval schema still admits retired operator_marker binding"
fi
pass "active execution-binding schema matches current first-start authority"

# The obsolete fixed builder semantic-result path must not be advertised by
# active generic adapter docs.
if grep -Fq 'scratch/builder/BUILD_AGENT_RESULT.json' "$ROOT_DIR/adapters/generic-cli/README.md"; then
  fail "generic adapter advertises obsolete unscoped builder result path"
fi
pass "generic adapter uses deterministic pass-scoped result-path contract"

BUILD_SKILL="$ROOT_DIR/skills/build/SKILL.md"
SPEC_SKILL="$ROOT_DIR/skills/spec/SKILL.md"
REVIEW_SKILL="$ROOT_DIR/skills/review/SKILL.md"

# Build: pre-start is startable, never terminal.
grep -Fq 'AWAITING_APPROVAL / READY_TO_START | STARTABLE' "$BUILD_SKILL" || fail "build skill does not classify pre-start as STARTABLE"
if grep -Eiq 'APPROVED[^\n]*BLOCKED[^\n]*STOPPED[^\n]*AWAITING_APPROVAL' "$BUILD_SKILL"; then
  fail "build skill reintroduced AWAITING_APPROVAL into terminal stop states"
fi
grep -Fq 'first claim may auto-seal' "$BUILD_SKILL" || fail "build skill does not describe first-start auto-seal"
pass "active build skill has no approval-era pre-start contradiction"

# Spec: normal background flow is supervisor-first and explicitly has no
# approval ceremony. Plugin-era /loop scheduling must not return.
grep -Fq 'ofloop supervisor enqueue <repo> <run-id>' "$SPEC_SKILL" || fail "spec skill missing supervisor enqueue handoff"
grep -Fq 'ofloop supervisor status <repo> <run-id>' "$SPEC_SKILL" || fail "spec skill missing supervisor status handoff"
grep -Fq 'ofloop supervisor serve' "$SPEC_SKILL" || fail "spec skill missing supervisor execution-clock handoff"
if grep -Fq '/loop /of-loop:' "$SPEC_SKILL"; then
  fail "spec skill reintroduced retired /loop scheduling"
fi
grep -Fq 'no approval ceremony is required' "$SPEC_SKILL" || fail "spec skill does not state no-ceremony contract"
pass "active spec skill exposes supervisor-first no-ceremony UX"

# Review: builder alone owns first start.
grep -Fq 'AWAITING_APPROVAL / READY_TO_START | WAIT' "$REVIEW_SKILL" || fail "review skill does not WAIT at pre-start"
grep -Fq 'builder owns first start' "$REVIEW_SKILL" || fail "review skill does not assign first-start ownership to builder"
pass "active review skill waits before first start"

# Cross-adapter coordinator parity: host-specific prose may differ, but the
# execution-authority doctrine must remain aligned.
require_pair_phrase() {
  local left="$1" right="$2" phrase="$3"
  grep -Fiq "$phrase" "$ROOT_DIR/$left" || fail "$left missing shared adapter doctrine: $phrase"
  grep -Fiq "$phrase" "$ROOT_DIR/$right" || fail "$right missing shared adapter doctrine: $phrase"
}

require_pair_phrase "skills/spec/SKILL.md" ".agents/skills/of-loop-spec/SKILL.md" "ofloop supervisor enqueue <repo> <run-id>"
require_pair_phrase "skills/spec/SKILL.md" ".agents/skills/of-loop-spec/SKILL.md" "Never add push, merge, deploy, publish"

require_pair_phrase "skills/build/SKILL.md" ".agents/skills/of-loop-build/SKILL.md" "ofloop supervisor enqueue <repo> <run-id>"
require_pair_phrase "skills/build/SKILL.md" ".agents/skills/of-loop-build/SKILL.md" "No raw worktree/branch creation or removal"
require_pair_phrase "skills/build/SKILL.md" ".agents/skills/of-loop-build/SKILL.md" "no push, merge, deploy,"

require_pair_phrase "skills/review/SKILL.md" ".agents/skills/of-loop-review/SKILL.md" "ofloop supervisor enqueue <repo> <run-id>"
require_pair_phrase "skills/review/SKILL.md" ".agents/skills/of-loop-review/SKILL.md" "builder owns first start"
require_pair_phrase "skills/review/SKILL.md" ".agents/skills/of-loop-review/SKILL.md" "no push, merge, deploy, publish"

for f in "$ROOT_DIR/skills/spec/SKILL.md" "$ROOT_DIR/.agents/skills/of-loop-spec/SKILL.md"; do
  grep -Fq 'Always write `runner_profile`' "$f" || fail "spec adapter does not require explicit runner_profile: $f"
  grep -Fq 'does not reread interactive user/project/local' "$f" || fail "spec adapter misstates interactive settings inheritance: $f"
done
for f in "$ROOT_DIR/skills/build/SKILL.md" "$ROOT_DIR/.agents/skills/of-loop-build/SKILL.md"; do
  grep -Fq 'first claim may auto-seal' "$f" || fail "build adapter drifted first-start semantics: $f"
done
for f in "$ROOT_DIR/skills/review/SKILL.md" "$ROOT_DIR/.agents/skills/of-loop-review/SKILL.md"; do
  grep -Fq 'builder owns first start' "$f" || fail "review adapter drifted first-start ownership: $f"
done
pass "Claude and Codex coordinator surfaces share critical execution doctrine"

# Examples are executable documentation: every packet example must parse and
# pass the same current structural/business admission validator as a real packet.
PYTHONPATH="$ROOT_DIR/lib" python3 - "$ROOT_DIR" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import packet

root = Path(sys.argv[1])
files = sorted(p for p in (root / "examples").glob("*.md") if p.name != "README.md")
if not files:
    raise SystemExit("no packet examples found")
for path in files:
    meta, _ = packet.parse_packet_file(path)
    errors = packet.validate_packet_for_approval(meta)
    if errors:
        raise SystemExit(f"{path.relative_to(root)} invalid: " + "; ".join(errors))
print(f"EXAMPLE_PACKET_CONTRACTS=PASS count={len(files)}")
PY
pass "packet examples validate against current executable contracts"

# Product identity: active generic contracts may name Claude only as an
# adapter/runner, never as the owner of the core runtime or scheduler.
if grep -Fq 'A reusable Claude Code plugin' "$ROOT_DIR/docs/ARCHITECTURE.md"; then
  fail "architecture still identifies product as Claude Code plugin"
fi
if grep -Fq 'claude plugin list --json' "$ROOT_DIR/README.md"; then
  fail "README still derives core installation from Claude plugin registry"
fi
pass "active product identity is core/supervisor/adapter, not plugin-era /loop"
echo "PUBLIC_CONTRACT_TRUTH=PASS"
