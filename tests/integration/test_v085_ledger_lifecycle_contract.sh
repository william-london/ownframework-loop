#!/usr/bin/env bash
# v0.8.5 platform-lifecycle repair: ledger truth + destructive uninstall safety.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$ROOT_DIR/lib"
PROBE="$ROOT_DIR/scripts/probe-supervisor-runtime-dependencies.py"
TMP="$(mktemp -d -t ofloop-v085-ledger-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

fail(){ echo "FAIL: $*" >&2; exit 1; }
expect_probe(){
  local db="$1" incoming="$2" expected_rc="$3" reason="$4"; shift 4
  set +e
  local out
  out="$(PYTHONDONTWRITEBYTECODE=1 python3 -B "$PROBE" "$db" "$incoming" "$@" 2>&1)"
  local rc=$?
  set -e
  [[ "$rc" -eq "$expected_rc" ]] || fail "probe rc=$rc expected=$expected_rc db=$db out=$out"
  grep -F "$reason" <<<"$out" >/dev/null || fail "probe missing reason=$reason out=$out"
}

make_canonical(){
  PYTHONPATH="$LIB" python3 -B - "$1" "${2:-}" <<'PY'
import sys,time
from pathlib import Path
from ownframework_loop import supervisor
db=Path(sys.argv[1]); status=sys.argv[2]
with supervisor._connect(db) as c:
    if status:
        c.execute(
            "INSERT INTO jobs(repo,run_id,status,created_at,updated_at,runtime_generation) VALUES(?,?,?,?,?,?)",
            (str(db.parent/"repo"), "run-"+status.lower(), status, time.time(), time.time(), "ofloop-old@git-deadbeef"),
        )
        c.commit()
PY
}

# Canonical empty is provably empty; missing/corrupt/unrecognized is never safe.
EMPTY="$TMP/empty.sqlite3"; make_canonical "$EMPTY"
expect_probe "$EMPTY" "ofloop-new@git-cafe" 0 "reason=safe"
expect_probe "$EMPTY" "uninstall" 0 "reason=safe" --allow-generation-migration

MISSING="$TMP/missing.sqlite3"
expect_probe "$MISSING" "uninstall" 12 "reason=ledger_missing" --allow-generation-migration

ZERO="$TMP/zero.sqlite3"; : > "$ZERO"
expect_probe "$ZERO" "uninstall" 12 "reason=ledger_schema_unrecognized" --allow-generation-migration

BYTES="$TMP/bytes.sqlite3"; printf 'not-sqlite\n' > "$BYTES"
expect_probe "$BYTES" "uninstall" 12 "reason=ledger_unreadable" --allow-generation-migration

NOJOBS="$TMP/nojobs.sqlite3"
python3 -B - "$NOJOBS" <<'PY'
import sqlite3,sys
c=sqlite3.connect(sys.argv[1]); c.execute("CREATE TABLE other(x TEXT)"); c.commit(); c.close()
PY
expect_probe "$NOJOBS" "uninstall" 12 "reason=ledger_schema_unrecognized" --allow-generation-migration

PARTIAL="$TMP/partial.sqlite3"
python3 -B - "$PARTIAL" <<'PY'
import sqlite3,sys
c=sqlite3.connect(sys.argv[1]); c.execute("CREATE TABLE jobs(status TEXT)"); c.commit(); c.close()
PY
expect_probe "$PARTIAL" "uninstall" 12 "jobs_columns_missing:run_id" --allow-generation-migration

UNKNOWN="$TMP/unknown.sqlite3"
python3 -B - "$UNKNOWN" <<'PY'
import sqlite3,sys
c=sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE jobs(run_id TEXT,status TEXT,runtime_generation TEXT,worker_pid INTEGER)")
c.execute("INSERT INTO jobs VALUES('run-x','MYSTERY','gen',NULL)")
c.commit(); c.close()
PY
expect_probe "$UNKNOWN" "uninstall" 12 "unknown_job_status:MYSTERY" --allow-generation-migration

for status in DONE RETIRED; do
  db="$TMP/$status.sqlite3"; make_canonical "$db" "$status"
  expect_probe "$db" "ofloop-new@git-cafe" 0 "reason=safe"
  expect_probe "$db" "uninstall" 0 "reason=safe" --allow-generation-migration
done

for status in QUEUED BACKOFF QUARANTINED; do
  db="$TMP/$status.sqlite3"; make_canonical "$db" "$status"
  expect_probe "$db" "ofloop-new@git-cafe" 13 "reason=runtime_generation_dependency"
  expect_probe "$db" "uninstall" 13 "reason=unfinished_runtime_dependency" --allow-generation-migration
done
RUNNING="$TMP/RUNNING.sqlite3"; make_canonical "$RUNNING" RUNNING
expect_probe "$RUNNING" "ofloop-new@git-cafe" 11 "reason=active_semantic_work"
expect_probe "$RUNNING" "uninstall" 11 "reason=active_semantic_work" --allow-generation-migration

# DB-only unfinished work remains dependency evidence even if manager artifacts
# have disappeared.
export HOME="$TMP/core-home"
export XDG_DATA_HOME="$TMP/core-data"
export XDG_STATE_HOME="$TMP/core-state"
export XDG_CONFIG_HOME="$TMP/core-config"
export OFLOOP_BIN_DIR="$TMP/core-bin"
mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CONFIG_HOME" "$OFLOOP_BIN_DIR"
bash "$ROOT_DIR/install.sh" > "$TMP/core-install.out"
CORE_ROOT="$(sed -n 's/^CORE_ROOT=//p' "$TMP/core-install.out" | tail -n1)"
GEN="$(sed -n 's/^RUNTIME_GENERATION=//p' "$TMP/core-install.out" | tail -n1)"
DB="$XDG_STATE_HOME/ownframework-loop/supervisor.sqlite3"
PYTHONPATH="$CORE_ROOT/lib" python3 -B - "$DB" "$GEN" <<'PY'
import sys,time
from pathlib import Path
from ownframework_loop import supervisor
db=Path(sys.argv[1]); gen=sys.argv[2]
with supervisor._connect(db) as c:
    c.execute(
        "INSERT INTO jobs(repo,run_id,status,created_at,updated_at,runtime_generation) VALUES(?,?,?,?,?,?)",
        (str(db.parent/"repo"),"run-db-only","QUEUED",time.time(),time.time(),gen),
    )
    c.commit()
PY
set +e
OUT="$(bash "$ROOT_DIR/uninstall.sh" 2>&1)"
RC=$?
set -e
[[ "$RC" -eq 13 ]] || fail "DB-only unfinished core uninstall rc=$RC out=$OUT"
grep -F 'unfinished_runtime_dependency' <<<"$OUT" >/dev/null || fail "DB-only dependency reason missing: $OUT"
test -d "$CORE_ROOT" || fail "core removed despite DB-only unfinished work"
test -L "$OFLOOP_BIN_DIR/ofloop" || fail "launcher removed despite DB-only unfinished work"
python3 -B - "$DB" <<'PY'
import sqlite3,sys
c=sqlite3.connect(sys.argv[1]); c.execute("UPDATE jobs SET status='DONE'"); c.commit(); c.close()
PY
ABSENT_MANAGER="$TMP/terminal-absent-manager"; mkdir -p "$ABSENT_MANAGER"
if [[ "$(uname -s)" == "Darwin" ]]; then
  cat > "$ABSENT_MANAGER/launchctl" <<'SH'
#!/bin/sh
if [ "${1:-}" = print ]; then
  case "${2:-}" in
    gui/*/com.ownframework.loop-supervisor) exit 1 ;;
    gui/*) exit 0 ;;
  esac
fi
exit 0
SH
  chmod +x "$ABSENT_MANAGER/launchctl"
  PATH="$ABSENT_MANAGER:$PATH" bash "$ROOT_DIR/uninstall.sh" >/dev/null
else
  cat > "$ABSENT_MANAGER/systemctl" <<'SH'
#!/bin/sh
case " $* " in
  *" is-active "*) exit 4 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$ABSENT_MANAGER/systemctl"
  SYSTEMCTL_BIN="$ABSENT_MANAGER/systemctl" bash "$ROOT_DIR/uninstall.sh" >/dev/null
fi
test ! -e "$CORE_ROOT" || fail "terminal-only DB did not permit core uninstall"

# macOS manager hard failure must retain service artifacts; already-absent is
# idempotent and succeeds.  Fake uname makes this deterministic on Linux CI too.
MHOME="$TMP/mac-home"; MXDG="$TMP/mac-state"; MFAKE="$TMP/mac-fake"
mkdir -p "$MHOME/Library/LaunchAgents" "$MXDG/ownframework-loop" "$MFAKE"
MPLIST="$MHOME/Library/LaunchAgents/com.ownframework.loop-supervisor.plist"
MPROV="$MXDG/ownframework-loop/runtime-provenance.json"
printf 'plist\n' > "$MPLIST"; printf '{}\n' > "$MPROV"
make_canonical "$MXDG/ownframework-loop/supervisor.sqlite3"
cat > "$MFAKE/uname" <<'SH'
#!/bin/sh
echo Darwin
SH
cat > "$MFAKE/launchctl" <<'SH'
#!/bin/sh
if [ "${1:-}" = print ]; then echo "manager transport failed" >&2; exit 5; fi
exit 5
SH
chmod +x "$MFAKE/"*
set +e
OUT="$(HOME="$MHOME" XDG_STATE_HOME="$MXDG" PATH="$MFAKE:$PATH" bash "$ROOT_DIR/scripts/supervisor/uninstall-macos.sh" 2>&1)"
RC=$?
set -e
[[ "$RC" -eq 14 ]] || fail "mac manager failure rc=$RC out=$OUT"
test -f "$MPLIST" && test -f "$MPROV" || fail "mac artifacts removed on manager failure"
cat > "$MFAKE/launchctl" <<'SH'
#!/bin/sh
if [ "${1:-}" = print ]; then
  case "${2:-}" in
    gui/*/com.ownframework.loop-supervisor) echo "Could not find service" >&2; exit 1 ;;
    gui/*) exit 0 ;;
  esac
fi
exit 0
SH
chmod +x "$MFAKE/launchctl"
HOME="$MHOME" XDG_STATE_HOME="$MXDG" PATH="$MFAKE:$PATH" bash "$ROOT_DIR/scripts/supervisor/uninstall-macos.sh" >/dev/null
test ! -e "$MPLIST" && test ! -e "$MPROV" || fail "mac already-absent uninstall did not converge"

# Linux: unknown manager state refuses; known inactive unit can be removed.
LHOME="$TMP/linux-home"; LXDG="$TMP/linux-state"; LCFG="$TMP/linux-config"; LFAKE="$TMP/linux-fake"
mkdir -p "$LHOME" "$LXDG/ownframework-loop" "$LCFG/systemd/user" "$LFAKE"
LUNIT="$LCFG/systemd/user/ownframework-loop-supervisor.service"
LPROV="$LXDG/ownframework-loop/runtime-provenance.json"
printf '[Service]\nExecStart=/bin/true\n' > "$LUNIT"; printf '{}\n' > "$LPROV"
make_canonical "$LXDG/ownframework-loop/supervisor.sqlite3"
cat > "$LFAKE/uname" <<'SH'
#!/bin/sh
echo Linux
SH
cat > "$LFAKE/systemctl" <<'SH'
#!/bin/sh
case " $* " in
  *" is-active "*) exit 1 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$LFAKE/"*
set +e
OUT="$(HOME="$LHOME" XDG_STATE_HOME="$LXDG" XDG_CONFIG_HOME="$LCFG" PATH="$LFAKE:$PATH" SYSTEMCTL_BIN="$LFAKE/systemctl" bash "$ROOT_DIR/scripts/supervisor/uninstall-linux.sh" 2>&1)"
RC=$?
set -e
[[ "$RC" -eq 14 ]] || fail "linux manager unknown rc=$RC out=$OUT"
test -f "$LUNIT" && test -f "$LPROV" || fail "linux artifacts removed on manager failure"
cat > "$LFAKE/systemctl" <<'SH'
#!/bin/sh
case " $* " in
  *" is-active "*) exit 3 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$LFAKE/systemctl"
HOME="$LHOME" XDG_STATE_HOME="$LXDG" XDG_CONFIG_HOME="$LCFG" PATH="$LFAKE:$PATH" SYSTEMCTL_BIN="$LFAKE/systemctl" bash "$ROOT_DIR/scripts/supervisor/uninstall-linux.sh" >/dev/null
test ! -e "$LUNIT" && test ! -e "$LPROV" || fail "linux inactive uninstall did not converge"

echo "V085_LEDGER_LIFECYCLE_CONTRACT=PASS"
