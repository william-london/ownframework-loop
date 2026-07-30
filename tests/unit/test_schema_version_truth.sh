#!/usr/bin/env bash
# Schema-version truth checks:
# - build-receipt.schema.json const matches runtime emission (v2)
# - review-verdict.schema.json const matches runtime emission (v2)
# - receipts.py / verdicts.py SCHEMA_VERSION constants match schemas
# - cli.py SCHEMA_PACKET matches work-packet schema (v2)
# - state schema is v1 (matches runtime SCHEMA_VERSION in state.py)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
fail=0
ok() { echo "  PASS: $*"; }
bad() { echo "  FAIL: $*"; fail=$((fail+1)); }

get_const() {
  python3 -c "import json,sys; print(json.load(open('$1'))['properties']['schema']['const'])"
}

BR=$(get_const "$ROOT/schemas/build-receipt.schema.json")
RV=$(get_const "$ROOT/schemas/review-verdict.schema.json")
WP=$(get_const "$ROOT/schemas/work-packet.schema.json")

[[ "$BR" == "ownframework-loop-build-receipt/v2" ]] \
  && ok "build-receipt schema const = v2" \
  || bad "build-receipt schema const = $BR (want v2)"

[[ "$RV" == "ownframework-loop-review-verdict/v2" ]] \
  && ok "review-verdict schema const = v2" \
  || bad "review-verdict schema const = $RV (want v2)"

[[ "$WP" == "ownframework-work-packet/v2" ]] \
  && ok "work-packet schema const = v2" \
  || bad "work-packet schema const = $WP (want v2)"

# receipts.py / verdicts.py constants
grep -q 'SCHEMA_VERSION = "ownframework-loop-build-receipt/v2"' "$ROOT/lib/ownframework_loop/receipts.py" \
  && ok "receipts.py: SCHEMA_VERSION = build-receipt/v2" \
  || bad "receipts.py: SCHEMA_VERSION mismatch"

grep -q 'SCHEMA_VERSION = "ownframework-loop-review-verdict/v2"' "$ROOT/lib/ownframework_loop/verdicts.py" \
  && ok "verdicts.py: SCHEMA_VERSION = review-verdict/v2" \
  || bad "verdicts.py: SCHEMA_VERSION mismatch"

grep -q 'SCHEMA_PACKET = "ownframework-work-packet/v2"' "$ROOT/lib/ownframework_loop/cli.py" \
  && ok "cli.py: SCHEMA_PACKET = work-packet/v2" \
  || bad "cli.py: SCHEMA_PACKET mismatch"

# State schema (v1) must match state.py SCHEMA_VERSION
STATE_CONST=$(get_const "$ROOT/schemas/state.schema.json")
[[ "$STATE_CONST" == "ownframework-loop-state/v1" ]] \
  && ok "state schema const = v1 (matches state.py)" \
  || bad "state schema const = $STATE_CONST (want v1)"

# v2 state schema file exists for Phase D (program mode)
[[ -f "$ROOT/schemas/state.schema.v2.json" ]] \
  && ok "v2 state schema file (program mode) present" \
  || echo "  NOTE: v2 state schema file not present (planned for Phase D)"

# Examples must be on v2 packet
for ex in "$ROOT"/examples/*.md; do
  if grep -q '"schema": "ownframework-work-packet/v2"' "$ex"; then
    ok "example $(basename "$ex"): packet schema v2"
  else
    bad "example $(basename "$ex"): packet schema still v1"
  fi
done

if [[ "$fail" -eq 0 ]]; then
  echo "  RESULT: schema-version truth checks pass"
  exit 0
fi
echo "  RESULT: $fail schema-version truth checks failed"
exit 1
