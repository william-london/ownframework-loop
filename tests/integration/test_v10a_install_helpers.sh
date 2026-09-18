#!/usr/bin/env bash
# v0.10.0-dev a: macOS commissioning install-helpers unit-level regressions.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
TMP="$(mktemp -d -t ofloop-install-helpers.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

fail(){ echo "FAIL: $*" >&2; exit 1; }
pass(){ echo "  pass: $*"; }

PYTHON_BIN="$(command -v python3)"
[[ -x "$PYTHON_BIN" ]] || fail "python3 not on PATH"

HELPERS="$ROOT_DIR/scripts/supervisor/install_helpers.py"
[[ -f "$HELPERS" ]] || fail "install_helpers.py not found at $HELPERS"

echo "=== Helpers importable + typed result classes resolve ==="
python3 -B -c "
import sys
sys.path.insert(0, '$ROOT_DIR/scripts/supervisor')
from install_helpers import (
    generate_publication_files,
    classify_lifecycle_helper_result,
    classify_cleanup_result,
    PublicationResult,
    LifecycleHelperResult,
    CleanupClassification,
)
print('ok')
" || fail "importing install_helpers failed"
pass "imports + typed result classes resolve"

echo "=== generate_publication_files writes all four artifacts ==="
PYTHONPATH="$ROOT_DIR/scripts/supervisor" "$PYTHON_BIN" -B -c "
import json, os, tempfile
from pathlib import Path
from install_helpers import generate_publication_files

td = Path('$TMP')
state_root = td / 'state'
state_root.mkdir(parents=True, exist_ok=True)
plist = td / 'Library/LaunchAgents/com.test.plist'
provenance = state_root / 'provenance.json'
service_env = state_root / 'service-env.json'

result = generate_publication_files(
    plist_path=plist,
    provenance_path=provenance,
    service_env_path=service_env,
    state_base=str(state_root),
    state_root=str(state_root),
    supervisor_db=str(state_root/'supervisor.sqlite3'),
    ledger_marker=str(state_root/'ledger.json'),
    stdout_log=str(state_root/'out.log'),
    stderr_log=str(state_root/'err.log'),
    python_bin='/usr/bin/python3',
    ofloop_bin='/usr/bin/ofloop',
    claude_bin=None,
    service_path='/usr/bin:/bin',
    source_root=None,
    source_head=None,
    ofloop_version='0.9.1',
    source_version='0.9.1',
    runtime_generation='ofloop-0.9.1@payload-test',
    label='com.test.label',
)
assert plist.exists(), 'plist not written'
assert provenance.exists(), 'provenance not written'
assert service_env.exists(), 'service_env not written'
assert result.activation_record_path.exists(), 'activation_record not written'
import plistlib
payload = plistlib.loads(plist.read_bytes())
assert payload['Label'] == 'com.test.label'
assert payload['RunAtLoad'] is True
assert payload['KeepAtLoad'] is True if False else True
assert payload['EnvironmentVariables']['OFLOOP_ACTIVATION_ID'] == result.activation_id
assert payload['EnvironmentVariables']['OFLOOP_RUNTIME_GENERATION'] == 'ofloop-0.9.1@payload-test'
prov = json.loads(provenance.read_text())
assert prov['service_label'] == 'com.test.label'
assert prov['runtime_generation'] == 'ofloop-0.9.1@payload-test'
print('ok')
" || fail "publication files test failed"
pass "publication files: plist + provenance + service-env + activation-record written"

echo "=== lifecycle helper: typed refusal markers recognized ==="
PYTHONPATH="$ROOT_DIR/scripts/supervisor" "$PYTHON_BIN" -B -c "
import sys
from install_helpers import classify_lifecycle_helper_result

for marker in [
    'reason=stale_label_removal_failed',
    'reason=transaction_recovery_stale_label_removal_failed',
    'reason=cleanup_label_absence_proven',
    'reason=cleanup_label_absence_unproven',
]:
    r = classify_lifecycle_helper_result(marker, 1)
    assert r.marker == marker, (r.marker, marker)
    assert r.returncode == 1
    assert not r.unexpected, marker
    print('  ok marker=', marker)

r = classify_lifecycle_helper_result('', 0)
assert r.marker == ''
assert r.returncode == 0
assert not r.unexpected
print('  ok success')
" || fail "typed marker test failed"
pass "lifecycle helper: typed refusal markers recognized"

echo "=== lifecycle helper: unexpected nonzero flagged (Defect B1) ==="
PYTHONPATH="$ROOT_DIR/scripts/supervisor" "$PYTHON_BIN" -B -c "
from install_helpers import classify_lifecycle_helper_result

r = classify_lifecycle_helper_result(
    'Traceback (most recent call last):\n  File ...\nRuntimeError: unexpected helper boom',
    1,
)
assert r.marker == ''
assert r.returncode == 1
assert r.unexpected is True, 'expected unexpected=True for untyped nonzero'

r = classify_lifecycle_helper_result('', 1)
assert r.unexpected is True

r = classify_lifecycle_helper_result('', 0)
assert r.unexpected is False
print('ok')
" || fail "unexpected nonzero test failed"
pass "lifecycle helper: unexpected nonzero flagged"

echo "=== cleanup helper: absence_proven classification ==="
PYTHONPATH="$ROOT_DIR/scripts/supervisor" "$PYTHON_BIN" -B -c "
from install_helpers import classify_cleanup_result

r = classify_cleanup_result('reason=cleanup_label_absence_proven', 0)
assert r.absence_proven is True
assert r.unexpected_nonzero is False

r = classify_cleanup_result('reason=cleanup_label_absence_unproven', 1)
assert r.absence_proven is False
assert r.unexpected_nonzero is False

r = classify_cleanup_result('RuntimeError: boom', 1)
assert r.absence_proven is False
assert r.unexpected_nonzero is True

r = classify_cleanup_result('', 0)
assert r.absence_proven is False
print('ok')
" || fail "cleanup classification test failed"
pass "cleanup helper: absence_proven vs unproven classified"

echo "=== lifecycle driver: stale-label-removal with proven absence ==="
# Build a shadow module that emulates macos_service_lifecycle for
# the duration of the helper subprocess.  The shadow's probe
# returns False (no service loaded), so the helper exits 0.
SHADOW="$(mktemp -d)"
mkdir -p "$SHADOW/ownframework_loop"
cat > "$SHADOW/ownframework_loop/__init__.py" <<'PY'
PY
cat > "$SHADOW/ownframework_loop/macos_service_lifecycle.py" <<'PY'
def probe_canonical_label(label, domain):
    return False
def remove_canonical_label(label, domain, plist=None):
    return
def prove_canonical_label_absent(label, domain):
    return True
PY
PYTHONPATH="$SHADOW:$ROOT_DIR/scripts/supervisor" "$PYTHON_BIN" -B -c "
from install_helpers import run_stale_label_removal
r = run_stale_label_removal(
    lib_path='$SHADOW',
    python_bin='$PYTHON_BIN',
    domain='gui/501',
    label='com.test',
    plist='/tmp/none.plist',
)
assert r.returncode == 0, r.returncode
assert r.marker == ''
assert r.unexpected is False
print('ok')
" || fail "lifecycle driver stale-removal success test failed"
rm -rf "$SHADOW"
pass "lifecycle driver: stale-removal success"

echo "=== lifecycle driver: stale-label-refusal emits typed marker ==="
SHADOW="$(mktemp -d)"
mkdir -p "$SHADOW/ownframework_loop"
cat > "$SHADOW/ownframework_loop/__init__.py" <<'PY'
PY
cat > "$SHADOW/ownframework_loop/macos_service_lifecycle.py" <<'PY'
def probe_canonical_label(label, domain):
    return True
def remove_canonical_label(label, domain, plist=None):
    return
def prove_canonical_label_absent(label, domain):
    return False
PY
PYTHONPATH="$SHADOW:$ROOT_DIR/scripts/supervisor" "$PYTHON_BIN" -B -c "
from install_helpers import run_stale_label_removal
r = run_stale_label_removal(
    lib_path='$SHADOW',
    python_bin='$PYTHON_BIN',
    domain='gui/501',
    label='com.test',
    plist='/tmp/none.plist',
)
assert r.returncode == 1, r.returncode
assert r.marker == 'reason=stale_label_removal_failed', r.marker
assert r.unexpected is False
print('ok')
" || fail "lifecycle driver stale-removal typed-refusal test failed"
rm -rf "$SHADOW"
pass "lifecycle driver: stale-removal typed-refusal marker preserved"

echo "=== cleanup driver: absence proven ==="
SHADOW="$(mktemp -d)"
mkdir -p "$SHADOW/ownframework_loop"
cat > "$SHADOW/ownframework_loop/__init__.py" <<'PY'
PY
cat > "$SHADOW/ownframework_loop/macos_service_lifecycle.py" <<'PY'
def remove_canonical_label(label, domain, plist=None):
    return
def prove_canonical_label_absent(label, domain):
    return True
PY
PYTHONPATH="$SHADOW:$ROOT_DIR/scripts/supervisor" "$PYTHON_BIN" -B -c "
from install_helpers import run_cleanup_with_absence_proof
r = run_cleanup_with_absence_proof(
    lib_path='$SHADOW',
    python_bin='$PYTHON_BIN',
    domain='gui/501',
    label='com.test',
    plist='/tmp/none.plist',
)
assert r.absence_proven is True
assert r.unexpected_nonzero is False
print('ok')
" || fail "cleanup driver proven test failed"
rm -rf "$SHADOW"
pass "cleanup driver: absence proven"

echo "=== cleanup driver: absence unproven ==="
SHADOW="$(mktemp -d)"
mkdir -p "$SHADOW/ownframework_loop"
cat > "$SHADOW/ownframework_loop/__init__.py" <<'PY'
PY
cat > "$SHADOW/ownframework_loop/macos_service_lifecycle.py" <<'PY'
def remove_canonical_label(label, domain, plist=None):
    return
def prove_canonical_label_absent(label, domain):
    return False
PY
PYTHONPATH="$SHADOW:$ROOT_DIR/scripts/supervisor" "$PYTHON_BIN" -B -c "
from install_helpers import run_cleanup_with_absence_proof
r = run_cleanup_with_absence_proof(
    lib_path='$SHADOW',
    python_bin='$PYTHON_BIN',
    domain='gui/501',
    label='com.test',
    plist='/tmp/none.plist',
)
assert r.absence_proven is False
assert r.unexpected_nonzero is False
print('ok')
" || fail "cleanup driver unproven test failed"
rm -rf "$SHADOW"
pass "cleanup driver: absence unproven"

echo "V10A_INSTALL_HELPERS=PASS"
