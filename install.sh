#!/usr/bin/env bash
# Install the vendor-neutral OwnFramework Loop core runtime.
#
# This is intentionally NOT an agent/plugin installer. Host integrations are
# installed separately with:
#   bash install-adapter.sh claude-code
#   bash install-adapter.sh codex
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "CORE_INSTALL=REFUSED reason=python3_missing" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "CORE_INSTALL=REFUSED reason=git_missing" >&2; exit 2; }
command -v tar >/dev/null 2>&1 || { echo "CORE_INSTALL=REFUSED reason=tar_missing" >&2; exit 2; }

case "$(uname -s)" in
  Darwin|Linux) ;;
  *) echo "CORE_INSTALL=REFUSED reason=unsupported_platform platform=$(uname -s)" >&2; exit 2 ;;
esac

VERSION="$(PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$ROOT/lib" python3 -B - <<'PY'
from ownframework_loop import __version__
print(__version__)
PY
)"
DATA_BASE="${OFLOOP_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/ownframework-loop}"
INSTALL_ROOT="$DATA_BASE/$VERSION"
BIN_DIR="${OFLOOP_BIN_DIR:-$HOME/.local/bin}"
LAUNCHER="$BIN_DIR/ofloop"
MARKER="$INSTALL_ROOT/.ownframework-loop-managed"

if [[ -e "$INSTALL_ROOT" && ! -f "$MARKER" ]]; then
  echo "CORE_INSTALL=REFUSED reason=unmanaged_install_root path=$INSTALL_ROOT" >&2
  exit 3
fi
if [[ -e "$LAUNCHER" || -L "$LAUNCHER" ]]; then
  LAUNCHER_MANAGED=0
  if [[ -L "$LAUNCHER" ]]; then
    RESOLVED_LAUNCHER="$(python3 -B - "$LAUNCHER" <<'PY'
import sys
from pathlib import Path
print(Path(sys.argv[1]).resolve(strict=False))
PY
)"
    RESOLVED_ROOT="$(dirname "$(dirname "$RESOLVED_LAUNCHER")")"
    [[ -f "$RESOLVED_ROOT/.ownframework-loop-managed" ]] && LAUNCHER_MANAGED=1
  elif grep -q 'OWNFRAMEWORK_LOOP_MANAGED_LAUNCHER' "$LAUNCHER" 2>/dev/null; then
    # One-time migration from the pre-generic managed wrapper.
    LAUNCHER_MANAGED=1
  fi
  [[ "$LAUNCHER_MANAGED" == "1" ]] || {
    echo "CORE_INSTALL=REFUSED reason=unmanaged_launcher path=$LAUNCHER" >&2
    exit 3
  }
fi

mkdir -p "$DATA_BASE" "$BIN_DIR"
HAD_PREVIOUS_LAUNCHER=0
PREVIOUS_LAUNCHER_KIND=""
PREVIOUS_LAUNCHER_TARGET=""
PREVIOUS_LAUNCHER_BACKUP=""
if [[ -L "$LAUNCHER" ]]; then
  HAD_PREVIOUS_LAUNCHER=1
  PREVIOUS_LAUNCHER_KIND="symlink"
  PREVIOUS_LAUNCHER_TARGET="$(readlink "$LAUNCHER")"
elif [[ -f "$LAUNCHER" ]]; then
  HAD_PREVIOUS_LAUNCHER=1
  PREVIOUS_LAUNCHER_KIND="file"
  PREVIOUS_LAUNCHER_BACKUP="$(mktemp "$DATA_BASE/.launcher-preinstall-XXXXXX")"
  cp -p "$LAUNCHER" "$PREVIOUS_LAUNCHER_BACKUP"
fi
STAGE="$(mktemp -d "$DATA_BASE/.stage-$VERSION-XXXXXX")"
cleanup(){ rm -rf "$STAGE"; }
trap cleanup EXIT INT TERM HUP

# Prefer immutable Git HEAD from a checkout. Release/source tarballs without
# .git fall back to their on-disk payload with transient paths excluded. Compare
# physical paths so macOS /var -> /private/var aliases do not misclassify a real
# checkout as an ordinary source tree and accidentally stage dirty working bytes.
GIT_TOP="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
ROOT_PHYSICAL="$(cd "$ROOT" && pwd -P)"
GIT_TOP_PHYSICAL=""
if [[ -n "$GIT_TOP" && -d "$GIT_TOP" ]]; then
  GIT_TOP_PHYSICAL="$(cd "$GIT_TOP" && pwd -P)"
fi
if [[ -n "$GIT_TOP_PHYSICAL" && "$GIT_TOP_PHYSICAL" == "$ROOT_PHYSICAL" ]]; then
  git -C "$ROOT" archive HEAD | tar -x -C "$STAGE"
  SOURCE_KIND="git-head"
  SOURCE_HEAD="$(git -C "$ROOT" rev-parse HEAD)"
else
  (
    cd "$ROOT"
    tar -cf - \
      --exclude='.git' \
      --exclude='.ownframework-loop' \
      --exclude='.worktrees' \
      --exclude='__pycache__' \
      --exclude='*.pyc' \
      --exclude='.DS_Store' \
      --exclude='.install.log' \
      --exclude='.uninstall.log' \
      --exclude='.supervisor-refresh.log' \
      .
  ) | tar -xf - -C "$STAGE"
  SOURCE_KIND="source-tree"
  SOURCE_HEAD=""
fi

[[ -x "$STAGE/bin/ofloop" ]] || { echo "CORE_INSTALL=REFUSED reason=staged_launcher_missing" >&2; exit 4; }
STAGED_VERSION="$(PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$STAGE/lib" python3 -B - <<'PY'
from ownframework_loop import __version__
print(__version__)
PY
)"
[[ "$STAGED_VERSION" == "$VERSION" ]] || {
  echo "CORE_INSTALL=REFUSED reason=staged_version_mismatch expected=$VERSION actual=$STAGED_VERSION" >&2
  exit 4
}

INCOMING_GENERATION="$(PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$STAGE/lib" STAGE_ROOT="$STAGE" STAGED_VERSION="$STAGED_VERSION" python3 -B - <<'PY'
import os
from pathlib import Path
from ownframework_loop.runtime_identity import runtime_generation_for_root
print(runtime_generation_for_root(Path(os.environ["STAGE_ROOT"]), os.environ["STAGED_VERSION"]))
PY
)"
[[ -n "$INCOMING_GENERATION" ]] || { echo "CORE_INSTALL=REFUSED reason=runtime_generation_undetermined" >&2; exit 4; }

# Before replacing any installed bytes, enforce the same runtime-dependency
# contract used by the platform service installers.
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/ownframework-loop"
DB="$STATE_ROOT/supervisor.sqlite3"
PROVENANCE="$STATE_ROOT/runtime-provenance.json"
LEDGER_MARKER="$STATE_ROOT/ledger-incarnation.json"
COMMISSIONED=0
case "$(uname -s)" in
  Darwin)
    [[ -f "$HOME/Library/LaunchAgents/com.ownframework.loop-supervisor.plist" || -f "$PROVENANCE" || -f "$DB" || -f "$LEDGER_MARKER" ]] && COMMISSIONED=1
    ;;
  Linux)
    UNIT_DIR="${OFLOOP_SYSTEMD_USER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
    [[ -f "$UNIT_DIR/ownframework-loop-supervisor.service" || -f "$PROVENANCE" || -f "$DB" || -f "$LEDGER_MARKER" ]] && COMMISSIONED=1
    ;;
esac
if [[ "$COMMISSIONED" == "1" ]]; then
  [[ -f "$DB" ]] || { echo "CORE_INSTALL=REFUSED reason=runtime_dependency_ledger_missing" >&2; exit 13; }
  PROBE_ARGS=("$DB" "$INCOMING_GENERATION")
  [[ "${OFLOOP_ALLOW_SUPERVISOR_SWAP_WITH_ACTIVE_WORK:-0}" == "1" ]] && PROBE_ARGS+=(--allow-active)
  [[ "${OFLOOP_ALLOW_RUNTIME_GENERATION_MIGRATION:-0}" == "1" ]] && PROBE_ARGS+=(--allow-generation-migration)
  set +e
  PROBE_OUT="$(PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$STAGE/lib" python3 -B "$STAGE/scripts/probe-supervisor-runtime-dependencies.py" "${PROBE_ARGS[@]}" 2>&1)"
  PROBE_RC=$?
  set -e
  if [[ "$PROBE_RC" -ne 0 ]]; then
    echo "CORE_INSTALL=REFUSED $PROBE_OUT" >&2
    exit "$PROBE_RC"
  fi
fi

cat > "$STAGE/.ownframework-loop-managed" <<EOF
kind=core
version=$VERSION
source_kind=$SOURCE_KIND
source_head=$SOURCE_HEAD
EOF

# Installed payload integrity is core-owned, not adapter/plugin-owned.
STAGE_ROOT="$STAGE" VERSION="$VERSION" SOURCE_KIND="$SOURCE_KIND" SOURCE_HEAD="$SOURCE_HEAD" \
python3 -B - <<'PY'
import fnmatch,hashlib,os
from pathlib import Path
root=Path(os.environ["STAGE_ROOT"])
skip_dirs={".git","logs",".ownframework-loop","__pycache__"}
skip_names={".payload.manifest",".payload.manifest.tmp"}
skip_suffixes=(".pyc",".pyo",".pyd")
files=[]
for dirpath,dirnames,filenames in os.walk(root):
    dirnames[:]=sorted(d for d in dirnames if d not in skip_dirs)
    base=Path(dirpath)
    for name in sorted(filenames):
        if name in skip_names or name.endswith(skip_suffixes):
            continue
        p=base/name
        if not p.is_file():
            continue
        files.append(p)
files=sorted(files,key=lambda p:p.relative_to(root).as_posix())
manifest=root/".payload.manifest"
lines=[
    "# OwnFramework Loop core payload manifest",
    f"# installed_version={os.environ['VERSION']}",
    f"# source_kind={os.environ['SOURCE_KIND']}",
    f"# source_head={os.environ.get('SOURCE_HEAD') or '(none)'}",
]
for p in files:
    rel=p.relative_to(root).as_posix()
    h=hashlib.sha256(p.read_bytes()).hexdigest()
    lines.append(f"sha256  {h}  {rel}")
lines.append(f"# file_count={len(files)}")
manifest.write_text("\n".join(lines)+"\n",encoding="utf-8")
PY

PYTHONDONTWRITEBYTECODE=1 python3 -B "$STAGE/scripts/verify_payload_manifest.py" \
  --root "$STAGE" --manifest "$STAGE/.payload.manifest" >/dev/null
PYTHONDONTWRITEBYTECODE=1 python3 -B "$STAGE/scripts/manifest_count_check.py" \
  --root "$STAGE" --manifest "$STAGE/.payload.manifest" >/dev/null

BACKUP_ROOT="$(mktemp -d "$DATA_BASE/.preinstall-$VERSION-XXXXXX")"
rmdir "$BACKUP_ROOT"
HAD_OLD=0
if [[ -e "$INSTALL_ROOT" ]]; then
  mv "$INSTALL_ROOT" "$BACKUP_ROOT"
  HAD_OLD=1
fi
mv "$STAGE" "$INSTALL_ROOT"
trap - EXIT INT TERM HUP

rollback_core_install() {
  rm -rf "$INSTALL_ROOT"
  if [[ "$HAD_OLD" == "1" ]]; then mv "$BACKUP_ROOT" "$INSTALL_ROOT"; fi
  rm -f "$LAUNCHER"
  if [[ "$HAD_PREVIOUS_LAUNCHER" == "1" ]]; then
    if [[ "$PREVIOUS_LAUNCHER_KIND" == "symlink" ]]; then
      ln -s "$PREVIOUS_LAUNCHER_TARGET" "$LAUNCHER"
    else
      cp -p "$PREVIOUS_LAUNCHER_BACKUP" "$LAUNCHER"
    fi
  fi
}

NEW_LAUNCHER="$BIN_DIR/.ofloop.new.$$"
rm -f "$NEW_LAUNCHER"
if ! ln -s "$INSTALL_ROOT/bin/ofloop" "$NEW_LAUNCHER" ||
   ! mv -f "$NEW_LAUNCHER" "$LAUNCHER"; then
  rm -f "$NEW_LAUNCHER"
  rollback_core_install
  rm -f "$PREVIOUS_LAUNCHER_BACKUP"
  echo "CORE_INSTALL=REFUSED reason=launcher_publish_failed rollback=core_runtime_and_launcher_restored" >&2
  exit 5
fi

if ! "$LAUNCHER" adapter doctor generic-cli >/dev/null; then
  rollback_core_install
  rm -f "$PREVIOUS_LAUNCHER_BACKUP"
  echo "CORE_INSTALL=REFUSED reason=installed_core_doctor_failed rollback=core_runtime_and_launcher_restored" >&2
  exit 5
fi

# Refresh only an already-commissioned durable service. Core installation never
# creates a service implicitly.
REFRESH="$INSTALL_ROOT/scripts/refresh-existing-supervisor.sh"
if [[ -x "$REFRESH" && "${OFLOOP_SKIP_SUPERVISOR_REFRESH:-0}" != "1" ]]; then
  if ! "$REFRESH" "$INSTALL_ROOT" "$ROOT"; then
    rollback_core_install
    rm -f "$PREVIOUS_LAUNCHER_BACKUP"
    echo "CORE_INSTALL=REFUSED reason=supervisor_refresh_failed rollback=core_runtime_and_launcher_restored" >&2
    exit 5
  fi
fi
[[ "$HAD_OLD" == "1" ]] && rm -rf "$BACKUP_ROOT"
rm -f "$PREVIOUS_LAUNCHER_BACKUP"

cat <<EOF
CORE_INSTALL=PASS
VERSION=$VERSION
CORE_ROOT=$INSTALL_ROOT
OFLOOP_LAUNCHER=$LAUNCHER
PLATFORM=$(uname -s)
SOURCE_KIND=$SOURCE_KIND
SOURCE_HEAD=${SOURCE_HEAD:-(none)}
RUNTIME_GENERATION=$INCOMING_GENERATION
EOF
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "PATH_NOTE=Add $BIN_DIR to PATH to invoke 'ofloop' directly." ;;
esac
