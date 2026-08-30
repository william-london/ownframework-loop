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
mkdir -p "$HOME/.claude" "$FAKE" "$OFLOOP_SYSTEMD_USER_DIR"
printf '{"oauth":"fixture"}\n' > "$HOME/.claude/.credentials.json"
chmod 0600 "$HOME/.claude/.credentials.json"

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
cat > "$FAKE/loginctl" <<'EOF'
#!/usr/bin/env bash
echo yes
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
export ANTHROPIC_AUTH_TOKEN="linux-test-token"
export ANTHROPIC_BASE_URL="https://api.example.invalid/anthropic"
export ANTHROPIC_MODEL="linux-test-model"

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
grep -F 'USER_MANAGER_PERSISTENCE=linger-enabled' "$TMP/install.out" >/dev/null

UNIT="$OFLOOP_SYSTEMD_USER_DIR/ownframework-loop-supervisor.service"
PROV="$XDG_STATE_HOME/ownframework-loop/runtime-provenance.json"
SERVICE_ENV="$XDG_STATE_HOME/ownframework-loop/service-env.json"
STATE_ROOT="$XDG_STATE_HOME/ownframework-loop"
DB="$STATE_ROOT/supervisor.sqlite3"
test -f "$UNIT"
test -f "$PROV"
test -f "$SERVICE_ENV"
test -f "$DB"
test -f "$STATE_ROOT/ledger-incarnation.json"
EXPECTED_PY="$(python3 -B - "$PROV" <<'PY'
import json,sys
print(json.load(open(sys.argv[1],encoding="utf-8"))["python_bin"])
PY
)"
grep -F "ExecStart=\"$EXPECTED_PY\" -B \"$CORE_ROOT/scripts/launch-commissioned-supervisor.py\"" "$UNIT" >/dev/null
grep -F -- "--db \"$DB\"" "$UNIT" >/dev/null
grep -F -- "--ofloop \"$CORE_ROOT/bin/ofloop\"" "$UNIT" >/dev/null
grep -F "OFLOOP_RUNTIME_ROOT=$CORE_ROOT" "$UNIT" >/dev/null
grep -F "OFLOOP_CLAUDE_BIN=$(python3 -B - "$FAKE/claude" <<'PY'
import sys
from pathlib import Path
print(Path(sys.argv[1]).resolve(strict=False))
PY
)" "$UNIT" >/dev/null

grep -F "OFLOOP_SERVICE_ENV_FILE=$SERVICE_ENV" "$UNIT" >/dev/null
grep -F "OFLOOP_ADAPTER_AUTH_READ_PATHS=$HOME/.claude/.credentials.json" "$UNIT" >/dev/null
if grep -Eq 'ANTHROPIC_(AUTH_TOKEN|API_KEY|BASE_URL|MODEL)=' "$UNIT"; then
  echo "FAIL: systemd unit leaked provider auth/model material" >&2
  exit 1
fi

python3 -B - "$UNIT" "$PROV" "$SERVICE_ENV" "$STATE_ROOT" "$HOME/.claude/.credentials.json" <<'PY'
import json, pathlib, stat, sys
unit, prov, service_env, state_root, credential = map(pathlib.Path, sys.argv[1:])
secret=json.loads(service_env.read_text(encoding="utf-8"))
assert secret["ANTHROPIC_AUTH_TOKEN"]=="linux-test-token", secret
assert secret["ANTHROPIC_BASE_URL"]=="https://api.example.invalid/anthropic", secret
assert secret["ANTHROPIC_MODEL"]=="linux-test-model", secret
provenance=json.loads(prov.read_text(encoding="utf-8"))
assert provenance["service_env_file"]==str(service_env), provenance
assert "linux-test-token" not in prov.read_text(encoding="utf-8")
assert stat.S_IMODE(state_root.stat().st_mode)==0o700
for path in (unit, prov, service_env, credential):
    assert stat.S_IMODE(path.stat().st_mode)==0o600, (path, oct(stat.S_IMODE(path.stat().st_mode)))
PY

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
assert p["service_env_file"].endswith("/ownframework-loop/service-env.json"),p
assert p["user_manager_persistence"]=="linger-enabled",p
assert p["ledger_incarnation_file"].endswith("/ownframework-loop/ledger-incarnation.json"),p
assert p["service_entrypoint"].endswith("/scripts/launch-commissioned-supervisor.py"),p
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
test ! -e "$SERVICE_ENV"
test -f "$DB"
grep -F -- '--user daemon-reload' "$TMP/systemctl.calls" >/dev/null
grep -F -- '--user enable --now ownframework-loop-supervisor.service' "$TMP/systemctl.calls" >/dev/null
grep -F -- '--user disable --now ownframework-loop-supervisor.service' "$TMP/systemctl.calls" >/dev/null

echo "LINUX_SUPERVISOR_SERVICE=PASS"
