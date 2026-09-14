#!/usr/bin/env bash
# v0.9.1 — scanner-internal severities must be normalized at public artifact
# boundaries for both BUILD_RECEIPT and REVIEW_VERDICT.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"

python3 - <<'PY'
from ownframework_loop import secrets_v2

assert secrets_v2.normalize_public_artifact_severity("hard") == "hard"
assert secrets_v2.normalize_public_artifact_severity("heuristic") == "soft"
assert secrets_v2.normalize_public_artifact_severity("info") == "informational"
try:
    secrets_v2.normalize_public_artifact_severity("unsupported")
except ValueError:
    pass
else:
    raise AssertionError("unknown scanner severity must fail closed")
print("SECRET_SEVERITY_MAPPING=PASS")
print("UNKNOWN_SEVERITY_FAIL_CLOSED=PASS")
PY

fill_builder_result() {
  local semantic="$1"
  python3 - "$semantic" <<'PY'
import json
import sys
from pathlib import Path

p = Path(sys.argv[1])
d = json.loads(p.read_text())
d.update({
    "summary": "secret severity contract synthetic builder",
    "outcome_requested": "candidate_ready",
    "unit_ids_completed": ["UNIT-1"],
    "acceptance_addressed": ["AC-1"],
})
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
}

fill_reviewer_result() {
  local semantic="$1"
  python3 - "$semantic" <<'PY'
import json
import sys
from pathlib import Path

p = Path(sys.argv[1])
d = json.loads(p.read_text())
d.update({
    "validation_results": [],
    "acceptance_results": [{"id": "AC-1", "result": "pass", "evidence": "synthetic"}],
    "non_goal_results": [],
    "findings": [],
    "recommended_verdict": "APPROVED",
    "escalation_recommended": False,
})
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
}

validate_artifact() {
  local repo="$1" rid="$2" kind="$3"
  python3 - "$repo" "$rid" "$kind" <<'PY'
import json
import sys
from pathlib import Path
from ownframework_loop import schema_validate

repo = Path(sys.argv[1])
rid = sys.argv[2]
kind = sys.argv[3]
path = repo / ".ownframework-loop" / rid / (
    "BUILD_RECEIPT.json" if kind == "build" else "REVIEW_VERDICT.json"
)
doc = json.loads(path.read_text())
errors = (
    schema_validate.validate_receipt(doc)
    if kind == "build"
    else schema_validate.validate_verdict(doc)
)
assert not errors, errors
print(f"{kind.upper()}_ARTIFACT_SCHEMA=PASS")
PY
}

# BUILD heuristic: a real finalizer-produced receipt must expose soft and must
# remain reviewable rather than blocking the candidate.
BUILD_REPO="$(make_tmp_repo)"
BUILD_RUN="$(make_approved_run "$BUILD_REPO" FEATURE low "secret-severity-build")"
BUILD_ORDER="$("$OFLOOP_BIN" dispatch claim "$BUILD_REPO" "$BUILD_RUN")"
BUILD_WT="$(printf '%s' "$BUILD_ORDER" | jq -r '.worktree')"
BUILD_SEM="$(printf '%s' "$BUILD_ORDER" | jq -r '.semantic_path')"
mkdir -p "$BUILD_WT/src"
python3 - "$BUILD_WT/src/heuristic_fixture.py" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
p.write_text('password = "synthetic-reviewable-value"\n')
PY
git -C "$BUILD_WT" add src/heuristic_fixture.py
git -C "$BUILD_WT" commit -m "test: synthetic heuristic secret finding" >/dev/null
fill_builder_result "$BUILD_SEM"
"$OFLOOP_BIN" dispatch finalize "$BUILD_REPO" "$BUILD_RUN" BUILD "$BUILD_SEM" >/dev/null
BUILD_SEVERITIES="$(jq -r '.secret_scan_check.findings[].severity' "$BUILD_REPO/.ownframework-loop/$BUILD_RUN/BUILD_RECEIPT.json")"
assert_eq "$BUILD_SEVERITIES" "soft" "BUILD heuristic normalized to soft"
assert_eq "$(jq -r '.secret_scan_check.result' "$BUILD_REPO/.ownframework-loop/$BUILD_RUN/BUILD_RECEIPT.json")" "pass" "BUILD heuristic remains non-blocking"
assert_eq "$(jq -r '.state' "$BUILD_REPO/.ownframework-loop/$BUILD_RUN/STATE.json")" "READY_FOR_REVIEW" "BUILD heuristic does not block candidate"
validate_artifact "$BUILD_REPO" "$BUILD_RUN" build

# REVIEW heuristic: the independent reviewer finalizer must use the same
# boundary and produce a schema-valid verdict.
REVIEW_ORDER="$("$OFLOOP_BIN" dispatch claim "$BUILD_REPO" "$BUILD_RUN")"
REVIEW_SEM="$(printf '%s' "$REVIEW_ORDER" | jq -r '.semantic_path')"
fill_reviewer_result "$REVIEW_SEM"
"$OFLOOP_BIN" dispatch finalize "$BUILD_REPO" "$BUILD_RUN" REVIEW "$REVIEW_SEM" >/dev/null
assert_eq "$(jq -r '.secret_scan_check.findings[].severity' "$BUILD_REPO/.ownframework-loop/$BUILD_RUN/REVIEW_VERDICT.json")" "soft" "REVIEW heuristic normalized to soft"
assert_eq "$(jq -r '.verdict' "$BUILD_REPO/.ownframework-loop/$BUILD_RUN/REVIEW_VERDICT.json")" "APPROVED" "REVIEW heuristic does not block approval"
validate_artifact "$BUILD_REPO" "$BUILD_RUN" review

# BUILD hard: construct the recognizable shape from pieces so no credential-
# shaped literal is stored in this repository.
HARD_BUILD_REPO="$(make_tmp_repo)"
HARD_BUILD_RUN="$(make_approved_run "$HARD_BUILD_REPO" FEATURE low "secret-severity-hard-build")"
HARD_BUILD_ORDER="$("$OFLOOP_BIN" dispatch claim "$HARD_BUILD_REPO" "$HARD_BUILD_RUN")"
HARD_BUILD_WT="$(printf '%s' "$HARD_BUILD_ORDER" | jq -r '.worktree')"
HARD_BUILD_SEM="$(printf '%s' "$HARD_BUILD_ORDER" | jq -r '.semantic_path')"
mkdir -p "$HARD_BUILD_WT/src"
python3 - "$HARD_BUILD_WT/src/hard_fixture.py" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
p.write_text('provider_key = "' + "AKIA" + ("0" * 16) + '"\n')
PY
git -C "$HARD_BUILD_WT" add src/hard_fixture.py
git -C "$HARD_BUILD_WT" commit -m "test: synthetic hard secret finding" >/dev/null
fill_builder_result "$HARD_BUILD_SEM"
set +e
HARD_BUILD_OUTPUT="$("$OFLOOP_BIN" dispatch finalize "$HARD_BUILD_REPO" "$HARD_BUILD_RUN" BUILD "$HARD_BUILD_SEM" 2>&1)"
HARD_BUILD_RC=$?
set -e
[[ "$HARD_BUILD_RC" -ne 0 ]] || fail "BUILD hard finding unexpectedly finalized"
assert_contains "$HARD_BUILD_OUTPUT" "hard secret pattern detected" "BUILD hard finding blocks finalization"
[[ ! -e "$HARD_BUILD_REPO/.ownframework-loop/$HARD_BUILD_RUN/BUILD_RECEIPT.json" ]] || fail "blocked BUILD wrote receipt"
pass "BUILD hard finding remains blocking"

# REVIEW hard: first produce a clean receipt, then inject a scanner hard hit
# into the actual review finalizer. This isolates review semantics because a
# real BUILD hard hit correctly prevents the prerequisite receipt.
HARD_REVIEW_REPO="$(make_tmp_repo)"
HARD_REVIEW_RUN="$(make_approved_run "$HARD_REVIEW_REPO" FEATURE low "secret-severity-hard-review")"
HARD_REVIEW_ORDER="$("$OFLOOP_BIN" dispatch claim "$HARD_REVIEW_REPO" "$HARD_REVIEW_RUN")"
HARD_REVIEW_WT="$(printf '%s' "$HARD_REVIEW_ORDER" | jq -r '.worktree')"
HARD_REVIEW_SEM="$(printf '%s' "$HARD_REVIEW_ORDER" | jq -r '.semantic_path')"
mkdir -p "$HARD_REVIEW_WT/src"
printf 'def clean_candidate():\n    return True\n' > "$HARD_REVIEW_WT/src/clean.py"
git -C "$HARD_REVIEW_WT" add src/clean.py
git -C "$HARD_REVIEW_WT" commit -m "test: clean review candidate" >/dev/null
fill_builder_result "$HARD_REVIEW_SEM"
"$OFLOOP_BIN" dispatch finalize "$HARD_REVIEW_REPO" "$HARD_REVIEW_RUN" BUILD "$HARD_REVIEW_SEM" >/dev/null
HARD_REVIEW_ORDER="$("$OFLOOP_BIN" dispatch claim "$HARD_REVIEW_REPO" "$HARD_REVIEW_RUN")"
HARD_REVIEW_SEM="$(printf '%s' "$HARD_REVIEW_ORDER" | jq -r '.semantic_path')"
fill_reviewer_result "$HARD_REVIEW_SEM"
python3 - "$HARD_REVIEW_REPO" "$HARD_REVIEW_RUN" "$HARD_REVIEW_SEM" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import review_finalize, secrets_v2

repo = Path(sys.argv[1])
rid = sys.argv[2]
assessment = Path(sys.argv[3])
hard_hits = secrets_v2.scan_text("provider_key = '" + "AKIA" + ("0" * 16) + "'", source="synthetic")
assert hard_hits and hard_hits[0]["severity"] == "hard", hard_hits
original = secrets_v2.scan_path_for_secrets_strict
secrets_v2.scan_path_for_secrets_strict = lambda _path: hard_hits
try:
    verdict = review_finalize.finalize_review(
        canonical_repo=repo,
        run_id=rid,
        assessment_path=assessment,
        actor="secret-severity-test",
    )
finally:
    secrets_v2.scan_path_for_secrets_strict = original
assert verdict["verdict"] == "BLOCKED", verdict
assert verdict["failure_reason"] == "hard_secret_detected", verdict
assert verdict["secret_scan_check"]["findings"][0]["severity"] == "hard", verdict
print("REVIEW_HARD_BLOCK=PASS")
PY
validate_artifact "$HARD_REVIEW_REPO" "$HARD_REVIEW_RUN" review

echo "V091_SECRET_SEVERITY_CONTRACT=PASS"
