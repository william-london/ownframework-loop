#!/usr/bin/env bash
# Trust suite — Secret safety and Isolation tests (51–57).

set -uo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

# 51. literal secret never appears in event
T="$(make_tmp_repo)"
"$OFLOOP_BIN" spec new "$T" "secret-test" >/dev/null
RID="$(ls -1t "$T/.ownframework-loop" | head -n1)"
EVENTS="$T/.ownframework-loop/$RID/EVENTS.log"
SECRET="AKIAIOSFODNN7EXAMPLE"
python3 - "$EVENTS" <<'PY'
import sys, base64, os, json
from pathlib import Path
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib'))
from ownframework_loop import secrets_v2, state as state_mod
events = sys.argv[1]
secret = "AKIAIOSFODNN7EXAMPLE"
text = "before\n" + secret + "\nafter\n"
findings = secrets_v2.scan_text(text, source="bash_output")
redacted = secrets_v2.redact_findings_for_event(findings)
canonical = Path(os.path.dirname(os.path.dirname(events)))
run_id = os.path.basename(os.path.dirname(events))
state_mod.append_event(
    canonical, run_id,
    event_type="secret_scan_positive",
    old_state=None, new_state=None,
    actor="test",
    reason=f"{len(redacted)} findings",
    extras={"findings": redacted},
)
PY
if grep -qF "$SECRET" "$EVENTS" 2>/dev/null; then
  fail "literal secret appeared in EVENTS.log"
else
  pass "literal secret never appears in event"
fi

# 52. literal secret never appears in receipt; hard secret blocks
T2="$(make_tmp_repo)"
RID2="$(make_approved_run "$T2" BUG low "secret-test-2")"
"$OFLOOP_BIN" build claim "$T2" "$RID2" >/dev/null 2>&1
WT2="$T2/.worktrees/ownframework-loop/$RID2/builder"
git -C "$T2" worktree add -b "factory/candidate/$RID2" "$WT2" master >/dev/null 2>&1
echo "key = \"$SECRET\"" > "$WT2/secret.py"
git -C "$WT2" add secret.py && git -C "$WT2" commit -m "add secret" >/dev/null 2>&1
out52="$("$OFLOOP_BIN" build finalize "$T2" "$RID2" 2>&1 || true)"
assert_contains "$out52" "OF_LOOP_BUILD_FINALIZE_REFUSED" "hard secret fixture blocks candidate"
RECEIPT2="$T2/.ownframework-loop/$RID2/BUILD_RECEIPT.json"
if [[ -f "$RECEIPT2" ]] && grep -qF "$SECRET" "$RECEIPT2"; then
  fail "literal secret appeared in BUILD_RECEIPT.json"
else
  pass "literal secret never appears in receipt"
fi

# 53. private-key fixture blocks candidate
T3="$(make_tmp_repo)"
RID3="$(make_approved_run "$T3" BUG low "pem-test")"
"$OFLOOP_BIN" build claim "$T3" "$RID3" >/dev/null 2>&1
WT3="$T3/.worktrees/ownframework-loop/$RID3/builder"
git -C "$T3" worktree add -b "factory/candidate/$RID3" "$WT3" master >/dev/null 2>&1
cat > "$WT3/key.pem" <<'PEM'
-----BEGIN RSA PRIVATE KEY-----
MIIBOgIBAAJBAKj34GkxFhD90vcNLYLInFEX6Ppy1tPf9Cnzj4p4WGeKLs1Pt8Qu
KUpRKfFLfRYC9AIKjbJTWit+CqvjWYzvQwECAwEAAQJAIJLixBy2qpFoS4DSmoEm
o3qGy0t6z09AIJtH+5OeRV1be+N4cDYJKffGzDa88vQENZiRm0GRq6a+HPGQMf2F
TQIhAKMSvzIBnni7ot/OSie2TmJLY4SwTQAevXysE2RbFDYdAiEBCUEaRQnMnbp7
9mxDXDf6AU0cN/RPBjb9qSHDcWZHGzUCIG2Es59z8ugGrDY+pxLQnwfotadxd+Uy
v/Ow5T0q5gIJAiEAyS4RaI9YG8EWx/2w0T67ZUVAw8eOMB6BIUg0Xcu+3okCIBOs
/5OiPgoTdSy7bcF9IGpSE8ZgGKzgYQVZeN97YE00
-----END RSA PRIVATE KEY-----
PEM
git -C "$WT3" add key.pem && git -C "$WT3" commit -m "add pem" >/dev/null 2>&1
out53="$("$OFLOOP_BIN" build finalize "$T3" "$RID3" 2>&1 || true)"
assert_contains "$out53" "OF_LOOP_BUILD_FINALIZE_REFUSED" "private-key fixture blocks candidate"

# 54. high-confidence token fixture blocks candidate
T4="$(make_tmp_repo)"
RID4="$(make_approved_run "$T4" BUG low "gh-test")"
"$OFLOOP_BIN" build claim "$T4" "$RID4" >/dev/null 2>&1
WT4="$T4/.worktrees/ownframework-loop/$RID4/builder"
git -C "$T4" worktree add -b "factory/candidate/$RID4" "$WT4" master >/dev/null 2>&1
echo "token = ghp_1234567890abcdefghijklmnopqrstuvwxyzAB" > "$WT4/tok.py"
git -C "$WT4" add tok.py && git -C "$WT4" commit -m "add token" >/dev/null 2>&1
out54="$("$OFLOOP_BIN" build finalize "$T4" "$RID4" 2>&1 || true)"
assert_contains "$out54" "OF_LOOP_BUILD_FINALIZE_REFUSED" "high-confidence token fixture blocks candidate"

# 55. heuristic fixture produces reviewable warning (does NOT block)
T5="$(make_tmp_repo)"
RID5="$(make_approved_run "$T5" BUG low "heuristic-test")"
"$OFLOOP_BIN" build claim "$T5" "$RID5" >/dev/null 2>&1
WT5="$T5/.worktrees/ownframework-loop/$RID5/builder"
git -C "$T5" worktree add -b "factory/candidate/$RID5" "$WT5" master >/dev/null 2>&1
mkdir -p "$WT5/src"
echo "password = hello-world-fake" > "$WT5/src/pw.py"
git -C "$WT5" add src/pw.py && git -C "$WT5" commit -m "add pw" >/dev/null 2>&1
"$OFLOOP_BIN" build finalize "$T5" "$RID5" >/dev/null 2>&1 || true
RECEIPT5="$T5/.ownframework-loop/$RID5/BUILD_RECEIPT.json"
[[ -f "$RECEIPT5" ]] && pass "heuristic fixture produces reviewable warning (receipt exists)" || fail "heuristic fixture unexpectedly blocked"
HEUR=$(python3 -c "
import json
r = json.load(open('$RECEIPT5'))
ss = r.get('secret_scan_check', {})
heur = [f for f in ss.get('findings', []) if f.get('severity') == 'heuristic']
print(len(heur))
")
[[ "$HEUR" -gt 0 ]] && pass "heuristic finding is recorded in receipt" || fail "heuristic finding not recorded"

# 56. scanner handles quotes/newlines safely
out56="$(python3 -c "
import sys
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib'))
from ownframework_loop import secrets_v2
text = 'line1 \"with quotes\"\nline2\n-----BEGIN RSA PRIVATE KEY-----\n'
findings = secrets_v2.scan_text(text)
for f in findings:
    print(f['pattern_id'], f['severity'])
")"
assert_contains "$out56" "pem_private_key" "scanner handles quotes/newlines safely"

# 57. scanner failure cannot leak a traceback or secret
out57="$(python3 -c "
import sys
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get('OFLOOP_LIB', '/path/to/ownframework-loop/lib'))
from ownframework_loop import secrets_v2
try:
    findings = secrets_v2.scan_text(None)
    print('OK', len(findings))
except Exception as e:
    print('EXC', type(e).__name__)
" 2>&1 || echo "EXC_RAISED")"
assert_contains "$out57" "OK" "scanner failure cannot leak a traceback or secret"

echo "TRUST_SECRETS_TESTS=PASS"
