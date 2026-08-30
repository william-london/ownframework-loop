#!/usr/bin/env bash
# Linux systemd-user supervisor portability + Claude sandbox readiness.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "LINUX_SUPERVISOR_SERVICE=SKIPPED reason=non_linux"
  exit 0
fi

TMP="$(mktemp -d -t ofloop-linux-service-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP
export HOME="$TMP/home"
export XDG_DATA_HOME="$TMP/data"
export XDG_STATE_HOME="$TMP/state"
export XDG_CONFIG_HOME="$TMP/config"
export OFLOOP_BIN_DIR="$TMP/bin"
export OFLOOP_SYSTEMD_USER_DIR="$TMP/systemd-user"
FAKE="$TMP/fakebin"
mkdir -p "$HOME" "$FAKE" "$OFLOOP_SYSTEMD_USER_DIR"

# Install vendor-neutral core first.
bash "$ROOT_DIR/install.sh" >"$TMP/core.out"
CORE_ROOT="$(sed -n 's/^CORE_ROOT=//p' "$TMP/core.out" | tail -n1)"
EXPECTED_VERSION="$(sed -n 's/^VERSION=//p' "$TMP/core.out" | tail -n1)"
test -x "$CORE_ROOT/bin/ofloop"
test -L "$OFLOOP_BIN_DIR/ofloop"

cat > "$FAKE/systemctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$TMP/systemctl.calls"
exit 0
EOF
cat > "$FAKE/bwrap" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$FAKE/socat" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$FAKE/claude" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then echo "2.1.247 (Claude Code)"; exit 0; fi
exit 0
EOF
chmod +x "$FAKE/"*

PATH="$OFLOOP_BIN_DIR:$FAKE:/usr/bin:/bin"
export PATH
export SYSTEMCTL_BIN="$FAKE/systemctl"
export CLAUDE_BIN="$FAKE/claude"

# Old Claude fails at commissioning, before a service is written.
if "$CORE_ROOT/install-supervisor.sh" >"$TMP/old.out" 2>&1; then
  echo "FAIL: Claude below minimum commissioned on Linux" >&2
  exit 1
fi
grep -F 'reason=claude_version_unsupported minimum=2.1.248' "$TMP/old.out" >/dev/null
test ! -e "$OFLOOP_SYSTEMD_USER_DIR/ownframework-loop-supervisor.service"

cat > "$FAKE/claude" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then echo "2.1.251 (Claude Code)"; exit 0; fi
exit 0
EOF
chmod +x "$FAKE/claude"

"$CORE_ROOT/install-supervisor.sh" | tee "$TMP/install.out"
grep -F 'SUPERVISOR_INSTALL=PASS' "$TMP/install.out" >/dev/null
grep -F 'SERVICE_MANAGER=systemd-user' "$TMP/install.out" >/dev/null

UNIT="$OFLOOP_SYSTEMD_USER_DIR/ownframework-loop-supervisor.service"
PROV="$XDG_STATE_HOME/ownframework-loop/runtime-provenance.json"
DB="$XDG_STATE_HOME/ownframework-loop/supervisor.sqlite3"
test -f "$UNIT"
test -f "$PROV"
grep -F "supervisor serve" "$UNIT" >/dev/null
grep -F "OFLOOP_RUNTIME_ROOT=$CORE_ROOT" "$UNIT" >/dev/null
grep -F "OFLOOP_CLAUDE_BIN=$(python3 -B - "$FAKE/claude" <<'PY'
import sys
from pathlib import Path
print(Path(sys.argv[1]).resolve(strict=False))
PY
)" "$UNIT" >/dev/null

PYTHONPATH="$CORE_ROOT/lib" python3 -B - "$PROV" "$CORE_ROOT" "$EXPECTED_VERSION" <<'PY'
import json,sys
from pathlib import Path
p=json.load(open(sys.argv[1],encoding="utf-8"))
root=str(Path(sys.argv[2]).resolve(strict=False))
version=sys.argv[3]
assert p["service_manager"]=="systemd-user",p
assert p["runtime_root"]==root,p
assert p["ofloop_bin"]==str(Path(root,"bin","ofloop")),p
assert p["ofloop_version"]==version,p
assert p["runtime_generation"].startswith(f"ofloop-{version}@payload-"),p
PY

# Model the ledger the real launched supervisor creates, then prove an ordinary
# same-generation core refresh has no migration/active-work override.
PYTHONPATH="$CORE_ROOT/lib" python3 -B - "$DB" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import supervisor
with supervisor._connect(Path(sys.argv[1])):
    pass
PY

"$CORE_ROOT/scripts/refresh-existing-supervisor.sh" "$CORE_ROOT" "$ROOT_DIR" | tee "$TMP/refresh.out"
grep -F 'SUPERVISOR_REFRESH=PASS' "$TMP/refresh.out" >/dev/null

"$CORE_ROOT/uninstall-supervisor.sh" | tee "$TMP/uninstall.out"
grep -F 'SUPERVISOR_UNINSTALL=PASS' "$TMP/uninstall.out" >/dev/null
test ! -e "$UNIT"
test ! -e "$PROV"
test -f "$DB"
grep -F -- '--user daemon-reload' "$TMP/systemctl.calls" >/dev/null
grep -F -- '--user enable --now ownframework-loop-supervisor.service' "$TMP/systemctl.calls" >/dev/null
grep -F -- '--user disable --now ownframework-loop-supervisor.service' "$TMP/systemctl.calls" >/dev/null

echo "LINUX_SUPERVISOR_SERVICE=PASS"
