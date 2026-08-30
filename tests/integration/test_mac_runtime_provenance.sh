#!/usr/bin/env bash
# v0.6.1 Mac runtime-provenance closure — 8 regression tests.
#
# Proves install-supervisor-macos.sh writes consistent runtime
# provenance and the generated plist + provenance agree byte-for-byte
# on the Claude executable path, the STATE_ROOT, and source identity.
# The tests do NOT actually invoke launchctl; they invoke only the
# bash installer under controlled fake-binary environments and
# inspect the produced artifacts.
#
#   T1: CLAUDE_BIN supplied → plist EnvironmentVariables.OFLOOP_CLAUDE_BIN
#       equals runtime provenance claude_bin, both = canonical resolved path.
#   T2: supervisor runner prefers OFLOOP_CLAUDE_BIN over PATH "claude"
#       when the env var is set.
#   T3: non-executable CLAUDE_BIN supplied → install REFUSED.
#   T4: no Claude binary available → idle-only install supported;
#       claude_bin=null in provenance; OFLOOP_CLAUDE_BIN OMITTED from plist.
#   T5: custom XDG_STATE_HOME → STATE_ROOT, StandardOutPath,
#       StandardErrorPath, runtime-provenance path, and provenance.state_root
#       all agree.
#   T6: default state root = $HOME/.local/state/ownframework-loop.
#   T7: provenance.source_head equals `git rev-parse HEAD` of source.
#   T8: no launchd regression — plist retains RunAtLoad, KeepAlive,
#       ProcessType=Background, ThrottleInterval, exact ofloop ProgramArguments.

set -uo pipefail

# The installer under test is macOS-only by design. On non-Darwin
# runners (CI Linux matrix) the test exits SKIPPED — the installer's
# own `uname -s != Darwin` check refuses with reason=macos_required
# which is correct macOS gate behavior, not a test failure.
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "MAC_RUNTIME_PROVENANCE=SKIPPED reason=installer_is_macos_only"
  exit 0
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
INSTALLER="$ROOT/install-supervisor-macos.sh"
LIB="$ROOT/lib"
EXPECTED_VERSION="$(PYTHONPATH="$LIB" python3 - <<'PY'
from ownframework_loop import __version__
print(__version__)
PY
)"

export PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$LIB"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

# Sandbox: one fake HOME per run so XDG_STATE_HOME / ~/.local/state
# computations are deterministic and never touch the operator's real
# macOS launchd surface.
SANDBOX="$(mktemp -d -t ofloop-macprov.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"
mkdir -p "$HOME"

# Fake python3 / ofloop / claude executables. Each is symlinked to the
# real system binary so the installer's python3 invocation actually
# works; non-executable and idle-only cases use distinct fixtures.
REAL_PY="$(command -v python3)"
REAL_OFLOOP="$ROOT/bin/ofloop"
# ALWAYS provide a fake claude binary in the fakebin dir so the
# installer cannot fall back to a system-installed claude via PATH
# resolution. The test creates a real executable file at a
# deterministic path and uses that for the fakery. This ensures the
# provenance + plist write exactly the symlink target regardless of
# whether a real claude is installed on the runner.
REAL_CLAUDE="$SANDBOX/fakebin-claude/real-claude"
mkdir -p "$SANDBOX/fakebin-claude"
cat > "$REAL_CLAUDE" <<'FAKE_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "2.1.251 (Claude Code)"; fi
exit 0
FAKE_EOF
chmod +x "$REAL_CLAUDE"

write_fake_symlink() {
  local name="$1"
  local real="$2"
  local dir="$SANDBOX/fakebins"
  mkdir -p "$dir"
  ln -sf "$real" "$dir/$name"
  echo "$dir/$name"
}

PYTHON_FAKE_DIR="$SANDBOX/fakebins"
PYTHON_FAKE="$(write_fake_symlink python3 "$REAL_PY")"
OFLOOP_FAKE="$(write_fake_symlink ofloop "$REAL_OFLOOP")"
CLAUDE_FAKE="$(write_fake_symlink claude "$REAL_CLAUDE")"

# Stub launchctl so the installer doesn't touch the real macOS service.
STUB_BIN_DIR="$SANDBOX/stub-bin"
mkdir -p "$STUB_BIN_DIR"
cat > "$STUB_BIN_DIR/launchctl" <<'STUB_EOF'
#!/usr/bin/env bash
exit 0
STUB_EOF
chmod +x "$STUB_BIN_DIR/launchctl"

# Run the installer with controlled env. Uses env -i to ensure no
# operator-side env leaks into the install.
run_installer() {
  (cd "$ROOT" && env -i \
    HOME="$HOME" \
    PATH="$PYTHON_FAKE_DIR:$STUB_BIN_DIR:/usr/bin:/bin" \
    PYTHONPATH="$LIB" \
    PYTHON_BIN="$PYTHON_FAKE" \
    OFLOOP_BIN="$OFLOOP_FAKE" \
    CLAUDE_BIN="${CLAUDE_BIN:-}" \
    XDG_STATE_HOME="${XDG_STATE_HOME:-}" \
    bash "$INSTALLER" 2>&1)
}

# Several cases below are fresh-install provenance tests that intentionally
# switch XDG_STATE_HOME. They must not inherit the plist produced by an earlier
# case, because plist/provenance presence is a real commissioning signal and a
# commissioned service without the matching ledger correctly fails closed.
reset_shared_commissioning() {
  rm -f "$HOME/Library/LaunchAgents/com.ownframework.loop-supervisor.plist"
}

read_plist_key() {
  # Returns the value as Python would print it (no surrounding quotes
  # for strings, no repr prefix). Comparison-friendly.
  "$REAL_PY" - "$1" "$2" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    d = plistlib.load(f)
keys = sys.argv[2].split(".")
v = d
for k in keys:
    v = v.get(k) if isinstance(v, dict) else None
    if v is None:
        break
if v is None:
    print("")
else:
    print(v)
PY
}

# =====================================================================
# T1: CLAUDE_BIN supplied → plist + provenance agree on canonical path
# =====================================================================
echo ""
echo "=== T1: CLAUDE_BIN → plist/provenance agree on canonical path ==="
CLAUDE_BIN="$CLAUDE_FAKE" XDG_STATE_HOME="$SANDBOX/xdg1" run_installer > /tmp/t1.out 2>&1 || true
PROV="$SANDBOX/xdg1/ownframework-loop/runtime-provenance.json"
SERVICE_ENV="$SANDBOX/xdg1/ownframework-loop/service-env.json"
PLIST="$HOME/Library/LaunchAgents/com.ownframework.loop-supervisor.plist"
[[ -f "$PROV" ]] || { fail "T1: provenance file not written at $PROV. out=$(cat /tmp/t1.out)"; }
[[ -f "$PLIST" ]] || { fail "T1: plist not written at $PLIST. out=$(cat /tmp/t1.out)"; }
if [[ -f "$PROV" && -f "$PLIST" ]]; then
  PROV_CLAUDE=$(python3 -c "import json; print(json.load(open('$PROV'))['claude_bin'])" 2>/dev/null || echo MISSING)
  PLIST_CLAUDE=$(read_plist_key "$PLIST" "EnvironmentVariables.OFLOOP_CLAUDE_BIN" 2>/dev/null || echo MISSING)
  EXPECTED_CLAUDE="$(python3 -c "from pathlib import Path; print(str(Path('$CLAUDE_FAKE').resolve(strict=False)))")"
  [[ "$PROV_CLAUDE" == "$EXPECTED_CLAUDE" ]] \
    && pass "T1: provenance claude_bin = canonical resolved path" \
    || fail "T1: provenance claude_bin=$PROV_CLAUDE != $EXPECTED_CLAUDE"
  [[ "$PLIST_CLAUDE" == "$EXPECTED_CLAUDE" ]] \
    && pass "T1: plist OFLOOP_CLAUDE_BIN = canonical resolved path" \
    || fail "T1: plist OFLOOP_CLAUDE_BIN=$PLIST_CLAUDE != $EXPECTED_CLAUDE"
  [[ "$PROV_CLAUDE" == "$PLIST_CLAUDE" ]] \
    && pass "T1: parity — provenance claude_bin == plist OFLOOP_CLAUDE_BIN" \
    || fail "T1: parity mismatch: $PROV_CLAUDE vs $PLIST_CLAUDE"

  PROV_SERVICE_ENV=$(python3 -c "import json; print(json.load(open('$PROV'))['service_env_file'])" 2>/dev/null || echo MISSING)
  PLIST_SERVICE_ENV=$(read_plist_key "$PLIST" "EnvironmentVariables.OFLOOP_SERVICE_ENV_FILE" 2>/dev/null || echo MISSING)
  [[ "$PROV_SERVICE_ENV" == "$SERVICE_ENV" && "$PLIST_SERVICE_ENV" == "$SERVICE_ENV" ]] \
    && pass "T1: plist/provenance agree on private service-env path" \
    || fail "T1: service-env parity mismatch prov=$PROV_SERVICE_ENV plist=$PLIST_SERVICE_ENV expected=$SERVICE_ENV"
  PLIST_AUTH_READ=$(read_plist_key "$PLIST" "EnvironmentVariables.OFLOOP_ADAPTER_AUTH_READ_PATHS" 2>/dev/null || echo "")
  [[ -z "$PLIST_AUTH_READ" ]] \
    && pass "T1: macOS does not reopen ~/.claude for commissioned worker" \
    || fail "T1: macOS unexpectedly set auth read path=$PLIST_AUTH_READ"
  python3 -B - "$PROV" "$SERVICE_ENV" "$PLIST" "$SANDBOX/xdg1/ownframework-loop" <<'PY'
import pathlib, stat, sys
prov, service_env, plist, state_root = map(pathlib.Path, sys.argv[1:])
assert stat.S_IMODE(state_root.stat().st_mode) == 0o700
for p in (prov, service_env, plist):
    assert stat.S_IMODE(p.stat().st_mode) == 0o600, (p, oct(stat.S_IMODE(p.stat().st_mode)))
PY
fi

# =====================================================================
# T2: supervisor runner prefers OFLOOP_CLAUDE_BIN over PATH "claude"
# =====================================================================
echo ""
echo "=== T2: supervisor prefers OFLOOP_CLAUDE_BIN ==="
PROBE_DIR="$SANDBOX/probe"
mkdir -p "$PROBE_DIR"
# The "real" claude (would be picked up via PATH "claude"):
cat > "$PROBE_DIR/claude" <<'P1'
#!/usr/bin/env bash
echo "PATH_RESOLVED"
exit 0
P1
chmod +x "$PROBE_DIR/claude"
# The env-supplied OFLOOP_CLAUDE_BIN (the one we want the runner to use):
cat > "$PROBE_DIR/supplied-claude" <<'P2'
#!/usr/bin/env bash
echo "ENV_SUPPLIED"
exit 0
P2
chmod +x "$PROBE_DIR/supplied-claude"
# Drive ClaudeCodeRunner.run indirectly via subprocess.Popen mock.
RESULT="$(PYTHONPATH="$LIB" python3 - <<PY
import os, sys
os.environ["OFLOOP_CLAUDE_BIN"] = "$PROBE_DIR/supplied-claude"
os.environ["PATH"] = "$PROBE_DIR:/usr/bin:/bin"
from ownframework_loop import supervisor
captured = {}
class FakePopen:
    def __init__(self, cmd, **kw):
        captured["cmd"] = cmd
        raise SystemExit(0)
supervisor.subprocess.Popen = FakePopen
try:
    wo = {
        "schema": supervisor.SCHEMA,
        "decision": "BUILD",
        "role": "builder",
        "run_id": "run-T2",
        "state": "BUILDING",
        "replayed": False,
        "canonical_repo": "/tmp",
        "worktree": "/tmp",
        "semantic_path": "/tmp/x",
    }
    supervisor.ClaudeCodeRunner().run(wo, timeout_seconds=1)
except SystemExit:
    pass
print(captured.get("cmd", ["NONE"])[0])
PY
)"
[[ "$RESULT" == "$PROBE_DIR/supplied-claude" ]] \
  && pass "T2: ClaudeCodeRunner uses OFLOOP_CLAUDE_BIN, not PATH" \
  || fail "T2: runner resolved to $RESULT, expected $PROBE_DIR/supplied-claude"

# =====================================================================
# T3: non-executable CLAUDE_BIN supplied → install REFUSED
# =====================================================================
echo ""
echo "=== T3: non-executable CLAUDE_BIN refused ==="
NONEXEC="$SANDBOX/nonexec"
mkdir -p "$NONEXEC"
cat > "$NONEXEC/claude" <<'NE'
#!/usr/bin/env bash
exit 0
NE
chmod 644 "$NONEXEC/claude"
OUT=$(CLAUDE_BIN="$NONEXEC/claude" XDG_STATE_HOME="$SANDBOX/xdg3" run_installer 2>&1 || true)
if grep -q "REFUSED.*claude_not_executable" <<<"$OUT"; then
  pass "T3: install refused with claude_not_executable reason"
else
  fail "T3: install did not refuse non-executable CLAUDE_BIN. out=$OUT"
fi

# =====================================================================
# T4: idle-only install (no Claude) supported; OFLOOP_CLAUDE_BIN OMITTED
# =====================================================================
echo ""
echo "=== T4: idle-only install supported, no bogus OFLOOP_CLAUDE_BIN ==="
IDLE_HOME="$SANDBOX/idle/home"
mkdir -p "$IDLE_HOME"
IDLE_XDG="$SANDBOX/xdg4"
mkdir -p "$IDLE_XDG"
# IDLE path: NO claude on PATH, NO CLAUDE_BIN env. The installer
# must detect this and produce an idle-only install without a bogus
# OFLOOP_CLAUDE_BIN. We deliberately exclude the fakebins dir from
# PATH and use a separate dir without a claude symlink so command
# -v claude cannot find the symlinked claude.
IDLE_FAKEBIN_DIR="$SANDBOX/fakebins-idle"
mkdir -p "$IDLE_FAKEBIN_DIR"
ln -sf "$REAL_PY" "$IDLE_FAKEBIN_DIR/python3"
ln -sf "$REAL_OFLOOP" "$IDLE_FAKEBIN_DIR/ofloop"
# Deliberately do NOT create a claude symlink in IDLE_FAKEBIN_DIR.
(cd "$ROOT" && env -i \
  HOME="$IDLE_HOME" \
  PATH="$IDLE_FAKEBIN_DIR:$STUB_BIN_DIR:/usr/bin:/bin" \
  PYTHONPATH="$LIB" \
  PYTHON_BIN="$PYTHON_FAKE" \
  OFLOOP_BIN="$OFLOOP_FAKE" \
  XDG_STATE_HOME="$IDLE_XDG" \
  bash "$INSTALLER" > /tmp/t4.out 2>&1 || true)
IDLE_PROV="$IDLE_XDG/ownframework-loop/runtime-provenance.json"
IDLE_SERVICE_ENV="$IDLE_XDG/ownframework-loop/service-env.json"
IDLE_PLIST="$IDLE_HOME/Library/LaunchAgents/com.ownframework.loop-supervisor.plist"
[[ -f "$IDLE_PROV" ]] || { fail "T4: provenance not written for idle install. out=$(cat /tmp/t4.out)"; }
if [[ -f "$IDLE_PROV" ]]; then
  IDLE_PROV_CLAUDE=$(python3 -c "import json; v=json.load(open('$IDLE_PROV'))['claude_bin']; print('None' if v is None else v)" 2>/dev/null || echo MISSING)
  [[ "$IDLE_PROV_CLAUDE" == "None" ]] \
    && pass "T4: provenance claude_bin = null in idle-only install" \
    || fail "T4: provenance claude_bin=$IDLE_PROV_CLAUDE (expected None)"

  IDLE_PROV_SERVICE_ENV=$(python3 -c "import json; v=json.load(open('$IDLE_PROV'))['service_env_file']; print('None' if v is None else v)" 2>/dev/null || echo MISSING)
  [[ "$IDLE_PROV_SERVICE_ENV" == "None" ]] \
    && pass "T4: idle-only provenance does not commission service-env" \
    || fail "T4: idle-only service_env_file=$IDLE_PROV_SERVICE_ENV"
  [[ -f "$IDLE_SERVICE_ENV" ]] || fail "T4: private empty service-env file missing"
fi
if [[ -f "$IDLE_PLIST" ]]; then
  IDLE_PLIST_CLAUDE=$(read_plist_key "$IDLE_PLIST" "EnvironmentVariables.OFLOOP_CLAUDE_BIN" 2>/dev/null || echo MISSING)
  [[ -z "$IDLE_PLIST_CLAUDE" ]] \
    && pass "T4: plist omits OFLOOP_CLAUDE_BIN in idle-only install" \
    || fail "T4: plist OFLOOP_CLAUDE_BIN=$IDLE_PLIST_CLAUDE (expected empty — env var omitted)"
fi

# =====================================================================
# T5: custom XDG_STATE_HOME → STATE_ROOT, stdout/stderr/provenance agree
# =====================================================================
echo ""
echo "=== T5: custom XDG_STATE_HOME causes all STATE_ROOT paths to agree ==="
reset_shared_commissioning
CLAUDE_BIN="$CLAUDE_FAKE" XDG_STATE_HOME="$SANDBOX/xdg5" run_installer > /tmp/t5.out 2>&1 || true
PROV5="$SANDBOX/xdg5/ownframework-loop/runtime-provenance.json"
PLIST5="$HOME/Library/LaunchAgents/com.ownframework.loop-supervisor.plist"
[[ -f "$PROV5" && -f "$PLIST5" ]] || { fail "T5: artifacts missing. out=$(cat /tmp/t5.out)"; }
if [[ -f "$PROV5" && -f "$PLIST5" ]]; then
  PROV_STATE=$(python3 -c "import json; print(json.load(open('$PROV5'))['state_root'])")
  PROV_STDOUT=$(python3 -c "import json; print(json.load(open('$PROV5'))['stdout_log'])")
  PROV_STDERR=$(python3 -c "import json; print(json.load(open('$PROV5'))['stderr_log'])")
  PLIST_STDOUT=$(read_plist_key "$PLIST5" "StandardOutPath")
  PLIST_STDERR=$(read_plist_key "$PLIST5" "StandardErrorPath")
  PLIST_XDG=$(read_plist_key "$PLIST5" "EnvironmentVariables.XDG_STATE_HOME")
  EXPECTED_STATE="$SANDBOX/xdg5/ownframework-loop"
  [[ "$PROV_STATE" == "$EXPECTED_STATE" ]] \
    && pass "T5: provenance.state_root = $EXPECTED_STATE" \
    || fail "T5: provenance.state_root=$PROV_STATE"
  [[ "$PROV_STDOUT" == "$EXPECTED_STATE/supervisor.stdout.log" ]] \
    && pass "T5: provenance.stdout_log = state_root/supervisor.stdout.log" \
    || fail "T5: provenance.stdout_log=$PROV_STDOUT"
  [[ "$PROV_STDERR" == "$EXPECTED_STATE/supervisor.stderr.log" ]] \
    && pass "T5: provenance.stderr_log = state_root/supervisor.stderr.log" \
    || fail "T5: provenance.stderr_log=$PROV_STDERR"
  [[ "$PLIST_STDOUT" == "$EXPECTED_STATE/supervisor.stdout.log" ]] \
    && pass "T5: plist StandardOutPath = state_root/supervisor.stdout.log" \
    || fail "T5: plist StandardOutPath=$PLIST_STDOUT"
  [[ "$PLIST_STDERR" == "$EXPECTED_STATE/supervisor.stderr.log" ]] \
    && pass "T5: plist StandardErrorPath = state_root/supervisor.stderr.log" \
    || fail "T5: plist StandardErrorPath=$PLIST_STDERR"
  [[ "$PLIST_XDG" == "$SANDBOX/xdg5" ]] \
    && pass "T5: plist persists commissioned XDG_STATE_HOME" \
    || fail "T5: plist XDG_STATE_HOME=$PLIST_XDG"

  XDG_STATE_HOME="$PLIST_XDG" PYTHONPATH="$LIB" python3 -B - "$EXPECTED_STATE" <<'PY'
import pathlib, stat, sys
from ownframework_loop import supervisor, runtime_env
root=pathlib.Path(sys.argv[1]).resolve(strict=False)
assert supervisor.default_db_path().parent.resolve(strict=False) == root
assert supervisor.default_worker_log_dir().parent.resolve(strict=False) == root
assert runtime_env.default_runtime_cache_root().parent.resolve(strict=False) == root
assert stat.S_IMODE(root.stat().st_mode)==0o700
for name in ("supervisor.stdout.log","supervisor.stderr.log","runtime-provenance.json","service-env.json","supervisor.sqlite3","ledger-incarnation.json"):
    p=root/name
    assert stat.S_IMODE(p.stat().st_mode)==0o600, (p, oct(stat.S_IMODE(p.stat().st_mode)))
PY
fi

# =====================================================================
# T6: default state root = $HOME/.local/state/ownframework-loop
# =====================================================================
echo ""
echo "=== T6: default state root is ~/.local/state/ownframework-loop ==="
DEF_HOME="$SANDBOX/default/home"
mkdir -p "$DEF_HOME"
(cd "$ROOT" && env -i \
  HOME="$DEF_HOME" \
  PATH="$PYTHON_FAKE_DIR:$STUB_BIN_DIR:/usr/bin:/bin" \
  PYTHONPATH="$LIB" \
  PYTHON_BIN="$PYTHON_FAKE" \
  OFLOOP_BIN="$OFLOOP_FAKE" \
  CLAUDE_BIN="$CLAUDE_FAKE" \
  bash "$INSTALLER" > /tmp/t6.out 2>&1 || true)
DEF_PROV="$DEF_HOME/.local/state/ownframework-loop/runtime-provenance.json"
[[ -f "$DEF_PROV" ]] || { fail "T6: default provenance not written. out=$(cat /tmp/t6.out)"; }
if [[ -f "$DEF_PROV" ]]; then
  DEF_PROV_STATE=$(python3 -c "import json; print(json.load(open('$DEF_PROV'))['state_root'])" 2>/dev/null || echo MISSING)
  [[ "$DEF_PROV_STATE" == "$DEF_HOME/.local/state/ownframework-loop" ]] \
    && pass "T6: default state root = ~/.local/state/ownframework-loop" \
    || fail "T6: default state root=$DEF_PROV_STATE"
fi

# =====================================================================
# T7: provenance.source_head equals Git HEAD of source checkout
# =====================================================================
echo ""
echo "=== T7: provenance.source_head equals Git HEAD ==="
reset_shared_commissioning
CLAUDE_BIN="$CLAUDE_FAKE" XDG_STATE_HOME="$SANDBOX/xdg7" run_installer > /tmp/t7.out 2>&1 || true
PROV7="$SANDBOX/xdg7/ownframework-loop/runtime-provenance.json"
[[ -f "$PROV7" ]] || { fail "T7: provenance not written. out=$(cat /tmp/t7.out)"; }
if [[ -f "$PROV7" ]]; then
  PROV_HEAD=$(python3 -c "import json; print(json.load(open('$PROV7'))['source_head'])" 2>/dev/null || echo MISSING)
  EXPECTED_HEAD=$(git -C "$ROOT" rev-parse HEAD)
  [[ "$PROV_HEAD" == "$EXPECTED_HEAD" ]] \
    && pass "T7: provenance.source_head = $EXPECTED_HEAD" \
    || fail "T7: provenance.source_head=$PROV_HEAD"
  PROV_VERSION=$(python3 -c "import json; print(json.load(open('$PROV7'))['ofloop_version'])" 2>/dev/null || echo MISSING)
  [[ "$PROV_VERSION" == "$EXPECTED_VERSION" ]] \
    && pass "T7: provenance.ofloop_version = $EXPECTED_VERSION" \
    || fail "T7: provenance.ofloop_version=$PROV_VERSION expected=$EXPECTED_VERSION"
fi

# =====================================================================
# T8: no launchd regression — RunAtLoad / KeepAlive / ProcessType / ThrottleInterval / ProgramArguments
# =====================================================================
echo ""
echo "=== T8: launchd plist regression ==="
reset_shared_commissioning
CLAUDE_BIN="$CLAUDE_FAKE" XDG_STATE_HOME="$SANDBOX/xdg8" run_installer > /tmp/t8.out 2>&1 || true
PLIST8="$HOME/Library/LaunchAgents/com.ownframework.loop-supervisor.plist"
[[ -f "$PLIST8" ]] || { fail "T8: plist not written. out=$(cat /tmp/t8.out)"; }
if [[ -f "$PLIST8" ]]; then
  [[ "$(read_plist_key "$PLIST8" "RunAtLoad")" == "True" ]] \
    && pass "T8: RunAtLoad = True" \
    || fail "T8: RunAtLoad missing"
  [[ "$(read_plist_key "$PLIST8" "KeepAlive")" == "True" ]] \
    && pass "T8: KeepAlive = True" \
    || fail "T8: KeepAlive missing"
  [[ "$(read_plist_key "$PLIST8" "ProcessType")" == "Background" ]] \
    && pass "T8: ProcessType = Background" \
    || fail "T8: ProcessType = $(read_plist_key "$PLIST8" "ProcessType")"
  [[ "$(read_plist_key "$PLIST8" "ThrottleInterval")" == "5" ]] \
    && pass "T8: ThrottleInterval = 5" \
    || fail "T8: ThrottleInterval missing"
  EXPECTED_OFLOOP="$(python3 -c "from pathlib import Path; print(str(Path('$OFLOOP_FAKE').resolve(strict=False)))")"
  EXPECTED_PY="$(python3 -c "from pathlib import Path; print(str(Path('$PYTHON_FAKE').resolve(strict=False)))")"
  EXPECTED_HELPER="$(python3 -c "from pathlib import Path; print(str(Path('$ROOT/scripts/launch-commissioned-supervisor.py').resolve(strict=False)))")"
  EXPECTED_PROBE="$(python3 -c "from pathlib import Path; print(str(Path('$ROOT/scripts/probe-supervisor-runtime-dependencies.py').resolve(strict=False)))")"
  EXPECTED_DB="$SANDBOX/xdg8/ownframework-loop/supervisor.sqlite3"
  EXPECTED_MARKER="$SANDBOX/xdg8/ownframework-loop/ledger-incarnation.json"
  PROG=$(read_plist_key "$PLIST8" "ProgramArguments")
  EXPECTED_PROG="['$EXPECTED_PY', '-B', '$EXPECTED_HELPER', '--db', '$EXPECTED_DB', '--ledger-marker', '$EXPECTED_MARKER', '--probe', '$EXPECTED_PROBE', '--ofloop', '$EXPECTED_OFLOOP']"
  [[ "$PROG" == "$EXPECTED_PROG" ]] \
    && pass "T8: ProgramArguments execute through exact commissioned Python + ledger guard" \
    || fail "T8: ProgramArguments=$PROG expected=$EXPECTED_PROG"
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$PLIST8" >/dev/null \
      && pass "T8: emitted plist passes plutil validation" \
      || fail "T8: emitted plist failed plutil validation"
  fi
fi

# =====================================================================
# T9: optional real launchctl smoke on actual Darwin user domain
# =====================================================================
echo ""
echo "=== T9: real launchctl disposable service-manager smoke ==="
REAL_LAUNCHCTL="$(command -v launchctl || true)"
if [[ -n "$REAL_LAUNCHCTL" ]]; then
  SMOKE_LABEL="com.ownframework.loop-ci-smoke.$$"
  SMOKE_PLIST="$SANDBOX/$SMOKE_LABEL.plist"
  python3 -B - "$SMOKE_PLIST" "$SMOKE_LABEL" <<'PY'
import plistlib,sys
with open(sys.argv[1],"wb") as f:
    plistlib.dump({
        "Label":sys.argv[2],
        "ProgramArguments":["/bin/sleep","30"],
        "RunAtLoad":True,
    },f)
PY
  plutil -lint "$SMOKE_PLIST" >/dev/null \
    || fail "T9: generated disposable smoke plist failed plutil"
  if "$REAL_LAUNCHCTL" bootstrap "gui/$UID" "$SMOKE_PLIST" >/dev/null 2>&1; then
    if "$REAL_LAUNCHCTL" print "gui/$UID/$SMOKE_LABEL" >/dev/null 2>&1; then
      pass "T9: real launchctl bootstrap/print succeeded"
    else
      fail "T9: real launchctl bootstrap succeeded but service was not observable"
    fi
    "$REAL_LAUNCHCTL" bootout "gui/$UID/$SMOKE_LABEL" >/dev/null 2>&1 \
      && pass "T9: real launchctl bootout succeeded" \
      || fail "T9: real launchctl bootout failed"
  else
    echo "  SKIP: real launchctl bootstrap unavailable in hosted/user domain"
  fi
else
  echo "  SKIP: launchctl unavailable"
fi

echo ""
if [[ $FAIL -eq 0 ]]; then
  echo "MAC_RUNTIME_PROVENANCE=PASS"
  exit 0
else
  echo "MAC_RUNTIME_PROVENANCE=FAIL count=$FAIL"
  exit 1
fi
