#!/usr/bin/env bash
# v0.8.5 platform-lifecycle repair: commissioned Python, rollback, crash recovery.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d -t ofloop-v085-platform-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP
fail(){ echo "FAIL: $*" >&2; exit 1; }

# C-01: the commissioned launcher must end as the exact interpreter even when a
# different python3 is first on PATH.
A="$(python3 -B - <<'PY'
import sys
from pathlib import Path
print(Path(sys.executable).resolve(strict=False))
PY
)"
GUARD_DB="$TMP/guard.sqlite3"
PYTHONPATH="$ROOT_DIR/lib" "$A" -B - "$GUARD_DB" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import supervisor
with supervisor._connect(Path(sys.argv[1])):
    pass
PY
GUARD_MARKER="$TMP/ledger-incarnation.json"
printf '{"schema":"ownframework-loop-ledger-incarnation/v1"}\n' > "$GUARD_MARKER"
chmod 0600 "$GUARD_MARKER"
DUMMY="$TMP/dummy-ofloop.py"
cat > "$DUMMY" <<'PY'
import sys
assert sys.argv[1:] == ["supervisor", "serve"], sys.argv
print(sys.executable)
PY
BADBIN="$TMP/badbin"; mkdir -p "$BADBIN"
cat > "$BADBIN/python3" <<'SH'
#!/bin/sh
echo BAD_PYTHON_USED
exit 91
SH
chmod +x "$BADBIN/python3"
OUT="$(PATH="$BADBIN:$PATH" "$A" -B "$ROOT_DIR/scripts/launch-commissioned-supervisor.py" \
  --db "$GUARD_DB" --ledger-marker "$GUARD_MARKER" \
  --probe "$ROOT_DIR/scripts/probe-supervisor-runtime-dependencies.py" --ofloop "$DUMMY")"
[[ "$OUT" == "$A" ]] || fail "commissioned launcher used wrong Python: $OUT expected=$A"

# Create source-tree release copies with distinct semantic versions for an A->B
# cross-version rollback.  No .git means install.sh consumes exactly these bytes.
A_SRC="$TMP/source-a"; B_SRC="$TMP/source-b"
python3 -B - "$ROOT_DIR" "$A_SRC" "$B_SRC" <<'PY'
import re,shutil,sys
from pathlib import Path
root,a,b=map(Path,sys.argv[1:])
ignore=shutil.ignore_patterns(".git","__pycache__",".ownframework-loop","logs","*.pyc")
shutil.copytree(root,a,ignore=ignore)
shutil.copytree(root,b,ignore=ignore)
for path,ver in ((a,"9.8.1"),(b,"9.8.2")):
    init=path/"lib"/"ownframework_loop"/"__init__.py"
    text=init.read_text(encoding="utf-8")
    text=re.sub(r'__version__\s*=\s*["\'][^"\']+["\']', f'__version__ = "{ver}"', text, count=1)
    init.write_text(text,encoding="utf-8")
PY

RB_HOME="$TMP/rb-home"; RB_DATA="$TMP/rb-data"; RB_STATE="$TMP/rb-state"; RB_CFG="$TMP/rb-config"; RB_BIN="$TMP/rb-bin"; RB_FAKE="$TMP/rb-fake"
mkdir -p "$RB_HOME" "$RB_DATA" "$RB_STATE" "$RB_CFG" "$RB_BIN" "$RB_FAKE"
export HOME="$RB_HOME" OFLOOP_DATA_HOME="$RB_DATA" XDG_STATE_HOME="$RB_STATE" XDG_CONFIG_HOME="$RB_CFG" OFLOOP_BIN_DIR="$RB_BIN"
A_OUT="$(bash "$A_SRC/install.sh")"
A_ROOT="$(sed -n 's/^CORE_ROOT=//p' <<<"$A_OUT" | tail -n1)"
test -x "$A_ROOT/bin/ofloop" || fail "version A did not install"
STATE_ROOT="$RB_STATE/ownframework-loop"; mkdir -p "$STATE_ROOT"
PYTHONPATH="$A_ROOT/lib" python3 -B - "$STATE_ROOT/supervisor.sqlite3" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import supervisor
with supervisor._connect(Path(sys.argv[1])):
    pass
PY

if [[ "$(uname -s)" == "Darwin" ]]; then
  mkdir -p "$RB_HOME/Library/LaunchAgents"
  printf 'old-plist\n' > "$RB_HOME/Library/LaunchAgents/com.ownframework.loop-supervisor.plist"
  printf '{"old":true}\n' > "$STATE_ROOT/runtime-provenance.json"
  COUNT="$TMP/rb-launchctl-count"
  cat > "$RB_FAKE/launchctl" <<'SH'
#!/bin/bash
case "${1:-}" in
  print) echo "Could not find service" >&2; exit 1 ;;
  bootout|enable) exit 0 ;;
  bootstrap)
    n=0; [[ -f "$COUNT" ]] && n="$(cat "$COUNT")"
    n=$((n+1)); printf '%s\n' "$n" > "$COUNT"
    [[ "$n" -eq 1 ]] && exit 44
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$RB_FAKE/launchctl"
  export COUNT
  set +e
  B_OUT="$(PATH="$RB_FAKE:$PATH" PYTHON_BIN="$A" bash "$B_SRC/install.sh" 2>&1)"
  B_RC=$?
  set -e
else
  UNIT_DIR="$TMP/rb-systemd"; mkdir -p "$UNIT_DIR"
  printf '[Service]\nExecStart=/bin/true\n' > "$UNIT_DIR/ownframework-loop-supervisor.service"
  printf '{"old":true}\n' > "$STATE_ROOT/runtime-provenance.json"
  COUNT="$TMP/rb-systemctl-count"
  cat > "$RB_FAKE/systemctl" <<'SH'
#!/bin/bash
echo "$*" >> "$CALLS"
case " $* " in
  *" is-active "*) exit 3 ;;
  *" enable --now "*)
    n=0; [[ -f "$COUNT" ]] && n="$(cat "$COUNT")"
    n=$((n+1)); printf '%s\n' "$n" > "$COUNT"
    [[ "$n" -eq 1 ]] && exit 44
    exit 0
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$RB_FAKE/systemctl"
  CALLS="$TMP/rb-systemctl-calls"; export COUNT CALLS
  set +e
  B_OUT="$(OFLOOP_SYSTEMD_USER_DIR="$UNIT_DIR" SYSTEMCTL_BIN="$RB_FAKE/systemctl" PYTHON_BIN="$A" bash "$B_SRC/install.sh" 2>&1)"
  B_RC=$?
  set -e
fi
[[ "$B_RC" -eq 5 ]] || fail "forced B refresh did not fail at core rollback boundary rc=$B_RC out=$B_OUT"
grep -F 'rollback=core_runtime_and_launcher_restored' <<<"$B_OUT" >/dev/null || fail "core rollback marker missing: $B_OUT"
RESOLVED="$(python3 -B - "$RB_BIN/ofloop" <<'PY'
import sys
from pathlib import Path
print(Path(sys.argv[1]).resolve(strict=False))
PY
)"
EXPECTED_A="$(python3 -B - "$A_ROOT/bin/ofloop" <<'PY'
import sys
from pathlib import Path
print(Path(sys.argv[1]).resolve(strict=False))
PY
)"
[[ "$RESOLVED" == "$EXPECTED_A" ]] || fail "public launcher not restored to A: $RESOLVED != $EXPECTED_A"
test -x "$A_ROOT/bin/ofloop" || fail "A runtime lost during failed B upgrade"
test ! -e "$RB_DATA/9.8.2" || fail "failed B runtime still present"
test -L "$RB_BIN/ofloop" || fail "public launcher is not a symlink after rollback"

# C-06 + first initialization: commission a fresh current core, then synthesize
# each durable half-publication state exactly as a killed installer can leave it.
TX_HOME="$TMP/tx-home"; TX_DATA="$TMP/tx-data"; TX_STATE="$TMP/tx-state"; TX_CFG="$TMP/tx-config"; TX_BIN="$TMP/tx-bin"; TX_FAKE="$TMP/tx-fake"
mkdir -p "$TX_HOME" "$TX_DATA" "$TX_STATE" "$TX_CFG" "$TX_BIN" "$TX_FAKE"
export HOME="$TX_HOME" OFLOOP_DATA_HOME="$TX_DATA" XDG_STATE_HOME="$TX_STATE" XDG_CONFIG_HOME="$TX_CFG" OFLOOP_BIN_DIR="$TX_BIN"
CORE_OUT="$(bash "$ROOT_DIR/install.sh")"
CORE_ROOT="$(sed -n 's/^CORE_ROOT=//p' <<<"$CORE_OUT" | tail -n1)"
TX_ROOT="$TX_STATE/ownframework-loop"
if [[ "$(uname -s)" == "Darwin" ]]; then
  cat > "$TX_FAKE/launchctl" <<'SH'
#!/bin/sh
if [ "${1:-}" = print ]; then
  case "${2:-}" in
    gui/*/com.ownframework.loop-supervisor) exit 1 ;;
    gui/*) exit 0 ;;
  esac
fi
exit 0
SH
  chmod +x "$TX_FAKE/launchctl"
  PATH_TX="$TX_BIN:$TX_FAKE:/usr/local/bin:/usr/bin:/bin"
  HOME="$TX_HOME" XDG_STATE_HOME="$TX_STATE" PATH="$PATH_TX" PYTHON_BIN="$A" OFLOOP_BIN="$CORE_ROOT/bin/ofloop" bash "$CORE_ROOT/install-supervisor.sh" > "$TMP/tx-first.out"
  test -f "$TX_ROOT/supervisor.sqlite3" && test -f "$TX_ROOT/ledger-incarnation.json" || fail "first mac commissioning did not initialize canonical ledger"
  ART1="$TX_HOME/Library/LaunchAgents/com.ownframework.loop-supervisor.plist"
  ART2="$TX_ROOT/runtime-provenance.json"; ART3="$TX_ROOT/service-env.json"
  TXN="$TX_ROOT/.supervisor-install-transaction"
  for stage in 1 2 3; do
    rm -rf "$TXN"; mkdir -p "$TXN"; chmod 0700 "$TXN"
    cp "$ART1" "$TXN/old.plist"; touch "$TXN/had-plist"
    cp "$ART2" "$TXN/old.provenance.json"; touch "$TXN/had-provenance"
    cp "$ART3" "$TXN/old.service-env.json"; touch "$TXN/had-service-env"
    chmod 0600 "$TXN"/*
    printf 'BROKEN-PLIST\n' > "$ART1"
    [[ "$stage" -ge 2 ]] && printf 'BROKEN-PROV\n' > "$ART2"
    [[ "$stage" -ge 3 ]] && printf 'BROKEN-ENV\n' > "$ART3"
    OUT="$(HOME="$TX_HOME" XDG_STATE_HOME="$TX_STATE" PATH="$PATH_TX" PYTHON_BIN="$A" OFLOOP_BIN="$CORE_ROOT/bin/ofloop" bash "$CORE_ROOT/install-supervisor.sh")"
    grep -F 'SUPERVISOR_INSTALL_RECOVERY=recovered_incomplete_transaction' <<<"$OUT" >/dev/null || fail "mac crash stage $stage not recovered"
    test ! -e "$TXN" || fail "mac transaction marker survived successful recovery stage $stage"
    python3 -B - "$ART1" "$ART2" "$ART3" <<'PY'
import json,plistlib,sys
with open(sys.argv[1],"rb") as f: plistlib.load(f)
json.load(open(sys.argv[2],encoding="utf-8"))
json.load(open(sys.argv[3],encoding="utf-8"))
PY
  done
else
  cat > "$TX_FAKE/systemctl" <<'SH'
#!/bin/sh
case " $* " in
  *" is-active "*) exit 3 ;;
  *) exit 0 ;;
esac
SH
  cat > "$TX_FAKE/loginctl" <<'SH'
#!/bin/sh
echo yes
SH
  chmod +x "$TX_FAKE/"*
  UNIT_DIR="$TMP/tx-systemd"; mkdir -p "$UNIT_DIR"
  PATH_TX="$TX_BIN:$TX_FAKE:/usr/local/bin:/usr/bin:/bin"
  HOME="$TX_HOME" XDG_STATE_HOME="$TX_STATE" XDG_CONFIG_HOME="$TX_CFG" PATH="$PATH_TX" PYTHON_BIN="$A" OFLOOP_BIN="$CORE_ROOT/bin/ofloop" SYSTEMCTL_BIN="$TX_FAKE/systemctl" OFLOOP_SYSTEMD_USER_DIR="$UNIT_DIR" bash "$CORE_ROOT/install-supervisor.sh" > "$TMP/tx-first.out"
  test -f "$TX_ROOT/supervisor.sqlite3" && test -f "$TX_ROOT/ledger-incarnation.json" || fail "first Linux commissioning did not initialize canonical ledger"
  ART1="$UNIT_DIR/ownframework-loop-supervisor.service"
  ART2="$TX_ROOT/runtime-provenance.json"; ART3="$TX_ROOT/service-env.json"
  TXN="$TX_ROOT/.supervisor-install-transaction"
  for stage in 1 2 3; do
    rm -rf "$TXN"; mkdir -p "$TXN"; chmod 0700 "$TXN"
    cp "$ART1" "$TXN/old.unit"; touch "$TXN/had-unit"
    cp "$ART2" "$TXN/old.provenance.json"; touch "$TXN/had-provenance"
    cp "$ART3" "$TXN/old.service-env.json"; touch "$TXN/had-service-env"
    chmod 0600 "$TXN"/*
    printf 'BROKEN-UNIT\n' > "$ART1"
    [[ "$stage" -ge 2 ]] && printf 'BROKEN-PROV\n' > "$ART2"
    [[ "$stage" -ge 3 ]] && printf 'BROKEN-ENV\n' > "$ART3"
    OUT="$(HOME="$TX_HOME" XDG_STATE_HOME="$TX_STATE" XDG_CONFIG_HOME="$TX_CFG" PATH="$PATH_TX" PYTHON_BIN="$A" OFLOOP_BIN="$CORE_ROOT/bin/ofloop" SYSTEMCTL_BIN="$TX_FAKE/systemctl" OFLOOP_SYSTEMD_USER_DIR="$UNIT_DIR" bash "$CORE_ROOT/install-supervisor.sh")"
    grep -F 'SUPERVISOR_INSTALL_RECOVERY=recovered_incomplete_transaction' <<<"$OUT" >/dev/null || fail "linux crash stage $stage not recovered"
    test ! -e "$TXN" || fail "linux transaction marker survived successful recovery stage $stage"
    grep -F '[Service]' "$ART1" >/dev/null || fail "linux unit not regenerated after recovery stage $stage"
    python3 -B - "$ART2" "$ART3" <<'PY'
import json,sys
json.load(open(sys.argv[1],encoding="utf-8"))
json.load(open(sys.argv[2],encoding="utf-8"))
PY
  done
fi

# Exercise the actual installer publication fault hooks, not only synthesized
# damaged tuples. Each abrupt exit must preserve the transaction and the next
# normal invocation must recover without an unsafe migration override.
if [[ "$(uname -s)" == "Darwin" ]]; then
  ABORT_STAGES=(plist service-env provenance)
  for stage in "${ABORT_STAGES[@]}"; do
    set +e
    HOME="$TX_HOME" XDG_STATE_HOME="$TX_STATE" PATH="$PATH_TX"       PYTHON_BIN="$A" OFLOOP_BIN="$CORE_ROOT/bin/ofloop"       OFLOOP_TEST_ABORT_AFTER_PUBLICATION="$stage"       bash "$CORE_ROOT/install-supervisor.sh" >"$TMP/abort-$stage.out" 2>&1
    ABORT_RC=$?
    set -e
    [[ "$ABORT_RC" -eq 97 ]] || fail "mac publication abort stage=$stage rc=$ABORT_RC out=$(cat "$TMP/abort-$stage.out")"
    test -d "$TXN" || fail "mac publication abort stage=$stage lost transaction recovery state"
    OUT="$(HOME="$TX_HOME" XDG_STATE_HOME="$TX_STATE" PATH="$PATH_TX"       PYTHON_BIN="$A" OFLOOP_BIN="$CORE_ROOT/bin/ofloop"       bash "$CORE_ROOT/install-supervisor.sh")"
    grep -F 'SUPERVISOR_INSTALL_RECOVERY=recovered_incomplete_transaction' <<<"$OUT" >/dev/null       || fail "mac publication abort stage=$stage did not recover"
    test ! -e "$TXN" || fail "mac publication abort stage=$stage left pending transaction after recovery"
  done
else
  ABORT_STAGES=(unit provenance service-env)
  for stage in "${ABORT_STAGES[@]}"; do
    set +e
    HOME="$TX_HOME" XDG_STATE_HOME="$TX_STATE" XDG_CONFIG_HOME="$TX_CFG" PATH="$PATH_TX"       PYTHON_BIN="$A" OFLOOP_BIN="$CORE_ROOT/bin/ofloop"       SYSTEMCTL_BIN="$TX_FAKE/systemctl" OFLOOP_SYSTEMD_USER_DIR="$UNIT_DIR"       OFLOOP_TEST_ABORT_AFTER_PUBLICATION="$stage"       bash "$CORE_ROOT/install-supervisor.sh" >"$TMP/abort-$stage.out" 2>&1
    ABORT_RC=$?
    set -e
    [[ "$ABORT_RC" -eq 97 ]] || fail "linux publication abort stage=$stage rc=$ABORT_RC out=$(cat "$TMP/abort-$stage.out")"
    test -d "$TXN" || fail "linux publication abort stage=$stage lost transaction recovery state"
    OUT="$(HOME="$TX_HOME" XDG_STATE_HOME="$TX_STATE" XDG_CONFIG_HOME="$TX_CFG" PATH="$PATH_TX"       PYTHON_BIN="$A" OFLOOP_BIN="$CORE_ROOT/bin/ofloop"       SYSTEMCTL_BIN="$TX_FAKE/systemctl" OFLOOP_SYSTEMD_USER_DIR="$UNIT_DIR"       bash "$CORE_ROOT/install-supervisor.sh")"
    grep -F 'SUPERVISOR_INSTALL_RECOVERY=recovered_incomplete_transaction' <<<"$OUT" >/dev/null       || fail "linux publication abort stage=$stage did not recover"
    test ! -e "$TXN" || fail "linux publication abort stage=$stage left pending transaction after recovery"
  done
fi

echo "V085_PLATFORM_COMMISSIONING_REPAIR=PASS"
