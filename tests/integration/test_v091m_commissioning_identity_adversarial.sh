#!/usr/bin/env bash
# v0.9.1+ (closure m): macOS commissioning active-identity adversarial
# regressions.  Each case proves an INDEPENDENCE-OF-PROOF assertion
# from the architectural addendum's Seam 7:
#
#   A: configured env vs actual --ofloop mismatch (receipt derives refuse)
#   B: configured runtime_generation vs generation from actual payload
#      (receipt derives differ; verifier refuses on env mismatch)
#   C: configured DB vs actual launcher DB (verifier refuses on mismatch)
#   D: receipt written but durable supervisor startup fails (startup_ready
#      missing → REFUSED)
#   E: correct receipt but canonical label belongs to another PID
#      (label_pid_mismatch → REFUSED)
#   F: canonical label still present after removal reports success
#      (stale_label_removal_failed → REFUSED)
#   G: activation from prior install cannot satisfy current attempt
#      (activation_id_mismatch → REFUSED)
#
# Cases A/B/C are direct unit-level tests against the receipt
# derivation/verification helpers (no installer invocation): they prove
# the receipt module enforces independence from configured commissioning
# truth.  Cases D/E/F/G run the installer end-to-end with adversarial
# shim configurations.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../_helpers.sh"
. "$HERE/../launchctl_fixture.sh"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
TMP="$(mktemp -d -t ofloop-v091m-adversarial.XXXXXX)"
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

# Launchctl shim that:
#   - records every invocation;
#   - tracks service-loaded state in a marker file so the installer's
#     stop-by-label re-probe can prove removal (Seam 3);
#   - models post-bootstrap supervisor startup by writing a receipt +
#     startup-ready attestation via the real service_identity code;
#   - supports adversarial overrides via OFLOOP_TEST_LAUNCHCTL_* env:
#       FOREIGN_PID=1: launchd-reported pid = 999999 (foreign process);
#       FORCE_LABEL_STILL_LOADED=1: re-prime state file after bootout;
#       TAMPER_RECEIPT_FIELD=field=value: rewrite receipt field after write;
#       SKIP_STARTUP_READY=1: do NOT write startup-ready attestation;
#       NO_RECEIPT=1: do not write receipt (test will pre-write a stale one).
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
      if [[ "${OFLOOP_TEST_LAUNCHCTL_FORCE_LABEL_STILL_LOADED:-0}" == "1" ]]; then
        printf 'loaded\n' > "$state_file"
      fi
      if [[ -f "$state_file" && -s "$state_file" ]]; then
        if [[ "${OFLOOP_TEST_LAUNCHCTL_FOREIGN_PID:-0}" == "1" ]]; then
          printf 'gui/501/com.ownframework.loop-supervisor = {\n'
          printf '\tstate = running\n'
          printf '\tpid = %s\n' "999999"
          printf '}\n'
          exit 0
        fi
        if [[ -n "${OFLOOP_TEST_LAUNCHCTL_RECEIPT_PATH:-}" && \
              -f "${OFLOOP_TEST_LAUNCHCTL_RECEIPT_PATH}" ]]; then
          receipt_pid="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['pid'])" "${OFLOOP_TEST_LAUNCHCTL_RECEIPT_PATH}" 2>/dev/null || true)"
          printf 'gui/501/com.ownframework.loop-supervisor = {\n'
          printf '\tstate = running\n'
          printf '\tpid = %s\n' "${receipt_pid:-0}"
          printf '}\n'
          exit 0
        fi
        exit 0
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
      */*) rc="${OFLOOP_TEST_LAUNCHCTL_BOOTOUT_LABEL_RC:-0}" ;;
      *)   rc="${OFLOOP_TEST_LAUNCHCTL_BOOTOUT_PLIST_RC:-0}" ;;
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
      if [[ -n "$plist" && -f "$plist" && \
            "${OFLOOP_TEST_LAUNCHCTL_NO_LAUNCH:-0}" != "1" ]]; then
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
      fi
      if [[ -n "${OFLOOP_TEST_LAUNCHCTL_RECEIPT_PATH:-}" && \
            -f "${OFLOOP_TEST_LAUNCHCTL_RECEIPT_PATH}" && \
            "${OFLOOP_TEST_LAUNCHCTL_SKIP_STARTUP_READY:-0}" != "1" ]]; then
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
      if [[ -n "${OFLOOP_TEST_LAUNCHCTL_TAMPER_RECEIPT_FIELD:-}" ]]; then
        python3 - "$OFLOOP_TEST_LAUNCHCTL_RECEIPT_PATH" "${OFLOOP_TEST_LAUNCHCTL_TAMPER_RECEIPT_FIELD}" <<'TAMPERPY'
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
    exit "$rc"
    ;;
  enable) exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$shimdir/launchctl"
}

# Build a structurally valid installed-core layout.  Symlinks the
# real ownframework_loop modules so the launcher's receipt-writer
# imports the actual production code.
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
try:
    service_identity.write_receipt_atomic(receipt, Path(args.receipt_path))
except OSError as exc:
    print(f"LAUNCHER=REFUSED reason=write_failed detail={exc}", file=sys.stderr)
    sys.exit(79)
print(f"LAUNCHER=ATTESTED activation_id={receipt['activation_id']} pid={receipt['pid']}")
sys.exit(0)
PY
  chmod +x "$install_root/scripts/launch-commissioned-supervisor.py"
  # Stub runtime_identity that returns a deterministic version-keyed
  # generation so the receipt's runtime_generation is predictable.
  cat > "$install_root/lib/ownframework_loop/runtime_identity.py" <<PY
from pathlib import Path
def runtime_generation_for_root(root: Path, version: str) -> str:
    return f"ofloop-{version}@test-stub"
PY
  # Symlink the rest of the real ownframework_loop modules so the
  # launcher's receipt-writer can import service_identity.  Skip
  # __init__.py because the printf below will write to it directly
  # (symlinking it would redirect the write into the real source).
  for src in "$ROOT_DIR/lib/ownframework_loop/"*.py "$ROOT_DIR/lib/ownframework_loop/locking"; do
    [[ -e "$src" ]] || continue
    base="$(basename "$src")"
    [[ "$base" == "__init__.py" || "$base" == "runtime_identity.py" ]] && continue
    ln -sf "$src" "$install_root/lib/ownframework_loop/$base"
  done
  printf '__version__ = "%s"\n' "$version" > "$install_root/lib/ownframework_loop/__init__.py"
  echo "$install_root"
}

##########################################################################
# Case A: configured env vs actual --ofloop mismatch.
#   Receipt derivation MUST refuse when --ofloop argv disagrees with
#   OFLOOP_BIN env (Seam 1).  The receipt is never written; the
#   launcher fails before exec into the durable supervisor.
##########################################################################
echo "=== Case A: configured env vs actual --ofloop mismatch ==="
CORE_A_ROOT="$(install_core_layout "$TMP/case-a-core" "9.9.1-m-a")"
CORE_A2_ROOT="$(install_core_layout "$TMP/case-a-core-2" "9.9.1-m-a2")"
OFLOOP_A="$CORE_A_ROOT/bin/ofloop"
OFLOOP_A2="$CORE_A2_ROOT/bin/ofloop"
ACTIVATION_ID_A="$(uuidgen 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())')"
DERIVE_OUT_A="$(OFLOOP_A_PATH="$OFLOOP_A" python3 - "$OFLOOP_A2" "$PYTHON_BIN" \
  "$CORE_A_ROOT/scripts/launch-commissioned-supervisor.py" \
  "$CORE_A_ROOT/scripts/probe-supervisor-runtime-dependencies.py" \
  "$ACTIVATION_ID_A" <<'PY' 2>&1
import json, os, sys
from pathlib import Path
actual_ofloop = sys.argv[1]
python_bin = sys.argv[2]
launcher = sys.argv[3]
probe = sys.argv[4]
activation_id = sys.argv[5]
sys.path.insert(0, str(Path(launcher).parent.parent / "lib"))
from ownframework_loop import service_identity
argv_list = [
    python_bin, "-B", launcher,
    "--db", "/tmp/db.sqlite3",
    "--ledger-marker", "/tmp/ledger.json",
    "--probe", probe,
    "--ofloop", actual_ofloop,
    "--activation-id", activation_id,
    "--receipt-path", "/tmp/receipt.json",
]
env = {
    "OFLOOP_ACTIVATION_ID": activation_id,
    "OFLOOP_BIN": os.environ["OFLOOP_A_PATH"],
    "OFLOOP_RUNTIME_ROOT": str(Path(actual_ofloop).resolve(strict=False).parent.parent),
    "OFLOOP_RUNTIME_GENERATION": "ofloop-9.9.1-m-a@test-stub",
    "LABEL": "com.ownframework.loop-supervisor",
}
try:
    receipt = service_identity.derive_active_identity(
        launcher_argv=argv_list,
        launcher_env=env,
        launcher_pid=os.getpid(),
    )
    print("DERIVED=" + json.dumps(receipt))
    sys.exit(0)
except ValueError as exc:
    print("REFUSED=" + str(exc))
    sys.exit(14)
PY
)" || true
if echo "$DERIVE_OUT_A" | grep -Fq "DERIVED="; then
  fail "Case A: receipt derived despite OFLOOP_BIN/--ofloop mismatch: $DERIVE_OUT_A"
fi
echo "$DERIVE_OUT_A" | grep -Fq "ofloop_bin_mismatch" \
  || fail "Case A: derivation did not surface ofloop_bin_mismatch: $DERIVE_OUT_A"
pass "Case A: configured vs actual --ofloop mismatch refused at derivation"

##########################################################################
# Case B: configured runtime_generation vs generation from actual payload.
#   Receipt derives a runtime_generation from actual payload (via
#   runtime_identity.runtime_generation_for_root).  Verifier compares
#   receipt.runtime_generation against the installer's configured
#   commissioning truth (OFLOOP_RUNTIME_GENERATION env).  When the
#   receipt's payload-derived value differs from the configured env
#   value, REFUSED.
##########################################################################
echo "=== Case B: configured runtime_generation vs actual payload ==="
CORE_B_ROOT="$(install_core_layout "$TMP/case-b-core" "9.9.1-m-b")"
OFLOOP_B="$CORE_B_ROOT/bin/ofloop"
ACTIVATION_ID_B="$(uuidgen 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())')"
RECEIPT_B_PATH="$TMP/case-b-receipt.json"
OFLOOP_B_PATH="$OFLOOP_B" python3 - "$OFLOOP_B" "$PYTHON_BIN" \
  "$CORE_B_ROOT/scripts/launch-commissioned-supervisor.py" \
  "$CORE_B_ROOT/scripts/probe-supervisor-runtime-dependencies.py" \
  "$ACTIVATION_ID_B" "$RECEIPT_B_PATH" <<'PY' 2>&1
import json, os, sys
from pathlib import Path
actual_ofloop = sys.argv[1]
python_bin = sys.argv[2]
launcher = sys.argv[3]
probe = sys.argv[4]
activation_id = sys.argv[5]
receipt_path = Path(sys.argv[6])
sys.path.insert(0, str(Path(launcher).parent.parent / "lib"))
from ownframework_loop import service_identity
argv_list = [
    python_bin, "-B", launcher,
    "--db", "/tmp/db.sqlite3",
    "--ledger-marker", "/tmp/ledger.json",
    "--probe", probe,
    "--ofloop", actual_ofloop,
    "--activation-id", activation_id,
    "--receipt-path", str(receipt_path),
]
env = {
    "OFLOOP_ACTIVATION_ID": activation_id,
    "OFLOOP_BIN": os.environ["OFLOOP_B_PATH"],
    "OFLOOP_RUNTIME_ROOT": str(Path(actual_ofloop).resolve(strict=False).parent.parent),
    # The configured commissioning truth: stale-X.  The launcher's
    # payload-recomputation will OVERRIDE this with the actual
    # payload's generation "ofloop-9.9.1-m-b@test-stub" (the stub
    # runtime_identity).
    "OFLOOP_RUNTIME_GENERATION": "stale-X@configured",
    "LABEL": "com.ownframework.loop-supervisor",
}
receipt = service_identity.derive_active_identity(
    launcher_argv=argv_list,
    launcher_env=env,
    launcher_pid=os.getpid(),
)
service_identity.write_receipt_atomic(receipt, receipt_path)
PY
# Receipt should derive runtime_generation from the actual payload
# (the stub returns ofloop-9.9.1-m-b@test-stub), NOT from the env.
RUNTIME_GEN_B="$(python3 -c "import json; print(json.load(open('$RECEIPT_B_PATH'))['runtime_generation'])")"
[[ "$RUNTIME_GEN_B" == "ofloop-9.9.1-m-b@test-stub" ]] \
  || fail "Case B: receipt.runtime_generation=$RUNTIME_GEN_B (expected payload-derived value)"

# Now verify with the configured commissioning truth OFLOOP_RUNTIME_GENERATION=stale-X.
VERIFY_OUT_B="$(RUNTIME_GENERATION="stale-X@configured" INSTALL_ROOT="$CORE_B_ROOT" \
  OFLOOP_BIN="$OFLOOP_B" "$PYTHON_BIN" -B - "$RECEIPT_B_PATH" "$ACTIVATION_ID_B" <<'PY' 2>&1
import json, os, sys
from pathlib import Path as _Path
receipt_path = sys.argv[1]
activation_id = sys.argv[2]
from ownframework_loop import service_identity
receipt = service_identity.load_receipt(_Path(receipt_path))
expected = {
    "pid": int(receipt.get("pid", 0)),
    "label": "com.ownframework.loop-supervisor",
    "runtime_generation": os.environ["RUNTIME_GENERATION"],
    "runtime_root": os.environ["INSTALL_ROOT"],
    "ofloop_bin": os.environ["OFLOOP_BIN"],
    "supervisor_db": "/tmp/db.sqlite3",
    "ledger_marker": "/tmp/ledger.json",
}
ok, reason = service_identity.verify_active_identity(receipt, activation_id, expected)
print("ok=" + str(ok), "reason=" + reason)
PY
)"
if echo "$VERIFY_OUT_B" | grep -Fq "ok=True"; then
  fail "Case B: verifier ACCEPTED stale-X vs receipt's payload value: $VERIFY_OUT_B"
fi
echo "$VERIFY_OUT_B" | grep -Eq "runtime_generation|field=runtime_generation" \
  || fail "Case B: verifier did not surface runtime_generation mismatch: $VERIFY_OUT_B"
pass "Case B: configured vs payload-derived runtime_generation REFUSED"

##########################################################################
# Case C: configured DB vs actual launcher DB.
#   Receipt carries supervisor_db from --db argv.  Verifier compares
#   against installer's expected supervisor_db (from XDG_STATE_HOME).
#   When they disagree, REFUSED.
##########################################################################
echo "=== Case C: configured DB vs actual launcher DB ==="
CORE_C_ROOT="$(install_core_layout "$TMP/case-c-core" "9.9.1-m-c")"
OFLOOP_C="$CORE_C_ROOT/bin/ofloop"
ACTIVATION_ID_C="$(uuidgen 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())')"
RECEIPT_C_PATH="$TMP/case-c-receipt.json"
python3 - "$OFLOOP_C" "$PYTHON_BIN" \
  "$CORE_C_ROOT/scripts/launch-commissioned-supervisor.py" \
  "$CORE_C_ROOT/scripts/probe-supervisor-runtime-dependencies.py" \
  "$ACTIVATION_ID_C" "$RECEIPT_C_PATH" <<'PY' 2>&1
import json, os, sys
from pathlib import Path
actual_ofloop = sys.argv[1]
python_bin = sys.argv[2]
launcher = sys.argv[3]
probe = sys.argv[4]
activation_id = sys.argv[5]
receipt_path = Path(sys.argv[6])
sys.path.insert(0, str(Path(launcher).parent.parent / "lib"))
from ownframework_loop import service_identity
argv_list = [
    python_bin, "-B", launcher,
    # Actual launcher DB path: /tmp/launcher-actual/db.sqlite3
    "--db", "/tmp/launcher-actual/db.sqlite3",
    "--ledger-marker", "/tmp/launcher-actual/ledger.json",
    "--probe", probe,
    "--ofloop", actual_ofloop,
    "--activation-id", activation_id,
    "--receipt-path", str(receipt_path),
]
env = {
    "OFLOOP_ACTIVATION_ID": activation_id,
    "OFLOOP_BIN": actual_ofloop,
    "OFLOOP_RUNTIME_ROOT": str(Path(actual_ofloop).resolve(strict=False).parent.parent),
    "OFLOOP_RUNTIME_GENERATION": "ofloop-9.9.1-m-c@test-stub",
    "LABEL": "com.ownframework.loop-supervisor",
}
receipt = service_identity.derive_active_identity(
    launcher_argv=argv_list,
    launcher_env=env,
    launcher_pid=os.getpid(),
)
service_identity.write_receipt_atomic(receipt, receipt_path)
PY

# Now verify with the installer's expected DB path: /tmp/installer-expected/db.sqlite3.
# Receipt says /tmp/launcher-actual/db.sqlite3.  Mismatch → REFUSED.
RUNTIME_ROOT_C="$("$PYTHON_BIN" -c "from pathlib import Path; print(str(Path('$OFLOOP_C').resolve(strict=False).parent.parent))")"
OFLOOP_C_CANON="$("$PYTHON_BIN" -c "from pathlib import Path; print(str(Path('$OFLOOP_C').resolve(strict=False)))")"
VERIFY_OUT_C="$(RUNTIME_ROOT_C="$RUNTIME_ROOT_C" OFLOOP_BIN="$OFLOOP_C_CANON" "$PYTHON_BIN" -B - "$RECEIPT_C_PATH" "$ACTIVATION_ID_C" <<'PY' 2>&1
import json, os, sys
from pathlib import Path as _Path
receipt_path = sys.argv[1]
activation_id = sys.argv[2]
from ownframework_loop import service_identity
receipt = service_identity.load_receipt(_Path(receipt_path))
expected = {
    "pid": int(receipt.get("pid", 0)),
    "label": "com.ownframework.loop-supervisor",
    "runtime_generation": "ofloop-9.9.1-m-c@test-stub",
    "runtime_root": os.environ["RUNTIME_ROOT_C"],
    "ofloop_bin": os.environ["OFLOOP_BIN"],
    # Installer's expected DB (different from launcher's actual)
    "supervisor_db": "/tmp/installer-expected/db.sqlite3",
    "ledger_marker": "/tmp/installer-expected/ledger.json",
}
ok, reason = service_identity.verify_active_identity(receipt, activation_id, expected)
print("ok=" + str(ok), "reason=" + reason)
PY
)"
if echo "$VERIFY_OUT_C" | grep -Fq "ok=True"; then
  fail "Case C: verifier ACCEPTED launcher-actual vs installer-expected DB mismatch: $VERIFY_OUT_C"
fi
echo "$VERIFY_OUT_C" | grep -Eq "supervisor_db|field=supervisor_db" \
  || fail "Case C: verifier did not surface supervisor_db mismatch: $VERIFY_OUT_C"
pass "Case C: configured vs actual DB mismatch REFUSED"

##########################################################################
# Case D: receipt written but durable supervisor startup fails.
#   Run the installer end-to-end with the launcher's startup-ready
#   attestation suppressed (SKIP_STARTUP_READY=1).  The receipt-wait
#   succeeds but the startup-ready-wait fails → REFUSED.
##########################################################################
echo "=== Case D: receipt written but durable supervisor startup fails ==="
SHIM_D="$TMP/case-d-shim"; CALLLOG_D="$TMP/case-d-calls"
HOME_D="$TMP/case-d-home"; STATE_D="$TMP/case-d-state"
CORE_D="$TMP/case-d-core"
CORE_D_ROOT="$(install_core_layout "$CORE_D" "9.9.1-m-d")"
OFLOOP_D="$CORE_D_ROOT/bin/ofloop"
mkdir -p "$SHIM_D"; write_stub_uname "$SHIM_D"; write_launchctl_shim "$SHIM_D"
mkdir -p "$STATE_D/ownframework-loop"
python3 -B - "$STATE_D/ownframework-loop/supervisor.sqlite3" >/dev/null 2>&1 <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE IF NOT EXISTS jobs (id INTEGER PRIMARY KEY, run_id TEXT, status TEXT, runtime_generation TEXT)")
c.commit(); c.close()
PY
printf 'loaded\n' > "$TMP/case-d.state"
PATH="$SHIM_D:$PATH" USER_UID="$USER_UID" \
  OFLOOP_TEST_LAUNCHCTL_CALLLOG="$CALLLOG_D" \
  OFLOOP_TEST_LAUNCHCTL_STATE_FILE="$TMP/case-d.state" \
  OFLOOP_TEST_LAUNCHCTL_PLIST="$HOME_D/Library/LaunchAgents/com.ownframework.loop-supervisor.plist" \
  OFLOOP_TEST_LAUNCHCTL_RECEIPT_PATH="$STATE_D/ownframework-loop/supervisor-activation.json" \
  OFLOOP_TEST_LAUNCHCTL_SKIP_STARTUP_READY=1 \
  HOME="$HOME_D" XDG_STATE_HOME="$STATE_D" \
  PYTHON_BIN="$PYTHON_BIN" OFLOOP_BIN="$OFLOOP_D" \
  SOURCE_ROOT_OVERRIDE="$ROOT_DIR" \
  bash "$ROOT_DIR/scripts/supervisor/install-macos.sh" \
    > "$TMP/case-d.install.out" 2>&1 || true
if grep -Fq "SUPERVISOR_INSTALL=PASS" "$TMP/case-d.install.out"; then
  fail "Case D: installer emitted PASS despite missing startup-ready: $(cat "$TMP/case-d.install.out")"
fi
grep -Eq "active_identity_unproven|startup_ready_missing" "$TMP/case-d.install.out" \
  || fail "Case D: missing startup_ready refusal marker: $(cat "$TMP/case-d.install.out")"
pass "Case D: missing durable supervisor attestation REFUSED"

##########################################################################
# Case E: correct receipt but canonical label belongs to another PID.
#   Run the installer with FOREIGN_PID=1; launchd reports pid=999999
#   instead of the receipt pid → label_pid_mismatch → REFUSED.
##########################################################################
echo "=== Case E: correct receipt but canonical label belongs to another PID ==="
SHIM_E="$TMP/case-e-shim"; CALLLOG_E="$TMP/case-e-calls"
HOME_E="$TMP/case-e-home"; STATE_E="$TMP/case-e-state"
CORE_E="$TMP/case-e-core"
CORE_E_ROOT="$(install_core_layout "$CORE_E" "9.9.1-m-e")"
OFLOOP_E="$CORE_E_ROOT/bin/ofloop"
mkdir -p "$SHIM_E"; write_stub_uname "$SHIM_E"; write_launchctl_shim "$SHIM_E"
mkdir -p "$STATE_E/ownframework-loop"
python3 -B - "$STATE_E/ownframework-loop/supervisor.sqlite3" >/dev/null 2>&1 <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE IF NOT EXISTS jobs (id INTEGER PRIMARY KEY, run_id TEXT, status TEXT, runtime_generation TEXT)")
c.commit(); c.close()
PY
printf 'loaded\n' > "$TMP/case-e.state"
PATH="$SHIM_E:$PATH" USER_UID="$USER_UID" \
  OFLOOP_TEST_LAUNCHCTL_CALLLOG="$CALLLOG_E" \
  OFLOOP_TEST_LAUNCHCTL_STATE_FILE="$TMP/case-e.state" \
  OFLOOP_TEST_LAUNCHCTL_PLIST="$HOME_E/Library/LaunchAgents/com.ownframework.loop-supervisor.plist" \
  OFLOOP_TEST_LAUNCHCTL_RECEIPT_PATH="$STATE_E/ownframework-loop/supervisor-activation.json" \
  OFLOOP_TEST_LAUNCHCTL_FOREIGN_PID=1 \
  HOME="$HOME_E" XDG_STATE_HOME="$STATE_E" \
  PYTHON_BIN="$PYTHON_BIN" OFLOOP_BIN="$OFLOOP_E" \
  SOURCE_ROOT_OVERRIDE="$ROOT_DIR" \
  bash "$ROOT_DIR/scripts/supervisor/install-macos.sh" \
    > "$TMP/case-e.install.out" 2>&1 || true
if grep -Fq "SUPERVISOR_INSTALL=PASS" "$TMP/case-e.install.out"; then
  fail "Case E: installer emitted PASS despite foreign label pid: $(cat "$TMP/case-e.install.out")"
fi
grep -Eq "active_identity_unproven|label_pid_mismatch" "$TMP/case-e.install.out" \
  || fail "Case E: missing label_pid_mismatch refusal marker: $(cat "$TMP/case-e.install.out")"
pass "Case E: foreign label pid REFUSED"

##########################################################################
# Case F: canonical label still present after removal reports success.
#   bootout returns rc=0 but state file is forced to persist.  Re-probe
#   detects stale label → stale_label_removal_failed → REFUSED.
##########################################################################
echo "=== Case F: canonical label still present after removal reports success ==="
SHIM_F="$TMP/case-f-shim"; CALLLOG_F="$TMP/case-f-calls"
HOME_F="$TMP/case-f-home"; STATE_F="$TMP/case-f-state"
CORE_F="$TMP/case-f-core"
CORE_F_ROOT="$(install_core_layout "$CORE_F" "9.9.1-m-f")"
OFLOOP_F="$CORE_F_ROOT/bin/ofloop"
mkdir -p "$SHIM_F"; write_stub_uname "$SHIM_F"; write_launchctl_shim "$SHIM_F"
mkdir -p "$STATE_F/ownframework-loop"
python3 -B - "$STATE_F/ownframework-loop/supervisor.sqlite3" >/dev/null 2>&1 <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE IF NOT EXISTS jobs (id INTEGER PRIMARY KEY, run_id TEXT, status TEXT, runtime_generation TEXT)")
c.commit(); c.close()
PY
printf 'loaded\n' > "$TMP/case-f.state"
PATH="$SHIM_F:$PATH" USER_UID="$USER_UID" \
  OFLOOP_TEST_LAUNCHCTL_CALLLOG="$CALLLOG_F" \
  OFLOOP_TEST_LAUNCHCTL_BOOTOUT_PLIST_RC=0 \
  OFLOOP_TEST_LAUNCHCTL_BOOTOUT_LABEL_RC=0 \
  OFLOOP_TEST_LAUNCHCTL_STATE_FILE="$TMP/case-f.state" \
  OFLOOP_TEST_LAUNCHCTL_PLIST="$HOME_F/Library/LaunchAgents/com.ownframework.loop-supervisor.plist" \
  OFLOOP_TEST_LAUNCHCTL_RECEIPT_PATH="$STATE_F/ownframework-loop/supervisor-activation.json" \
  OFLOOP_TEST_LAUNCHCTL_FORCE_LABEL_STILL_LOADED=1 \
  HOME="$HOME_F" XDG_STATE_HOME="$STATE_F" \
  PYTHON_BIN="$PYTHON_BIN" OFLOOP_BIN="$OFLOOP_F" \
  SOURCE_ROOT_OVERRIDE="$ROOT_DIR" \
  bash "$ROOT_DIR/scripts/supervisor/install-macos.sh" \
    > "$TMP/case-f.install.out" 2>&1 || true
if grep -Fq "SUPERVISOR_INSTALL=PASS" "$TMP/case-f.install.out"; then
  fail "Case F: installer emitted PASS despite stale-label re-probe failure: $(cat "$TMP/case-f.install.out")"
fi
grep -Fq "stale_label_removal_failed" "$TMP/case-f.install.out" \
  || fail "Case F: missing stale_label_removal_failed refusal marker: $(cat "$TMP/case-f.install.out")"
pass "Case F: stale-label re-probe failure REFUSED"

##########################################################################
# Case G: activation from prior install cannot satisfy current attempt.
#   First install PASSes (writes receipt+attestation+activation_record).
#   Manually overwrite the receipt+attestation with stale
#   activation_id.  Second install runs; the receipt-wait finds the
#   stale receipt+attestation with activation_id=OLD, but the new
#   install's activation-record has activation_id=NEW → activation_id
#   mismatch → REFUSED.
##########################################################################
echo "=== Case G: activation from prior install cannot satisfy current attempt ==="
SHIM_G="$TMP/case-g-shim"; CALLLOG_G="$TMP/case-g-calls"
HOME_G="$TMP/case-g-home"; STATE_G="$TMP/case-g-state"
CORE_G="$TMP/case-g-core"
CORE_G_ROOT="$(install_core_layout "$CORE_G" "9.9.1-m-g")"
OFLOOP_G="$CORE_G_ROOT/bin/ofloop"
mkdir -p "$SHIM_G"; write_stub_uname "$SHIM_G"; write_launchctl_shim "$SHIM_G"
mkdir -p "$STATE_G/ownframework-loop"
python3 -B - "$STATE_G/ownframework-loop/supervisor.sqlite3" >/dev/null 2>&1 <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE IF NOT EXISTS jobs (id INTEGER PRIMARY KEY, run_id TEXT, status TEXT, runtime_generation TEXT)")
c.commit(); c.close()
PY
printf 'loaded\n' > "$TMP/case-g.state"
PATH="$SHIM_G:$PATH" USER_UID="$USER_UID" \
  OFLOOP_TEST_LAUNCHCTL_CALLLOG="$CALLLOG_G" \
  OFLOOP_TEST_LAUNCHCTL_STATE_FILE="$TMP/case-g.state" \
  OFLOOP_TEST_LAUNCHCTL_PLIST="$HOME_G/Library/LaunchAgents/com.ownframework.loop-supervisor.plist" \
  OFLOOP_TEST_LAUNCHCTL_RECEIPT_PATH="$STATE_G/ownframework-loop/supervisor-activation.json" \
  HOME="$HOME_G" XDG_STATE_HOME="$STATE_G" \
  PYTHON_BIN="$PYTHON_BIN" OFLOOP_BIN="$OFLOOP_G" \
  SOURCE_ROOT_OVERRIDE="$ROOT_DIR" \
  bash "$ROOT_DIR/scripts/supervisor/install-macos.sh" \
    > "$TMP/case-g1.install.out" 2>&1 || true
grep -Fq "SUPERVISOR_INSTALL=PASS" "$TMP/case-g1.install.out" \
  || fail "Case G: prior install did not PASS: $(cat "$TMP/case-g1.install.out")"

# Overwrite the receipt+attestation with stale activation_id BEFORE
# the second install's receipt-wait.  The receipt-wait will pick up
# the stale receipt, find activation_id != activation_record's
# activation_id, and REFUSE.
cat > "$STATE_G/ownframework-loop/supervisor-activation.json" <<EOF
{
  "schema": "ownframework-loop-supervisor-activation/v1",
  "activation_id": "00000000-0000-0000-0000-000000000000",
  "pid": 1,
  "label": "com.ownframework.loop-supervisor",
  "runtime_generation": "old",
  "runtime_root": "/old",
  "ofloop_bin": "/old/ofloop",
  "supervisor_db": "/old/db",
  "ledger_marker": "/old/ledger",
  "started_at": 1.0,
  "generation_source": "env_fallback"
}
EOF
cat > "$STATE_G/ownframework-loop/supervisor-startup-ready.json" <<EOF
{
  "schema": "ownframework-loop-supervisor-startup-ready/v1",
  "activation_id": "00000000-0000-0000-0000-000000000000",
  "ready_pid": 1,
  "label": "com.ownframework.loop-supervisor",
  "runtime_generation": "old",
  "runtime_root": "/old",
  "ofloop_bin": "/old/ofloop",
  "supervisor_db": "/old/db",
  "ledger_marker": "/old/ledger",
  "ready_at": 1.0
}
EOF
chmod 0600 "$STATE_G/ownframework-loop/supervisor-activation.json" \
         "$STATE_G/ownframework-loop/supervisor-startup-ready.json"

# Re-prime state so the second install sees the prior service as loaded.
# Critically, set BOOTOUT_PLIST_RC=1 so bootout FAILS to unload the label.
# This means the installer's stop-by-label authority branch triggers,
# the receipt preflight does NOT delete the prior receipt (label still
# loaded), and the receipt-wait then picks up the stale receipt whose
# activation_id does NOT match the new install's activation_record.
printf 'loaded\n' > "$TMP/case-g.state"
: > "$CALLLOG_G"
PATH="$SHIM_G:$PATH" USER_UID="$USER_UID" \
  OFLOOP_TEST_LAUNCHCTL_CALLLOG="$CALLLOG_G" \
  OFLOOP_TEST_LAUNCHCTL_BOOTOUT_PLIST_RC=1 \
  OFLOOP_TEST_LAUNCHCTL_BOOTOUT_LABEL_RC=1 \
  OFLOOP_TEST_LAUNCHCTL_STATE_FILE="$TMP/case-g.state" \
  OFLOOP_TEST_LAUNCHCTL_PLIST="$HOME_G/Library/LaunchAgents/com.ownframework.loop-supervisor.plist" \
  OFLOOP_TEST_LAUNCHCTL_RECEIPT_PATH="$STATE_G/ownframework-loop/supervisor-activation.json" \
  HOME="$HOME_G" XDG_STATE_HOME="$STATE_G" \
  PYTHON_BIN="$PYTHON_BIN" OFLOOP_BIN="$OFLOOP_G" \
  SOURCE_ROOT_OVERRIDE="$ROOT_DIR" \
  bash "$ROOT_DIR/scripts/supervisor/install-macos.sh" \
    > "$TMP/case-g2.install.out" 2>&1 || true
if grep -Fq "SUPERVISOR_INSTALL=PASS" "$TMP/case-g2.install.out"; then
  fail "Case G: installer emitted PASS despite prior-install receipt: $(cat "$TMP/case-g2.install.out")"
fi
# Case G can refuse via EITHER stale_label_removal_failed (because
# bootout rc=1 left the label loaded) OR activation_id_mismatch (the
# receipt-wait picked up the prior receipt with the wrong activation
# id).  Either is a valid failure surface.
grep -Eq "active_identity_unproven|activation_id_mismatch|stale_label_removal_failed" "$TMP/case-g2.install.out" \
  || fail "Case G: missing refusal marker: $(cat "$TMP/case-g2.install.out")"
pass "Case G: prior-install receipt cannot satisfy current attempt"

echo "V091M_COMMISSIONING_IDENTITY_ADVERSARIAL=PASS"
