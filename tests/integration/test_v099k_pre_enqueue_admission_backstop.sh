#!/usr/bin/env bash
# v0.9.9-k: pre-enqueue admission backstop — supervisor refuses durable
# admission of a never-started run whose pre-seal packet is deterministically
# invalid.
#
# Defect: the deterministic core admitted invalid packets into durable
# scheduler rows; the same invalid packet was only caught at first execution /
# build claim, sending the job to operational QUARANTINED. Recovery required
# explicit `ofloop supervisor resume`. This is operator friction on a normal
# spec workflow when the trusted adapter accidentally drafts a schema-invalid
# packet.
#
# Closure: supervisor.enqueue runs the authoritative
# ``packet.validate_packet_for_approval`` BEFORE the durable INSERT. If the
# packet is missing or invalid, the function returns a structured refusal
# WITHOUT creating or mutating a job row. Existing legitimate QUARANTINED
# semantics are untouched.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib"
export PYTHONDONTWRITEBYTECODE=1

OFLOOP_BIN="${OFLOOP_BIN:-/Users/mr.mrs.london/.local/share/ownframework-loop/0.9.1/bin/ofloop}"

fail_counter=0
pass_counter=0
fail() { echo "  FAIL: $1"; fail_counter=$((fail_counter+1)); }
pass() { echo "  PASS: $1"; pass_counter=$((pass_counter+1)); }

# Use a fresh tempdir so we don't disturb any in-flight runs.
WORK="$(mktemp -d -t ofloop-v099k.XXXXXX)"
DB="$WORK/supervisor.sqlite3"

mkpkg() {
  # mkpkg <badfield> <badvalue>
  local badfield="$1"
  local badvalue="$2"
  local repo="$WORK/repo-$RANDOM"
  git init -q -b master "$repo"
  echo "x" > "$repo/a.txt"
  git -C "$repo" add a.txt
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q -m init
  local run_id="run-$(date -u +%Y%m%dT%H%M%SZ)-$(printf '%s' "$RANDOM" | head -c 8)"
  local run_dir="$repo/.ownframework-loop/$run_id"
  mkdir -p "$run_dir"
  local pkt="$run_dir/WORK_PACKET.md"
  # packet_id + created_at are required by schema; mkpkg produces a baseline
  # packet that already includes them so the only mutation across tests is
  # the deliberate defect (badfield/badvalue).
  local packet_id="pkt-$(date -u +%Y%m%dT%H%M%SZ)-$(printf '%s' "$RANDOM" | head -c 8)"
  local created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # Use \``` escapes so bash does NOT command-substitute the triple backticks.
  cat > "$pkt" <<EOF
# v0.9.9-k test packet (deliberate defect: ${badfield})

\`\`\`json
{
  "schema": "ownframework-work-packet/v3",
  "packet_id": "${packet_id}",
  "created_at": "${created_at}",
  "work_class": "${badvalue}",
  "risk_class": "low",
  "title": "v0.9.9-k pre-enqueue admission test",
  "target": {"repo": "${repo}", "branch": "master", "classification": "local_only"},
  "execution_mode": "single",
  "acceptance_criteria": [{"id": "AC-1", "text": "ok"}],
  "non_goals": [{"id": "NG-1", "text": "none"}],
  "allowed_paths": ["a.txt"],
  "protected_paths": [".ownframework-loop/"],
  "capabilities": ["toolchain.git"],
  "runner_profile": "default",
  "required_validation": [{"name": "t", "command": "true", "kind": "bad_kind", "expected_exit_code": 0}],
  "work_units": [{"id": "UNIT-1", "title": "t", "scope": "do"}],
  "risk_budget": {
    "max_build_passes": 4, "max_review_passes": 4, "max_repair_rounds": 1,
    "max_diff_lines": 100, "max_files_changed": 5,
    "max_pass_runtime_seconds": 3600, "max_runtime_seconds": 86400,
    "max_consecutive_no_progress_passes": 3, "max_identical_finding_repeats": 3
  },
  "merge_authority": "human_only",
  "deploy_authority": "human_only",
  "push_authority": "human_only",
  "external_action_authority": "none"
}
\`\`\`
EOF
  echo "$repo|$run_id"
}

# patch_packet <pkt_path> <python_expression>  — apply a patch to the packet's
# JSON body. The expression runs in a small Python env with `d` (the parsed
# packet dict) and `text` (the full file) in scope. The patched text is
# written back to disk.
patch_packet() {
  local pkt_path="$1"
  local expr="$2"
  PKT_PATH="$pkt_path" python3 - <<PY
import os, re, json, pathlib
p = pathlib.Path(os.environ["PKT_PATH"])
text = p.read_text()
m = re.search(r"\`\`\`json\n(.*?)\n\`\`\`", text, re.DOTALL)
assert m is not None, "could not locate json fenced block"
d = json.loads(m.group(1))
${expr}
new = "\`\`\`json\n" + json.dumps(d, indent=2) + "\n\`\`\`"
p.write_text(text.replace(m.group(0), new))
PY
}

count_quarantined() {
  local db="$1"
  if [[ -f "$db" ]]; then
    sqlite3 "$db" "SELECT COUNT(*) FROM jobs WHERE status='QUARANTINED'"
  else
    echo "0"
  fi
}

count_total() {
  local db="$1"
  if [[ -f "$db" ]]; then
    sqlite3 "$db" "SELECT COUNT(*) FROM jobs"
  else
    echo "0"
  fi
}

# ----------------------------------------------------------------------
# TEST A: invalid work_class is refused pre-admission.
# ----------------------------------------------------------------------
echo "TEST A: invalid work_class refused before durable admission"
IFS='|' read -r REPO_A RID_A <<< "$(mkpkg work_class MATURE_FEATURE)"
OUT_A="$($OFLOOP_BIN supervisor enqueue --db "$DB" "$REPO_A" "$RID_A" 2>&1 || true)"
if [[ "$OUT_A" == *"pre_seal_packet_invalid"* ]] && [[ "$OUT_A" == *"work_class"* ]]; then
  pass "TEST A: invalid work_class triggers pre_seal_packet_invalid"
else
  fail "TEST A: expected pre_seal_packet_invalid; got: $OUT_A"
fi
NQA=$(count_total "$DB")
NAQ=$(count_quarantined "$DB")
if [[ "$NQA" == "0" ]]; then
  pass "TEST A: no job row admitted"
else
  fail "TEST A: expected 0 jobs admitted; got $NQA"
fi
if [[ "$NAQ" == "0" ]]; then
  pass "TEST A: no QUARANTINED row created"
else
  fail "TEST A: expected 0 QUARANTINED rows; got $NAQ"
fi

# ----------------------------------------------------------------------
# TEST B: invalid required_validation.kind is refused pre-admission.
# ----------------------------------------------------------------------
echo "TEST B: invalid required_validation.kind refused before durable admission"
IFS='|' read -r REPO_B RID_B <<< "$(mkpkg kind scoped)"
PKT_B="$REPO_B/.ownframework-loop/$RID_B/WORK_PACKET.md"
# Repair work_class to valid, keep kind invalid.
patch_packet "$PKT_B" 'd["work_class"] = "FEATURE"'
OUT_B="$($OFLOOP_BIN supervisor enqueue --db "$DB" "$REPO_B" "$RID_B" 2>&1 || true)"
if [[ "$OUT_B" == *"pre_seal_packet_invalid"* ]] && [[ "$OUT_B" == *"kind"* ]]; then
  pass "TEST B: invalid validation kind triggers pre_seal_packet_invalid"
else
  fail "TEST B: expected pre_seal_packet_invalid with kind reference; got: $OUT_B"
fi
NQB=$(count_total "$DB")
if [[ "$NQB" == "0" ]]; then
  pass "TEST B: no job row admitted"
else
  fail "TEST B: expected 0 jobs admitted; got $NQB"
fi

# ----------------------------------------------------------------------
# TEST C: invalid → refusal → correction → enqueue succeeds without resume.
# ----------------------------------------------------------------------
echo "TEST C: correction path bypasses resume ceremony"
# Same repo/run as TEST A. Correct the packet via direct pre-seal edit.
PKT_C="$REPO_A/.ownframework-loop/$RID_A/WORK_PACKET.md"
patch_packet "$PKT_C" 'd["work_class"] = "FEATURE"; d["required_validation"] = [{"name": "t", "command": "true", "kind": "fast", "expected_exit_code": 0}]'
OUT_C="$($OFLOOP_BIN supervisor enqueue --db "$DB" "$REPO_A" "$RID_A" 2>&1 || true)"
if [[ "$OUT_C" == *'"ok": true'* ]] || [[ "$OUT_C" == *'"ok":true'* ]]; then
  pass "TEST C: corrected packet enqueues successfully"
else
  fail "TEST C: expected ok=true enqueue; got: $OUT_C"
fi
NQC=$(count_total "$DB")
NSC=$(sqlite3 "$DB" "SELECT COUNT(*) FROM jobs WHERE status='QUEUED'" 2>/dev/null || echo 0)
NRC=$(sqlite3 "$DB" "SELECT COUNT(*) FROM jobs WHERE status='QUARANTINED'" 2>/dev/null || echo 0)
if [[ "$NQC" == "1" ]] && [[ "$NSC" == "1" ]] && [[ "$NRC" == "0" ]]; then
  pass "TEST C: exactly one QUEUED enrollment; zero QUARANTINED"
else
  fail "TEST C: expected 1 total/1 QUEUED/0 QUARANTINED; got total=$NQC queued=$NSC quarantined=$NRC"
fi

# ----------------------------------------------------------------------
# TEST D: valid packet follows existing enqueue path unchanged.
# ----------------------------------------------------------------------
echo "TEST D: valid packet regression"
IFS='|' read -r REPO_D RID_D <<< "$(mkpkg work_class FEATURE)"
PKT_D="$REPO_D/.ownframework-loop/$RID_D/WORK_PACKET.md"
patch_packet "$PKT_D" 'd["required_validation"] = [{"name": "t", "command": "true", "kind": "fast", "expected_exit_code": 0}]'
OUT_D="$($OFLOOP_BIN supervisor enqueue --db "$DB" "$REPO_D" "$RID_D" 2>&1 || true)"
if [[ "$OUT_D" == *'"ok": true'* ]] || [[ "$OUT_D" == *'"ok":true'* ]]; then
  pass "TEST D: valid packet enqueues"
else
  fail "TEST D: expected ok=true; got: $OUT_D"
fi
NQD=$(count_total "$DB")
NSD=$(sqlite3 "$DB" "SELECT COUNT(*) FROM jobs WHERE status='QUEUED'" 2>/dev/null || echo 0)
if [[ "$NQD" == "2" ]] && [[ "$NSD" == "2" ]]; then
  pass "TEST D: 2 total jobs, 2 QUEUED (no QUARANTINED)"
else
  fail "TEST D: expected 2/2; got total=$NQD queued=$NSD"
fi

# ----------------------------------------------------------------------
# TEST E: existing QUARANTINE semantics are NOT auto-recovered.
# ----------------------------------------------------------------------
echo "TEST E: QUARANTINE recovery requires explicit resume"
IFS='|' read -r REPO_E RID_E <<< "$(mkpkg work_class FEATURE)"
PKT_E="$REPO_E/.ownframework-loop/$RID_E/WORK_PACKET.md"
patch_packet "$PKT_E" 'd["required_validation"] = [{"name": "t", "command": "true", "kind": "fast", "expected_exit_code": 0}]'
$OFLOOP_BIN supervisor enqueue --db "$DB" "$REPO_E" "$RID_E" >/dev/null 2>&1 || true
sqlite3 "$DB" "UPDATE jobs SET status='QUARANTINED', infra_failures=3, max_infra_failures=3, last_error='legit quarantine for test E' WHERE run_id='$RID_E';" 2>&1 || true
PRE_RESUME=$(sqlite3 "$DB" "SELECT status FROM jobs WHERE run_id='$RID_E'" 2>/dev/null || echo unknown)
# Now re-enqueue. Re-enqueue of an existing row must NOT auto-recover.
$OFLOOP_BIN supervisor enqueue --db "$DB" "$REPO_E" "$RID_E" >/dev/null 2>&1 || true
POST_ENQ=$(sqlite3 "$DB" "SELECT status FROM jobs WHERE run_id='$RID_E'" 2>/dev/null || echo unknown)
if [[ "$PRE_RESUME" == "QUARANTINED" ]] && [[ "$POST_ENQ" == "QUARANTINED" ]]; then
  pass "TEST E: legitimate QUARANTINE survives re-enqueue (no auto-recovery)"
else
  fail "TEST E: expected QUARANTINED both times; got pre=$PRE_RESUME post=$POST_ENQ"
fi
OUT_RES="$($OFLOOP_BIN supervisor resume --db "$DB" "$REPO_E" "$RID_E" 2>&1 || true)"
POST_RES=$(sqlite3 "$DB" "SELECT status FROM jobs WHERE run_id='$RID_E'" 2>/dev/null || echo unknown)
if [[ "$POST_RES" == "QUEUED" ]]; then
  pass "TEST E: explicit resume still clears legitimate QUARANTINE"
else
  fail "TEST E: explicit resume did not clear; got $POST_RES"
fi

# ----------------------------------------------------------------------
# TEST F: PROGRAM packet remains valid through admission.
# ----------------------------------------------------------------------
echo "TEST F: PROGRAM mode admission path"
IFS='|' read -r REPO_F RID_F <<< "$(mkpkg work_class FEATURE)"
PKT_F="$REPO_F/.ownframework-loop/$RID_F/WORK_PACKET.md"
patch_packet "$PKT_F" 'd["required_validation"] = [{"name": "t", "command": "true", "kind": "fast", "expected_exit_code": 0}]
d["execution_mode"] = "program"
d["promotion_policy"] = "human_gate"
d["checkpoint_graph"] = {
  "execution_order": ["CP-0", "CP-1"],
  "checkpoints": [
    {"id": "CP-0", "title": "first", "scope": "do first", "acceptance_criterion_ids": ["AC-1"],
     "work_units": ["UNIT-1"],
     "risk_budget": {"max_build_passes": 2, "max_review_passes": 2, "max_repair_rounds": 1}},
    {"id": "CP-1", "title": "second", "scope": "do second", "acceptance_criterion_ids": ["AC-1"],
     "work_units": ["UNIT-1"],
     "risk_budget": {"max_build_passes": 2, "max_review_passes": 2, "max_repair_rounds": 1}},
  ],
}'
OUT_F="$($OFLOOP_BIN supervisor enqueue --db "$DB" "$REPO_F" "$RID_F" 2>&1 || true)"
if [[ "$OUT_F" == *'"ok": true'* ]] || [[ "$OUT_F" == *'"ok":true'* ]]; then
  pass "TEST F: PROGRAM packet enqueues"
else
  fail "TEST F: expected ok=true; got: $OUT_F"
fi
EMF=$(sqlite3 "$DB" "SELECT execution_mode FROM jobs WHERE run_id='$RID_F'" 2>/dev/null || echo unknown)
if [[ "$EMF" == "program" || "$EMF" == "PROGRAM" ]]; then
  pass "TEST F: PROGRAM execution_mode persisted"
else
  fail "TEST F: expected execution_mode=program; got $EMF"
fi

# ----------------------------------------------------------------------
# TEST G: adapter-failure regression — invalid packet from the trusted
# spec adapter must be refused at enqueue admission, mirroring the actual
# mature-certification failure (work_class=MATURE_FEATURE + kind=scoped).
# ----------------------------------------------------------------------
echo "TEST G: trusted spec adapter's invalid draft is refused"
IFS='|' read -r REPO_G RID_G <<< "$(mkpkg work_class MATURE_FEATURE)"
PKT_G="$REPO_G/.ownframework-loop/$RID_G/WORK_PACKET.md"
# Mirror the real failure: change work_class to MATURE_FEATURE and kind to scoped.
patch_packet "$PKT_G" 'd["work_class"] = "MATURE_FEATURE"
d["required_validation"] = [{"name": "t", "command": "true", "kind": "scoped", "expected_exit_code": 0}]'
OUT_G="$($OFLOOP_BIN supervisor enqueue --db "$DB" "$REPO_G" "$RID_G" 2>&1 || true)"
if [[ "$OUT_G" == *"pre_seal_packet_invalid"* ]]; then
  pass "TEST G: trusted adapter's invalid draft is refused"
else
  fail "TEST G: expected pre_seal_packet_invalid; got: $OUT_G"
fi
NQG=$(count_total "$DB")
NQGG=$(count_quarantined "$DB")
NQGG_PRECORRECT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM jobs WHERE run_id='$RID_G'" 2>/dev/null || echo 0)
if [[ "$NQGG" == "0" ]] && [[ "$NQGG_PRECORRECT" == "0" ]]; then
  pass "TEST G: 0 QUARANTINED rows, 0 RID_G rows (no rows mutated by refusal)"
else
  fail "TEST G: expected 0 QUARANTINED / 0 RID_G; got quarantined=$NQGG rid_g=$NQGG_PRECORRECT"
fi
# Now correct via the spec amend equivalent: rewrite the packet to be valid.
patch_packet "$PKT_G" 'd["work_class"] = "FEATURE"
d["required_validation"] = [{"name": "t", "command": "true", "kind": "fast", "expected_exit_code": 0}]'
OUT_G2="$($OFLOOP_BIN supervisor enqueue --db "$DB" "$REPO_G" "$RID_G" 2>&1 || true)"
if [[ "$OUT_G2" == *'"ok": true'* ]] || [[ "$OUT_G2" == *'"ok":true'* ]]; then
  pass "TEST G: corrected packet enqueues without resume"
else
  fail "TEST G: expected ok=true after correction; got: $OUT_G2"
fi

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------
echo
echo "v0.9.9-k summary: pass=$pass_counter fail=$fail_counter"
if [[ "$fail_counter" -gt 0 ]]; then
  exit 1
fi
exit 0
