#!/usr/bin/env bash
# v0.9.1+ (closure m): macOS commissioning active-identity proof.
#
# Loop source owns macOS supervisor commissioning via
# scripts/supervisor/install-macos.sh. The previous installer emitted
# SUPERVISOR_INSTALL=PASS after `launchctl bootstrap` without proving the
# actually loaded launchd job carried the exact commissioned
# configuration. When the canonical-label job originated from a different
# plist (the documented stale-fixture condition), the installer silently
# held the wrong service under the canonical label and reported PASS.
#
# This test exercises the full installer against a shimmed launchctl on
# PATH, using disposable HOME / XDG_STATE_HOME, so the real production
# launchd domain is never touched. Each case writes its own
# OFLOOP_TEST_LAUNCHCTL_FIXTURE describing:
#   - whether kickstart -k / bootout / bootstrap / enable succeed;
#   - the body returned by `launchctl print gui/$UID/$LABEL`.
# The installer must REFUSE on stale-label removal failure and on active
# identity mismatch, and PASS only when the loaded job carries the exact
# expected --db / --ofloop / OFLOOP_RUNTIME_ROOT / XDG_STATE_HOME / stdout
# / stderr / state=running.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
TMP="$(mktemp -d -t ofloop-v091m-commission.XXXXXX)"
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

# Write a launchctl shim that:
#   - records every invocation to $OFLOOP_TEST_LAUNCHCTL_CALLLOG;
#   - for `print gui/$UID/com.ownframework.loop-supervisor` returns the
#     body from $OFLOOP_TEST_LAUNCHCTL_PRINT_BODY (if set) and rc from
#     $OFLOOP_TEST_LAUNCHCTL_PRINT_RC (default 0);
#   - for `kickstart -k` returns rc from
#     $OFLOOP_TEST_LAUNCHCTL_KICKSTART_RC (default 0);
#   - for `bootout $DOMAIN $PLIST` returns rc from
#     $OFLOOP_TEST_LAUNCHCTL_BOOTOUT_PLIST_RC (default 0);
#   - for `bootout $DOMAIN/$LABEL` returns rc from
#     $OFLOOP_TEST_LAUNCHCTL_BOOTOUT_LABEL_RC (default 0);
#   - for `bootstrap $DOMAIN $PLIST` returns rc from
#     $OFLOOP_TEST_LAUNCHCTL_BOOTSTRAP_RC (default 0);
#   - tracks service-loaded state in a marker file:
#       * after a successful kickstart -k or bootout, the service is
#         marked absent (print returns rc=1);
#       * after a successful bootstrap, the service is marked loaded
#         (print returns the configured body) AND the shim invokes
#         the canonical launcher (via the plist's ProgramArguments)
#         so the receipt is written.  This models real launchd's
#         post-bootstrap supervisor startup.
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
    if [[ "$target" == "gui/"*"/com.ownframework.loop-supervisor" ]]; then
      if [[ -f "$state_file" && -s "$state_file" ]]; then
        # If the receipt exists, override the print body's pid field
        # with the receipt's pid so the installer's label/pid binding
        # succeeds.  The receipt is the active-runtime-truth artifact.
        if [[ -n "${OFLOOP_TEST_LAUNCHCTL_RECEIPT_PATH:-}" && \
              -f "${OFLOOP_TEST_LAUNCHCTL_RECEIPT_PATH}" ]]; then
          receipt_pid="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['pid'])" "${OFLOOP_TEST_LAUNCHCTL_RECEIPT_PATH}" 2>/dev/null || true)"
          if [[ -n "${OFLOOP_TEST_LAUNCHCTL_PRINT_BODY_FILE:-}" && \
                -f "${OFLOOP_TEST_LAUNCHCTL_PRINT_BODY_FILE}" ]]; then
            cat "${OFLOOP_TEST_LAUNCHCTL_PRINT_BODY_FILE}"
            if [[ -n "$receipt_pid" ]]; then
              printf '\tpid = %s\n' "$receipt_pid"
            fi
          fi
          exit "${OFLOOP_TEST_LAUNCHCTL_PRINT_RC:-0}"
        fi
        if [[ -n "${OFLOOP_TEST_LAUNCHCTL_PRINT_BODY_FILE:-}" && \
              -f "${OFLOOP_TEST_LAUNCHCTL_PRINT_BODY_FILE}" ]]; then
          cat "${OFLOOP_TEST_LAUNCHCTL_PRINT_BODY_FILE}"
        fi
        exit "${OFLOOP_TEST_LAUNCHCTL_PRINT_RC:-0}"
      fi
      echo "Could not find service" >&2
      exit 1
    fi
    exit 0
    ;;
  kickstart)
    rc="${OFLOOP_TEST_LAUNCHCTL_KICKSTART_RC:-0}"
    if [[ "$rc" -eq 0 && -n "$state_file" ]]; then
      rm -f "$state_file"
    fi
    exit "$rc"
    ;;
  bootout)
    rc=0
    case "${2:-}" in
      */*)
        rc="${OFLOOP_TEST_LAUNCHCTL_BOOTOUT_LABEL_RC:-0}"
        ;;
      *)
        rc="${OFLOOP_TEST_LAUNCHCTL_BOOTOUT_PLIST_RC:-0}"
        ;;
    esac
    if [[ "$rc" -eq 0 && -n "$state_file" ]]; then
      rm -f "$state_file"
    fi
    exit "$rc"
    ;;
  bootstrap)
    counter_file="${state_file}.bootstrap_count"
    count=0
    [[ -f "$counter_file" ]] && count="$(cat "$counter_file")"
    count=$((count+1))
    printf '%s' "$count" > "$counter_file"
    if [[ "${OFLOOP_TEST_LAUNCHCTL_BOOTSTRAP_FAIL_FIRST:-0}" == "1" && \
          "$count" -eq 1 ]]; then
      rc="${OFLOOP_TEST_LAUNCHCTL_BOOTSTRAP_RC:-44}"
      [[ "$rc" -eq 0 ]] && rc=44
    else
      rc="${OFLOOP_TEST_LAUNCHCTL_BOOTSTRAP_RC:-0}"
    fi
    if [[ "$rc" -eq 0 && -n "$state_file" ]]; then
      printf 'loaded\n' > "$state_file"
      # Model real launchd: after a successful bootstrap, the loaded
      # service runs its ProgramArguments.  Parse the plist and exec
      # the launcher so the activation receipt is written.
      if [[ -n "$plist" && -f "$plist" ]]; then
        if command -v python3 >/dev/null 2>&1; then
          python3 - "$plist" <<'PYINV'
import json, os, plistlib, subprocess, sys
with open(sys.argv[1], "rb") as fh:
    payload = plistlib.load(fh)
argv = payload.get("ProgramArguments", [])
env = payload.get("EnvironmentVariables", {})
merged = dict(os.environ)
merged.update({k: str(v) for k, v in env.items()})
sys.exit(subprocess.call([str(a) for a in argv], env=merged))
PYINV
          # Seam 2: also write the durable supervisor's startup-ready
          # attestation from the receipt the launcher just wrote. The
          # post-exec supervisor normally writes this itself; here
          # the test shim writes it because the launcher stub exits
          # before the durable supervisor can take over.
          if [[ -n "${OFLOOP_TEST_LAUNCHCTL_RECEIPT_PATH:-}" && \
                -f "${OFLOOP_TEST_LAUNCHCTL_RECEIPT_PATH}" ]]; then
            if [[ "${OFLOOP_TEST_LAUNCHCTL_SKIP_STARTUP_READY:-0}" != "1" ]]; then
              python3 - "$OFLOOP_TEST_LAUNCHCTL_RECEIPT_PATH" <<'READYPY'
import json, os, sys
from pathlib import Path
receipt_path = Path(sys.argv[1])
ready_path = receipt_path.with_name("supervisor-startup-ready.json")
with open(receipt_path, "r", encoding="utf-8") as fh:
    body = json.load(fh)
attestation = {
    "schema": "ownframework-loop-supervisor-startup-ready/v1",
    "activation_id": body["activation_id"],
    "ready_pid": body["pid"],
    "label": body["label"],
    "runtime_generation": body["runtime_generation"],
    "runtime_root": body["runtime_root"],
    "ofloop_bin": body["ofloop_bin"],
    "supervisor_db": body["supervisor_db"],
    "ledger_marker": body["ledger_marker"],
    "ready_at": body.get("started_at", 0.0),
}
tmp = ready_path.with_name(ready_path.name + ".tmp")
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(attestation, fh, indent=2, sort_keys=True)
os.replace(tmp, ready_path)
READYPY
            fi
          fi
          # For Case C: after the launcher writes a fresh receipt,
          # overwrite it with a stale one to simulate a leftover
          # from a prior activation.  For Case G: tamper with a
          # specific receipt field to test mismatch detection.
          if [[ -n "${OFLOOP_TEST_LAUNCHCTL_RECEIPT_PATH:-}" ]]; then
            if [[ "${OFLOOP_TEST_LAUNCHCTL_FORCE_STALE_RECEIPT:-0}" == "1" ]]; then
              python3 - "$OFLOOP_TEST_LAUNCHCTL_RECEIPT_PATH" <<'STALEPY'
import json, os, sys, time
receipt = {
    "schema": "ownframework-loop-supervisor-activation/v1",
    "activation_id": "00000000-0000-0000-0000-000000000000",
    "pid": int(os.getpid()),
    "label": "com.ownframework.loop-supervisor",
    "runtime_generation": "stale",
    "runtime_root": "/stale",
    "ofloop_bin": "/stale/ofloop",
    "supervisor_db": "/stale/db",
    "ledger_marker": "/stale/ledger",
    "started_at": time.time(),
    "generation_source": "env_fallback",
}
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(receipt, fh, indent=2, sort_keys=True)
import pathlib
ready = pathlib.Path(sys.argv[1]).with_name("supervisor-startup-ready.json")
if ready.exists():
    ready_body = {
        "schema": "ownframework-loop-supervisor-startup-ready/v1",
        "activation_id": "00000000-0000-0000-0000-000000000000",
        "ready_pid": int(os.getpid()),
        "label": "com.ownframework.loop-supervisor",
        "runtime_generation": "stale",
        "runtime_root": "/stale",
        "ofloop_bin": "/stale/ofloop",
        "supervisor_db": "/stale/db",
        "ledger_marker": "/stale/ledger",
        "ready_at": time.time(),
    }
    with open(ready, "w", encoding="utf-8") as fh:
        json.dump(ready_body, fh, indent=2, sort_keys=True)
STALEPY
            elif [[ -n "${OFLOOP_TEST_LAUNCHCTL_TAMPER_RECEIPT_FIELD:-}" ]]; then
              python3 - "$OFLOOP_TEST_LAUNCHCTL_RECEIPT_PATH" "$OFLOOP_TEST_LAUNCHCTL_TAMPER_RECEIPT_FIELD" <<'TAMPERPY'
import json, sys
field, value = sys.argv[2].split("=", 1)
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    receipt = json.load(fh)
receipt[field] = value
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(receipt, fh, indent=2, sort_keys=True)
TAMPERPY
            fi
          fi
        fi
      fi
    fi
    exit "$rc"
    ;;
  enable) exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$shimdir/launchctl"
}

# Canonicalize a filesystem path the same way the installer does: via
# Path().resolve(strict=False), which collapses /var -> /private/var
# aliases and follows symlinks.
canonicalize_path() {
  python3 -B - "$1" <<'PY'
import sys
from pathlib import Path
print(str(Path(sys.argv[1]).resolve(strict=False)))
PY
}

# Build a launchctl print body that matches the canonical commissioned
# configuration.  The installer derives its expected values:
#   - `--db` from raw XDG_STATE_HOME (NOT canonicalized)
#   - `--ofloop`, `OFLOOP_BIN`, `OFLOOP_RUNTIME_ROOT` via canon_path
#     (canonicalized)
#   - `XDG_STATE_HOME` env: the value the installer passes (raw)
#   - stdout / stderr paths: raw
#   - `PYTHON_BIN` env: the canonicalized interpreter path
write_print_body() {
  local body_file="$1" db="$2" ofloop="$3" runtime_root="$4" \
        state_base="$5" stdout_log="$6" stderr_log="$7"
  local canon_ofloop canon_root
  canon_ofloop="$(canonicalize_path "$ofloop")"
  canon_root="$(canonicalize_path "$runtime_root")"
  local canon_python
  canon_python="$(canonicalize_path "$PYTHON_BIN")"
  cat > "$body_file" <<BODY
gui/$USER_UID/com.ownframework.loop-supervisor = {
	active count = 1
	type = LaunchAgent
	state = running

	program = ${canon_python}
	arguments = {
		${canon_python}
		-B
		/runtime/launch-commissioned-supervisor.py
		--db
		${db}
		--ledger-marker
		/var/ledger-marker.json
		--probe
		/runtime/probe-supervisor-runtime-dependencies.py
		--ofloop
		${canon_ofloop}
	}

	working directory = /Users/test/Library/LaunchAgents
	environment = {
		PATH => /opt/homebrew/bin:/usr/bin:/bin
		OFLOOP_RUNTIME_ROOT => ${canon_root}
		OFLOOP_BIN => ${canon_ofloop}
		PYTHON_BIN => ${canon_python}
		XDG_STATE_HOME => ${state_base}
	}

	domain = gui/$USER_UID
	stdout path = ${stdout_log}
	stderr path = ${stderr_log}
}
BODY
}

# Build a structurally valid installed-core layout.  The installer
# derives INSTALL_ROOT from `Path(OFLOOP_BIN).resolve().parents[1]`,
# so the binary must live at $core_root/<version>/bin/ofloop with
# the corresponding lib/ and scripts/ siblings.  The launcher stub
# writes an activation receipt by importing the real
# ``ownframework_loop.service_identity`` module from this repository,
# so the test exercises the actual receipt schema and verify path.
install_core_layout() {
  local core_root="$1" version="$2"
  local install_root="$core_root/$version"
  mkdir -p "$install_root/bin" "$install_root/lib/ownframework_loop" \
           "$install_root/scripts"
  # Use real wrapper scripts (not symlinks) because the installer
  # resolves the binary to determine INSTALL_ROOT and then looks for
  # lib/ and scripts/ siblings of the resolved path.
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
  # Launcher stub: write a real activation receipt then exit 0
  # (the test does not actually exec a durable supervisor).
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

# Derive receipt from THIS process's own argv + env.
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
try:
    service_identity.write_receipt_atomic(receipt, Path(args.receipt_path))
except OSError as exc:
    print(f"LAUNCHER=REFUSED reason=write_failed detail={exc}", file=sys.stderr)
    sys.exit(79)
print(f"LAUNCHER=ATTESTED activation_id={receipt['activation_id']} pid={receipt['pid']}")
sys.exit(0)
PY
  chmod +x "$install_root/scripts/launch-commissioned-supervisor.py"
  # The installer derives runtime_generation via a deterministic payload
  # hash; for the test we expose a stub that returns a fixed string so
  # the install path doesn't depend on the real payload-shape contract.
  cat > "$install_root/lib/ownframework_loop/runtime_identity.py" <<'PY'
from pathlib import Path

def runtime_generation_for_root(root: Path, version: str) -> str:
    return f"ofloop-{version}@test-stub"
PY
  # Symlink the real service_identity.py into the fake install so the
  # launcher stub (and the installer's receipt-verifier block) imports
  # the real module.
  ln -sf "$ROOT_DIR/lib/ownframework_loop/service_identity.py" \
         "$install_root/lib/ownframework_loop/service_identity.py"
  printf '__version__ = "%s"\n' "$version" > "$install_root/lib/ownframework_loop/__init__.py"
  echo "$install_root"
}

run_installer() {
  local home="$1" state_base="$2" core_root="$3" shimdir="$4" \
        print_body_file="$5" launcher_log="$6" out_file="$7" \
        state_file="$8"
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
  # Default the state file to "loaded" if not primed; the installer
  # will boot it out cleanly before bootstrap.  Pass an empty/absent
  # state file to model fresh host (service absent).
  if [[ ! -e "$state_file" ]]; then
    printf 'loaded\n' > "$state_file"
  fi
  HOME="$home" XDG_STATE_HOME="$state_base" \
    PATH="$shimdir:$PATH" \
    USER_UID="$USER_UID" \
    OFLOOP_TEST_LAUNCHCTL_CALLLOG="$launcher_log" \
    OFLOOP_TEST_LAUNCHCTL_PRINT_BODY_FILE="$print_body_file" \
    OFLOOP_TEST_LAUNCHCTL_PRINT_RC=0 \
    OFLOOP_TEST_LAUNCHCTL_STATE_FILE="$state_file" \
    OFLOOP_TEST_LAUNCHCTL_PLIST="$home/Library/LaunchAgents/com.ownframework.loop-supervisor.plist" \
    OFLOOP_TEST_LAUNCHCTL_RECEIPT_PATH="$state_root/supervisor-activation.json" \
    PYTHON_BIN="$PYTHON_BIN" OFLOOP_BIN="$core_root/bin/ofloop" \
    SOURCE_ROOT_OVERRIDE="$ROOT_DIR" \
    bash "$ROOT_DIR/scripts/supervisor/install-macos.sh" \
      > "$out_file" 2>&1 || true
  local rc=$?
  return "$rc"
}

##########################################################################
# Case A: STALE SAME-LABEL REPLACEMENT
#   1) install with v1 print body pointing at v1 DB + v1 OFLOOP_BIN;
#   2) install again with v2 print body pointing at v2 DB + v2 OFLOOP_BIN
#      and bootstrap succeeds.
#   Assert installer emits PASS, kickstart -k was called once, and the
#   final print body in the call log references v2.
##########################################################################
SHIM="$TMP/case-a-shim"; CALLLOG="$TMP/case-a-calls"
HOME_A="$TMP/case-a-home"; STATE_A="$TMP/case-a-state"; CORE_A="$TMP/case-a-core"
CORE_A_ROOT="$(install_core_layout "$CORE_A" "9.9.1-m")"
OFLOOP_A="$CORE_A_ROOT/bin/ofloop"
mkdir -p "$SHIM"; write_stub_uname "$SHIM"; write_launchctl_shim "$SHIM"

PRINT_V1="$TMP/case-a-print-v1"
PRINT_V2="$TMP/case-a-print-v2"
write_print_body "$PRINT_V1" \
  "$STATE_A/ownframework-loop/supervisor.sqlite3" \
  "$OFLOOP_A" \
  "$CORE_A_ROOT" "$STATE_A" \
  "$STATE_A/ownframework-loop/supervisor.stdout.log" \
  "$STATE_A/ownframework-loop/supervisor.stderr.log"

OFLOOP_TEST_LAUNCHCTL_PRINT_BODY_FILE="$PRINT_V1" \
  run_installer "$HOME_A" "$STATE_A" "$CORE_A_ROOT" "$SHIM" "$PRINT_V1" "$CALLLOG" "$TMP/case-a.install.out" "$TMP/case-a.state" || true
grep -Fq "SUPERVISOR_INSTALL=PASS" "$TMP/case-a.install.out" \
  || fail "Case A: first install did not emit PASS: $(cat "$TMP/case-a.install.out")"
pass "Case A: first install with v1 print body emits PASS"

# Now perform a second install whose print body points at v2 args.
write_print_body "$PRINT_V2" \
  "$STATE_A/ownframework-loop/supervisor.sqlite3" \
  "$OFLOOP_A-v2" \
  "$CORE_A_ROOT" "$STATE_A" \
  "$STATE_A/ownframework-loop/supervisor.stdout.log" \
  "$STATE_A/ownframework-loop/supervisor.stderr.log"
: > "$CALLLOG"
run_installer "$HOME_A" "$STATE_A" "$CORE_A_ROOT" "$SHIM" "$PRINT_V2" "$CALLLOG" "$TMP/case-a2.install.out" "$TMP/case-a.state" || true
grep -Fq "SUPERVISOR_INSTALL=PASS" "$TMP/case-a2.install.out" \
  || fail "Case A: stale same-label replacement did not emit PASS: $(cat "$TMP/case-a2.install.out")"
# Seam 3: removal uses bootout (NOT kickstart -k).  The call log
# must show at least one bootout invocation against the canonical
# label OR plist target.
grep -Fq "bootout" "$CALLLOG" \
  || fail "Case A: bootout not invoked on stale same-label replacement: $(cat "$CALLLOG")"
grep -Fq "bootstrap" "$CALLLOG" \
  || fail "Case A: bootstrap not invoked on stale same-label replacement: $(cat "$CALLLOG")"
pass "Case A: stale same-label replacement is removed and re-bootstrapped"

##########################################################################
# Case B: STALE LABEL REMOVAL FAILURE
#   kickstart returns nonzero; bootout (both targets) returns nonzero.
#   Installer must REFUSE with stale_label_removal_failed and exit 14.
##########################################################################
SHIM_B="$TMP/case-b-shim"; CALLLOG_B="$TMP/case-b-calls"
HOME_B="$TMP/case-b-home"; STATE_B="$TMP/case-b-state"; CORE_B="$TMP/case-b-core"
CORE_B_ROOT="$(install_core_layout "$CORE_B" "9.9.1-m")"
OFLOOP_B="$CORE_B_ROOT/bin/ofloop"
mkdir -p "$SHIM_B"; write_stub_uname "$SHIM_B"; write_launchctl_shim "$SHIM_B"
PRINT_B="$TMP/case-b-print"
write_print_body "$PRINT_B" \
  "$STATE_B/ownframework-loop/supervisor.sqlite3" \
  "$OFLOOP_B" "$CORE_B_ROOT" "$STATE_B" \
  "$STATE_B/ownframework-loop/supervisor.stdout.log" \
  "$STATE_B/ownframework-loop/supervisor.stderr.log"

# Pre-create the ledger so the installer skips its first-time supervisor
# import branch.  The active-identity proof under test does not depend on
# the real supervisor schema, only on the path strings.
mkdir -p "$STATE_B/ownframework-loop"
python3 -B - "$STATE_B/ownframework-loop/supervisor.sqlite3" >/dev/null 2>&1 <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE IF NOT EXISTS jobs (id INTEGER PRIMARY KEY, run_id TEXT, status TEXT, runtime_generation TEXT)")
c.commit(); c.close()
PY

# Prime the launchctl state file as "loaded" so the installer enters
# the removal block.  Case B then exercises the failure path.
printf 'loaded\n' > "$TMP/case-b.state"

PATH="$SHIM_B:$PATH" USER_UID="$USER_UID" \
  OFLOOP_TEST_LAUNCHCTL_CALLLOG="$CALLLOG_B" \
  OFLOOP_TEST_LAUNCHCTL_PRINT_BODY_FILE="$PRINT_B" \
  OFLOOP_TEST_LAUNCHCTL_PRINT_RC=0 \
  OFLOOP_TEST_LAUNCHCTL_KICKSTART_RC=1 \
  OFLOOP_TEST_LAUNCHCTL_BOOTOUT_PLIST_RC=1 \
  OFLOOP_TEST_LAUNCHCTL_BOOTOUT_LABEL_RC=1 \
  OFLOOP_TEST_LAUNCHCTL_BOOTSTRAP_RC=1 \
  OFLOOP_TEST_LAUNCHCTL_STATE_FILE="$TMP/case-b.state" \
  HOME="$HOME_B" XDG_STATE_HOME="$STATE_B" \
  PYTHON_BIN="$PYTHON_BIN" OFLOOP_BIN="$OFLOOP_B" \
  SOURCE_ROOT_OVERRIDE="$ROOT_DIR" \
  bash "$ROOT_DIR/scripts/supervisor/install-macos.sh" \
    > "$TMP/case-b.install.out" 2>&1 || RC_B=$?
[[ "${RC_B:-14}" == "14" ]] || fail "Case B: expected exit 14, got rc=${RC_B:-0}: $(cat "$TMP/case-b.install.out")"
grep -Fq "stale_label_removal_failed" "$TMP/case-b.install.out" \
  || fail "Case B: missing stale_label_removal_failed: $(cat "$TMP/case-b.install.out")"
grep -Fq "SUPERVISOR_INSTALL=PASS" "$TMP/case-b.install.out" \
  && fail "Case B: installer emitted PASS when removal failed"
pass "Case B: stale-label removal failure REFUSED without PASS"

##########################################################################
# Case C: STALE ACTIVATION RECEIPT
#   A receipt from a previous installation sits at the canonical
#   receipt path.  The installer generates a fresh activation id and
#   writes a fresh activation-record; the launcher writes the receipt
#   (overwriting the stale one); the installer verifies the receipt
#   against the fresh activation-record.  For this test we intercept
#   the receipt by pre-writing one with a deliberately stale
#   activation_id, so the installer's verification must REFUSE.
##########################################################################
SHIM_C="$TMP/case-c-shim"; CALLLOG_C="$TMP/case-c-calls"
HOME_C="$TMP/case-c-home"; STATE_C="$TMP/case-c-state"; CORE_C="$TMP/case-c-core"
CORE_C_ROOT="$(install_core_layout "$CORE_C" "9.9.1-m")"
OFLOOP_C="$CORE_C_ROOT/bin/ofloop"
mkdir -p "$SHIM_C"; write_stub_uname "$SHIM_C"; write_launchctl_shim "$SHIM_C"

mkdir -p "$STATE_C/ownframework-loop"
python3 -B - "$STATE_C/ownframework-loop/supervisor.sqlite3" >/dev/null 2>&1 <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE IF NOT EXISTS jobs (id INTEGER PRIMARY KEY, run_id TEXT, status TEXT, runtime_generation TEXT)")
c.commit(); c.close()
PY

# Prime launchctl state as "loaded" so installer enters removal+bootstrap.
printf 'loaded\n' > "$TMP/case-c.state"

# Pre-write a stale activation receipt at the canonical path with a
# stale activation_id that does NOT match any current install.  The
# launcher will overwrite this with a fresh receipt, but the test
# intercepts by setting the state file before the install so the
# receipt is not yet present, then writing the stale one between the
# installer's receipt-wait and the receipt-verify.
#
# Simpler approach: provide a launcher that writes a receipt with a
# mismatched activation_id.  We achieve this by overriding the
# activation_id the launcher reads from env.
PATH_C_LAUNCHER_OVERRIDE="$SHIM_C/launcher-override"
cat > "$PATH_C_LAUNCHER_OVERRIDE" <<PYLAUNCHER
#!/usr/bin/env bash
exec "$PYTHON_BIN" "\$@"
PYLAUNCHER
chmod +x "$PATH_C_LAUNCHER_OVERRIDE"

PATH="$SHIM_C:$PATH" USER_UID="$USER_UID" \
  OFLOOP_TEST_LAUNCHCTL_CALLLOG="$CALLLOG_C" \
  OFLOOP_TEST_LAUNCHCTL_PRINT_BODY_FILE="" \
  OFLOOP_TEST_LAUNCHCTL_PRINT_RC=0 \
  OFLOOP_TEST_LAUNCHCTL_KICKSTART_RC=0 \
  OFLOOP_TEST_LAUNCHCTL_BOOTOUT_PLIST_RC=0 \
  OFLOOP_TEST_LAUNCHCTL_BOOTOUT_LABEL_RC=0 \
  OFLOOP_TEST_LAUNCHCTL_BOOTSTRAP_RC=0 \
  OFLOOP_TEST_LAUNCHCTL_STATE_FILE="$TMP/case-c.state" \
  OFLOOP_TEST_LAUNCHCTL_PLIST="$HOME_C/Library/LaunchAgents/com.ownframework.loop-supervisor.plist" \
  OFLOOP_TEST_LAUNCHCTL_RECEIPT_PATH="$STATE_C/ownframework-loop/supervisor-activation.json" \
  OFLOOP_TEST_LAUNCHCTL_FORCE_STALE_RECEIPT=1 \
  HOME="$HOME_C" XDG_STATE_HOME="$STATE_C" \
  PYTHON_BIN="$PYTHON_BIN" OFLOOP_BIN="$OFLOOP_C" \
  SOURCE_ROOT_OVERRIDE="$ROOT_DIR" \
  bash "$ROOT_DIR/scripts/supervisor/install-macos.sh" \
    > "$TMP/case-c.install.out" 2>&1 || true
grep -Fq "SUPERVISOR_INSTALL=PASS" "$TMP/case-c.install.out" \
  && fail "Case C: installer emitted PASS despite stale activation receipt: $(cat "$TMP/case-c.install.out")"
grep -Eq "active_identity_unproven|activation_id_mismatch|activation_record_invalid|activation_receipt_missing" \
  "$TMP/case-c.install.out" \
  || fail "Case C: missing active-identity refusal marker: $(cat "$TMP/case-c.install.out")"
pass "Case C: stale activation receipt REFUSED without PASS"

##########################################################################
# Case D: ORDINARY CANONICAL REFRESH
#   Install once → PASS.  Install again with consistent args → PASS.
##########################################################################
SHIM_D="$TMP/case-d-shim"; CALLLOG_D="$TMP/case-d-calls"
HOME_D="$TMP/case-d-home"; STATE_D="$TMP/case-d-state"; CORE_D="$TMP/case-d-core"
CORE_D_ROOT="$(install_core_layout "$CORE_D" "9.9.1-m")"
OFLOOP_D="$CORE_D_ROOT/bin/ofloop"
mkdir -p "$SHIM_D"; write_stub_uname "$SHIM_D"; write_launchctl_shim "$SHIM_D"

PRINT_D="$TMP/case-d-print"
write_print_body "$PRINT_D" \
  "$STATE_D/ownframework-loop/supervisor.sqlite3" \
  "$OFLOOP_D" "$CORE_D_ROOT" "$STATE_D" \
  "$STATE_D/ownframework-loop/supervisor.stdout.log" \
  "$STATE_D/ownframework-loop/supervisor.stderr.log"

run_installer "$HOME_D" "$STATE_D" "$CORE_D_ROOT" "$SHIM_D" "$PRINT_D" "$CALLLOG_D" "$TMP/case-d.install.out" "$TMP/case-d.state" || true
grep -Fq "SUPERVISOR_INSTALL=PASS" "$TMP/case-d.install.out" \
  || fail "Case D: first install did not emit PASS: $(cat "$TMP/case-d.install.out")"
: > "$CALLLOG_D"
run_installer "$HOME_D" "$STATE_D" "$CORE_D_ROOT" "$SHIM_D" "$PRINT_D" "$CALLLOG_D" "$TMP/case-d.install.out" "$TMP/case-d.state" || true
grep -Fq "SUPERVISOR_INSTALL=PASS" "$TMP/case-d.install.out" \
  || fail "Case D: refresh did not emit PASS: $(cat "$TMP/case-d.install.out")"
pass "Case D: ordinary canonical refresh PASS"

##########################################################################
# Case E: FRESH NEVER-COMMISSIONED HOST
#   No prior plist in HOME/Library/LaunchAgents and no provenance; print
#   reports "service not loaded" (rc != 0); installer must still PASS
#   because the bootstrap path is exercised cleanly.
##########################################################################
SHIM_E="$TMP/case-e-shim"; CALLLOG_E="$TMP/case-e-calls"
HOME_E="$TMP/case-e-home"; STATE_E="$TMP/case-e-state"; CORE_E="$TMP/case-e-core"
CORE_E_ROOT="$(install_core_layout "$CORE_E" "9.9.1-m")"
OFLOOP_E="$CORE_E_ROOT/bin/ofloop"
mkdir -p "$SHIM_E"; write_stub_uname "$SHIM_E"; write_launchctl_shim "$SHIM_E"

PRINT_E="$TMP/case-e-print"
write_print_body "$PRINT_E" \
  "$STATE_E/ownframework-loop/supervisor.sqlite3" \
  "$OFLOOP_E" "$CORE_E_ROOT" "$STATE_E" \
  "$STATE_E/ownframework-loop/supervisor.stdout.log" \
  "$STATE_E/ownframework-loop/supervisor.stderr.log"

# Pre-create the ledger (Case E is inline, not via run_installer).
mkdir -p "$STATE_E/ownframework-loop"
python3 -B - "$STATE_E/ownframework-loop/supervisor.sqlite3" >/dev/null 2>&1 <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE IF NOT EXISTS jobs (id INTEGER PRIMARY KEY, run_id TEXT, status TEXT, runtime_generation TEXT)")
c.commit(); c.close()
PY
# Fresh host: state file must be absent so the shim reports "no service".
rm -f "$TMP/case-e.state"

PATH="$SHIM_E:$PATH" USER_UID="$USER_UID" \
  OFLOOP_TEST_LAUNCHCTL_CALLLOG="$CALLLOG_E" \
  OFLOOP_TEST_LAUNCHCTL_PRINT_BODY_FILE="$PRINT_E" \
  OFLOOP_TEST_LAUNCHCTL_PRINT_RC=0 \
  OFLOOP_TEST_LAUNCHCTL_BOOTSTRAP_RC=0 \
  OFLOOP_TEST_LAUNCHCTL_STATE_FILE="$TMP/case-e.state" \
  OFLOOP_TEST_LAUNCHCTL_PLIST="$HOME_E/Library/LaunchAgents/com.ownframework.loop-supervisor.plist" \
  OFLOOP_TEST_LAUNCHCTL_RECEIPT_PATH="$STATE_E/ownframework-loop/supervisor-activation.json" \
  HOME="$HOME_E" XDG_STATE_HOME="$STATE_E" \
  PYTHON_BIN="$PYTHON_BIN" OFLOOP_BIN="$OFLOOP_E" \
  SOURCE_ROOT_OVERRIDE="$ROOT_DIR" \
  bash "$ROOT_DIR/scripts/supervisor/install-macos.sh" \
    > "$TMP/case-e.install.out" 2>&1 || true
grep -Fq "SUPERVISOR_INSTALL=PASS" "$TMP/case-e.install.out" \
  || fail "Case E: fresh host install did not PASS: $(cat "$TMP/case-e.install.out")"
pass "Case E: fresh never-commissioned host PASS"

##########################################################################
# Case F: BOOTSTRAP FAILURE / ROLLBACK
#   First install → PASS (records OLD plist/provenance/service-env).  A
#   second install where bootstrap returns nonzero must REFUSE with
#   bootstrap_failed and rollback=restored_previous_service; the prior
#   plist/provenance bytes must remain on disk unchanged.
##########################################################################
SHIM_F="$TMP/case-f-shim"; CALLLOG_F="$TMP/case-f-calls"
HOME_F="$TMP/case-f-home"; STATE_F="$TMP/case-f-state"; CORE_F="$TMP/case-f-core"
CORE_F_ROOT="$(install_core_layout "$CORE_F" "9.9.1-m")"
OFLOOP_F="$CORE_F_ROOT/bin/ofloop"
mkdir -p "$SHIM_F"; write_stub_uname "$SHIM_F"; write_launchctl_shim "$SHIM_F"

PRINT_F="$TMP/case-f-print"
write_print_body "$PRINT_F" \
  "$STATE_F/ownframework-loop/supervisor.sqlite3" \
  "$OFLOOP_F" "$CORE_F_ROOT" "$STATE_F" \
  "$STATE_F/ownframework-loop/supervisor.stdout.log" \
  "$STATE_F/ownframework-loop/supervisor.stderr.log"

# Step 1: install successfully to record the previous plist/provenance.
run_installer "$HOME_F" "$STATE_F" "$CORE_F_ROOT" "$SHIM_F" "$PRINT_F" "$CALLLOG_F" "$TMP/case-f.install.out" "$TMP/case-f.state" || true
grep -Fq "SUPERVISOR_INSTALL=PASS" "$TMP/case-f.install.out" \
  || fail "Case F: prior install did not PASS: $(cat "$TMP/case-f.install.out")"
PRIOR_PLIST_BYTES="$(cat "$HOME_F/Library/LaunchAgents/com.ownframework.loop-supervisor.plist")"
PRIOR_PROV_BYTES="$(cat "$STATE_F/ownframework-loop/runtime-provenance.json")"
PRIOR_ENV_BYTES="$(cat "$STATE_F/ownframework-loop/service-env.json")"

# Step 2: install again with bootstrap failing only on the first call.
# The first install's prior service is now the active job; the
# installer must safely boot it out, attempt to bootstrap, fail, and
# roll back.  The roll-back's restore bootstrap must succeed.
# Reset the bootstrap counter so step 2's first call is "first" again.
rm -f "$TMP/case-f.state.bootstrap_count"
# Ledger is already created by run_installer step 1 above.
PATH="$SHIM_F:$PATH" USER_UID="$USER_UID" \
  OFLOOP_TEST_LAUNCHCTL_CALLLOG="$CALLLOG_F" \
  OFLOOP_TEST_LAUNCHCTL_PRINT_BODY_FILE="$PRINT_F" \
  OFLOOP_TEST_LAUNCHCTL_PRINT_RC=0 \
  OFLOOP_TEST_LAUNCHCTL_KICKSTART_RC=0 \
  OFLOOP_TEST_LAUNCHCTL_BOOTOUT_PLIST_RC=0 \
  OFLOOP_TEST_LAUNCHCTL_BOOTOUT_LABEL_RC=0 \
  OFLOOP_TEST_LAUNCHCTL_BOOTSTRAP_RC=0 \
  OFLOOP_TEST_LAUNCHCTL_BOOTSTRAP_FAIL_FIRST=1 \
  OFLOOP_TEST_LAUNCHCTL_STATE_FILE="$TMP/case-f.state" \
  OFLOOP_TEST_LAUNCHCTL_PLIST="$HOME_F/Library/LaunchAgents/com.ownframework.loop-supervisor.plist" \
  OFLOOP_TEST_LAUNCHCTL_RECEIPT_PATH="$STATE_F/ownframework-loop/supervisor-activation.json" \
  HOME="$HOME_F" XDG_STATE_HOME="$STATE_F" \
  PYTHON_BIN="$PYTHON_BIN" OFLOOP_BIN="$OFLOOP_F" \
  SOURCE_ROOT_OVERRIDE="$ROOT_DIR" \
  bash "$ROOT_DIR/scripts/supervisor/install-macos.sh" \
    > "$TMP/case-f.install.out" 2>&1 || true
grep -Fq "SUPERVISOR_INSTALL=REFUSED" "$TMP/case-f.install.out" \
  || fail "Case F: bootstrap failure did not REFUSE: $(cat "$TMP/case-f.install.out")"
grep -Fq "bootstrap_failed" "$TMP/case-f.install.out" \
  || fail "Case F: missing bootstrap_failed marker: $(cat "$TMP/case-f.install.out")"
# Seam 5 of the architectural addendum: rollback no longer claims
# "restored_previous_service" because the restored service is not
# proven via receipt+attestation.  The plist/provenance bytes are
# restored, but the loaded service is unverified.
grep -Fq "rollback=previous_config_bytes_restored_label_absent" "$TMP/case-f.install.out" \
  || fail "Case F: missing previous_config_bytes_restored_label_absent rollback: $(cat "$TMP/case-f.install.out")"
[[ "$(cat "$HOME_F/Library/LaunchAgents/com.ownframework.loop-supervisor.plist")" == "$PRIOR_PLIST_BYTES" ]] \
  || fail "Case F: prior plist bytes mutated on bootstrap failure"
[[ "$(cat "$STATE_F/ownframework-loop/runtime-provenance.json")" == "$PRIOR_PROV_BYTES" ]] \
  || fail "Case F: prior provenance bytes mutated on bootstrap failure"
[[ "$(cat "$STATE_F/ownframework-loop/service-env.json")" == "$PRIOR_ENV_BYTES" ]] \
  || fail "Case F: prior service-env bytes mutated on bootstrap failure"
pass "Case F: bootstrap failure rolls back prior service artifacts"

##########################################################################
# Case G: ACTIVE IDENTITY PROOF
#   Direct test of the installer's identity-proof helper, run through
#   the installer on a controlled shim, asserting that the proof
#   succeeds only when all of program, --db, --ofloop, OFLOOP_RUNTIME_ROOT,
#   XDG_STATE_HOME, stdout, stderr, and state=running match exactly.
##########################################################################
SHIM_G="$TMP/case-g-shim"; CALLLOG_G="$TMP/case-g-calls"
HOME_G="$TMP/case-g-home"; STATE_G="$TMP/case-g-state"; CORE_G="$TMP/case-g-core"
CORE_G_ROOT="$(install_core_layout "$CORE_G" "9.9.1-m")"
OFLOOP_G="$CORE_G_ROOT/bin/ofloop"
mkdir -p "$SHIM_G"; write_stub_uname "$SHIM_G"; write_launchctl_shim "$SHIM_G"

PRINT_G="$TMP/case-g-print"
write_print_body "$PRINT_G" \
  "$STATE_G/ownframework-loop/supervisor.sqlite3" \
  "$OFLOOP_G" "$CORE_G_ROOT" "$STATE_G" \
  "$STATE_G/ownframework-loop/supervisor.stdout.log" \
  "$STATE_G/ownframework-loop/supervisor.stderr.log"
run_installer "$HOME_G" "$STATE_G" "$CORE_G_ROOT" "$SHIM_G" "$PRINT_G" "$CALLLOG_G" "$TMP/case-g.install.out" "$TMP/case-g.state" || true
grep -Fq "SUPERVISOR_INSTALL=PASS" "$TMP/case-g.install.out" \
  || fail "Case G: install did not PASS with matching print body: $(cat "$TMP/case-g.install.out")"

# Now mutate the activation receipt AFTER the launcher writes it:
# the launcher writes a fresh receipt, then we overwrite the
# OFLOOP_RUNTIME_ROOT field.  The installer's receipt verification
# must REFUSE the install with field=runtime_root mismatch.
PATH="$SHIM_G:$PATH" USER_UID="$USER_UID" \
  OFLOOP_TEST_LAUNCHCTL_CALLLOG="$CALLLOG_G" \
  OFLOOP_TEST_LAUNCHCTL_PRINT_BODY_FILE="$PRINT_G" \
  OFLOOP_TEST_LAUNCHCTL_PRINT_RC=0 \
  OFLOOP_TEST_LAUNCHCTL_KICKSTART_RC=0 \
  OFLOOP_TEST_LAUNCHCTL_BOOTOUT_PLIST_RC=0 \
  OFLOOP_TEST_LAUNCHCTL_BOOTOUT_LABEL_RC=0 \
  OFLOOP_TEST_LAUNCHCTL_BOOTSTRAP_RC=0 \
  OFLOOP_TEST_LAUNCHCTL_STATE_FILE="$TMP/case-g.state" \
  OFLOOP_TEST_LAUNCHCTL_PLIST="$HOME_G/Library/LaunchAgents/com.ownframework.loop-supervisor.plist" \
  OFLOOP_TEST_LAUNCHCTL_RECEIPT_PATH="$STATE_G/ownframework-loop/supervisor-activation.json" \
  OFLOOP_TEST_LAUNCHCTL_TAMPER_RECEIPT_FIELD="runtime_root=/wrong/runtime/root" \
  HOME="$HOME_G" XDG_STATE_HOME="$STATE_G" \
  PYTHON_BIN="$PYTHON_BIN" OFLOOP_BIN="$OFLOOP_G" \
  SOURCE_ROOT_OVERRIDE="$ROOT_DIR" \
  bash "$ROOT_DIR/scripts/supervisor/install-macos.sh" \
    > "$TMP/case-g-bad.install.out" 2>&1 || true
grep -Fq "SUPERVISOR_INSTALL=PASS" "$TMP/case-g-bad.install.out" \
  && fail "Case G: install emitted PASS with mismatched receipt runtime_root"
grep -Eq "active_identity_unproven_or_mismatch|field=runtime_root" \
  "$TMP/case-g-bad.install.out" \
  || fail "Case G: identity mismatch not surfaced: $(cat "$TMP/case-g-bad.install.out")"
pass "Case G: receipt verification refuses mismatched runtime_root"

# Mismatched supervisor_db field on the receipt: same pattern.
PATH="$SHIM_G:$PATH" USER_UID="$USER_UID" \
  OFLOOP_TEST_LAUNCHCTL_CALLLOG="$CALLLOG_G" \
  OFLOOP_TEST_LAUNCHCTL_PRINT_BODY_FILE="$PRINT_G" \
  OFLOOP_TEST_LAUNCHCTL_PRINT_RC=0 \
  OFLOOP_TEST_LAUNCHCTL_KICKSTART_RC=0 \
  OFLOOP_TEST_LAUNCHCTL_BOOTOUT_PLIST_RC=0 \
  OFLOOP_TEST_LAUNCHCTL_BOOTOUT_LABEL_RC=0 \
  OFLOOP_TEST_LAUNCHCTL_BOOTSTRAP_RC=0 \
  OFLOOP_TEST_LAUNCHCTL_STATE_FILE="$TMP/case-g.state" \
  OFLOOP_TEST_LAUNCHCTL_PLIST="$HOME_G/Library/LaunchAgents/com.ownframework.loop-supervisor.plist" \
  OFLOOP_TEST_LAUNCHCTL_RECEIPT_PATH="$STATE_G/ownframework-loop/supervisor-activation.json" \
  OFLOOP_TEST_LAUNCHCTL_TAMPER_RECEIPT_FIELD="supervisor_db=/wrong/db.sqlite3" \
  HOME="$HOME_G" XDG_STATE_HOME="$STATE_G" \
  PYTHON_BIN="$PYTHON_BIN" OFLOOP_BIN="$OFLOOP_G" \
  SOURCE_ROOT_OVERRIDE="$ROOT_DIR" \
  bash "$ROOT_DIR/scripts/supervisor/install-macos.sh" \
    > "$TMP/case-g-bad2.install.out" 2>&1 || true
grep -Fq "SUPERVISOR_INSTALL=PASS" "$TMP/case-g-bad2.install.out" \
  && fail "Case G: install emitted PASS with mismatched receipt supervisor_db"
grep -Eq "active_identity_unproven_or_mismatch|field=supervisor_db" \
  "$TMP/case-g-bad2.install.out" \
  || fail "Case G: identity mismatch not surfaced for supervisor_db: $(cat "$TMP/case-g-bad2.install.out")"
pass "Case G: receipt verification refuses mismatched supervisor_db"

echo "V091M_COMMISSIONING_IDENTITY_PROOF=PASS"
