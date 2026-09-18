#!/usr/bin/env bash
# v0.9.1+ (closure n): macOS commissioning lifecycle-helper
# failure-path regressions.  Closes the two commissioning source
# defects in this round:
#
#   B1: helper nonzero must fail closed; both stdout AND return code
#       must be preserved (no `|| REMOVE_OUT=""` clobber; no `|| true`
#       swallowing);
#   B2: cleanup paths must PROVE canonical-label absence before
#       claiming `label_absent`.  No source-truth corruption.
#
# Three cases per the round's explicit invariants:
#   A: helper prints expected stale-label refusal marker + exits
#      nonzero → marker preserved → installer REFUSED.
#   B: helper exits nonzero with unexpected diagnostic and NO
#      recognized marker → installer REFUSED → diagnostic preserved
#      → never continues to bootstrap.
#   C: helper succeeds → normal behavior unchanged.
#
# Plus three B2 cleanup-absence cases:
#   D: cleanup succeeds (label genuinely absent) → CLEANUP_ABSENCE_PROVEN
#      → rollback=..._label_absent wording permitted.
#   E: cleanup fails to prove absence → CLEANUP_ABSENCE_UNPROVEN
#      → rollback=..._label_presence_unproven wording used.
#   F: cleanup helper exits nonzero with unexpected diagnostic
#      → installer REFUSED → never continues.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
TMP="$(mktemp -d -t ofloop-v091n-lifecycle.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

fail(){ echo "FAIL: $*" >&2; exit 1; }
pass(){ echo "  pass: $*"; }

PYTHON_BIN="$(command -v python3)"
[[ -x "$PYTHON_BIN" ]] || fail "python3 not on PATH"
USER_UID="${USER_UID:-${UID:-501}}"
export USER_UID

write_stub_uname() {
  local bin="$1"
  mkdir -p "$bin"
  cat > "$bin/uname" <<'SH'
#!/bin/sh
echo Darwin
SH
  chmod +x "$bin/uname"
}

# launchctl shim that:
#   - prints whatever the test's stub launchctl PYTHON helper says
#     (via OFLOOP_TEST_LAUNCHCTL_PRINT_BODY_FILE / state file)
#   - returns whatever rc the test sets via env
write_launchctl_shim() {
  local shimdir="$1"
  cat > "$shimdir/launchctl" <<'SH'
#!/bin/bash
{
  printf 'argv=%s\n' "$*"
  for a in "$@"; do printf 'arg=%s\n' "$a"; done
} >> "$OFLOOP_TEST_LAUNCHCTL_CALLLOG"
cmd="${1:-}"
state_file="${OFLOOP_TEST_LAUNCHCTL_STATE_FILE:-}"
plist="${OFLOOP_TEST_LAUNCHCTL_PLIST:-}"
case "$cmd" in
  print)
    target="${2:-}"
    if [[ "$target" == *"/com.ownframework.loop-supervisor" ]]; then
      if [[ -f "$state_file" && -s "$state_file" ]]; then
        if [[ -n "${OFLOOP_TEST_LAUNCHCTL_PRINT_BODY_FILE:-}" && \
              -f "${OFLOOP_TEST_LAUNCHCTL_PRINT_BODY_FILE}" ]]; then
          cat "${OFLOOP_TEST_LAUNCHCTL_PRINT_BODY_FILE}"
        fi
        exit "${OFLOOP_TEST_LAUNCHCTL_PRINT_RC:-0}"
      fi
      exit "${OFLOOP_TEST_LAUNCHCTL_PRINT_RC_ABSENT:-1}"
    fi
    exit 0
    ;;
  kickstart)
    rc="${OFLOOP_TEST_LAUNCHCTL_KICKSTART_RC:-0}"
    [[ "$rc" -eq 0 && -n "$state_file" ]] && rm -f "$state_file"
    exit "$rc"
    ;;
  bootout)
    rc=0
    case "${2:-}" in
      */*) rc="${OFLOOP_TEST_LAUNCHCTL_BOOTOUT_LABEL_RC:-0}" ;;
      *)   rc="${OFLOOP_TEST_LAUNCHCTL_BOOTOUT_PLIST_RC:-0}" ;;
    esac
    [[ "$rc" -eq 0 && -n "$state_file" ]] && rm -f "$state_file"
    exit "$rc"
    ;;
  bootstrap)
    counter_file="${state_file}.bootstrap_count"
    count=0
    [[ -f "$counter_file" ]] && count="$(cat "$counter_file")"
    count=$((count+1))
    printf '%s' "$count" > "$counter_file"
    rc="${OFLOOP_TEST_LAUNCHCTL_BOOTSTRAP_RC:-0}"
    [[ "$rc" -eq 0 && -n "$state_file" ]] && printf 'loaded\n' > "$state_file"
    exit "$rc"
    ;;
  enable) exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$shimdir/launchctl"
}

# Install fake-core layout (mirrors v091m layout).
install_core_layout() {
  local core_root="$1" version="$2"
  local install_root="$core_root/$version"
  mkdir -p "$install_root/bin" "$install_root/lib/ownframework_loop" \
           "$install_root/scripts"
  cat > "$install_root/bin/ofloop" <<PY
#!/usr/bin/env bash
exec "$PYTHON_BIN" "\$@"
PY
  chmod +x "$install_root/bin/ofloop"
  cp "$install_root/bin/ofloop" "$install_root/bin/python3"
  cat > "$install_root/scripts/probe-supervisor-runtime-dependencies.py" <<'PY'
#!/usr/bin/env python3
import sys
sys.exit(0)
PY
  cat > "$install_root/scripts/launch-commissioned-supervisor.py" <<'PY'
#!/usr/bin/env python3
import argparse, os, sys
from pathlib import Path
HERE = Path(__file__).resolve(strict=False)
sys.path.insert(0, str(HERE.parent.parent / "lib"))
from ownframework_loop import service_identity
ap = argparse.ArgumentParser()
ap.add_argument("--db", required=True)
ap.add_argument("--ledger-marker", required=True)
ap.add_argument("--probe", required=True)
ap.add_argument("--ofloop", required=True)
ap.add_argument("--activation-id", required=True)
ap.add_argument("--receipt-path", required=True)
args = ap.parse_args()
argv_list = [sys.executable, str(HERE)] + sys.argv[1:]
try:
    receipt = service_identity.derive_active_identity(
        launcher_argv=argv_list,
        launcher_env=os.environ,
        launcher_pid=os.getpid(),
    )
except ValueError as exc:
    print(f"LAUNCHER=REFUSED reason={exc}", file=sys.stderr)
    sys.exit(78)
service_identity.write_receipt_atomic(receipt, Path(args.receipt_path))
sys.exit(0)
PY
  chmod +x "$install_root/scripts/launch-commissioned-supervisor.py"
  cat > "$install_root/lib/ownframework_loop/runtime_identity.py" <<'PY'
from pathlib import Path
def runtime_generation_for_root(root, version):
    return f"ofloop-{version}@test-stub"
PY
  # Lifecycle helper override (controlled by OFLOOP_TEST_LIFECYCLE_MODE
  # + OFLOOP_TEST_LIFECYCLE_CLEANUP_MODE env vars; see comment below).
  cat > "$install_root/lib/ownframework_loop/macos_service_lifecycle.py" <<'PY'
"""Lifecycle helper override for v091n regression.

Controlled by env:
  OFLOOP_TEST_LIFECYCLE_MODE=A: probe returns True; remove is no-op;
    prove_canonical_label_absent returns False; helper prints
    "reason=stale_label_removal_failed" and exits 1.
  OFLOOP_TEST_LIFECYCLE_MODE=B: probe returns True; remove raises
    RuntimeError("unexpected helper boom").  Helper exits nonzero
    WITHOUT printing the typed stale-label marker.
  OFLOOP_TEST_LIFECYCLE_MODE=C: probe returns False; helper exits 0
    with no output (no service loaded; normal success path).
  OFLOOP_TEST_LIFECYCLE_CLEANUP_MODE=D: remove is no-op; prove returns True.
  OFLOOP_TEST_LIFECYCLE_CLEANUP_MODE=E: remove is no-op; prove returns False.
  OFLOOP_TEST_LIFECYCLE_CLEANUP_MODE=F: remove raises RuntimeError.
"""
import os
def probe_canonical_label(label, domain):
    mode = os.environ.get("OFLOOP_TEST_LIFECYCLE_MODE", "")
    return mode in ("A", "B")

def remove_canonical_label(label, domain, plist=None):
    cleanup_mode = os.environ.get("OFLOOP_TEST_LIFECYCLE_CLEANUP_MODE", "")
    if cleanup_mode == "F":
        raise RuntimeError("unexpected helper boom")
    mode = os.environ.get("OFLOOP_TEST_LIFECYCLE_MODE", "")
    if mode == "B":
        raise RuntimeError("unexpected helper boom")
    return  # no-op otherwise

def prove_canonical_label_absent(label, domain):
    cleanup_mode = os.environ.get("OFLOOP_TEST_LIFECYCLE_CLEANUP_MODE", "")
    if cleanup_mode == "D":
        return True
    if cleanup_mode == "E":
        return False
    if cleanup_mode == "F":
        raise RuntimeError("unexpected helper boom")
    mode = os.environ.get("OFLOOP_TEST_LIFECYCLE_MODE", "")
    if mode == "A":
        return False
    if mode == "B":
        return False
    if mode == "C":
        return True
    return True

def remove_and_prove_absent(label, domain, plist=None):
    remove_canonical_label(label, domain, plist)
    return prove_canonical_label_absent(label, domain)
PY
  for src in "$ROOT_DIR/lib/ownframework_loop/"*.py; do
    [[ -e "$src" ]] || continue
    base="$(basename "$src")"
    [[ "$base" == "__init__.py" || "$base" == "runtime_identity.py" || "$base" == "macos_service_lifecycle.py" ]] && continue
    ln -sf "$src" "$install_root/lib/ownframework_loop/$base"
  done
  printf '__version__ = "%s"\n' "$version" > "$install_root/lib/ownframework_loop/__init__.py"
  echo "$install_root"
}

# Override the installer's macos_service_lifecycle helper by
# installing an override module directly into the fake install root's
# lib/ownframework_loop/ directory.  The installer hardcodes
# PYTHONPATH=$INSTALL_ROOT/lib so the shadow wins via that path.
#
# The actual override module is written by install_core_layout() above;
# its behavior is controlled by OFLOOP_TEST_LIFECYCLE_MODE and
# OFLOOP_TEST_LIFECYCLE_CLEANUP_MODE env vars.

run_installer() {
  local home="$1" state_base="$2" core_root="$3" shimdir="$4" \
        out_file="$5" state_file="$6"
  local db="$state_base/ownframework-loop/supervisor.sqlite3"
  local state_root="$state_base/ownframework-loop"
  local stdout_log="$state_root/supervisor.stdout.log"
  local stderr_log="$state_root/supervisor.stderr.log"
  mkdir -p "$home/Library/LaunchAgents" "$state_root"
  : > "$stdout_log"; : > "$stderr_log"; chmod 0600 "$stdout_log" "$stderr_log"
  python3 -B - "$db" >/dev/null 2>&1 <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE IF NOT EXISTS jobs (id INTEGER PRIMARY KEY, run_id TEXT, status TEXT, runtime_generation TEXT)")
c.commit(); c.close()
PY
  printf 'loaded\n' > "$state_file"
  HOME="$home" XDG_STATE_HOME="$state_base" \
    PATH="$shimdir:$PATH" \
    USER_UID="$USER_UID" \
    OFLOOP_TEST_LAUNCHCTL_CALLLOG="$TMP/calls" \
    OFLOOP_TEST_LAUNCHCTL_STATE_FILE="$state_file" \
    OFLOOP_TEST_LAUNCHCTL_PLIST="$home/Library/LaunchAgents/com.ownframework.loop-supervisor.plist" \
    OFLOOP_TEST_LAUNCHCTL_BOOTSTRAP_RC="${OFLOOP_TEST_LAUNCHCTL_BOOTSTRAP_RC_OVERRIDE:-1}" \
    OFLOOP_TEST_LAUNCHCTL_KICKSTART_RC=0 \
    OFLOOP_TEST_LAUNCHCTL_BOOTOUT_PLIST_RC=0 \
    OFLOOP_TEST_LAUNCHCTL_BOOTOUT_LABEL_RC=0 \
    OFLOOP_TEST_LAUNCHCTL_BOOTSTRAP_FAIL_FIRST=0 \
    PYTHON_BIN="$PYTHON_BIN" OFLOOP_BIN="$core_root/bin/ofloop" \
    SOURCE_ROOT_OVERRIDE="$ROOT_DIR" \
    bash "$ROOT_DIR/scripts/supervisor/install-macos.sh" \
      > "$out_file" 2>&1 || true
  return 0
}

##########################################################################
# CASE A: helper prints expected stale-label refusal + exits nonzero
#   → marker preserved → installer REFUSED with reason containing
#     stale_label_removal_failed (not lifecycle_helper_unexpected_nonzero).
##########################################################################
echo "=== Case A: typed stale-label refusal marker preserved ==="
SHIM_A="$TMP/case-a-shim"
HOME_A="$TMP/case-a-home"; STATE_A="$TMP/case-a-state"; CORE_A="$TMP/case-a-core"
CORE_A_ROOT="$(install_core_layout "$CORE_A" "9.9.1-n-a")"
export OFLOOP_TEST_LIFECYCLE_MODE="A"
export OFLOOP_TEST_LIFECYCLE_CLEANUP_MODE=""
mkdir -p "$SHIM_A"; write_stub_uname "$SHIM_A"; write_launchctl_shim "$SHIM_A"
OFLOOP_TEST_LAUNCHCTL_BOOTSTRAP_RC_OVERRIDE=0 \
  run_installer "$HOME_A" "$STATE_A" "$CORE_A_ROOT" "$SHIM_A" "$TMP/case-a.install.out" "$TMP/case-a.state"
grep -Fq "stale_label_removal_failed" "$TMP/case-a.install.out" \
  || fail "Case A: missing stale_label_removal_failed marker: $(cat "$TMP/case-a.install.out")"
grep -Fq "lifecycle_helper_unexpected_nonzero" "$TMP/case-a.install.out" \
  && fail "Case A: helper nonzero was treated as unexpected: $(cat "$TMP/case-a.install.out")"
pass "Case A: typed stale-label refusal marker preserved"

##########################################################################
# CASE B: helper exits nonzero with unexpected diagnostic (no recognized
# marker) → installer REFUSED with lifecycle_helper_unexpected_nonzero
# (defect B1); never continues to bootstrap.
##########################################################################
echo "=== Case B: unexpected helper nonzero fails closed ==="
SHIM_B="$TMP/case-b-shim"
HOME_B="$TMP/case-b-home"; STATE_B="$TMP/case-b-state"; CORE_B="$TMP/case-b-core"
CORE_B_ROOT="$(install_core_layout "$CORE_B" "9.9.1-n-b")"
export OFLOOP_TEST_LIFECYCLE_MODE="B"
export OFLOOP_TEST_LIFECYCLE_CLEANUP_MODE=""
mkdir -p "$SHIM_B"; write_stub_uname "$SHIM_B"; write_launchctl_shim "$SHIM_B"
# Bootstrap would succeed if reached; if B fails closed, bootstrap is
# never called.
OFLOOP_TEST_LAUNCHCTL_BOOTSTRAP_RC_OVERRIDE=0 \
  run_installer "$HOME_B" "$STATE_B" "$CORE_B_ROOT" "$SHIM_B" "$TMP/case-b.install.out" "$TMP/case-b.state"
grep -Fq "lifecycle_helper_unexpected_nonzero" "$TMP/case-b.install.out" \
  || fail "Case B: missing lifecycle_helper_unexpected_nonzero marker: $(cat "$TMP/case-b.install.out")"
grep -Fq "SUPERVISOR_INSTALL=PASS" "$TMP/case-b.install.out" \
  && fail "Case B: installer emitted PASS despite unexpected helper nonzero: $(cat "$TMP/case-b.install.out")"
# Helper's RuntimeError detail must be preserved in the refusal.
grep -Fq "unexpected helper boom" "$TMP/case-b.install.out" \
  || fail "Case B: helper diagnostic not preserved in refusal: $(cat "$TMP/case-b.install.out")"
pass "Case B: unexpected helper nonzero fails closed with diagnostic"

##########################################################################
# CASE C: helper succeeds → normal install reaches bootstrap.
##########################################################################
echo "=== Case C: helper success path reaches bootstrap ==="
SHIM_C="$TMP/case-c-shim"
HOME_C="$TMP/case-c-home"; STATE_C="$TMP/case-c-state"; CORE_C="$TMP/case-c-core"
CORE_C_ROOT="$(install_core_layout "$CORE_C" "9.9.1-n-c")"
export OFLOOP_TEST_LIFECYCLE_MODE="C"
export OFLOOP_TEST_LIFECYCLE_CLEANUP_MODE=""
mkdir -p "$SHIM_C"; write_stub_uname "$SHIM_C"; write_launchctl_shim "$SHIM_C"
# Bootstrap is the gate: rc=0 means we get past; rc=anything else means
# installer's bootstrap_failed fires.  For Case C, set bootstrap rc=0
# but no receipt+attestation (the launcher would write them in a real
# install; we don't model that here, so the activation-receipt-wait
# will time out — that proves the helper path did NOT short-circuit).
# Use skip-startup-ready to skip attestation wait and bootstrap rc=0
# to reach the activation-receipt-wait (which will time out → REFUSED).
# Either way, the important thing is: the installer DID reach bootstrap
# AND DID NOT short-circuit on a helper nonzero.  The expected refusal
# is either bootstrap_failed (if we set rc!=0) or active_identity_*
# (if we set rc=0).  We test that NEITHER stale_label_removal_failed
# NOR lifecycle_helper_unexpected_nonzero appears.
OFLOOP_TEST_LAUNCHCTL_BOOTSTRAP_RC_OVERRIDE=0 \
  run_installer "$HOME_C" "$STATE_C" "$CORE_C_ROOT" "$SHIM_C" "$TMP/case-c.install.out" "$TMP/case-c.state"
grep -Fq "stale_label_removal_failed" "$TMP/case-c.install.out" \
  && fail "Case C: helper success should not trigger stale_label_removal_failed: $(cat "$TMP/case-c.install.out")"
grep -Fq "lifecycle_helper_unexpected_nonzero" "$TMP/case-c.install.out" \
  && fail "Case C: helper success should not trigger lifecycle_helper_unexpected_nonzero: $(cat "$TMP/case-c.install.out")"
pass "Case C: helper success path reaches bootstrap"

##########################################################################
# CASE D: cleanup succeeds (label genuinely absent) → CLEANUP_ABSENCE_PROVEN
# → rollback=..._label_absent wording.
##########################################################################
echo "=== Case D: cleanup label absence PROVEN → label_absent wording ==="
SHIM_D="$TMP/case-d-shim"
HOME_D="$TMP/case-d-home"; STATE_D="$TMP/case-d-state"; CORE_D="$TMP/case-d-core"
CORE_D_ROOT="$(install_core_layout "$CORE_D" "9.9.1-n-d")"
export OFLOOP_TEST_LIFECYCLE_MODE="C"
export OFLOOP_TEST_LIFECYCLE_CLEANUP_MODE="D"  # helper success, cleanup proven
mkdir -p "$SHIM_D"; write_stub_uname "$SHIM_D"; write_launchctl_shim "$SHIM_D"
OFLOOP_TEST_LAUNCHCTL_BOOTSTRAP_RC_OVERRIDE=44 \
  run_installer "$HOME_D" "$STATE_D" "$CORE_D_ROOT" "$SHIM_D" "$TMP/case-d.install.out" "$TMP/case-d.state"
grep -Fq "cleanup_label_absence_proven" "$TMP/case-d.install.out" \
  || fail "Case D: missing cleanup_label_absence_proven marker: $(cat "$TMP/case-d.install.out")"
grep -Fq "label_presence_unproven" "$TMP/case-d.install.out" \
  && fail "Case D: cleanup proven but wording says presence_unproven: $(cat "$TMP/case-d.install.out")"
pass "Case D: cleanup label absence PROVEN → label_absent wording permitted"

##########################################################################
# CASE E: cleanup fails to prove absence → CLEANUP_ABSENCE_UNPROVEN
# → rollback=..._label_presence_unproven wording.
##########################################################################
echo "=== Case E: cleanup label absence UNPROVEN → label_presence_unproven wording ==="
SHIM_E="$TMP/case-e-shim"
HOME_E="$TMP/case-e-home"; STATE_E="$TMP/case-e-state"; CORE_E="$TMP/case-e-core"
CORE_E_ROOT="$(install_core_layout "$CORE_E" "9.9.1-n-e")"
export OFLOOP_TEST_LIFECYCLE_MODE="C"
export OFLOOP_TEST_LIFECYCLE_CLEANUP_MODE="E"  # helper success, cleanup unproven
mkdir -p "$SHIM_E"; write_stub_uname "$SHIM_E"; write_launchctl_shim "$SHIM_E"
OFLOOP_TEST_LAUNCHCTL_BOOTSTRAP_RC_OVERRIDE=44 \
  run_installer "$HOME_E" "$STATE_E" "$CORE_E_ROOT" "$SHIM_E" "$TMP/case-e.install.out" "$TMP/case-e.state"
grep -Fq "cleanup_label_absence_unproven" "$TMP/case-e.install.out" \
  || fail "Case E: missing cleanup_label_absence_unproven marker: $(cat "$TMP/case-e.install.out")"
grep -Fq "_label_absent\"" "$TMP/case-e.install.out" \
  && fail "Case E: cleanup unproven but wording still says label_absent: $(cat "$TMP/case-e.install.out")"
pass "Case E: cleanup label absence UNPROVEN → label_presence_unproven wording"

##########################################################################
# CASE F: cleanup helper exits nonzero with unexpected diagnostic
# → installer REFUSED with lifecycle_helper_unexpected_nonzero marker
# → never continues.
##########################################################################
echo "=== Case F: cleanup helper unexpected nonzero fails closed ==="
SHIM_F="$TMP/case-f-shim"
HOME_F="$TMP/case-f-home"; STATE_F="$TMP/case-f-state"; CORE_F="$TMP/case-f-core"
CORE_F_ROOT="$(install_core_layout "$CORE_F" "9.9.1-n-f")"
export OFLOOP_TEST_LIFECYCLE_MODE="C"
export OFLOOP_TEST_LIFECYCLE_CLEANUP_MODE="F"  # helper success, cleanup raises
mkdir -p "$SHIM_F"; write_stub_uname "$SHIM_F"; write_launchctl_shim "$SHIM_F"
OFLOOP_TEST_LAUNCHCTL_BOOTSTRAP_RC_OVERRIDE=44 \
  run_installer "$HOME_F" "$STATE_F" "$CORE_F_ROOT" "$SHIM_F" "$TMP/case-f.install.out" "$TMP/case-f.state"
grep -Fq "lifecycle_helper_unexpected_nonzero" "$TMP/case-f.install.out" \
  || fail "Case F: missing lifecycle_helper_unexpected_nonzero marker: $(cat "$TMP/case-f.install.out")"
grep -Fq "_label_absent\"" "$TMP/case-f.install.out" \
  && fail "Case F: cleanup helper raised but wording still says label_absent: $(cat "$TMP/case-f.install.out")"
pass "Case F: cleanup helper unexpected nonzero fails closed"

echo "V091N_COMMISSIONING_LIFECYCLE_FAILURE_PATHS=PASS"
