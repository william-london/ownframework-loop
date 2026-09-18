#!/usr/bin/env bash
# Remove the per-user OwnFramework Loop macOS supervisor service.
#
# Seam 4 + Seam 5 + Seam 6 of the residual-closure: uninstall uses
# the same macOS service-lifecycle primitive as the installer
# (canonical-label authority, not plist-origin).  The postcondition
# is PROVEN canonical-label absence.  Transient active-identity
# artifacts (receipt, startup-ready attestation, activation-record)
# are removed on successful uninstall; durable supervisor DB and
# ledger-incarnation marker are preserved as historical execution
# truth.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

LABEL="com.ownframework.loop-supervisor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/ownframework-loop"
SUPERVISOR_DB="$STATE_ROOT/supervisor.sqlite3"
RUNTIME_PROVENANCE="$STATE_ROOT/runtime-provenance.json"
SERVICE_ENV="$STATE_ROOT/service-env.json"
LEDGER_MARKER="$STATE_ROOT/ledger-incarnation.json"
RECEIPT="$STATE_ROOT/supervisor-activation.json"
STARTUP_READY="$STATE_ROOT/supervisor-startup-ready.json"
ACTIVATION_RECORD="$STATE_ROOT/activation-record.json"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "SUPERVISOR_UNINSTALL=REFUSED reason=macos_required" >&2
  exit 2
fi

if [[ ! -f "$SUPERVISOR_DB" && ( -f "$PLIST" || -f "$RUNTIME_PROVENANCE" || -f "$LEDGER_MARKER" ) ]]; then
  echo "SUPERVISOR_UNINSTALL=REFUSED reason=ledger_missing_runtime_dependency_unverifiable" >&2
  exit 13
fi
if [[ -f "$SUPERVISOR_DB" && "${OFLOOP_ALLOW_SUPERVISOR_SWAP_WITH_ACTIVE_WORK:-0}" != "1" ]]; then
  set +e
  PROBE_OUT="$(PYTHONDONTWRITEBYTECODE=1 python3 -B "$ROOT/scripts/probe-supervisor-runtime-dependencies.py" "$SUPERVISOR_DB" uninstall --allow-generation-migration 2>&1)"
  PROBE_RC=$?
  set -e
  if [[ "$PROBE_RC" -ne 0 ]]; then
    echo "SUPERVISOR_UNINSTALL=REFUSED $PROBE_OUT" >&2
    exit "$PROBE_RC"
  fi
fi
DOMAIN="gui/$UID"
# Prove the user launchd domain itself is reachable.  Only then can a missing
# label be treated as benign absence rather than manager-state ambiguity.
if ! launchctl print "$DOMAIN" >/dev/null 2>&1; then
  echo "SUPERVISOR_UNINSTALL=REFUSED reason=launchd_manager_unavailable" >&2
  exit 14
fi

# Seam 4 + Seam 6: use the canonical-label removal primitive.  This
# is the same primitive the installer uses; it tries both plist-target
# and label-target bootout forms, then PROVES the canonical label is
# absent under the canonical domain.  The postcondition is
# ``launchctl print "$DOMAIN/$LABEL"`` exits nonzero.
REMOVE_OUT="$(PYTHONPATH="$ROOT/lib" python3 -B - "$DOMAIN" "$LABEL" "$PLIST" <<'PY'
import sys
from ownframework_loop import macos_service_lifecycle
domain = sys.argv[1]
label = sys.argv[2]
plist = sys.argv[3]
if macos_service_lifecycle.probe_canonical_label(label, domain):
    macos_service_lifecycle.remove_canonical_label(label, domain, plist)
    if not macos_service_lifecycle.prove_canonical_label_absent(label, domain):
        print("reason=canonical_label_removal_failed")
        sys.exit(1)
sys.exit(0)
PY
)"
if [[ "$REMOVE_OUT" == *"reason=canonical_label_removal_failed"* ]]; then
  echo "SUPERVISOR_UNINSTALL=REFUSED reason=canonical_label_removal_failed" >&2
  exit 14
fi

if [[ ! -e "$PLIST" && ! -e "$RUNTIME_PROVENANCE" ]]; then
  # No service configuration present, but we may still have transient
  # active-identity artifacts left over from a prior failed install.
  # Remove them so they cannot satisfy a future install attempt.
  rm -f "$RECEIPT" "$STARTUP_READY" "$ACTIVATION_RECORD"
  echo "SUPERVISOR_UNINSTALL=NOOP reason=service_artifacts_absent"
  echo "STATE_PRESERVED=yes"
  exit 0
fi

# Seam 5: remove service configuration AND transient active-identity
# artifacts.  The durable supervisor DB and ledger-incarnation marker
# are preserved as historical execution truth (deleting them would
# erase sealed completion records for past jobs).
rm -f "$PLIST" "$RUNTIME_PROVENANCE" "$SERVICE_ENV"
rm -f "$RECEIPT" "$STARTUP_READY" "$ACTIVATION_RECORD"

echo "SUPERVISOR_UNINSTALL=PASS"
echo "SERVICE_MANAGER=launchd"
echo "LABEL=$LABEL"
echo "STATE_PRESERVED=yes"
