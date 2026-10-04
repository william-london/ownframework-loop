#!/usr/bin/env bash
# v1.1.2 — acceptance-criteria `verification` must reach the semantic roles.
#
# Defect: every work-packet generation (v1, v3, v4) accepts an optional
# `verification` string on each acceptance criterion, and the shipped example
# packet populates it (examples/program.md). But dispatch._checkpoint_authority_context
# — the single canonical projection feeding BOTH the builder and the reviewer
# work order — rebuilt each row as {"id", "text"} only. The field was therefore
# accepted as packet authority and then silently discarded before either
# semantic role could see it, which made the public packet schema misleading:
# an author could bind an intended proof method to a criterion and have it
# vanish. The exemplar failure mode this enables is substituting
# artifact-existence reasoning for the proof the author actually specified.
#
# Required invariants proven here:
#   PACKET_AC.verification        => SEMANTIC_WORK_ORDER_AC.verification
#   ABSENT verification            => REMAINS ABSENT (backward compatible)
#   BLANK/WHITESPACE verification  => OMITTED (never a meaningless key)
#   PROJECTION NEVER INVENTS TEXT  => absent stays absent
#   SCOPE: SINGLE / CHECKPOINT / PROGRAM_FINAL all project consistently
#   PROGRAM_FINAL sees the FULL PACKET contract (checkpoint_id forced empty)
#   CHECKPOINT sees only CP-OWNED criteria, never future-checkpoint ones
#   PROJECTION IS NOT SHARED MUTABLE STATE across callers
#   ROLE CONTRACTS carry the proof-guidance semantics (not a bare field)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib:$ROOT_DIR/tests/helpers${PYTHONPATH:+:$PYTHONPATH}"
export OFLOOP_LIB="$ROOT_DIR/lib"
export PYTHONDONTWRITEBYTECODE=1
TMP="$(mktemp -d -t ofloop-v130-verification.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

python3 -B - "$TMP" "$ROOT_DIR" <<'PY'
from __future__ import annotations

import sys
from pathlib import Path

root = Path(sys.argv[2])
sys.path.insert(0, str(root / "lib"))
from ownframework_loop import dispatch, program as program_mod  # noqa: E402

PACKET = {
    "schema": "ownframework-work-packet/v4",
    "acceptance_criteria": [
        {"id": "AC-1", "text": "Real product boots",
         "verification": "Run scripts/verify_clean_checkout.sh"},
        {"id": "AC-2", "text": "Surface is populated"},
        {"id": "AC-3", "text": "Whitespace verification is not a value",
         "verification": "   \n\t "},
    ],
    "checkpoint_graph": {
        "execution_order": ["CP-1", "CP-2"],
        "checkpoints": [
            {"id": "CP-1", "acceptance_criterion_ids": ["AC-1", "AC-2"]},
            {"id": "CP-2", "acceptance_criterion_ids": ["AC-3"]},
        ],
    },
    "allowed_paths": ["src/"],
    "protected_paths": [".ownframework-loop/"],
}


def ctx(state_doc, checkpoint_id):
    return dispatch._checkpoint_authority_context(
        PACKET, state_doc, checkpoint_id=checkpoint_id, work_unit_id="UNIT-1",
    )


def row(rows, ac_id):
    for item in rows:
        if item.get("id") == ac_id:
            return item
    raise AssertionError(f"missing projected criterion {ac_id}")


CHECKPOINT_STATE = {
    "program": {
        "review_scope": "checkpoint",
        "current_checkpoints": ["CP-1"],
        "finalized_checkpoints": [],
    }
}
FINAL_STATE = {
    "program": {
        "review_scope": "program_final",
        "current_checkpoints": [],
        "finalized_checkpoints": [{"id": "CP-1"}, {"id": "CP-2"}],
    }
}

# --- 1. SINGLE mode projects the full packet contract with verification ----
single = ctx({}, "")
assert single["acceptance_criterion_ids"] == ["AC-1", "AC-2", "AC-3"], \
    single["acceptance_criterion_ids"]
assert row(single["acceptance_criteria"], "AC-1")["verification"] == \
    "Run scripts/verify_clean_checkout.sh", "SINGLE dropped verification"
print("SINGLE_VERIFICATION_PRESERVED=PASS")

# --- 2. Absence stays absent: backward compatibility ----------------------
assert "verification" not in row(single["acceptance_criteria"], "AC-2"), \
    "verification invented for a criterion that never supplied one"
print("ABSENT_VERIFICATION_STAYS_ABSENT=PASS")

# --- 3. Whitespace-only verification is omitted, not carried as a key -----
assert "verification" not in row(single["acceptance_criteria"], "AC-3"), \
    "blank verification projected as a meaningless key"
print("BLANK_VERIFICATION_OMITTED=PASS")

# --- 4. PROGRAM checkpoint scope: CP-owned criteria only, verification on -
cp = ctx(CHECKPOINT_STATE, "CP-1")
assert cp["acceptance_criterion_ids"] == ["AC-1", "AC-2"], cp["acceptance_criterion_ids"]
assert row(cp["acceptance_criteria"], "AC-1")["verification"] == \
    "Run scripts/verify_clean_checkout.sh", "checkpoint review dropped verification"
print("CHECKPOINT_VERIFICATION_PRESERVED=PASS")

# --- 5. PROGRAM_FINAL: checkpoint_id forced empty, FULL packet contract ----
final = ctx(FINAL_STATE, "CP-1")
assert final["checkpoint_id"] == "", final["checkpoint_id"]
assert final["review_scope"] == "program_final", final["review_scope"]
assert final["acceptance_criterion_ids"] == ["AC-1", "AC-2", "AC-3"], \
    final["acceptance_criterion_ids"]
assert row(final["acceptance_criteria"], "AC-1")["verification"] == \
    "Run scripts/verify_clean_checkout.sh", "PROGRAM_FINAL dropped verification"
print("PROGRAM_FINAL_VERIFICATION_PRESERVED=PASS")

# --- 6. text is still carried alongside verification (no regression) ------
assert row(final["acceptance_criteria"], "AC-1")["text"] == "Real product boots"
print("TEXT_PRESERVED_ALONGSIDE=PASS")

# --- 7. Projected rows are per-caller copies, not shared mutable state ----
final["acceptance_criteria"][0]["verification"] = "TAMPERED"
final["acceptance_criteria"][0]["text"] = "TAMPERED"
fresh = ctx(FINAL_STATE, "CP-1")
assert fresh["acceptance_criteria"][0]["verification"] == \
    "Run scripts/verify_clean_checkout.sh", "projection leaked caller mutation"
assert fresh["acceptance_criteria"][0]["text"] == "Real product boots"
print("PROJECTION_ISOLATION=PASS")

# --- 8. A verdict is never derived: the field is a value, nothing more ----
assert set(PACKET["acceptance_criteria"][0]) == {"id", "text", "verification"}
print("NO_DERIVED_PROOF_AUTHORITY=PASS")

# --- 9. Both semantic roles consume the SAME projection -------------------
src = (root / "lib" / "ownframework_loop" / "dispatch.py").read_text()
assert src.count('"checkpoint_authority": _checkpoint_authority_context(') == 2, \
    "expected exactly one builder and one reviewer projection call site"
print("BOTH_ROLES_SHARE_PROJECTION=PASS")

# --- 10. Role contracts carry the proof-guidance semantics ----------------
def flatten(path: Path) -> str:
    """Collapse wrapping so prose assertions are not layout-coupled."""
    return " ".join(path.read_text().split())


reviewer = flatten(root / "agents" / "of-reviewer.md")
builder = flatten(root / "agents" / "of-builder.md")
assert "Acceptance-criterion `verification` (packet proof guidance)" in reviewer, \
    "of-reviewer.md lost the verification guidance section"
# The reviewer owns a verdict, so unobtainable proof must route to a real
# machine result (inconclusive/fail) rather than a substituted claim.
assert "inconclusive" in reviewer, \
    "of-reviewer.md must route unobtainable proof to inconclusive/fail"
# The builder owns no verdict; the equivalent duty is honest evidence.
assert "cannot be obtained" in builder, \
    "of-builder.md must report unobtainable proof honestly in its evidence"
for doc, name in ((reviewer, "of-reviewer.md"), (builder, "of-builder.md")):
    assert "artifact-existence" in doc, f"{name} lost the anti-substitution rule"
    assert "deterministic finalizer remains the authority" in doc, \
        f"{name} lost the authority boundary for verification"
print("ROLE_CONTRACT_GUIDANCE=PASS")

# --- 11. Packet schema still accepts the field on every generation --------
import json  # noqa: E402
for schema_name in ("work-packet.schema.json", "work-packet-v3.schema.json",
                    "work-packet-v4.schema.json"):
    schema = json.loads((root / "schemas" / schema_name).read_text())
    ac_item = schema["properties"]["acceptance_criteria"]["items"]
    props = ac_item.get("properties") or {}
    assert "verification" in props, f"{schema_name} dropped acceptance verification"
    assert props["verification"].get("type") == "string", schema_name
print("SCHEMA_ACCEPTS_VERIFICATION=PASS")

print("V130_VERIFICATION_PROJECTION=PASS")
PY
