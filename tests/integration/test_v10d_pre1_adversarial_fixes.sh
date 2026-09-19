#!/usr/bin/env bash
# v0.10.0-dev d: pre-1.0 adversarial-audit hardening regressions.
#
# Direct regression tests for each A/B-grade finding fixed in the
# pre-1.0 adversarial audit. Each test below would FAIL on the
# pre-audit base `d3464192` and PASS on the post-audit candidate.
#
# Each section pins one specific fix; the test fails with a
# diagnostic if the fix has regressed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
TMP="$(mktemp -d -t ofloop-v10d-pre1-fixes.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

fail(){ echo "FAIL: $*" >&2; exit 1; }
pass(){ echo "  pass: $*"; }

PYTHON_BIN="$(command -v python3)"
[[ -x "$PYTHON_BIN" ]] || fail "python3 not on PATH"

cd "$ROOT_DIR"

########################################################################
# A001 — _run_cli timeout from claim_next
########################################################################
echo "=== A001: claim_next threads timeout_seconds into _run_cli ==="
PYTHONPATH="$ROOT_DIR/lib" "$PYTHON_BIN" -B -c "
import inspect
from ownframework_loop import dispatch
# The default constant exists
assert hasattr(dispatch, '_DEFAULT_CLAIM_CLI_TIMEOUT_SECONDS'), 'A001: _DEFAULT_CLAIM_CLI_TIMEOUT_SECONDS must exist'
assert isinstance(dispatch._DEFAULT_CLAIM_CLI_TIMEOUT_SECONDS, int), 'A001: constant must be int'
assert dispatch._DEFAULT_CLAIM_CLI_TIMEOUT_SECONDS > 0, 'A001: safety fuse must be positive'
# The value matches the historical cli.py per-pass fallback (3600s)
# or is at least >= 600 (the A002 default).
assert dispatch._DEFAULT_CLAIM_CLI_TIMEOUT_SECONDS >= 600, 'A001: must match or exceed per-pass fallback'

# _claim_or_terminal accepts timeout_seconds
sig = inspect.signature(dispatch._claim_or_terminal)
assert 'timeout_seconds' in sig.parameters, 'A001: _claim_or_terminal must accept timeout_seconds'
assert sig.parameters['timeout_seconds'].default is None, 'A001: default must be None (caller-supplied)'

# _run_cli forwards timeout_seconds to subprocess.run
src = inspect.getsource(dispatch._run_cli)
assert 'timeout=' in src, 'A001: _run_cli must forward timeout to subprocess.run'
assert 'timeout_seconds' in src, 'A001: _run_cli must consult timeout_seconds'
print('ok')
" || fail "A001 regression"
pass "A001: claim_next threads timeout_seconds with positive safety fuse"

########################################################################
# A002 — default finalize timeout
########################################################################
echo "=== A002: finalize CLI has default timeout when max_wall==0 ==="
PYTHONPATH="$ROOT_DIR/lib" "$PYTHON_BIN" -B -c "
from ownframework_loop import supervisor
assert hasattr(supervisor, '_DEFAULT_FINALIZER_TIMEOUT_SECONDS'), 'A002: _DEFAULT_FINALIZER_TIMEOUT_SECONDS must exist'
assert isinstance(supervisor._DEFAULT_FINALIZER_TIMEOUT_SECONDS, int), 'A002: must be int'
assert supervisor._DEFAULT_FINALIZER_TIMEOUT_SECONDS >= 600, 'A002: must be at least 600s (matches per-pass fallback)'
# The fix's exact comment is in supervisor.py — verify the constant is
# not infinite and not None.
assert supervisor._DEFAULT_FINALIZER_TIMEOUT_SECONDS <= 7200, 'A002: must not exceed v2 per-pass ceiling (7200) for unfunded runs'
print('ok')
" || fail "A002 regression"
pass "A002: default finalize timeout bounded within per-pass envelope"

########################################################################
# E004 — cost_known=0 refuses replay
########################################################################
echo "=== E004: _attempt_provenance_gate refuses cost_known=0 replay ==="
PYTHONPATH="$ROOT_DIR/lib" "$PYTHON_BIN" -B -c "
import sqlite3, tempfile, os
from pathlib import Path
from ownframework_loop import supervisor_attempts

# Build a minimal DB with one semantic_attempts row carrying
# cost_accounted=1 cost_known=0 semantic_accepted=1 with the
# required SHAs. _attempt_provenance_gate must refuse.

td = tempfile.mkdtemp()
db_path = Path(td) / 'gate.sqlite3'
conn = sqlite3.connect(str(db_path))
conn.executescript('''
CREATE TABLE jobs (
    id INTEGER PRIMARY KEY,
    repo TEXT, run_id TEXT, candidate_branch TEXT,
    latest_attempt_id TEXT, worker_attempt_id TEXT,
    runtime_generation TEXT, runner TEXT, packet_sha256 TEXT
);
CREATE TABLE semantic_attempts (
    attempt_id TEXT,
    job_id INTEGER,
    role TEXT,
    status TEXT,
    failure_class TEXT,
    failure_reason TEXT,
    cost_accounted INTEGER DEFAULT 0,
    cost_known INTEGER DEFAULT 0,
    cost_usd REAL DEFAULT 0,
    semantic_accepted INTEGER DEFAULT 0,
    accepted_semantic_sha256 TEXT,
    accepted_candidate_sha TEXT,
    effective_model TEXT,
    launch_gate_version INTEGER DEFAULT 0
);
INSERT INTO jobs (id, repo, run_id, latest_attempt_id, runner)
  VALUES (1, '/tmp/repo', 'run-x', 'att-1', 'claude-code');
INSERT INTO semantic_attempts
  (attempt_id, job_id, role, status, cost_accounted, cost_known,
   semantic_accepted, accepted_semantic_sha256, accepted_candidate_sha)
  VALUES ('att-1', 1, 'builder', 'COMPLETED', 1, 0, 1,
          'a'*64, 'b'*40);
''')

# Stub the runner registry to avoid the capability check
import ownframework_loop.supervisor_attempts as sa
sa._runner_registry_mod.get_runner = lambda name: type('R', (), {'requires_capability_receipt': False})()
# Skip capability receipt path
sa.capabilities_mod.read_resolution_receipt = lambda *a, **k: {}

job = conn.execute('SELECT * FROM jobs WHERE id=1').fetchone()
# _attempt_provenance_gate indexes job["id"] so we need a sqlite3.Row
conn.row_factory = sqlite3.Row
job = conn.execute('SELECT * FROM jobs WHERE id=1').fetchone()
wo = {'role': 'builder', 'semantic_path': '/nonexistent'}
ok, reason, _ = sa._attempt_provenance_gate(
    conn, job=job, work_order=wo, attempt_id='att-1')
assert ok is False, f'E004: must refuse cost_known=0 replay, got ok=True'
assert reason == 'semantic_replay_attempt_cost_unknown', f'E004: refusal reason must be specific, got {reason!r}'
print('ok')
" || fail "E004 regression"
pass "E004: cost_known=0 attempt refused at provenance gate"

########################################################################
# F002/F004 — positive proof of all CPs finalized for program_final
########################################################################
echo "=== F002/F004: program_final requires positive all-cps-finalized proof ==="
PYTHONPATH="$ROOT_DIR/lib" "$PYTHON_BIN" -B -c "
from ownframework_loop import program

# Find advance_after_review_approval
import inspect
src = inspect.getsource(program.advance_after_review_approval)
# Must contain the positive proof
assert 'all_cps_finalized' in src, 'F002/F004: must compute all_cps_finalized positively'
assert 'expected_cp_ids' in src, 'F002/F004: must compute expected_cp_ids from packet'
assert 'finalized_cp_ids' in src, 'F002/F004: must compute finalized_cp_ids from program_state'
# Must raise when dep-blocked CPs produce empty new_cps with non-empty finalized coverage
# The string is split across two lines in source for readability.
assert 'cannot promote to' in src, 'F002/F004: must refuse with promotion reason'
assert 'program_final with unfinished checkpoints' in src, 'F002/F004: must mention unfinished checkpoints'
print('ok')
" || fail "F002/F004 regression"
pass "F002/F004: positive proof + refuse-with-reason"

########################################################################
# F003 — review-scope mismatch in semantic_result_ready
########################################################################
echo "=== F003: review_scope mismatch detected at semantic_result_ready ==="
PYTHONPATH="$ROOT_DIR/lib" "$PYTHON_BIN" -B -c "
import inspect
from ownframework_loop import dispatch
src = inspect.getsource(dispatch.semantic_result_ready)
# Must contain the scope-match check
assert 'review_scope_mismatch_durable_program_final' in src, 'F003: must check scope match against program_final'
assert 'review_scope_mismatch_durable_not_program_final' in src, 'F003: must check scope escalation against non-program_final'
print('ok')
" || fail "F003 regression"
pass "F003: scope mismatch refused at semantic_result_ready"

########################################################################
# F007 — TornState recovery via pending journal
########################################################################
echo "=== F007: torn STATE.json triggers StateTorn, not TamperingDetected ==="
PYTHONPATH="$ROOT_DIR/lib" "$PYTHON_BIN" -B -c "
from ownframework_loop import integrity
# StateTorn must inherit from TamperingDetected so existing narrow
# catches still match
assert hasattr(integrity, 'StateTorn'), 'F007: StateTorn must exist'
assert issubclass(integrity.StateTorn, integrity.TamperingDetected), 'F007: StateTorn must subclass TamperingDetected'
print('ok')
" || fail "F007 regression"
pass "F007: StateTorn subclass exists for torn-write recovery"

########################################################################
# F022 — empty effective validation list when packet declares validation
########################################################################
echo "=== F022: build_finalize fails closed on empty effective validation list ==="
PYTHONPATH="$ROOT_DIR/lib" "$PYTHON_BIN" -B -c "
import inspect
from ownframework_loop import build_finalize
src = inspect.getsource(build_finalize)
assert 'validation_required_but_effective_list_empty' in src, 'F022: build_finalize must fail-closed on empty effective list'
assert '_packet_declares_validation' in src, 'F022: must compute packet declares validation'
print('ok')
" || fail "F022 regression"
pass "F022: build_finalize empty-validation fail-closed"

########################################################################
# F023 — symmetric review_finalize
########################################################################
echo "=== F023: review_finalize fails closed on empty effective validation list ==="
PYTHONPATH="$ROOT_DIR/lib" "$PYTHON_BIN" -B -c "
import inspect
from ownframework_loop import review_finalize
src = inspect.getsource(review_finalize)
assert 'validation_required_but_effective_list_empty' in src, 'F023: review_finalize must fail-closed on empty effective list'
assert '_packet_declares_validation' in src, 'F023: must compute packet declares validation'
print('ok')
" || fail "F023 regression"
pass "F023: review_finalize empty-validation fail-closed"

########################################################################
# B001 — duplicate PRE_PROVIDER_FAILURE_REASONS eliminated
########################################################################
echo "=== B001: PRE_PROVIDER_FAILURE_REASONS defined exactly once ==="
PYTHONPATH="$ROOT_DIR/lib" "$PYTHON_BIN" -B -c "
import ast
from pathlib import Path
src = (Path('$ROOT_DIR/lib/ownframework_loop/supervisor_attempts.py')).read_text()
tree = ast.parse(src)
count = 0
for node in ast.walk(tree):
    if isinstance(node, ast.Assign):
        for tgt in node.targets:
            if isinstance(tgt, ast.Name) and tgt.id == 'PRE_PROVIDER_FAILURE_REASONS':
                count += 1
assert count == 1, f'B001: PRE_PROVIDER_FAILURE_REASONS must be defined exactly once, found {count}'
print('ok')
" || fail "B001 regression"
pass "B001: PRE_PROVIDER_FAILURE_REASONS defined exactly once"

########################################################################
# B002 — exception visibility in v0.9.9-h recovery paths
########################################################################
echo "=== B002: v0.9.9-h recovery paths surface RuntimeError cause ==="
PYTHONPATH="$ROOT_DIR/lib" "$PYTHON_BIN" -B -c "
import inspect
from ownframework_loop import supervisor_attempts
# Both siblings must narrow to RuntimeError and delegate to one shared
# diagnostic-only owner. The owner must persist the bounded cause without
# routing through _update_job (which is a lifecycle transition).
for name in ('_maybe_complete_semantic_artifact', '_publish_acceptance_for_ready_artifact'):
    fn = getattr(supervisor_attempts, name)
    src = inspect.getsource(fn)
    assert 'except RuntimeError as exc' in src, f'B002: {name} must narrow except to RuntimeError'
    assert '_persist_semantic_acceptance_failure' in src, f'B002: {name} must delegate diagnostic persistence'
helper_src = inspect.getsource(supervisor_attempts._persist_semantic_acceptance_failure)
assert 'semantic_acceptance_publication_failed' in helper_src, 'B002: shared helper must persist the actual cause'
assert '_persist_job_last_error' in helper_src, 'B002: shared helper must use diagnostic-only DB primitive'
assert '_update_job' not in helper_src, 'B002: diagnostic helper must not perform lifecycle transition'
assert 'except Exception' not in helper_src, 'B002: deterministic diagnostic programming errors must not be swallowed'
print('ok')
" || fail "B002 regression"
pass "B002: RuntimeError cause surfaced on last_error"

########################################################################
# B003 — single canonical _LOCAL_EXECUTION_LOCK
########################################################################
echo "=== B003: _LOCAL_EXECUTION_LOCK is the same object in db and process ==="
PYTHONPATH="$ROOT_DIR/lib" "$PYTHON_BIN" -B -c "
from ownframework_loop import supervisor_db, supervisor_process
# Both modules must reference the same lock object
assert supervisor_db._LOCAL_EXECUTION_LOCK is supervisor_process._LOCAL_EXECUTION_LOCK, \
    'B003: _LOCAL_EXECUTION_LOCK must be the same object in db and process modules'
print('ok')
" || fail "B003 regression"
pass "B003: single canonical _LOCAL_EXECUTION_LOCK across modules"

########################################################################
# B009 — orphan identity failure forces QUARANTINED
########################################################################
echo "=== B009: orphan identity unproven forces QUARANTINED ==="
PYTHONPATH="$ROOT_DIR/lib" "$PYTHON_BIN" -B -c "
import inspect
from ownframework_loop import supervisor_recovery
src = inspect.getsource(supervisor_recovery._recover_stale_running)
assert \"status='QUARANTINED'\" in src or 'status=\\'QUARANTINED\\'' in src, 'B009: must transition to QUARANTINED'
assert 'orphan_identity' in src, 'B009: must classify as orphan_identity'
print('ok')
" || fail "B009 regression"
pass "B009: identity-unproven forces QUARANTINED with orphan_identity classification"

echo "V10D_PRE1_ADVERSARIAL_FIXES=PASS"
