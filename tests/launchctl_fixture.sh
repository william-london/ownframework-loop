#!/usr/bin/env bash
# Shared shimmed ``launchctl`` fixture for macOS commissioning tests.
#
# The OwnFramework Loop installer's macOS commissioning path runs
# `launchctl print / bootout / bootstrap / enable` against the
# canonical ``com.ownframework.loop-supervisor`` launchd label.
# Real launchd must NEVER be touched from a canonical test: every
# test that exercises install-macos.sh must source this helper and
# prepend the produced shim directory to PATH, with the test
# exporting the OFLOOP_TEST_STUB_* env vars this fixture honors.
#
# The fixture models the real launchd post-bootstrap supervisor
# startup: after a successful bootstrap, the shim writes both
# artifacts the installer verifies:
#   - supervisor-activation.json (the pre-exec launcher receipt)
#   - supervisor-startup-ready.json (the durable supervisor
#     startup-ready attestation)
#
# The fixture reads the canonical ``ProgramArguments`` and
# ``EnvironmentVariables`` from the bootstrapped plist, derives a
# receipt from the launcher's argv+env+pid via the real
# ``service_identity.derive_active_identity``, and writes the
# receipt+attestation atomically.
#
# Source order: tests must source ``_helpers.sh`` first (which sets
# ROOT_DIR / LIB_DIR), then source this file.

# write_launchctl_fixture <shimdir> [variant]
#   writes $shimdir/launchctl and $shimdir/uname (Darwin).
#   variant is currently unused; reserved for future profiles.
write_launchctl_fixture() {
  local shimdir="$1"
  mkdir -p "$shimdir"
  cat > "$shimdir/uname" <<'SH'
#!/bin/sh
echo Darwin
SH
  chmod +x "$shimdir/uname"

  cat > "$shimdir/launchctl" <<'SH'
#!/bin/bash
state_dir="${OFLOOP_TEST_STUB_STATE_DIR:-}"
plist="${OFLOOP_TEST_STUB_PLIST:-}"
case "${1:-}" in
  print)
    target="${2:-}"
    case "$target" in
      gui/*/com.ownframework.loop-supervisor)
        # Model launchd's authority surface directly: a loaded label prints
        # successfully whether or not the test receipt has been published yet.
        # An absent label returns nonzero WITH the explicit missing-service
        # diagnostic production code requires before treating absence as proven.
        if [[ -n "$state_dir" && -f "${state_dir}/com.ownframework.loop-supervisor" ]]; then
          receipt_pid=""
          if [[ -n "${OFLOOP_TEST_STUB_RECEIPT_PATH:-}" && \
                -f "${OFLOOP_TEST_STUB_RECEIPT_PATH}" ]]; then
            receipt_pid="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['pid'])" "${OFLOOP_TEST_STUB_RECEIPT_PATH}" 2>/dev/null || echo "")"
          fi
          printf 'gui/501/com.ownframework.loop-supervisor = {\n'
          printf '\tstate = running\n'
          if [[ -n "$receipt_pid" ]]; then
            printf '\tpid = %s\n' "$receipt_pid"
          fi
          printf '}\n'
          exit 0
        fi
        printf 'Could not find service "com.ownframework.loop-supervisor" in domain for user gui: 501\n' >&2
        exit 1
        ;;
      *) exit 0 ;;
    esac
    ;;
  kickstart)
    # kickstart -k force-restarts the loaded service. The fixture
    # treats this as a no-op (the state file persists) — removal
    # is the installer's responsibility via bootout + re-probe.
    rc="${OFLOOP_TEST_STUB_KICKSTART_RC:-0}"
    exit "$rc"
    ;;
  bootout)
    rc="${OFLOOP_TEST_STUB_BOOTOUT_RC:-0}"
    if [[ "$rc" -eq 0 && -n "$state_dir" ]]; then
      rm -f "${state_dir}/com.ownframework.loop-supervisor"
    fi
    exit "$rc"
    ;;
  bootstrap)
    rc="${OFLOOP_TEST_STUB_BOOTSTRAP_RC:-0}"
    if [[ "$rc" -eq 0 ]]; then
      if [[ -n "$state_dir" ]]; then
        : > "${state_dir}/com.ownframework.loop-supervisor"
      fi
      # Model real launchd: after a successful bootstrap, the
      # loaded service runs its ProgramArguments.  We parse the
      # plist and write the receipt + startup-ready attestation
      # directly via the real service_identity helpers, then
      # optionally run the launcher stub if
      # OFLOOP_TEST_STUB_LAUNCHER_NOOP is not 1.  The installer's
      # receipt-wait then succeeds against these artifacts.
      if [[ -n "$plist" && -f "$plist" && \
            -n "${OFLOOP_TEST_STUB_RECEIPT_PATH:-}" ]]; then
        python3 - \
            "$plist" \
            "${OFLOOP_TEST_STUB_RECEIPT_PATH}" \
            "${OFLOOP_TEST_STUB_INSTALL_ROOT:-}" \
            "${OFLOOP_TEST_STUB_LIB_ROOT:-${OFLOOP_TEST_STUB_INSTALL_ROOT:-}}" \
            "${OFLOOP_TEST_STUB_SUPERVISOR_DB:-}" \
            "${OFLOOP_TEST_STUB_LEDGER_MARKER:-}" \
            "${OFLOOP_TEST_STUB_ACTIVATION_ID:-}" \
            "${OFLOOP_TEST_STUB_LABEL:-com.ownframework.loop-supervisor}" \
            "${OFLOOP_TEST_STUB_RUNTIME_GENERATION:-}" \
            "${OFLOOP_TEST_STUB_LAUNCHER_NOOP:-0}" \
            <<'PYINV'
import json, os, plistlib, sys, time
from pathlib import Path
(plist, receipt_path, install_root_s, lib_root_s,
 supervisor_db, ledger_marker, override_activation_id, override_label,
 override_generation, launcher_noop) = sys.argv[1:11]
install_root = Path(install_root_s) if install_root_s else Path(plist).parent.parent
lib_root = Path(lib_root_s) if lib_root_s else install_root
sys.path.insert(0, str(lib_root / "lib"))
from ownframework_loop import service_identity
with open(plist, "rb") as fh:
    payload = plistlib.load(fh)
argv = payload.get("ProgramArguments", [])
env = payload.get("EnvironmentVariables", {})
# The launcher's actual argv is [<python>, "-B", <launcher>, ...flags].
# The shim's argv is what would be exec'd by real launchd.
argv_list = [sys.executable] + [str(a) for a in argv]
# Override activation_id / label / generation when the test sets
# explicit values (these are how tests inject adversarial cases
# without rebuilding the entire plist).
if override_activation_id:
    env["OFLOOP_ACTIVATION_ID"] = override_activation_id
if override_label:
    env["LABEL"] = override_label
if override_generation:
    env["OFLOOP_RUNTIME_GENERATION"] = override_generation

# The receipt is derived from this shim process's argv + env + pid.
# We pass argv_list verbatim so derive_active_identity observes
# the actual --ofloop (Seam 1 — actual exec target wins over env).
try:
    receipt = service_identity.derive_active_identity(
        launcher_argv=argv_list,
        launcher_env=env,
        launcher_pid=int(os.getpid()),
    )
except ValueError as exc:
    print("SHIM=REFUSED reason=" + str(exc), file=sys.stderr)
    sys.exit(2)
# Override supervisor_db / ledger_marker / runtime_root / runtime_generation
# in the receipt to match what the test wants to assert. These mirror the
# installer's installed layout when the test wants the receipt to pass
# verification.  Canonicalize the paths the same way
# ``derive_active_identity`` does (via .resolve(strict=False)) so the
# receipt's supervisor_db/ledger_marker match the canonical paths the
# startup-ready attestation will derive post-exec.
if supervisor_db:
    receipt["supervisor_db"] = str(Path(supervisor_db).expanduser().resolve(strict=False))
if ledger_marker:
    receipt["ledger_marker"] = str(Path(ledger_marker).expanduser().resolve(strict=False))
if override_generation:
    receipt["runtime_generation"] = override_generation
service_identity.write_receipt_atomic(receipt, Path(receipt_path))

# Now write the startup-ready attestation.  Seam 8 of the residual
# closure: exercise the REAL durable-attestation owner with INDEPENDENT
# actual runtime context.  In production the launcher exec's into the
# durable supervisor with argv ``[<ofloop_bin>, "supervisor", "serve"]``;
# the supervisor's startup attestation derives everything from its own
# post-exec context and compares to the receipt.  The shim simulates
# that exact flow: it reconstructs the post-exec argv from the plist
# by extracting ``--ofloop`` from the launcher argv (which is the
# actual exec target) and using it as ``argv[0]``.
ofloop_argv = ""
for i, tok in enumerate(argv_list):
    if tok == "--ofloop" and i + 1 < len(argv_list):
        ofloop_argv = str(argv_list[i + 1])
        break
post_exec_argv = [ofloop_argv, "supervisor", "serve"] if ofloop_argv else argv_list
actual_db = str(Path(supervisor_db).expanduser().resolve(strict=False)) if supervisor_db else None
actual_ledger = ledger_marker if ledger_marker else None
try:
    attestation = service_identity.derive_startup_ready(
        receipt=receipt,
        ready_pid=int(os.getpid()),
        actual_argv=post_exec_argv,
        actual_env=env,
        actual_db_path=actual_db,
        actual_state_root=None,
    )
except ValueError as exc:
    print("SHIM=REFUSED reason=" + str(exc), file=sys.stderr)
    sys.exit(2)
ready_path = Path(receipt_path).with_name("supervisor-startup-ready.json")
service_identity.write_receipt_atomic(attestation, ready_path)

# Optional receipt-field tampering (Case G, etc.).
if os.environ.get("OFLOOP_TEST_STUB_TAMPER_RECEIPT_FIELD"):
    field, value = os.environ["OFLOOP_TEST_STUB_TAMPER_RECEIPT_FIELD"].split("=", 1)
    with open(receipt_path, "r", encoding="utf-8") as fh:
        body = json.load(fh)
    body[field] = value
    with open(receipt_path, "w", encoding="utf-8") as fh:
        json.dump(body, fh, indent=2, sort_keys=True)
sys.exit(0)
PYINV
        # If the test asks us to model a stale-receipt condition
        # (Case C), overwrite the receipt AFTER it's written.
        if [[ "${OFLOOP_TEST_STUB_FORCE_STALE_RECEIPT:-0}" == "1" ]]; then
          python3 - "${OFLOOP_TEST_STUB_RECEIPT_PATH}" "${OFLOOP_TEST_STUB_STARTUP_READY_PATH:-}" <<'STALEPY'
import json, sys, time
receipt_path = sys.argv[1]
ready_path = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else ""
body = {
    "schema": "ownframework-loop-supervisor-activation/v1",
    "activation_id": "00000000-0000-0000-0000-000000000000",
    "pid": 999999,
    "label": "com.ownframework.loop-supervisor",
    "runtime_generation": "stale",
    "runtime_root": "/stale",
    "ofloop_bin": "/stale/ofloop",
    "supervisor_db": "/stale/db",
    "ledger_marker": "/stale/ledger",
    "started_at": time.time(),
    "generation_source": "env_fallback",
}
with open(receipt_path, "w", encoding="utf-8") as fh:
    json.dump(body, fh, indent=2, sort_keys=True)
if ready_path:
    ready_body = {
        "schema": "ownframework-loop-supervisor-startup-ready/v1",
        "activation_id": "00000000-0000-0000-0000-000000000000",
        "ready_pid": 999999,
        "label": "com.ownframework.loop-supervisor",
        "runtime_generation": "stale",
        "runtime_root": "/stale",
        "ofloop_bin": "/stale/ofloop",
        "supervisor_db": "/stale/db",
        "ledger_marker": "/stale/ledger",
        "ready_at": time.time(),
    }
    with open(ready_path, "w", encoding="utf-8") as fh:
        json.dump(ready_body, fh, indent=2, sort_keys=True)
STALEPY
        fi
        # Optionally delete the receipt+attestation to model a
        # launcher that never wrote one (tests can detect this).
        if [[ "${OFLOOP_TEST_STUB_FORCE_NO_RECEIPT:-0}" == "1" ]]; then
          rm -f "${OFLOOP_TEST_STUB_RECEIPT_PATH}"
          ready_path="${OFLOOP_TEST_STUB_RECEIPT_PATH%.json}"
          # The startup-ready path is sibling of receipt_path with
          # the canonical filename; recompute here.
          ready_dir="$(dirname "${OFLOOP_TEST_STUB_RECEIPT_PATH}")"
          rm -f "$ready_dir/supervisor-startup-ready.json"
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
