#!/usr/bin/env bash
# Model-free contract test for the final commissioned PROGRAM canary.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"

HARNESS="$ROOT_DIR/tests/canary/commissioned_program_canary.sh"
RENDER="$ROOT_DIR/tests/canary/commissioned_program_packet.py"
README="$ROOT_DIR/tests/canary/README.md"

bash -n "$HARNESS" || fail "commissioned canary shell syntax invalid"
PYTHONDONTWRITEBYTECODE=1 python3 -B - "$RENDER" <<'PY' || fail "commissioned packet renderer does not compile"
import sys
from pathlib import Path
source=Path(sys.argv[1]).read_text(encoding="utf-8")
compile(source, sys.argv[1], "exec")
PY

TMP="$(mktemp -d -t ofloop_canary_contract.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo/.ownframework-loop/run-test"
OUT="$TMP/repo/.ownframework-loop/run-test/WORK_PACKET.md"
python3 "$RENDER" "$TMP/repo" "$OUT"

python3 -B - "$OUT" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import packet,schema_validate
p=Path(sys.argv[1]); meta,_=packet.parse_packet_file(p)
assert meta["schema"]=="ownframework-work-packet/v3"
assert meta["execution_mode"]=="program"
assert meta["checkpoint_graph"]["execution_order"]==["CP-1","CP-2"]
cps=meta["checkpoint_graph"]["checkpoints"]
assert cps[1]["depends_on"]==["CP-1"]
assert "CANARY_REPAIR_REQUIRED" in cps[0]["scope"]
assert "CHANGES_REQUESTED" in meta["acceptance_criteria"][0]["text"]
assert meta["network_read_allowlist"]==[]
assert meta["external_action_authority"]=="none"
assert not packet.validate_packet_for_approval(meta), packet.validate_packet_for_approval(meta)
assert not schema_validate.validate_packet(meta), schema_validate.validate_packet(meta)
print("COMMISSIONED_CANARY_PACKET=VALID")
PY

if grep -Fq 'supervisor serve' "$HARNESS"; then
  fail "commissioned canary bypasses commissioned service with foreground serve"
fi
if grep -Fq -- '--db' "$HARNESS"; then
  fail "commissioned canary uses isolated/custom DB instead of commissioned ledger"
fi
grep -Fq '.ownframework-loop-managed' "$HARNESS" || fail "canary does not require installed managed core"
grep -Fq 'runtime-provenance.json' "$HARNESS" || fail "canary does not bind runtime provenance"
grep -Fq 'launchctl kickstart -k' "$HARNESS" || fail "canary lacks launchd restart path"
grep -Fq 'systemctl --user restart' "$HARNESS" || fail "canary lacks systemd-user restart path"
for marker in PREPARED STARTED IN_PROGRESS TERMINAL_PASS TERMINAL_FAIL; do
  grep -Fq "CANARY_STATE=$marker" "$HARNESS" || fail "canary lifecycle marker missing: $marker"
done
for evidence in DUPLICATE_SEMANTIC_ATTEMPTS LOST_SEMANTIC_ATTEMPTS WRONG_SHA_REVIEWS REPAIR_ACCOUNTING CHECKPOINT_ACCOUNTING RUNTIME_GENERATION_STABLE STATE_EVENT_CHAIN_VALID ATTEMPT_LEDGER_COHERENT UNAUTHORIZED_EXTERNAL_EFFECTS HUMAN_SEMANTIC_INTERVENTION_DURING_RUN FINAL_PROGRAM_STATE; do
  grep -Fq "$evidence" "$HARNESS" || fail "terminal evidence check missing: $evidence"
done
grep -Fq 'single-run v2 source-lane smoke' "$README" || fail "README does not scope old canary honestly"
grep -Fq 'final commissioning harness' "$README" || fail "README omits commissioned PROGRAM harness"

pass "commissioned v3 canary is model-free prepared, service-driven, restart-aware, and terminal-evidence gated"
echo "V085_COMMISSIONED_CANARY_CONTRACT=PASS"
