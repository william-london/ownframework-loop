#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SRC="$TMP/source"
CACHE="$TMP/cache"
HOME_EXISTING="$TMP/home-existing"
HOME_FRESH="$TMP/home-fresh"
FAKEBIN="$TMP/fakebin"
mkdir -p "$HOME_EXISTING" "$HOME_FRESH" "$FAKEBIN"

git clone -q "$ROOT_DIR" "$SRC"
mkdir -p "$CACHE"
cp -R "$SRC"/. "$CACHE"/
HEAD_EXPECTED="$(git -C "$SRC" rev-parse HEAD)"

cat > "$FAKEBIN/uname" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-s" ]]; then echo Darwin; else /usr/bin/uname "$@"; fi
EOF
chmod +x "$FAKEBIN/uname"

cat > "$FAKEBIN/launchctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKEBIN/launchctl"

cat > "$FAKEBIN/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKEBIN/claude"

# Existing commissioning signal must refresh to CACHE/bin/ofloop.
mkdir -p "$HOME_EXISTING/Library/LaunchAgents"
echo existing > "$HOME_EXISTING/Library/LaunchAgents/com.ownframework.loop-supervisor.plist"
OUT="$TMP/refresh.out"
env HOME="$HOME_EXISTING" PATH="$FAKEBIN:/usr/local/bin:/usr/bin:/bin" \
  "$CACHE/scripts/refresh-existing-supervisor-macos.sh" "$CACHE" "$SRC" >"$OUT" 2>&1
grep -Fq "SUPERVISOR_REFRESH=PASS" "$OUT" || fail "existing supervisor did not refresh"
PLIST="$HOME_EXISTING/Library/LaunchAgents/com.ownframework.loop-supervisor.plist"
PROV="$HOME_EXISTING/.local/state/ownframework-loop/runtime-provenance.json"
[[ -f "$PROV" ]] || fail "runtime provenance missing after refresh"

python3 - "$PLIST" "$PROV" "$CACHE/bin/ofloop" "$SRC" "$HEAD_EXPECTED" <<'PY'
import json, plistlib, sys
from pathlib import Path
plist_path, prov_path, ofloop, source, head = sys.argv[1:]
with open(plist_path, 'rb') as f:
    plist = plistlib.load(f)
with open(prov_path) as f:
    prov = json.load(f)
expected_ofloop = str(Path(ofloop).resolve(strict=False))
expected_source = str(Path(source).resolve(strict=False))
assert plist['ProgramArguments'] == [expected_ofloop, 'supervisor', 'serve'], plist
assert prov['ofloop_bin'] == expected_ofloop, prov
assert prov['source_root'] == expected_source, prov
assert prov['source_head'] == head, prov
assert prov['ofloop_version'] == '0.6.1', prov
PY

# Fresh host has no commissioning signal: helper must be a true no-op.
OUT2="$TMP/fresh.out"
env HOME="$HOME_FRESH" PATH="$FAKEBIN:/usr/local/bin:/usr/bin:/bin" \
  "$CACHE/scripts/refresh-existing-supervisor-macos.sh" "$CACHE" "$SRC" >"$OUT2" 2>&1
grep -Fq "SUPERVISOR_REFRESH=NOOP reason=not_commissioned" "$OUT2" || fail "fresh host was not a no-op"
[[ ! -e "$HOME_FRESH/Library/LaunchAgents/com.ownframework.loop-supervisor.plist" ]] || fail "fresh host got implicit service"

# Opt-out remains explicit and non-mutating.
OUT3="$TMP/skip.out"
env HOME="$HOME_EXISTING" PATH="$FAKEBIN:/usr/local/bin:/usr/bin:/bin" OFLOOP_SKIP_SUPERVISOR_REFRESH=1 \
  "$CACHE/scripts/refresh-existing-supervisor-macos.sh" "$CACHE" "$SRC" >"$OUT3" 2>&1
grep -Fq "SUPERVISOR_REFRESH=SKIPPED reason=operator_opt_out" "$OUT3" || fail "opt-out not honored"

echo "V061_INSTALL_SUPERVISOR_AUTOREFRESH=PASS"
