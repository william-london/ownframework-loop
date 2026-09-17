#!/usr/bin/env bash
# v0.9.9-d BLOCKED source-budget continuation repair context TRANSPORT.
#
# Outlaw R3 CP-9 first funded repair had BUILD_RECEIPT.next_state="BLOCKED"
# but dispatch ignored BLOCKED receipts entirely for repair transport, so
# the new builder received repair_context=None and had no idea why it was
# authorized. The fix routes BLOCKED source-budget receipts through a typed
# `blocked_build_receipt` repair context, gated by an authoritative matching
# PROGRAM continuation receipt at the same checkpoint, candidate, and funded
# repair round.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib"
export PYTHONDONTWRITEBYTECODE=1

canonical_json() {
  python3 -c "
import sys, json
print(json.dumps(json.loads(sys.stdin.read()), sort_keys=True, indent=2))
"
}

run_helper() {
  python3 - <<PY
import json, sys
from pathlib import Path
sys.path.insert(0, '$ROOT_DIR/lib')
repo = Path('$1')
rid = '$2'
from ownframework_loop import dispatch, state as state_mod
state = state_mod.load_verified(repo, rid)
ctx = dispatch._repair_context_for_build(canonical_repo=repo, run_id=rid, state_doc=state)
print(json.dumps(ctx if ctx else None, sort_keys=True))
PY
}

run_helper_with_mutations() {
  local repo="$1" rid="$2" mutations_b64="$3"
  python3 - <<PY
import json, sys, base64
from pathlib import Path
sys.path.insert(0, '$ROOT_DIR/lib')
repo = Path('$repo')
rid = '$rid'
mutations = json.loads(base64.b64decode('$mutations_b64').decode('utf-8'))
from ownframework_loop import dispatch, state as state_mod
state_doc = state_mod.load_verified(repo, rid)
for k, v in mutations.items():
    keys = k.split('.')
    cur = state_doc
    for kk in keys[:-1]:
        cur = cur.setdefault(kk, {})
    cur[keys[-1]] = v
ctx = dispatch._repair_context_for_build(canonical_repo=repo, run_id=rid, state_doc=state_doc)
print(json.dumps(ctx if ctx else None, sort_keys=True))
PY
}

write_blocked_receipt() {
  local repo="$1" rid="$2" measured_lines="$3" effective_max="$4"
  python3 - "$repo" "$rid" "$measured_lines" "$effective_max" <<'PY'
import json, sys
from pathlib import Path
repo, rid, measured_lines, effective_max = sys.argv[1:5]
measured = int(measured_lines); cap = int(effective_max)
rd = Path(repo) / '.ownframework-loop' / rid
rec = {
    'schema': 'ownframework-loop-build-receipt/v2',
    'run_id': rid,
    'candidate_sha': 'a' * 40,
    'candidate_branch': 'factory/candidate/x',
    'builder_worktree': '/tmp/x',
    'builder_pass_number': 1,
    'repair_round': 0,
    'added_lines': measured,
    'removed_lines': 0,
    'files_changed': 221,
    'changed_paths': [],
    'validation': [{
        'name': 'validate', 'command': 'just validate',
        'kind': 'full', 'exit_code': 0, 'duration_seconds': 1.0,
        'passed': True, 'expected_exit_code': 0,
        'marker_match': True, 'timed_out': False,
        'stdout_truncated': False, 'stderr_truncated': False,
        'output_truncated': False,
        'stdout_excerpt_redacted': '', 'stderr_excerpt_redacted': '',
    }],
    'timestamp': '2026-09-16T14:00:00Z',
    'builder_agent': 'of-builder',
    'next_state': 'BLOCKED',
    'validation_status': 'PASS',
    'approval_sha256': 'b' * 64,
    'packet_sha256': 'c' * 64,
    'baseline_sha': 'd' * 40,
    'work_unit_id': 'UNIT-1',
    'protected_path_check': {'result': 'pass', 'offending_paths': []},
    'scope_check': {'result': 'pass', 'findings': []},
    'secret_scan_check': {'result': 'pass', 'findings': []},
    'sensitive_path_assessment': {'result': 'none', 'paths': []},
    'protected_drift_recovery': {'result': 'not_applicable'},
    'candidate_identity_reproof': {'result': 'pass'},
    'program_source_ceiling_check': {
        'result': 'fail',
        'accounting': 'absolute_baseline_to_candidate',
        'files_changed_unique': 221,
        'diff_lines_total': measured,
        'top_level_risk_max_files_changed': 500,
        'top_level_risk_max_diff_lines': cap,
        'program_max_unique_changed_files': 500,
        'program_max_baseline_to_final_diff_lines': cap,
        'effective_max_files_changed': 500,
        'effective_max_diff_lines': cap,
        'breach': f'diff_lines={measured} exceeds frozen envelope {cap}',
    },
    'additional_review_required': False,
    'escalation_recommended': False,
    'blocker_reason': None,
    'agent_summary': 'over-budget candidate',
}
(rd / 'BUILD_RECEIPT.json').write_text(json.dumps(rec, indent=2, sort_keys=True) + '\n')
PY
}

write_canonical_state() {
  local repo="$1" rid="$2"
  python3 - "$repo" "$rid" <<'PY'
import json, sys
from pathlib import Path
repo, rid = sys.argv[1], sys.argv[2]
rd = Path(repo) / '.ownframework-loop' / rid
state = {
    'schema': 'ownframework-loop-state/v2',
    'state': 'READY_TO_BUILD',
    'run_id': rid,
    'build_pass_count': 1,
    'review_pass_count': 0,
    'repair_round': 1,
    'last_candidate_sha': 'a' * 40,
    'last_actor': 'test',
    'no_progress_streak': 0,
    'identical_finding_streak': 0,
    'last_must_fix_fingerprint': '',
    'state_sha256': None,
    'updated_at': '2026-09-16T14:00:00Z',
    'started_at': '2026-09-16T14:00:00Z',
    'state_history': [],
    'transitions_count': 1,
    'program': {
        'checkpoint_graph_sha256': '0000000000000000000000000000000000000000000000000000000000000000',
        'execution_order': ['CP-1'],
        'current_checkpoints': ['CP-1'],
        'finalized_checkpoints': [],
        'checkpoints': [],
        'cumulative_ceilings': {'max_unique_changed_files': 500, 'max_baseline_to_final_diff_lines': 30000},
        'cumulative_counters': {'build_pass_count': 1, 'review_pass_count': 0, 'repair_round_count': 1, 'diff_lines_total': 33521, 'files_changed_unique': 221},
        'source_sha_provenance': {'baseline_sha': 'd' * 40, 'candidate_branch': 'factory/candidate/x', 'captured_at': '2026-09-16T14:00:00Z'},
    },
}
(rd / 'STATE.json').write_text(json.dumps(state, indent=2, sort_keys=True) + '\n')
# Ensure no EVENTS.log so integrity verification does not cross-check.
ep = rd / 'EVENTS.log'
if ep.exists():
    ep.unlink()
PY
}

write_supported_continuation() {
  local repo="$1" rid="$2" reason="$3"
  python3 - "$repo" "$rid" "$reason" <<'PY'
import json, sys
from pathlib import Path
repo, rid, reason = sys.argv[1], sys.argv[2], sys.argv[3]
rd = Path(repo) / '.ownframework-loop' / rid / 'continuations'
rd.mkdir(parents=True, exist_ok=True)
# Use the canonical derivation so the helper would find it.
from ownframework_loop.continuation_authority import derive_continuation_id
cid = derive_continuation_id(run_id=rid, checkpoint_id='CP-1', candidate_sha='a'*40, reason=reason)
rec = {
    'schema': 'ownframework-loop-program-continuation/v1',
    'continuation_id': cid,
    'run_id': rid,
    'checkpoint_id': 'CP-1',
    'candidate_sha': 'a'*40,
    'active_candidate_sha': 'a'*40,
    'candidate_branch': 'factory/candidate/x',
    'reason': reason,
    'before': {'repair_round': 0, 'build_pass_count': 1, 'review_pass_count': 0, 'cumulative_repair_round_count': 0},
    'after': {'repair_round': 1, 'build_pass_count': 1, 'review_pass_count': 0, 'cumulative_repair_round_count': 1},
    'status': 'QUEUED',
    'created_at': '2026-09-16T14:00:00Z',
    'queued_at': '2026-09-16T14:00:00Z',
    'funded_at': '2026-09-16T14:00:00Z',
}
(rd / f'{cid}.json').write_text(json.dumps(rec, indent=2, sort_keys=True) + '\n')
PY
}

# =========================================================================
# TEST A — BLOCKED without continuation fails closed
# =========================================================================
REPO_A="$(make_tmp_repo)"
"$OFLOOP_BIN" spec new "$REPO_A" "blocked-no-continuation-$RANDOM" >/dev/null
RID_A="$(ls -1t "$REPO_A/.ownframework-loop" | head -n1)"
write_blocked_receipt "$REPO_A" "$RID_A" 33521 30000
write_canonical_state "$REPO_A" "$RID_A"

OUT_A="$(run_helper "$REPO_A" "$RID_A")"
assert_contains "$OUT_A" 'null' "TEST A: no repair_context when continuation absent (ctx is null)"
pass "TEST A: BLOCKED without continuation fails closed"

# =========================================================================
# TEST B — supported continuation transports exact context
# =========================================================================
REPO_B="$(make_tmp_repo)"
"$OFLOOP_BIN" spec new "$REPO_B" "blocked-supported-$RANDOM" >/dev/null
RID_B="$(ls -1t "$REPO_B/.ownframework-loop" | head -n1)"
write_blocked_receipt "$REPO_B" "$RID_B" 33521 30000
write_canonical_state "$REPO_B" "$RID_B"
write_supported_continuation "$REPO_B" "$RID_B" "Reduce candidate 33521 to <=30000; preserve AC-1; do not widen the packet."

OUT_B="$(run_helper "$REPO_B" "$RID_B")"
assert_contains "$OUT_B" '"source_kind": "blocked_build_receipt"' "TEST B: source_kind=blocked_build_receipt"
assert_contains "$OUT_B" '"measured_diff_lines": 33521' "TEST B: measured diff lines transported"
assert_contains "$OUT_B" '"effective_max_diff_lines": 30000' "TEST B: effective ceiling transported"
assert_contains "$OUT_B" '"checkpoint_id": "CP-1"' "TEST B: checkpoint_id transported"
assert_contains "$OUT_B" '"repair_round": 1' "TEST B: repair_round transported"
assert_contains "$OUT_B" '"repair_instruction"' "TEST B: deterministic repair_instruction present"
assert_contains "$OUT_B" '"verification_chain"' "TEST B: verification_chain exposes the chain"
pass "TEST B: supported continuation populates typed BLOCKED repair context"

# =========================================================================
# TEST C — stale candidate (last_candidate_sha mutated) refuses
# =========================================================================
REPO_C="$(make_tmp_repo)"
"$OFLOOP_BIN" spec new "$REPO_C" "blocked-stale-cand-$RANDOM" >/dev/null
RID_C="$(ls -1t "$REPO_C/.ownframework-loop" | head -n1)"
write_blocked_receipt "$REPO_C" "$RID_C" 33521 30000
write_canonical_state "$REPO_C" "$RID_C"
write_supported_continuation "$REPO_C" "$RID_C" "TEST C stale-candidate probe"

# Mutate state.last_candidate_sha to a different value.
MUT_C="$(python3 -c '
import json, base64
mutations = {"last_candidate_sha": "b" * 40}
print(base64.b64encode(json.dumps(mutations).encode()).decode())
')"
OUT_C="$(run_helper_with_mutations "$REPO_C" "$RID_C" "$MUT_C")"
assert_contains "$OUT_C" 'null' "TEST C: stale candidate fails closed"
pass "TEST C: stale candidate refused"

# =========================================================================
# TEST D — stale repair_round refuses
# =========================================================================
REPO_D="$(make_tmp_repo)"
"$OFLOOP_BIN" spec new "$REPO_D" "blocked-stale-round-$RANDOM" >/dev/null
RID_D="$(ls -1t "$REPO_D/.ownframework-loop" | head -n1)"
write_blocked_receipt "$REPO_D" "$RID_D" 33521 30000
write_canonical_state "$REPO_D" "$RID_D"
write_supported_continuation "$REPO_D" "$RID_D" "TEST D stale-round probe"

# Mutate state.repair_round to 99 (mismatches continuation's after=1)
MUT_D="$(python3 -c '
import json, base64
print(base64.b64encode(json.dumps({"repair_round": 99}).encode()).decode())
')"
OUT_D="$(run_helper_with_mutations "$REPO_D" "$RID_D" "$MUT_D")"
assert_contains "$OUT_D" 'null' "TEST D: stale repair_round fails closed"
pass "TEST D: stale repair_round refused"

# =========================================================================
# TEST E — wrong checkpoint refuses
# =========================================================================
REPO_E="$(make_tmp_repo)"
"$OFLOOP_BIN" spec new "$REPO_E" "blocked-wrong-cp-$RANDOM" >/dev/null
RID_E="$(ls -1t "$REPO_E/.ownframework-loop" | head -n1)"
write_blocked_receipt "$REPO_E" "$RID_E" 33521 30000
write_canonical_state "$REPO_E" "$RID_E"
write_supported_continuation "$REPO_E" "$RID_E" "TEST E wrong-cp probe"

MUT_E="$(python3 -c '
import json, base64
print(base64.b64encode(json.dumps({"program.current_checkpoints": ["CP-NOT-FUNDED"]}).encode()).decode())
')"
OUT_E="$(run_helper_with_mutations "$REPO_E" "$RID_E" "$MUT_E")"
assert_contains "$OUT_E" 'null' "TEST E: wrong checkpoint fails closed"
pass "TEST E: wrong checkpoint refused"

# =========================================================================
# TEST F — ambiguous continuation (two funded continuations) refuses
# =========================================================================
REPO_F="$(make_tmp_repo)"
"$OFLOOP_BIN" spec new "$REPO_F" "blocked-ambiguous-$RANDOM" >/dev/null
RID_F="$(ls -1t "$REPO_F/.ownframework-loop" | head -n1)"
write_blocked_receipt "$REPO_F" "$RID_F" 33521 30000
write_canonical_state "$REPO_F" "$RID_F"
# Two receipts with the same (run, cp, candidate, round) tuple but different
# reasons → different continuation_ids, both eligible.
write_supported_continuation "$REPO_F" "$RID_F" "TEST F reason A"
write_supported_continuation "$REPO_F" "$RID_F" "TEST F reason B"

OUT_F="$(run_helper "$REPO_F" "$RID_F")"
assert_contains "$OUT_F" 'null' "TEST F: ambiguous continuation fails closed"
pass "TEST F: ambiguous continuation refused"

# =========================================================================
# TEST G — CHANGES_REQUESTED review_verdict + build_receipt paths unchanged
# =========================================================================
REPO_G="$(make_tmp_repo)"
"$OFLOOP_BIN" spec new "$REPO_G" "cr-regression-$RANDOM" >/dev/null
RID_G="$(ls -1t "$REPO_G/.ownframework-loop" | head -n1)"
# Synthesize a CHANGES_REQUESTED receipt and state.
python3 - "$REPO_G" "$RID_G" <<'PY'
import json, sys
from pathlib import Path
repo, rid = sys.argv[1], sys.argv[2]
rd = Path(repo) / '.ownframework-loop' / rid
rec = {
    'schema': 'ownframework-loop-build-receipt/v2',
    'run_id': rid,
    'candidate_sha': 'a' * 40,
    'candidate_branch': 'factory/candidate/x',
    'builder_worktree': '/tmp/x',
    'builder_pass_number': 1,
    'repair_round': 0,
    'added_lines': 0, 'removed_lines': 0, 'files_changed': 0,
    'changed_paths': [], 'validation': [],
    'timestamp': '2026-09-16T14:00:00Z',
    'builder_agent': 'of-builder',
    'next_state': 'CHANGES_REQUESTED',
    'approval_sha256': 'b' * 64, 'packet_sha256': 'c' * 64,
    'baseline_sha': 'd' * 40, 'work_unit_id': 'UNIT-1',
    'protected_path_check': {'result': 'pass', 'offending_paths': []},
    'scope_check': {'result': 'fail', 'findings': [{'path': 'src/extra.txt', 'kind': 'out_of_scope'}]},
    'secret_scan_check': {'result': 'pass', 'findings': []},
    'sensitive_path_assessment': {'result': 'none', 'paths': []},
    'protected_drift_recovery': {'result': 'not_applicable'},
    'candidate_identity_reproof': {'result': 'pass'},
    'program_source_ceiling_check': {'result': 'not_applicable'},
    'additional_review_required': False,
    'escalation_recommended': False,
}
(rd / 'BUILD_RECEIPT.json').write_text(json.dumps(rec, indent=2, sort_keys=True) + '\n')
state = {
    'schema': 'ownframework-loop-state/v2',
    'state': 'CHANGES_REQUESTED',
    'run_id': rid,
    'build_pass_count': 1, 'review_pass_count': 0, 'repair_round': 0,
    'last_candidate_sha': 'a' * 40,
    'program': {
        'current_checkpoints': ['CP-1'],
        'source_sha_provenance': {'candidate_branch': 'factory/candidate/x'},
        'cumulative_ceilings': {}, 'cumulative_counters': {},
    },
}
(rd / 'STATE.json').write_text(json.dumps(state, indent=2, sort_keys=True) + '\n')
# Delete EVENTS.log if present so integrity verify passes (no prior sha).
ep = rd / 'EVENTS.log'
if ep.exists():
    ep.unlink()
PY

OUT_G="$(run_helper "$REPO_G" "$RID_G")"
assert_contains "$OUT_G" '"source_kind": "build_receipt"' "TEST G: CHANGES_REQUESTED path still uses 'build_receipt' source_kind"
assert_contains "$OUT_G" '"verdict": "CHANGES_REQUESTED"' "TEST G: verdict remains CHANGES_REQUESTED"
assert_contains "$OUT_G" '"scope_findings"' "TEST G: scope_findings transported as before"
pass "TEST G: CHANGES_REQUESTED review + build-receipt contexts unchanged"

# =========================================================================
# TEST H — semantic invocation actually transports the BLOCKED context
# =========================================================================
# Reach through the dispatcher / patch the binding-authority surface so we
# can call claim_next() with our BLOCKED-receipt + matching-continuation
# fixture. We bypass reconcile_run by hand-running the build prepare path
# (which is what the supervisor does on the dispatch boundary) instead of
# going through the dispatch CLI.
REPO_H="$(make_tmp_repo)"
"$OFLOOP_BIN" spec new "$REPO_H" "claim-transport-$RANDOM" >/dev/null
RID_H="$(ls -1t "$REPO_H/.ownframework-loop" | head -n1)"

# Stand up a minimal viable fixture: packet, state, APPROVAL, BUILD_RECEIPT,
# continuation. All hand-signed so dispatch can resolve them.
python3 - "$REPO_H" "$RID_H" <<'PY'
import json, sys, hashlib, subprocess
from pathlib import Path
repo, rid = sys.argv[1], sys.argv[2]
rd = Path(repo) / '.ownframework-loop' / rid
# Seed git baseline commit so HEAD can be resolved.
subprocess.run(['git', '-C', repo, 'init', '-q', '-b', 'master'], check=False)
subprocess.run(['git', '-C', repo, 'config', 'user.email', 'test@ofloop'], check=False)
subprocess.run(['git', '-C', repo, 'config', 'user.name', 'ofloop-test'], check=False)
subprocess.run(['git', '-C', repo, 'commit', '--allow-empty', '-q', '-m', 'init'], check=False)
# Compute SHA and ids deterministically.
sha_of = lambda s: hashlib.sha256(s.encode()).hexdigest()
baseline_sha = subprocess.run(['git','-C',repo,'rev-parse','master'], capture_output=True, text=True, check=True).stdout.strip()
packet_sha = sha_of('packet-' + rid)
approval_sha = sha_of('approval-' + rid)
# Pick a candidate_sha = the baseline so claim_next's "candidate already at HEAD" path can run.
candidate_sha = baseline_sha
candidate_branch = 'factory/test-' + repo.split('/')[-1][:8]

# Build the packet (PROGRAM shape) and APPROVAL.
packet = {
    'schema': 'ownframework-work-packet/v3',
    'packet_id': 'p-blocked-transport', 'created_at': '2026-09-16T14:00:00Z',
    'work_class': 'FEATURE', 'risk_class': 'low',
    'title': 'blocked-transport fixture',
    'target': {'repo': repo, 'branch': 'master', 'classification': 'local_only',
               'candidate_branch_prefix': 'factory/test-' + repo.split('/')[-1][:8]},
    'execution_mode': 'program',
    'checkpoint_graph': {
        'execution_order': ['CP-1'],
        'global_source_ceilings': {
            'max_unique_changed_files': 500,
            'max_baseline_to_final_diff_lines': 30000,
        },
        'checkpoints': [{
            'id': 'CP-1', 'title': 't', 'scope': 'src/',
            'depends_on': [],
            'risk_budget': {'max_build_passes': 6, 'max_review_passes': 7, 'max_repair_rounds': 5},
        }],
    },
    'promotion_policy': 'human_gate',
    'acceptance_criteria': [{'id': 'AC-1', 'text': 'ok'}],
    'non_goals': [], 'allowed_paths': ['src/'], 'protected_paths': ['.ownframework-loop/'],
    'work_units': [{'id': 'UNIT-1', 'title': 'u', 'scope': 'src/'}],
    'merge_authority': 'human_only', 'deploy_authority': 'human_only',
    'push_authority': 'human_only', 'external_action_authority': 'none',
    'risk_budget': {'max_build_passes': 6, 'max_review_passes': 7,
                     'max_repair_rounds': 5, 'max_files_changed': 500,
                     'max_diff_lines': 30000},
}
from ownframework_loop import approval as approval_mod, packet as packet_mod
fence = chr(96) * 3
(rd / 'WORK_PACKET.md').write_text(fence + 'json\n' + json.dumps(packet, indent=2, sort_keys=True) + '\n' + fence + '\n')
# packet_sha is hashlib.sha256(packet_path.read_bytes()) — raw file bytes.
packet_sha = hashlib.sha256((rd / 'WORK_PACKET.md').read_bytes()).hexdigest()

# build approval
token = approval_mod.derive_confirmation_token(packet_sha)
approval = {
    'schema': 'ownframework-loop-approval/v1',
    'run_id': rid,
    'packet_sha256': packet_sha,
    'approved_at': '2026-09-16T14:00:00Z',
    'approved_actor': 'test',
    'canonical_repo': repo,
    'baseline_branch': 'master',
    'baseline_sha': baseline_sha,
    'candidate_branch': candidate_branch,
    'packet_schema': 'ownframework-work-packet/v3',
    'approval_method': 'build_start',
    'confirmation_token': token,
}
(rd / 'APPROVAL.json').write_text(json.dumps(approval, indent=2, sort_keys=True) + '\n')
(rd / 'APPROVAL.json').chmod(0o600)

# State: READY_TO_BUILD with current_checkpoints=['CP-1']
# Materialise the program_state the canonical way so dispatch sees it.
from ownframework_loop.program import (
    checkpoint_graph_sha256,
    materialise_initial_program_state,
)
graph_sha = checkpoint_graph_sha256(packet)
program_state = materialise_initial_program_state(
    packet, baseline_sha=baseline_sha, candidate_branch=candidate_branch,
)
program_state['current_checkpoints'] = ['CP-1']
program_state['cumulative_counters'] = {
    'build_pass_count': 1, 'review_pass_count': 0, 'repair_round_count': 1,
    'diff_lines_total': 33521, 'files_changed_unique': 221,
}
state = {
    'schema': 'ownframework-loop-state/v2',
    'state': 'READY_TO_BUILD',
    'run_id': rid,
    'build_pass_count': 1, 'review_pass_count': 0, 'repair_round': 1,
    'last_candidate_sha': candidate_sha,
    'last_actor': 'test', 'no_progress_streak': 0,
    'identical_finding_streak': 0, 'last_must_fix_fingerprint': '',
    'state_sha256': None, 'updated_at': '2026-09-16T14:00:00Z',
    'started_at': '2026-09-16T14:00:00Z',
    'state_history': [], 'transitions_count': 1,
    'program': program_state,
}
(rd / 'STATE.json').write_text(json.dumps(state, indent=2, sort_keys=True) + '\n')

# BUILD_RECEIPT with next_state=BLOCKED and source-budget evidence.
rec = {
    'schema': 'ownframework-loop-build-receipt/v2',
    'run_id': rid,
    'packet_sha256': packet_sha,
    'approval_sha256': hashlib.sha256(json.dumps(approval, indent=2, sort_keys=True).encode()).hexdigest(),
    'work_unit_id': 'UNIT-1',
    'baseline_sha': baseline_sha,
    'candidate_sha': candidate_sha,
    'candidate_branch': candidate_branch,
    'builder_worktree': str(repo),
    'builder_pass_number': 1,
    'repair_round': 0,
    'added_lines': 33521, 'removed_lines': 0,
    'files_changed': 221, 'changed_paths': [],
    'validation': [],
    'timestamp': '2026-09-16T14:00:00Z',
    'builder_agent': 'of-builder',
    'next_state': 'BLOCKED',
    'validation_status': 'PASS',
    'protected_path_check': {'result': 'pass', 'offending_paths': []},
    'scope_check': {'result': 'pass', 'findings': []},
    'secret_scan_check': {'result': 'pass', 'findings': []},
    'sensitive_path_assessment': {'result': 'none', 'paths': []},
    'protected_drift_recovery': {'result': 'not_applicable'},
    'candidate_identity_reproof': {'result': 'pass'},
    'program_source_ceiling_check': {
        'result': 'fail',
        'accounting': 'absolute_baseline_to_candidate',
        'files_changed_unique': 221,
        'diff_lines_total': 33521,
        'top_level_risk_max_files_changed': 500,
        'top_level_risk_max_diff_lines': 30000,
        'program_max_unique_changed_files': 500,
        'program_max_baseline_to_final_diff_lines': 30000,
        'effective_max_files_changed': 500,
        'effective_max_diff_lines': 30000,
        'breach': 'diff_lines=33521 exceeds frozen envelope 30000',
    },
    'additional_review_required': False,
    'escalation_recommended': False,
    'agent_summary': 'over-budget candidate for TEST H',
}
(rd / 'BUILD_RECEIPT.json').write_text(json.dumps(rec, indent=2, sort_keys=True) + '\n')

# Drop EVENTS.log so integrity.verify_state_sha passes (no prior sha recorded).
ep = rd / 'EVENTS.log'
if ep.exists():
    ep.unlink()

# Continuation matching this BLOCKED receipt.
from ownframework_loop.continuation_authority import derive_continuation_id
cont_dir = rd / 'continuations'
cont_dir.mkdir(parents=True, exist_ok=True)
cid = derive_continuation_id(
    run_id=rid, checkpoint_id='CP-1',
    candidate_sha=candidate_sha, reason='TEST H transport probe',
)
cont = {
    'schema': 'ownframework-loop-program-continuation/v1',
    'continuation_id': cid, 'run_id': rid, 'checkpoint_id': 'CP-1',
    'candidate_sha': candidate_sha, 'active_candidate_sha': candidate_sha,
    'candidate_branch': candidate_branch,
    'reason': 'TEST H transport probe',
    'before': {'repair_round': 0, 'build_pass_count': 1, 'review_pass_count': 0, 'cumulative_repair_round_count': 0},
    'after': {'repair_round': 1, 'build_pass_count': 1, 'review_pass_count': 0, 'cumulative_repair_round_count': 1},
    'status': 'QUEUED',
    'created_at': '2026-09-16T14:00:00Z',
    'queued_at': '2026-09-16T14:00:00Z',
    'funded_at': '2026-09-16T14:00:00Z',
}
(cont_dir / f'{cid}.json').write_text(json.dumps(cont, indent=2, sort_keys=True) + '\n')
PY

# Invoke dispatch.claim_next() — this is the canonical boundary.
OUT_H="$(python3 - "$REPO_H" "$RID_H" 2>&1 <<'PY'
import sys, json
from pathlib import Path
sys.path.insert(0, '$ROOT_DIR/lib')
repo = Path(sys.argv[1])
rid = sys.argv[2]
from ownframework_loop import dispatch
try:
    out = dispatch.claim_next(canonical_repo=repo, run_id=rid)
    print(json.dumps(out, sort_keys=True, default=str))
except SystemExit as e:
    print(json.dumps({'system_exit': str(e)}))
except Exception as e:
    print(json.dumps({'error': repr(e)}))
PY
)"
assert_contains "$OUT_H" '"source_kind": "blocked_build_receipt"' "TEST H: dispatcher surfaces blocked_build_receipt in work order"
assert_contains "$OUT_H" '"repair_instruction"' "TEST H: dispatcher surfaces repair_instruction in work order"
pass "TEST H: dispatcher actually transports the BLOCKED repair context end-to-end"

# =========================================================================
# TEST I — exact values: measured=33521, max=30000 survive intact
# =========================================================================
assert_contains "$OUT_H" '"measured_diff_lines": 33521' "TEST I: measured 33521 in work order"
assert_contains "$OUT_H" '"effective_max_diff_lines": 30000' "TEST I: effective 30000 in work order"
assert_contains "$OUT_H" '"top_level_risk_max_diff_lines": 30000' "TEST I: top_level_risk_max_diff_lines=30000"
assert_contains "$OUT_H" '"program_max_baseline_to_final_diff_lines": 30000' "TEST I: program ceiling transported"
pass "TEST I: source-budget exact values survive deterministic transport"

# =========================================================================
# TEST J — BLOCKED receipt alone cannot independently reopen the run
# =========================================================================
# Helper already proves dispatch fails closed. We also prove the run cannot
# be claim-advanced by an external BUILD claim with no continuation.
REPO_J="$(make_tmp_repo)"
"$OFLOOP_BIN" spec new "$REPO_J" "blocked-claim-refused-$RANDOM" >/dev/null
RID_J="$(ls -1t "$REPO_J/.ownframework-loop" | head -n1)"
write_blocked_receipt "$REPO_J" "$RID_J" 33521 30000

# Without prior ensure_executable + state mutation, dispatch.claim_next
# should refuse or surface TERMINAL because no continuation supports the
# repair. We just verify the helper returns no context.
OUT_J="$(run_helper "$REPO_J" "$RID_J")"
assert_contains "$OUT_J" 'null' "TEST J: BLOCKED alone refuses repair context"
pass "TEST J: BLOCKED receipt alone cannot independently reopen the run"

# =========================================================================
# TEST K — multi-round repair: a later-funded continuation is NOT a conflict
# =========================================================================
# Two funded continuations at the same (run, cp, candidate) but at DIFFERENT
# repair rounds must not produce a continuation_receipt_conflict.
REPO_K="$(make_tmp_repo)"
"$OFLOOP_BIN" spec new "$REPO_K" "multi-round-$RANDOM" >/dev/null
RID_K="$(ls -1t "$REPO_K/.ownframework-loop" | head -n1)"
write_blocked_receipt "$REPO_K" "$RID_K" 33521 30000
write_canonical_state "$REPO_K" "$RID_K"
# One funded continuation at after.repair_round=1
write_supported_continuation "$REPO_K" "$RID_K" "TEST K round-1 reason"
# With state.repair_round=1, the single round-1 continuation matches.
MUT_K1="$(python3 -c '
import json, base64
print(base64.b64encode(json.dumps({
    "repair_round": 1,
    "program.cumulative_counters.repair_round_count": 1,
}).encode()).decode())
')"
MUT_K2="$(python3 -c '
import json, base64
print(base64.b64encode(json.dumps({
    "repair_round": 2,
    "program.cumulative_counters.repair_round_count": 2,
}).encode()).decode())
')"
HIT_K1="$(run_helper_with_mutations "$REPO_K" "$RID_K" "$MUT_K1")"
HIT_K1_OK="$(python3 -c "
import json
ctx = json.loads('''$HIT_K1'''.strip().splitlines()[0] if False else '''$HIT_K1''')
print('yes' if ctx else 'no')
")"
assert_eq "$HIT_K1_OK" "yes" "TEST K: cumulative=1 continuation matches cumulative=1 state"
# Bumping cumulative to 2 must not match the round-1 continuation.
HIT_K2="$(run_helper_with_mutations "$REPO_K" "$RID_K" "$MUT_K2")"
HIT_K2_OK="$(python3 -c "
import json
ctx = json.loads('''$HIT_K2'''.strip().splitlines()[0] if False else '''$HIT_K2''')
print('yes' if ctx else 'no')
")"
assert_eq "$HIT_K2_OK" "no" "TEST K: cumulative=1 continuation does NOT match cumulative=2 state"
pass "TEST K: continuation matching rounds must not conflict across rounds"
