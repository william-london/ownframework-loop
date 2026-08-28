#!/usr/bin/env bash
# Public active-contract truth gate. Historical CHANGELOG/docs/history are excluded.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

ACTIVE_FILES=(
  README.md
  AGENTS.md
  SECURITY.md
  docs/SECURITY_MODEL.md
  docs/OPERATOR_RUNBOOK.md
  docs/ADAPTER_DEVELOPMENT.md
  docs/architecture/README.md
  docs/architecture/CORE_INVARIANTS.md
  docs/architecture/ADAPTER_CONTRACT.md
  docs/architecture/PORTABILITY_MODEL.md
  docs/architecture/CAPABILITY_MATRIX.md
  docs/architecture/AGENT_SKILLS.md
  adapters/README.md
  adapters/generic-cli/README.md
  skills/spec/SKILL.md
  skills/build/SKILL.md
  skills/review/SKILL.md
  .agents/skills/of-loop-spec/SKILL.md
  .agents/skills/of-loop-build/SKILL.md
  .agents/skills/of-loop-review/SKILL.md
  .agents/skills/of-loop-status/SKILL.md
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
)

for phrase in "${FORBIDDEN[@]}"; do
  for f in "${ACTIVE_FILES[@]}"; do
    if grep -Fq "$phrase" "$ROOT_DIR/$f"; then
      fail "stale public-contract phrase in $f: $phrase"
    fi
  done
done
pass "active public contracts contain no stale mandatory-approval doctrine"

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

# Spec: normal flow returns builder/reviewer commands and explicitly has no
# approval ceremony. Compatibility-only text is allowed outside normal flow.
grep -Fq '/loop /of-loop:build <run-id>' "$SPEC_SKILL" || fail "spec skill missing builder handoff"
grep -Fq '/loop /of-loop:review <run-id>' "$SPEC_SKILL" || fail "spec skill missing reviewer handoff"
grep -Fq 'no approval ceremony is required' "$SPEC_SKILL" || fail "spec skill does not state no-ceremony contract"
pass "active spec skill exposes direct start UX"

# Review: builder alone owns first start.
grep -Fq 'AWAITING_APPROVAL / READY_TO_START | WAIT' "$REVIEW_SKILL" || fail "review skill does not WAIT at pre-start"
grep -Fq 'builder owns first start' "$REVIEW_SKILL" || fail "review skill does not assign first-start ownership to builder"
pass "active review skill waits before first start"

echo "PUBLIC_CONTRACT_TRUTH=PASS"
