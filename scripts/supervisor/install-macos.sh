#!/usr/bin/env bash
# Install the OwnFramework Loop durable supervisor as a per-user macOS launchd service.
#
# The supervisor is commissioned from the vendor-neutral installed core
# runtime. Claude Code is currently the first production semantic runner, not
# the owner of the core installation. Runtime executables are canonicalized and
# persisted in runtime-provenance.json and the generated launchd plist; provider
# auth/model secrets live separately in a private Loop service-env file.
#
# When Claude is genuinely unavailable the install is intentionally
# idle-only: claude_bin is recorded as null, OFLOOP_CLAUDE_BIN is
# omitted from the plist (NOT written with a bogus value), and the
# service waits without semantic attempts until Claude is installed in the
# persisted service PATH, then continues queued work automatically. No manual
# supervisor resume is required for this idle-only discovery case.
#
# STATE_ROOT is computed once via ${XDG_STATE_HOME:-$HOME/.local/state}
# and passed consistently to the plist generator for stdout, stderr,
# runtime-provenance.json, and service-env paths. The plist generator never
# silently recomputes a different root.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# 1. Resolve runtime executables to canonical absolute paths.
#    Python and ofloop are mandatory. Claude is optional; when absent,
#    the install is intentionally idle-only and OFLOOP_CLAUDE_BIN is
#    omitted from the plist.
PYTHON_BIN_RAW="${PYTHON_BIN:-$(command -v python3 || true)}"
OFLOOP_BIN_RAW="${OFLOOP_BIN:-$(command -v ofloop || true)}"
CLAUDE_BIN_RAW="${CLAUDE_BIN:-$(command -v claude || true)}"

# Canonicalize paths via python3 (always available alongside this script).
# `realpath` may not be installed on macOS; use Python for portability.
canon_path() {
  # $1 = input path; $2 = python interpreter to use (avoids relying on
  # the outer-scope $PYTHON_BIN, which is not yet assigned when we
  # canonicalize PYTHON_BIN itself).
  local py="$2"
  [[ -x "$py" ]] || { echo ""; return 1; }
  "$py" - "$1" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1]).expanduser().resolve(strict=False)
print(str(p))
PY
}

if [[ -z "$OFLOOP_BIN_RAW" ]]; then
  echo "SUPERVISOR_INSTALL=REFUSED reason=core_not_installed" >&2
  echo "hint: run './install.sh' first or set OFLOOP_BIN explicitly for development/testing" >&2
  exit 2
fi

if [[ -z "$PYTHON_BIN_RAW" ]]; then
  echo "SUPERVISOR_INSTALL=REFUSED reason=python3_missing" >&2
  exit 2
fi
PYTHON_BIN="$(canon_path "$PYTHON_BIN_RAW" "${PYTHON_BIN_RAW}")"
if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "SUPERVISOR_INSTALL=REFUSED reason=python3_not_executable path=$PYTHON_BIN" >&2
  exit 2
fi

OFLOOP_BIN="$(canon_path "$OFLOOP_BIN_RAW" "$PYTHON_BIN")"
if [[ ! -x "$OFLOOP_BIN" ]]; then
  echo "SUPERVISOR_INSTALL=REFUSED reason=ofloop_not_executable path=$OFLOOP_BIN" >&2
  exit 2
fi

CLAUDE_BIN=""
if [[ -n "$CLAUDE_BIN_RAW" ]]; then
  CLAUDE_BIN="$(canon_path "$CLAUDE_BIN_RAW" "$PYTHON_BIN")"
  if [[ ! -x "$CLAUDE_BIN" ]]; then
    echo "SUPERVISOR_INSTALL=REFUSED reason=claude_not_executable path=$CLAUDE_BIN" >&2
    exit 2
  fi
  CLAUDE_VERSION="$("$CLAUDE_BIN" --version 2>/dev/null | head -n1 || true)"
  if ! "$PYTHON_BIN" - "$CLAUDE_VERSION" <<'PY'
import re,sys
m=re.search(r'(\d+)\.(\d+)\.(\d+)', sys.argv[1])
raise SystemExit(0 if m and tuple(map(int,m.groups())) >= (2,1,248) else 1)
PY
  then
    echo "SUPERVISOR_INSTALL=REFUSED reason=claude_version_unsupported minimum=2.1.248 actual=$CLAUDE_VERSION" >&2
    exit 6
  fi
fi

# 2. Source provenance: derive from the current source checkout so the
#    runtime record can later be cross-checked against the Git HEAD
#    that backed the installed ofloop binary.
SOURCE_ROOT_RAW="${SOURCE_ROOT_OVERRIDE:-$ROOT}"
SOURCE_ROOT="$(canon_path "$SOURCE_ROOT_RAW" "$PYTHON_BIN")"
SOURCE_HEAD=""
if git -C "$SOURCE_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  SOURCE_HEAD="$(git -C "$SOURCE_ROOT" rev-parse HEAD 2>/dev/null || true)"
fi

# 3. Record source-tree version separately from the installed runtime version.
#    The runtime provenance field ofloop_version is populated from INSTALL_ROOT
#    below; SOURCE_ROOT_OVERRIDE must never make installed-version truth lie.
SOURCE_VERSION=""
if PYTHONPATH="$SOURCE_ROOT/lib" "$PYTHON_BIN" -c "from ownframework_loop import __version__; print(__version__)" >/dev/null 2>&1; then
  SOURCE_VERSION="$(PYTHONPATH="$SOURCE_ROOT/lib" "$PYTHON_BIN" -c "from ownframework_loop import __version__; print(__version__)")"
fi

LABEL="com.ownframework.loop-supervisor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# 4. Compute the commissioned state base/root once.  Persist the state base in
#    launchd so the running supervisor derives the exact same DB/log/cache root
#    that installation, provenance, and dependency probes use.
STATE_BASE="${XDG_STATE_HOME:-$HOME/.local/state}"
STATE_ROOT="$STATE_BASE/ownframework-loop"
STDOUT_LOG="$STATE_ROOT/supervisor.stdout.log"
STDERR_LOG="$STATE_ROOT/supervisor.stderr.log"
RUNTIME_PROVENANCE="$STATE_ROOT/runtime-provenance.json"
SERVICE_ENV="$STATE_ROOT/service-env.json"
SUPERVISOR_DB="$STATE_ROOT/supervisor.sqlite3"
LEDGER_MARKER="$STATE_ROOT/ledger-incarnation.json"
TXN_DIR="$STATE_ROOT/.supervisor-install-transaction"
DOMAIN="gui/$UID"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "SUPERVISOR_INSTALL=REFUSED reason=macos_required" >&2
  exit 2
fi

mkdir -p "$HOME/Library/LaunchAgents" "$STATE_ROOT"
chmod 0700 "$STATE_ROOT"

recover_pending_transaction() {
  [[ -d "$TXN_DIR" ]] || return 0
  echo "SUPERVISOR_INSTALL_RECOVERY=pending_transaction"
  # Prove the launchd user domain itself is reachable before treating a
  # missing label as benign absence.
  if ! launchctl print "$DOMAIN" >/dev/null 2>&1; then
    echo "SUPERVISOR_INSTALL=REFUSED reason=transaction_recovery_manager_unavailable" >&2
    return 15
  fi
  # Seam 6: use the same lifecycle primitive as the installer's
  # stop-by-label path.  Removal uses canonical-label authority,
  # not plist-origin.  PROVE absence after removal: a stale
  # transaction + stale same-label registration (different plist
  # origin) must not wedge the recovery.
  REMOVE_OUT="$(PYTHONPATH="$ROOT/lib" "$PYTHON_BIN" -B - "$DOMAIN" "$LABEL" "$PLIST" <<'PY'
import sys
from ownframework_loop import macos_service_lifecycle
domain = sys.argv[1]
label = sys.argv[2]
plist = sys.argv[3]
if macos_service_lifecycle.probe_canonical_label(label, domain):
    macos_service_lifecycle.remove_canonical_label(label, domain, plist)
    if not macos_service_lifecycle.prove_canonical_label_absent(label, domain):
        print("reason=transaction_recovery_stale_label_removal_failed")
        sys.exit(1)
sys.exit(0)
PY
)"
  if [[ "$REMOVE_OUT" == *"reason=transaction_recovery_stale_label_removal_failed"* ]]; then
    echo "SUPERVISOR_INSTALL=REFUSED reason=transaction_recovery_stale_label_removal_failed" >&2
    return 15
  fi
  if [[ -f "$TXN_DIR/had-plist" ]]; then
    cp "$TXN_DIR/old.plist" "$PLIST"; chmod 0600 "$PLIST"
  else
    rm -f "$PLIST"
  fi
  if [[ -f "$TXN_DIR/had-provenance" ]]; then
    cp "$TXN_DIR/old.provenance.json" "$RUNTIME_PROVENANCE"; chmod 0600 "$RUNTIME_PROVENANCE"
  else
    rm -f "$RUNTIME_PROVENANCE"
  fi
  if [[ -f "$TXN_DIR/had-service-env" ]]; then
    cp "$TXN_DIR/old.service-env.json" "$SERVICE_ENV"; chmod 0600 "$SERVICE_ENV"
  else
    rm -f "$SERVICE_ENV"
  fi
  # Seam 7: do NOT rebootstrap the prior service during recovery.
  # Recovery restores on-disk configuration bytes (for evidence /
  # retry) but leaves the canonical label absent unless the
  # restored active service can pass the same identity proof.
  rm -rf "$TXN_DIR"
  echo "SUPERVISOR_INSTALL_RECOVERY=recovered_incomplete_transaction"
}
recover_pending_transaction

# 4b. RUNTIME-GENERATION + LIVE-EXECUTION GUARD.
#
#     (a) A commissioned supervisor must never be replaced while it has an
#         active semantic worker: bootout would orphan the worker mid-pass
#         and hot-swap the runtime under a live sealed execution.
#     (b) RUNTIME-GENERATION CONTRACT: a sealed unfinished PROGRAM must not
#         silently change runtime generation merely because it is between
#         passes. Every non-terminal enrolled job (QUEUED, BACKOFF, RUNNING,
#         QUARANTINED-but-resumable) must retain its recorded runtime. A
#         different generation refuses replacement; an unbound legacy
#         unfinished job also refuses because its generation is ambiguous.
#         Terminal (DONE) jobs never block a normal install.
#
#     The probes are read-only and fail closed (unreadable ledger = refuse).
#     Overrides are explicit operator declarations, clearly unsafe:
#       OFLOOP_ALLOW_SUPERVISOR_SWAP_WITH_ACTIVE_WORK=1   (skips a)
#       OFLOOP_ALLOW_RUNTIME_GENERATION_MIGRATION=1       (skips b)
#     After a deliberate migration, bound runs fail closed on the generation
#     mismatch at serve time; `supervisor resume` is the explicit rebind.

# Incoming runtime generation is computed by the exact installed identity code.
INSTALL_ROOT="$("$PYTHON_BIN" - "$OFLOOP_BIN" <<'PY'
import sys
from pathlib import Path
print(Path(sys.argv[1]).resolve(strict=False).parents[1])
PY
)" || INSTALL_ROOT=""
INSTALL_VERSION=""
if [[ -n "$INSTALL_ROOT" && -d "$INSTALL_ROOT/lib" ]]; then
  INSTALL_VERSION="$(PYTHONPATH="$INSTALL_ROOT/lib" "$PYTHON_BIN" -c \
    "from ownframework_loop import __version__; print(__version__)" 2>/dev/null || true)"
fi
if [[ -z "$INSTALL_VERSION" ]]; then
  echo "SUPERVISOR_INSTALL=REFUSED reason=runtime_version_undetermined install_root=$INSTALL_ROOT" >&2
  exit 12
fi
SERVICE_ENTRYPOINT="$INSTALL_ROOT/scripts/launch-commissioned-supervisor.py"
DEPENDENCY_PROBE="$INSTALL_ROOT/scripts/probe-supervisor-runtime-dependencies.py"
[[ -x "$SERVICE_ENTRYPOINT" && -f "$DEPENDENCY_PROBE" ]] || {
  echo "SUPERVISOR_INSTALL=REFUSED reason=installed_payload_incomplete component=commissioned_service_entrypoint_or_probe" >&2
  exit 12
}
OFLOOP_VERSION="$INSTALL_VERSION"
RUNTIME_GENERATION="$(PYTHONPATH="$INSTALL_ROOT/lib" INSTALL_ROOT="$INSTALL_ROOT" INSTALL_VERSION="$INSTALL_VERSION" "$PYTHON_BIN" -B - <<'PY'
import os
from pathlib import Path
from ownframework_loop.runtime_identity import runtime_generation_for_root
print(runtime_generation_for_root(Path(os.environ["INSTALL_ROOT"]), os.environ["INSTALL_VERSION"]))
PY
)" || RUNTIME_GENERATION=""
if [[ -z "$RUNTIME_GENERATION" ]]; then
  echo "SUPERVISOR_INSTALL=REFUSED reason=runtime_generation_undetermined" >&2
  exit 12
fi

# A durable ledger-incarnation marker distinguishes first-ever initialization
# from unexplained loss of an already commissioned ledger.  Missing history is
# never recoverable via the generation-migration override.
if [[ ( -f "$PLIST" || -f "$RUNTIME_PROVENANCE" || -f "$LEDGER_MARKER" ) && ! -f "$SUPERVISOR_DB" ]]; then
  echo "SUPERVISOR_INSTALL=REFUSED reason=runtime_dependency_ledger_missing" >&2
  echo "hint: restore the commissioned ledger; missing history cannot be migrated safely" >&2
  exit 13
fi
if [[ ! -f "$SUPERVISOR_DB" ]]; then
  PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$INSTALL_ROOT/lib" "$PYTHON_BIN" -B - "$SUPERVISOR_DB" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import supervisor
with supervisor._connect(Path(sys.argv[1])):
    pass
PY
fi
PROBE_ARGS=("$SUPERVISOR_DB" "$RUNTIME_GENERATION")
[[ "${OFLOOP_ALLOW_SUPERVISOR_SWAP_WITH_ACTIVE_WORK:-0}" == "1" ]] && PROBE_ARGS+=(--allow-active)
[[ "${OFLOOP_ALLOW_RUNTIME_GENERATION_MIGRATION:-0}" == "1" ]] && PROBE_ARGS+=(--allow-generation-migration)
set +e
PROBE_OUT="$(PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$INSTALL_ROOT/lib" "$PYTHON_BIN" -B "$INSTALL_ROOT/scripts/probe-supervisor-runtime-dependencies.py" "${PROBE_ARGS[@]}" 2>&1)"
PROBE_RC=$?
set -e
if [[ "$PROBE_RC" -ne 0 ]]; then
  echo "SUPERVISOR_INSTALL=REFUSED $PROBE_OUT" >&2
  exit "$PROBE_RC"
fi
if [[ ! -f "$LEDGER_MARKER" ]]; then
  LEDGER_MARKER="$LEDGER_MARKER" RUNTIME_GENERATION="$RUNTIME_GENERATION" "$PYTHON_BIN" -B - <<'PY'
import json, os
from pathlib import Path
path=Path(os.environ["LEDGER_MARKER"])
fd=os.open(path, os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o600)
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8", closefd=False) as fh:
        json.dump({
            "schema":"ownframework-loop-ledger-incarnation/v1",
            "created_runtime_generation":os.environ["RUNTIME_GENERATION"],
        }, fh, indent=2, sort_keys=True)
        fh.write("\n"); fh.flush(); os.fsync(fh.fileno())
finally:
    os.close(fd)
PY
fi
chmod 0600 "$LEDGER_MARKER"
# 5. Build a minimal PATH for the noninteractive service so it can find
#    Python, ofloop, claude, git, jq, etc. Persisted so a future
#    operator can reproduce the environment exactly.
SERVICE_PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
[[ -d "/opt/homebrew/bin" ]] && SERVICE_PATH="/opt/homebrew/bin:$SERVICE_PATH"
[[ -d "$HOME/.local/bin" ]] && SERVICE_PATH="$HOME/.local/bin:$SERVICE_PATH"

touch "$STDOUT_LOG" "$STDERR_LOG"
chmod 0600 "$STDOUT_LOG" "$STDERR_LOG"

# Persistent transaction state survives installer death/power loss.  Backups are
# retained until launchd activation commits.
rm -rf "$TXN_DIR"
mkdir -p "$TXN_DIR"
chmod 0700 "$TXN_DIR"
OLD_PLIST_BACKUP="$TXN_DIR/old.plist"
OLD_PROVENANCE_BACKUP="$TXN_DIR/old.provenance.json"
OLD_SERVICE_ENV_BACKUP="$TXN_DIR/old.service-env.json"
HAD_OLD_PLIST=0
HAD_OLD_PROVENANCE=0
HAD_OLD_SERVICE_ENV=0
if [[ -f "$PLIST" ]]; then cp "$PLIST" "$OLD_PLIST_BACKUP"; chmod 0600 "$OLD_PLIST_BACKUP"; touch "$TXN_DIR/had-plist"; chmod 0600 "$TXN_DIR/had-plist"; HAD_OLD_PLIST=1; fi
if [[ -f "$RUNTIME_PROVENANCE" ]]; then cp "$RUNTIME_PROVENANCE" "$OLD_PROVENANCE_BACKUP"; chmod 0600 "$OLD_PROVENANCE_BACKUP"; touch "$TXN_DIR/had-provenance"; chmod 0600 "$TXN_DIR/had-provenance"; HAD_OLD_PROVENANCE=1; fi
if [[ -f "$SERVICE_ENV" ]]; then cp "$SERVICE_ENV" "$OLD_SERVICE_ENV_BACKUP"; chmod 0600 "$OLD_SERVICE_ENV_BACKUP"; touch "$TXN_DIR/had-service-env"; chmod 0600 "$TXN_DIR/had-service-env"; HAD_OLD_SERVICE_ENV=1; fi
printf 'prepared\n' > "$TXN_DIR/state"
chmod 0600 "$TXN_DIR/state"

# 6. Generate plist + provenance atomically. The python block is the
#    sole owner of both artifacts; STATE_ROOT, CLAUDE_BIN, OFLOOP_BIN,
#    PYTHON_BIN, and SERVICE_PATH are passed as env vars so the
#    generator cannot drift from the bash-side computation.
PLIST="$PLIST" \
RUNTIME_PROVENANCE="$RUNTIME_PROVENANCE" \
SERVICE_ENV="$SERVICE_ENV" \
STATE_BASE="$STATE_BASE" \
STATE_ROOT="$STATE_ROOT" \
SUPERVISOR_DB="$SUPERVISOR_DB" \
LEDGER_MARKER="$LEDGER_MARKER" \
STDOUT_LOG="$STDOUT_LOG" \
STDERR_LOG="$STDERR_LOG" \
PYTHON_BIN="$PYTHON_BIN" \
OFLOOP_BIN="$OFLOOP_BIN" \
CLAUDE_BIN="$CLAUDE_BIN" \
SERVICE_PATH="$SERVICE_PATH" \
SOURCE_ROOT="$SOURCE_ROOT" \
SOURCE_HEAD="$SOURCE_HEAD" \
OFLOOP_VERSION="$OFLOOP_VERSION" \
SOURCE_VERSION="$SOURCE_VERSION" \
RUNTIME_GENERATION="$RUNTIME_GENERATION" \
LABEL="$LABEL" \
"$PYTHON_BIN" - <<'PY'
import json, os, plistlib, sys, uuid
from pathlib import Path

plist = Path(os.environ["PLIST"])
provenance_path = Path(os.environ["RUNTIME_PROVENANCE"])
service_env_path = Path(os.environ["SERVICE_ENV"])
state_base = os.environ["STATE_BASE"]
state_root = os.environ["STATE_ROOT"]
supervisor_db = os.environ["SUPERVISOR_DB"]
ledger_marker = os.environ["LEDGER_MARKER"]
stdout_log = os.environ["STDOUT_LOG"]
stderr_log = os.environ["STDERR_LOG"]
python_bin = os.environ["PYTHON_BIN"]
ofloop_bin = os.environ["OFLOOP_BIN"]
launcher_script = str(Path(ofloop_bin).resolve(strict=False).parent.parent / "scripts" / "launch-commissioned-supervisor.py")
probe_script = str(Path(ofloop_bin).resolve(strict=False).parent.parent / "scripts" / "probe-supervisor-runtime-dependencies.py")
claude_bin = os.environ.get("CLAUDE_BIN") or None
service_path = os.environ["SERVICE_PATH"]
source_root = os.environ.get("SOURCE_ROOT") or None
source_head = os.environ.get("SOURCE_HEAD") or None
ofloop_version = os.environ.get("OFLOOP_VERSION") or None
source_version = os.environ.get("SOURCE_VERSION") or None
runtime_generation = os.environ.get("RUNTIME_GENERATION") or None
label = os.environ["LABEL"]

activation_id = str(uuid.uuid4())
receipt_path = str(Path(state_root) / "supervisor-activation.json")

env_vars = {
    "PATH": service_path,
    "PYTHONUNBUFFERED": "1",
    "PYTHONDONTWRITEBYTECODE": "1",
    "PYTHON_BIN": python_bin,
    "OFLOOP_BIN": ofloop_bin,
    "OFLOOP_RUNTIME_ROOT": str(Path(ofloop_bin).resolve(strict=False).parent.parent),
    "XDG_STATE_HOME": state_base,
    # Per-installation activation id and the canonical receipt path the
    # launcher writes before exec into the supervisor.  The receipt
    # is the load-bearing active-identity proof the installer verifies
    # before emitting SUPERVISOR_INSTALL=PASS.
    "OFLOOP_ACTIVATION_ID": activation_id,
    "OFLOOP_RECEIPT_PATH": receipt_path,
    "OFLOOP_RUNTIME_GENERATION": runtime_generation or "",
    "LABEL": label,
}
# CRITICAL: only export OFLOOP_CLAUDE_BIN when a Claude binary was
# actually commissioned. Writing a bogus path here would let the
# supervisor execute the wrong Claude binary later (or fail to start
# semantic workers). Omitting it preserves the supported idle-only
# installation behavior — the service waits without semantic attempts
# and automatically continues if Claude later appears on the persisted service PATH.
service_env = {}
if claude_bin:
    env_vars["OFLOOP_CLAUDE_BIN"] = claude_bin
    env_vars["OFLOOP_SERVICE_ENV_FILE"] = str(service_env_path)
    # macOS Claude credentials are held in Keychain. Do not reopen ~/.claude
    # merely for authentication. Environment-based provider/auth/model aliases
    # needed by a durable launchd service are persisted in one private Loop
    # service-env file instead of the plist.
    for auth_var in (
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_OAUTH_REFRESH_TOKEN",
        "CLAUDE_CODE_OAUTH_SCOPES",
        "CLAUDE_CONFIG_DIR",
    ):
        value = os.environ.get(auth_var)
        if value:
            service_env[auth_var] = value

payload = {
    "Label": label,
    "ProgramArguments": [
        python_bin, "-B", launcher_script,
        "--db", supervisor_db,
        "--ledger-marker", ledger_marker,
        "--probe", probe_script,
        "--ofloop", ofloop_bin,
        "--activation-id", activation_id,
        "--receipt-path", receipt_path,
    ],
    "EnvironmentVariables": env_vars,
    "RunAtLoad": True,
    "KeepAlive": True,
    "ProcessType": "Background",
    "ThrottleInterval": 5,
    "StandardOutPath": stdout_log,
    "StandardErrorPath": stderr_log,
    "WorkingDirectory": str(Path.home()),
}
plist.parent.mkdir(parents=True, exist_ok=True)
service_env_path.parent.mkdir(parents=True, exist_ok=True)
os.chmod(service_env_path.parent, 0o700)

def test_abort_after(stage: str) -> None:
    if os.environ.get("OFLOOP_TEST_ABORT_AFTER_PUBLICATION") == stage:
        os._exit(97)


def write_private_json(path: Path, value: object) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8", closefd=False) as fh:
            json.dump(value, fh, indent=2, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
    finally:
        os.close(fd)

fd = os.open(plist, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "wb", closefd=False) as f:
        plistlib.dump(payload, f, sort_keys=True)
        f.flush()
        os.fsync(f.fileno())
finally:
    os.close(fd)
test_abort_after("plist")

write_private_json(service_env_path, service_env)
test_abort_after("service-env")

provenance = {
    "schema": "ownframework-loop-supervisor-runtime-provenance/v1",
    "service_manager": "launchd",
    "service_label": label,
    "python_bin": python_bin,
    "ofloop_bin": ofloop_bin,
    "runtime_root": str(Path(ofloop_bin).resolve(strict=False).parent.parent),
    # claude_bin is recorded exactly as the plist will export: the
    # canonical absolute path when commissioned, or null when this
    # install is intentionally idle-only. The provenance and the
    # plist EnvironmentVariables MUST agree byte-for-byte.
    "claude_bin": claude_bin,
    "service_path": service_path,
    "plist": str(plist),
    "state_base": state_base,
    "state_root": state_root,
    "ledger_incarnation_file": ledger_marker,
    "service_entrypoint": launcher_script,
    "stdout_log": stdout_log,
    "stderr_log": stderr_log,
    "source_root": source_root,
    "source_head": source_head,
    "source_version": source_version,
    "ofloop_version": ofloop_version,
    "runtime_generation": runtime_generation,
    "service_env_file": str(service_env_path) if claude_bin else None,
}
provenance_path.parent.mkdir(parents=True, exist_ok=True)
write_private_json(provenance_path, provenance)
# Persist the activation id (and its expected receipt path) in a
# dedicated file so the bash-side active-identity proof can find
# them deterministically without parsing the plist.  The receipt
# itself is written by the launcher; this file only carries the
# commissioning-side commitment.
activation_record = {
    "schema": "ownframework-loop-supervisor-activation-record/v1",
    "activation_id": activation_id,
    "receipt_path": receipt_path,
    "expected_pid": None,
}
activation_record_path = Path(state_root) / "activation-record.json"
write_private_json(activation_record_path, activation_record)
test_abort_after("provenance")
PY

if command -v plutil >/dev/null 2>&1; then
  if ! plutil -lint "$PLIST" >/dev/null 2>&1; then
    recover_pending_transaction || true
    echo "SUPERVISOR_INSTALL=REFUSED reason=launchd_plist_invalid" >&2
    exit 14
  fi
fi

# 7. Stop the canonical-label service by identity, not by source plist.
#    The loaded canonical-label job may have originated from a different
#    plist path (the documented stale-fixture condition exposed by mature
#    R2 cert). Targeting bootout at $PLIST alone is insufficient: when the
#    loaded job came from another plist, plist-targeted bootout is a
#    no-op and the stale foreign registration persists under the same
#    label. The commissioned Loop label therefore MUST be owned by this
#    installer via service-identity, not accidental plist origin.
#
#    Seam 3 + Seam 4 + Seam 6 of the residual-closure: removal must end
#    in PROVEN absence (postcondition: ``launchctl print "$DOMAIN/$LABEL"``
#    exits nonzero).  Use the single macOS service-lifecycle primitive
#    so this logic is shared with recover_pending_transaction and
#    uninstall, with no plist-origin assumption.
REMOVE_OUT="$(PYTHONPATH="$INSTALL_ROOT/lib" "$PYTHON_BIN" -B - "$DOMAIN" "$LABEL" "$PLIST" <<'PY'
import os, sys
from ownframework_loop import macos_service_lifecycle
domain = sys.argv[1]
label = sys.argv[2]
plist = sys.argv[3]
if macos_service_lifecycle.probe_canonical_label(label, domain):
    macos_service_lifecycle.remove_canonical_label(label, domain, plist)
    if not macos_service_lifecycle.prove_canonical_label_absent(label, domain):
        print("reason=stale_label_removal_failed")
        sys.exit(1)
sys.exit(0)
PY
)"
if [[ "$REMOVE_OUT" == *"reason=stale_label_removal_failed"* ]]; then
  # Canonical label still loaded after removal attempt.  Restore
  # prior on-disk configuration bytes (for evidence / retry) but
  # DO NOT rebootstrap — an unverified restored service must not be
  # left executing (Seam 7).  Leave canonical label absent.
  if [[ "$HAD_OLD_PLIST" == "1" ]]; then
    cp "$OLD_PLIST_BACKUP" "$PLIST"; chmod 0600 "$PLIST"
    if [[ "$HAD_OLD_PROVENANCE" == "1" ]]; then
      cp "$OLD_PROVENANCE_BACKUP" "$RUNTIME_PROVENANCE"; chmod 0600 "$RUNTIME_PROVENANCE"
    else
      rm -f "$RUNTIME_PROVENANCE"
    fi
    if [[ "$HAD_OLD_SERVICE_ENV" == "1" ]]; then
      cp "$OLD_SERVICE_ENV_BACKUP" "$SERVICE_ENV"; chmod 0600 "$SERVICE_ENV"
    else
      rm -f "$SERVICE_ENV"
    fi
  else
    rm -f "$PLIST" "$RUNTIME_PROVENANCE" "$SERVICE_ENV"
  fi
  rm -rf "$TXN_DIR"
  echo "SUPERVISOR_INSTALL=REFUSED reason=stale_label_removal_failed rollback=bytes_restored_label_absent" >&2
  exit 14
fi

# 6.5 Receipt preflight: after proven removal (label genuinely
#     unloaded above), any prior receipt+attestation is stale and
#     would only confuse the receipt-wait below.  Delete them so the
#     receipt-wait below only succeeds when THIS install's launcher
#     writes a fresh receipt for THIS install's activation id.
#
#     The activation-record.json is NOT deleted here: it carries the
#     THIS-install's activation_id commitment and was just written
#     by the plist generator.  Deleting it would make the
#     receipt-wait's `load activation_record` step fail.  Receipt
#     + startup-ready files, by contrast, belong to a previous
#     activation and must be cleared so the receipt-wait does not
#     pick up a stale receipt.
rm -f "$STATE_ROOT/supervisor-activation.json" \
      "$STATE_ROOT/supervisor-startup-ready.json"

if ! launchctl bootstrap "$DOMAIN" "$PLIST"; then
  # Seam 7: an unverified restored service must NOT be left
  # executing.  Restore on-disk configuration bytes for evidence /
  # retry but DO NOT rebootstrap the prior service.  Leave canonical
  # label absent and let the operator explicitly retry.
  if [[ "$HAD_OLD_PLIST" == "1" ]]; then
    cp "$OLD_PLIST_BACKUP" "$PLIST"
    chmod 0600 "$PLIST"
    if [[ "$HAD_OLD_PROVENANCE" == "1" ]]; then
      cp "$OLD_PROVENANCE_BACKUP" "$RUNTIME_PROVENANCE"
      chmod 0600 "$RUNTIME_PROVENANCE"
    else
      rm -f "$RUNTIME_PROVENANCE"
    fi
    if [[ "$HAD_OLD_SERVICE_ENV" == "1" ]]; then
      cp "$OLD_SERVICE_ENV_BACKUP" "$SERVICE_ENV"
      chmod 0600 "$SERVICE_ENV"
    else
      rm -f "$SERVICE_ENV"
    fi
    rollback="previous_config_bytes_restored_label_absent"
  else
    rm -f "$PLIST" "$RUNTIME_PROVENANCE" "$SERVICE_ENV"
    rollback="new_config_removed_label_absent"
  fi
  # Receipt+attestation artifacts MUST be removed on failure — a
  # stale receipt from this install attempt cannot satisfy a future
  # install.
  rm -f "$STATE_ROOT/supervisor-activation.json" \
        "$STATE_ROOT/supervisor-startup-ready.json" \
        "$STATE_ROOT/activation-record.json"
  rm -rf "$TXN_DIR"
  # Use the same lifecycle primitive to prove canonical label absent
  # is the postcondition here.
  PYTHONPATH="$INSTALL_ROOT/lib" "$PYTHON_BIN" -B - "$DOMAIN" "$LABEL" "$PLIST" <<'PY'
import sys
from ownframework_loop import macos_service_lifecycle
macos_service_lifecycle.remove_canonical_label(sys.argv[1], sys.argv[2], sys.argv[3])
PY
  echo "SUPERVISOR_INSTALL=REFUSED reason=bootstrap_failed rollback=$rollback" >&2
  exit 14
fi
launchctl enable "$DOMAIN/$LABEL" >/dev/null 2>&1 || true

# 8. ACTIVE-IDENTITY PROOF — load-bearing postcondition for
#    SUPERVISOR_INSTALL=PASS.  Configuration artifacts (plist, provenance)
#    can lie about what launchd actually loaded.  This step waits for
#    the launcher to write an activation receipt at the canonical
#    receipt path, then verifies the receipt against the configured
#    commissioning truth.  The receipt is the active-runtime-truth
#    authority surface: the launcher derives every value from its own
#    argv/env/pid before exec-ing into the durable supervisor.
#
#    A small "launchctl print gui/$UID/$LABEL" check follows, used
#    only to bind the canonical service-manager label to the
#    receipt's PID (when launchd exposes it).  An arbitrary manually
#    launched process can write a receipt, but it cannot be bound to
#    the canonical label.
set +e
ACTIVATION_RC=0
ACTIVATION_REASON=""
ACTIVATION_OUT="$(LABEL="$LABEL" DOMAIN="$DOMAIN" \
  SUPERVISOR_DB="$SUPERVISOR_DB" \
  LEDGER_MARKER="$LEDGER_MARKER" \
  OFLOOP_BIN="$OFLOOP_BIN" \
  PYTHON_BIN="$PYTHON_BIN" \
  INSTALL_ROOT="$INSTALL_ROOT" \
  STATE_BASE="$STATE_BASE" \
  STATE_ROOT="$STATE_ROOT" \
  RUNTIME_GENERATION="$RUNTIME_GENERATION" \
  ACTIVATION_RECORD_PATH="$STATE_ROOT/activation-record.json" \
  RECEIPT_MAX_ATTEMPTS="${OFLOOP_ACTIVATION_RECEIPT_MAX_ATTEMPTS:-30}" \
  RECEIPT_ATTEMPT_SLEEP="${OFLOOP_ACTIVATION_RECEIPT_ATTEMPT_SLEEP:-0.1}" \
  STARTUP_READY_MAX_ATTEMPTS="${OFLOOP_STARTUP_READY_MAX_ATTEMPTS:-90}" \
  STARTUP_READY_ATTEMPT_SLEEP="${OFLOOP_STARTUP_READY_ATTEMPT_SLEEP:-0.5}" \
  PYTHONPATH="$INSTALL_ROOT/lib" \
  "$PYTHON_BIN" -B - <<'PY' 2>&1
import json, os, re, subprocess, sys, time
from pathlib import Path as _Path

activation_record_path = os.environ["ACTIVATION_RECORD_PATH"]
label = os.environ["LABEL"]
domain = os.environ["DOMAIN"]
exp_db = os.environ["SUPERVISOR_DB"]
exp_ledger = os.environ["LEDGER_MARKER"]
exp_runtime_root = os.environ["INSTALL_ROOT"]
exp_ofloop_bin = os.environ["OFLOOP_BIN"]
exp_runtime_generation = os.environ.get("RUNTIME_GENERATION") or ""
max_attempts = int(os.environ.get("RECEIPT_MAX_ATTEMPTS") or "30")
attempt_sleep = float(os.environ.get("RECEIPT_ATTEMPT_SLEEP") or "0.1")
startup_max_attempts = int(os.environ.get("STARTUP_READY_MAX_ATTEMPTS") or "90")
startup_attempt_sleep = float(os.environ.get("STARTUP_READY_ATTEMPT_SLEEP") or "0.5")

try:
    with open(activation_record_path, "r", encoding="utf-8") as fh:
        activation_record = json.load(fh)
except (OSError, ValueError) as exc:
    print("reason=activation_record_unavailable detail=" + str(exc), file=sys.stderr)
    sys.exit(14)
activation_id = activation_record.get("activation_id") or ""
receipt_path = activation_record.get("receipt_path") or ""
if not activation_id or not receipt_path:
    print("reason=activation_record_invalid detail=missing_activation_id_or_receipt_path", file=sys.stderr)
    sys.exit(14)
startup_ready_path = str(_Path(receipt_path).with_name("supervisor-startup-ready.json"))

from ownframework_loop import service_identity
receipt = None
last_err = None
for _ in range(max_attempts):
    try:
        receipt = service_identity.load_receipt(_Path(receipt_path))
        break
    except FileNotFoundError:
        pass
    except (ValueError, OSError) as exc:
        last_err = exc
    time.sleep(attempt_sleep)
if receipt is None:
    print("reason=activation_receipt_missing attempts=" + str(max_attempts) + " detail=" + str(last_err), file=sys.stderr)
    sys.exit(14)

expected = {
    "pid": int(receipt.get("pid", 0)),
    "label": label,
    "runtime_generation": exp_runtime_generation,
    "runtime_root": exp_runtime_root,
    "ofloop_bin": exp_ofloop_bin,
    # Canonicalize the expected supervisor_db and ledger_marker the
    # same way the launcher did (_Path.resolve(strict=False)), so
    # /var/... becomes /private/var/... on macOS.  Receipt-vs-
    # verification exact-match would otherwise fail on path
    # symlink-only differences.
    "supervisor_db": str(_Path(exp_db).expanduser().resolve(strict=False)),
    "ledger_marker": str(_Path(exp_ledger).expanduser().resolve(strict=False)),
}
ok, reason = service_identity.verify_active_identity(receipt, activation_id, expected)
if not ok:
    print("reason=" + reason, file=sys.stderr)
    sys.exit(14)

# Seam 2: durable supervisor attestation.  The receipt alone proves
# the launcher pre-exec identity; this attestation proves the
# durable supervisor actually entered its scheduler loop with the
# same activation context.  Both must succeed.
startup_ready = None
startup_last_err = None
for _ in range(startup_max_attempts):
    try:
        startup_ready = service_identity.load_startup_ready(_Path(startup_ready_path))
        break
    except FileNotFoundError:
        pass
    except (ValueError, OSError) as exc:
        startup_last_err = exc
    time.sleep(startup_attempt_sleep)
if startup_ready is None:
    print("reason=startup_ready_missing attempts=" + str(startup_max_attempts) + " detail=" + str(startup_last_err), file=sys.stderr)
    sys.exit(14)

# Seam 3: receipt PID must equal startup-ready PID.  The launcher uses
# ``exec`` so PID continuity is an invariant.  Two PIDs that differ
# mean either the receipt was written by one process and the
# attestation by another (no PID continuity), or the durable
# supervisor was replaced (unacceptable).  Reject immediately.
receipt_pid = int(receipt.get("pid", 0))
ready_pid = int(startup_ready.get("ready_pid", 0))
if receipt_pid <= 0 or ready_pid <= 0:
    print(
        "reason=invalid_pid receipt_pid=" + str(receipt_pid) + " ready_pid=" + str(ready_pid),
        file=sys.stderr,
    )
    sys.exit(14)
if receipt_pid != ready_pid:
    print(
        "reason=receipt_ready_pid_mismatch receipt_pid=" + str(receipt_pid)
        + " ready_pid=" + str(ready_pid),
        file=sys.stderr,
    )
    sys.exit(14)

ready_expected = {
    "pid": receipt_pid,
    "label": label,
    "runtime_generation": exp_runtime_generation,
    "runtime_root": exp_runtime_root,
    "ofloop_bin": exp_ofloop_bin,
    "supervisor_db": str(_Path(exp_db).expanduser().resolve(strict=False)),
    "ledger_marker": str(_Path(exp_ledger).expanduser().resolve(strict=False)),
}
ok2, reason2 = service_identity.verify_startup_ready(startup_ready, activation_id, ready_expected)
if not ok2:
    print("reason=" + reason2, file=sys.stderr)
    sys.exit(14)

# Seam 2 generation_source must be ``recomputed_from_payload``.  The
# receipt own generation_source is not enough: the durable
# supervisor independently re-derives its generation from payload
# bytes (see supervisor._publish_startup_ready_attestation).  Either
# receipt or attestation failing this check fails commissioning
# closed.
def _gen_source(obj):
    val = obj.get("generation_source") if isinstance(obj, dict) else ""
    return str(val or "")

if _gen_source(receipt) != "recomputed_from_payload":
    print(
        "reason=active_runtime_generation_unproven source="
        + _gen_source(receipt),
        file=sys.stderr,
    )
    sys.exit(14)
if _gen_source(startup_ready) != "recomputed_from_payload":
    print(
        "reason=active_runtime_generation_unproven source="
        + _gen_source(startup_ready),
        file=sys.stderr,
    )
    sys.exit(14)

# Service-manager label proof: the canonical label must be loaded
# AND the launchd-reported pid MUST equal the single receipt/ready
# pid (Seam 3).  ``label_pid_unreported`` is NOT acceptable — if
# launchd does not expose a pid within a bounded retry window,
# commissioning REFUSES with reason=loaded_service_pid_unproven.
label_pid_unreported_attempts = int(os.environ.get("LABEL_PID_MAX_ATTEMPTS") or "30")
label_pid_attempt_sleep = float(os.environ.get("LABEL_PID_ATTEMPT_SLEEP") or "0.5")
launchd_pid = None
last_print_stdout = ""
last_print_rc = None
for _ in range(label_pid_unreported_attempts):
    proc = subprocess.run(
        ["launchctl", "print", domain + "/" + label],
        check=False, capture_output=True, text=True,
    )
    last_print_stdout = proc.stdout
    last_print_rc = proc.returncode
    if proc.returncode != 0:
        print(
            "reason=label_not_loaded launchctl_rc=" + str(proc.returncode),
            file=sys.stderr,
        )
        sys.exit(14)
    m = re.search(r"^\tpid\s*=\s*(\d+)\s*$", proc.stdout, re.MULTILINE)
    if m is not None:
        launchd_pid = int(m.group(1))
        break
    time.sleep(label_pid_attempt_sleep)
if launchd_pid is None:
    print(
        "reason=loaded_service_pid_unproven attempts=" + str(label_pid_unreported_attempts),
        file=sys.stderr,
    )
    sys.exit(14)
if launchd_pid != receipt_pid:
    print(
        "reason=label_pid_mismatch launchd_pid=" + str(launchd_pid)
        + " receipt_pid=" + str(receipt_pid)
        + " ready_pid=" + str(ready_pid),
        file=sys.stderr,
    )
    sys.exit(14)
print("reason=active_identity_proven")
sys.exit(0)
PY
)"
ACTIVATION_RC=$?
ACTIVATION_REASON="$ACTIVATION_OUT"
set -e

if [[ "$ACTIVATION_RC" -ne 0 ]]; then
  # Active identity could not be proven.  Tear down the just-bootstrapped
  # service so the canonical label is not silently held by an
  # unverified configuration.  Use the lifecycle primitive so the
  # canonical-label removal invariant is shared with recover and
  # uninstall.  Restore on-disk configuration bytes for evidence /
  # retry but DO NOT rebootstrap the prior service (Seam 7).
  PYTHONPATH="$INSTALL_ROOT/lib" "$PYTHON_BIN" -B - "$DOMAIN" "$LABEL" "$PLIST" <<'PY'
import sys
from ownframework_loop import macos_service_lifecycle
macos_service_lifecycle.remove_canonical_label(sys.argv[1], sys.argv[2], sys.argv[3])
PY
  if [[ "$HAD_OLD_PLIST" == "1" ]]; then
    cp "$OLD_PLIST_BACKUP" "$PLIST"; chmod 0600 "$PLIST"
    if [[ "$HAD_OLD_PROVENANCE" == "1" ]]; then
      cp "$OLD_PROVENANCE_BACKUP" "$RUNTIME_PROVENANCE"; chmod 0600 "$RUNTIME_PROVENANCE"
    else
      rm -f "$RUNTIME_PROVENANCE"
    fi
    if [[ "$HAD_OLD_SERVICE_ENV" == "1" ]]; then
      cp "$OLD_SERVICE_ENV_BACKUP" "$SERVICE_ENV"; chmod 0600 "$SERVICE_ENV"
    else
      rm -f "$SERVICE_ENV"
    fi
    rollback="previous_config_bytes_restored_label_absent"
  else
    rm -f "$PLIST" "$RUNTIME_PROVENANCE" "$SERVICE_ENV"
    rollback="new_config_removed_label_absent"
  fi
  # Receipt+attestation artifacts MUST be removed on failure
  # regardless of which rollback branch ran — a stale receipt from
  # this install attempt cannot satisfy a future install.
  rm -f "$STATE_ROOT/supervisor-activation.json" \
        "$STATE_ROOT/supervisor-startup-ready.json" \
        "$STATE_ROOT/activation-record.json"
  rm -rf "$TXN_DIR"
  echo "SUPERVISOR_INSTALL=REFUSED reason=active_identity_unproven_or_mismatch detail=${ACTIVATION_REASON} rollback=$rollback" >&2
  exit 14
fi

rm -rf "$TXN_DIR"

echo "SUPERVISOR_INSTALL=PASS"
echo "LABEL=$LABEL"
echo "PLIST=$PLIST"
echo "PYTHON_BIN=$PYTHON_BIN"
echo "OFLOOP_BIN=$OFLOOP_BIN"
echo "CLAUDE_BIN=${CLAUDE_BIN:-(none-idle-only)}"
echo "STATE_ROOT=$STATE_ROOT"
echo "RUNTIME_PROVENANCE=$RUNTIME_PROVENANCE"
echo "SERVICE_ENV=$SERVICE_ENV"
echo "SOURCE_HEAD=${SOURCE_HEAD:-(not-a-git-checkout)}"
echo "OFLOOP_VERSION=${OFLOOP_VERSION:-(unknown)}"
echo "SOURCE_VERSION=${SOURCE_VERSION:-(unknown)}"
echo "RUNTIME_GENERATION=${RUNTIME_GENERATION:-(unknown)}"
