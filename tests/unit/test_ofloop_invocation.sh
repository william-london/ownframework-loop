#!/usr/bin/env bash
# OwnFramework Loop — ofloop CLI invocation contract.
#
# Pins the supported invocations and rejects the broken `bash bin/ofloop`
# form that treats Python source as Bash.

set -uo pipefail

source "$(dirname "$0")/../_helpers.sh"

echo "--- test_ofloop_invocation ---"

# 1. Documented forms SUCCEED.
if ./bin/ofloop --help >/dev/null 2>&1; then
  pass "./bin/ofloop --help succeeds (executable bit + shebang)"
else
  fail "./bin/ofloop --help failed"
fi

if python3 bin/ofloop --help >/dev/null 2>&1; then
  pass "python3 bin/ofloop --help succeeds (explicit interpreter)"
else
  fail "python3 bin/ofloop --help failed"
fi

# 2. The broken form FAILS — bash interpreting Python source is SyntaxError.
if bash bin/ofloop --help >/dev/null 2>&1; then
  fail "bash bin/ofloop --help unexpectedly succeeded"
else
  pass "bash bin/ofloop --help rejected (bash runs Python source — SyntaxError)"
fi

# 3. The exit code from the broken form must be non-zero (we expect 2 from bash).
RC=$(bash bin/ofloop --help >/dev/null 2>&1; echo $?)
if [[ "$RC" -ne 0 ]]; then
  pass "bash bin/ofloop exits non-zero (rc=$RC) — confirmed unsupported"
else
  fail "bash bin/ofloop exited 0 unexpectedly"
fi

# 4. The shebang is correct on disk.
SHEBANG=$(head -n1 bin/ofloop)
if [[ "$SHEBANG" == "#!/usr/bin/env python3" || "$SHEBANG" == "#!/usr/bin/python3" ]]; then
  pass "bin/ofloop shebang is python ($SHEBANG)"
else
  fail "bin/ofloop shebang is $SHEBANG"
fi

# 5. The bin/ofloop file is executable.
if [[ -x bin/ofloop ]]; then
  pass "bin/ofloop is executable"
else
  fail "bin/ofloop is not executable (chmod +x required)"
fi

# 6. The form `bash bin/ofloop` must NOT appear as an *invocation* in any
#    executable context (shell script, runbook, smoke). It MAY appear in
#    documentation prose that explicitly warns against it.
#    We check: any line that starts (after whitespace) with `bash bin/ofloop`
#    in a `.sh` file would be an executable invocation. In `.md`, only a
#    fenced-code-block line counts.
HITS_SH=$(grep -rn "^[ \t]*bash bin/ofloop\|^[ \t]*bash\\s\\./bin/ofloop" \
  --include="*.sh" --include="install.sh" --include="uninstall.sh" \
  --include="rollback.sh" --include="validate.sh" --include="release_gate.sh" \
  --include="*.bash" \
  . 2>/dev/null | grep -v "\.git/" | grep -v "tests/unit/test_ofloop_invocation.sh" || true)
if [[ -z "$HITS_SH" ]]; then
  pass "no `bash bin/ofloop` invocation in shell scripts"
else
  fail "shell scripts use broken form: $HITS_SH"
fi

# Check fenced-code blocks in markdown (a line inside ```bash ...``` that
# contains `bash bin/ofloop` as a command — not as prose).
HITS_MD=$(grep -rn "^bash bin/ofloop\\|^bash\\s\\./bin/ofloop" \
  --include="*.md" . 2>/dev/null | grep -v "\.git/" || true)
if [[ -z "$HITS_MD" ]]; then
  pass "no `bash bin/ofloop` invocation in markdown code blocks"
else
  fail "markdown code blocks use broken form: $HITS_MD"
fi

exit 0
