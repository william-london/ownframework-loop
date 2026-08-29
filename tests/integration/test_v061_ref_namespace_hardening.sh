#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib"

python3 - <<'PY'
from ownframework_loop import git_checks, branch_resolver, state
valid=["master","feature/x","factory/candidate/run-abc"]
invalid=["","../x","-bad","a..b","a b","a~b","refs/heads/x","x.lock","x@{y}"]
for v in valid:
    assert git_checks.is_valid_branch_name(v),v
for v in invalid:
    assert not git_checks.is_valid_branch_name(v),v
assert branch_resolver.default_candidate_branch("run-abc")=="factory/candidate/run-abc"
for rid in ("../../outside","run-a/b","run-../escape"):
    try:
        branch_resolver.default_candidate_branch(rid)
    except ValueError:
        pass
    else:
        raise SystemExit(f"unsafe run id accepted: {rid}")
PY

# Empty-run convenience paths must not call validated run_dir with "".
if grep -R --include='*.py' -nE 'run_dir\([^,]+,[[:space:]]*["'\''"]["'\''][[:space:]]*\)' "$ROOT_DIR/lib/ownframework_loop"; then
  echo "FAIL: empty run_id still passed to run_dir"
  exit 1
fi

echo "V061_REF_NAMESPACE_HARDENING=PASS"
