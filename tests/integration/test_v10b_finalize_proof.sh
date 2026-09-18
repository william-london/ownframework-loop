#!/usr/bin/env bash
# v0.10.0-dev b: shared deterministic proof primitives regressions.
#
# The build/review finalize modules now share primitives through
# finalize_proof.py.  This test exercises the shared module's
# surface (read_json, candidate_branch_contains, ancestor_of,
# path_in_list, classify_path_against_packet, strict_ceiling).
# These were previously duplicated and are now exercised once for
# both finalizer roles.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
TMP="$(mktemp -d -t ofloop-finalize-proof.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

fail(){ echo "FAIL: $*" >&2; exit 1; }
pass(){ echo "  pass: $*"; }

PYTHON_BIN="$(command -v python3)"
[[ -x "$PYTHON_BIN" ]] || fail "python3 not on PATH"

echo "=== finalize_proof module loads and exposes the shared primitives ==="
PYTHONPATH="$ROOT_DIR/lib" "$PYTHON_BIN" -B -c "
from ownframework_loop import finalize_proof as fp
# Required shared primitives
assert callable(fp.read_json)
assert callable(fp.candidate_branch_contains)
assert callable(fp.ancestor_of)
assert callable(fp.path_in_list)
assert callable(fp.classify_path_against_packet)
assert callable(fp.strict_ceiling)
print('ok')
" || fail "finalize_proof module load failed"
pass "shared primitives are importable"

echo "=== strict_ceiling: min of two declared; single-source falls through ==="
PYTHONPATH="$ROOT_DIR/lib" "$PYTHON_BIN" -B -c "
from ownframework_loop import finalize_proof as fp
assert fp.strict_ceiling(100, 200) == 100, 'stricter wins'
assert fp.strict_ceiling(200, 100) == 100
assert fp.strict_ceiling(0, 100) == 100, 'single declared falls through'
assert fp.strict_ceiling(100, 0) == 100
assert fp.strict_ceiling(0, 0) == 0, 'both undeclared returns 0'
print('ok')
" || fail "strict_ceiling test failed"
pass "strict_ceiling returns the stricter of two declared envelopes"

echo "=== path_in_list: supports exact + dir/** semantics ==="
PYTHONPATH="$ROOT_DIR/lib" "$PYTHON_BIN" -B -c "
from ownframework_loop import finalize_proof as fp
assert fp.path_in_list('a/b.py', 'a/b.py') is True
assert fp.path_in_list('a/b.py', 'a') is True
assert fp.path_in_list('a/b/c.py', 'a/**') is True
assert fp.path_in_list('a', 'a/**') is True, 'a/** matches descendants of a'
assert fp.path_in_list('b.py', 'a/**') is False, 'a/** does not match b.py'
print('ok')
" || fail "path_in_list test failed"
pass "path_in_list honors exact + dir/** + descendant semantics"

echo "=== classify_path_against_packet: protected > allowed > elevated > sensitive > out_of_scope ==="
PYTHONPATH="$ROOT_DIR/lib" "$PYTHON_BIN" -B -c "
from ownframework_loop import finalize_proof as fp
packet = {
    'allowed_paths': ['src/**'],
    'protected_paths': ['SECURITY.md'],
    'elevated_allowed_paths': ['infra/**'],
    'sensitive_paths': ['secrets.env'],
}
assert fp.classify_path_against_packet(packet, 'SECURITY.md') == 'protected', \
    'protected wins'
assert fp.classify_path_against_packet(packet, 'src/foo.py') == 'allowed'
assert fp.classify_path_against_packet(packet, 'infra/k8s.yaml') == 'elevated'
assert fp.classify_path_against_packet(packet, 'secrets.env') == 'sensitive'
assert fp.classify_path_against_packet(packet, 'random.md') == 'out_of_scope'
print('ok')
" || fail "classify_path_against_packet test failed"
pass "classify_path_against_packet enforces precedence"

echo "=== read_json: missing file returns default; parse error returns default ==="
PYTHONPATH="$ROOT_DIR/lib" "$PYTHON_BIN" -B -c "
import json, tempfile
from pathlib import Path
from ownframework_loop import finalize_proof as fp

with tempfile.TemporaryDirectory() as td:
    missing = Path(td) / 'missing.json'
    sentinel = {'sentinel': True}
    assert fp.read_json(missing, default=sentinel) is sentinel
    assert fp.read_json(missing) is None

    bad = Path(td) / 'bad.json'
    bad.write_text('{not valid json', encoding='utf-8')
    assert fp.read_json(bad, default=sentinel) is sentinel

    good = Path(td) / 'good.json'
    good.write_text(json.dumps({'x': 1}), encoding='utf-8')
    assert fp.read_json(good) == {'x': 1}
print('ok')
" || fail "read_json test failed"
pass "read_json returns default on missing/parse; returns payload otherwise"

echo "V10B_FINALIZE_PROOF=PASS"
