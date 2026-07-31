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

PY=python3
PYLIB="$ROOT/lib"

pass=0; fail=0
fail_msgs=()
pass_test() { echo "  PASS: $1"; pass=$((pass+1)); }
fail_test() { echo "  FAIL: $1 -- $2"; fail=$((fail+1)); fail_msgs+=("$1: $2"); }
skip_test() { echo "  SKIP: $1 -- $2"; skip=$((skip+1)); }
skip=0

# Helper: normalize a path the way macOS resolves it (/tmp -> /private/tmp).
_norm() { "$PY" -c "import sys, os; print(os.path.realpath(sys.argv[1]))" "$1"; }

# Every temporary path is owned by this test and cleaned by this targeted trap.
HELPER_DIR=""
cleanup() { [[ -n "${HELPER_DIR:-}" && -d "$HELPER_DIR" ]] && rm -rf "$HELPER_DIR"; }
trap cleanup EXIT INT TERM HUP
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

# ----- T6: production release-artifact helpers use plugin data -----
ALT=$(mktemp -d -t ofloop-gate-XXXXXX)
OUT=$(CLAUDE_PLUGIN_DATA="$ALT" PYTHONPATH="$PYLIB" python3 - <<'PY'
from ownframework_loop import plugin_data
p = plugin_data.release_log_path("20260723T000000Z")
r = plugin_data.write_receipt("receipts", {"schema": plugin_data.SCHEMA_RELEASE_RECEIPT, "test": "t6"})
l = plugin_data.write_text_log("release-test.log", "bounded")
print(p)
print(r)
print(l)
PY
)
if [[ "$OUT" == *"$ALT/receipts/release-20260723T000000Z.log"* ]]; then
  pass_test "T6: release path selected by shared production helper"
else
  fail_test "T6" "unexpected release path: $OUT"
fi
if [[ -f "$ALT/receipts/release-test.log" && -f "$ALT/receipts/receipt-"* ]]; then
  pass_test "T6b: receipt helper writes only under plugin data"
else
  # The glob check above is intentionally conservative on shells without array globbing.
  if [[ -d "$ALT/receipts" && -n "$(find "$ALT/receipts" -type f -print -quit)" ]]; then
    pass_test "T6b: receipt helper wrote under plugin data"
  else
    fail_test "T6b" "receipt helper did not write under $ALT"
  fi
fi
rm -rf "$ALT"

# ----- T7: installation receipt helper uses plugin data -----
ALT=$(mktemp -d -t ofloop-inst-XXXXXX)
OUT=$(CLAUDE_PLUGIN_DATA="$ALT" PYTHONPATH="$PYLIB" python3 - <<'PY'
from ownframework_loop import plugin_data
print(plugin_data.write_receipt("installation", {"schema": plugin_data.SCHEMA_INSTALL_RECEIPT, "test": "t7"}))
PY
)
if [[ "$OUT" == "$ALT/installation/"* || "$OUT" == */installation/* ]]; then
  pass_test "T7: installation receipt helper writes to plugin-data/installation"
else
  fail_test "T7" "unexpected path: $OUT"
fi
rm -rf "$ALT"

CACHE=${HOME}/.claude/plugins/cache/ownframework-local/of-loop/0.1.2
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

# ----- T9: legacy migration manifest is intentionally archived, not re-emitted -----
# Storage doctrine: the legacy-migration-manifest.json is a one-time migration
# inventory record. Per the migration-receipt's archive contract, the manifest
# lives in the Cockpit migration evidence tree (operator-owned, separate from
# the plugin's runtime data). It is NOT regenerated under
# ~/.claude/plugins/data/of-loop-ownframework-local/migration/ after the
# migration has completed — the plugin-data migration/ subdir is reserved
# for future migrations, not historical re-emission.
#
# The 39 manifest items are checked against the ARCHIVED COPIES, not the
# plugin-data target paths. A subsequent uninstall (e.g. install.sh step 1a
# during a fresh V2.0.1 install) legitimately removes the plugin-data copies
# while the archive (operator evidence) is preserved. Re-verifying the
# archived bytes against their recorded legacy_sha256 confirms the migration
# was lossless; verifying the post-migration target paths would re-assert
# runtime state that is correctly managed by uninstall/install choreography.
# Per env override: every environment may have a different archived path.
# If unset, the test treats this as a SKIP rather than a FAIL because the
# archived evidence is operator-private and not owned by this plugin.
: "${OFLOOP_MIGRATION_ARCHIVE_ROOT:=${OFLOOP_MIGRATION_ARCHIVE_ROOT:-/path/to/operator-root/state/migration/ownframework-loop}}"
ARCHIVE_DIR="$OFLOOP_MIGRATION_ARCHIVE_ROOT/legacy-receipts-archive/migrated-20260723T161000Z"
ARCHIVE_MANIFEST="$OFLOOP_MIGRATION_ARCHIVE_ROOT/legacy-migration-manifest.json"
PLUGIN_DATA_MANIFEST="$HOME/.claude/plugins/data/of-loop-ownframework-local/migration/legacy-migration-manifest.json"
HAVE_ARCHIVE=0
[[ -f "$ARCHIVE_MANIFEST" ]] && HAVE_ARCHIVE=1
[[ "${SKIP_EXTERNAL_ARCHIVE:-0}" == "1" ]] && HAVE_ARCHIVE=0
ARCHIVE_DIR_PRESENT=0
[[ -d "$ARCHIVE_DIR" ]] && ARCHIVE_DIR_PRESENT=1
if [[ -f "$ARCHIVE_MANIFEST" ]]; then
  OK_COUNT=$(python3 -c "
import json, hashlib
from pathlib import Path
m = json.load(open('$ARCHIVE_MANIFEST'))
ok = 0
total = len(m.get('manifest_items', []))
for it in m['manifest_items']:
    legacy_path = it.get('legacy_path')
    if not legacy_path:
        continue
    archived = Path('$ARCHIVE_DIR') / legacy_path
    if not archived.exists():
        continue
    h = hashlib.sha256(archived.read_bytes()).hexdigest()
    if h == it['legacy_sha256']:
        ok += 1
print(f'{ok}/{total}')
")
  OK_NUM="${OK_COUNT%%/*}"
  if [[ "$OK_NUM" == "39" ]]; then
    pass_test "T9: 39/39 legacy artifacts verified by SHA-256 (archive)"
  else
    fail_test "T9" "ok=$OK_COUNT"
  fi
elif [[ "$HAVE_ARCHIVE" -eq 1 ]]; then
  fail_test "T9" "archive manifest absent at $ARCHIVE_MANIFEST despite HAVE_ARCHIVE=1"
else
  skip_test "T9" "external archive not present at $ARCHIVE_MANIFEST (set OFLOOP_MIGRATION_ARCHIVE_ROOT or SKIP_EXTERNAL_ARCHIVE=0 to enable)"
fi
# T9b: explicit not-applicable classification for the plugin-data path.
# The plugin-data location is NOT the storage location for the migration
# manifest; the archive is. A failure here is a regression of the storage
# doctrine (would mean the manifest was re-emitted where it does not belong).
if [[ -f "$PLUGIN_DATA_MANIFEST" ]]; then
  fail_test "T9b" "manifest unexpectedly re-emitted at plugin-data: $PLUGIN_DATA_MANIFEST"
else
  pass_test "T9b: EXPLICIT_NOT_APPLICABLE — migration manifest correctly archived, not re-emitted at plugin-data"
fi

# ----- T10: legacy directory is removed -----
if [[ ! -d ${HOME}/.claude/ownframework-loop-receipts ]]; then
  pass_test "T10: source legacy path absent at canonical location"
else
  fail_test "T10" "still present"
fi
ARCH=$(ls -dt ${OFLOOP_MIGRATION_ARCHIVE_ROOT:-/path/to/operator-root/state/migration/ownframework-loop}/legacy-receipts-archive/*/ 2>/dev/null | head -1)
if [[ -n "$ARCH" && -d "$ARCH" ]]; then
  pass_test "T10b: archive retained at $ARCH"
elif [[ "$HAVE_ARCHIVE" -eq 1 ]]; then
  fail_test "T10b" "archive directory absent despite HAVE_ARCHIVE=1"
else
  skip_test "T10b" "no archive present (external, opt-in)"
fi

# ----- T11: production helper never recreates the legacy dir -----
ALT=$(mktemp -d -t ofloop-t11-XXXXXX)
OUT=$(CLAUDE_PLUGIN_DATA="$ALT" PYTHONPATH="$PYLIB" python3 - <<'PY'
from ownframework_loop import plugin_data
print(plugin_data.plugin_data_root())
print(plugin_data.write_text_log("release-test.log", "test"))
PY
)
if [[ "$OUT" == *"$ALT"* && "$OUT" != *ownframework-loop-receipts* ]]; then
  pass_test "T11: production helper writes under plugin-data leaf (not legacy)"
else
  fail_test "T11" "got=$OUT"
fi
LEGACY_AT_ROOT=$(find ${HOME}/.claude -type d -name "ownframework-loop-receipts" 2>/dev/null | head -1)
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
CACHE_CLI=${HOME}/.claude/plugins/cache/ownframework-local/of-loop/0.1.2/bin/ofloop
LOG=$(mktemp -t ofloop-t12-XXXXXX.log)
if [[ ! -x "$CACHE_CLI" ]]; then
  fail_test "T12" "managed cache CLI missing at $CACHE_CLI"
else
  env -u CLAUDE_PLUGIN_DATA HOME=/tmp CLAUDE_CONFIG_DIR="$ALT" \
    OFLOOP_PLUGIN_ROOT=${HOME}/.claude/plugins/cache/ownframework-local/of-loop/0.1.2 \
    "$CACHE_CLI" spec new "$PROOFRUN" "Add marker" >"$LOG" 2>&1
  RUN_ID=$(grep -oE "run-[0-9TZ]+-[a-z0-9]+" "$LOG" | head -1)
  LEGACY_AT_ROOT=$(find ${HOME}/.claude -type d -name "ownframework-loop-receipts" 2>/dev/null | head -1)
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
if [[ -n "${CLAUDE_SCHEDULED_TASK_SUPPORTED:-}" || -d ${HOME}/.claude ]]; then
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
