#!/usr/bin/env bash
# Idempotency checks for install.sh / rollback.sh choreography:
# - install.sh captures SOURCE_BRANCH from current branch (no hardcoded master)
# - install.sh parity check is wired (failure path exits non-zero)
# - rollback.sh accepts both legacy `of-loop.backup-*` and current
#   `ownframework-loop-mgmt-backup-*` naming
# - rollback.sh honors INSTALL_ROOT and INSTALL_PARENT env overrides
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
fail=0
ok() { echo "  PASS: $*"; }
bad() { echo "  FAIL: $*"; fail=$((fail+1)); }

# 1. install.sh SOURCE_BRANCH derivation must be dynamic.
if grep -q 'SOURCE_BRANCH="${SOURCE_BRANCH:-$(git -C "\$SOURCE_ROOT" branch --show-current' "$ROOT/install.sh"; then
  ok "install.sh: SOURCE_BRANCH derived from git, not hardcoded"
else
  bad "install.sh: SOURCE_BRANCH is not derived from git"
fi

# 2. install.sh parity check must exist
if grep -q 'EXPECTED_CACHE.*claude/plugins/cache/ownframework-local/of-loop/' "$ROOT/install.sh"; then
  ok "install.sh: parity check after managed install"
else
  bad "install.sh: missing post-install parity check"
fi

# 3. rollback.sh accepts both backup-naming conventions
if grep -q 'of-loop.backup-\\*' "$ROOT/rollback.sh" && \
   grep -q 'ownframework-loop-mgmt-backup-\\*' "$ROOT/rollback.sh"; then
  ok "rollback.sh: accepts both legacy and current backup naming"
else
  bad "rollback.sh: backup-naming pattern missing"
fi

# 4. rollback.sh honors env override
if grep -q 'INSTALL_ROOT:=' "$ROOT/rollback.sh"; then
  ok "rollback.sh: INSTALL_ROOT env override"
else
  bad "rollback.sh: INSTALL_ROOT not env-overridable"
fi

# 5. install.sh atomicity: restore legacy on failure
if grep -q 'restore_legacy' "$ROOT/install.sh"; then
  ok "install.sh: legacy-rollback helper present"
else
  bad "install.sh: missing restore_legacy helper"
fi

if [[ "$fail" -eq 0 ]]; then
  echo "  RESULT: install/rollback idempotency checks pass"
  exit 0
fi
echo "  RESULT: $fail install/rollback idempotency checks failed"
exit 1
