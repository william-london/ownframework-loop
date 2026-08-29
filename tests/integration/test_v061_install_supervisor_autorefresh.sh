#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SRC="$TMP/source"
HOME_FAKE="$TMP/home"
FAKEBIN="$TMP/fakebin"
mkdir -p "$HOME_FAKE" "$FAKEBIN"

# Work from an isolated real Git clone so install provenance remains meaningful.
git clone -q "$ROOT_DIR" "$SRC"
HEAD_EXPECTED="$(git -C "$SRC" rev-parse HEAD)"

# Fake platform/runtime tools. The installer sees Darwin, while launchctl is
# harmless. Claude implements only the plugin-manager calls install.sh uses.
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
set -euo pipefail
if [[ "$*" == "plugin marketplace list" ]]; then
  echo ownframework
  exit 0
fi
if [[ "${1:-}" == "plugin" && "${2:-}" == "marketplace" && "${3:-}" == "add" ]]; then
  exit 0
fi
if [[ "${1:-}" == "plugin" && "${2:-}" == "uninstall" ]]; then
  exit 0
fi
if [[ "${1:-}" == "plugin" && "${2:-}" == "install" ]]; then
  dest="$HOME/.claude/plugins/cache/ownframework/of-loop/0.6.1"
  mkdir -p "$dest"
  cp -R "$FAKE_SOURCE"/. "$dest"/
  exit 0
fi
echo "unexpected fake claude args: $*" >&2
exit 97
EOF
chmod +x "$FAKEBIN/claude"

# Existing plist is the operator-intent signal: refresh an already commissioned
# supervisor, but do not create one implicitly on a fresh install.
mkdir -p "$HOME_FAKE/Library/LaunchAgents"
echo existing > "$HOME_FAKE/Library/LaunchAgents/com.ownframework.loop-supervisor.plist"

OUT="$TMP/install.out"
(cd "$SRC" && env \
  HOME="$HOME_FAKE" \
  PATH="$FAKEBIN:/usr/local/bin:/usr/bin:/bin" \
  FAKE_SOURCE="$SRC" \
  SOURCE_ROOT="$SRC" \
  bash "$SRC/install.sh" >"$OUT" 2>&1)

CACHE="$HOME_FAKE/.claude/plugins/cache/ownframework/of-loop/0.6.1"
PLIST="$HOME_FAKE/Library/LaunchAgents/com.ownframework.loop-supervisor.plist"
PROV="$HOME_FAKE/.local/state/ownframework-loop/runtime-provenance.json"
[[ -x "$CACHE/bin/ofloop" ]] || fail "installed cache ofloop missing"
[[ -f "$PLIST" ]] || fail "refreshed plist missing"
[[ -f "$PROV" ]] || fail "refreshed runtime provenance missing"
grep -Fq "existing macOS supervisor refreshed" "$OUT" || fail "install did not report supervisor refresh"

python3 - "$PLIST" "$PROV" "$CACHE/bin/ofloop" "$SRC" "$HEAD_EXPECTED" <<'PY'
import json, plistlib, sys
from pathlib import Path
plist_path, prov_path, ofloop, source, head = sys.argv[1:]
with open(plist_path, 'rb') as f:
    plist = plistlib.load(f)
prov = json.load(open(prov_path))
expected_ofloop = str(Path(ofloop).resolve(strict=False))
expected_source = str(Path(source).resolve(strict=False))
assert plist['ProgramArguments'] == [expected_ofloop, 'supervisor', 'serve'], plist
assert prov['ofloop_bin'] == expected_ofloop, prov
assert prov['source_root'] == expected_source, prov
assert prov['source_head'] == head, prov
assert prov['ofloop_version'] == '0.6.1', prov
assert plist['EnvironmentVariables']['OFLOOP_PLUGIN_ROOT'] == str(Path(expected_ofloop).parent.parent), plist
PY

# Fresh HOME with no prior supervisor signal must not create a service.
HOME_FRESH="$TMP/home-fresh"
mkdir -p "$HOME_FRESH"
OUT2="$TMP/install-fresh.out"
(cd "$SRC" && env \
  HOME="$HOME_FRESH" \
  PATH="$FAKEBIN:/usr/local/bin:/usr/bin:/bin" \
  FAKE_SOURCE="$SRC" \
  SOURCE_ROOT="$SRC" \
  bash "$SRC/install.sh" >"$OUT2" 2>&1)
[[ ! -e "$HOME_FRESH/Library/LaunchAgents/com.ownframework.loop-supervisor.plist" ]] || fail "fresh install implicitly created supervisor"
[[ ! -e "$HOME_FRESH/.local/state/ownframework-loop/runtime-provenance.json" ]] || fail "fresh install implicitly created supervisor provenance"

echo "V061_INSTALL_SUPERVISOR_AUTOREFRESH=PASS"
