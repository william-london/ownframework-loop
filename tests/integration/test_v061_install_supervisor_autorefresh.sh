#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SRC="$TMP/source"
CORE="$TMP/core"
HOME_EXISTING="$TMP/home-existing"
HOME_FRESH="$TMP/home-fresh"
FAKEBIN="$TMP/fakebin"
mkdir -p "$HOME_EXISTING" "$HOME_FRESH" "$FAKEBIN"

git clone -q "$ROOT_DIR" "$SRC"
mkdir -p "$CORE"
cp -R "$SRC"/. "$CORE"/
HEAD_EXPECTED="$(git -C "$SRC" rev-parse HEAD)"
VERSION_EXPECTED="$(PYTHONPATH="$SRC/lib" python3 - <<'PY'
from ownframework_loop import __version__
print(__version__)
PY
)"

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
if [[ "${1:-}" == "--version" ]]; then echo "2.1.251 (Claude Code)"; fi
exit 0
EOF
chmod +x "$FAKEBIN/claude"

# Provide the SAME python3 to the install/refresh probe that the DB was
# created with. Without this, a host that ships multiple pythons (e.g.
# macOS with /usr/bin/python3 and /opt/homebrew/bin/python3) creates the
# ledger under one major Python and probes it under another, which the
# sqlite3 module can refuse to read even when the on-disk format is
# wire-compatible.
cat > "$FAKEBIN/python3" <<EOF
#!/usr/bin/env bash
exec "$(command -v python3)" "\$@"
EOF
chmod +x "$FAKEBIN/python3"

# Existing commissioning signal must refresh to CORE/bin/ofloop.
mkdir -p "$HOME_EXISTING/Library/LaunchAgents"
echo existing > "$HOME_EXISTING/Library/LaunchAgents/com.ownframework.loop-supervisor.plist"
# v0.8.2 lifecycle safety: a commissioned service without its ledger is
# intentionally unverifiable and fails closed. Model a legitimate existing
# commissioning with an intact empty ledger (no unfinished runtime dependencies).
PYTHONPATH="$SRC/lib" python3 -B - "$HOME_EXISTING" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import supervisor
db = Path(sys.argv[1]) / ".local" / "state" / "ownframework-loop" / "supervisor.sqlite3"
with supervisor._connect(db):
    pass
PY
OUT="$TMP/refresh.out"
set +e
env HOME="$HOME_EXISTING" PATH="$FAKEBIN:/usr/local/bin:/usr/bin:/bin" \
  "$CORE/scripts/refresh-existing-supervisor.sh" "$CORE" "$SRC" >"$OUT" 2>&1
REFRESH_RC=$?
set -e
if [[ "$REFRESH_RC" -ne 0 ]]; then
  cat "$OUT" >&2
  fail "existing supervisor refresh returned rc=$REFRESH_RC"
fi
grep -Fq "SUPERVISOR_REFRESH=PASS" "$OUT" || {
  cat "$OUT" >&2
  fail "existing supervisor did not refresh"
}
PLIST="$HOME_EXISTING/Library/LaunchAgents/com.ownframework.loop-supervisor.plist"
PROV="$HOME_EXISTING/.local/state/ownframework-loop/runtime-provenance.json"
[[ -f "$PROV" ]] || fail "runtime provenance missing after refresh"

python3 - "$PLIST" "$PROV" "$CORE/bin/ofloop" "$SRC" "$HEAD_EXPECTED" "$VERSION_EXPECTED" <<'PY'
import json, plistlib, sys
from pathlib import Path
plist_path, prov_path, ofloop, source, head, version = sys.argv[1:]
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
assert prov['ofloop_version'] == version, prov
PY

# Fresh host has no commissioning signal: helper must be a true no-op.
OUT2="$TMP/fresh.out"
env HOME="$HOME_FRESH" PATH="$FAKEBIN:/usr/local/bin:/usr/bin:/bin" \
  "$CORE/scripts/refresh-existing-supervisor.sh" "$CORE" "$SRC" >"$OUT2" 2>&1
grep -Fq "SUPERVISOR_REFRESH=NOOP reason=not_commissioned" "$OUT2" || fail "fresh host was not a no-op"
[[ ! -e "$HOME_FRESH/Library/LaunchAgents/com.ownframework.loop-supervisor.plist" ]] || fail "fresh host got implicit service"

# Opt-out remains explicit and non-mutating.
OUT3="$TMP/skip.out"
env HOME="$HOME_EXISTING" PATH="$FAKEBIN:/usr/local/bin:/usr/bin:/bin" OFLOOP_SKIP_SUPERVISOR_REFRESH=1 \
  "$CORE/scripts/refresh-existing-supervisor.sh" "$CORE" "$SRC" >"$OUT3" 2>&1
grep -Fq "SUPERVISOR_REFRESH=SKIPPED reason=operator_opt_out" "$OUT3" || fail "opt-out not honored"

echo "V061_INSTALL_SUPERVISOR_AUTOREFRESH=PASS"
