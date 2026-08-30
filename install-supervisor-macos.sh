#!/usr/bin/env bash
# Install the OwnFramework Loop durable supervisor as a per-user macOS launchd service.
#
# v0.6.1 hardening: this installer resolves the runtime executables
# (Python, ofloop, Claude) to canonical absolute paths and persists
# them as the single source of truth in runtime-provenance.json AND
# in the generated launchd plist EnvironmentVariables. The supervisor
# subprocess MUST therefore execute the exact same Claude binary that
# was commissioned; PATH resolution is no longer trusted.
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
# and runtime-provenance.json paths. The plist generator never
# silently recomputes a different root.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

# 1. Resolve runtime executables to canonical absolute paths.
#    Python and ofloop are mandatory. Claude is optional; when absent,
#    the install is intentionally idle-only and OFLOOP_CLAUDE_BIN is
#    omitted from the plist.
PYTHON_BIN_RAW="${PYTHON_BIN:-$(command -v python3 || true)}"
OFLOOP_BIN_RAW="${OFLOOP_BIN:-$ROOT/bin/ofloop}"
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

# 4. Compute STATE_ROOT ONCE and pass it consistently to the plist
#    generator. The generator never silently recomputes a different
#    root (e.g. via Path.home() / ".local" / "state").
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/ownframework-loop"
STDOUT_LOG="$STATE_ROOT/supervisor.stdout.log"
STDERR_LOG="$STATE_ROOT/supervisor.stderr.log"
RUNTIME_PROVENANCE="$STATE_ROOT/runtime-provenance.json"

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

SUPERVISOR_DB="$STATE_ROOT/supervisor.sqlite3"
if [[ ( -f "$PLIST" || -f "$RUNTIME_PROVENANCE" ) && ! -f "$SUPERVISOR_DB" && "${OFLOOP_ALLOW_RUNTIME_GENERATION_MIGRATION:-0}" != "1" ]]; then
  echo "SUPERVISOR_INSTALL=REFUSED reason=runtime_dependency_ledger_missing" >&2
  echo "hint: restore the ledger or use OFLOOP_ALLOW_RUNTIME_GENERATION_MIGRATION=1 for an explicit migration" >&2
  exit 13
fi
if [[ -f "$SUPERVISOR_DB" ]]; then
  if [[ "${OFLOOP_ALLOW_SUPERVISOR_SWAP_WITH_ACTIVE_WORK:-0}" != "1" ]]; then
    ACTIVE_REPORT="$("$PYTHON_BIN" - "$SUPERVISOR_DB" <<'PY'
import os, sqlite3, sys

db = sys.argv[1]
terminal_attempts = {
    "COMPLETED", "COST_UNKNOWN", "TOKENS_UNKNOWN",
    "FAILED", "RECOVERED", "SUPERSEDED",
}

def pid_alive(pid):
    if pid is None:
        return None  # unknown — fail closed upstream
    try:
        os.kill(int(pid), 0)
        return True
    except (ValueError, TypeError):
        return None
    except ProcessLookupError:
        return False
    except PermissionError:
        return True

try:
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
except sqlite3.Error:
    print("ledger_probe_failed")
    sys.exit(0)
conn.row_factory = sqlite3.Row
problems = []
try:
    for row in conn.execute(
        "SELECT id, run_id, worker_pid FROM jobs WHERE status='RUNNING'"
    ):
        alive = pid_alive(row["worker_pid"])
        if alive is not False:  # alive OR unknown: refuse
            problems.append(f"running_job={row['run_id']}")
    for row in conn.execute(
        """SELECT a.attempt_id AS attempt_id, a.status AS status,
                  j.run_id AS run_id, j.worker_pid AS worker_pid
           FROM semantic_attempts a JOIN jobs j ON j.id = a.job_id
           WHERE j.status='RUNNING'"""
    ):
        if str(row["status"]) in terminal_attempts:
            continue
        if pid_alive(row["worker_pid"]) is False:
            continue
        problems.append(f"active_attempt={row['attempt_id']}:{row['status']}")
except sqlite3.Error:
    problems.append("ledger_probe_failed")
print(";".join(problems[:4]))
PY
    )" || ACTIVE_REPORT="ledger_probe_failed"
    if [[ -n "$ACTIVE_REPORT" ]]; then
      echo "SUPERVISOR_INSTALL=REFUSED reason=active_semantic_work detail=$ACTIVE_REPORT" >&2
      echo "hint: refresh again after the active pass completes, or set OFLOOP_ALLOW_SUPERVISOR_SWAP_WITH_ACTIVE_WORK=1 to force (unsafe: may orphan a live sealed execution)" >&2
      exit 11
    fi
  fi
  if [[ "${OFLOOP_ALLOW_RUNTIME_GENERATION_MIGRATION:-0}" != "1" ]]; then
    GENERATION_REPORT="$(RUNTIME_GENERATION="$RUNTIME_GENERATION" "$PYTHON_BIN" - "$SUPERVISOR_DB" <<'PY'
import os, sqlite3, sys

db = sys.argv[1]
incoming = os.environ.get("RUNTIME_GENERATION", "")
try:
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
except sqlite3.Error:
    print("ledger_probe_failed")
    sys.exit(0)
conn.row_factory = sqlite3.Row
problems = []
try:
    # Every NON-terminal enrolled job depends on its recorded runtime.
    # Unbound legacy rows are ambiguous unfinished executions and fail closed.
    for row in conn.execute(
        "SELECT run_id, status, runtime_generation FROM jobs "
        "WHERE status != 'DONE'"
    ):
        gen = str(row["runtime_generation"] or "")
        if not gen:
            problems.append(
                f"generation_dependency={row['run_id']}:{row['status']}:UNBOUND"
            )
        elif gen != incoming:
            problems.append(
                f"generation_dependency={row['run_id']}:{row['status']}:{gen}"
            )
except sqlite3.Error:
    problems.append("ledger_probe_failed")
print(";".join(problems[:4]))
PY
    )" || GENERATION_REPORT="ledger_probe_failed"
    if [[ -n "$GENERATION_REPORT" ]]; then
      echo "SUPERVISOR_INSTALL=REFUSED reason=runtime_generation_dependency incoming=$RUNTIME_GENERATION detail=$GENERATION_REPORT" >&2
      echo "hint: let enrolled runs reach terminal, or migrate deliberately with OFLOOP_ALLOW_RUNTIME_GENERATION_MIGRATION=1 and then rebind each quarantined run via 'ofloop supervisor resume'" >&2
      exit 13
    fi
  fi
fi

# 5. Build a minimal PATH for the noninteractive service so it can find
#    Python, ofloop, claude, git, jq, etc. Persisted so a future
#    operator can reproduce the environment exactly.
SERVICE_PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
[[ -d "/opt/homebrew/bin" ]] && SERVICE_PATH="/opt/homebrew/bin:$SERVICE_PATH"
[[ -d "$HOME/.local/bin" ]] && SERVICE_PATH="$HOME/.local/bin:$SERVICE_PATH"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "SUPERVISOR_INSTALL=REFUSED reason=macos_required" >&2
  exit 2
fi

mkdir -p "$HOME/Library/LaunchAgents" "$STATE_ROOT"

OLD_PLIST_BACKUP="$STATE_ROOT/.supervisor.plist.preinstall.${BASHPID}"
OLD_PROVENANCE_BACKUP="$STATE_ROOT/.runtime-provenance.preinstall.${BASHPID}"
HAD_OLD_PLIST=0
HAD_OLD_PROVENANCE=0
if [[ -f "$PLIST" ]]; then cp "$PLIST" "$OLD_PLIST_BACKUP"; HAD_OLD_PLIST=1; fi
if [[ -f "$RUNTIME_PROVENANCE" ]]; then cp "$RUNTIME_PROVENANCE" "$OLD_PROVENANCE_BACKUP"; HAD_OLD_PROVENANCE=1; fi

# 6. Generate plist + provenance atomically. The python block is the
#    sole owner of both artifacts; STATE_ROOT, CLAUDE_BIN, OFLOOP_BIN,
#    PYTHON_BIN, and SERVICE_PATH are passed as env vars so the
#    generator cannot drift from the bash-side computation.
PLIST="$PLIST" \
RUNTIME_PROVENANCE="$RUNTIME_PROVENANCE" \
STATE_ROOT="$STATE_ROOT" \
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
import json, os, plistlib, sys
from pathlib import Path

plist = Path(os.environ["PLIST"])
provenance_path = Path(os.environ["RUNTIME_PROVENANCE"])
state_root = os.environ["STATE_ROOT"]
stdout_log = os.environ["STDOUT_LOG"]
stderr_log = os.environ["STDERR_LOG"]
python_bin = os.environ["PYTHON_BIN"]
ofloop_bin = os.environ["OFLOOP_BIN"]
claude_bin = os.environ.get("CLAUDE_BIN") or None
service_path = os.environ["SERVICE_PATH"]
source_root = os.environ.get("SOURCE_ROOT") or None
source_head = os.environ.get("SOURCE_HEAD") or None
ofloop_version = os.environ.get("OFLOOP_VERSION") or None
source_version = os.environ.get("SOURCE_VERSION") or None
runtime_generation = os.environ.get("RUNTIME_GENERATION") or None
label = os.environ["LABEL"]

env_vars = {
    "PATH": service_path,
    "PYTHONUNBUFFERED": "1",
    "PYTHONDONTWRITEBYTECODE": "1",
    "PYTHON_BIN": python_bin,
    "OFLOOP_BIN": ofloop_bin,
    "OFLOOP_PLUGIN_ROOT": str(Path(ofloop_bin).resolve(strict=False).parent.parent),
}
# CRITICAL: only export OFLOOP_CLAUDE_BIN when a Claude binary was
# actually commissioned. Writing a bogus path here would let the
# supervisor execute the wrong Claude binary later (or fail to start
# semantic workers). Omitting it preserves the supported idle-only
# installation behavior — the service waits without semantic attempts
# and automatically continues if Claude later appears on the persisted service PATH.
if claude_bin:
    env_vars["OFLOOP_CLAUDE_BIN"] = claude_bin

payload = {
    "Label": label,
    "ProgramArguments": [ofloop_bin, "supervisor", "serve"],
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
with plist.open("wb") as f:
    plistlib.dump(payload, f, sort_keys=True)

provenance = {
    "schema": "ownframework-loop-supervisor-runtime-provenance/v1",
    "service_label": label,
    "python_bin": python_bin,
    "ofloop_bin": ofloop_bin,
    # claude_bin is recorded exactly as the plist will export: the
    # canonical absolute path when commissioned, or null when this
    # install is intentionally idle-only. The provenance and the
    # plist EnvironmentVariables MUST agree byte-for-byte.
    "claude_bin": claude_bin,
    "service_path": service_path,
    "plist": str(plist),
    "state_root": state_root,
    "stdout_log": stdout_log,
    "stderr_log": stderr_log,
    "source_root": source_root,
    "source_head": source_head,
    "source_version": source_version,
    "ofloop_version": ofloop_version,
    "runtime_generation": runtime_generation,
}
provenance_path.parent.mkdir(parents=True, exist_ok=True)
provenance_path.write_text(json.dumps(provenance, indent=2, sort_keys=True))
PY

DOMAIN="gui/$UID"
launchctl bootout "$DOMAIN" "$PLIST" >/dev/null 2>&1 || true
if ! launchctl bootstrap "$DOMAIN" "$PLIST"; then
  rollback="none"
  if [[ "$HAD_OLD_PLIST" == "1" ]]; then
    cp "$OLD_PLIST_BACKUP" "$PLIST"
    if [[ "$HAD_OLD_PROVENANCE" == "1" ]]; then
      cp "$OLD_PROVENANCE_BACKUP" "$RUNTIME_PROVENANCE"
    else
      rm -f "$RUNTIME_PROVENANCE"
    fi
    if launchctl bootstrap "$DOMAIN" "$PLIST" >/dev/null 2>&1; then
      rollback="restored_previous_service"
    else
      rollback="previous_service_restore_failed"
    fi
  else
    rm -f "$PLIST" "$RUNTIME_PROVENANCE"
    rollback="removed_failed_new_service"
  fi
  rm -f "$OLD_PLIST_BACKUP" "$OLD_PROVENANCE_BACKUP"
  echo "SUPERVISOR_INSTALL=REFUSED reason=bootstrap_failed rollback=$rollback" >&2
  exit 14
fi
launchctl enable "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
rm -f "$OLD_PLIST_BACKUP" "$OLD_PROVENANCE_BACKUP"

echo "SUPERVISOR_INSTALL=PASS"
echo "LABEL=$LABEL"
echo "PLIST=$PLIST"
echo "PYTHON_BIN=$PYTHON_BIN"
echo "OFLOOP_BIN=$OFLOOP_BIN"
echo "CLAUDE_BIN=${CLAUDE_BIN:-(none-idle-only)}"
echo "STATE_ROOT=$STATE_ROOT"
echo "RUNTIME_PROVENANCE=$RUNTIME_PROVENANCE"
echo "SOURCE_HEAD=${SOURCE_HEAD:-(not-a-git-checkout)}"
echo "OFLOOP_VERSION=${OFLOOP_VERSION:-(unknown)}"
echo "SOURCE_VERSION=${SOURCE_VERSION:-(unknown)}"
echo "RUNTIME_GENERATION=${RUNTIME_GENERATION:-(unknown)}"
