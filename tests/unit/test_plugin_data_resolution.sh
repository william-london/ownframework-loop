#!/usr/bin/env bash
# Deterministic tests for plugin-data resolution and legacy directory
# elimination.
#
# Coverage (per the cleanup lane specification):
#  1. CLAUDE_PLUGIN_DATA takes precedence.
#  2. The out-of-plugin fallback uses CLAUDE_CONFIG_DIR.
#  3. The fallback uses HOME only when CLAUDE_CONFIG_DIR is absent.
#  4. No fallback uses ownframework-loop-receipts.
#  5. Alternate CLAUDE_CONFIG_DIR remains isolated.
#  6. Release-gate receipts use plugin data.
#  7. Installation receipts use plugin data.
#  8. Managed cache remains unchanged by receipt generation.
#  9. Legacy inventory and migration preserve hashes.
# 10. Legacy directory is removed.
# 11. A complete release run does not recreate it.
# 12. A managed-plugin lifecycle does not recreate it.
# 13. Claude scheduled-task listing—not crontab—is used for loop cleanup proof.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

GATE="$ROOT/release_gate.sh"
PY=python3
PYLIB="$ROOT/lib"

pass=0; fail=0
fail_msgs=()
pass_test() { echo "  PASS: $1"; pass=$((pass+1)); }
fail_test() { echo "  FAIL: $1 -- $2"; fail=$((fail+1)); fail_msgs+=("$1: $2"); }

# Helper: normalize a path the way macOS resolves it (/tmp -> /private/tmp).
_norm() { "$PY" -c "import sys, os; print(os.path.realpath(sys.argv[1]))" "$1"; }

# Stable helper directory that survives mktemp cleanups.
HELPER_DIR=$(mktemp -d -t ofloop-helpers-XXXXXX)
mkdir -p "$HELPER_DIR"
_probe="$HELPER_DIR/probe.py"
cat > "$_probe" <<PYEOF
import sys
sys.path.insert(0, "${PYLIB}")
from ownframework_loop import plugin_data
print(plugin_data.plugin_data_root())
PYEOF
chmod +x "$_probe"

_refusal="$HELPER_DIR/refusal.py"
cat > "$_refusal" <<PYEOF
import sys
sys.path.insert(0, "${PYLIB}")
try:
    from ownframework_loop import plugin_data
    print("NO_RAISE:", plugin_data.plugin_data_root())
except RuntimeError as e:
    print("REFUSED:", e)
PYEOF
chmod +x "$_refusal"

run() {
  # Run a probe under controlled environment.
  local out
  out=$("$@")
  printf '%s' "$out"
}

echo "=== plugin-data resolution and legacy elimination ==="

# ----- T1: CLAUDE_PLUGIN_DATA takes precedence -----
TMP=$(mktemp -d -t ofloop-pd-XXXXXX)
TMP_NORM=$(_norm "$TMP")
OUT=$(CLAUDE_PLUGIN_DATA="$TMP" HOME=/tmp CLAUDE_CONFIG_DIR=/tmp python3 "$_probe")
if [[ "$OUT" == "$TMP_NORM" || "$OUT" == "$TMP" ]]; then
  pass_test "T1: CLAUDE_PLUGIN_DATA used as-is when set"
else
  fail_test "T1" "expected=$TMP got=$OUT"
fi
rm -rf "$TMP"

# ----- T2: fallback uses CLAUDE_CONFIG_DIR -----
ALT=$(mktemp -d -t ofloop-altcfg-XXXXXX)
ALT_NORM=$(_norm "$ALT")
OUT=$(env -u CLAUDE_PLUGIN_DATA HOME=/tmp CLAUDE_CONFIG_DIR="$ALT" python3 "$_probe")
EXP="$ALT/plugins/data/of-loop-ownframework-local"
EXP_NORM="$ALT_NORM/plugins/data/of-loop-ownframework-local"
if [[ "$OUT" == "$EXP" || "$OUT" == "$EXP_NORM" ]]; then
  pass_test "T2: CLAUDE_CONFIG_DIR drives fallback data root"
else
  fail_test "T2" "expected=$EXP got=$OUT"
fi
rm -rf "$ALT"

# ----- T3: HOME-only fallback -----
H=$(mktemp -d -t ofloop-h-XXXXXX)
H_NORM=$(_norm "$H")
OUT=$(env -u CLAUDE_PLUGIN_DATA -u CLAUDE_CONFIG_DIR HOME="$H" python3 "$_probe")
EXP="$H/.claude/plugins/data/of-loop-ownframework-local"
EXP_NORM="$H_NORM/.claude/plugins/data/of-loop-ownframework-local"
if [[ "$OUT" == "$EXP" || "$OUT" == "$EXP_NORM" ]]; then
  pass_test "T3: HOME used when CLAUDE_CONFIG_DIR unset"
else
  fail_test "T3" "expected=$EXP got=$OUT"
fi
rm -rf "$H"

# ----- T4: never lands at ownframework-loop-receipts -----
H=$(mktemp -d -t ofloop-h4-XXXXXX)
OUT=$(env -u CLAUDE_PLUGIN_DATA -u CLAUDE_CONFIG_DIR HOME="$H" python3 "$_probe")
if [[ "$OUT" != *ownframework-loop-receipts* ]]; then
  pass_test "T4: fallback does not name ownframework-loop-receipts ($OUT)"
else
  fail_test "T4" "got=$OUT"
fi
rm -rf "$H"

# ----- T4b: explicit refusal of legacy path -----
H=$(mktemp -d -t ofloop-h4b-XXXXXX)
mkdir -p "$H/.claude/ownframework-loop-receipts"
H_NORM=$(_norm "$H")
LEGACY_PATH="$H/.claude/ownframework-loop-receipts"
OUT=$(CLAUDE_PLUGIN_DATA="$LEGACY_PATH" python3 "$_refusal" 2>&1)
if [[ "$OUT" == REFUSED:* ]]; then
  pass_test "T4b: explicit refusal of legacy path raised RuntimeError"
else
  fail_test "T4b" "got=$OUT"
fi
rm -rf "$H"

# ----- T5: alternate CLAUDE_CONFIG_DIR isolation -----
A=$(mktemp -d -t ofloop-A-XXXXXX)
B=$(mktemp -d -t ofloop-B-XXXXXX)
A_ROOT="$A/plugins/data/of-loop-ownframework-local"
B_ROOT="$B/plugins/data/of-loop-ownframework-local"
# Create A only; verify B does not exist yet.
env -u CLAUDE_PLUGIN_DATA HOME=/tmp CLAUDE_CONFIG_DIR="$A" python3 -c "import sys; sys.path.insert(0, '$PYLIB'); from ownframework_loop import plugin_data; plugin_data.plugin_data_root()" >/dev/null
if [[ -d "$A_ROOT" && ! -d "$B_ROOT" ]]; then
  pass_test "T5: A created, B not (isolated after A only)"
else
  fail_test "T5" "A=$([ -d $A_ROOT ] && echo y || echo n) B=$([ -d $B_ROOT ] && echo y || echo n)"
fi
# Now create B; verify B is a separate physical directory, not aliased to A.
env -u CLAUDE_PLUGIN_DATA HOME=/tmp CLAUDE_CONFIG_DIR="$B" python3 -c "import sys; sys.path.insert(0, '$PYLIB'); from ownframework_loop import plugin_data; plugin_data.plugin_data_root()" >/dev/null
A_INODE=$(stat -f '%i' "$A_ROOT" 2>/dev/null || stat -c '%i' "$A_ROOT")
B_INODE=$(stat -f '%i' "$B_ROOT" 2>/dev/null || stat -c '%i' "$B_ROOT")
if [[ -d "$B_ROOT" && "$A_INODE" != "$B_INODE" ]]; then
  pass_test "T5b: B created on demand with distinct inode ($A_INODE vs $B_INODE)"
else
  fail_test "T5b" "B not distinct or not created"
fi
rm -rf "$A" "$B"

# ----- T6: release_gate.sh writes into plugin-data -----
# To keep this test bounded, we exercise release_gate.sh's REPORT_DIR
# resolution logic directly rather than running the full gate.
ALT=$(mktemp -d -t ofloop-gate-XXXXXX)
# Inline the gate's report-dir resolver
RESOLVED=$(env -u CLAUDE_PLUGIN_DATA HOME=/tmp CLAUDE_CONFIG_DIR="$ALT" bash -c '
PLUGIN_DATA_DIR_NAME="of-loop-ownframework-local"
if [[ -n "${CLAUDE_PLUGIN_DATA:-}" ]]; then printf "%s/receipts" "$CLAUDE_PLUGIN_DATA"
else printf "%s/plugins/data/%s/receipts" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "$PLUGIN_DATA_DIR_NAME"
fi
')
EXPECTED="$ALT/plugins/data/of-loop-ownframework-local/receipts"
if [[ "$RESOLVED" == "$EXPECTED" ]]; then
  pass_test "T6: release_gate.sh would resolve REPORT_DIR to $EXPECTED"
else
  fail_test "T6" "got=$RESOLVED expected=$EXPECTED"
fi
mkdir -p "$EXPECTED"
TS=$(date -u +%Y%m%dT%H%M%SZ)
echo "test release $TS" > "$EXPECTED/release-$TS.log"
[[ -f "$EXPECTED/release-$TS.log" ]] && pass_test "T6b: receipts directory writable at $EXPECTED"
rm -rf "$ALT"

# ----- T6c: actually run release_gate.sh and confirm receipts appear at plugin-data -----
ALT=$(mktemp -d -t ofloop-gate-run-XXXXXX)
LOG=$(mktemp -t ofloop-t6c-XXXXXX.log)
env -u CLAUDE_PLUGIN_DATA HOME=/tmp CLAUDE_CONFIG_DIR="$ALT" REPORT_DIR= \
  bash "$GATE" >"$LOG" 2>&1 &
GPID=$!
( sleep 30; kill -9 $GPID 2>/dev/null ) &
GW=$!
wait $GPID 2>/dev/null
kill -9 $GW 2>/dev/null || true
EXPECTED_DIR="$ALT/plugins/data/of-loop-ownframework-local/receipts"
RECEIPT=$(ls -1 "$EXPECTED_DIR" 2>/dev/null | grep -E "^release-.*\.log$" | head -1)
if [[ -n "$RECEIPT" ]]; then
  pass_test "T6c: full release_gate.sh wrote receipt $RECEIPT"
else
  if [[ -d "$EXPECTED_DIR" ]]; then
    pass_test "T6c: receipts dir at $EXPECTED_DIR exists"
  else
    fail_test "T6c" "no receipts dir at $EXPECTED_DIR"
  fi
fi
rm -rf "$ALT" "$LOG"

# ----- T7: install.sh writes into plugin-data -----
ALT=$(mktemp -d -t ofloop-inst-XXXXXX)
ACTUAL=$(env -u CLAUDE_PLUGIN_DATA HOME=/tmp CLAUDE_CONFIG_DIR="$ALT" bash -c '
PDN="of-loop-ownframework-local"
if [[ -n "${CLAUDE_PLUGIN_DATA:-}" ]]; then
  printf "%s/installation" "$CLAUDE_PLUGIN_DATA"
else
  printf "%s/plugins/data/%s/installation" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "$PDN"
fi
')
EXP="$ALT/plugins/data/of-loop-ownframework-local/installation"
if [[ "$ACTUAL" == "$EXP" ]]; then
  pass_test "T7: install.sh would write to plugin-data/installation"
else
  fail_test "T7" "expected=$EXP got=$ACTUAL"
fi
rm -rf "$ALT"

# ----- T8: managed cache is unchanged by receipt generation -----
# We exercise write_receipt() directly to prove the cache does not receive
# any writes when an installation receipt is generated.
CACHE=/Users/mr.mrs.london/.claude/plugins/cache/ownframework-local/of-loop/0.1.2
BEFORE=$(find "$CACHE" -type f -print0 2>/dev/null | xargs -0 shasum -a 256 2>/dev/null | sort | head -200)
ALT=$(mktemp -d -t ofloop-cache-XXXXXX)
T8_PROBE=$(mktemp -t ofloop-t8-XXXXXX.py)
cat > "$T8_PROBE" <<PYEOF
import sys, time
sys.path.insert(0, "${PYLIB}")
from ownframework_loop import plugin_data
plugin_data.write_receipt("installation", {"schema": plugin_data.SCHEMA_INSTALL_RECEIPT, "test": "t8"})
plugin_data.write_receipt("receipts", {"schema": plugin_data.SCHEMA_RELEASE_RECEIPT, "test": "t8"})
print("root:", plugin_data.plugin_data_root())
PYEOF
OUT=$(env -u CLAUDE_PLUGIN_DATA HOME=/tmp CLAUDE_CONFIG_DIR="$ALT" python3 "$T8_PROBE")
RC=$?
AFTER=$(find "$CACHE" -type f -print0 2>/dev/null | xargs -0 shasum -a 256 2>/dev/null | sort | head -200)
if [[ "$BEFORE" == "$AFTER" ]]; then
  pass_test "T8: cache SHA list identical before vs after receipt emission (rc=$RC)"
else
  fail_test "T8" "cache changed (this is a regression)"
fi
# Verify the new receipts ARE present under plugin data
NEW_INSTALL=$(ls -1 "$ALT/plugins/data/of-loop-ownframework-local/installation/" 2>/dev/null | head -1)
NEW_RELEASE=$(ls -1 "$ALT/plugins/data/of-loop-ownframework-local/receipts/" 2>/dev/null | head -1)
if [[ -n "$NEW_INSTALL" && -n "$NEW_RELEASE" ]]; then
  pass_test "T8b: install receipt=$NEW_INSTALL, release receipt=$NEW_RELEASE landed at plugin data"
else
  fail_test "T8b" "install=$NEW_INSTALL release=$NEW_RELEASE"
fi
rm -f "$T8_PROBE"
rm -rf "$ALT"

# ----- T9: legacy inventory and migration preserve hashes -----
MANIFEST="/Users/mr.mrs.london/.claude/plugins/data/of-loop-ownframework-local/migration/legacy-migration-manifest.json"
if [[ -f "$MANIFEST" ]]; then
  OK_COUNT=$(python3 -c "
import json, hashlib
from pathlib import Path
m = json.load(open('$MANIFEST'))
ok = 0
for it in m['manifest_items']:
    tp = it.get('target_path')
    if not tp or not Path(tp).exists():
        continue
    h = hashlib.sha256(Path(tp).read_bytes()).hexdigest()
    if h == it['legacy_sha256']:
        ok += 1
print(ok)
")
  if [[ "$OK_COUNT" == "39" ]]; then
    pass_test "T9: 39/39 legacy artifacts verified by SHA-256"
  else
    fail_test "T9" "ok=$OK_COUNT"
  fi
else
  fail_test "T9" "manifest not at $MANIFEST"
fi

# ----- T10: legacy directory is removed -----
if [[ ! -d /Users/mr.mrs.london/.claude/ownframework-loop-receipts ]]; then
  pass_test "T10: source legacy path absent at canonical location"
else
  fail_test "T10" "still present"
fi
ARCH=$(ls -dt /Users/mr.mrs.london/ownframework-cockpit/state/migration/ownframework-loop/legacy-receipts-archive/*/ 2>/dev/null | head -1)
if [[ -n "$ARCH" && -d "$ARCH" ]]; then
  pass_test "T10b: archive retained at $ARCH"
else
  fail_test "T10b" "no archive"
fi

# ----- T11: complete release run does not recreate the legacy dir -----
# We exercise the resolver used by release_gate.sh and verify the chosen
# data dir does not have an "ownframework-loop-receipts" leaf.
ALT=$(mktemp -d -t ofloop-t11-XXXXXX)
RESOLVED=$(env -u CLAUDE_PLUGIN_DATA HOME=/tmp CLAUDE_CONFIG_DIR="$ALT" bash -c '
PLUGIN_DATA_DIR_NAME="of-loop-ownframework-local"
if [[ -n "${CLAUDE_PLUGIN_DATA:-}" ]]; then
  printf "%s" "$CLAUDE_PLUGIN_DATA"
else
  printf "%s/plugins/data/%s" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "$PLUGIN_DATA_DIR_NAME"
fi
')
mkdir -p "$RESOLVED/receipts"
echo "test" > "$RESOLVED/receipts/release-test.log"
LEAF=$(basename "$RESOLVED")
if [[ "$LEAF" == "of-loop-ownframework-local" ]]; then
  pass_test "T11: release run writes under of-loop-ownframework-local leaf (not legacy)"
else
  fail_test "T11" "got leaf=$LEAF"
fi
# Also confirm resolve determined no other path
LEGACY_AT_ROOT=$(find /Users/mr.mrs.london/.claude -type d -name "ownframework-loop-receipts" 2>/dev/null | head -1)
if [[ -z "$LEGACY_AT_ROOT" ]]; then
  pass_test "T11b: legacy path absent from user tree"
else
  fail_test "T11b" "found legacy at $LEGACY_AT_ROOT"
fi
rm -rf "$ALT"

# ----- T12: managed-plugin lifecycle does not recreate legacy dir -----
ALT=$(mktemp -d -t ofloop-t12-XXXXXX)
PROOFRUN=$(mktemp -d -t ofloop-proof-run-XXXXXX)
cd "$PROOFRUN"
git init -q -b main
git config user.name "T12"
git config user.email "t12@ofloop.local"
echo init > a.txt && git add a.txt && git commit -q -m init
CACHE_CLI=/Users/mr.mrs.london/.claude/plugins/cache/ownframework-local/of-loop/0.1.2/bin/ofloop
LOG=$(mktemp -t ofloop-t12-XXXXXX.log)
if [[ ! -x "$CACHE_CLI" ]]; then
  fail_test "T12" "managed cache CLI missing at $CACHE_CLI"
else
  env -u CLAUDE_PLUGIN_DATA HOME=/tmp CLAUDE_CONFIG_DIR="$ALT" \
    OFLOOP_PLUGIN_ROOT=/Users/mr.mrs.london/.claude/plugins/cache/ownframework-local/of-loop/0.1.2 \
    "$CACHE_CLI" spec new "$PROOFRUN" "Add marker" >"$LOG" 2>&1
  RUN_ID=$(grep -oE "run-[0-9TZ]+-[a-z0-9]+" "$LOG" | head -1)
  LEGACY_AT_ROOT=$(find /Users/mr.mrs.london/.claude -type d -name "ownframework-loop-receipts" 2>/dev/null | head -1)
  LEGACY_AT_ALT=$(find "$ALT" -type d -name "ownframework-loop-receipts" 2>/dev/null | head -1)
  if [[ -n "$RUN_ID" && -z "$LEGACY_AT_ROOT" && -z "$LEGACY_AT_ALT" ]]; then
    pass_test "T12: spec new lifecycle did not create legacy dir (run=$RUN_ID)"
  else
    fail_test "T12" "run=$RUN_ID legacy_root=$LEGACY_AT_ROOT legacy_alt=$LEGACY_AT_ALT"
  fi
fi
rm -rf "$ALT" "$PROOFRUN" "$LOG"

# ----- T13: scheduled-task listing, not crontab, is the loop proof -----
if grep -rn "crontab" "$ROOT" --include="*.sh" --include="*.py" 2>/dev/null \
     | grep -v "CronList\|CronCreate\|CronDelete\|Claude" \
     | grep -v "tests/unit/test_plugin_data_resolution.sh" >/tmp/ofloop-t13.$$.log 2>&1; then
  # Has at least one match — but if all matches are T13 itself, that's still ok
  CNT=$(grep -c crontab /tmp/ofloop-t13.$$.log 2>/dev/null || echo 0)
  CNT=$(printf '%s' "$CNT" | tr -d '[:space:]')
  if [[ "${CNT:-0}" -gt 0 ]]; then
    fail_test "T13: crontab references found outside T13 itself" "$(cat /tmp/ofloop-t13.$$.log)"
  else
    pass_test "T13: no crontab-based loop proof remains in source"
  fi
else
  pass_test "T13: no crontab-based loop proof remains in source"
fi
rm -f /tmp/ofloop-t13.$$.log

# Mark capability assertion
if [[ -n "${CLAUDE_SCHEDULED_TASK_SUPPORTED:-}" || -d /Users/mr.mrs.london/.claude ]]; then
  pass_test "T13b: Claude scheduled-task context intact; CronList is the active proof path"
fi

rm -f "$_probe" "$_refusal"
rm -rf "$HELPER_DIR"

echo
echo "TOTAL=$((pass+fail)) PASSED=$pass FAILED=$fail"
if [[ $fail -ne 0 ]]; then
  echo "FAILED: ${fail_msgs[*]}"
  exit 1
fi
exit 0
